# Monitoring DB load tests: coverage, answers, and gaps

Notes against the Tracker Database Landscape design note. The load tests only
exercise the **Monitoring DB (section 4)** hot tier. Sections 1, 2, 3 and 5
(Configuration, Cabling, Calibration, O2O) are relational / object-store
problems and are **out of scope for these tests** - they need their own
validation and are flagged as such at the end.

---

## What the tests actually are (the boundary)

Read this first, because every claim below is bounded by it.

- **One** Prometheus node on the HPC: 32 cores, ~125 GB RAM.
- Pull model, **1 Hz**, scrape timeout 0.9 s.
- Load = Avalanche exporters (prometheus-community), one process per **module**,
  each exposing a chosen number of gauge **parameters** (1 parameter = 1 series
  = 1 value/s).
- Exporters run **on the same host** as Prometheus (localhost) - no network path.
- Series set is **fixed for the duration of a run** - flat, stable-named gauges.
- Longest hold is **30 minutes** (soak). Everything else is a spot reading.
- Parameter counts are grounded in this note's budget: **880k across 316
  per-DTC aggregation points**, then pushed higher.

So the tests measure **sample ingestion at fixed cardinality, hot tier only,
ingest-only, on one lab machine.** That framing is what creates the gaps.

---

## Questions from the note the tests can speak to

### Q3 / §4 - "validate Prometheus at ~1M parameters before committing"

**Partially answered - yes, with named gaps.**

On this hardware, a single Prometheus node:
- ingests the real **880k** load at 1 Hz in **0.03 s** (~3% of the 1 s budget),
  all 316 modules up;
- stays healthy through **~2.0M** active series (0.27 s, all up);
- **collapses between 2.0M and 2.5M** (at 2.5M only 15 of 316 modules stay up).

So the ~1M target is met for **static ingestion on this box, with ~2.3x
headroom** over real load. It is **not** the full "before committing" bar - see
the gap register. The honest headline: *ingestion volume is not the risk; the
risks are the things below.*

Second, independent finding the note should absorb: **it is parameters-per-module
that breaks, not total volume.** 2M split over 40 modules (50k each) scrapes in
0.81 s; the same 2M over 20 modules (100k each) times out with 7/20 up; a single
2M module never comes up. This directly informs the note's ingestion path
("local aggregator per DTC or per rack") - aggregate toward **more, thinner**
scrape targets, not fewer fat ones. At fixed 880k, coarsening 316 -> 8 modules
(110k each) already pushes the scrape to 0.93 s, at the budget edge.

### Q4 / §4 - cold tier strategy (deadband / downsampling / long-term Prometheus)

**Not answered.** The tests never leave the hot tier. See gap 3.

### Everything else in "Questions to answer"

Q1 (which relational engine), Q2 (DB consolidation), Q5 (topology ownership),
Q6 (Track Finder O2O), Q7 (calibration node allocation), Q8 (DQM scope) are
**not monitoring-load questions** - the tests say nothing about them and should
not be presented as if they do.

---

## Gap register - what the tests do NOT cover

Each item names the idea in the note, why the tests miss it, and what would
close it.

**1. Label cardinality churn (the big one).**
Note §4: non-ASIC parameters have "names and types [that] can change with
firmware updates"; open question warns "if cardinality becomes a bottleneck."
The tests hold a **fixed** series set, so they validate *static* cardinality up
to ~2M series but **never create or retire series over time**. Series churn - new
series on every firmware update, module recabling, restart - is what grows
the head index and drives compaction cost in production, and it is exactly the
risk the note flags. **Untested.** Would need a run that adds/renames/drops
series continuously while sampling.

**2. Realistic values / compression.**
Avalanche gauges are smooth and predictable, so Prometheus's delta-of-delta +
XOR compression is best-case. Real temperatures, currents and link metrics are
noisier and compress worse, so the on-disk and memory figures are **optimistic**.
The same point breaks a cold-tier option: **deadband efficiency depends entirely
on real signal variability**, which was not modelled.

**3. Cold tier, entirely.**
Note §4 lists deadband / downsampling / long-term Prometheus / combination as
open. Tests ran only the local Prometheus TSDB (on-disk hot tier) for <=30 min,
and **wiped it between runs** (`rm -rf .native-data/tsdb`), with no retention
flag set: **no remote_write, no downsampling, no hot->cold handoff, no long-term
retention.** So the tests exercised ingestion into the hot tier only; storage
and retention are untouched. Q4 is wide open.

**4. Duration, retention, disk.**
30 minutes is not the note's ~75x10^9 samples/day at multi-week retention. Not
tested: on-disk block compaction over days, disk-space growth, WAL replay time
after a restart, query latency over long time ranges. **Memory already crept
from ~1.7 to ~3.7 GB during the 30-min soak** (trivial on 125 GB, but the wrong
direction) - a multi-hour/day soak at real load is the single most important
missing test.

**5. Read / query load.**
Note §4: read by "DCS, alerting and alarming, shifter UIs, offline analysis,"
with a Grafana federation layer. Tests measured **ingest only** - no concurrent
PromQL, dashboards, or alert/recording-rule evaluation. A large head under real
query load behaves differently. **Untested.**

**6. Ingestion pipeline shape.**
Note §4 path: monitoring layer -> **local aggregator (per DTC or per rack)** ->
hot -> cold, with OpenTelemetry mentioned as transport. Tests pull directly from
exporters on localhost. **Not tested:** the aggregator hop, push-vs-pull at that
boundary, OTel transport, network latency/loss, back-pressure. The 316->8
aggregation sweep informs *where* to aggregate, not the aggregator component.

**7. High availability - the two proposed solutions.**
Twin nodes and functional sharding are **design proposals, not tested.** No
failover, no duplicate-scrape dedup, no sharding coverage/correctness, no
split-brain. Should be presented as unvalidated.

**8. Hardware representativeness.**
The ~2M-series ceiling is specific to the HPC (32c / 125 GB) with exporters on
localhost. The production-spec node requested from CERN IT will have a different
ceiling, and a real deployment puts a **network** between detector and hot tier.
Headroom numbers must be re-measured on production hardware.

**9. ASIC vs non-ASIC routing.**
Note §4 splits the cold tier: relational for stable ASIC params, schema-flexible
for non-ASIC. The tests treat every parameter identically and touch **neither**
cold path. **Untested.**

**10. Alternatives not benchmarked.**
Q3 names VictoriaMetrics / InfluxDB / OpenSearch as fallbacks if cardinality
bites. Only Prometheus was measured - **no head-to-head**, and cardinality churn
(gap 1) is precisely where those alternatives claim an edge.

---

## What the tests *did* get right (for balance)

- Parameter counts taken straight from the note's budget (880k / 316 DTC points),
  not invented.
- Both axes probed: growth (fixed topology, rising total) and aggregation (fixed
  total, coarsening modules) - the second directly serves the ingestion-path
  decision.
- 1 Hz held throughout, matching the note's baseline (the note allows per-type
  rates to vary later; the tests correctly test the stated baseline).
- Memory creep reported rather than hidden.

---

## One-line status for the other stores (out of test scope)

- **Configuration DB (§1)** - relational + blob/object store; not a load-test
  target here. Needs its own sizing test (the ~35 GB/version, ~350 TB blob path).
- **Cabling DB (§2)** - relational, shares the Config schema; untested here.
- **Calibration DB (§3)** - relational tier + S3 object store; untested here.
- **O2O (§5)** - interface on CMS Conditions infra, not a store load-tested here.

These are noted only so the meeting is clear the load tests speak to §4 alone.
