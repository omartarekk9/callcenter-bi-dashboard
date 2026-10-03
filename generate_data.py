"""
Synthetic call center data generator (star schema) - v2
=======================================================
ALL DATA IS SYNTHETIC (state this clearly in the README).

What makes this data realistic (and gives the analysis something to find):
  * Agents work 8-hour shifts (Early 09-17, Day 10-18, Mid 11-19, Late 13-21), Sun-Thu,
    plus a rotating half of the roster on Fri/Sat (weekend in Egypt).
  * Calls are only answered by agents who are scheduled AND present that hour,
    so fact_calls and fact_agent_daily always agree.
  * Wait times come from an Erlang-C queueing model: when offered load gets close
    to the number of available agents, waits explode -> customers abandon.
  * Seasonality (Jun/Jul/Nov), weekday pattern, and a few incident days (spikes).
  * Hidden agent skill + team effect drive AHT / FCR / CSAT / adherence.
  * Queue mix and queue difficulty differ (Tech Support and Complaints resolve less).

Outputs (CSV) in ./data (or --out):
  dim_date, dim_team, dim_agent, dim_queue, fact_calls, fact_agent_daily
Run: python generate_data.py
What-if: python generate_data.py --shift-mix 9:9,10:9,11:6,13:8 --out data_whatif
"""
import argparse
import os
import numpy as np
import pandas as pd

parser = argparse.ArgumentParser(description="Synthetic call center data generator")
parser.add_argument("--shift-mix", default="9:13,10:5,11:4,13:10",
                    help="agents per shift start hour, e.g. 9:13,10:5,11:4,13:10 (what-if scenarios)")
parser.add_argument("--out", default="data", help="output folder for the CSV files")
args = parser.parse_args()

SEED = 42
rng = np.random.default_rng(SEED)
os.makedirs(args.out, exist_ok=True)

START, END = "2025-01-01", "2025-12-31"
HOURS = np.arange(9, 21)                                   # calls arrive 09:00-20:59
HOUR_SHARE = np.array([6, 10, 11, 11, 10, 9, 10, 11, 9, 7, 4, 2]) / 100
SHIFT_LEN = 8

# ---- knobs ---------------------------------------------------------------
BASE_WEEKDAY_CALLS = 1150       # average Sun-Thu volume before seasonality
BREAK_SHARE = 0.14              # share of logged-in agents unavailable (break/training)
PATIENCE_MEAN_SEC = 300         # mean time a caller will wait before hanging up
ABSENT_RATE = 0.05
CSAT_RESPONSE_RATE = 0.35       # only ~1 in 3 callers answers the survey
DOW_FACTOR = {6: 1.12, 0: 1.05, 1: 1.00, 2: 0.97, 3: 0.88, 4: 0.30, 5: 0.40}  # Mon=0..Sun=6
BUSY_MONTHS = (6, 7, 11)

# ---------- dimensions ----------
dates = pd.date_range(START, END, freq="D")
dim_date = pd.DataFrame({
    "date_key": dates.strftime("%Y%m%d").astype(int),
    "date": dates.date,
    "year": dates.year,
    "quarter": dates.quarter,
    "month": dates.month,
    "month_name": dates.strftime("%b"),
    "year_month": dates.strftime("%Y-%m"),
    "week": dates.isocalendar().week.values,
    "day_name": dates.strftime("%a"),
    "dow_num": ((dates.dayofweek + 1) % 7) + 1,            # Sun=1 ... Sat=7 (Egypt week)
    "is_weekend": dates.dayofweek.isin([4, 5]).astype(int),  # Fri/Sat
})

dim_team = pd.DataFrame({
    "team_id": [1, 2, 3, 4],
    "team_name": ["Team A", "Team B", "Team C", "Team D"],
})
TEAM_EFFECT = np.array([0.0, 0.30, -0.25, 0.10])            # hidden: Team B best, C weakest

QUEUES = ["Billing", "Technical Support", "Sales", "Complaints"]
Q_AHT = np.array([300, 540, 240, 480])
Q_MIX = np.array([0.35, 0.30, 0.20, 0.15])
Q_FCR = np.array([0.80, 0.66, 0.85, 0.60])
dim_queue = pd.DataFrame({
    "queue_id": [1, 2, 3, 4], "queue_name": QUEUES, "avg_handle_sec": Q_AHT,
})

