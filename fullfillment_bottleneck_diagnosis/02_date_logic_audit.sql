-- PHASE 3: Timeline logic


-- finding unsquence stage date 

WITH
sequence AS (
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
,finding AS (
			SELECT
				*,
                LAG(stage_timestamp) OVER (PARTITION BY order_id ORDER BY stage_sequence) AS prev_event
            FROM sequence
            )
,order_unsequence AS (
					SELECT 
						*,
                        CASE
							WHEN stage_timestamp<prev_event THEN 'unsequence'
                            ELSE NULL
                        END AS marker
                    FROM finding 
                    
						)

SELECT
	*
FROM order_unsequence
WHERE order_id IN(
					SELECT
						order_id
					FROM order_unsequence
                    WHERE marker='unsequence'
				 )

;


-- Events happened before order placed 


SELECT
COUNT(*) AS events_happened_before_order_placed
FROM
(SELECT
e.order_id,
e.stage,
e.stage_timestamp,
o.order_placed_at
FROM order_stage_events e
JOIN orders o
	ON e.order_id=o.order_id
WHERE e.stage_timestamp<o.order_placed_at) t

;


-- findding duplicates events 


WITH duplicates AS (

					SELECT 
						* ,
						ROW_NUMBER() OVER (PARTITION BY order_id,stage) AS rn,
						LAG(stage_timestamp) OVER (PARTITION BY order_id) AS previous_time
					FROM order_stage_events 
                    )
 
SELECT
	-- COUNT(*	) AS duplicates_event_within_60_minute
	*
FROM duplicates
WHERE rn>1
AND TIMESTAMPDIFF(MINUTE,previous_time,stage_timestamp)<=60;


-- order event with stage missing 


WITH
sequence AS (
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
,finding AS (
			SELECT
				*,
                LAG(stage_sequence) OVER (PARTITION BY order_id ORDER BY stage_sequence) AS prev_sequence
            FROM sequence
            )
,stage_missing AS (
					SELECT 
						*,
                        CASE
							WHEN stage_sequence - NULLIF(prev_sequence,0) >1 THEN 'stage missing'
                            ELSE 'ok'
                        END AS marker
                    FROM finding 
                    
						)

SELECT
	-- count(DISTINCT order_id) AS stage_missing_order_count
	*
FROM stage_missing
WHERE marker='stage missing'

;

-- finding events handed to carrier time mismatch with shipment handed over time and delivery time mimatch orders 

WITH 
mapping AS (
			SELECT 
				e.order_id,
				stage,
				stage_timestamp,
				s.handed_over_at,
				s.delivered_at,
				CASE
					WHEN trim(lower(stage))='handed_to_carrier' AND TIMESTAMPDIFF(MINUTE,stage_timestamp,handed_over_at )<=30 THEN 'handed over time match'
					WHEN trim(lower(stage))='handed_to_carrier' AND TIMESTAMPDIFF(MINUTE,stage_timestamp,handed_over_at )>30  THEN 'handed over time mismatch'
					WHEN trim(lower(stage))='delivered' AND stage_timestamp=delivered_at THEN 'delivery time match'
					WHEN trim(lower(stage))='delivered' AND stage_timestamp!=delivered_at THEN 'delivery time mismatch'
				END AS match_marker
			FROM order_stage_events e
			JOIN shipments s
				ON e.order_id=s.order_id
				AND TRIM(LOWER(e.stage)) IN('handed_to_carrier','delivered')
			)
SELECT 
	match_marker,
    COUNT(distinct order_id) AS mismatch_orders
	
FROM mapping
WHERE match_marker IN ('delivery time mismatch','handed over time mismatch')
GROUP BY match_marker ;




-- delivered before handed over 

SELECT
	count(*) Delivered_before_handed_over
FROM shipments
WHERE delivered_at<handed_over_at
                        