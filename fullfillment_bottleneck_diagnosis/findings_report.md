# Fulfillment Bottleneck Diagnosis
## Findings, severity, recommendations, and limitations

## 1. Executive summary

The analysis investigated order-stage funnel gaps, prolonged inactivity, transition durations, warehouse/carrier variation, delivery priority, and the order value associated with late and stuck orders. The clearest investigation areas are prolonged stuck orders and the time between carrier handover and the first in-transit event.

The dataset contains approximately 3,000 orders and 20,078 order-stage events. Under the chosen 14-day snapshot-based rule, 274 orders (9.13%) qualify as stuck. The average `handed_to_carrier → in_transit` duration is approximately 74.31 hours (median 70 hours; P90 116 hours). The average `in_transit → delivered` duration is approximately 74.26 hours (median 71 hours; P90 115 hours).

These durations may reflect physical delay, late event capture, or both. The available data does not independently establish which explanation is correct.

## 2. Funnel findings

| Stage | Distinct orders reaching stage | Difference from previous stage |
|---|---:|---:|
| placed | 2,988 | — |
| payment_verified | 2,934 | -54 |
| picked | 2,867 | -67 |
| packed | 2,849 | -18 |
| handed_to_carrier | 2,797 | -52 |
| in_transit | 2,733 | -64 |
| delivered | 2,730 | -3 |

These are stage-presence counts. A difference between two stages is not automatically a confirmed operational failure: missing event records, incomplete journeys, and status definitions can affect the counts.

**Severity: Medium.** Use the funnel to direct further checks, not to assign a root cause on its own.

## 3. Stuck orders

The analytical rule is: last recorded stage is not delivered and the last event is at least 14 days before the maximum event timestamp in the dataset.

| Last recorded stage | Stuck orders |
|---|---:|
| payment_verified | 73 |
| packed | 73 |
| handed_to_carrier | 68 |
| placed | 41 |
| picked | 15 |
| in_transit | 4 |
| **Total** | **274** |

274 / 3,000 = **9.13%**.

**Severity: Critical.** A prolonged no-progress signal across 274 orders warrants a stage-specific operational queue, with an assigned owner, delay reason, and next action.

## 4. Stage duration findings

| Transition | Average hours | Median hours | P90 hours |
|---|---:|---:|---:|
| placed → payment_verified | 0.99 | 1 | 2 |
| payment_verified → picked | 7.27 | 5 | 17 |
| picked → packed | 4.37 | 4 | 7 |
| packed → handed_to_carrier | 28.89 | 18 | 64 |
| handed_to_carrier → in_transit | 74.31 | 70 | 116 |
| in_transit → delivered | 74.26 | 71 | 115 |

The two post-handover transitions have the longest observed average durations among the standard sequence. The P90 values show that the slower tail can be substantially longer than the median.

**Severity: Critical for handover-to-transit and transit-to-delivery; High for packed-to-handover.** Validate timestamp semantics and carrier scan compliance before labelling the entire duration as physical delay.

## 5. Delivery promise and priority

| Priority | Late orders | On-time orders | Late rate among classified outcomes |
|---|---:|---:|---:|
| Express | 729 | 60 | 92.40% |
| Standard | 1,640 | 272 | 85.77% |

The Express rate is about 6.63 percentage points higher. Pending outcomes are excluded from the denominator. This counterintuitive pattern should trigger a comparison of promised windows, routes, warehouse allocation, carrier assignment, and order mix. It does not prove that Express priority causes delays.

**Severity: High investigation priority.**

## 6. Warehouse and carrier variation

### Warehouse late rate

| Warehouse | Late | On-time | Classified outcomes | Late rate |
|---|---:|---:|---:|---:|
| 1 | 334 | 42 | 376 | 88.83% |
| 2 | 191 | 23 | 214 | 89.25% |
| 3 | 333 | 40 | 373 | 89.28% |
| 4 | 249 | 28 | 277 | 89.89% |
| 5 | 354 | 52 | 406 | 87.19% |
| 6 | 204 | 38 | 242 | 84.30% |
| 7 | 330 | 53 | 383 | 86.16% |
| 8 | 370 | 55 | 425 | 87.06% |

Warehouse 6 has the lowest observed late rate (84.30%), and Warehouse 4 the highest (89.89%). The 5.59-point difference is descriptive; order mix and allocation may influence it.

### Carrier late rate

