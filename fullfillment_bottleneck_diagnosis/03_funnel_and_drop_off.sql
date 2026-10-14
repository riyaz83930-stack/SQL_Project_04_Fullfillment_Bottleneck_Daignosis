--  Funnel aur drop-off


-- finding stage drop off

WITH 
mapping AS (
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

SELECT
	stage_sequence,
	TRIM(LOWER(stage)) AS stage,
    COUNT(DISTINCT order_id) AS order_at_this_stage,
	COUNT(DISTINCT order_id)/(SELECT COUNT(DISTINCT order_id) FROM order_stage_events) *100 AS  pct
				
FROM mapping
GROUP BY stage_sequence,
		 TRIM(LOWER(stage));
         
         
-- finding stuck order not deliver at  


WITH 
mapping AS (
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
					order_id,
                    MAX(stage_timestamp) AS last_event_time,
                    MAX(stage_sequence) AS stage,
                    (SELECT MAX(stage_timestamp) FROM order_stage_events) AS snapshot_time
				FROM mapping 
                
				GROUP BY order_id
				)
,filtering AS (
				SELECT
					*,
                    CASE stage
						WHEN  1 THEN 'placed' 
						WHEN  2 THEN 'payment_verified' 
						WHEN  3 THEN 'picked' 
						WHEN 4 THEN 'packed' 
						WHEN  5 THEN 'handed_to_carrier' 
						WHEN  6 THEN 'in_transit' 
						ELSE NULL
					END AS stage_name,
                    DATEDIFF(snapshot_time,last_event_time) AS stuck_for_days,
                    CASE 
						 WHEN DATEDIFF(snapshot_time,last_event_time) THEN 'YES'
                         ELSE 'no'
                    END AS 14_days
                FROM calculating 
                WHERE stage<7
				) 
SELECT
stage_name,
COUNT(DISTINCT order_id) AS stuck_order_at_stage
FROM filtering
WHERE 14_days='yes'
GROUP BY stage_name