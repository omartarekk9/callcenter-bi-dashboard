/* =====================================================================
   Call Center BI - analysis queries (SQL Server)            [script 3 of 4]
   Run the queries ONE BY ONE (select + F5). Each answers a business question
   and uses a technique worth showing in an interview.
   ===================================================================== */
USE CallCenterBI;
GO

-- A) Top 3 agents per team (by CSAT, then FCR)  ............... window: ROW_NUMBER
SELECT team_name, rank_in_team, agent_name, shift_name, calls_handled,
       ROUND(avg_csat, 2) AS avg_csat, ROUND(fcr_pct, 1) AS fcr_pct, ROUND(aht_sec, 0) AS aht_sec
FROM vw_agent_performance
WHERE rank_in_team <= 3
ORDER BY team_name, rank_in_team;

-- B) Month-over-month change in abandonment rate ............... window: LAG
WITH m AS (
    SELECT [year], [month], month_name,
           SUM(abandoned_calls) * 100.0 / SUM(offered_calls) AS abandonment_pct
    FROM vw_daily_kpis
    GROUP BY [year], [month], month_name
)
SELECT month_name,
       ROUND(abandonment_pct, 2) AS abandonment_pct,
       ROUND(abandonment_pct - LAG(abandonment_pct) OVER (ORDER BY [month]), 2) AS mom_change_pts
FROM m
ORDER BY [month];

-- C) Worst hours: which hours drive abandonment? ............... root cause #1
SELECT TOP 5 call_hour, offered_calls, abandoned_calls,
       ROUND(avg_wait_sec, 0) AS avg_wait_sec, abandonment_rate_pct, service_level_20s_pct
FROM vw_hourly_pattern
ORDER BY abandonment_rate_pct DESC;

-- D) Pareto: how few hours cause most abandoned calls? ......... window: running SUM
SELECT call_hour, abandoned_calls,
       ROUND(100.0 * abandoned_calls / SUM(abandoned_calls) OVER (), 1) AS pct_of_total,
       ROUND(100.0 * SUM(abandoned_calls) OVER (ORDER BY abandoned_calls DESC, call_hour
                                                ROWS UNBOUNDED PRECEDING)
             / SUM(abandoned_calls) OVER (), 1)                          AS cumulative_pct
FROM vw_hourly_pattern
ORDER BY abandoned_calls DESC, call_hour;

-- E) Does workload per agent explain abandonment? .............. root cause #2
--    Bucket every (date, hour) interval by how many calls each agent on the floor had to absorb.
WITH b AS (
    SELECT *,
           CASE WHEN calls_per_agent < 4 THEN '1) under 4 calls per agent'
                WHEN calls_per_agent < 6 THEN '2) 4 to 6'
                WHEN calls_per_agent < 8 THEN '3) 6 to 8'
                ELSE                          '4) 8 or more' END AS load_band
    FROM vw_interval_staffing
    WHERE agents_present > 0
)
SELECT load_band,
       COUNT(*)                                                    AS intervals,
       SUM(offered_calls)                                          AS offered_calls,
       ROUND(100.0 * SUM(abandoned_calls) / SUM(offered_calls), 2) AS abandonment_rate_pct,
       ROUND(100.0 * SUM(answered_20s)    / SUM(offered_calls), 2) AS service_level_20s_pct
FROM b
GROUP BY load_band
ORDER BY load_band;

-- F) Staffing vs demand by hour: who is over/under-staffed? .... capacity planning
SELECT call_hour,
       ROUND(AVG(1.0 * agents_present), 1)                           AS avg_agents_on_floor,
       ROUND(AVG(1.0 * offered_calls), 1)                            AS avg_calls_per_hour,
       ROUND(100.0 * SUM(handle_sec) / NULLIF(SUM(agents_present * 3600.0), 0), 1) AS occupancy_pct,
       ROUND(100.0 * SUM(abandoned_calls) / SUM(offered_calls), 2)   AS abandonment_rate_pct
FROM vw_interval_staffing
WHERE is_weekend = 0
GROUP BY call_hour
ORDER BY call_hour;

-- G) Unusual days (incidents / spikes) ......................... z-score per month
--    Compared with the same month and day type, so seasonality is not flagged.
WITH z AS (
    SELECT [date], day_name, is_weekend, offered_calls, abandonment_rate_pct,
           (offered_calls - AVG(1.0 * offered_calls) OVER (PARTITION BY [month], is_weekend))
           / NULLIF(STDEV(offered_calls) OVER (PARTITION BY [month], is_weekend), 0) AS z_score
    FROM vw_daily_kpis
)
SELECT [date], day_name, offered_calls, abandonment_rate_pct, ROUND(z_score, 2) AS z_score
FROM z
WHERE z_score > 2.5
ORDER BY z_score DESC;

-- H) Queues with below-average FCR .............................. subquery
SELECT q.queue_name, ROUND(100.0 * AVG(1.0 * c.resolved_first_call), 2) AS fcr_pct
FROM fact_calls c
JOIN dim_queue q ON q.queue_id = c.queue_id
WHERE c.abandoned = 0
GROUP BY q.queue_name
HAVING AVG(1.0 * c.resolved_first_call) <
       (SELECT AVG(1.0 * resolved_first_call) FROM fact_calls WHERE abandoned = 0)
ORDER BY fcr_pct;

-- I) Coaching list: agents below their team average on BOTH FCR and CSAT
WITH x AS (
    SELECT *,
           AVG(fcr_pct)  OVER (PARTITION BY team_name) AS team_fcr,
           AVG(avg_csat) OVER (PARTITION BY team_name) AS team_csat
    FROM vw_agent_performance
)
SELECT team_name, agent_name, shift_name,
       ROUND(fcr_pct, 1) AS fcr_pct,   ROUND(team_fcr, 1)  AS team_fcr,
       ROUND(avg_csat, 2) AS avg_csat, ROUND(team_csat, 2) AS team_csat,
       ROUND(aht_sec, 0) AS aht_sec
FROM x
WHERE fcr_pct < team_fcr AND avg_csat < team_csat
ORDER BY team_name, avg_csat;

-- J) Shift comparison: adherence, absence and occupancy ......... WFM view
SELECT shift_name,
       COUNT(DISTINCT agent_id)                                                        AS agents,
       ROUND(100.0 * SUM(CAST(logged_min AS BIGINT)) / SUM(CAST(scheduled_min AS BIGINT)), 2) AS adherence_pct,
       ROUND(100.0 * SUM(CAST(absent AS INT)) / COUNT(*), 2)                           AS absence_rate_pct,
       ROUND(100.0 * SUM(CAST(handle_sec AS BIGINT)) / NULLIF(SUM(logged_min * 60.0), 0), 2) AS occupancy_pct
FROM vw_agent_day
GROUP BY shift_name
ORDER BY shift_name;

-- K) Day-of-week profile ........................................ Sun..Sat order
SELECT day_name, dow_num,
       ROUND(AVG(1.0 * offered_calls), 0) AS avg_daily_calls,
       ROUND(SUM(abandoned_calls) * 100.0 / SUM(offered_calls), 2) AS abandonment_rate_pct,
       ROUND(AVG(service_level_20s_pct), 2) AS avg_service_level_pct
FROM vw_daily_kpis
GROUP BY day_name, dow_num
ORDER BY dow_num;

-- L) Running total of calls per month ............................ window: SUM OVER
SELECT [month], month_name, SUM(offered_calls) AS calls,
       SUM(SUM(offered_calls)) OVER (ORDER BY [month]) AS running_total
FROM vw_daily_kpis
GROUP BY [month], month_name
ORDER BY [month];
