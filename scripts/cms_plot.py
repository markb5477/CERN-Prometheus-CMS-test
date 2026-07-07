#!/usr/bin/env python3
"""Plot the CMS model CSVs into results/cms.png."""
import csv, os, textwrap
import matplotlib.pyplot as plt

def caption(ax, text):
    ax.text(0.0, -0.30, "\n".join(textwrap.wrap(text, 62)), transform=ax.transAxes,
            va="top", ha="left", fontsize=8.3, color="#555")

R, BUDGET, YMAX = "results", 1.0, 1.4
OK, BAD, LINE = "#2a9d8f", "#e76f51", "#c1121f"
CPUC, RAMC = "#8338ec", "#3a86ff"   # CPU and RAM lines (right axis)
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

def rows(name):
    p = os.path.join(R, name)
    return list(csv.DictReader(open(p))) if os.path.exists(p) else []

def num(v):
    try: return float(v)
    except (TypeError, ValueError): return None

def kfmt(x, _=None):
    return f"{x/1e6:g}M" if x >= 1e6 else f"{x/1e3:g}k"

def resources(ax, xs, rs):
    # Prometheus CPU% and RAM% (of the whole node) on a second y-axis; skip if not recorded.
    cpu = [num(r.get("cpu_pct")) for r in rs]
    ram = [num(r.get("ram_pct")) for r in rs]
    if not any(v is not None for v in cpu + ram):
        return
    nan = float("nan")
    cpu = [c if c is not None else nan for c in cpu]
    ram = [m if m is not None else nan for m in ram]
    ax2 = ax.twinx()
    ax2.plot(xs, cpu, color=CPUC, lw=1.4, marker="o", ms=3, label="CPU %", zorder=4)
    ax2.plot(xs, ram, color=RAMC, lw=1.4, marker="s", ms=3, label="RAM %", zorder=4)
    ax2.set_ylim(bottom=0)
    ax2.set_ylabel("CPU / RAM (% of node)", fontsize=8.5, color="#555")
    ax2.tick_params(axis="y", labelsize=7.5, colors="#555")
    ax2.legend(loc="upper left", fontsize=7, framealpha=0.85)

def panel(ax, r, xcol, expected):
    xs = [num(x[xcol]) for x in r]
    ys = [num(x["max_scrape_s"]) for x in r]
    disp = [min(y, YMAX * 0.97) if y else BUDGET for y in ys]
    ax.plot(xs, disp, color="#999", lw=1, zorder=1)
    for x, d, y, row, e in zip(xs, disp, ys, r, expected):
        up = num(row.get("modules_up"))
        ok = up is not None and up >= e and y is not None and y <= BUDGET
        ax.scatter(x, d, s=70, zorder=3,
                   color=OK if ok else BAD, edgecolor="white", linewidth=1)
        if not ok and up is not None:  # collapse: label how many modules stayed up
            over = y and y > YMAX
            txt = f"{y:.0f} s\n{int(up)}/{int(e)} up" if over else f"{int(up)}/{int(e)} up"
            ax.annotate(txt, xy=(x, d), xytext=(x, d - 0.35 if over else d + 0.15),
                        ha="center", fontsize=8, color=BAD)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_ylim(0, YMAX); ax.set_ylabel("scrape time (s)")
    ax.grid(axis="y", alpha=0.25); ax.margins(x=0.08)
    resources(ax, xs, r)

fig, (a1, a2) = plt.subplots(1, 2, figsize=(12, 5.6))

g = rows("cms_grow.csv")
if g:
    panel(a1, g, "params", [316] * len(g))
    a1.axvline(880000, ls=":", color="#888", lw=1)
    a1.annotate("real load\n~880k", xy=(880000, 1.15), fontsize=8.5, color="#555")
    a1.xaxis.set_major_formatter(kfmt)
    a1.set_xlabel("total parameters")
    a1.set_title("growth at 316 modules", loc="left", fontsize=11)
    caption(a1, "880k parameters over 316 modules (per-DTC aggregation points) = 2,784 "
                "parameters each; pushed to 2.5M = 7,911 each. 1 parameter = 1 series. Idea: "
                "measure headroom before the node's total ingestion ceiling, not the per-module limit.")

a = rows("cms_agg.csv")
if a:
    xs = [num(x["modules"]) for x in a]
    panel(a2, a, "modules", xs)
    a2.set_xscale("log"); a2.set_xticks(xs)
    a2.set_xticklabels([f"{int(n)}" for n in xs])
    a2.set_xlabel("number of modules (880k fixed)")
    a2.set_title("module granularity", loc="left", fontsize=11)
    caption(a2, "880k parameters fixed, modules coarsened 316 -> 8 (per-DTC toward per-rack) "
                "= 2,785 up to 110,009 parameters each. Idea: show how consolidating modules "
                "fattens each scrape, to pick a safe aggregation topology.")
    for x, row in zip(xs, a):
        pt = num(row["params_per_module"])
        if pt: a2.annotate(f"{int(pt/1000)}k", xy=(x, 0.06),
                           ha="center", fontsize=8, color="#555")

fig.suptitle("CMS Tracker monitoring model, single Prometheus node at 1 Hz", fontsize=12.5)
fig.tight_layout(rect=[0, 0.10, 1, 1])
fig.text(0.5, 0.02, "green: all modules up and under budget    red: over budget or collapsed    "
         "dashed: 1 s budget    labels = parameters per module", ha="center", fontsize=9, color="#444")
fig.text(0.5, 0.005, "purple: CPU %    blue: RAM %  (right axis, % of node)",
         ha="center", fontsize=8.5, color="#666")
fig.savefig(os.path.join(R, "cms.png"), bbox_inches="tight")
print("-> results/cms.png")
