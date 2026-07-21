#!/usr/bin/env python3
"""Plot the real CMS Tracker model into graphs/cms.png: the three canonical configurations
(Outer-only, Inner-only, full detector) measured on one node at 1 Hz."""
import matplotlib.pyplot as plt
from lib import rows, num, kfmt, resources, save, OK, BAD, LINE

BUDGET = 1.0
CADENCE_MAX = 1.05   # p99 gap between scrape cycles above this = 1 Hz slipping even if scrape time is fine
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

r = rows("cms.csv")
if not r:
    print("no data/cms.csv yet - run scenarios/baseline/cms.sh first")
    raise SystemExit(0)

NAMES = {"ot_only": "Outer Tracker\n180 boards", "it_only": "Inner Tracker\n50 boards",
         "full": "Full detector\n230 boards"}
labels = [NAMES.get(x["config"], x["config"]) for x in r]
scr = [num(x["max_scrape_s"]) or BUDGET for x in r]
up = [num(x.get("modules_up")) for x in r]
tgt = [num(x["targets"]) for x in r]
par = [num(x["params"]) for x in r]
cad = [num(x.get("cadence_p99_s")) for x in r]
xs = list(range(len(r)))

fig, ax = plt.subplots(figsize=(8.5, 5.4))
for i, (s, u, t, p, c) in enumerate(zip(scr, up, tgt, par, cad)):
    slipping = c is not None and c > CADENCE_MAX   # 1 Hz cadence slipping even if per-scrape time is green
    ok = u is not None and t is not None and u >= t and s <= BUDGET and not slipping
    ax.bar(i, s, width=0.55, zorder=2, color=OK if ok else BAD)
    cad_note = f"\ncadence {c:.2f}s !!" if slipping else (f"\ncadence {c:.2f}s" if c is not None else "")
    ax.annotate(f"{s:.3f}s\n{int(u) if u is not None else '?'}/{int(t) if t else '?'} up\n"
                f"{kfmt(p) if p else '?'} params{cad_note}",
                xy=(i, s), xytext=(i, s + 0.02), ha="center", fontsize=8.3,
                color=BAD if slipping else "#333")
ax.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
ax.set_xticks(xs); ax.set_xticklabels(labels)
ax.set_ylabel("max scrape time (s)")
ax.set_ylim(0, max(BUDGET * 1.15, max(scr) * 1.35))
ax.grid(axis="y", alpha=0.25); ax.margins(x=0.1)
resources(ax, xs, r)

fig.suptitle("CMS Tracker at 1 Hz: real board model on a single node", fontsize=12.5)
fig.text(0.5, -0.02,
         "Real board counts: OT board = 72x10 + 100 = 820 params; IT board = 500x35 "
         "= 17,500 params; the exposer runs on the board, so 1 board = 1 scrape target.\n"
         "The Inner Tracker carries ~86% of the parameters from ~22% of the boards - it sets "
         "the per-node limit.\n"
         "green: all boards up, under the 1 s budget, and cadence <=1.05s    dashed: 1 s budget    "
         "'cadence N.NNs !!' = p99 scrape gap slipping past 1 Hz even if scrape time is green    "
         "purple: CPU %    blue: RAM %  (% of node)",
         ha="center", fontsize=8.3, color="#555")
save(fig, "cms.png")
