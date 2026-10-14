
--  Stage duration (core finding)


-- calculating stage transition avg time 

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
						*,
                        LAG(stage_timestamp) OVER (PARTITION BY order_id ORDER BY stage_sequence)AS prev_date,
                        LAG(trim(lower(stage))) OVER (PARTITION BY order_id ORDER BY stage_sequence) AS prev_stage,
                        
                        COALESCE(TIMESTAMPDIFF(HOUR,LAG(stage_timestamp) OVER (PARTITION BY order_id ORDER BY stage_sequence),stage_timestamp),0) AS hour_taken,
                        CONCAT(LAG(trim(lower(stage))) OVER (PARTITION BY order_id ORDER BY stage_sequence),' -to- ', trim(lower(stage))) AS transition
                    FROM mapping
                    )
,avg_hour_taken AS
					(
                    SELECT
					transition,
					AVG(hour_taken) AS avg_hour_taken
					FROM calculating
					GROUP BY transition
					HAVING AVG(hour_taken) >0
                    )
                    
,median AS (  
    

						SELECT
							transition,
							AVG(hour_taken) AS median_hours
						FROM (
								SELECT
								transition,
								hour_taken,
								ROW_NUMBER() OVER (
									PARTITION BY transition
									ORDER BY hour_taken
								) AS rn,
								COUNT(*) OVER (
									PARTITION BY transition
								) AS total_rows
							FROM calculating
								)t
						WHERE rn IN (
							FLOOR((total_rows + 1) / 2),
							FLOOR((total_rows + 2) / 2)
						)
						GROUP BY transition
						HAVING AVG(hour_taken)>0
					)
,90th_percentile AS (

					SELECT
						transition,
						MAX(
							CASE
								WHEN rn = CEIL(0.90 * total_rows)
								THEN hour_taken
							END
							) AS p90_hours
						FROM (	
								SELECT
									transition,
										hour_taken,
										ROW_NUMBER() OVER (
											PARTITION BY transition
											ORDER BY hour_taken
										) AS rn,
										COUNT(*) OVER (
											PARTITION BY transition
										) AS total_rows
									FROM calculating
                                )t
                        GROUP BY transition
                        HAVING MAX(
							CASE
								WHEN rn = CEIL(0.90 * total_rows)
								THEN hour_taken
							END
							) >0
					  )
SELECT 
	p.transition,
    avg_hour_taken,
    median_hours,
    p90_hours
FROM median m
LEFT JOIN 90th_percentile p
	ON m.transition=p.transition
LEFT JOIN avg_hour_taken a
	ON m.transition=a.transition
           
