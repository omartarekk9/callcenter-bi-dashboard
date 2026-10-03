/* =====================================================================
   Call Center BI - KPI views (SQL Server)                   [script 2 of 4]
   KPI definitions (also listed in the README):
     Abandonment Rate = abandoned calls / offered calls
     AHT              = avg handle time of ANSWERED calls (sec)
     Service Level    = calls answered within 20s / offered calls
     FCR              = first-call-resolved / answered calls
     CSAT             = avg score of survey responses (only ~35% respond)
     Adherence        = logged minutes / scheduled minutes
     Shrinkage        = (break + training + absent-scheduled) / scheduled
     Occupancy        = handle time / logged time
   Views are layered:  fact tables -> vw_agent_day / vw_interval_staffing
                       -> monthly, agent and hourly views.
   ===================================================================== */
USE CallCenterBI;
GO

-- 1) Daily KPIs ------------------------------------------------------
CREATE OR ALTER VIEW vw_daily_kpis AS
SELECT  d.date_key, d.[date], d.[year], d.[month], d.month_name, d.year_month,
        d.day_name, d.dow_num, d.is_weekend,
        COUNT(*)                                                    AS offered_calls,
        SUM(1 - CAST(c.abandoned AS INT))                           AS answered_calls,
        SUM(CAST(c.abandoned AS INT))                               AS abandoned_calls,
        ROUND(100.0 * SUM(CAST(c.abandoned AS INT)) / COUNT(*), 2)  AS abandonment_rate_pct,
        AVG(1.0 * c.wait_sec)                                       AS avg_wait_sec,
        AVG(CASE WHEN c.abandoned = 0 THEN 1.0 * c.handle_sec END)  AS aht_sec,
        ROUND(100.0 * SUM(CASE WHEN c.abandoned = 0 AND c.wait_sec <= 20 THEN 1 ELSE 0 END)
              / COUNT(*), 2)                                        AS service_level_20s_pct,
        ROUND(100.0 * SUM(CASE WHEN c.abandoned = 0 THEN CAST(c.resolved_first_call AS INT) ELSE 0 END)
              / NULLIF(SUM(1 - CAST(c.abandoned AS INT)), 0), 2)    AS fcr_pct,
        COUNT(c.csat)                                               AS csat_responses,
        ROUND(100.0 * COUNT(c.csat)
              / NULLIF(SUM(1 - CAST(c.abandoned AS INT)), 0), 2)    AS csat_response_rate_pct,
        AVG(1.0 * c.csat)                                           AS avg_csat
FROM fact_calls c
JOIN dim_date d ON d.date_key = c.date_key
GROUP BY d.date_key, d.[date], d.[year], d.[month], d.month_name, d.year_month,
         d.day_name, d.dow_num, d.is_weekend;
GO

-- 2) Hourly pattern (find peak hours) --------------------------------
CREATE OR ALTER VIEW vw_hourly_pattern AS
SELECT  call_hour,
        COUNT(*)                                                   AS offered_calls,
        SUM(1 - CAST(abandoned AS INT))                            AS answered_calls,
        SUM(CAST(abandoned AS INT))                                AS abandoned_calls,
        AVG(1.0 * wait_sec)                                        AS avg_wait_sec,
        ROUND(100.0 * SUM(CAST(abandoned AS INT)) / COUNT(*), 2)   AS abandonment_rate_pct,
        ROUND(100.0 * SUM(CASE WHEN abandoned = 0 AND wait_sec <= 20 THEN 1 ELSE 0 END)
              / COUNT(*), 2)                                       AS service_level_20s_pct
FROM fact_calls
GROUP BY call_hour;
GO

-- 3) Agent-day grain: schedule + calls handled (base for WFM KPIs) ----
--    Calls are pre-aggregated per agent-day BEFORE joining, so the WFM
--    minutes are never multiplied by the number of calls (no fan-out).
CREATE OR ALTER VIEW vw_agent_day AS
WITH calls_agg AS (
    SELECT date_key, agent_id,
           COUNT(*)        AS calls_handled,
           SUM(handle_sec) AS handle_sec
    FROM fact_calls
    WHERE agent_id IS NOT NULL
    GROUP BY date_key, agent_id
)
SELECT  w.date_key, d.[date], d.[year], d.[month], d.month_name, d.year_month, d.day_name,
        w.agent_id, a.agent_name, a.team_id, t.team_name, a.shift_name,
        w.scheduled_min, w.logged_min, w.break_min, w.training_min, w.absent,
        COALESCE(c.calls_handled, 0) AS calls_handled,
        COALESCE(c.handle_sec, 0)    AS handle_sec
FROM fact_agent_daily w
JOIN dim_date  d ON d.date_key = w.date_key
JOIN dim_agent a ON a.agent_id = w.agent_id
JOIN dim_team  t ON t.team_id  = a.team_id
LEFT JOIN calls_agg c ON c.date_key = w.date_key AND c.agent_id = w.agent_id;
GO

-- 4) WFM monthly: adherence + shrinkage + occupancy -------------------
CREATE OR ALTER VIEW vw_wfm_monthly AS
SELECT  [year], [month], month_name, year_month,
        SUM(CAST(scheduled_min AS BIGINT))                                       AS scheduled_min,
        SUM(CAST(logged_min AS BIGINT))                                          AS logged_min,
        ROUND(100.0 * SUM(CAST(logged_min AS BIGINT))
              / SUM(CAST(scheduled_min AS BIGINT)), 2)                           AS adherence_pct,
        ROUND(100.0 * SUM(CAST(break_min AS BIGINT) + training_min
                          + CASE WHEN absent = 1 THEN scheduled_min ELSE 0 END)
              / SUM(CAST(scheduled_min AS BIGINT)), 2)                           AS shrinkage_pct,
        ROUND(100.0 * SUM(CAST(handle_sec AS BIGINT))
              / NULLIF(SUM(logged_min * 60.0), 0), 2)                            AS occupancy_pct
