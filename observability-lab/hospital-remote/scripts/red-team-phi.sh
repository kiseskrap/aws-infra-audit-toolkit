#!/usr/bin/env bash
# red-team-phi.sh — verify the OTel Collector's PHI defenses actually block
# PHI-shaped metrics.
#
# What it does:
#   1. Restart the VitalCare mock in RED_TEAM_MODE=true. In that mode the
#      mock deliberately emits three PHI-shaped metrics.
#   2. Wait long enough for the OTel Collector to have completed at least
#      two scrape+export cycles.
#   3. Query the cloud Prometheus and confirm NONE of the PHI metrics
#      arrived, AND that no series has a patient_id label.
#   4. Restore the mock to normal mode.
#
# Exit codes:
#   0 = PASS — PHI defenses held
#   1 = FAIL — PHI made it through (this is a compliance incident)
#   2 = infra error (stack not up, Prom not reachable, docker missing)
#
# Usage:
#   ./scripts/red-team-phi.sh
#
# Prereqs:
#   - docker compose stack is already up (docker compose up -d)
#   - cloud Prometheus reachable at http://localhost:9091

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOSPITAL_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$HOSPITAL_ROOT/docker-compose.yml"

CLOUD_PROM_URL="${CLOUD_PROM_URL:-http://localhost:9091}"
WAIT_SECONDS="${WAIT_SECONDS:-45}"

log() { printf "[red-team] %s\n" "$*"; }
fail() { printf "[red-team] ❌ %s\n" "$*" >&2; }
pass() { printf "[red-team] ✅ %s\n" "$*"; }

# --- Preflight -------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not on PATH"
  exit 2
fi

if ! docker compose -f "$COMPOSE_FILE" ps --format json >/dev/null 2>&1; then
  fail "docker compose stack not initialized. Run 'docker compose up -d' first."
  exit 2
fi

running=$(docker compose -f "$COMPOSE_FILE" ps --services --filter status=running 2>/dev/null | wc -l | tr -d ' ')
if [[ "$running" -lt 4 ]]; then
  fail "expected 4 containers running, got $running"
  fail "run 'docker compose -f $COMPOSE_FILE up -d' and try again"
  exit 2
fi

if ! curl -sf "$CLOUD_PROM_URL/-/ready" >/dev/null; then
  fail "cloud Prometheus not ready at $CLOUD_PROM_URL"
  exit 2
fi

log "preflight OK — 4 containers running, cloud Prometheus reachable"

# --- Enable red-team on the mock -------------------------------------------

log "enabling RED_TEAM_MODE on vitalcare-mock…"
# Recreate the mock container with the env var set.
# `docker compose run --rm` would create a one-off, so we use `up` with
# an override instead via a tempfile.
override_file=$(mktemp -t red-team-override.XXXXXX.yml)
trap 'rm -f "$override_file"' EXIT
cat > "$override_file" <<'YAML'
services:
  vitalcare-mock:
    environment:
      RED_TEAM_MODE: "true"
YAML

if ! docker compose -f "$COMPOSE_FILE" -f "$override_file" up -d vitalcare-mock >/dev/null 2>&1; then
  fail "failed to restart vitalcare-mock with RED_TEAM_MODE=true"
  exit 2
fi

# --- Sanity: the mock IS emitting PHI locally (would fail otherwise) -------

log "waiting 5s for mock to start emitting…"
sleep 5

# Reach the mock's /metrics directly (on-prem side, before any filtering).
mock_url="http://localhost:8081/metrics"
if ! curl -sf "$mock_url" >/dev/null; then
  fail "vitalcare-mock /metrics not reachable at $mock_url"
  exit 2
fi

local_leaked=0
if curl -s "$mock_url" | grep -q '^vitalcare_patient_id_leaked_total{'; then
  local_leaked=$((local_leaked + 1))
fi
if curl -s "$mock_url" | grep -q '^vitalcare_mrn_lookups_total{'; then
  local_leaked=$((local_leaked + 1))
fi
if curl -s "$mock_url" | grep -qE '^vitalcare_vitals_by_patient_total\{[^}]*patient_id='; then
  local_leaked=$((local_leaked + 1))
fi

