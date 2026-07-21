# Test suite: real CMS Tracker numbers

Every test is anchored to the real board model, not synthetic round numbers.

## The parameter model

**The metrics exposer runs on the readout board/DTC**, so in Prometheus terms **one board =
one scrape target**, and **one parameter = one series = one value per 1 Hz cycle**.

Confirmed building blocks:

| Subsystem | Composition | Params |
|---|---|---|
| **Inner Tracker (IT)** | 14,088 chips x 35 = 493,080; 4,416 modules x 12 = 52,992; + port-card / cooling-loop / HV-sector / serial-power blocks ~19,000 | **~565,000** |
| **Outer Tracker (OT)** | 13,296 modules x ~20 ~ 266,000; ~150 boards x ~100 ~ 15,000; + further OT board/infra blocks ~34,000 [A] | **~315,000** |
| **Combined per cycle** | | **~880,000** ("approaches ~1 million") |

IT carries **~64%** of the parameters (was ~86% in the old model). Rolled up to the scrape
target (board = subsystem total / board count): **OT ~2,100/board** (315,000 / ~150),
**IT ~11,300/board** (565,000 / ~50). An IT board is **~5.4x** an OT board (was ~21x), so the
Inner Tracker still sets the per-node limit, less extremely than before.

Full-detector projection (`common.sh`): **~150 OT + ~50 IT = ~200 targets**,
`150x2,100 + 50x11,300 = 880,000` params ~ **0.88M**. At natural board-level aggregation the
densest target (~11,300) sits at ~1/3 of the laptop per-target wall, so the real detector **fits
with headroom** - the wall only bites when aggregation coarsens or density grows.

These are constants at the top of `config/common.sh` (`OT_PER_BOARD`, `IT_PER_BOARD`,
`OT_BOARDS`, `IT_BOARDS`) - change one number if a count is revised and every test and
plot follows. **[D]** `IT_BOARDS` (readout DTC count) is the one unconfirmed number that sets
IT per-target density (the scrape wall); ~50 is derived from OT's ~89 modules/board and is not
yet confirmed. The cadence is fixed everywhere: `scrape_interval 1s`, `scrape_timeout 900ms`.

## Baseline suite (single node, co-located) - `scenarios/baseline/`

| Test | What varies | Range / mixture | Why |
|---|---|---|---|
| **cms** | fixed configs | `ot_only` (~150 OT / ~315k), `it_only` (~50 IT / ~565k), `full` (~200 / ~880k) | The three headline points. `full` is the real detector; the split shows IT carries ~64% at ~5.4x density. |
| **modules** | whole detector, scaled | 0.25x -> 2x real (~50 -> ~400 boards, ~220k -> ~1.76M), OT:IT ratio held | Capacity curve: does the real ~880k load fit in the 1 s budget, and how much headroom? |
| **ramp** | IT boards, on a fixed ~150-OT base | 0 -> 70 IT boards (~315k -> ~1.10M); real count = 50 | The IT boards are the heavy unit (~11,300 each) - find where adding them first breaks the budget. |
| **sweep** | OT:IT **mixture**, target count fixed | ~200 targets, redistribute ~880k between light OT (~2,100) and dense IT (~11,300) | Same target count, very different per-target density -> proves the limit is density, not #targets. |
| **stress** | whole detector, past 1x | 1x, 1.5x, 2x, 3x real (~880k -> ~2.64M); split *more targets* vs *denser targets* | Find the single-node ceiling **C**; report the last healthy multiple of the real detector. |
| **spike** | detector powered by **section** | 0 -> 6 OT sections -> 3 IT sections (full) -> back down, one section per step (`OT_SECTIONS`, `IT_SECTIONS`, `DESCEND`) | Real bring-up/trip granularity (~6 OT + ~3 IT sections, each ~equally populated). The transient is a section toggling while Prometheus keeps scraping, not an all-or-nothing IT jump - measures the scrape hit + recovery at every partial-detector level. |
| **soak** | none (hold real detector) | ~200 boards / ~880k for `DURATION` | Watch memory creep / scrape drift at the true operating point. |

Every scenario takes env overrides (`SCALES`, `IT_STEPS`, `IT_MIX`, `OT`, `IT`, ...) so a
small local smoke run is cheap; defaults are the real numbers above.

### What each sample records

`common.sh:sample()` (and the remote `prometheus/measure.sh`) emit one CSV fragment per
measurement. Two columns are worth calling out:

- **`max_scrape_s`** - the **windowed** worst scrape time, `max_over_time(max(scrape_duration_
  seconds{job="modules"})[$WIN:1s])` (`WIN=30s`, held <= `SETTLE` so the subquery always has
  data). A single instant read could miss a transient overrun during the settle window; the
  window catches it.