FROM vw_agent_day
GROUP BY [year], [month], month_name, year_month;
GO

-- 5) Agent performance + rank inside team (window functions) ----------
CREATE OR ALTER VIEW vw_agent_performance AS
WITH call_stats AS (
    SELECT  c.agent_id,
            COUNT(*)                                 AS calls_handled,
            AVG(1.0 * c.handle_sec)                  AS aht_sec,
            100.0 * AVG(1.0 * c.resolved_first_call) AS fcr_pct,
            AVG(1.0 * c.csat)                        AS avg_csat,
            COUNT(c.csat)                            AS csat_responses
    FROM fact_calls c
    WHERE c.abandoned = 0
    GROUP BY c.agent_id
), wfm_stats AS (
    SELECT  agent_id,
            100.0 * SUM(CAST(logged_min AS BIGINT)) / NULLIF(SUM(CAST(scheduled_min AS BIGINT)), 0) AS adherence_pct,
            100.0 * SUM(CAST(handle_sec AS BIGINT)) / NULLIF(SUM(logged_min * 60.0), 0)             AS occupancy_pct,
            100.0 * SUM(CAST(absent AS INT)) / COUNT(*)                                             AS absence_rate_pct
    FROM vw_agent_day
    GROUP BY agent_id
)
SELECT  a.agent_id, a.agent_name, t.team_name, a.shift_name, a.hire_date,
        s.calls_handled, s.aht_sec, s.fcr_pct, s.avg_csat, s.csat_responses,
        w.adherence_pct, w.occupancy_pct, w.absence_rate_pct,
        ROW_NUMBER() OVER (PARTITION BY t.team_name ORDER BY s.avg_csat DESC, s.fcr_pct DESC) AS rank_in_team,
        RANK()       OVER (ORDER BY s.avg_csat DESC)                                          AS rank_overall
FROM dim_agent a
JOIN dim_team   t ON t.team_id  = a.team_id
JOIN call_stats s ON s.agent_id = a.agent_id
JOIN wfm_stats  w ON w.agent_id = a.agent_id;
GO

-- 6) Queue performance ------------------------------------------------
CREATE OR ALTER VIEW vw_queue_performance AS
SELECT  q.queue_id, q.queue_name,
        COUNT(*)                                                                AS offered_calls,
        ROUND(100.0 * SUM(CAST(c.abandoned AS INT)) / COUNT(*), 2)              AS abandonment_rate_pct,
        AVG(1.0 * c.wait_sec)                                                   AS avg_wait_sec,
        AVG(CASE WHEN c.abandoned = 0 THEN 1.0 * c.handle_sec END)              AS aht_sec,
        ROUND(100.0 * SUM(CASE WHEN c.abandoned = 0 THEN CAST(c.resolved_first_call AS INT) ELSE 0 END)
              / NULLIF(SUM(1 - CAST(c.abandoned AS INT)), 0), 2)                AS fcr_pct,
        ROUND(100.0 * SUM(CASE WHEN c.abandoned = 0 AND c.wait_sec <= 20 THEN 1 ELSE 0 END)
              / COUNT(*), 2)                                                    AS service_level_20s_pct,
        AVG(1.0 * c.csat)                                                       AS avg_csat
FROM fact_calls c
JOIN dim_queue q ON q.queue_id = c.queue_id
GROUP BY q.queue_id, q.queue_name;
GO

-- 7) Interval staffing: agents on the floor vs calls, per date + hour --
--    An agent covers every hour of his 8-hour shift unless absent that day.
--    Handle time is attributed to the hour the call ARRIVED (simplification).
CREATE OR ALTER VIEW vw_interval_staffing AS
WITH hrs AS (
    SELECT 9 AS call_hour UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL SELECT 12
    UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL SELECT 15 UNION ALL SELECT 16
    UNION ALL SELECT 17 UNION ALL SELECT 18 UNION ALL SELECT 19 UNION ALL SELECT 20
), staff AS (
    SELECT w.date_key, h.call_hour, COUNT(*) AS agents_present
    FROM fact_agent_daily w
    JOIN dim_agent a ON a.agent_id = w.agent_id
    JOIN hrs h ON h.call_hour >= a.shift_start_hour AND h.call_hour < a.shift_start_hour + 8
    WHERE w.absent = 0
    GROUP BY w.date_key, h.call_hour
), calls AS (
    SELECT date_key, call_hour,
           COUNT(*)                                                         AS offered_calls,
           SUM(CAST(abandoned AS INT))                                      AS abandoned_calls,
           SUM(CAST(handle_sec AS BIGINT))                                  AS handle_sec,
           SUM(CASE WHEN abandoned = 0 AND wait_sec <= 20 THEN 1 ELSE 0 END) AS answered_20s
    FROM fact_calls
    GROUP BY date_key, call_hour
)
SELECT  d.[date], d.year_month, d.day_name, d.dow_num, d.is_weekend, c.call_hour,
        COALESCE(s.agents_present, 0)                                        AS agents_present,
        c.offered_calls, c.abandoned_calls, c.answered_20s, c.handle_sec,
        1.0 * c.offered_calls / NULLIF(s.agents_present, 0)                  AS calls_per_agent,
        100.0 * c.handle_sec / NULLIF(s.agents_present * 3600.0, 0)          AS interval_occupancy_pct
FROM calls c
JOIN dim_date d ON d.date_key = c.date_key
LEFT JOIN staff s ON s.date_key = c.date_key AND s.call_hour = c.call_hour;
GO
