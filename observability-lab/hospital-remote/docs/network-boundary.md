# Network Boundary

The boundary between the hospital and the cloud is the single most reviewed
part of any clinical-vendor deployment. This document is the artifact you
hand to a hospital security reviewer.

## The one rule

**One outbound HTTPS endpoint. Nothing inbound. No exceptions.**

Everything downstream of this decision follows from it.

## What the hospital firewall needs to allow

| Direction | Protocol | Destination | Purpose | How often |
|---|---|---|---|---|
| Outbound | HTTPS (TCP 443) | `metrics-ingest.<vendor>.example.com` | OTel Collector remote-write | ~every 5s (batch) |

Nothing else. No inbound, no other ports, no other hostnames.

## What the hospital firewall MUST NOT allow

| Direction | Why not |
|---|---|
| Inbound from cloud → hospital | Would let the cloud (or an attacker who compromises the cloud) reach the clinical service. Never. |
| Outbound to arbitrary internet | Turns the collector into an exfiltration vector if compromised. Restrict to the vendor's ingest endpoint only. |
| Outbound HTTP (unencrypted) | HTTPS is mandatory. |
| Direct DB access from cloud | If the cloud needs to query metrics, it queries the cloud-side Prometheus, not the hospital-side DB. |

## Failure modes and their intended behavior

| Failure | What should happen | What must NOT happen |
|---|---|---|
| Cloud ingest unreachable | Collector buffers samples locally, retries with backoff | Collector must not switch to a fallback endpoint or write to disk unencrypted |
| DNS resolution fails for the ingest hostname | Collector logs a warning, continues buffering | Collector must not attempt any other hostname |
| Cloud TLS certificate mismatch | Collector refuses to send | Collector must not disable TLS verification |
| Hospital lost internet for hours | On-prem service keeps running normally, on-prem operators keep local visibility via a local Prometheus if deployed | Clinical function must not depend on cloud reachability |

## Auth and identity

- **Ingest auth** — bearer token or mTLS. Rotated per hospital site. Compromise
  of one site's token affects only that site.
- **Tenancy label** — the collector adds `hospital_id` (and optionally
  `site_id`) resource attributes. The cloud enforces tenant isolation on
  those labels.
- **Per-site secrets** — stored in a hospital-local secret store, never
  committed to source control.

## Egress vs OT/IT segmentation

In a hospital, the observability collector should live on the **IT** network
segment, not on the **OT** (operational technology, clinical device) segment.
The clinical service scrapes into the collector across the internal IT-OT
boundary if applicable, and only the IT-side collector talks to the internet.

## Traceability

Every outbound sample should be traceable back to a policy decision. The
following minimal metadata should be attached at the collector:

- `hospital_id` — which site sent it
- `collector.id` — which collector instance sent it
- `service.name` — which clinical service produced it
- (optional) `policy_version` — which allow-list config was in effect

The cloud side stores these as tenant labels so a security investigation can
answer "which site emitted this bad sample, from which config version" in one
query.

## What this lab does not simulate

Real deployment adds several concerns this lab omits for clarity:

- **TLS** — the local lab uses plaintext HTTP inside the docker network. In
  production, the collector connects to the cloud over HTTPS with certificate
  pinning.
- **Auth** — no bearer token in the local exporter config. In production,
  the token is injected via `${env:CLOUD_INGEST_TOKEN}`.
- **Rate limiting** — the cloud ingest rate-limits per hospital. Not modelled
  here.
- **Regional routing** — a real deployment routes hospitals to region-local
  ingest endpoints for latency and data residency reasons.
