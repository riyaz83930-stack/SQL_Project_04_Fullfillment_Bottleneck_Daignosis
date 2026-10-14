-- Kahan concentrate hai (segmentation)



-- segmentation of slowest transition

-- CREATE VIEW transition_duration AS 

WITH 
mapping AS      (
					SELECT
						order_id,
						stage,
						stage_timestamp,
						CASE LOWER(TRIM(stage))
							WHEN 'placed' THEN 1
							WHEN 'payment_verified' THEN 2
							WHEN 'picked' THEN 3
							WHEN 'packed' THEN 4
							WHEN 'handed_to_carrier' THEN 5
							WHEN 'in_transit' THEN 6
							WHEN 'delivered' THEN 7
							ELSE NULL
						END AS stage_sequence
						
					FROM order_stage_events
					ORDER BY order_id,stage_sequence
                    )
,calculating AS (
					SELECT
						m.*,
                        LAG(stage_timestamp) OVER (PARTITION BY m.order_id ORDER BY stage_sequence)AS prev_date,
                        LAG(trim(lower(stage))) OVER (PARTITION BY m.order_id ORDER BY stage_sequence) AS prev_stage,
                        
                        COALESCE(TIMESTAMPDIFF(HOUR,LAG(stage_timestamp) OVER (PARTITION BY m.order_id ORDER BY stage_sequence),stage_timestamp),0) AS hour_taken,
                        CONCAT(LAG(trim(lower(stage))) OVER (PARTITION BY m.order_id ORDER BY stage_sequence),' -to- ', trim(lower(stage))) AS transition,
                        DATE_FORMAT(stage_timestamp,'%Y-%b') AS month_year,
                        o.warehouse_id
                    FROM mapping m
                    LEFT JOIN orders o
						ON m.order_id=o.order_id
                    )
SELECT
*
FROM calculating
;
-- avg hour taken by month year
SELECT
	month_year,
    transition,
    AVG(hour_taken) AS avg_hour_taken
FROM transition_duration
GROUP BY 
		month_year,
        transition
HAVING AVG(hour_taken) >0
ORDER BY month_year,transition
                           ;
                           
-- avg hour taken by warehouse                           
SELECT
	warehouse_id,
	transition,
	AVG(hour_taken) AS avg_hour_taken_by_warehouse
FROM transition_duration
GROUP BY 
	warehouse_id,
    transition
HAVING AVG(hour_taken) >0
ORDER BY warehouse_id,transition
                          ;
                          
                          
-- avg hour taken by warehouse with carrier where carrier id not null					
SELECT
	warehouse_id,
    s.carrier_id,
    transition,
    AVG(hour_taken) AS avg_hour_taken_warehouse_and_carrier
FROM transition_duration c
LEFT JOIN shipments s
	ON c.order_id=s.order_id
WHERE carrier_id IS NOT NULL    
GROUP BY 
	warehouse_id,
    s.carrier_id,
    transition
HAVING AVG(hour_taken) >0
ORDER BY warehouse_id,transition
 ;                                               
					
                    
  -- calculating avg hour and transition count taken by warehouse with carrier where transition is   'handed_to_carrier -to- in_transit'                 
SELECT
	o.warehouse_id,
    s.carrier_id,
    d.transition,
    COUNT(*) AS transition_count,
    ROUND(AVG(d.hour_taken), 2) AS avg_hours
FROM transition_duration  d
JOIN orders o
	ON d.order_id = o.order_id
JOIN shipments s
	ON s.order_id = o.order_id
WHERE d.transition = 'handed_to_carrier -to- in_transit'
GROUP BY
		o.warehouse_id,
        s.carrier_id,
        d.transition
ORDER BY avg_hours DESC;

-- avg hour taken by priority for 'handed_to_carrier -to- in_transit' transition
SELECT
    TRIM(LOWER(o.priority)) AS priority,
    COUNT(*) AS transition_count,
    ROUND(AVG(d.hour_taken), 2) AS avg_hours
FROM transition_duration d
JOIN orders o
    ON d.order_id = o.order_id
WHERE d.transition = 'handed_to_carrier -to- in_transit'
GROUP BY TRIM(LOWER(o.priority))
ORDER BY avg_hours DESC;


-- avg hour taken by weekday  for 'handed_to_carrier -to- in_transit' transition
SELECT
    DAYNAME(o.order_placed_at) AS placed_weekday,
    COUNT(*) AS transition_count,
    ROUND(AVG(d.hour_taken), 2) AS avg_hours,
    ROUND(AVG(d.hour_taken) / 24, 2) AS avg_days
FROM transition_duration d
JOIN orders o
    ON d.order_id = o.order_id
WHERE d.transition = 'handed_to_carrier -to- in_transit'
GROUP BY DAYOFWEEK(o.order_placed_at),
         DAYNAME(o.order_placed_at)
ORDER BY DAYOFWEEK(o.order_placed_at);
					
