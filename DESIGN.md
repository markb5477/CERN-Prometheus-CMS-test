# Design notes: monitoring the tracker at 1 Hz

Working document for the design-note evaluation. Everything is tagged:
**[F]** = measured finding; **[A]** = assumption (unverified); **[D]** = decision still needed.

---

## 1. The question

Can a single Prometheus node record ~1-1.2M detector parameters at a fixed **1 Hz**,
and if not, is the limit the *machine* or the *technology*? Then: what architecture
follows, and is Prometheus even the right tool?

---

## 2. What the tests found (laptop: 15 GB RAM, 16 cores, shared with other work)

- **[F] It is not RAM.** ~3.7 KB/series => 1.2M ~ 4.4 GB, which fits comfortably.
  Past the wall memory actually *falls* (to ~100 MB at 1.2M) because timed-out
  scrapes store nothing.
- **[F] The wall is the 1 Hz pull model.** Every scrape must finish inside the 1 s
  tick (a 900 ms timeout is enforced). Scrape *duration* grows with cardinality until
  it can't fit the budget; then the sample is dropped.
- **[F] The lever is series-PER-TARGET, not the total.** The same 500k parameters
  time out as 1 scrape target but ingest fine across 10-40 targets. Per-target wall
  on this laptop ~ **30-35k series**.
- **[F] Sensor ramp (35 params/sensor, 20 boards):** healthy to ~700k, dies at
  **800k**, stores nothing by 1.2M.
- **[F] Native ~ Docker** at healthy load - the wall is Prometheus, not containers.
- **[F] 1 Hz cadence itself is rock-steady** (verified: exactly 1 sample/series/second).
  Only the per-scrape *cost* varies.

The laptop numbers are **relative**, not the production ceiling (contended machine,
RAM-guarded). The HPC gives the real per-node capacity **C**.

---

## 3. Assumptions

### Workload / data
- **[A]** Fixed **1 Hz**, never exceeded. Data rate is one known constant.
- **[A]** Total cardinality ~1M, growing to ~1.2M **series** (parameters), bounded and
  known in advance.
- **[A]** 5-35 parameters per sensor; sensor readout aggregated behind front-end boards.
- **[A]** Cardinality is **static within a run** - no series appearing/disappearing at
  runtime (`series-interval=0`). Reconfiguration between runs is a separate event.
- **[A]** Metrics are simple numeric gauges (temperatures, voltages, currents), not
  histograms/summaries. **[D]** Confirm - histograms multiply series count.
- **[A]** Label sets are stable and modest in size. **[D]** Real metric names/labels may
  be longer than the synthetic ones -> re-measure per-series cost with realistic shapes.

### Environment / security
- **[A]** Protected network: no DDoS, no adversarial or surprise load. Provisioned load
  == actual load.
- **[A]** Trusted environment: TLS/basic-auth desirable but not hostile-internet hardening.
- **[A]** **Static** target list (known sensor->board->endpoint map); no dynamic membership
  churn (`static_configs`).
- **[A]** Boards<->Prometheus link is LAN-class: low latency, high bandwidth, reliable.

