/* =====================================================================
   Call Center BI - data quality checks (SQL Server)         [script 4 of 4]
   Run after loading. Every check must return failed_rows = 0 (PASS).
   Good practice to show: "I validated the data before building KPIs".
   ===================================================================== */
USE CallCenterBI;
GO

-- row counts
SELECT 'dim_date' AS tbl, COUNT(*) AS n FROM dim_date UNION ALL
SELECT 'dim_team',         COUNT(*) FROM dim_team UNION ALL
SELECT 'dim_queue',        COUNT(*) FROM dim_queue UNION ALL
SELECT 'dim_agent',        COUNT(*) FROM dim_agent UNION ALL
SELECT 'fact_calls',       COUNT(*) FROM fact_calls UNION ALL
SELECT 'fact_agent_daily', COUNT(*) FROM fact_agent_daily;

-- integrity checks
WITH checks AS (
    SELECT '01 answered call without an agent' AS check_name, COUNT(*) AS failed_rows
    FROM fact_calls WHERE abandoned = 0 AND agent_id IS NULL
    UNION ALL
    SELECT '02 abandoned call with an agent', COUNT(*)
    FROM fact_calls WHERE abandoned = 1 AND agent_id IS NOT NULL
    UNION ALL
    SELECT '03 abandoned call with handle time', COUNT(*)
    FROM fact_calls WHERE abandoned = 1 AND handle_sec > 0
    UNION ALL
    SELECT '04 answered call with zero handle time', COUNT(*)
    FROM fact_calls WHERE abandoned = 0 AND handle_sec <= 0
    UNION ALL
    SELECT '05 CSAT or FCR on an abandoned call', COUNT(*)
    FROM fact_calls WHERE abandoned = 1 AND (csat IS NOT NULL OR resolved_first_call = 1)
    UNION ALL
    SELECT '06 CSAT outside 1-5', COUNT(*)
    FROM fact_calls WHERE csat IS NOT NULL AND csat NOT BETWEEN 1 AND 5
    UNION ALL
    SELECT '07 call handled by an absent / unscheduled agent', COUNT(*)
    FROM fact_calls c
    LEFT JOIN fact_agent_daily w ON w.date_key = c.date_key AND w.agent_id = c.agent_id
    WHERE c.agent_id IS NOT NULL AND (w.agent_id IS NULL OR w.absent = 1)
    UNION ALL
    SELECT '08 call handled outside the agent''s shift hours', COUNT(*)
    FROM fact_calls c
    JOIN dim_agent a ON a.agent_id = c.agent_id
    WHERE c.call_hour < a.shift_start_hour OR c.call_hour >= a.shift_start_hour + 8
    UNION ALL
    SELECT '09 logged minutes above scheduled minutes', COUNT(*)
    FROM fact_agent_daily WHERE logged_min > scheduled_min
    UNION ALL
    SELECT '10 absent agent with logged minutes', COUNT(*)
    FROM fact_agent_daily WHERE absent = 1 AND logged_min > 0
    UNION ALL
    SELECT '11 break + training above logged minutes', COUNT(*)
    FROM fact_agent_daily WHERE break_min + training_min > logged_min
    UNION ALL
    SELECT '12 gaps in the date dimension', COUNT(*)
    FROM (SELECT [date], LAG([date]) OVER (ORDER BY [date]) AS prev_date FROM dim_date) x
    WHERE prev_date IS NOT NULL AND DATEDIFF(DAY, prev_date, [date]) <> 1
    UNION ALL
    SELECT '13 foreign keys not trusted (load skipped validation)', COUNT(*)
    FROM sys.foreign_keys WHERE is_not_trusted = 1
)
SELECT check_name, failed_rows,
       CASE WHEN failed_rows = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM checks
ORDER BY check_name;
