# What *Designing Data-Intensive Applications* (Kleppmann) says about this test suite

A mapping of DDIA's relevant material onto the four test ideas (warm retention, cold transfer,
downsampling, interesting events) and the surrounding suite (measurement method, HA, sharding).
Tags as elsewhere: **[F]** finding; **[A]** assumption; **[D]** decision. Chapter refs are to DDIA.

The one-line thesis DDIA would put on this project: **the raw 1 Hz stream is a *system of
record*; everything else - downsampled series, aggregates, cold copies - is *derived data* that
can be recomputed from it.** That single framing (Ch 12) reorganizes the whole storage design.

---

## 1. How the suite is *measured* - Chapter 1 (Reliable, Scalable, Maintainable)

DDIA Ch 1 is, almost line-for-line, a spec for how to run this benchmark.

- **[F->method] Load is described by "load parameters."** DDIA: pick the numbers that define load
  (req/s, concurrent users, cardinality) and vary them. The OT/IT board counts, series-per-target,
  and scale multiples (0.25x-3x) *are* load parameters - the suite is already built the DDIA way.
- **[D->method] Response time is a *distribution*, not a number.** DDIA is explicit: "users care if
  your site is occasionally slow even if the average is fine" - report **p50/p95/p99/p999**, never a
  mean or a single reading. `sample()` takes **one instant read** of `scrape_duration_seconds`.
  That is exactly the anti-pattern. A windowed high percentile over the settle window is the fix:
  `quantile_over_time(0.99, max(scrape_duration_seconds{job="modules"})[30s:1s])`.
- **[F] The scrape wall IS tail-latency amplification.** DDIA: when one request fans out to many
  backends, "the end-user request still needs to wait for the slowest of the parallel calls." A 1 Hz
  tick fans out to 230 parallel scrapes; the tick is healthy only if the **slowest** target fits
  900 ms. So the detector's health is a **tail** (p99/max across targets), not an average - the
  `max(scrape_duration)` approach is right, it just needs to be a windowed percentile. This is the
  book's own model of the headline finding.
- **[method] Name the two scalability axes** - DDIA's two questions map 1:1 onto the suite:
  1. *"Increase a load parameter, keep resources fixed - how does performance change?"* -> `ramp`,
     `stress`, `modules`, `sweep`.
  2. *"How much must you grow resources to keep performance unchanged?"* -> `shard`
     (`shards = total / (C x 0.55)`) and `twin`.
  Labelled this way in the write-up, the frame is recognizable to readers who know DDIA.
- **[D] The 900 ms timeout is an implicit SLO.** DDIA distinguishes SLO/SLA. State it as one:
  "*every scrape completes < 900 ms at p99*." Then a run passes/fails against a declared objective,
  not a vibe.
- **[F/method] Faults vs failures + deliberate fault injection.** DDIA: "prefer tolerating faults
  over preventing," and *induce* them on purpose (chaos). The `spike` (IT powers on) and `twin`
  (failover) are fault-injection tests; extending them to *kill a collector mid-soak* and measure
  recovery is the DDIA-approved move.

## 2. Warm retention on Prometheus (Suite A) - Chapter 3 (Storage & Retrieval)

Prometheus's TSDB is an **LSM-style** engine (WAL + in-memory head -> sealed, compacted blocks).
DDIA Ch 3 names the exact risks a retention test exists to find:

- **[F] Compaction can starve live traffic.** DDIA: "the compaction process can sometimes interfere
  with the performance of ongoing reads and writes." The retention test is really a *does-compaction-
  keep-up-at-1.2 M-series/s* test -> measure `prometheus_tsdb_compaction_duration_seconds` and watch
  whether scrape latency spikes *during* a compaction.
- **[F] "If compaction can't keep up with incoming writes, you run out of disk."** DDIA states this
  failure mode directly - it is the real risk of the 12 h/24 h/week rungs, not raw sample volume.
- **[F] Write amplification.** DDIA: "a write to the database results in multiple writes to disk."
  The `~150 GB/day` estimate is *logical* samples; on disk, WAL + block rewrites during compaction
  multiply it. Size the disk for amplified writes, and measure the real multiplier on `cmx-rack-sw-00`.
- **[A] WAL replay = restart cost.** The memory-creep + head-growth observed is the head filling
  before a block is cut; a crash means replaying the WAL. Time it (`..._data_replay_duration_seconds`).

