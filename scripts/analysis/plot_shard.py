#!/usr/bin/env python3
"""Plot the functional-sharding sweep into graphs/shard.png: worst-shard scrape time and
per-node series as the shard count K rises, showing per-node load falls as ~1/K."""
import matplotlib.pyplot as plt
from lib import rows, num, save, OK, BAD, LINE, CPUC

BUDGET = 1.0
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

r = rows("shard.csv")
if not r:
    print("no data/shard.csv yet - run scenarios/shard.sh first")
    raise SystemExit(0)

# group by K = number of shards; the binding constraint is the WORST shard at each K
Ks, worst_scrape, worst_cpu, per_node_series, all_up = [], [], [], [], []
for row in r:
    row["_k"] = int(num(row["shards"]))
for K in sorted({row["_k"] for row in r}):
    grp = [x for x in r if x["_k"] == K]
    scr = [num(x["max_scrape_s"]) for x in grp if num(x["max_scrape_s"]) is not None]
    cpu = [num(x["cpu_pct"]) for x in grp if num(x["cpu_pct"]) is not None]
    ser = [num(x["head_series"]) for x in grp if num(x["head_series"]) is not None]
    up = [num(x.get("modules_up")) for x in grp]
    tgtmods = sum(num(x["targets"]) or 0 for x in grp)
    Ks.append(K)
    worst_scrape.append(max(scr) if scr else BUDGET)
    worst_cpu.append(max(cpu) if cpu else float("nan"))
    per_node_series.append(max(ser) if ser else float("nan"))
    all_up.append(all((u or 0) >= (num(x["targets"]) or 0) for u, x in zip(up, grp)))

xs = list(range(len(Ks)))
fig, ax = plt.subplots(figsize=(9, 5.4))
ax.plot(xs, worst_scrape, color="#999", lw=1, zorder=1)
for i, (s, ok) in enumerate(zip(worst_scrape, all_up)):
    ax.scatter(i, s, s=80, zorder=3, color=OK if (ok and s <= BUDGET) else BAD,
               edgecolor="white", linewidth=1)
    ser = per_node_series[i]
    if ser == ser:  # not nan
        ax.annotate(f"{ser/1e6:.2f}M\nper node", xy=(i, s), xytext=(i, s + 0.03),
                    ha="center", fontsize=8, color="#555")
ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
ax.set_xticks(xs); ax.set_xticklabels([f"{k}\nshard{'s' if k > 1 else ''}" for k in Ks])
ax.set_xlabel("functional shards (K)")
ax.set_ylabel("worst-shard scrape time (s)")
ax.set_ylim(0, max(BUDGET * 1.15, max(worst_scrape) * 1.3))
ax.grid(axis="y", alpha=0.25); ax.margins(x=0.08)

ax2 = ax.twinx()
ax2.plot(xs, worst_cpu, color=CPUC, lw=1.4, marker="o", ms=4, label="worst-shard CPU %")
ax2.set_ylim(0, 100)
ax2.set_ylabel("CPU (% of node)", fontsize=8.5, color="#555")
ax2.tick_params(axis="y", labelsize=7.5, colors="#555")
ax2.legend(loc="upper right", fontsize=7.5, framealpha=0.85)

fig.suptitle("Functional sharding: per-node load falls as ~1/K", fontsize=12.5)
fig.text(0.5, -0.02,
         "Full target set split into K disjoint shards, one Prometheus per shard, load on "
         "separate node(s). Labels = series carried per node.\n"
         "green: every shard healthy and under budget    dashed: 1 s budget    "
         "purple: worst-shard CPU % (of node)",
         ha="center", fontsize=8.5, color="#555")
save(fig, "shard.png")
