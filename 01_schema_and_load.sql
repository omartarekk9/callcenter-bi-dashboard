/* =====================================================================
   Call Center BI - schema + load (SQL Server / SSMS)        [script 1 of 4]
   ---------------------------------------------------------------------
   1) Run generate_data.py            -> creates the ./data folder with 6 CSVs
   2) Copy that folder to a path SQL Server can read (e.g. C:\callcenter-bi\data\)
      NOTE: do NOT leave it in Desktop/Downloads/Documents - the SQL Server
      service account has no access there (error: "Access is denied", code 5).
   3) Change @path below, then run this script in SSMS.
   Re-runnable: it drops and recreates every table.
   ===================================================================== */
SET NOCOUNT ON;
IF DB_ID('CallCenterBI') IS NULL CREATE DATABASE CallCenterBI;
GO
USE CallCenterBI;
GO

-- drop in dependency order so the script is re-runnable
DROP TABLE IF EXISTS fact_agent_daily, fact_calls, dim_agent, dim_team, dim_queue, dim_date;
GO

-- ---------------------------- dimensions ----------------------------
CREATE TABLE dim_date (
    date_key   INT         NOT NULL PRIMARY KEY,          -- yyyymmdd
    [date]     DATE        NOT NULL UNIQUE,
    [year]     SMALLINT    NOT NULL,
    [quarter]  TINYINT     NOT NULL,
    [month]    TINYINT     NOT NULL,
    month_name VARCHAR(3)  NOT NULL,
    year_month CHAR(7)     NOT NULL,                      -- 2025-01 (sorts correctly)
    [week]     TINYINT     NOT NULL,
    day_name   VARCHAR(3)  NOT NULL,
    dow_num    TINYINT     NOT NULL,                      -- Sun=1 ... Sat=7 (sort key for day_name)
    is_weekend BIT         NOT NULL                       -- Fri/Sat
);
CREATE TABLE dim_team  (team_id INT PRIMARY KEY, team_name VARCHAR(20) NOT NULL);
CREATE TABLE dim_queue (queue_id INT PRIMARY KEY, queue_name VARCHAR(30) NOT NULL, avg_handle_sec INT);
CREATE TABLE dim_agent (
    agent_id         INT         NOT NULL PRIMARY KEY,
    agent_name       VARCHAR(30) NOT NULL,
    team_id          INT         NOT NULL REFERENCES dim_team(team_id),
    hire_date        DATE,
    shift_name       VARCHAR(10) NOT NULL,                -- Early / Day / Mid / Late
    shift_start_hour TINYINT     NOT NULL                 -- every shift is 8 hours
);

-- ------------------------------ facts -------------------------------
CREATE TABLE fact_calls (
    call_id             INT     NOT NULL PRIMARY KEY,
    date_key            INT     NOT NULL REFERENCES dim_date(date_key),
    call_hour           TINYINT NOT NULL,
    call_minute         TINYINT NOT NULL,
    agent_id            INT     NULL REFERENCES dim_agent(agent_id),   -- NULL = abandoned
    queue_id            INT     NOT NULL REFERENCES dim_queue(queue_id),
    wait_sec            INT     NOT NULL,
    handle_sec          INT     NOT NULL,                              -- 0 when abandoned
    abandoned           BIT     NOT NULL,
    resolved_first_call BIT     NOT NULL,
    csat                TINYINT NULL,                                  -- only ~35% of answered calls respond
    CONSTRAINT ck_calls_agent_vs_abandon
        CHECK ((abandoned = 1 AND agent_id IS NULL) OR (abandoned = 0 AND agent_id IS NOT NULL)),
    CONSTRAINT ck_calls_csat CHECK (csat IS NULL OR csat BETWEEN 1 AND 5)
);
CREATE TABLE fact_agent_daily (
    date_key      INT NOT NULL REFERENCES dim_date(date_key),
    agent_id      INT NOT NULL REFERENCES dim_agent(agent_id),
    scheduled_min INT NOT NULL,
    logged_min    INT NOT NULL,
    break_min     INT NOT NULL,
    training_min  INT NOT NULL,
    absent        BIT NOT NULL,
    PRIMARY KEY (date_key, agent_id)                     -- grain: one row per scheduled agent per day
);
GO

-- ---------- load (order matters because of foreign keys) ----------
DECLARE @path NVARCHAR(400) = N'C:\callcenter-bi\data\';   -- <== CHANGE ME (keep trailing \)
DECLARE @sql  NVARCHAR(MAX);
DECLARE @t TABLE (n INT IDENTITY, tbl SYSNAME);
INSERT @t(tbl) VALUES ('dim_date'),('dim_team'),('dim_queue'),('dim_agent'),('fact_calls'),('fact_agent_daily');

DECLARE @i INT = 1, @tbl SYSNAME;
WHILE @i <= (SELECT COUNT(*) FROM @t)
BEGIN
    SELECT @tbl = tbl FROM @t WHERE n = @i;
    SET @sql = N'BULK INSERT ' + @tbl + N' FROM ''' + @path + @tbl + N'.csv'' WITH (
        FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'',
        CODEPAGE = ''65001'', KEEPNULLS, CHECK_CONSTRAINTS, TABLOCK);';
    BEGIN TRY
        EXEC sp_executesql @sql;
        PRINT 'Loaded ' + @tbl;
    END TRY
    BEGIN CATCH
        PRINT 'FAILED loading ' + @tbl + ' from ' + @path + ' -> ' + ERROR_MESSAGE();
        THROW;
    END CATCH
    SET @i += 1;
END
GO

-- ---------- indexes (added AFTER the bulk load = faster load) ----------
-- Covering indexes for the KPI views: date / hour / agent / queue slicing.
CREATE INDEX ix_calls_date  ON fact_calls (date_key)
    INCLUDE (call_hour, agent_id, queue_id, wait_sec, handle_sec, abandoned, resolved_first_call, csat);
CREATE INDEX ix_calls_hour  ON fact_calls (call_hour)
    INCLUDE (date_key, wait_sec, handle_sec, abandoned);
CREATE INDEX ix_calls_agent ON fact_calls (agent_id, date_key)
    INCLUDE (handle_sec, abandoned, resolved_first_call, csat);
CREATE INDEX ix_calls_queue ON fact_calls (queue_id)
    INCLUDE (wait_sec, handle_sec, abandoned, resolved_first_call, csat);
GO

-- ---------- quick sanity check ----------
SELECT 'dim_date' AS tbl, COUNT(*) AS n FROM dim_date UNION ALL
SELECT 'dim_agent',        COUNT(*) FROM dim_agent UNION ALL
SELECT 'fact_calls',       COUNT(*) FROM fact_calls UNION ALL
SELECT 'fact_agent_daily', COUNT(*) FROM fact_agent_daily;
