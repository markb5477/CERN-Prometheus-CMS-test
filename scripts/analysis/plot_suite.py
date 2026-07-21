#!/usr/bin/env python3
"""Plot the baseline single-node suite CSVs into graphs/suite.png (real CMS board model)."""
import textwrap
import matplotlib.pyplot as plt
from lib import rows, num, kfmt, resources, save, OK, BAD, LINE

BUDGET = 1.0
CADENCE_MAX = 1.05   # p99 gap between scrape cycles above this = 1 Hz slipping even if scrape time is fine
REAL = 880000   # the real detector: 150 OT x 2,100 + 50 IT x 11,300 (confirmed model, common.sh)
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})


def caption(ax, text, width=70):
    ax.text(0.0, -0.30, "\n".join(textwrap.wrap(text, width)), transform=ax.transAxes,
            va="top", ha="left", fontsize=8.3, color="#555")


def expected(rs):
    return [num(r.get("targets")) for r in rs]


def slipping(r):
    c = num(r.get("cadence_s") or r.get("cadence_p99_s"))
    return c is not None and c > CADENCE_MAX


def healthy(r, e):
    up = num(r.get("modules_up"))
    return up is not None and e is not None and up >= e and not slipping(r)


def scatter(ax, xs, rs):
    ys = [num(r["max_scrape_s"]) for r in rs]
    ax.plot(xs, [y if y else BUDGET for y in ys], color="#999", lw=1, zorder=1)
    for x, y, r, e in zip(xs, ys, rs, expected(rs)):
        yy = y if y else BUDGET
        ax.scatter(x, yy, s=70, zorder=3,
                   color=OK if healthy(r, e) else BAD, edgecolor="white", linewidth=1)
        # ring a point whose scrape time is fine but whose 1 Hz cadence is slipping - the whole
        # point of the cadence column: a green scrape time can still miss the tick.
        if slipping(r) and (y is None or y <= BUDGET):
            ax.scatter(x, yy, s=190, zorder=2, facecolors="none",
                       edgecolors=BAD, linewidths=1.6)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    ax.set_ylabel("scrape time (s)")
    ax.grid(axis="y", alpha=0.25); ax.margins(x=0.06)
    resources(ax, xs, rs)


fig = plt.figure(figsize=(11, 13.5))
gs = fig.add_gridspec(3, 2, height_ratios=[1.25, 1, 1], hspace=0.85, wspace=0.24)

# capacity curve, full width on top
r = rows("modules.csv")
if r:
    ax = fig.add_subplot(gs[0, :])
    xs = [num(x["params"]) for x in r]
    scatter(ax, xs, r)
    ax.axvline(REAL, ls=":", color="#888", lw=1)
    ax.annotate("real detector\n~0.88M", xy=(REAL, BUDGET * 0.5), fontsize=8.5, color="#555")
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlabel("total parameters (real 150:50 OT:IT ratio held at each point)")
    for x, row, e in zip(xs, r, expected(r)):
        if not healthy(row, e):
            ax.annotate("scrape > budget", xy=(x, BUDGET), xytext=(x, BUDGET - 0.4),
                        ha="center", fontsize=9, color=BAD,
                        arrowprops=dict(arrowstyle="->", color=BAD))
            break
    ax.set_title("capacity curve: scale the whole real detector", loc="left",
                 fontsize=11.5, weight="bold")
    caption(ax, "The real detector (150 OT boards x 2,100 + 50 IT boards x 11,300 = ~0.88M "
                "params over 200 targets) scaled 0.25x to 2x, keeping the true OT:IT ratio. "
                "Idea: confirm the real ~0.88M load scrapes inside the 1 s budget and show the headroom.",
            width=95)


def panel(cell, name, xcol, title):
    r = rows(name)
    if not r:
        return None, None
    ax = fig.add_subplot(cell)
    xs = [num(x[xcol]) for x in r]
    scatter(ax, xs, r)
    ax.set_title(title, loc="left", fontsize=10)
    return ax, r


ax, r = panel(gs[1, 0], "ramp.csv", "params", "ramp: Inner Tracker coming online")
if ax:
    ax.axvline(REAL, ls=":", color="#888", lw=1)
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlabel("total parameters")
    caption(ax, "Fixed 150-OT base; Inner-Tracker boards added 0 -> 70 (real count 50). Each "
                "IT board adds 11,300 params, so scrape time climbs in big steps. Idea: find "
                "where adding IT boards first breaks the 1 s budget.")

ax, r = panel(gs[1, 1], "sweep.csv", "it_boards", "mixture (200 boards fixed)")
if ax:
    ax.set_xlabel("Inner-Tracker boards (of 200)")
    caption(ax, "Board count held at the real 200; IT share swept 0 -> 200 (real detector = "
                "50 IT). Same targets, wildly different load, because an IT board is 5.4x an OT "
                "board. Idea: show the limit is the OT:IT mixture, not the target count.")

ax, r = panel(gs[2, 0], "stress.csv", "params", "stress: past the real detector")
if ax:
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlabel("total parameters")
    caption(ax, "Real mix scaled 1x -> 3x (~0.88M -> ~2.64M params). Idea: find the single-node "
                "ceiling and the last healthy multiple of the real detector.")

# spike: bar per phase
r = rows("spike.csv")
if r:
    ax = fig.add_subplot(gs[2, 1])
    ys = [num(x["max_scrape_s"]) or BUDGET for x in r]
    for i, x in enumerate(r):
        up = num(x.get("modules_up")); e = num(x.get("targets"))
        ok = up is not None and e is not None and up >= e and not slipping(x)
        ax.bar(i, ys[i], width=0.6, zorder=2, color=OK if ok else BAD)
        if slipping(x):
            ax.annotate("cadence\nslipping", xy=(i, ys[i]), xytext=(i, ys[i]),
                        ha="center", va="bottom", fontsize=7.5, color=BAD)
    ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    n = len(r)
    rot = 90 if n > 6 else 0
    fs = 6 if n > 12 else (7 if n > 6 else 8)
    ax.set_xticks(range(n))
    ax.set_xticklabels([x["phase"].replace("_", "\n") for x in r], rotation=rot, fontsize=fs)
    ax.set_ylabel("scrape time (s)"); ax.grid(axis="y", alpha=0.25)
    resources(ax, list(range(n)), r)
    ax.set_title("spike: power-on/off by section", loc="left", fontsize=10)
    caption(ax, "Detector powered by SECTION (6 OT + 3 IT): 0 -> all OT -> all IT (full) "
                "-> back down, one section per step (+OTn on, -ITn off). Idea: the real transient "
                "is a section toggling while Prometheus scrapes - measure the hit and recovery at "
                "every partial-detector level, not just an all-or-nothing IT jump.")

fig.suptitle("Prometheus 1 Hz scrape tests - real CMS board model (single-node baseline)",
             fontsize=13, y=0.995)
fig.text(0.5, 0.020,
         "green: all boards up    red: scrape over budget, a target dropped, or cadence slipping    "
         "red ring: scrape time OK but p99 cadence >1.05s (1 Hz slipping)    dashed: 1 s budget    "
         "purple: CPU %    blue: RAM %  (right axis, % of node)",
         ha="center", fontsize=9.5, color="#444")
fig.text(0.5, 0.006,
         "1 parameter = 1 Prometheus series; the exposer runs on the board, so 1 board = 1 scrape "
         "target. OT board = 2,100 params, IT board = 11,300 params.",
         ha="center", fontsize=8.3, color="#777")
save(fig, "suite.png")
