# Fulfillment Bottleneck Diagnosis

## Project overview

This project uses SQL and Python to investigate where orders slow down between placement and delivery. It audits data quality and timeline consistency, builds a stage funnel, calculates transition durations, segments the handover-to-transit delay, and estimates the business exposure associated with late and stuck orders.

**Dataset snapshot:** use `MAX(order_stage_events.stage_timestamp)` as the snapshot reference rather than the computer's current date.

## Business questions

1. Do the core tables contain invalid values or broken relationships?
2. Are stage timestamps consistent with the expected fulfillment sequence?
3. How many distinct orders reach each stage, and where are the funnel gaps?
4. Which stage transitions have the longest average, median, and P90 duration?
5. Do transition durations differ by month, warehouse, carrier, priority, or order-placement weekday?
6. Which transitions are most often the longest transition within late orders?
7. What order value is associated with late and stuck orders?
8. What does a warehouse benchmark suggest about a possible improvement opportunity?

## Repository structure

```text
fulfillment_bottleneck_phase11/
├── fulfillment_analysis.py
├── requirements.txt
├── .env.example
├── README.md
├── findings_report.md
├── linkedin_post.md
├── sql/
│   ├── 01_surface_and_referential_integrity_audit.sql
│   ├── 02_date_logic_audit.sql
│   ├── 03_funnel_and_drop_off.sql
│   ├── 04_stage_duration_audit.sql
│   ├── 05_segmentation_for_transition.sql
│   ├── 06_promise_vs_reality_late_delivery.sql
│   └── 07_business_impact.sql
├── outputs/
│   ├── check_summary.csv       # generated when script runs
│   ├── per-check CSVs          # generated when script runs
│   └── transition_pivots_reference.xlsx
└── charts/
    ├── funnel_bar.png          # generated when data is available
    ├── stage_duration_boxplot.png
    └── carrier_warehouse_heatmap.png
```

## Setup

Requires Python 3.10+ and MySQL 8+ (the script uses CTEs and window functions).

1. Create/activate a virtual environment.
2. Install dependencies:

   ```bash
   pip install -r requirements.txt
   ```

3. Set the database connection environment variables. Defaults are `localhost:3306`, database `fulfillment_diag`, user `root`, and blank password. For example in PowerShell:

   ```powershell
   $env:DB_HOST="localhost"
   $env:DB_PORT="3306"
   $env:DB_NAME="fulfillment_diag"
   $env:DB_USER="root"
   $env:DB_PASSWORD="your_password"
   python fulfillment_analysis.py
   ```

   In macOS/Linux:

   ```bash
   export DB_HOST=localhost
   export DB_PORT=3306
   export DB_NAME=fulfillment_diag
   export DB_USER=root
   export DB_PASSWORD='your_password'
   python fulfillment_analysis.py
   ```

4. Confirm that the six source tables exist in the database: `warehouses`, `carriers`, `customers`, `orders`, `shipments`, and `order_stage_events`.

**Security:** never commit real credentials. `.env.example` is only a template; the script reads environment variables directly and does not require a `.env` file.

## Automation behaviour

- `QUERIES` contains one named query per check.
- `run_check()` returns a consistent dictionary containing check name, status, returned row count, output path, error, and the resulting DataFrame.
- Every check is wrapped in its own `try/except`; one failed query is recorded and does not prevent the remaining checks from running.
- `outputs/check_summary.csv` records each check's success/failure and error message.
- Successful checks create individual CSV files in `outputs/`.
- Three charts are generated when their input query succeeds and returns usable data:
  - `funnel_bar.png` — distinct orders at each event stage.
  - `stage_duration_boxplot.png` — distribution of durations for the seven standard adjacent transitions. Outliers are hidden for readability, not deleted from the data.
  - `carrier_warehouse_heatmap.png` — average `handed_to_carrier → in_transit` duration by warehouse and carrier. Blank cells mean no matching observations.

The script logs failures and continues. Review `check_summary.csv` after each run rather than assuming every check succeeded.

## Important definitions

- **Funnel count:** distinct orders with at least one event for that stage. This is not necessarily a sequential conversion funnel; a missing event can cause an order to be absent from a stage count.
- **Stuck order:** last recorded stage is not `delivered`, and the last event is at least 14 days before the dataset snapshot. This is an analytical threshold, not a confirmed business SLA.
- **Late rate:** late orders / (late orders + on-time orders). Pending outcomes are excluded.
- **P90:** the 90th percentile of observed transition durations. It helps describe the slower tail, not just the typical order.
- **Benchmark estimate:** applying Warehouse 6's observed late rate to other warehouses is a scenario estimate, not a causal forecast or guaranteed reduction.

## Data and analytical caveats

- Stage event timestamps may represent scan/logging time rather than the exact physical moment an operation occurred.
- Missing intermediate events can create direct transitions such as `placed → picked`; these should be reviewed as possible instrumentation gaps rather than assumed process steps.
- A warehouse/carrier average with a very small sample is unstable. Always review `transition_count` alongside `avg_hours`.
- Observed differences by warehouse, carrier, and priority are associations. Route, order mix, allocation, and missing data may explain part of the differences.
- Order value associated with late or stuck orders is exposure, not automatically a financial loss. Refunds, compensation, cancellation, and retention data would be needed to estimate realized loss.
- The Python runner reproduces the core checks in a reusable form. The original SQL files are retained under `sql/` for auditability; the Python implementation makes some defensive choices explicit (for example, the intended `>= 14 days` stuck threshold and timestamp ordering to break ties).

## Main findings (current analysis snapshot)

- 3,000 orders and 20,078 stage events.
- 274 orders meet the 14-day stuck-order rule (9.13% of all orders).
- `handed_to_carrier → in_transit`: average around 74.31 hours, median 70 hours, P90 116 hours.
- `in_transit → delivered`: average around 74.26 hours, median 71 hours, P90 115 hours.
- Late orders are associated with 16,373,090 in order value; stuck orders with 7,230,500. These groups can overlap, so do not add the amounts without deduplicating orders.
- Express observed late rate: 92.40%; Standard: 85.77%, using late/(late + on-time).
- Warehouse 6 had the lowest observed warehouse late rate among the eight warehouses at 84.30%; a simple benchmark scenario suggested about 92 fewer late outcomes, subject to comparability assumptions.

## Reproducibility checklist

- [ ] Database connection configured without committing credentials.
- [ ] All expected tables available.
- [ ] Script completed and `check_summary.csv` reviewed.
- [ ] Failed checks investigated rather than silently ignored.
- [ ] Chart source CSVs inspected for sample sizes and missing groups.
- [ ] Findings reported as observed associations, not proven causes.