N_AGENTS = 32
first = ["Ahmed", "Mohamed", "Mahmoud", "Omar", "Youssef", "Karim", "Hassan", "Ali", "Mostafa",
         "Khaled", "Tamer", "Amr", "Sara", "Mona", "Nour", "Hana", "Salma", "Dina", "Rania",
         "Yasmin", "Heba", "Mariam", "Farida", "Laila", "Nada", "Aya", "Eman", "Reem"]
last = ["Hassan", "Ibrahim", "Saleh", "Mansour", "Fahmy", "Nabil", "Adel", "Samir", "Gamal",
        "Farouk", "Zaki", "Rashed", "Shaker", "Hegazy", "Lotfy", "Soliman", "Badawy", "Kamel"]
pairs = [(f, l) for f in first for l in last]
pick = rng.choice(len(pairs), N_AGENTS, replace=False)
names = [f"{pairs[i][0]} {pairs[i][1]}" for i in pick]

SHIFT_NAME = {9: "Early", 10: "Day", 11: "Mid", 12: "Midlate", 13: "Late"}
SHIFT_START = {v: k for k, v in SHIFT_NAME.items()}
# default: 13 early, 5 day, 4 mid, 10 late (cover is intentionally uneven -> realistic gaps)
mix = {int(k): int(v) for k, v in (p.split(":") for p in args.shift_mix.split(","))}
assert sum(mix.values()) == N_AGENTS, f"--shift-mix must add up to {N_AGENTS} agents"
shift_defs = [(SHIFT_NAME[h], h) for h, n in mix.items() for _ in range(n)]
order = rng.permutation(N_AGENTS)
team_ids = np.tile([1, 2, 3, 4], N_AGENTS // 4)[order]      # balanced teams (8 each)
shift_name = np.array([s[0] for s in shift_defs])[rng.permutation(N_AGENTS)]
shift_start = np.array([SHIFT_START[s] for s in shift_name])

dim_agent = pd.DataFrame({
    "agent_id": np.arange(1, N_AGENTS + 1),
    "agent_name": names,
    "team_id": team_ids,
    "hire_date": pd.to_datetime("2021-01-01")
    + pd.to_timedelta(rng.integers(0, 1460, N_AGENTS), unit="D"),
    "shift_name": shift_name,
    "shift_start_hour": shift_start,
})
skill = rng.normal(0, 0.8, N_AGENTS) + TEAM_EFFECT[team_ids - 1]   # hidden skill factor


# ---------- Erlang C ----------
def erlang_c(c: int, a: float) -> float:
    """Probability a call has to wait (M/M/c). c = servers, a = offered load (Erlangs)."""
    if c <= 0 or a >= c:
        return 1.0
    b = 1.0
    for k in range(1, c + 1):
        b = a * b / (k + a * b)            # Erlang B recursion (numerically stable)
    rho = a / c
    return b / (1 - rho * (1 - b))


# ---------- agent schedule (fact_agent_daily) ----------
sched_rows = {}      # (date_key, agent_idx) -> dict
for d in dates:
    dk = int(d.strftime("%Y%m%d"))
    dow = d.dayofweek
    week = int(d.isocalendar().week)
    for a in range(N_AGENTS):
        works = dow not in (4, 5) or ((a + week) % 2 == 0)    # Fri/Sat rotation: half of roster
        if not works:
            continue
        absent = rng.random() < ABSENT_RATE
        if absent:
            logged = brk = train = 0
        else:
            logged = int(np.clip(rng.normal(455 + 6 * skill[a], 25), 300, 480))
            brk = int(np.clip(rng.normal(62, 12), 30, 120))
            train = 60 if rng.random() < 0.08 else 0
        sched_rows[(dk, a)] = (480, logged, brk, train, int(absent))

fact_agent_daily = pd.DataFrame(
    [(dk, a + 1, *v) for (dk, a), v in sched_rows.items()],
    columns=["date_key", "agent_id", "scheduled_min", "logged_min",
             "break_min", "training_min", "absent"])

# ---------- fact_calls ----------
incident_days = set(rng.choice(dates[dates.dayofweek.isin([6, 0, 1, 2, 3])], 5, replace=False))
present_by_day = {}
for (dk, a), v in sched_rows.items():
    if v[4] == 0:
        present_by_day.setdefault(dk, []).append(a)

frames = []
for d in dates:
    dk = int(d.strftime("%Y%m%d"))
    mult = DOW_FACTOR[d.dayofweek] * (1.25 if d.month in BUSY_MONTHS else 1.0)
    if d in incident_days:
        mult *= 1.5                                           # outage / campaign spike
    day_total = rng.poisson(BASE_WEEKDAY_CALLS * mult)
    hourly = rng.multinomial(day_total, HOUR_SHARE)
    present = np.array(present_by_day.get(dk, []), dtype=int)

    for h, n in zip(HOURS, hourly):
        if n == 0:
            continue
        staff = present[(shift_start[present] <= h) & (h < shift_start[present] + SHIFT_LEN)] \
            if len(present) else present
        queues = rng.choice(4, n, p=Q_MIX)
        aht_avg = Q_AHT[queues].mean()
        a_load = n * aht_avg / 3600.0                         # Erlangs
        c = int(round(len(staff) * (1 - BREAK_SHARE)))

        base_wait = rng.integers(1, 6, n)                     # IVR / ring time
        if c <= 0:
            queue_wait = np.full(n, 600.0)                    # nobody there
            waited = np.ones(n, dtype=bool)
        else:
            if a_load >= 0.98 * c:                            # saturated queue
                pw, w_mean = 1.0, min(120 + 600 * (a_load / c - 0.98), 600)
            else:
                pw, w_mean = erlang_c(c, a_load), min(aht_avg / (c - a_load), 900)
            waited = rng.random(n) < pw
            queue_wait = np.where(waited, rng.exponential(w_mean, n), 0.0)

        patience = rng.exponential(PATIENCE_MEAN_SEC, n)
        abandoned = waited & (queue_wait > patience)
        wait = base_wait + np.where(abandoned, patience, queue_wait)

        agent_idx = np.full(n, -1)
        if len(staff):
            agent_idx = np.where(abandoned, -1, rng.choice(staff, n))
        ans = ~abandoned & (agent_idx >= 0)
        abandoned = ~ans                                      # (no staff -> everyone abandons)

        sk = np.where(ans, skill[np.maximum(agent_idx, 0)], 0.0)
        aht_mean = Q_AHT[queues] * (1 - 0.06 * sk)
        handle = np.where(ans, np.clip(rng.normal(aht_mean, aht_mean * 0.25), 60, 1800), 0).astype(int)
        p_fcr = np.clip(Q_FCR[queues] + 0.05 * sk - wait / 3000, 0.30, 0.97)
        resolved = (ans & (rng.random(n) < p_fcr)).astype(int)
        csat_raw = np.clip(np.round(rng.normal(3.5 + 0.30 * sk - wait / 180 + 0.6 * resolved, 0.9)), 1, 5)
        responded = ans & (rng.random(n) < CSAT_RESPONSE_RATE)
        csat = np.where(responded, csat_raw, np.nan)

        frames.append(pd.DataFrame({
            "date_key": dk, "call_hour": h, "call_minute": rng.integers(0, 60, n),
            "agent_id": np.where(ans, agent_idx + 1, np.nan),
            "queue_id": queues + 1,
            "wait_sec": wait.astype(int), "handle_sec": handle,
            "abandoned": abandoned.astype(int), "resolved_first_call": resolved,
            "csat": csat,
        }))

fact_calls = pd.concat(frames, ignore_index=True)
fact_calls = fact_calls.sort_values(["date_key", "call_hour", "call_minute"], kind="stable") \
                       .reset_index(drop=True)
fact_calls.insert(0, "call_id", np.arange(1, len(fact_calls) + 1))

# ---------- write ----------
for name, df in {
    "dim_date": dim_date, "dim_team": dim_team, "dim_agent": dim_agent,
    "dim_queue": dim_queue, "fact_calls": fact_calls,
    "fact_agent_daily": fact_agent_daily,
}.items():
    for c in ("agent_id", "csat"):
        if c in df.columns:
            df[c] = df[c].astype("Int64")          # no "12.0" decimals, keeps NULLs empty
    df.to_csv(f"{args.out}/{name}.csv", index=False, lineterminator="\n")
    print(f"{name:18s} {len(df):>9,} rows")
