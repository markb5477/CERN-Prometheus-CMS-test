#!/usr/bin/env bash
# Ceiling pretest (co-located box): ramp the real-mix load until this machine ceils out, and at
# EVERY step record the three actors SEPARATELY -
#   * Prometheus (cpu_pct/ram_pct/memory_bytes, from its own job="server" metrics) - the isolated
#     per-node number we actually want for the HPC / k8s spec;
#   * avalanche  (av_cpu/av_rss, summed over all load-gen PIDs via /proc) - the load generator's
#     own footprint, i.e. how much of a co-located reading is contamination;
#   * the WHOLE machine (host_cpu/host_ram_used, from /proc/stat + /proc/meminfo) - BOOKKEEPING:
#     it is the host running out of cores/RAM that makes a co-located run stale / die, not
#     Prometheus itself. This column is why we ceil out, recorded on purpose.
#
# Goal: the RAM-vs-series and CPU-vs-(samples/s) slopes (extrapolate to the real 880k detector)
# plus the point where THIS box ceils - so the isolated HPC run can be sized to avoid it.
# Storage columns (disk_bytes, bytes_per_sample) come along for free; the dedicated bytes/sample
# number is soak.sh's job (it needs time to compact).
#
# Fresh bringup per step (bringup_mixed wipes the TSDB) so each scale's RAM is clean. Stops and
# logs WHY at the first hard failure (a scrape target dropped, or host RAM below the floor). Soft
# degradation (cadence slip / scrape over the 1 s budget) is recorded and the ramp continues so
# the degradation curve is visible before the hard wall.
source "$(dirname "$0")/../../config/common.sh"
trap stop_all EXIT

SCALES=${SCALES:-"0.25 0.5 0.75 1.0 1.25"}   # fraction of the real detector (150 OT + 50 IT = 880k)
FLOOR_GB=${FLOOR_GB:-2}                        # stop before the host OOMs (protect the box)
REPEAT=${REPEAT:-1}                            # samples taken (and logged) per scale, for averaging
PROC_WIN=${PROC_WIN:-1}                        # /proc CPU sampling window (s); widen for cleaner low-load reads
OUT="$DATA/pretest.csv"

echo "scale,rep,ot,it,targets,params,head_series,max_scrape_s,modules_up,cadence_s,memory_bytes,cpu_pct,ram_pct,prom_cpu_proc,prom_rss_proc,av_cpu,av_rss,host_cpu,host_ram_used,block_bytes,head_bytes,wal_bytes,disk_bytes,samples_appended,bytes_per_sample,status" > "$OUT"

for S in $SCALES; do
  CUR=$(free -g | awk 'NR==2{print $7}')
  [ "${CUR:-99}" -lt "$FLOOR_GB" ] && { echo "host already below floor (${CUR}g avail) - stopping before scale=$S"; break; }

  OT=$(awk -v b="$OT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  IT=$(awk -v b="$IT_BOARDS" -v s="$S" 'BEGIN{printf "%d", b*s + 0.5}')
  N=$(( OT + IT )); P=$(( OT * OT_PER_BOARD + IT * IT_PER_BOARD ))
  echo ">> scale=$S : $OT OT + $IT IT = $N targets / $P params"

  bringup_mixed "$OT" "$IT"    # stop, wipe tsdb, config, start mixed fleet + prometheus, settle
  SCALE_STATUS=ok
  for ((rep=1; rep<=REPEAT; rep++)); do
    IFS=, read -r HEAD DUR UP MEM AV CPU RAM CAD <<< "$(sample)"
    BB=$(prom 'prometheus_tsdb_storage_blocks_bytes{job="server"}')
    HB=$(prom 'prometheus_tsdb_head_chunks_storage_size_bytes{job="server"}')
    WB=$(prom 'prometheus_tsdb_wal_storage_size_bytes{job="server"}')
    SA=$(prom 'sum(prometheus_tsdb_head_samples_appended_total{job="server"})')
    IFS=, read -r HCPU HUSED ACPU ARSS PCPU PRSS <<< "$(proc_sample "$PROC_WIN")"
    read -r DISK BPS <<< "$(awk -v b="${BB:-0}" -v h="${HB:-0}" -v w="${WB:-0}" -v s="${SA:-0}" 'BEGIN{d=b+h+w; printf "%d %.4f", d, (s>0? d/s : 0)}')"

    STATUS=ok
    awk "BEGIN{exit !(${CAD:-0} > 1.05)}" && STATUS=cadence_slip
    awk "BEGIN{exit !(${DUR:-0} > 1.0)}"  && STATUS=scrape_over_budget
    [ "${UP:-0}" -lt "$N" ] && STATUS=targets_dropped
    [ "${AV:-99}" -lt "$FLOOR_GB" ] && STATUS=host_ram_floor
    [ "$STATUS" != ok ] && SCALE_STATUS="$STATUS"

    echo "   [rep $rep/$REPEAT] up=$UP/$N scrape=${DUR}s cad=${CAD}s | prom ${CPU}%cpu $(( ${MEM:-0}/1048576 ))MiB | avln ${ACPU}%cpu $(( ${ARSS:-0}/1048576 ))MiB | host ${HCPU}%cpu avail=${AV}g [$STATUS]"
    echo "$S,$rep,$OT,$IT,$N,$P,$HEAD,$DUR,$UP,$CAD,$MEM,$CPU,$RAM,$PCPU,$PRSS,$ACPU,$ARSS,$HCPU,$HUSED,$BB,$HB,$WB,$DISK,$SA,$BPS,$STATUS" >> "$OUT"
    case "$STATUS" in targets_dropped|host_ram_floor) break;; esac
  done

  case "$SCALE_STATUS" in
    targets_dropped|host_ram_floor) echo "   CEILING hit ($SCALE_STATUS) - stopping ramp"; break;;
  esac
done
stop_all
echo "-> $OUT"