## 3. Downsampling: minute/hour averages (Suite C) - Chapter 3 + Chapter 12

- **[F] Downsampled series are "materialized aggregates" / a "data cube."** DDIA Ch 3: a data cube is
  "a grid of aggregates grouped by different dimensions"; materialized aggregates "cache the counts
  and sums that queries use most often." The 1-min and 1-hour averages are precisely this.
- **[D] The materialized-view trade-off DDIA warns about applies here twice:**
  1. *Writes get more expensive / flexibility is lost* - "when the underlying data changes, a
     materialized view needs to be updated." Once only the **mean** is stored, the ability to ask a
     different question later is gone. **For a detector, `avg` hides exactly the peaks that matter** -
     keep **min / max / stddev / count** per bucket too, not just the average, or an excursion
     cannot be reconstructed from downsampled data.
  2. *Compression is best-case on smooth data* (Ch 3, column compression) - gap 2. "Deadband
     efficiency" = compression efficiency, and it collapses on noisy real signals. Re-measure on real
     variability before trusting the volume reduction.
- **[F] The cold tier wants column-oriented layout.** DDIA Ch 3: analytical scans read few columns
  over many rows -> columnar storage + compression (bitmap/RLE). Prometheus blocks and Parquet/
  VictoriaMetrics already lean this way; it's the right shape for long-term analytical reads.
- **[F->reframe] Downsampled = *derived data* (Ch 12).** "Derived data can always be recomputed from
  the source." So the minute/hour series are **disposable**: as long as the raw 1 Hz is kept (even
  briefly), any downsampling can be re-derived later, or a bug fixed by **reprocessing**. This is the
  argument for treating raw as the source of truth and downsamples as caches.

## 4. Transfer to cold storage (Suite B: HTTP / SSE / local) - Chapter 11 + Chapter 12

DDIA Ch 11 gives the exact axis on which the three mechanisms differ: **can the transport replay?**

- **[F] Log-based transport (HTTP `remote_write`) = a replayable event log.** DDIA: a log-based
  message broker is append-only and re-readable - a consumer that falls behind, or a brand-new
  consumer, can **replay from an offset**, and the log provides **buffering / backpressure** at the
  source. This is the strongest of the three for a cold *system of record*.
- **[F] SSE streaming ~ direct messaging = fire-and-forget.** DDIA warns direct messaging (webhooks/
  SSE) **drops messages if the consumer is down** - no durability, no replay. For monitoring data
  (AP, an occasional lost scrape tolerable) that may be acceptable for a *live* feed, but it is the
  wrong choice for the authoritative cold copy. DDIA supplies the decision criterion for free.
- **[F] Local-machine block upload = the sidecar/log pattern.** Sealed 2 h block on local XFS
  ([F] `cmx-rack-sw-00`) -> uploaded to object store. This is durable and replayable (re-upload).
- **[D->measure] Backpressure is the thing to measure.** DDIA names it: if the cold sink slows, does
  it back-pressure the collector and **steal CPU from live scraping**? `transfer.sh` should hold the
  real load and watch the `modules` scrape p99 while the sink is throttled. That single graph decides
  push-vs-pull safety more than throughput does.

## 5. Interesting events: anomalies / ML / fixed guards - Chapter 11 (+ Ch 8 clocks)

This is where DDIA is most directly useful - it gives these ideas their proper names and exposes two
traps the note doesn't mention.

- **[F] "Interesting events" = Complex Event Processing (CEP).** DDIA Ch 11: CEP stores the *queries*
  and lets data flow past them (the inversion of a normal DB), "searching for specific patterns of
  events." The **fixed guards** and **+/-2sigma rules** are CEP queries; the ML detector is CEP with a
  learned pattern. That is the architecture: rules resident, stream flowing through.
- **[F] +/-2sigma needs *stream analytics* - a rolling aggregation.** DDIA: stream analytics computes
  rolling counts/means/percentiles over windows. The baseline mu/sigma "depending on the stage" is a
  windowed aggregation with a **stage-selected** baseline (`config/stage.sh` already models stages).
- **[F] The window taxonomy names all three resolutions and the ML case exactly:**
  | Idea | DDIA window (Ch 11) | Definition |
  |---|---|---|
  | minute-for-minute average | **Tumbling** | fixed length, every event in exactly one window (10:03:00-10:03:59 ->one bucket) |
  | hour-for-hour average | **Tumbling** (larger) | same, 1 h buckets |
  | smoothed anomaly baseline | **Hopping / Sliding** | fixed length but overlapping, for smoothing |
  | "ML on a time-stretch, autosize" | **Session** | *no fixed duration* - bounded by activity; the window "autosizes" to the event |
  The handwritten "autosize" is literally DDIA's session window.
