# Power BI model + DAX measures

## 1. Load the data (Get Data -> SQL Server, **Import** mode)
Import these objects from the `CallCenterBI` database:

| Type | Objects |
|------|---------|
| Dimensions | `dim_date`, `dim_team`, `dim_agent`, `dim_queue` |
| Facts | `fact_calls` (~370k rows), `fact_agent_daily` |
| Helper views | `vw_interval_staffing` (hour-level staffing vs demand) and `vw_agent_performance` (agent scorecard) |

> **BIT columns:** Power BI imports SQL `BIT` as True/False. The DAX below uses `TRUE()` / `FALSE()`
> for that reason. (Alternative: change the type to Whole Number in Power Query.)

## 2. Relationships (all one-to-many, single direction, from dimension to fact)
```
dim_date[date_key]    -> fact_calls[date_key]        dim_date[date_key]  -> fact_agent_daily[date_key]
dim_agent[agent_id]   -> fact_calls[agent_id]        dim_agent[agent_id] -> fact_agent_daily[agent_id]
dim_queue[queue_id]   -> fact_calls[queue_id]        dim_team[team_id]   -> dim_agent[team_id]
```
* Mark `dim_date` as the **Date table** (column `date`).
* Sort `month_name` by `month`, and `day_name` by `dow_num` (Sun..Sat).
* Abandoned calls have a blank `agent_id` - that is correct, they were never answered.
* `vw_interval_staffing` and `vw_agent_performance` have no relationships; they are used on their own. Slicers for them must come from their own columns (for example `vw_agent_performance[team_name]`), not from the dimension tables.

## 3. Measures
Create a blank table called `_Measures` and keep every measure there.

### Call volume and service
```DAX
Offered Calls   = COUNTROWS ( fact_calls )
Answered Calls  = CALCULATE ( COUNTROWS ( fact_calls ), fact_calls[abandoned] = FALSE () )
Abandoned Calls = CALCULATE ( COUNTROWS ( fact_calls ), fact_calls[abandoned] = TRUE () )

Abandonment Rate = DIVIDE ( [Abandoned Calls], [Offered Calls] )

Avg Wait (sec) = AVERAGE ( fact_calls[wait_sec] )

AHT (sec) =
CALCULATE ( AVERAGE ( fact_calls[handle_sec] ), fact_calls[abandoned] = FALSE () )

Service Level 20s =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_calls ),
                fact_calls[abandoned] = FALSE (),
                fact_calls[wait_sec] <= 20 ),
    [Offered Calls]
)

FCR % =
DIVIDE (
    CALCULATE ( COUNTROWS ( fact_calls ), fact_calls[resolved_first_call] = TRUE () ),
    [Answered Calls]
)
```

### Customer satisfaction
```DAX
CSAT              = AVERAGE ( fact_calls[csat] )                     -- blanks are ignored
CSAT Responses    = COUNT ( fact_calls[csat] )
CSAT Response Rate = DIVIDE ( [CSAT Responses], [Answered Calls] )
```

### Workforce (WFM)
```DAX
Scheduled Min = SUM ( fact_agent_daily[scheduled_min] )
Logged Min    = SUM ( fact_agent_daily[logged_min] )

Adherence % = DIVIDE ( [Logged Min], [Scheduled Min] )

Shrinkage % =
DIVIDE (
    SUMX (
        fact_agent_daily,
        fact_agent_daily[break_min] + fact_agent_daily[training_min]
            + IF ( fact_agent_daily[absent], fact_agent_daily[scheduled_min], 0 )
    ),
    [Scheduled Min]
)

-- Works when sliced by date / agent / team / shift (both facts share those dimensions).
-- Do NOT slice it by queue or hour: fact_agent_daily has no queue/hour.
Occupancy % = DIVIDE ( SUM ( fact_calls[handle_sec] ), [Logged Min] * 60 )
```

### Time intelligence (dim_date must be marked as Date table)
```DAX
Abandonment Rate PM = CALCULATE ( [Abandonment Rate], DATEADD ( dim_date[date], -1, MONTH ) )
Abandonment MoM (pts) = ( [Abandonment Rate] - [Abandonment Rate PM] ) * 100
Offered Calls PM = CALCULATE ( [Offered Calls], DATEADD ( dim_date[date], -1, MONTH ) )
```

### Staffing vs demand (hour-level, from interval_staffing)
```DAX
Calls per Agent-Hour =
DIVIDE ( SUM ( vw_interval_staffing[offered_calls] ), SUM ( vw_interval_staffing[agents_present] ) )

Interval Abandonment Rate =
DIVIDE ( SUM ( vw_interval_staffing[abandoned_calls] ), SUM ( vw_interval_staffing[offered_calls] ) )

Avg Agents on Floor = AVERAGE ( vw_interval_staffing[agents_present] )
```

### Targets + conditional formatting
```DAX
Abandonment Target   = 0.05
Service Level Target = 0.80

Abandonment Color =
IF ( [Abandonment Rate] > [Abandonment Target], "#C0392B", "#2E8B57" )

Service Level Color =
IF ( [Service Level 20s] < [Service Level Target], "#C0392B", "#2E8B57" )
```
Use them in *Format -> Conditional formatting -> Field value*.

## 4. Report pages (1-3 built, 4 planned)
1. **Executive overview** - KPI cards (Offered, Abandonment, Service Level, AHT, FCR, CSAT) with target colors, monthly trend with MoM, abandonment by hour.
2. **Root cause: peaks and staffing** - day x hour heatmap of abandonment (matrix + color scale), `Calls per Agent-Hour` vs `Interval Abandonment Rate` scatter, agents on floor vs calls per hour (combo chart).
3. **Agents and teams** - scorecard table (rank in team, CSAT, FCR, AHT, adherence), scatter AHT vs CSAT, coaching list (below team average on FCR and CSAT).
4. **Workforce (planned)** - adherence, shrinkage, occupancy by month and by shift; absence rate.

Slicers (synced across pages): Month, Day type (weekday/weekend), Queue, Team, Shift.
Add tooltips and bookmarks, keep one color for "bad" (red) and one for "good" (green).
