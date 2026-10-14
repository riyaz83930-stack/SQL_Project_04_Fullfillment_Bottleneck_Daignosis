-- ==========================================================
-- SURFACE EXPLORATION AND REFERENTIAL INTEGERITY AUDIT
-- ==========================================================



-- Tables row counts

SELECT 'warehouses' AS table_name, COUNT(*) AS total_rows
FROM warehouses

UNION ALL

SELECT 'carriers', COUNT(*)
FROM carriers

UNION ALL

SELECT 'customers', COUNT(*)
FROM customers

UNION ALL

SELECT 'orders', COUNT(*)
FROM orders

UNION ALL

SELECT 'shipments', COUNT(*)
FROM shipments

UNION ALL

SELECT 'order_stage_events', COUNT(*)
FROM order_stage_events;


-- Describing tables

DESCRIBE warehouses;
DESCRIBE carriers;
DESCRIBE customers;
DESCRIBE orders;
DESCRIBE shipments;
DESCRIBE order_stage_events;



-- invalid order values
SELECT
    COUNT(*) AS invalid_order_value_rows,
    SUM(order_value = 0) AS zero_value_rows,
    SUM(order_value < 0) AS negative_value_rows
FROM orders
WHERE order_value <= 0;

SELECT *
FROM orders
WHERE order_value <= 0
ORDER BY order_value;

-- Priority row count
SELECT
    priority AS original_value,
    TRIM(priority) AS trimmed_value,
    LOWER(TRIM(priority)) AS normalized_value,
    COUNT(*) AS row_count
FROM orders
GROUP BY
    priority,
    TRIM(priority),
    LOWER(TRIM(priority))
ORDER BY row_count DESC;

-- row count by order status
SELECT
    order_status AS original_value,
    TRIM(order_status) AS trimmed_value,
    LOWER(TRIM(order_status)) AS normalized_value,
    COUNT(*) AS row_count
FROM orders
GROUP BY
    order_status,
    TRIM(order_status),
    LOWER(TRIM(order_status))
ORDER BY row_count DESC;


-- row count for satge 
SELECT
    stage AS original_value,
    TRIM(stage) AS trimmed_value,
    LOWER(TRIM(stage)) AS normalized_value,
    COUNT(*) AS row_count
FROM order_stage_events
GROUP BY
    stage,
    TRIM(stage),
    LOWER(TRIM(stage))
ORDER BY row_count DESC;


-- row count by delivery status
SELECT
    delivery_status AS original_value,
    TRIM(delivery_status) AS trimmed_value,
    LOWER(TRIM(delivery_status)) AS normalized_value,
    COUNT(*) AS row_count
FROM shipments
GROUP BY
    delivery_status,
    TRIM(delivery_status),
    LOWER(TRIM(delivery_status))
ORDER BY row_count DESC;



-- row count by customer tier 
SELECT
    tier AS original_value,
    TRIM(tier) AS trimmed_value,
    LOWER(TRIM(tier)) AS normalized_value,
    COUNT(*) AS row_count
FROM customers
GROUP BY
    tier,
    TRIM(tier),
    LOWER(TRIM(tier))
ORDER BY row_count DESC;



-- total orders distribution by status
SELECT
    trim(lower(order_status)) AS order_status,
    COUNT(*) AS total_orders,
    ROUND(
        100.0 * COUNT(*) / NULLIF((SELECT COUNT(*) FROM orders), 0),
        2
    ) AS percentage
FROM orders
GROUP BY  trim(lower(order_status))
ORDER BY total_orders DESC;


-- finding orphan customers orders 
SELECT
    COUNT(*) AS orphan_customer_orders
FROM orders o
LEFT JOIN customers c
    ON o.customer_id = c.customer_id
WHERE o.customer_id IS NOT NULL
  AND c.customer_id IS NULL;
  
  
  
SELECT o.*
FROM orders o
LEFT JOIN customers c
    ON o.customer_id = c.customer_id
WHERE o.customer_id IS NOT NULL
  AND c.customer_id IS NULL;
  
  
  
 --  orphan warehouse orders
  SELECT
    COUNT(*) AS orphan_warehouse_orders
FROM orders o
LEFT JOIN warehouses w
    ON o.warehouse_id = w.warehouse_id
WHERE o.warehouse_id IS NOT NULL
  AND w.warehouse_id IS NULL;
  
  
SELECT o.*
FROM orders o
LEFT JOIN warehouses w
    ON o.warehouse_id = w.warehouse_id
WHERE o.warehouse_id IS NOT NULL
  AND w.warehouse_id IS NULL;
  
  
  
 --  orphan satge events rows 
SELECT
    COUNT(*) AS orphan_stage_event_rows
FROM order_stage_events e
LEFT JOIN orders o
    ON e.order_id = o.order_id
WHERE e.order_id IS NOT NULL
  AND o.order_id IS NULL;
  
  
-- orphan shipments orders 
SELECT
    COUNT(*) AS orphan_shipment_order_rows
FROM shipments s
LEFT JOIN orders o
    ON s.order_id = o.order_id
WHERE s.order_id IS NOT NULL
  AND o.order_id IS NULL;
  
 
 -- orphan shipment carriers
SELECT
    COUNT(*) AS orphan_shipment_carrier_rows
FROM shipments s
LEFT JOIN carriers c
    ON s.carrier_id = c.carrier_id
WHERE s.carrier_id IS NOT NULL
  AND c.carrier_id IS NULL;



--   orders without stage event 
SELECT
    COUNT(*) AS orders_without_stage_events
FROM orders o
WHERE NOT EXISTS (
    SELECT 1
    FROM order_stage_events e
    WHERE e.order_id = o.order_id
);

SELECT o.*
FROM orders o
WHERE NOT EXISTS (
    SELECT 1
    FROM order_stage_events e
    WHERE e.order_id = o.order_id
);



-- customers with zero orders
SELECT
    COUNT(*) AS customers_with_zero_orders
FROM customers c
WHERE NOT EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.customer_id = c.customer_id
);

SELECT c.*
FROM customers c
WHERE NOT EXISTS (
    SELECT 1
    FROM orders o
    WHERE o.customer_id = c.customer_id
);