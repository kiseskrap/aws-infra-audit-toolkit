# Hospital Remote — On-Prem to Cloud Observability

Simulates a hospital deployment where a clinical service runs on-prem, but
operational health signals need to be visible from outside (developer laptop,
vendor support, TPM review) via a **single outbound HTTPS endpoint**.

This is not "put a hospital service on the internet." It is the opposite:
prove that a narrow, PHI-free, auditable metric stream is enough to run and
support the service remotely, while the raw patient data never leaves the
hospital network.

## When this lab is relevant

- Vendor supports a clinical product deployed inside multiple hospitals.
- The hospital IT policy does not permit inbound connectivity, only outbound
  HTTPS to a small allow-list of hosts.
- The organization does not have Datadog, or Datadog is not permitted in the
  clinical environment.
- The team needs a repeatable pattern that works across many hospital sites
  and that a security reviewer can read in one sitting.

## What this lab is NOT

- Not a replacement for Datadog. If Datadog is already deployed and permitted,
  keep using it.
- Not a way to exfiltrate patient data. The pipeline actively drops anything
  that looks like PHI (see [docs/phi-protection.md](./docs/phi-protection.md)).
- Not production-ready. Local containers, no HA, no persistence beyond 6 hours.
  Use it to prove the design; use a managed backend for production.

## Architecture

```text
+-------------------- Hospital on-prem --------------------+
|                                                          |
|   VitalCare (mock)     OTel Collector                    |
|   :8080 /metrics  -->  scrape + PHI-filter + batch  ---> |
|                                                          |
+----------------------------------------------------------+
                          |
                          |  HTTPS out (only)
                          |  single endpoint
                          v
+-------------------- Cloud backend -----------------------+
|                                                          |
|   Prometheus  <----  remote-write  <----                 |
|      ^                                                   |
|      |                                                   |
|   Grafana  --  developer / TPM / vendor support          |
|                                                          |
+----------------------------------------------------------+
```

In this local lab the two zones share a docker network. The container names
mimic the boundary so the reader can see the design.

## Prerequisites

- Docker Desktop (or equivalent) — running
- ~1.5 GB free RAM
- No AWS credentials required — this lab does not touch AWS

## Quick start

```bash
cd observability-lab/hospital-remote
docker compose up --build
```

Wait ~60 seconds for the OTel Collector to complete its first scrape and
push. Then open:

| Service | URL | Purpose |
|---|---|---|
| Grafana | <http://localhost:3001> (admin / admin) | Dashboard view — the developer's perspective |
| Cloud Prometheus | <http://localhost:9091> | Verify remote-write is receiving samples |
| VitalCare `/metrics` | <http://localhost:8081/metrics> | Verify the on-prem service is emitting metrics |

In Grafana → **Dashboards** → **hospital-remote** → **VitalCare — Service Health (PHI-free)**.

Expected within 1–2 minutes:
- `Service Up` shows `1`
- `Active Patients (aggregated)` shows a small number (5–20)
- `Vitals received per second` shows a non-zero line
- `Errors by class` shows occasional `ProcessingError` (1 % synthetic error rate)
- `PHI protection audit` table lists only the allow-listed label set

## Verify PHI defenses (automated)

The core claim of this lab — that PHI cannot cross the network boundary —
is verified by a red-team script:

```bash
./scripts/red-team-phi.sh
```

The script temporarily enables `RED_TEAM_MODE` on the VitalCare mock,
which makes it emit three deliberately non-compliant metrics, then
queries the cloud Prometheus to confirm none of them arrived. Exit code
0 = PASS, 1 = FAIL (compliance incident), 2 = infra error.

See [docs/red-team.md](./docs/red-team.md) for how this is designed,
what each attack vector tests, and how to wire it into CI.

## Verify WAN outage behavior (automated)

The second claim — that a WAN outage does not lose samples — is verified
by an outage-demo script:

```bash
./scripts/wan-outage-demo.sh
```

The script stops `cloud-prometheus` for 60 seconds (simulating WAN loss),
then starts it again and confirms the collector's in-memory queue
backfills the outage window into the cloud. Exit code 0 = PASS,
1 = data loss beyond tolerance, 2 = infra error.

See [docs/offline-behavior.md](./docs/offline-behavior.md) for the
buffering design, tuning knobs, and how to extend the in-memory queue
to a persistent disk queue for production.

## Files

```text
hospital-remote/
├── README.md                                ← this file
├── docker-compose.yml                       ← default: in-memory queue
├── docker-compose.file-storage.yml          ← overlay: disk-persisted queue (production template)
├── on-prem/
│   ├── vitalcare-mock/                      ← Flask + prometheus_client, no PHI (unless RED_TEAM_MODE)
│   │   ├── vitalcare_mock.py
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── otel-collector/
│       ├── config.yaml                      ← default in-memory pipeline
│       └── config.file-storage.yaml         ← disk-backed queue variant
├── cloud/
│   ├── prometheus/
│   │   └── prometheus.yml                   ← OTLP + remote-write receiver + OOO tolerance
│   └── grafana/
│       ├── provisioning/                    ← datasource + dashboard provider
│       └── dashboards/
│           └── vitalcare-service-health.json
├── scripts/
│   ├── red-team-phi.sh                      ← automated PHI defense verification
│   └── wan-outage-demo.sh                   ← simulate WAN loss + verify backfill
└── docs/
    ├── phi-protection.md                    ← how PHI is prevented from leaving
    ├── network-boundary.md                  ← single-endpoint outbound design
    ├── offline-behavior.md                  ← what happens when the WAN is down (+ demo + file_storage)
    ├── red-team.md                          ← how the verification works + CI usage
    └── applicability.md                     ← how a clinical vendor actually adopts this pattern
```

## Design principles (read before extending)

1. **Fail closed on labels.** Any metric label that is not on the allow-list is
   dropped. Adding a new label is a conscious two-step change: update the
   service *and* update the collector allow-list.
2. **Aggregated only.** Counters, histograms, gauges of population-level
   quantities. No per-patient labels ever.
3. **One outbound endpoint.** The security review artifact is "what is on the
   firewall allow-list." Keep it to one hostname.
4. **Local visibility survives WAN loss.** The on-prem side keeps buffering
   and remains observable from the on-prem management network even when the
   cloud side is unreachable. See `docs/offline-behavior.md`.
5. **Auditable.** A "PHI protection audit" panel is part of the default
   dashboard. If an unexpected label appears, that panel changes and someone
   notices.

## What to do after this lab

1. Read [`docs/phi-protection.md`](./docs/phi-protection.md) and reconcile
   the allow-list with your real clinical service's metric names.
2. Replace `cloud-prometheus` with a managed backend (Grafana Cloud, AWS
   Managed Prometheus, self-hosted Mimir) and put the ingest endpoint behind
   auth (bearer token, mTLS).
3. Add alerting rules for `vitalcare_service_up == 0` and error rate.
   Alertmanager is intentionally out of scope for this lab.
4. Extend the OTel Collector pipeline to include a resource attribute for
   the specific hospital site (`site_id`) so multi-tenant dashboards work.
5. Do a red-team pass: try to make the service emit a PHI-shaped metric and
   confirm the collector drops it. Record the finding.

## Related

- Parent lab: [`../README.md`](../README.md)
- Lab onboarding tutorial: [`../docs/onboarding.md`](../docs/onboarding.md)
- Toolkit roadmap: [`../../ROADMAP.md`](../../ROADMAP.md)