if [[ "$local_leaked" -ne 3 ]]; then
  fail "sanity check failed — expected 3 PHI-shaped metrics locally, saw $local_leaked"
  fail "the red-team traffic never started; this is a test infrastructure bug, not a filter incident"
  exit 2
fi

pass "sanity: vitalcare-mock IS emitting 3 PHI-shaped metrics locally (as intended)"

# --- Wait for collector to have scraped + exported --------------------------

log "waiting ${WAIT_SECONDS}s for OTel Collector to scrape + export at least twice…"
sleep "$WAIT_SECONDS"

# --- Check the cloud side --------------------------------------------------

query_series_count() {
  local promql="$1"
  # Use the label endpoint for existence rather than instant query.
  # We simply ask Prometheus if any series matches the name filter.
  local encoded
  encoded=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$promql")
  local response
  response=$(curl -sf "$CLOUD_PROM_URL/api/v1/series?match%5B%5D=${encoded}" 2>/dev/null || echo '{"data":[]}')
  echo "$response" | python3 -c 'import sys,json;print(len(json.load(sys.stdin).get("data",[])))'
}

violation_count=0
log "checking cloud Prometheus for PHI leakage…"

# Attack 1
c1=$(query_series_count 'vitalcare_patient_id_leaked_total')
if [[ "$c1" -gt 0 ]]; then
  fail "leak #1: vitalcare_patient_id_leaked_total is present in cloud ($c1 series)"
  violation_count=$((violation_count + 1))
else
  pass "attack 1 blocked: vitalcare_patient_id_leaked_total is NOT in cloud"
fi

# Attack 2
c2=$(query_series_count 'vitalcare_mrn_lookups_total')
if [[ "$c2" -gt 0 ]]; then
  fail "leak #2: vitalcare_mrn_lookups_total is present in cloud ($c2 series)"
  violation_count=$((violation_count + 1))
else
  pass "attack 2 blocked: vitalcare_mrn_lookups_total is NOT in cloud"
fi

# Attack 3 — the metric name is innocent, but the label carries patient_id.
# The metric MAY appear in the cloud (it's not PHI-named), but no series
# should carry a patient_id label. Check both.
c3_metric=$(query_series_count 'vitalcare_vitals_by_patient_total')
if [[ "$c3_metric" -gt 0 ]]; then
  # OK — the metric name is not PHI. But the label must have been scrubbed.
  # Query the actual series and look at their labels.
  labels_json=$(curl -sf "$CLOUD_PROM_URL/api/v1/series?match%5B%5D=vitalcare_vitals_by_patient_total" 2>/dev/null || echo '{"data":[]}')
  bad_series=$(echo "$labels_json" | python3 -c '
import sys, json
d = json.load(sys.stdin)
bad = [s for s in d.get("data", []) if "patient_id" in s]
print(len(bad))
')
  if [[ "$bad_series" -gt 0 ]]; then
    fail "leak #3: vitalcare_vitals_by_patient_total kept the patient_id label ($bad_series series)"
    violation_count=$((violation_count + 1))
  else
    pass "attack 3 blocked: patient_id label was scrubbed from vitalcare_vitals_by_patient_total"
  fi
else
  # Metric didn't make it either; also acceptable.
  pass "attack 3 blocked: vitalcare_vitals_by_patient_total is NOT in cloud at all"
fi

# --- Restore the mock to normal mode --------------------------------------

log "restoring vitalcare-mock to normal (RED_TEAM_MODE off)…"
docker compose -f "$COMPOSE_FILE" up -d vitalcare-mock >/dev/null 2>&1 || true

# --- Verdict ----------------------------------------------------------------

echo
if [[ "$violation_count" -eq 0 ]]; then
  pass "PASS — all 3 PHI attack vectors were blocked by the OTel Collector"
  echo "     evidence: series match count reported above."
  exit 0
else
  fail "FAIL — $violation_count of 3 PHI attack vectors leaked to the cloud"
  fail "this is a COMPLIANCE INCIDENT. Review:"
  fail "  1. on-prem/otel-collector/config.yaml — is transform/allowlist correct?"
  fail "  2. on-prem/otel-collector/config.yaml — is filter/drop_phi_metrics correct?"
  fail "  3. cloud-prometheus may still have stale samples — restart it:"
  fail "     docker compose -f $COMPOSE_FILE restart cloud-prometheus"
  exit 1
fi
