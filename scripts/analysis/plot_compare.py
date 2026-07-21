#!/usr/bin/env python3
"""Overlay the laptop and HPC (Xeon 4514Y) scaling pretests on the SAME axes, one panel per
metric (Prometheus RAM/CPU, avalanche RAM/CPU), to see HOW the two machines differ:

  * If the two fit lines COINCIDE, the resource is machine-independent (same bytes/series or
    same core-seconds/series regardless of hardware) - the slope is a property of the workload.
  * If they share a slope but offset, it's a fixed per-machine overhead.
  * If the SLOPES differ, the per-unit cost itself is hardware-dependent - for CPU that is the
    per-core clock/IPC (a slow 2.0 GHz server core needs more core-seconds for the same work).

CPU is converted to ABSOLUTE cores with each box's own core count (laptop 16, HPC 32), so the
comparison is cores-vs-cores, not %-vs-% of differently sized machines. RAM is already absolute.
Fit uses only CLEAN points (scrape < 0.9 s AND host < 75% CPU); see plot_pretest.py for why the
pretest status column (cadence_p99) is not trusted. Lines extrapolate to the 3M-param test.
"""
import os
import numpy as np
import matplotlib.pyplot as plt
from lib import rows, num, kfmt, save

REAL, TEST = 880_000, 3_000_000
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})

# (label, csv, cores, color)
MACHINES = [
    ("laptop",            "pretest.csv",     16, "#3a86ff"),
    ("HPC (Xeon 4514Y)",  "pretest_hpc.csv", 32, "#e76f51"),
]


def is_clean(x):
    d = num(x.get("max_scrape_s")); h = num(x.get("host_cpu"))
    return d is not None and d < 0.9 and (h is None or h < 75)


def fit(data, ycol, yscale):
    x = np.array([num(d["head_series"]) for d in data], float)
    y = np.array([num(d[ycol]) * yscale for d in data], float)
    m, b = np.polyfit(x, y, 1)
    return dict(x=x, y=y, m=m, b=b)


# each metric: (ycol, per-machine yscale factory, unit, title)
def gb(_cores):     return 1 / 2**30
def cores(c):       return c / 100

METRICS = [
    ("memory_bytes", gb,    "GB",    "Prometheus RAM (metric RSS)"),
    ("cpu_pct",      cores, "cores", "Prometheus CPU (absolute cores)"),
    ("av_rss",       gb,    "GB",    "avalanche RAM (load generator)"),
    ("av_cpu",       cores, "cores", "avalanche CPU (absolute cores)"),
]

data = {lbl: [x for x in rows(csvf) if is_clean(x)] for lbl, csvf, _, _ in MACHINES}

fig, axs = plt.subplots(2, 2, figsize=(14, 10.5))
xs = np.linspace(0, TEST * 1.03, 200)

for ax, (ycol, yscf, unit, title) in zip(axs.flat, METRICS):
    fits = {}
    for lbl, csvf, c, color in MACHINES:
        d = data[lbl]
        ys = yscf(c)
        f = fit(d, ycol, ys)
        fits[lbl] = (f, color, c)
        ax.scatter(f["x"], f["y"], s=30, color=color, edgecolor="white", lw=0.5, zorder=4,
                   label=lbl)
        ax.plot(xs, f["m"] * xs + f["b"], color=color, lw=1.7, zorder=3)
        yh880 = f["m"] * REAL + f["b"]; yh3 = f["m"] * TEST + f["b"]
        ax.annotate(f"{yh3:.1f}", xy=(TEST, yh3), xytext=(TEST * 0.845, yh3),
                    fontsize=9, color=color, weight="bold", va="center")
    # slope callout: plain measured rates + their ratio (this is the comparison, not inference)
    (fl, _, _), (fh, _, _) = fits["laptop"], fits["HPC (Xeon 4514Y)"]
    ratio = fh["m"] / fl["m"]
    txt = (f"laptop:  {fl['m']*1e6:6.1f} {unit}/1M\n"
           f"HPC:     {fh['m']*1e6:6.1f} {unit}/1M\n"
           f"HPC / laptop = {ratio:.1f}$\\times$")
    ax.text(0.03, 0.97, txt, transform=ax.transAxes, va="top", ha="left", fontsize=8.6,
            family="monospace",
            bbox=dict(boxstyle="round", fc="white", ec="#888", alpha=0.92))
    for xv, lab in [(REAL, "880k"), (TEST, "3M")]:
        ax.axvline(xv, ls=":" if xv == REAL else "--", color="#aaa", lw=1)
    ax.set_title(title, loc="left", fontsize=11.5, weight="bold")
    ax.set_xlabel("active series (1 param = 1 series)")
    ax.set_ylabel(unit)
    ax.xaxis.set_major_formatter(kfmt)
    ax.set_xlim(0, TEST * 1.05); ax.set_ylim(bottom=0)
    ax.grid(alpha=0.25)
    ax.legend(loc="lower right", fontsize=8.5, framealpha=0.92)

fig.suptitle("Laptop vs HPC scaling - same axes  (real CMS OT:IT mix, clean uncontended points)",
             fontsize=14, y=0.997)
fig.text(0.5, 0.005,
         "RAM slopes coincide -> bytes/series is machine-independent (a workload property). "
         "CPU slopes diverge by ~2.2x -> cores/series is hardware-dependent (slow 2.0 GHz Xeon "
         "cores need more core-seconds for the same ingest). Size cores against the DEPLOYMENT CPU.",
         ha="center", fontsize=9, color="#555")
fig.tight_layout(rect=[0, 0.02, 1, 0.98])
save(fig, "pretest_compare.png")
