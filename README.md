# CERN Prometheus / CMS Tracker

Can one Prometheus node monitor the tracker's ~1-2M parameters at **1 Hz**, and
if not, is the limit the machine or the technology?

```
  client (Avalanche)                 server (Prometheus)
  N fake sensors        ── scrape ──►  stores every series;
  M series each            1 Hz        each scrape must finish in < 1 s
```

Avalanche synthesises the time series; Prometheus can't tell them from real
sensors, and raw cardinality is what stresses it. Everything runs native
(no Docker) so nothing hides the real cost.

## Layout

```
scripts/
  run_all.sh            driver: baseline suite, then two-node tests, then plots
  config/               common.sh (shared plumbing), topology.sh, stage.sh, check.sh
  scenarios/baseline/   single-node tests: modules ramp sweep stress spike soak cms push
  scenarios/            two-node tests: twin shard ramp_dist, plus hardware
  avalanche/            load-node start/stop/measure
  prometheus/           collector-node start/stop/measure
  analysis/             plot_*.py -> scripts/graphs/*.png
  data/                 raw CSVs (gitignored)
  graphs/               rendered PNGs (gitignored)
results-hpc/            committed HPC result CSVs
bin/                    prometheus + avalanche binaries (not committed)
```

## Run

Single node, everything on localhost:

```bash
./scripts/run_all.sh                    # full suite + plots
./scripts/scenarios/baseline/ramp.sh    # or one test
python3 scripts/analysis/plot_suite.py
```

Common overrides (`MODULES`, `TOTAL`, `DURATION`, ...) are documented at the top
of `config/common.sh`. The 1 Hz cap is fixed there: `INTERVAL=1s`,
`TIMEOUT=900ms` (a scrape may take up to 90% of the period; overrun = dropped
sample). `PROTO=PrometheusText0.0.4` pins the exposition format so every scrape
parses identically; set `PROTO=PrometheusProto` for Avalanche's faster binary
path (best-case ceiling). A guard stops a run if host free RAM drops below
`MIN_AVAIL_GB`, so a failure stays Prometheus's, not the machine's.

## Two-node run (load and collector on separate hosts)

Keeping the generators off the collector is the point: Prometheus is alone on its
node, so its CPU/RAM is the true per-node footprint. Copy
`config/secrets.env.example` to `config/secrets.env`, fill in `SSHPASS` and the
`LOAD_HOSTS` / `COLLECTOR_HOSTS`, then:

```bash
./scripts/config/check.sh    # reachability + host specs
./scripts/config/stage.sh    # scp binaries + scripts to each host
./scripts/scenarios/twin.sh  # or shard.sh
```

`run_all.sh` runs these automatically once `config/secrets.env` exists.

## Findings so far (laptop, 15 GB / 16 cores)

- Memory is not the wall: ~3.7 KB/param, so 1M ~ 3.8 GB.
- The wall is the 1 Hz scrape model - one fat target hits the 900 ms timeout
  at a few hundred k series.
- The lever is **series-per-target** (~30-35k here), not the grand total;
  fan the load out and the wall moves. A real server is next, to push to 2M.
