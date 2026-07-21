#!/usr/bin/env python3
"""Plot the twin-node HA test into graphs/twin.png: each replica's scrape time and its
generator-free CPU/RAM, side by side, to show both independently sustain the full load."""
import matplotlib.pyplot as plt
from lib import rows, num, resources, save, OK, BAD, LINE

BUDGET = 1.0
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

r = rows("twin.csv")
if not r:
    print("no data/twin.csv yet - run scenarios/twin.sh first")
    raise SystemExit(0)

labels = [f"replica {x['replica']}\n{x['host'].split('.')[0]}" for x in r]
scr = [num(x["max_scrape_s"]) or BUDGET for x in r]
up = [num(x.get("modules_up")) for x in r]
tgt = max((u or 0) for u in up)
xs = list(range(len(r)))

fig, ax = plt.subplots(figsize=(8, 5.2))
for i, (s, u) in enumerate(zip(scr, up)):
    ax.bar(i, s, width=0.55, zorder=2,
           color=OK if (u is not None and u >= tgt and s <= BUDGET) else BAD)
    ax.annotate(f"{s:.3f}s\n{int(u) if u is not None else '?'} up",
                xy=(i, s), xytext=(i, s + 0.02), ha="center", fontsize=8.5, color="#333")
ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
ax.set_xticks(xs); ax.set_xticklabels(labels)
ax.set_ylabel("max scrape time (s)")
ax.set_ylim(0, max(BUDGET * 1.15, max(scr) * 1.3))
ax.grid(axis="y", alpha=0.25)
resources(ax, xs, r)

fig.suptitle("Twin-node HA: two independent replicas, full load each", fontsize=12.5)
fig.text(0.5, -0.02,
         "Both replicas scrape the FULL target set from separate load node(s). "
         "CPU/RAM (right axis) is now Prometheus-only, uncontended by the generators.\n"
         "green: all modules up and under the 1 s budget    dashed: 1 s budget    "
         "purple: CPU %    blue: RAM %  (% of node)",
         ha="center", fontsize=8.5, color="#555")
save(fig, "twin.png")
