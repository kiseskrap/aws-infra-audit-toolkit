# Offline Behavior

The single most important safety property of this pipeline is that when the
wide-area network fails, the hospital keeps working. Nothing about the
clinical service should depend on the cloud being reachable.

## The invariants

1. **Clinical function does not depend on the cloud.** The service treats the
   collector and the cloud ingest as best-effort export. Losing them changes
   nothing about patient care.
2. **On-prem operators keep visibility.** A local Prometheus (optional but
   recommended) continues to scrape and store metrics on-prem for the duration
   of a WAN outage.
3. **No data loss for the observed retention window.** The collector buffers
   samples during a WAN outage up to a configured limit, then drops the
   oldest.
4. **Recovery is automatic.** When the WAN returns, the collector drains the
   buffer to the cloud with rate-limiting so it does not overwhelm ingest.
5. **The failure is loud on both sides.** An outage should appear on both a
   local dashboard and the cloud dashboard (as absence of samples). Silent
   failures are the worst outcome.

## What happens in each layer

### VitalCare service

- Continues to serve `/health` and `/metrics` normally.
- Does not depend on the collector or the cloud for any operation.
- If the on-prem management network is intact, on-prem operators can reach
  `/metrics` directly for local diagnosis.

### OTel Collector

- Continues to scrape VitalCare.
- Retries remote-write with exponential backoff.
- Buffers samples in memory (default) or on disk (opt-in). For a real
  deployment, size the buffer to cover expected WAN outage duration.
- Logs a warning per failed export batch. Log line count should trigger a
  local alarm if it grows.

### Cloud Prometheus

- Simply stops receiving samples from the affected hospital.
- A cloud-side alert should fire on "no samples from tenant $X in $Y minutes"
  so support knows a site is silent.

### Grafana

- Panels for the affected hospital show "no data" during the outage.
- After recovery, the buffered samples arrive and backfill the time series.

## Operator playbook

If you notice `vitalcare_service_up` disappears from the cloud dashboard:

1. **Confirm the scope.** Is it one hospital or all? Look at the number of
   affected `hospital_id` labels.
2. **Check the cloud ingest health.** If the ingest is degraded, a batch of
   hospitals will drop together. This is a cloud-side incident, not a
   hospital-side one.
3. **Ping the on-prem contact.** Ask them to reach the local `/metrics`
   endpoint at `http://vitalcare-mock:8080/metrics` from the on-prem
   management network. If that works, the clinical service is fine and the
   problem is between the collector and the cloud.
4. **Check the OTel Collector logs.** If the collector is reachable, look at
   its own logs for `remote-write` errors. TLS mismatch, auth token expired,
   or DNS resolution errors are the common causes.
5. **Do not attempt to modify the clinical service** to work around an
   observability outage. The observability channel is separate from patient
   care and must fail without cascading.

## Buffer sizing (real deployment)

For a single VitalCare-like service emitting ~50 samples per scrape at 15s
intervals, a 4-hour WAN outage produces ~48,000 samples. That fits comfortably
in the collector's in-memory buffer, but longer outages need disk buffering.

Recommended defaults for a real deployment:

- Buffer target duration: 24 hours
- Storage: local disk with dedicated volume (do not share with clinical data)
- Compression: enabled
- Retention semantics: drop oldest when full, always keep the newest
- Alarm: local alarm when buffer usage exceeds 70 %

## What is out of scope for this lab

The local lab does not simulate WAN loss automatically. To see the intended
behavior, disrupt it manually:

```bash
# Simulate cloud ingest failure:
docker compose stop cloud-prometheus

# Wait ~5 minutes. The collector's logs should now show export failures.
docker compose logs otel-collector --tail 20

# Bring the cloud back:
docker compose start cloud-prometheus

# The Grafana dashboard should recover within the next scrape cycle.
```

Longer outages, buffered-to-disk semantics, and rate-limited recovery are all
straightforward to add in a real deployment but are intentionally omitted here
to keep the lab small.
