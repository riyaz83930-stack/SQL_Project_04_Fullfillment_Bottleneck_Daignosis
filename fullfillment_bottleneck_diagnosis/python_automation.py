"""Fulfillment Bottleneck Diagnosis — repeatable SQL-to-Python analysis.

Reads the existing MySQL fulfillment_diag database, runs each check independently,
returns a dict of DataFrames, writes check_summary.csv and per-check CSVs, and
creates the three requested charts. Each check is isolated by try/except so one
failed query does not stop the rest of the pipeline.

Configure DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD as environment variables.
"""
from __future__ import annotations
import os
import re
import logging
from pathlib import Path
from typing import Dict

import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

BASE_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = BASE_DIR / "outputs"
CHART_DIR = BASE_DIR / "charts"
OUTPUT_DIR.mkdir(exist_ok=True)
CHART_DIR.mkdir(exist_ok=True)

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")

STAGE_ORDER = [
    "placed", "payment_verified", "picked", "packed",
    "handed_to_carrier", "in_transit", "delivered"
]

# One query per check. Names intentionally map to the SQL audit files/tasks.
QUERIES: Dict[str, str] = {
    "table_row_counts": """
        SELECT 'warehouses' table_name, COUNT(*) total_rows FROM warehouses
        UNION ALL SELECT 'carriers', COUNT(*) FROM carriers
        UNION ALL SELECT 'customers', COUNT(*) FROM customers
        UNION ALL SELECT 'orders', COUNT(*) FROM orders
        UNION ALL SELECT 'shipments', COUNT(*) FROM shipments
        UNION ALL SELECT 'order_stage_events', COUNT(*) FROM order_stage_events
    """,
    "invalid_order_values": """
        SELECT order_id, order_value,
            CASE WHEN order_value IS NULL THEN 'null'
                    WHEN order_value = 0 THEN 'zero'
                    WHEN order_value < 0 THEN 'negative' END AS issue
        FROM orders WHERE order_value IS NULL OR order_value <= 0
    """,
    "order_status_distribution": """
        SELECT LOWER(TRIM(order_status)) order_status, COUNT(*) orders,
            ROUND(100.0*COUNT(*)/NULLIF((SELECT COUNT(*) FROM orders),0),2) pct
        FROM orders GROUP BY LOWER(TRIM(order_status)) ORDER BY orders DESC
    """,
    "priority_distribution": """
        SELECT priority original_value, LOWER(TRIM(priority)) normalized_value, COUNT(*) row_count
        FROM orders GROUP BY priority, LOWER(TRIM(priority)) ORDER BY row_count DESC
    """,
    "stage_value_distribution": """
        SELECT stage original_value, LOWER(TRIM(stage)) normalized_value, COUNT(*) row_count
        FROM order_stage_events GROUP BY stage, LOWER(TRIM(stage)) ORDER BY row_count DESC
    """,
    "delivery_status_distribution": """
        SELECT delivery_status original_value, LOWER(TRIM(delivery_status)) normalized_value, COUNT(*) row_count
        FROM shipments GROUP BY delivery_status, LOWER(TRIM(delivery_status)) ORDER BY row_count DESC
    """,
    "orphan_customer_orders": """
        SELECT o.* FROM orders o LEFT JOIN customers c ON o.customer_id=c.customer_id
        WHERE o.customer_id IS NOT NULL AND c.customer_id IS NULL
    """,
    "orphan_warehouse_orders": """
        SELECT o.* FROM orders o LEFT JOIN warehouses w ON o.warehouse_id=w.warehouse_id
        WHERE o.warehouse_id IS NOT NULL AND w.warehouse_id IS NULL
    """,
    "orphan_stage_event_orders": """
        SELECT e.* FROM order_stage_events e LEFT JOIN orders o ON e.order_id=o.order_id
        WHERE e.order_id IS NOT NULL AND o.order_id IS NULL
    """,
    "orphan_shipment_orders": """
        SELECT s.* FROM shipments s LEFT JOIN orders o ON s.order_id=o.order_id
        WHERE s.order_id IS NOT NULL AND o.order_id IS NULL
    """,
    "orphan_shipment_carriers": """
        SELECT s.* FROM shipments s LEFT JOIN carriers c ON s.carrier_id=c.carrier_id
        WHERE s.carrier_id IS NOT NULL AND c.carrier_id IS NULL
    """,
    "orders_without_stage_events": """
        SELECT o.* FROM orders o WHERE NOT EXISTS
        (SELECT 1 FROM order_stage_events e WHERE e.order_id=o.order_id)
    """,
    "customers_without_orders": """
        SELECT c.* FROM customers c WHERE NOT EXISTS
        (SELECT 1 FROM orders o WHERE o.customer_id=c.customer_id)
    """,
    "events_before_order_placed": """
        SELECT e.order_id,e.stage,e.stage_timestamp,o.order_placed_at
        FROM order_stage_events e JOIN orders o ON e.order_id=o.order_id
        WHERE e.stage_timestamp < o.order_placed_at
    """,
    "out_of_sequence_timestamps": """
        WITH seq AS (
        SELECT order_id, stage, stage_timestamp,
            CASE LOWER(TRIM(stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2
            WHEN 'picked' THEN 3 WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5
            WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events
        ), ordered AS (
          SELECT *, LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_event
        FROM seq
        )
        SELECT * FROM ordered WHERE stage_timestamp < prev_event
    """,
    "duplicate_stage_events": """
        WITH d AS (
        SELECT e.*, ROW_NUMBER() OVER(PARTITION BY order_id,LOWER(TRIM(stage)) ORDER BY stage_timestamp) rn,
                LAG(stage_timestamp) OVER(PARTITION BY order_id,LOWER(TRIM(stage)) ORDER BY stage_timestamp) prev_same_stage_time
        FROM order_stage_events e
        )
        SELECT * FROM d WHERE rn > 1 AND TIMESTAMPDIFF(MINUTE,prev_same_stage_time,stage_timestamp) <= 60
    """,
    "missing_intermediate_stages": """
        WITH seq AS (
        SELECT order_id,stage,stage_timestamp,
            CASE LOWER(TRIM(stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2
            WHEN 'picked' THEN 3 WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5
            WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events
        ), ordered AS (
          SELECT *, LAG(stage_sequence) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_sequence
        FROM seq
        )
        SELECT * FROM ordered WHERE stage_sequence-prev_sequence > 1
    """,
    "shipment_event_time_mismatches": """
        WITH x AS (
        SELECT e.order_id,e.stage,e.stage_timestamp,s.handed_over_at,s.delivered_at,
            CASE
            WHEN LOWER(TRIM(e.stage))='handed_to_carrier' AND ABS(TIMESTAMPDIFF(MINUTE,e.stage_timestamp,s.handed_over_at)) > 30 THEN 'handover_time_mismatch'
            WHEN LOWER(TRIM(e.stage))='delivered' AND NOT (e.stage_timestamp <=> s.delivered_at) THEN 'delivery_time_mismatch'
            END mismatch_type
        FROM order_stage_events e JOIN shipments s ON e.order_id=s.order_id
        WHERE LOWER(TRIM(e.stage)) IN ('handed_to_carrier','delivered')
        ) SELECT * FROM x WHERE mismatch_type IS NOT NULL
    """,
    "delivered_before_handover": """
        SELECT * FROM shipments WHERE delivered_at < handed_over_at
    """,
    "funnel_counts": """
        SELECT LOWER(TRIM(stage)) stage, COUNT(DISTINCT order_id) orders_at_stage
        FROM order_stage_events
        WHERE LOWER(TRIM(stage)) IN ('placed','payment_verified','picked','packed','handed_to_carrier','in_transit','delivered')
        GROUP BY LOWER(TRIM(stage))
    """,
    "stuck_orders": """
        WITH last_event AS (
        SELECT e.order_id, MAX(e.stage_timestamp) last_event_time,
                SUBSTRING_INDEX(GROUP_CONCAT(LOWER(TRIM(e.stage)) ORDER BY e.stage_timestamp DESC),',',1) last_stage
        FROM order_stage_events e GROUP BY e.order_id
        ), snap AS (SELECT MAX(stage_timestamp) snapshot_time FROM order_stage_events)
        SELECT l.order_id,l.last_stage,l.last_event_time,s.snapshot_time,
            DATEDIFF(s.snapshot_time,l.last_event_time) stuck_days,o.order_value,o.warehouse_id,o.priority
        FROM last_event l CROSS JOIN snap s JOIN orders o ON o.order_id=l.order_id
        WHERE l.last_stage <> 'delivered' AND DATEDIFF(s.snapshot_time,l.last_event_time) >= 14
    """,
    "stage_durations": """
        WITH clean_events AS (
        SELECT order_id,LOWER(TRIM(stage)) stage,stage_timestamp,
            CASE LOWER(TRIM(stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2
            WHEN 'picked' THEN 3 WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5
            WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events
        ), transitions AS (
        SELECT order_id,stage,stage_timestamp,
            LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_timestamp
        FROM clean_events
        )
        SELECT order_id, CONCAT(prev_stage,' -to- ',stage) transition,
            prev_stage,stage,prev_timestamp,stage_timestamp,
            TIMESTAMPDIFF(MINUTE,prev_timestamp,stage_timestamp)/60.0 hour_taken
        FROM transitions WHERE prev_timestamp IS NOT NULL AND stage_timestamp >= prev_timestamp
        AND prev_stage IS NOT NULL
    """,
    "monthly_transition_duration": """
        WITH d AS (
        SELECT order_id,stage_timestamp,
            LOWER(TRIM(stage)) stage,
            CASE LOWER(TRIM(stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        )
        SELECT DATE_FORMAT(stage_timestamp,'%Y-%b') month_year,CONCAT(prev_stage,' -to- ',stage) transition,
        COUNT(*) transition_count,AVG(TIMESTAMPDIFF(MINUTE,prev_time,stage_timestamp)/60.0) avg_hours
        FROM t WHERE prev_time IS NOT NULL AND stage_timestamp>=prev_time
        GROUP BY DATE_FORMAT(stage_timestamp,'%Y-%b'),CONCAT(prev_stage,' -to- ',stage)
    """,
    "warehouse_transition_duration": """
        WITH d AS (
        SELECT e.order_id,e.stage_timestamp,LOWER(TRIM(e.stage)) stage,
            CASE LOWER(TRIM(e.stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events e
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        )
        SELECT o.warehouse_id,CONCAT(t.prev_stage,' -to- ',t.stage) transition,
        COUNT(*) transition_count,AVG(TIMESTAMPDIFF(MINUTE,t.prev_time,t.stage_timestamp)/60.0) avg_hours
        FROM t JOIN orders o ON o.order_id=t.order_id
        WHERE t.prev_time IS NOT NULL AND t.stage_timestamp>=t.prev_time
        GROUP BY o.warehouse_id,CONCAT(t.prev_stage,' -to- ',t.stage)
    """,
    "carrier_warehouse_handover_to_transit": """
        WITH d AS (
        SELECT e.order_id,e.stage_timestamp,LOWER(TRIM(e.stage)) stage,
            CASE LOWER(TRIM(e.stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events e
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        )
        SELECT o.warehouse_id,s.carrier_id,COUNT(*) transition_count,
        AVG(TIMESTAMPDIFF(MINUTE,t.prev_time,t.stage_timestamp)/60.0) avg_hours
        FROM t JOIN orders o ON o.order_id=t.order_id JOIN shipments s ON s.order_id=t.order_id
        WHERE t.prev_stage='handed_to_carrier' AND t.stage='in_transit'
        AND t.prev_time IS NOT NULL AND t.stage_timestamp>=t.prev_time AND s.carrier_id IS NOT NULL
        GROUP BY o.warehouse_id,s.carrier_id
    """,
    "priority_handover_to_transit": """
        WITH d AS (
        SELECT e.order_id,e.stage_timestamp,LOWER(TRIM(e.stage)) stage,
            CASE LOWER(TRIM(e.stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events e
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        )
        SELECT LOWER(TRIM(o.priority)) priority,COUNT(*) transition_count,
        AVG(TIMESTAMPDIFF(MINUTE,t.prev_time,t.stage_timestamp)/60.0) avg_hours
        FROM t JOIN orders o ON o.order_id=t.order_id
        WHERE t.prev_stage='handed_to_carrier' AND t.stage='in_transit'
        AND t.prev_time IS NOT NULL AND t.stage_timestamp>=t.prev_time
        GROUP BY LOWER(TRIM(o.priority))
    """,
    "weekday_handover_to_transit": """
        WITH d AS (
        SELECT e.order_id,e.stage_timestamp,LOWER(TRIM(e.stage)) stage,
            CASE LOWER(TRIM(e.stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events e
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        )
        SELECT DAYNAME(o.order_placed_at) placed_weekday,DAYOFWEEK(o.order_placed_at) weekday_number,
        COUNT(*) transition_count,AVG(TIMESTAMPDIFF(MINUTE,t.prev_time,t.stage_timestamp)/60.0) avg_hours
        FROM t JOIN orders o ON o.order_id=t.order_id
        WHERE t.prev_stage='handed_to_carrier' AND t.stage='in_transit'
        AND t.prev_time IS NOT NULL AND t.stage_timestamp>=t.prev_time
        GROUP BY DAYOFWEEK(o.order_placed_at),DAYNAME(o.order_placed_at)
        ORDER BY weekday_number
    """,
    "delivery_status_by_priority": """
        SELECT LOWER(TRIM(o.priority)) priority,LOWER(TRIM(s.delivery_status)) delivery_status,
        COUNT(DISTINCT o.order_id) orders
        FROM orders o LEFT JOIN shipments s ON s.order_id=o.order_id
        GROUP BY LOWER(TRIM(o.priority)),LOWER(TRIM(s.delivery_status))
    """,
    "late_orders_longest_transition": """
        WITH d AS (
        SELECT e.order_id,e.stage_timestamp,LOWER(TRIM(e.stage)) stage,
            CASE LOWER(TRIM(e.stage)) WHEN 'placed' THEN 1 WHEN 'payment_verified' THEN 2 WHEN 'picked' THEN 3
            WHEN 'packed' THEN 4 WHEN 'handed_to_carrier' THEN 5 WHEN 'in_transit' THEN 6 WHEN 'delivered' THEN 7 END stage_sequence
        FROM order_stage_events e
        ), t AS (
          SELECT *,LAG(stage) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_stage,
            LAG(stage_timestamp) OVER(PARTITION BY order_id ORDER BY stage_sequence,stage_timestamp) prev_time
        FROM d
        ), durations AS (
        SELECT order_id,CONCAT(prev_stage,' -to- ',stage) transition,
            TIMESTAMPDIFF(MINUTE,prev_time,stage_timestamp)/60.0 hour_taken
        FROM t WHERE prev_time IS NOT NULL AND stage_timestamp>=prev_time
        ), ranked AS (
        SELECT durations.*,ROW_NUMBER() OVER(PARTITION BY order_id ORDER BY hour_taken DESC) rn
        FROM durations
        )
        SELECT r.transition,COUNT(*) orders,AVG(r.hour_taken) avg_hours
        FROM ranked r JOIN shipments s ON s.order_id=r.order_id
        WHERE r.rn=1 AND LOWER(TRIM(s.delivery_status))='late'
        GROUP BY r.transition
    """,
    "late_and_stuck_order_value": """
        WITH snapshot AS (SELECT MAX(stage_timestamp) snapshot_time FROM order_stage_events),
        last_event AS (
        SELECT e.order_id,MAX(e.stage_timestamp) last_event_time,
            SUBSTRING_INDEX(GROUP_CONCAT(LOWER(TRIM(e.stage)) ORDER BY e.stage_timestamp DESC),',',1) last_stage
        FROM order_stage_events e GROUP BY e.order_id
        ), stuck AS (
        SELECT l.order_id FROM last_event l CROSS JOIN snapshot x
        WHERE l.last_stage<>'delivered' AND DATEDIFF(x.snapshot_time,l.last_event_time)>=14
        ), late AS (SELECT DISTINCT s.order_id FROM shipments s WHERE LOWER(TRIM(s.delivery_status))='late')
        SELECT 'late_orders' metric,COUNT(DISTINCT o.order_id) orders,COALESCE(SUM(o.order_value),0) order_value
        FROM orders o JOIN late l ON l.order_id=o.order_id
        UNION ALL
        SELECT 'stuck_orders',COUNT(DISTINCT o.order_id),COALESCE(SUM(o.order_value),0)
        FROM orders o JOIN stuck st ON st.order_id=o.order_id
    """,
    "warehouse_delivery_performance": """
        SELECT o.warehouse_id,COUNT(DISTINCT o.order_id) total_orders,
        COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='late' THEN o.order_id END) late_orders,
        COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='on_time' THEN o.order_id END) on_time_orders,
        ROUND(100.0*COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='late' THEN o.order_id END)/
            NULLIF(COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status)) IN ('late','on_time') THEN o.order_id END),0),2) late_rate_pct
        FROM orders o LEFT JOIN shipments s ON s.order_id=o.order_id GROUP BY o.warehouse_id
    """,
    "carrier_delivery_performance": """
        SELECT s.carrier_id,COUNT(DISTINCT o.order_id) total_orders,
        COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='late' THEN o.order_id END) late_orders,
        COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='on_time' THEN o.order_id END) on_time_orders,
        ROUND(100.0*COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status))='late' THEN o.order_id END)/
            NULLIF(COUNT(DISTINCT CASE WHEN LOWER(TRIM(s.delivery_status)) IN ('late','on_time') THEN o.order_id END),0),2) late_rate_pct
        FROM orders o LEFT JOIN shipments s ON s.order_id=o.order_id GROUP BY s.carrier_id
    """,
}


