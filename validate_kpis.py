"""
KPI reconciliation: recompute the headline KPIs in pandas straight from the CSVs.
Compare these numbers with the SQL views / Power BI cards - they must match.
(Good interview line: "I reconciled SQL, Python and Power BI on the same KPIs.")
Run: python validate_kpis.py   (after generate_data.py)
"""
import pandas as pd

calls = pd.read_csv("data/fact_calls.csv")
wfm = pd.read_csv("data/fact_agent_daily.csv")
dates = pd.read_csv("data/dim_date.csv")

answered = calls[calls.abandoned == 0]
offered = len(calls)

print("=== Headline KPIs (full year) ===")
print(f"Offered calls        : {offered:,}")
print(f"Abandonment rate     : {100 * calls.abandoned.mean():.2f} %")
print(f"AHT (answered)       : {answered.handle_sec.mean():.0f} sec")
print(f"Service level (20s)  : {100 * ((calls.abandoned == 0) & (calls.wait_sec <= 20)).sum() / offered:.2f} %")
print(f"FCR                  : {100 * answered.resolved_first_call.mean():.2f} %")
print(f"CSAT (responders)    : {answered.csat.mean():.2f}   (response rate {100 * answered.csat.notna().mean():.1f} %)")

print("\n=== Workforce (WFM) ===")
sched = wfm.scheduled_min.sum()
print(f"Adherence            : {100 * wfm.logged_min.sum() / sched:.2f} %")
print(f"Shrinkage            : {100 * (wfm.break_min + wfm.training_min + wfm.absent * wfm.scheduled_min).sum() / sched:.2f} %")
handle = calls.groupby(["date_key", "agent_id"]).handle_sec.sum().rename("handle_sec").reset_index()
ad = wfm.merge(handle, on=["date_key", "agent_id"], how="left").fillna({"handle_sec": 0})
print(f"Occupancy            : {100 * ad.handle_sec.sum() / (ad.logged_min.sum() * 60):.2f} %")

print("\n=== Abandonment by hour ===")
h = calls.groupby("call_hour").abandoned.agg(offered="count", abandoned="sum")
h["rate_pct"] = (100 * h.abandoned / h.offered).round(2)
print(h.to_string())

print("\n=== Unusual days (z-score within month + day type, > 2.5) ===")
d = calls.groupby("date_key").size().rename("offered").reset_index().merge(
    dates[["date_key", "date", "month", "is_weekend"]], on="date_key")
g = d.groupby(["month", "is_weekend"]).offered
d["z"] = (d.offered - g.transform("mean")) / g.transform("std")
print(d[d.z > 2.5][["date", "offered", "z"]].round(2).to_string(index=False))
