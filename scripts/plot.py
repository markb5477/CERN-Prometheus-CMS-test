#!/usr/bin/env python3
"""Plot results/*.csv into results/suite.png."""
import csv, os, textwrap
import matplotlib.pyplot as plt

def caption(ax, text, width=70):
    ax.text(0.0, -0.30, "\n".join(textwrap.wrap(text, width)), transform=ax.transAxes,
            va="top", ha="left", fontsize=8.3, color="#555")

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

def healthy(r, expected):
    up = num(r.get("targets_up"))
    return up is not None and up >= expected

def scatter(ax, xs, rs, expected):
    ys = [num(r["max_scrape_s"]) for r in rs]
    ax.plot(xs, [y if y else BUDGET for y in ys], color="#999", lw=1, zorder=1)
    for x, y, r, e in zip(xs, ys, rs, expected):
        ok = healthy(r, e)
        ax.scatter(x, y if y else BUDGET, s=70, zorder=3,
                   color=OK if ok else BAD, edgecolor="white", linewidth=1)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_ylabel("scrape time (s)")
    ax.grid(axis="y", alpha=0.25); ax.margins(x=0.06)

fig = plt.figure(figsize=(11, 13.5))
gs = fig.add_gridspec(3, 2, height_ratios=[1.25, 1, 1], hspace=0.85, wspace=0.24)

# sensor ramp, full width on top
r = rows("sensors.csv")
if r:
    ax = fig.add_subplot(gs[0, :])
    xs = [num(x["params"]) for x in r]
    exp = [num(x["params"]) / num(x["per_exporter"]) for x in r]
    scatter(ax, xs, r, exp)
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlabel("total parameters (35 per sensor)")
    for x, row, e in zip(xs, r, exp):
        if not healthy(row, e):
            ax.annotate("scrape > budget", xy=(x, BUDGET),
                        xytext=(x, BUDGET - 0.4), ha="center", fontsize=9, color=BAD,
                        arrowprops=dict(arrowstyle="->", color=BAD))
            break
    ax.set_title("sensor ramp", loc="left", fontsize=11.5, weight="bold")
    caption(ax, "Realistic detector model: 35 parameters per sensor across a fixed set "
                "of boards, total stepped up to 1.2M. Idea: check the tracker's actual "
                "operating load scrapes inside the 1 s budget.", width=95)

# ---- supporting panels ----
def panel(cell, name, xcol, title, xfmt=True, expected_from="ratio"):
    r = rows(name)
    if not r: return
    ax = fig.add_subplot(cell)
    xs = [num(x[xcol]) for x in r]
    exp = ([num(x["params"]) / num(x["per_exporter"]) for x in r]
           if expected_from == "ratio" else xs[:])
    scatter(ax, xs, r, exp)
    if xfmt: ax.xaxis.set_major_formatter(kfmt)
    ax.set_title(title, loc="left", fontsize=10)
    return ax

ax = panel(gs[1, 0], "ramp.csv", "params", "ramp")
if ax:
    ax.set_xlabel("total parameters")
    caption(ax, "Many thin targets, total raised 200k to 2M. Idea: trace how scrape "
                "time grows when each target stays light.")

ax = panel(gs[1, 1], "sweep.csv", "exporters",
           "sweep (2M fixed)", xfmt=False, expected_from="self")
if ax:
    xs = [num(x["exporters"]) for x in rows("sweep.csv")]
    ax.set_xscale("log"); ax.set_xticks(xs)
    ax.set_xticklabels([f"{int(n)}" for n in xs])
    ax.set_xlabel("number of targets")
    caption(ax, "Same 2M total, split across 1 to 160 targets. Idea: isolate the real "
                "limit, series per target, not total volume or RAM.")

ax = panel(gs[2, 0], "stress.csv", "params", "stress")
if ax:
    ax.set_xlabel("total parameters")
    caption(ax, "Large jumps straight to 2M. Idea: find the breaking point quickly "
                "rather than creeping up to it.")

# spike: bar per phase
r = rows("spike.csv")
if r:
    ax = fig.add_subplot(gs[2, 1])
    ys = [num(x["max_scrape_s"]) or BUDGET for x in r]
    ntgt = max((num(x.get("targets_up")) or 0) for x in r)
    for i, x in enumerate(r):
        up = num(x.get("targets_up"))
        ax.bar(i, ys[i], width=0.6, zorder=2,
               color=OK if (up is not None and up >= ntgt) else BAD)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_xticks(range(len(r)))
    ax.set_xticklabels([x["phase"].replace("_", "\n") for x in r])
    ax.set_ylabel("scrape time (s)"); ax.grid(axis="y", alpha=0.25)
    ax.set_title("spike", loc="left", fontsize=10)
    caption(ax, "Steady baseline, sudden 2M spike, back to baseline. Idea: test that "
                "it survives a burst and recovers with no lingering damage.")

fig.suptitle("Prometheus 1 Hz scrape tests", fontsize=13, y=0.995)
fig.text(0.5, 0.008,
         "green: all targets up    red: scrape timed out    dashed: 1 s budget",
         ha="center", fontsize=9.5, color="#444")
fig.savefig(os.path.join(R, "suite.png"), bbox_inches="tight")
print("-> results/suite.png")