def build_engine() -> Engine:
    """Create SQLAlchemy engine from environment variables (MySQL 8+ recommended)."""
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "3306")
    name = os.getenv("DB_NAME", "project_05_fullfillment_bottleneck_diagnosis")
    user = os.getenv("DB_USER", "root")
    password = os.getenv("DB_PASSWORD", "")
    url = f"mysql+pymysql://{user}:{password}@{host}:{port}/{name}?charset=utf8mb4"
    return create_engine(url, pool_pre_ping=True)


def run_check(engine: Engine, check_name: str, query: str) -> dict:
    """Run one check safely and return a consistent result dictionary."""
    result = {"check_name": check_name, "status": "failed", "rows_returned": 0,
                "output_file": "", "error": "", "data": pd.DataFrame()}
    try:
        df = pd.read_sql(text(query), engine)
        safe_name = re.sub(r"[^a-zA-Z0-9_-]+", "_", check_name).strip("_")
        output_path = OUTPUT_DIR / f"{safe_name}.csv"
        df.to_csv(output_path, index=False)
        result.update(status="success", rows_returned=len(df), output_file=str(output_path), data=df)
        logging.info("OK %-42s rows=%s", check_name, len(df))
    except Exception as exc:  # keep remaining checks running
        result["error"] = f"{type(exc).__name__}: {exc}"
        logging.exception("Check failed: %s", check_name)
    return result


