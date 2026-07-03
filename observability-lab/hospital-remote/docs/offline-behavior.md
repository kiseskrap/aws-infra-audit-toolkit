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

## Automated WAN outage demo

The scenario above is automated as
[`scripts/wan-outage-demo.sh`](../scripts/wan-outage-demo.sh). It exists so
"WAN loss is safe" is a reproducible claim, not an assertion.

Preconditions: stack is up (`docker compose up -d`), all four containers
running, cloud Prometheus reachable at <http://localhost:9091>.

Run it:

```bash
cd observability-lab/hospital-remote
./scripts/wan-outage-demo.sh
```

Expected output on a healthy stack:

```
[wan-demo] preflight OK
[wan-demo] step 1 — establishing baseline (pipeline is flowing)
[wan-demo] ✅ baseline cloud counter = 43
[wan-demo] step 2 — simulating WAN outage: stopping cloud-prometheus
[wan-demo]   on-prem counter at start of outage: 51
[wan-demo]   outage in progress — sleeping 60s
[wan-demo]   on-prem counter at end of outage: 108 (Δ=57 produced during outage)
[wan-demo] ✅ on-prem service kept producing during the outage (Δ=57 samples)
[wan-demo] step 3 — WAN recovery: starting cloud-prometheus
[wan-demo]   cloud Prometheus is up. draining collector queue for 45s…
[wan-demo] step 4 — verifying backfill
[wan-demo]   on-prem now: 132
[wan-demo]   cloud now:   130
[wan-demo]   gap: 2 samples (tolerance 5)

[wan-demo] ✅ PASS — backfill closed the outage gap within tolerance
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | PASS — collector queued through outage and cloud caught up on recovery |
| 1 | FAIL — significant sample loss detected |
| 2 | Infra error — stack not up or curl missing |

Tunables via env: `OUTAGE_SECONDS` (default 60), `DRAIN_SECONDS` (default 45),
`LOSS_TOLERANCE_PCT` (default 5).

### What the script actually verifies

1. **On-prem keeps running during the outage.** The mock's local
   `vitalcare_vitals_received_total` counter must increase while
   cloud-prometheus is stopped. If it does not, the offline invariant is
   already broken and the rest of the pipeline is irrelevant.
2. **Collector buffers samples.** The `sending_queue` configured on the
   `prometheusremotewrite` exporter keeps samples in memory while the
   remote endpoint is unreachable.
3. **Recovery backfills.** After cloud-prometheus restarts, the collector's
   background workers drain the queue. The cloud counter should catch up to
   within a small tolerance of the on-prem counter.

## What the collector is configured to do (this lab)

From `on-prem/otel-collector/config.yaml`:

```yaml
prometheusremotewrite:
  endpoint: http://cloud-prometheus:9090/api/v1/write
  sending_queue:
    enabled: true
    num_consumers: 4
    queue_size: 10000
  retry_on_failure:
    enabled: true
    initial_interval: 5s
    max_interval: 30s
    max_elapsed_time: 15m
```

Interpretation:

- `sending_queue.queue_size: 10000` — the collector will hold up to 10 000
  batches in memory before it starts dropping oldest.
- `retry_on_failure.max_elapsed_time: 15m` — after 15 minutes of failure
  the collector will give up on a batch (and the queue will drop it).
- `num_consumers: 4` — four concurrent drain workers on recovery, so the
  backfill catches up faster than the current scrape rate.

For a lab with 5-second sampling and ~10 samples per scrape, 10 000 batches
easily covers a multi-hour outage. In production, size the queue for the
worst outage you must survive.

## Extending to a real deployment

### file_storage: on-disk queue that survives collector restarts

The default lab flow uses an in-memory queue. That is fine for
demonstrating the pattern, but it has two limits:

- **Collector restart wipes the queue.** If the on-prem collector
  restarts during a WAN outage — deploy, machine reboot, OOM — everything
  in RAM is gone.
- **Multi-hour outages** can outgrow the RAM budget.

The collector's `file_storage` extension solves both by persisting the
queue to disk. This lab ships a ready-to-use variant.

**Activate it:**

```bash
cd observability-lab/hospital-remote
docker compose \
  -f docker-compose.yml \
  -f docker-compose.file-storage.yml \
  up -d --build
```

The overlay swaps in `on-prem/otel-collector/config.file-storage.yaml`
and mounts a named volume `hospital-remote-otelcol-queue` at
`/var/lib/otelcol/queue` inside the collector container.

The variant differs from the default config in three ways:

| Aspect | Default (in-memory) | file_storage variant |
|---|---|---|
| Queue location | RAM | On-disk (`/var/lib/otelcol/queue`) |
| `queue_size` | 10,000 batches | 200,000 batches |
| `max_elapsed_time` | 15m | 6h |
| Survives restart? | ❌ | ✅ |

Reason for the differences: disk is cheap, so the queue can be much
larger; and if you are already paying for disk persistence, the retry
budget should reflect a realistic hospital WAN outage window
(hours, not minutes).

**Demonstrate the restart-survival behavior manually:**

```bash
# 1. Bring up the file_storage variant.
docker compose -f docker-compose.yml -f docker-compose.file-storage.yml up -d --build

# 2. Simulate WAN loss.
docker compose stop cloud-prometheus

# 3. Kill the collector midway to prove disk persistence.
docker compose kill otel-collector
docker compose up -d otel-collector

# 4. Bring the cloud back.
docker compose start cloud-prometheus

# 5. Verify: buffered samples arrive after both the WAN and the
#    collector restart. `vitalcare_vitals_received_total` should show a
#    continuous line in Grafana without a gap.
```

**Sizing reminder**: for a service emitting ~50 samples per 15-second
scrape, a 24-hour WAN outage produces ~288 000 samples. Put the queue on
a dedicated volume, not shared with any clinical data path.

## What is still out of scope for this lab

- **Rate-limited recovery** to protect the cloud ingest from thundering-herd
  behaviour when many hospital sites reconnect at once. Real vendors add
  jittered backoff on the ingest side.
- **Regional failover** — if the primary cloud region is unreachable, does
  the collector fall through to a secondary? This lab uses a single
  endpoint by design (see `network-boundary.md`).
- **Explicit alerts on the cloud side** for "no samples from tenant X in
  Y minutes". Alertmanager is deliberately excluded from this lab.
