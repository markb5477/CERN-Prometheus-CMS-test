#!/usr/bin/env python3
"""Plot the DIST pilot (ramp_dist.csv + soak_dist.csv) and project the ORACLE sizing.

Three figures:
  dist_ramp.png       scaling vs parameter count, with fits extrapolated to the limits
  dist_soak.png       the soak timeline: scrape/cadence, memory, and the storage saw-tooth
  dist_projection.png what to ask ORACLE for, at the real detector and with growth margin

Unlike the baseline plots these come from a two-node run: Prometheus alone on the collector,
load generated elsewhere, so cpu_pct/ram_pct are an uncontended per-node footprint.

Env: PARAMS (real detector size, default 880000), COLL_CORES (collector cores, default 32),
     BLOCK_SECS (soak block period, default 900 = MIN_BLOCK=15m),
     SOAK_CSV / RAMP_CSV (which file to read - the scenarios archive previous runs under a
     timestamp, so point SOAK_CSV at the MIN_BLOCK run to get bytes/sample and at the
     default-block run to get the true memory curve).
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from lib import rows, num, kfmt, save, OK, BAD, LINE, CPUC, RAMC

PARAMS = float(os.environ.get("PARAMS", 880_000))
CORES = float(os.environ.get("COLL_CORES", 32))
BLOCK_SECS = float(os.environ.get("BLOCK_SECS", 900))
SOAK_CSV = os.environ.get("SOAK_CSV", "soak_dist.csv")
RAMP_CSV = os.environ.get("RAMP_CSV", "ramp_dist.csv")
BUDGET = 0.9          # scrape_timeout: an overrun is a dropped sample
CADENCE_MAX = 1.05
plt.rcParams.update({"figure.dpi": 130, "font.size": 10})


def col(rs, name):
    return [num(r.get(name)) for r in rs]


def fit_cross(x, y, target, deg):
    """Least-squares fit of degree `deg`, solved for the smallest x > max(x) where it hits
    `target`. Returns (poly, crossing or None)."""
    if len(x) <= deg:
        return None, None
    p = np.polyfit(x, y, deg)
    roots = np.roots(np.polyval(p, [1]) * 0 + (p - np.eye(1, deg + 1, deg)[0] * target))
    real = sorted(r.real for r in roots if abs(r.imag) < 1e-6 and r.real > max(x))
    return p, (real[0] if real else None)


# ---------------------------------------------------------------- ramp
def plot_ramp():
    r = [x for x in rows(RAMP_CSV) if x.get("status") == "ok"]
    if len(r) < 2:
        print(f"no usable data/{RAMP_CSV} (need >=2 rows with status=ok) - skipping ramp")
        return None
    par = np.array(col(r, "params"), dtype=float)
    scr = np.array(col(r, "max_scrape_s"), dtype=float)
    cpu = np.array(col(r, "cpu_pct"), dtype=float)
    mem = np.array([(m or 0) / 2**30 for m in col(r, "memory_bytes")], dtype=float)

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 5.2))

    # -- scrape time, the binding constraint: it curves, so fit quadratic when we can
    deg = 2 if len(par) >= 4 else 1
    p_s, cross = fit_cross(par, scr, BUDGET, deg)
    a1.plot(par, scr, "o-", color=OK, lw=1.6, ms=5, zorder=3, label="measured")
    if p_s is not None:
        hi = cross * 1.05 if cross else par.max() * 2
        xs = np.linspace(par.min(), hi, 200)
        a1.plot(xs, np.polyval(p_s, xs), "--", color="#888", lw=1.2,
                label=f"fit (deg {deg}), extrapolated")
    a1.axhline(BUDGET, ls="--", color=LINE, lw=1.3)
    a1.annotate(f"{BUDGET}s scrape_timeout", xy=(par.min(), BUDGET), xytext=(0, 4),
                textcoords="offset points", fontsize=8, color=LINE)
    a1.axvline(PARAMS, ls=":", color="#444", lw=1.1)
    a1.annotate("real detector", xy=(PARAMS, 0), xytext=(3, 6), textcoords="offset points",
                fontsize=8, color="#444", rotation=90)
    if cross:
        a1.axvline(cross, ls=":", color=BAD, lw=1.4)
        a1.annotate(f"projected ceiling\n{cross/1e6:.2f}M params\n({cross/PARAMS:.1f}x detector)",
                    xy=(cross, BUDGET), xytext=(-8, -40), textcoords="offset points",
                    fontsize=8.5, color=BAD, ha="right")
    a1.set_xlabel("parameters (series scraped per second)")
    a1.set_ylabel("max scrape time (s)")
    a1.set_title("Scrape time is the binding constraint", fontsize=11)
    a1.grid(alpha=0.25); a1.legend(fontsize=8, loc="upper left")
    a1.xaxis.set_major_formatter(plt.FuncFormatter(kfmt))

    # -- CPU and RAM, both linear in this range
    p_c = np.polyfit(par, cpu, 1)
    xs = np.linspace(0, max(par.max() * 1.6, PARAMS * 2), 100)
    a1b = None
    a2.plot(par, cpu, "o-", color=CPUC, lw=1.6, ms=5, label="CPU % of node")
    a2.plot(xs, np.polyval(p_c, xs), "--", color=CPUC, lw=1, alpha=0.5)
    a2.set_xlabel("parameters (series scraped per second)")
    a2.set_ylabel("Prometheus CPU (% of collector node)", color=CPUC)
    a2.tick_params(axis="y", colors=CPUC)
    a2.xaxis.set_major_formatter(plt.FuncFormatter(kfmt))
    a2.grid(alpha=0.25)
    a2b = a2.twinx()
    a2b.plot(par, mem, "s-", color=RAMC, lw=1.6, ms=4, label="RSS (GiB)")
    a2b.set_ylabel("Prometheus resident memory (GiB)", color=RAMC)
    a2b.tick_params(axis="y", colors=RAMC)
    a2.axvline(PARAMS, ls=":", color="#444", lw=1.1)
    cores_at = np.polyval(p_c, PARAMS) / 100 * CORES
    a2.set_title(f"CPU is linear: {cores_at:.1f} cores at the real detector", fontsize=11)
    a2.legend(fontsize=8, loc="upper left")
    a2b.legend(fontsize=8, loc="lower right")

    fig.suptitle("CMS Tracker at 1 Hz - distributed pilot: scaling on one collector node",
                 fontsize=12.5)
    fig.text(0.5, -0.04,
             "Prometheus runs alone on the collector; load is generated on separate hosts, so "
             "CPU/RAM here are a true uncontended per-node footprint.\n"
             "Only rows with status=ok are plotted - a LOAD_SATURATED step measures the "
             "generator, not Prometheus. RAM is measured 45 s after start and is a FLOOR, "
             "not steady state (see the soak).",
             ha="center", fontsize=8.3, color="#555")
    save(fig, "dist_ramp.png")
    return {"cores_at_detector": cores_at, "scrape_ceiling": cross, "cpu_fit": p_c}


# ---------------------------------------------------------------- soak
def plot_soak():
    r = [x for x in rows(SOAK_CSV) if (num(x.get("elapsed_s")) or 0) > 0]
    if len(r) < 3:
        print(f"no usable data/{SOAK_CSV} - skipping soak")
        return None
    t = np.array(col(r, "elapsed_s"), dtype=float) / 60.0     # minutes
    scr = np.array(col(r, "max_scrape_s"), dtype=float)
    cad = np.array(col(r, "cadence_s"), dtype=float)
    mem = np.array([(m or 0) / 2**30 for m in col(r, "memory_bytes")], dtype=float)
    blk = np.array([(b or 0) / 2**30 for b in col(r, "block_bytes")], dtype=float)
    hb = np.array([(b or 0) / 2**30 for b in col(r, "head_bytes")], dtype=float)
    wb = np.array([(b or 0) / 2**30 for b in col(r, "wal_bytes")], dtype=float)
    comp = np.array([c or 0 for c in col(r, "compactions")], dtype=float)
    cuts = [t[i] for i in range(1, len(comp)) if comp[i] > comp[i - 1]]

    fig, (a1, a2, a3) = plt.subplots(3, 1, figsize=(11, 10), sharex=True)

    a1.plot(t, scr, color=OK, lw=1.4, label="max scrape (s)")
    a1.axhline(BUDGET, ls="--", color=LINE, lw=1.2)
    a1b = a1.twinx()
    a1b.plot(t, cad, color="#444", lw=1.2, label="cadence (s)")
    a1b.axhline(CADENCE_MAX, ls=":", color=BAD, lw=1)
    a1b.set_ylabel("scrape cadence (s)", fontsize=9)
    a1b.set_ylim(0.9, max(CADENCE_MAX * 1.02, float(np.nanmax(cad)) * 1.02))
    a1.set_ylabel("max scrape time (s)")
    a1.set_ylim(0, max(BUDGET * 1.15, float(np.nanmax(scr)) * 1.2))
    a1.set_title("Scrape health holds flat for the whole soak", fontsize=11)
    a1.grid(alpha=0.25); a1.legend(fontsize=8, loc="upper left")
    a1b.legend(fontsize=8, loc="upper right")

    a2.plot(t, mem, color=RAMC, lw=1.6)
    a2.set_ylabel("Prometheus RSS (GiB)")
    a2.set_title("Memory: the head block grows until it is cut", fontsize=11)
    a2.grid(alpha=0.25)

    a3.stackplot(t, blk, hb, wb, labels=["blocks (compacted)", "head chunks", "WAL"],
                 colors=["#2a9d8f", "#8ecae6", "#ffb703"], alpha=0.9)
    a3.set_ylabel("on-disk (GiB)")
    a3.set_xlabel("elapsed (minutes)")
    a3.set_title("Storage: WAL dominates until compaction converts it to blocks", fontsize=11)
    a3.grid(alpha=0.25); a3.legend(fontsize=8, loc="upper left")

    for ax in (a1, a2, a3):
        for c in cuts:
            ax.axvline(c, ls=":", color=BAD, lw=1.1, alpha=0.8)
    if cuts:
        a2.annotate("compaction", xy=(cuts[0], float(np.nanmax(mem))), xytext=(4, -10),
                    textcoords="offset points", fontsize=8, color=BAD)

    fig.suptitle("CMS Tracker at 1 Hz - distributed soak at the real detector", fontsize=12.5)
    fig.text(0.5, 0.005,
             "Dotted red verticals mark compactions. The first sample is dropped: it is taken "
             "before settling and its window still contains target discovery.\n"
             "bytes/sample is only meaningful across a compaction - the running "
             "(blocks+head+WAL)/samples figure is mostly WAL and reads ~7 at every load.",
             ha="center", fontsize=8.3, color="#555")
    save(fig, "dist_soak.png")
    return bytes_per_sample(r)


def bytes_per_sample(r):
    """Recover the WAL-free cost per sample from the soak.

    Two independent estimates, because each has a different weakness:
      step  - delta(block_bytes) across one compaction / (params * BLOCK_SECS). Exact only for
              blocks that span a full period, so the FIRST block is dropped: Prometheus aligns
              block boundaries to wall-clock multiples and block 1 covers a partial span.
      slope - least-squares slope of block_bytes against samples_appended over the whole run.
              Needs no assumption about block duration at all, but wants >=2 compactions.
    """
    blk = [num(x.get("block_bytes")) or 0 for x in r]
    sa = [num(x.get("samples_appended")) or 0 for x in r]
    comp = [num(x.get("compactions")) or 0 for x in r]
    steps, n = [], 0
    for i in range(1, len(comp)):
        if comp[i] > comp[i - 1]:
            n += 1
            if n > 1 and blk[i] > blk[i - 1]:
                steps.append((blk[i] - blk[i - 1]) / (PARAMS * BLOCK_SECS))
    slope = None
    if n >= 2:
        x, y = np.array(sa, dtype=float), np.array(blk, dtype=float)
        m = x > 0
        if m.sum() >= 3:
            slope = float(np.polyfit(x[m], y[m], 1)[0])
    return {"steps": steps, "slope": slope, "n_compactions": n}


# ---------------------------------------------------------------- projection
def plot_projection(ramp, soak):
    bps = None
    if soak:
        if soak["steps"]:
            bps = float(np.mean(soak["steps"]))
        elif soak["slope"] and soak["slope"] > 0:
            bps = soak["slope"]

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(13, 5.2))

    # -- storage vs retention, the dominant cost
    if bps:
        per_day = bps * PARAMS * 86400 / 1e12          # TB/day
        rets = np.array([7, 30, 90, 180, 365], dtype=float)
        need = per_day * rets
        bars = a1.bar([str(int(x)) for x in rets], need, color=OK, zorder=2, width=0.6)
        for b, v in zip(bars, need):
            a1.annotate(f"{v:.1f} TB", xy=(b.get_x() + b.get_width() / 2, v),
                        xytext=(0, 3), textcoords="offset points", ha="center", fontsize=9)
        a1.set_xlabel("retention (days)")
        a1.set_ylabel("storage required (TB)")
        a1.set_title(f"Storage at {kfmt(PARAMS)} params, 1 Hz\n"
                     f"{bps:.2f} bytes/sample -> {per_day*1000:.0f} GB/day", fontsize=11)
        a1.grid(axis="y", alpha=0.25)
    else:
        a1.text(0.5, 0.5, "no compaction measured yet\nrun the soak past a second block cut",
                ha="center", va="center", fontsize=10, color=BAD)
        a1.set_axis_off()

    # -- compute headroom
    if ramp:
        labels = ["CPU\n(cores)", "scrape time\n(s)"]
        used = [ramp["cores_at_detector"], None]
        cap = [CORES, BUDGET]
        r0 = [x for x in rows(RAMP_CSV) if x.get("status") == "ok"]
        at = min(r0, key=lambda x: abs((num(x["params"]) or 0) - PARAMS)) if r0 else None
        used[1] = num(at.get("max_scrape_s")) if at else 0
        xs = np.arange(len(labels))
        a2.bar(xs - 0.19, [u / c * 100 for u, c in zip(used, cap)], width=0.36,
               color=OK, label="used at real detector", zorder=2)
        a2.bar(xs + 0.19, [100] * len(labels), width=0.36, color="#ddd",
               label="capacity", zorder=1)
        for i, (u, c) in enumerate(zip(used, cap)):
            a2.annotate(f"{u:.2f} / {c:g}\n({c/u:.1f}x headroom)", xy=(i - 0.19, u / c * 100),
                        xytext=(0, 4), textcoords="offset points", ha="center", fontsize=8.5)
        a2.set_xticks(xs); a2.set_xticklabels(labels)
        a2.set_ylabel("% of capacity")
        a2.set_ylim(0, 125)
        a2.set_title("Compute headroom on one collector node", fontsize=11)
        a2.grid(axis="y", alpha=0.25); a2.legend(fontsize=8)

    fig.suptitle("CMS Tracker at 1 Hz - what to request from ORACLE", fontsize=12.5)
    fig.text(0.5, -0.04,
             "Storage is the dominant cost and grows without bound at 1 Hz - retention policy "
             "is the decision that sets it.\n"
             "Avalanche's synthetic values compress far worse under Gorilla XOR than real "
             "slowly-varying detector telemetry, so bytes/sample here is an UPPER BOUND.",
             ha="center", fontsize=8.3, color="#555")
    save(fig, "dist_projection.png")
    return bps


if __name__ == "__main__":
    ramp = plot_ramp()
    soak = plot_soak()
    bps = plot_projection(ramp, soak)

    print("\n=== projection " + "=" * 50)
    if ramp:
        print(f"  CPU at {kfmt(PARAMS)} params : {ramp['cores_at_detector']:.2f} cores "
              f"of {CORES:g} ({ramp['cores_at_detector']/CORES*100:.1f}%)")
        if ramp["scrape_ceiling"]:
            print(f"  scrape-time ceiling      : {kfmt(ramp['scrape_ceiling'])} params "
                  f"({ramp['scrape_ceiling']/PARAMS:.1f}x the real detector)")
    if soak:
        print(f"  compactions seen         : {soak['n_compactions']}")
        if soak["steps"]:
            print(f"  bytes/sample (per block) : "
                  f"{', '.join(f'{s:.3f}' for s in soak['steps'])}")
        if soak["slope"]:
            print(f"  bytes/sample (regression): {soak['slope']:.3f}")
    if bps:
        gb = bps * PARAMS * 86400 / 1e9
        print(f"  storage                  : {gb:.0f} GB/day, {gb*365/1000:.1f} TB/year")
    print("=" * 65)
