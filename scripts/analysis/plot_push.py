#!/usr/bin/env python3
"""Plot the pull-vs-push diagnostic into graphs/push.png: samples/s Prometheus actually ingests
via remote_write vs the expected 1-sample-per-series-per-second target, for the three canonical
configs. Green where push sustains the full rate (the wall the pull suite hit was the 1 s scrape
deadline, not the machine). Skips gracefully if data/push.csv doesn't exist (RUN_PUSH opt-in)."""
import matplotlib.pyplot as plt
from lib import rows, num, kfmt, save, OK, BAD, LINE

plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

r = rows("push.csv")
if not r:
    print("no data/push.csv yet - run RUN_PUSH=1 scenarios/baseline/push.sh first")
    raise SystemExit(0)

NAMES = {"ot_only": "Outer Tracker\n180 boards", "it_only": "Inner Tracker\n50 boards",
         "full": "Full detector\n230 boards"}
labels = [NAMES.get(x["label"], x["label"]) for x in r]
appended = [num(x.get("appended_per_s")) or 0.0 for x in r]
expected = [num(x.get("expected_per_s")) or 0.0 for x in r]
xs = list(range(len(r)))

fig, ax = plt.subplots(figsize=(8.5, 5.4))
for i, (a, e) in enumerate(zip(appended, expected)):
    # "sustaining" = ingesting within 5% of the expected 1 Hz sample rate
    ok = e > 0 and a >= 0.95 * e
    ax.bar(i, a, width=0.55, zorder=2, color=OK if ok else BAD)
    ax.annotate(f"{kfmt(a)}/s\nof {kfmt(e)}/s", xy=(i, a), xytext=(i, a),
                ha="center", va="bottom", fontsize=8.3, color="#333")
    ax.plot([i - 0.32, i + 0.32], [e, e], color=LINE, lw=1.6, zorder=3)

# the real-detector target line (~1.02M samples/s across the full push fleet)
full_e = next((num(x.get("expected_per_s")) for x in r if x.get("label") == "full"), None)
if full_e:
    ax.axhline(full_e, ls="--", color="#888", lw=1)
    ax.annotate(f"full-detector target ~{kfmt(full_e)}/s", xy=(0, full_e),
                xytext=(0, full_e), fontsize=8.5, color="#555", va="bottom")

ax.set_xticks(xs); ax.set_xticklabels(labels)
ax.set_ylabel("samples ingested per second (remote_write)")
ax.yaxis.set_major_formatter(kfmt)
ax.set_ylim(0, max(appended + expected) * 1.25)
ax.grid(axis="y", alpha=0.25); ax.margins(x=0.1)

fig.suptitle("Pull vs push: remote_write ingest at 1 Hz (diagnostic)", fontsize=12.5)
fig.text(0.5, -0.02,
         "Same synthetic fleet, PUSHED via remote_write instead of scraped. No per-scrape 1 s "
         "deadline, so ingest is bounded only by the box.\n"
         "green: sustains the full expected sample rate (>=95%)    red line per bar: expected "
         "1-sample/series/s    dashed: full-detector target.\n"
         "Diagnostic only - proves the pull wall is the 1 s deadline, not the machine. Ranked "
         "below the VictoriaMetrics head-to-head; not a deployment recommendation.",
         ha="center", fontsize=8.3, color="#555")
save(fig, "push.png")
