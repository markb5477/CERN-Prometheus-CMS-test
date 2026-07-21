#!/usr/bin/env python3
"""Plot the real-hardware measurement into graphs/hardware.png: measured scrape time and
generator-free CPU/RAM on REAL module exporters, against the 1 s budget. One bar per run
(re-run hardware.sh as the bench grows and it becomes a small real-hardware sweep)."""
import matplotlib.pyplot as plt
from lib import rows, num, resources, save, OK, BAD, LINE

BUDGET = 1.0
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

r = rows("hardware.csv")
if not r:
    print("no data/hardware.csv yet - run scenarios/hardware.sh first")
    raise SystemExit(0)

scr = [num(x["max_scrape_s"]) or BUDGET for x in r]
tgt = [num(x["targets"]) for x in r]
up = [num(x.get("modules_up")) for x in r]
ser = [num(x.get("head_series")) for x in r]
labels = [f"{int(t) if t else '?'} modules" for t in tgt]
xs = list(range(len(r)))

fig, ax = plt.subplots(figsize=(max(6, 1.6 * len(r) + 4), 5.2))
for i, (s, t, u) in enumerate(zip(scr, tgt, up)):
    healthy = u is not None and t is not None and u >= t and s <= BUDGET
    ax.bar(i, s, width=0.5, zorder=2, color=OK if healthy else BAD)
    tail = f"\n{int(ser[i]/1000)}k series" if ser[i] else ""
    ax.annotate(f"{s:.3f}s\n{int(u) if u is not None else '?'}/{int(t) if t else '?'} up{tail}",
                xy=(i, s), xytext=(i, s + 0.02), ha="center", fontsize=8.5, color="#333")
ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
ax.set_xticks(xs); ax.set_xticklabels(labels)
ax.set_ylabel("max scrape time (s)")
ax.set_ylim(0, max(BUDGET * 1.15, max(scr) * 1.3))
ax.grid(axis="y", alpha=0.25); ax.margins(x=0.15)
resources(ax, xs, r)

fig.suptitle("Real hardware at 1 Hz: measured footprint on actual module exporters", fontsize=12.5)
fig.text(0.5, -0.02,
         "Prometheus scrapes REAL exporters (no Avalanche); the load runs on the sensors' own "
         "hardware, so CPU/RAM (right axis) is Prometheus-only.\n"
         "green: all modules up and under the 1 s budget    dashed: 1 s budget    "
         "purple: CPU %    blue: RAM %  (% of node)",
         ha="center", fontsize=8.5, color="#555")
save(fig, "hardware.png")
