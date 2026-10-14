
-- Business impact of late delivery or stuck orders 
SELECT
	SUM(order_value) ,
    'late_delivery_total' AS marker
FROM orders o
LEFT JOIN shipments s
	ON o.order_id=s.order_id
  
  
  UNION 
  
SELECT
	SUM(order_value) ,
    'total_stuck_order'  AS marker
FROM
		(SELECT 
				t.order_id,
                MAX(stage_timestamp) AS last_date,
                MAX(order_value) AS order_value
		FROM transition_duration t
        LEFT JOIN orders o
			ON t.order_id=o.order_id
		WHERE TRIM(LOWER(order_status))NOT IN ('delivered','cancelled','returned')
        GROUP BY t.order_id)t
        JOIN transition_duration d
			ON t.order_id=d.order_id
            AND t.last_date=d.stage_timestamp
		WHERE DATEDIFF((SELECT MAX(stage_timestamp) FROM order_stage_events),last_date) >14
;





CREATE index order_id_order ON orders(order_id);
CREATE index order_id_shipments ON  shipments(order_id);
CREATE index order_id_events ON order_stage_events(order_id);
CREATE VIEW master_delivery_table AS 

WITH 
late_delivery AS (

					SELECT
						t.*,
                        carrier_id,
                        TRIM(LOWER(priority)) AS priority,
						TRIM(LOWER(delivery_status)) AS delivery_status,
						day_diff AS late_day,
                        ROW_NUMBER()OVER(PARTITION BY order_id ORDER BY hour_taken DESC ) AS rnk
					FROM transition_duration t
					LEFT JOIN order_shipments s 
						ON t.order_id=s.order_id
					-- WHERE delivery_status='late'
					
				)


SELECT

*
FROM late_delivery
WHERE rnk=1
;

-- CALCULATING TRANSITION AND AVG HOUR TAKEN AND TOTAL LATE DELIVERY FOR EVERY CARRIER

SELECT
	carrier_id,
    transition,
    COUNT(*) AS total_transition,
    AVG(hour_taken) AS avg_hour_taken
FROM master_delivery_table
GROUP BY 
	carrier_id,
    transition
ORDER BY carrier_id 



;

SELECT
	carrier_id,
    COUNT(DISTINCT order_id) AS late_order
FROM master_delivery_table
WHERE delivery_status='late'
GROUP BY carrier_id;



-- CALCULATING TRANSITION AND AVG HOUR TAKEN AND TOTAL LATE DELIVERY FOR EVERY CARRIER




SELECT
	warehouse_id,
    transition,
    COUNT(*) AS total_transition,
    AVG(hour_taken) AS avg_hour_taken
FROM master_delivery_table
GROUP BY 
	warehouse_id,
    transition
ORDER BY warehouse_id ;






WITH 
warehouse_calculation AS (

							SELECT
								warehouse_id,
								COUNT(DISTINCT order_id) AS total_order,
								COUNT(CASE WHEN delivery_status='late' THEN order_id END ) AS late_order,
								COUNT(CASE WHEN delivery_status='on_time' THEN order_id END ) AS ontime_order,
								COUNT(CASE WHEN delivery_status='late' THEN order_id END )/((COUNT(CASE WHEN delivery_status='late' THEN order_id END ))+(COUNT(CASE WHEN delivery_status='on_time' THEN order_id END )))*100 AS late_percent
								
							FROM master_delivery_table

							GROUP BY warehouse_id
                            )
,warehouse_avg_delivery_time AS (
								SELECT
									warehouse_id,
                                    AVG(CASE WHEN del_stat='late' THEN total_delivery_hour END ) AS late_del_avg_hour,
                                    AVG(CASE WHEN del_stat='on_time' THEN total_delivery_hour END ) AS ontime_del_avg_hour,
                                    AVG(CASE WHEN del_stat IN ('late','on_time') THEN total_delivery_hour END ) AS total_del_avg_hour
                                FROM
									(
										SELECT
										order_id,
										MAX(warehouse_id) AS warehouse_id,
										MAX(carrier_id) AS carrier_id,
										SUM(hour_taken) AS total_delivery_hour,
										MAX(delivery_status) AS del_stat
										FROM(
												SELECT
													t.*,
													carrier_id,
													TRIM(LOWER(priority)) AS priority,
													TRIM(LOWER(delivery_status)) AS delivery_status,
													day_diff AS late_day,
													ROW_NUMBER()OVER(PARTITION BY order_id ORDER BY hour_taken DESC ) AS rnk
												FROM transition_duration t
												LEFT JOIN order_shipments s 
													ON t.order_id=s.order_id
												)t
										GROUP BY order_id)b
                                    GROUP BY warehouse_id
                                    
                                   
									)	
SELECT 
	a.*,
    total_del_avg_hour,
    ontime_del_avg_hour,
    late_del_avg_hour
    
FROM warehouse_calculation a
JOIN warehouse_avg_delivery_time b
	ON a.warehouse_id=b.warehouse_id
;










WITH 
carrier_calculation AS (

							SELECT
								carrier_id,
								COUNT(DISTINCT order_id) AS total_order,
								COUNT(CASE WHEN delivery_status='late' THEN order_id END ) AS late_order,
								COUNT(CASE WHEN delivery_status='on_time' THEN order_id END ) AS ontime_order,
								COUNT(CASE WHEN delivery_status='late' THEN order_id END )/((COUNT(CASE WHEN delivery_status='late' THEN order_id END ))+(COUNT(CASE WHEN delivery_status='on_time' THEN order_id END )))*100 AS late_percent
								
							FROM master_delivery_table

							GROUP BY  carrier_id
                            )
,carrier_avg_delivery_time AS (
								SELECT
									carrier_id,
                                    AVG(CASE WHEN del_stat='late' THEN total_delivery_hour END ) AS late_del_avg_hour,
                                    AVG(CASE WHEN del_stat='on_time' THEN total_delivery_hour END ) AS ontime_del_avg_hour,
                                    AVG(CASE WHEN del_stat IN ('late','on_time') THEN total_delivery_hour END ) AS total_del_avg_hour
                                FROM
									(
										SELECT
											order_id,
											MAX(warehouse_id) AS warehouse_id,
											MAX(carrier_id) AS carrier_id,
											SUM(hour_taken) AS total_delivery_hour,
											MAX(delivery_status) AS del_stat
										FROM(
												SELECT
													t.*,
													carrier_id,
													TRIM(LOWER(priority)) AS priority,
													TRIM(LOWER(delivery_status)) AS delivery_status,
													day_diff AS late_day,
													ROW_NUMBER()OVER(PARTITION BY order_id ORDER BY hour_taken DESC ) AS rnk
												FROM transition_duration t
												LEFT JOIN order_shipments s 
													ON t.order_id=s.order_id
												)t
										GROUP BY order_id)b
                                    GROUP BY carrier_id
                                    
                                   
									)	
SELECT 
	a.*,
    total_del_avg_hour,
    ontime_del_avg_hour,
    late_del_avg_hour
    
FROM carrier_calculation a
JOIN carrier_avg_delivery_time b
	ON a.carrier_id=b.carrier_id
;

-- Report:

-- Potential Late-Delivery Reduction: Warehouse 6 had the lowest observed late-delivery rate among the eight main warehouses, at 84.30%. Using this rate as a benchmark for completed deliveries at the other warehouses, the estimated number of late deliveries could decrease by approximately 92. This estimate assumes comparable performance across warehouses and does not account for differences in carrier allocation, destinations, or order characteristics. It represents potential improvement, not guaranteed avoided delays.


