# Storage-tier test suite: warm retention -> cold transfer -> downsampling

Extends the ingest-only baseline. Tags: **[F]** measured; **[A]** assumption; **[D]** decision needed.

The baseline suite (`scenarios/baseline/`) answers *"can one node ingest ~1M params at 1 Hz."*
It never leaves the hot tier - it wipes the TSDB between runs and sets no retention (gap 3 & 4
in `monitoring-test-notes.md`). **This suite adds the storage lifecycle**: how long data lives
in Prometheus (warm), how it is handed to long-term storage (cold), and how it is thinned on
the way (downsampling + full-resolution capture of interesting events).

```
  1 Hz raw  ──►  WARM (Prometheus TSDB, full resolution)  ──►  COLD (long-term store)
                 retention: 1h / 12h / 24h / 1wk?                downsampled + event-full-res
                                        │
                          transfer mechanism (3 to compare)
```

---

## Suite A - Warm retention on Prometheus  `scenarios/storage/retention.sh`

**Question:** what does holding the real detector at full 1 Hz *cost* as the retention window
grows - disk, block compaction, WAL replay, query latency - and where is the sane hot-tier
horizon before offload becomes necessary?

One knob: `--storage.tsdb.retention.time`. Hold the real detector (230 boards / ~1.02M series)
and step the window.

| Step | Retention | What it exercises |
|---|---|---|
| 1 | **1 h**  | >= several 2 h... (see note) block boundaries only at min-block override; smallest footprint |
| 2 | **12 h** | multiple sealed blocks, first real compaction cycles |
| 3 | **24 h** | one full day; the `~150 GB/day` disk estimate ([F/est] DESIGN §3) validated on real disk |
| 4 | **1 week?** [D] | is week-long *raw* 1 Hz even wanted, or is this already a cold-tier job? |

Measured per step: on-disk block size, `prometheus_tsdb_head_series`, compaction duration
(`prometheus_tsdb_compaction_duration_seconds`), disk growth rate, and **WAL replay time on
restart** (`prometheus_tsdb_data_replay_duration_seconds`). To exercise compaction inside a
short run without waiting hours, force small blocks with
`--storage.tsdb.min-block-duration=5m --storage.tsdb.max-block-duration=15m`.

> [A] "Warm" in the note = data still live in Prometheus at full 1 Hz. "Cold" = anything handed
> off to long-term storage. The retention window is the warm->cold boundary.

---

## Suite B - Transfer to cold storage  `scenarios/storage/transfer.sh`

**Question:** by what mechanism does data leave the warm tier, and what does each cost the
collector (does offloading steal CPU/latency from live scraping)? Compare three, same real load.

| Mechanism | How | Prometheus flag / component | Notes |
|---|---|---|---|
| **HTTP endpoint** | `remote_write` to a cold sink | `remote_write:` block in `prom.yml` | The Prometheus-native path; sink can be VictoriaMetrics / object-store gateway |
| **SSE streaming** | server-sent-events stream to a consumer | external sidecar reading `/federate` or a stream shim | [D] confirm the SSE source - Prometheus has no native SSE; needs a bridge |
| **Local-machine store** | seal 2 h block -> sidecar uploads | Thanos-style sidecar on local XFS ([F] `cmx-rack-sw-00` is local XFS, safe) | The "upload a sealed block" path in DESIGN §3 |

Measured per mechanism: added CPU/RAM on the collector during offload, scrape-duration impact
on the live `modules` job (does transfer contend with ingest?), transfer throughput, and
end-to-end lag (sample time -> visible in cold store).

> [D] Are all three real candidates, or is HTTP `remote_write` the intended path and SSE /
> local-block two fallbacks? That decides whether this is a 3-way bake-off or one path + checks.

---

## Suite C - Downsampling policy  `scenarios/storage/downsample.sh`

**Question:** what does the cold tier actually keep? Not all 1 Hz forever - three resolutions:

| Tier | Rule | Resolution kept | Purpose |
|---|---|---|---|
| minute | 1-min **average** ("average it out") | 1 point / 60 s | routine trending, weeks-months |
| hour | 1-hour **average** | 1 point / 3600 s | long-term / archival |
| **event** | **interesting events -> full 1 Hz** | raw, no thinning | forensics on anomalies |

Test: run the downsampler (recording rules `avg_over_time(...)[1m]` / `[1h]`, or the cold store's
native downsampling e.g. VictoriaMetrics/Thanos) and measure the volume reduction vs. the raw
`~150 GB/day`, plus that full-resolution windows survive intact around flagged events.

> [F/est] Downsampling is the 1-2 orders-of-magnitude lever from DESIGN §3 - this suite puts a
> real number on it against real (or realistic) signal variability, which closes gap 2.

---

## Interesting events - the full-resolution trigger  `scenarios/storage/events.sh`

"Interesting" = keep raw 1 Hz instead of downsampling. Defined three ways, cheapest first:

1. **Fixed guards** - static bounds per parameter (hard min/max). Simplest; a recording/alerting
   rule that flags out-of-band and marks the window for full-resolution retention.
2. **Statistical anomaly** - value diverges beyond **+/-2sigma** of the normal baseline. **[D] The
   baseline is stage-dependent** - "normal" during ramp-up != normal during stable running, so sigma
   must be computed per operational stage (`config/stage.sh` already models stages). A rolling
   `stddev_over_time` with a stage-selected mu/sigma.
3. **ML on a time-stretch** - a model over a sliding window flags anomalies. Needs **labeled
   data** and an **autosized** window. Most powerful, most work; last to build. [A] out of scope
   for the load tests themselves - it is a detector, not a storage-capacity question.

Output of any of the three = a time-window tag -> downsampler keeps that window at full 1 Hz.

> [D] Precedence when rules disagree, and how far *before/after* a trigger to keep raw (pre-roll
> / post-roll), are policy decisions, not measured - flag them for stakeholders.

---

## Scope boundary (unchanged from `monitoring-test-notes.md`)

Suites A-C are still **§4 hot/warm-tier + the hot->cold handoff**. They close gaps 3 (cold tier),
4 (duration/retention/disk) and part of 2 (compression vs real variability). They do **not** turn
the ML detector or the cold store's own internals into validated components - those are separate.
