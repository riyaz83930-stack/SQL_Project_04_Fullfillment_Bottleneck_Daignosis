
-- Promise vs reality




CREATE VIEW order_shipments AS 
SELECT
					o.order_id,
					o.order_status,
					o.warehouse_id,
					o.priority,
					carrier_id,
					handed_over_at,
					promised_delivery_date,
					delivered_at,
					delivery_status,
					DATEDIFF(delivered_at,promised_delivery_date) AS day_diff
					FROM orders o
					LEFT JOIN shipments s
						ON o.order_id=s.order_id

;

-- deleivery_status count by priority

SELECT
	TRIM(LOWER(priority)) AS priority,
	TRIM(LOWER(delivery_status)) AS delivery_status,
	COUNT(order_id) AS orders
FROM order_shipments
GROUP BY 
	TRIM(LOWER(priority)),
	TRIM(LOWER(delivery_status))	
    
    
;

-- deleivery_status count by priority over carrier
SELECT
	TRIM(LOWER(priority)) AS priority,
    carrier_id,
	TRIM(LOWER(delivery_status)) AS delivery_status,
	COUNT(order_id) AS orders
FROM order_shipments
GROUP BY 
	TRIM(LOWER(priority)),
    carrier_id,
	TRIM(LOWER(delivery_status))


;

-- deleivery_status count by priority over warehouse
SELECT
	TRIM(LOWER(priority)) AS priority,
    waarehouse_id,
	TRIM(LOWER(delivery_status)) AS delivery_status,
	COUNT(order_id) AS orders
FROM order_shipments
GROUP BY 
	TRIM(LOWER(priority)),
    waarehouse_id,
	TRIM(LOWER(delivery_status))
;


-- SLOWEST TRANSITION PER ORDER 
WITH 
late_delivery AS (

					SELECT
						t.*,
                        TRIM(LOWER(priority)) AS priority,
						TRIM(LOWER(delivery_status)) AS delivery_status,
						day_diff AS late_day,
                        ROW_NUMBER()OVER(PARTITION BY order_id ORDER BY hour_taken DESC ) AS rnk
					FROM transition_duration t
					LEFT JOIN order_shipments s 
						ON t.order_id=s.order_id
					WHERE trim(lower(s.delivery_status))='late'
				)
-- ,filtering

SELECT
transition,
COUNT(*) AS orders,
AVG(hour_taken) AS avg_hour_taken 
FROM late_delivery
WHERE rnk=1
GROUP BY transition

;



-- FINDING BEST PRIORITY FOR BEST DELIVERY

SELECT
		TRIM(LOWER(priority)) AS priority,
		COUNT(DISTINCT order_id) AS total_order,
		COUNT(CASE WHEN TRIM(LOWER(delivery_status))='late' THEN order_id END ) AS late_delivery,
		COUNT(CASE WHEN TRIM(LOWER(delivery_status))='pending' THEN order_id END ) AS pending_delivery,
		COUNT(CASE WHEN TRIM(LOWER(delivery_status))='on_time' THEN order_id END ) AS ontime_delivery,
        COUNT(CASE WHEN TRIM(LOWER(delivery_status))='late' THEN order_id END )/(COUNT(CASE WHEN TRIM(LOWER(delivery_status))='late' THEN order_id END )+COUNT(CASE WHEN TRIM(LOWER(delivery_status))='on_time' THEN order_id END ))*100 AS promise_miss_rate
FROM order_shipments
GROUP BY 
	TRIM(LOWER(priority))