def write_summary(results: dict) -> pd.DataFrame:
    rows = [{k: v for k, v in r.items() if k != "data"} for r in results.values()]
    summary = pd.DataFrame(rows, columns=["check_name", "status", "rows_returned", "output_file", "error"])
    summary.to_csv(OUTPUT_DIR / "check_summary.csv", index=False)
    return summary


def create_charts(results: dict) -> dict:
    """Create funnel, transition-duration boxplot and carrier x warehouse heatmap."""
    made = {}
    # 1) Funnel bar chart
    funnel = results.get("funnel_counts", {}).get("data", pd.DataFrame()).copy()
    if not funnel.empty and {"stage", "orders_at_stage"}.issubset(funnel.columns):
        funnel["stage"] = pd.Categorical(funnel["stage"], categories=STAGE_ORDER, ordered=True)
        funnel = funnel.sort_values("stage")
        fig, ax = plt.subplots(figsize=(10, 5.5))
        bars = ax.bar(funnel["stage"].astype(str), funnel["orders_at_stage"])
        ax.bar_label(bars, padding=3, fontsize=8)
        ax.set_title("Order Funnel — Distinct Orders Reaching Each Stage")
        ax.set_xlabel("Stage"); ax.set_ylabel("Distinct orders")
        ax.tick_params(axis="x", rotation=30)
        fig.tight_layout(); path = CHART_DIR / "funnel_bar.png"; fig.savefig(path, dpi=160); plt.close(fig)
        made["funnel_bar"] = str(path)

    # 2) Stage-duration box plot (show the seven expected transitions when present)
    durations = results.get("stage_durations", {}).get("data", pd.DataFrame()).copy()
    if not durations.empty and {"transition", "hour_taken"}.issubset(durations.columns):
        durations = durations[durations["hour_taken"].notna() & (durations["hour_taken"] >= 0)]
        counts = durations["transition"].value_counts()
        order = [f"{STAGE_ORDER[i]} -to- {STAGE_ORDER[i+1]}" for i in range(len(STAGE_ORDER)-1)]
        order = [x for x in order if x in counts.index]
        if order:
            plot_df = durations[durations["transition"].isin(order)]
            fig, ax = plt.subplots(figsize=(12, 6))
            sns.boxplot(data=plot_df, x="transition", y="hour_taken", order=order, showfliers=False, ax=ax)
            ax.set_title("Stage Transition Duration Distribution (Outliers Hidden for Readability)")
            ax.set_xlabel("Transition"); ax.set_ylabel("Duration (hours)")
            ax.tick_params(axis="x", rotation=35)
            fig.tight_layout(); path = CHART_DIR / "stage_duration_boxplot.png"; fig.savefig(path, dpi=160); plt.close(fig)
            made["stage_duration_boxplot"] = str(path)

    # 3) Heatmap: average handover-to-transit duration by warehouse and carrier
    heat = results.get("carrier_warehouse_handover_to_transit", {}).get("data", pd.DataFrame()).copy()
    if not heat.empty and {"warehouse_id", "carrier_id", "avg_hours"}.issubset(heat.columns):
        pivot = heat.pivot_table(index="warehouse_id", columns="carrier_id", values="avg_hours", aggfunc="mean")
        if not pivot.empty:
            fig, ax = plt.subplots(figsize=(11, 6.5))
            sns.heatmap(pivot, annot=True, fmt=".1f", linewidths=.4, cmap="YlOrRd", cbar_kws={"label": "Average hours"}, ax=ax)
            ax.set_title("Handover → In Transit: Average Duration by Warehouse × Carrier")
            ax.set_xlabel("Carrier ID"); ax.set_ylabel("Warehouse ID")
            fig.tight_layout(); path = CHART_DIR / "carrier_warehouse_heatmap.png"; fig.savefig(path, dpi=160); plt.close(fig)
            made["carrier_warehouse_heatmap"] = str(path)
    return made


def main() -> None:
    try:
        engine = build_engine()
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:
        raise SystemExit(
            "Database connection failed. Set DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD. "
            f"Details: {type(exc).__name__}: {exc}"
        )

    results = {}
    for name, query in QUERIES.items():
        results[name] = run_check(engine, name, query)

    summary = write_summary(results)
    charts = create_charts(results)
    logging.info("Finished. %s/%s checks succeeded.", (summary.status == "success").sum(), len(summary))
    logging.info("Summary: %s", OUTPUT_DIR / "check_summary.csv")
    logging.info("Charts created: %s", charts)
    engine.dispose()

    # Keep the dict-return pattern available for notebooks / importing.
    return results


if __name__ == "__main__":
    main()