| Carrier | Late | On-time | Classified outcomes | Late rate |
|---|---:|---:|---:|---:|
| 1 | 460 | 54 | 514 | 89.49% |
| 2 | 280 | 44 | 324 | 86.42% |
| 3 | 509 | 75 | 584 | 87.16% |
| 4 | 464 | 58 | 522 | 88.89% |
| 5 | 290 | 42 | 332 | 87.35% |
| 6 | 362 | 58 | 420 | 86.19% |

Carrier 6 has the lowest observed rate among the listed carriers (86.19%). Carrier comparisons should be segmented by warehouse, destination, and priority before operational decisions are made.

**Severity: High for investigation; not yet a confirmed root cause.**

## 7. Business impact

| Metric | Observed value | Interpretation |
|---|---:|---|
| Order value associated with late orders | 16,373,090 | Value exposure, not confirmed loss |
| Order value associated with stuck orders | 7,230,500 | Value associated with stuck orders |
| Benchmark scenario | ~92 fewer late orders | Scenario based on applying Warehouse 6's observed late rate to other warehouses |

Late and stuck groups may overlap; their values must not be added without deduplicating orders. The ~92-order scenario assumes that other warehouses could achieve Warehouse 6's rate and does not adjust for route, carrier, priority, or order-mix differences.

**Severity: High business exposure; scenario estimate requires validation.**

## 8. Top five findings

1. **274 stuck orders (9.13%)** — Critical; actionable stage-level follow-up.
2. **Handover-to-transit averages ~74.31 hours** — Critical; investigate physical delay versus scan delay.
3. **Late-order value of 16,373,090** — High exposure; actual financial loss is not established.
4. **Express late rate 92.40% vs Standard 85.77%** — High; unexpected result merits segmented validation.
5. **Warehouse variation and ~92-order benchmark scenario** — High opportunity; benchmark is not a causal forecast.

## 9. Recommendations

1. Create a stuck-order queue using last stage, last event time, age in days, order value, priority, warehouse, carrier, owner, and next action.
2. Track handover-to-first-movement duration using a stage-specific SLA, median, P90, and SLA-breach rate.
3. Capture and validate actual handover scan and first physical movement timestamps to separate process delays from logging delays.
4. Investigate Express late outcomes by promised delivery window, warehouse, carrier, route, and order characteristics.
5. Compare warehouse/carrier performance only alongside sample counts and comparable order mix; do not rank combinations with one observation as confirmed worst performers.
6. Treat Warehouse 6 as a benchmark candidate and validate its practices before scaling them.
7. Add refund, compensation, cancellation, and repeat-purchase data if the business needs realized financial loss rather than associated order value.
8. Standardize event names and instrument useful properties such as order ID, event timestamp, priority, warehouse, carrier, promise timestamp, first movement timestamp, and delay reason. Confirm which properties already exist before calling them missing.

## 10. Data quality and timeline checks

The SQL audit covers invalid order values, categorical consistency, orphan customer/warehouse/order/carrier references, orders without stage events, customers without orders, events before order placement, out-of-sequence timestamps, duplicate stage events, missing intermediate stages, shipment/event timestamp mismatches, and delivery recorded before handover.

Exact affected-row counts for these audit checks should be taken from the generated per-check CSVs and `check_summary.csv`. Do not fill missing counts from assumptions. A failed query is not equivalent to zero affected rows.

## 11. Limitations

- The dataset is synthetic and may not represent real operational distributions.
- The meaning of `stage_timestamp` may be scan/logging time rather than physical operation time.
- The stuck rule uses a 14-day threshold against the dataset snapshot; it is not necessarily a formal SLA.
- The late-rate denominator includes late and on-time orders only; pending outcomes are excluded.
- Stage-presence funnel counts do not prove that one stage directly converted into the next.
- Missing intermediate events can create direct transitions and distort stage duration interpretation.
- Warehouse, carrier, and priority comparisons are observational and do not prove causation.
- Benchmark estimates assume comparability and are not guaranteed improvements.
- Associated order value is not the same as financial loss.
- Very small warehouse-carrier samples create unstable averages.

## Final conclusion

The strongest operational leads are prolonged inactivity among 274 orders and long observed durations after carrier handover. The next step is not to declare a single root cause; it is to validate event timing, isolate the affected warehouse/carrier/priority groups, and create a measurable stage-level improvement loop.
