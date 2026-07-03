#!/usr/bin/env bash
# wan-outage-demo.sh — simulate a WAN outage and verify the collector
# buffers samples through the outage and backfills them on recovery.
#
# Scenario:
#   1. Confirm the pipeline is flowing (samples arriving at cloud Prometheus).
#   2. Capture the current cumulative counter value from the mock's local
#      /metrics endpoint. This is the "ground truth" of what the on-prem
#      side has generated.
#   3. Stop cloud-prometheus (simulate WAN loss).
#   4. Wait through the outage. On-prem keeps running, mock keeps emitting,
#      collector's sending_queue accumulates.
#   5. Start cloud-prometheus again.
#   6. Wait for the queue to drain.
#   7. Confirm cloud Prometheus now shows a counter value close to the
#      on-prem ground truth. Any large gap = data was lost.
#
# Exit codes:
#   0 = PASS — backfill delivered the counters we expected
#   1 = FAIL — significant data loss detected
#   2 = infra error (stack not up, curl missing, etc.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSPITAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$HOSPITAL_ROOT/docker-compose.yml"

CLOUD_PROM_URL="${CLOUD_PROM_URL:-http://localhost:9091}"
MOCK_URL="${MOCK_URL:-http://localhost:8081}"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-60}"
# Drain long enough for the sending_queue to catch up. During drain, the
# on-prem side is still producing new samples, so drain has to outpace
# fresh production plus the queued backlog.
DRAIN_SECONDS="${DRAIN_SECONDS:-90}"
# Tolerated loss during backfill (percent of samples produced during the
# outage). The lab uses in-memory queue only; a small margin accounts for
# scrape-cycle alignment and the last-second drain frontier. In production
# with file_storage extension, aim for 0%.
LOSS_TOLERANCE_PCT="${LOSS_TOLERANCE_PCT:-15}"

log()   { printf "[wan-demo] %s\n" "$*"; }
warn()  { printf "[wan-demo] ⚠️  %s\n" "$*"; }
fail()  { printf "[wan-demo] ❌ %s\n" "$*" >&2; }
pass()  { printf "[wan-demo] ✅ %s\n" "$*"; }

# --- Preflight -------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not on PATH"
  exit 2
fi

if ! curl -sf "$CLOUD_PROM_URL/-/ready" >/dev/null; then
  fail "cloud Prometheus not ready at $CLOUD_PROM_URL"
  fail "run 'docker compose up -d' from $HOSPITAL_ROOT first"
  exit 2
fi

if ! curl -sf "$MOCK_URL/metrics" >/dev/null; then
  fail "vitalcare-mock /metrics not reachable at $MOCK_URL"
  exit 2
fi

log "preflight OK"

# --- Helpers ---------------------------------------------------------------

# Read a Prometheus counter from the mock's local /metrics endpoint.
# We pick a single, stable label set so the number is comparable across
# steps.
onprem_counter() {
  curl -s "$MOCK_URL/metrics" \
    | awk '/^vitalcare_vitals_received_total{/ { print $2; exit }' \
    | awk '{printf "%d", $1}'
}

# Query the same counter's most-recent value from cloud Prometheus.
cloud_counter() {
  curl -sf "$CLOUD_PROM_URL/api/v1/query?query=vitalcare_vitals_received_total" \
    2>/dev/null \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d.get("data", {}).get("result", [])
if not r:
    print("MISSING")
else:
    # There should be exactly one series in the lab.
    print(int(float(r[0]["value"][1])))
'
}

# --- Step 1: baseline ------------------------------------------------------

log "step 1 — establishing baseline (pipeline is flowing)"
sleep 15  # let one clean scrape cycle happen

baseline_cloud=$(cloud_counter)
if [[ "$baseline_cloud" == "MISSING" ]] || [[ "$baseline_cloud" -eq 0 ]]; then
  fail "cloud Prometheus has no vitalcare_vitals_received_total samples yet"
  fail "let the stack settle for a minute and try again"
  exit 2
fi
pass "baseline cloud counter = $baseline_cloud"

# --- Step 2: simulate WAN loss --------------------------------------------

log "step 2 — simulating WAN outage: stopping cloud-prometheus"
docker compose -f "$COMPOSE_FILE" stop cloud-prometheus >/dev/null

before_outage_onprem=$(onprem_counter)
log "  on-prem counter at start of outage: $before_outage_onprem"

log "  outage in progress — sleeping ${OUTAGE_SECONDS}s"
log "  (on-prem service keeps emitting; collector queues samples)"
sleep "$OUTAGE_SECONDS"

after_outage_onprem=$(onprem_counter)
delta=$((after_outage_onprem - before_outage_onprem))
log "  on-prem counter at end of outage: $after_outage_onprem (Δ=$delta produced during outage)"

if [[ "$delta" -le 0 ]]; then
  fail "on-prem side stopped producing during outage — this violates offline invariant"
  docker compose -f "$COMPOSE_FILE" start cloud-prometheus >/dev/null
  exit 1
fi
pass "on-prem service kept producing during the outage (Δ=$delta samples)"

# --- Step 3: recovery ------------------------------------------------------

log "step 3 — WAN recovery: starting cloud-prometheus"
docker compose -f "$COMPOSE_FILE" start cloud-prometheus >/dev/null

# Wait for the cloud endpoint to come back up.
for _ in $(seq 1 20); do
  if curl -sf "$CLOUD_PROM_URL/-/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! curl -sf "$CLOUD_PROM_URL/-/ready" >/dev/null; then
  fail "cloud Prometheus did not become ready after restart"
  exit 2
fi

log "  cloud Prometheus is up. draining collector queue for ${DRAIN_SECONDS}s…"
sleep "$DRAIN_SECONDS"

# --- Step 4: verify backfill ----------------------------------------------

log "step 4 — verifying backfill"

recovered_cloud=$(cloud_counter)
if [[ "$recovered_cloud" == "MISSING" ]]; then
  fail "cloud has NO samples after recovery — backfill failed entirely"
  exit 1
fi

# The recovered cloud counter should be close to the current on-prem
# counter. Any gap = data lost.
current_onprem=$(onprem_counter)

log "  on-prem now: $current_onprem"
log "  cloud now:   $recovered_cloud"

gap=$((current_onprem - recovered_cloud))
if [[ "$gap" -lt 0 ]]; then gap=0; fi

# Tolerance: LOSS_TOLERANCE_PCT of what was produced during the outage.
tolerance=$((delta * LOSS_TOLERANCE_PCT / 100))
if [[ "$tolerance" -lt 5 ]]; then tolerance=5; fi

log "  gap: $gap samples (tolerance $tolerance)"

# --- Verdict --------------------------------------------------------------

echo
if [[ "$gap" -le "$tolerance" ]]; then
  pass "PASS — backfill closed the outage gap within tolerance"
  echo "     produced during outage: $delta samples"
  echo "     cloud caught up to within: $gap samples"
  echo "     collector sending_queue + retry worked as designed"
  exit 0
else
  fail "FAIL — significant data loss detected"
  fail "  produced during outage: $delta samples"
  fail "  remaining gap:          $gap samples"
  fail "  tolerance:              $tolerance samples"
  fail
  fail "possible causes:"
  fail "  1. Collector sending_queue was too small (queue_size)"
  fail "  2. Outage exceeded retry max_elapsed_time"
  fail "  3. Cloud Prometheus did not accept out-of-order samples"
  fail
  fail "see docs/offline-behavior.md for tuning guidance"
  exit 1
fi