### Hardware / infrastructure
- **[F] Target node `cmx-rack-sw-00` measured (2026-07-06):** AlmaLinux 9.4, **x86_64**
  (the amd64 binaries run as-is), **32 cores** (Xeon Silver 4514Y, 16C/32T), **124 GB RAM**
  (~110 GB free), **3.6 TB local XFS** root (13% used, ~3.2 TB free). Docker/Podman/git
  present; Prometheus/Go absent -> bring the prebuilt binaries. Shared box, near-idle
  (load ~0.2, a couple of other users' light processes).
- **[F] Disk is local XFS, not NFS** - the TSDB can live on `/` safely. Resolves the
  "Prometheus doesn't support NFS" concern for this node.
- **[F] RAM is not the constraint on this node:** 1.2M series ~ 4.4 GB, trivial in 124 GB.
  So any failure here is the *scrape technology*, not memory - the clean test the laptop
  (RAM-contended) could not give.
- **[A]/[D] Enough front-end boards (scrape targets)** exist to keep series-per-target
  under the wall. *This is a design requirement, not a given* - the number of scrape
  endpoints matters as much as the number of servers.
- **[A]** Object storage (CERN CEPH/S3) is available and reachable for long-term data.

### Long-term storage & "transport"
- **[A]** Each Prometheus seals a ~2 h data block and a sidecar **uploads** it to object
  storage; upload bandwidth is available and does not starve scraping.
- **[F/est] Data volume:** 1.2M series x 1 Hz ~ 104 billion samples/day. At ~1.5 bytes/
  sample compressed => **~150 GB/day ~ ~55 TB/year of raw 1 Hz data** (per stored copy,
  before downsampling). This is the number the object store must be sized for.
- **[D] Retention policy:** how long is *raw* 1 Hz needed vs. **downsampled** (e.g. 1-min
  averages after N days)? Downsampling cuts long-term volume by 1-2 orders of magnitude.
  This is a physics/analysis decision, not a technical one.
- **[A]** Hosts are **NTP-synchronized** so timestamps across replicas/shards line up for
  deduplication (clock skew is a classic distributed-systems trap).

### Availability
- **[A]** 2 independent replicas per shard, in **separate failure domains** (rack/power/
  room), meet the availability target. **[D]** Confirm acceptable data-loss window.
- **[A]** Monitoring data is **derived/observational** - losing an occasional scrape is
  tolerable (AP over CP). **[D]** Is any of this safety-critical (interlocks)? If so it
  needs stronger guarantees and probably a different path.
- **[A]** Query/alert load is modest and known -> covered by the ~45% headroom per node.

### Test-method caveats
- **[A]** Synthetic Avalanche series ~ real series in cost (cardinality dominates).
- **[F]** Laptop results are contended/RAM-guarded -> **HPC measures the real C**.
- **[A]** Measured with pinned `PrometheusText0.0.4` exposition; protobuf is faster and
  real boards may differ - re-check on representative data.

---

## 4. The plan

1. **[done] Laptop characterization** - establish *what* the limit is (per-target scrape
   wall, not RAM) and validate the test suite.
2. **HPC run on `cmx-rack-sw-00`** - run the suite *unshrunk* (80+ boards, to 2M) to
   measure the real per-node ceiling **C** and confirm behavior at scale.
   *Access solved (2026-07-06):* pubkey and Kerberos both fail (key not installed on this
   host; host has no Kerberos principal), but **`keyboard-interactive` / PAM password auth
   works** - login with the CERN password succeeds. Recon done (specs above). Running the
   suite needs file copy + execution (writes) - pending go-ahead.
3. **[after C] Topology decision:**
   - If the full detector fits one node with headroom -> **1 primary + 1 hot standby**
     (both scrape everything, dedup at query). Simplest; no sharding.
   - Else -> **static functional sharding**: `shards = total / (C x 0.55)`, 2 replicas
     each, a Thanos-style Querier for the global view, object storage for long-term/DR.
4. **[parallel] Technology bake-off** (see §5) - measure the same load against at least
   one alternative before committing.
5. **Long-term storage** - sidecar -> CEPH/S3, define retention/downsampling, size for the
   volume in §3.
6. **Write the CERN design note** from the measured numbers.

---

## 5. Technology flag - is Prometheus the right choice?

**Short answer: it's a reasonable, CERN-standard default, but the headline finding is a
real Prometheus limitation, and one alternative should be A/B-tested before committing.**

Why Prometheus fits: mature, simple, excellent compression, huge ecosystem (Grafana,
Thanos), widely used at CERN, and the pull model gives HA almost for free (independent
replicas, no replication protocol).

Why to pause: **the per-target scrape wall measured here is a direct consequence of the
1 Hz *pull* model** - each scrape must finish in one tick. That forces the readout to fragment
the readout into many targets and, past a point, into many servers. Two levers deserve
a hard look:

- **[D] Pull vs. push.** The 1 s deadline is *self-imposed by choosing pull*. If sensors/
  boards **pushed** samples (remote_write / line protocol), there is no per-scrape
  deadline - ingestion is decoupled from a 1 s window, and the wall largely disappears.
  Push costs the free "is it alive?" signal and needs a buffer at the source, but in
  a fixed-load, protected environment those costs are small. This is arguably the single
  biggest architectural lever.

- **[D] A higher-capacity TSDB.** Candidates, cheapest-to-switch first:
  - **VictoriaMetrics** - PromQL-compatible, reuses Grafana, supports *both* pull and
    push, and is engineered for far higher per-node cardinality with better compression.
    Could turn a "4 shards + Thanos" design into 1-2 nodes. **Strongly worth a head-to-head.**
  - **Grafana Mimir / Cortex** - horizontally sharded, replicated Prometheus-compatible
    TSDB (hash ring). Solves scale natively but is built for *elastic, multi-tenant*
    loads - likely overkill for a fixed single workload.
  - **InfluxDB / TimescaleDB** - purpose-built TSDBs (push, different query languages).
    Consider only if SQL/joins are wanted, or to leave the Prometheus ecosystem deliberately.

- **[D] Scope check:** is this detector-control/monitoring (DCS) data that already has a
  CERN-standard home (e.g. WinCC OA + Oracle archive)? If so, Prometheus is being
  evaluated as a *modern alternative* and should be compared against the incumbent, not
  designed in isolation.

**Recommendation:** measure Prometheus **C** on the HPC first (baseline). Then point the
*same* synthetic load - Avalanche can `remote_write` - at **VictoriaMetrics** (and try a
push config) and compare the per-node ceiling. If a single VM node holds 1.2M at 1 Hz
with headroom, the entire distributed design collapses into something far simpler. That
comparison is cheap (same harness, an afternoon) and decision-changing.

---

## 6. Decisions needed from stakeholders

- [D] Retention: how long is raw 1 Hz required vs. downsampled?
- [D] Is any signal safety-critical (needs stronger-than-AP guarantees)?
- [D] Pull vs. push - is push acceptable given boards would run a small agent?
- [D] Must the project stay on Prometheus (ecosystem/standardization), or is a bake-off welcome?
- [D] Confirm metric shapes (gauges only? label sizes?) for an accurate per-series cost.