- **`cadence_p99_s`** (trailing column) - `max(prometheus_target_interval_length_seconds{quantile
  ="0.99"})`, the p99 **actual gap between scrape cycles**. This is the real "keeping up at
  1 Hz?" signal: **> ~1.05 s means 1 Hz is already slipping even if the per-scrape time still
  looks fine**. `plot_cms.py` and `plot_suite.py` flag such a point (red / red ring) even when
  its scrape time is under budget - that is the whole reason the column exists.

### TSDB location (`TSDB_ROOT`)

The head block and on-disk blocks live under `$TSDB_ROOT/tsdb` (default `$TSDB_ROOT=$NATIVE`,
i.e. the repo's gitignored `.native-data`, matching the previous behaviour). **On the HPC set
`TSDB_ROOT` to node-local scratch (`/tmp`, a local NVMe) - never Lustre/GPFS/NFS**: the TSDB's
fsync-heavy write path degrades badly on a networked filesystem and the measured footprint
stops meaning anything. It is deliberately **not** defaulted to `/dev/shm`, because tmpfs would
consume the very RAM this harness is measuring. `warn_if_network_fs()` runs `stat -f` at bringup
and prints a one-line warning if `TSDB_ROOT` resolves to an nfs/lustre/gpfs/fuse filesystem.

### Soak compaction knob (`MIN_BLOCK`, `RETENTION`)

`soak.sh` normally just holds the head block. Set `MIN_BLOCK` (e.g. `MIN_BLOCK=5m`) to force
Prometheus to cut and compact blocks on a short cadence so even a brief soak exercises the
compactor; `RETENTION` caps on-disk history. The soak CSV then carries a **`blocks`** column
(`prometheus_tsdb_compactions_total`) that rises each time a block is compacted out of the head.
Caveat: `--storage.tsdb.min/max-block-duration` are hidden/undocumented flags in Prometheus 3.13
(`--help-long` still accepts them) - **off by default, opt-in only**.

## Two-node suite (SSH-orchestrated) - `scenarios/`

Load generators and Prometheus live on **separate machines**, so the collector's CPU/RAM is
the true, uncontended per-node footprint. Both use the real mixed load: `topology.sh`
`gen_series()` emits 820 for the first 180 boards and 17,500 for the next 50, in the same
order `gen_targets()` places them, and each load host launches its slice with the real
per-board series counts.

- **twin** - 2 collectors each scrape the full 230-board real detector as independent
  replicas -> validates 1 primary + 1 hot standby.
- **shard** - the 230 boards split into K disjoint shards (K in {1,2,4,8}), one Prometheus
  each -> per-node load falls ~1/K, which sizes `shards = total / (C x 0.55)`.

## Real-hardware test - `scenarios/hardware.sh`

No Avalanche: Prometheus scrapes the **real board exporters** listed in `config/targets.real`.
The exposers run on the boards' own hardware, so the collector is already uncontended. This
is the bench validation of the synthetic curve - start with the handful of real boards
available and re-run as more come online (the plot becomes a small real-hardware sweep).

## Pull-vs-push diagnostic - `scenarios/baseline/push.sh` (opt-in, `RUN_PUSH=1`)

Self-contained and **not part of the core pull sweep** - it doesn't touch the pull suite's
schema. It answers *what* the single-node wall is. The pull suite hits a ceiling because every
scrape must finish inside the 1 s tick; **push (`remote_write`) removes that per-scrape deadline
entirely**. The same synthetic fleet runs in remote-write mode (`start_push`, OT boards then IT
at 1 Hz) against a Prometheus launched with `--web.enable-remote-write-receiver` and **no
`modules` scrape job** (`write_config 0`, server self-scrape only). There is no
`scrape_duration` to read, so the "keeping up at 1 Hz" signal becomes
`rate(prometheus_tsdb_head_samples_appended_total[$WIN])` vs the expected params/s (1 sample per
series per second), plus `head_series` / CPU / RAM. Own CSV `data/push.csv`
(`label,params,expected_per_s,appended_per_s,head_series,memory_bytes,cpu_pct,ram_pct`);
`analysis/plot_push.py` renders ingest/s against the ~1.02M-samples/s target and greens when
push sustains what pull walled on.

**Framing (DESIGN.md §5):** this is the pull-vs-push lever - it proves the wall is the 1 s pull
deadline, not the machine. It is ranked **below** the VictoriaMetrics head-to-head the design
note calls the decision-changer, and it is **not a deployment recommendation**: boards today
expose `/metrics`, and push is still an open `[D]`. Wired into `run_all.sh` only behind
`RUN_PUSH=1`.
