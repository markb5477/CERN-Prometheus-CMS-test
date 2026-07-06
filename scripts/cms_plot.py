#!/usr/bin/env python3
"""Plot the CMS model CSVs into results/cms.png."""
import csv, os
import matplotlib.pyplot as plt

R, BUDGET = "results", 1.0
OK, BAD, LINE = "#2a9d8f", "#e76f51", "#c1121f"
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

def rows(name):
    p = os.path.join(R, name)
    return list(csv.DictReader(open(p))) if os.path.exists(p) else []

def num(v):
    try: return float(v)
    except (TypeError, ValueError): return None

def kfmt(x, _=None):
    return f"{x/1e6:g}M" if x >= 1e6 else f"{x/1e3:g}k"

def panel(ax, r, xcol, expected):
    xs = [num(x[xcol]) for x in r]
    ys = [num(x["max_scrape_s"]) for x in r]
    ax.plot(xs, [y if y else BUDGET for y in ys], color="#999", lw=1, zorder=1)
    for x, y, row, e in zip(xs, ys, r, expected):
        up = num(row.get("targets_up"))
        ok = up is not None and up >= e
        ax.scatter(x, y if y else BUDGET, s=70, zorder=3,
                   color=OK if ok else BAD, edgecolor="white", linewidth=1)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_ylabel("scrape time (s)")
    ax.grid(axis="y", alpha=0.25); ax.margins(x=0.08)

fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 4.8))

g = rows("cms_grow.csv")
if g:
    panel(a1, g, "params", [316] * len(g))
    a1.axvline(880000, ls=":", color="#888", lw=1)
    a1.annotate("real load\n~880k", xy=(880000, BUDGET * 0.9), fontsize=8.5, color="#555")
    a1.xaxis.set_major_formatter(kfmt)
    a1.set_xlabel("total parameters")
    a1.set_title("growth at 316 DTC aggregators", loc="left", fontsize=11)

a = rows("cms_agg.csv")
if a:
    xs = [num(x["targets"]) for x in a]
    panel(a2, a, "targets", xs)
    a2.set_xscale("log"); a2.set_xticks(xs)
    a2.set_xticklabels([f"{int(n)}" for n in xs])
    a2.set_xlabel("number of aggregators (880k fixed)")
    a2.set_title("aggregation granularity", loc="left", fontsize=11)
    for x, row in zip(xs, a):
        pt = num(row["per_target"])
        if pt: a2.annotate(f"{int(pt/1000)}k", xy=(x, 0.04),
                           ha="center", fontsize=8, color="#555")

fig.suptitle("CMS Tracker monitoring model, single Prometheus node at 1 Hz", fontsize=12.5)
fig.text(0.5, -0.02, "green: all aggregators up    red: scrape timed out    dashed: 1 s budget    "
         "labels on right = series per aggregator", ha="center", fontsize=9, color="#444")
fig.tight_layout()
fig.savefig(os.path.join(R, "cms.png"), bbox_inches="tight")
print("-> results/cms.png")