- **[D->TRAP 1] Event time vs processing time.** DDIA Ch 11's sharpest warning here. When bucketing
  into a 1-min average, does it use the sample's **event time** or Prometheus's **ingest (processing)
  time**? A scrape that times out and recovers (the `spike` scenario) produces DDIA's textbook
  **"dip then spike"** artifact - a gap of missing minutes then a burst - which the +/-2sigma detector
  will **false-trigger on as an anomaly** when it is really a *monitoring* artifact, not a *detector*
  event. Decide event-time bucketing explicitly, and exclude scrape-health gaps from the baseline.
- **[D->TRAP 2] Stragglers / window completeness.** DDIA: "When do you know you have every event within
  a window? You don't - there could be an event stuck in the network." So: when is the 10:03
  minute-bucket finalized and shipped cold? A late/retried sample after averaging corrupts the
  bucket. DDIA's two options - *ignore past a max wait*, or *issue a correction downstream* - are the
  two policies to choose between; pre-roll/post-roll around a trigger is the same decision.

## 6. HA - twin (Ch 5 Replication) & shard (Ch 6 Partitioning)

- **[F] Twin = independent replicas; pull gives HA "almost for free" - and avoids split-brain.**
  DDIA Ch 5's big failover danger is **split brain** (two nodes think they're leader). The twin has
  **no leader election** - both scrape everything independently - so that entire class of bug is
  designed out. Worth stating as a *positive* DDIA result, not just an assumption.
- **[D] But async replicas diverge -> dedup needs aligned time.** DDIA Ch 5: async replication means
  replication lag; two replicas won't be sample-identical at an instant. Query-time dedup across the
  twins therefore depends on aligned timestamps -> **Ch 8: time-of-day clocks cannot be trusted; NTP
  has skew.** The DESIGN [A] "hosts NTP-synchronized for dedup" is *exactly* the classic clock trap
  DDIA flags - keep it as an assumption to verify, not a given.
- **[F] Sharding must balance by *series*, not board count - this is DDIA's hot-spot/skew problem.**
  Ch 6: partition by key and *relieve hot spots*; an even split of keys can be a skewed split of load.
  The finding "it's series-per-target that breaks, not total" is a **skew** finding: an IT board
  (17,500) is a hot partition vs an OT board (820). A shard split that balances *boards* is a *skewed*
  split of *load*. Balance shards by summed series, and keep no single target above the per-target wall.

## 7. Cardinality churn & reprocessing - Chapter 4 + Chapter 12

- **[F] Gap 1 (metric names change on firmware updates) = schema evolution.** DDIA Ch 4 is about
  exactly this: backward/forward compatibility as fields come and go. In Prometheus terms a renamed
  metric is a *new series*; the cost is head-index growth and compaction churn (gap 1). Test it by
  actually churning series (`--series-operation-mode`/interval), not just static cardinality.
- **[F] Reprocessing is the safety net (Ch 12).** Because downsamples are derived, "every stage is
  reversible" - if a downsampling rule or an anomaly threshold is wrong, fix it and **re-derive from
  the raw log**. This is the concrete payoff of the system-of-record framing in §3-4, and the reason to
  keep raw (at least for interesting-event windows) rather than only the averages.

---

## Sources
- Ch 1 (load parameters, percentiles p50/p95/p99/p999, tail-latency amplification, two scalability
  questions, faults vs failures) and Ch 3 (OLTP/OLAP, column storage + compression, materialized
  aggregates / data cubes, LSM compaction, write amplification, compaction-can't-keep-up):
  keyvanakbary *learning-notes* DDIA summary.
- Ch 5 (leader/follower, sync vs async, split brain), Ch 6 (partitioning / hot spots), Ch 8 (clocks/
  NTP), Ch 9 (CAP): same summary + O'Reilly ch outlines.
- Ch 11 window taxonomy (tumbling/hopping/sliding/session) and stragglers/window-completeness:
  ResidentMario notes + xinrong-meng/knowledge-sharing DDIA notes.
- Ch 12 (derived data vs system of record, reprocessing, unbundling, lambda, recomputation):
  comeshare.net Ch 12 summary.
