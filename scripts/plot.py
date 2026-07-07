#!/usr/bin/env python3
"""Plot results/*.csv into results/suite.png."""
import csv, os, textwrap
import matplotlib.pyplot as plt

R, BUDGET = "results", 1.0
OK, BAD, LINE = "#2a9d8f", "#e76f51", "#c1121f"
CPUC, RAMC = "#8338ec", "#3a86ff"   # CPU and RAM lines (right axis)
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

def caption(ax, text, width=70):
    ax.text(0.0, -0.30, "\n".join(textwrap.wrap(text, width)), transform=ax.transAxes,
            va="top", ha="left", fontsize=8.3, color="#555")

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

def healthy(r, expected):
    up = num(r.get("modules_up"))
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
    resources(ax, xs, rs)

fig = plt.figure(figsize=(11, 13.5))
gs = fig.add_gridspec(3, 2, height_ratios=[1.25, 1, 1], hspace=0.85, wspace=0.24)

# module ramp, full width on top
r = rows("modules.csv")
if r:
    ax = fig.add_subplot(gs[0, :])
    xs = [num(x["params"]) for x in r]
    exp = [num(x["params"]) / num(x["params_per_module"]) for x in r]
    scatter(ax, xs, r, exp)
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlabel("total parameters")
    for x, row, e in zip(xs, r, exp):
        if not healthy(row, e):
            ax.annotate("scrape > budget", xy=(x, BUDGET),
                        xytext=(x, BUDGET - 0.4), ha="center", fontsize=9, color=BAD,
                        arrowprops=dict(arrowstyle="->", color=BAD))
            break
    ax.set_title("module ramp", loc="left", fontsize=11.5, weight="bold")
    caption(ax, "25 modules, total parameters stepped to 1.2M, i.e. each module holds "
                "8,000 (at 200k) up to 48,000 (at 1.2M) parameters. Idea: confirm the "
                "tracker's real operating load scrapes inside the 1 s budget.", width=95)

# ---- supporting panels ----
def panel(cell, name, xcol, title, xfmt=True, expected_from="ratio"):
    r = rows(name)
    if not r: return
    ax = fig.add_subplot(cell)
    xs = [num(x[xcol]) for x in r]
    exp = ([num(x["params"]) / num(x["params_per_module"]) for x in r]
           if expected_from == "ratio" else xs[:])
    scatter(ax, xs, r, exp)
    if xfmt: ax.xaxis.set_major_formatter(kfmt)
    ax.set_title(title, loc="left", fontsize=10)
    return ax

ax = panel(gs[1, 0], "ramp.csv", "params", "ramp")
if ax:
    ax.set_xlabel("total parameters")
    caption(ax, "80 modules; each holds total/80 parameters, i.e. 2,500 (at 200k) up to "
                "25,000 (at 2M). Idea: trace how scrape time grows when modules stay thin.")

ax = panel(gs[1, 1], "sweep.csv", "modules",
           "sweep (2M fixed)", xfmt=False, expected_from="self")
if ax:
    xs = [num(x["modules"]) for x in rows("sweep.csv")]
    ax.set_xscale("log"); ax.set_xticks(xs)
    ax.set_xticklabels([f"{int(n)}" for n in xs])
    ax.set_xlabel("number of modules")
    caption(ax, "2M parameters held fixed, split across 1 to 160 modules: 2M down to "
                "12,500 parameters each. Idea: isolate the real limit, parameters per "
                "module, not total volume or RAM.")

ax = panel(gs[2, 0], "stress.csv", "params", "stress")
if ax:
    ax.set_xlabel("total parameters")
    caption(ax, "80 modules in large jumps: 6,250 (500k) to 25,000 (2M) parameters each. "
                "Idea: find the breaking point fast rather than creeping up to it.")

# spike: bar per phase
r = rows("spike.csv")
if r:
    ax = fig.add_subplot(gs[2, 1])
    ys = [num(x["max_scrape_s"]) or BUDGET for x in r]
    ntgt = max((num(x.get("modules_up")) or 0) for x in r)
    for i, x in enumerate(r):
        up = num(x.get("modules_up"))
        ax.bar(i, ys[i], width=0.6, zorder=2,
               color=OK if (up is not None and up >= ntgt) else BAD)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_xticks(range(len(r)))
    ax.set_xticklabels([x["phase"].replace("_", "\n") for x in r])
    ax.set_ylabel("scrape time (s)"); ax.grid(axis="y", alpha=0.25)
    resources(ax, list(range(len(r))), r)
    ax.set_title("spike", loc="left", fontsize=10)
    caption(ax, "80 modules. Baseline 400k = 5,000 parameters/module; spike to 2M = "
                "25,000/module; back to baseline. Idea: test burst survival and recovery.")

fig.suptitle("Prometheus 1 Hz scrape tests", fontsize=13, y=0.995)
fig.text(0.5, 0.020,
         "green: all modules up    red: scrape timed out    dashed: 1 s budget    "
         "purple: CPU %    blue: RAM %  (right axis, % of node)",
         ha="center", fontsize=9.5, color="#444")
fig.text(0.5, 0.006,
         "1 parameter = 1 Prometheus series; a module is one unit Prometheus scrapes "
         "(a readout board or per-DTC aggregation point), and it exposes many parameters",
         ha="center", fontsize=8.3, color="#777")
fig.savefig(os.path.join(R, "suite.png"), bbox_inches="tight")
print("-> results/suite.png")
