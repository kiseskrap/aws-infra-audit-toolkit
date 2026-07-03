# Applicability — How a Clinical Vendor Actually Adopts This Pattern

This lab is a working demonstration of a pattern, not a drop-in system.
Real hospital deployments require decisions this lab deliberately did not
make. This document is a map of those decisions, in the order a clinical
vendor typically has to make them.

Read this if you are considering the pattern for a real deployment.

## The pattern in one sentence

> On-prem clinical service emits aggregated, PHI-free operational metrics.
> A hospital-side OTel Collector enforces a PHI allow-list and forwards
> over a single outbound HTTPS endpoint to a cloud backend, buffering
> through WAN outages, so a support engineer can see service health from
> outside without ever touching patient data.

Everything below is what changes when you take that sentence to a real
hospital.

## Who this pattern fits

- Vendors of clinical software installed inside hospitals or clinics,
  where the deployment is behind hospital IT firewalls.
- Vendors whose customers span many sites and where visiting each site
  for troubleshooting is not viable.
- Deployments where the customer's IT policy allows outbound HTTPS to a
  vendor-controlled endpoint but does not permit inbound traffic.
- Products where the vendor has an existing engineering or support team
  that already runs on-call for other software and can extend on-call to
  cover the clinical product.

## Who this pattern does not fit

- Cloud-native SaaS where the service already runs in the vendor's cloud
  and Datadog / Grafana Cloud / Datadog Cluster Agent are appropriate.
  The complexity of this pattern only makes sense when the service must
  run inside the hospital.
- Regulated environments where **no** outbound connectivity is permitted
  from the clinical network. In that case a physical log/metric export
  (USB, dedicated line, or scheduled manual pull) is the only option and
  this pattern does not apply.
- Very small vendors with a single hospital site and a direct customer
  relationship. Just SSH in.

## Decisions the vendor has to make (this lab does not decide for you)

### 1. Choice of cloud backend

The lab uses a local Prometheus for demo purposes. Real options:

| Backend | When it fits |
|---|---|
| Grafana Cloud (free tier or paid) | Small vendor, quick to start, OTLP receiver built in. |
| AWS Managed Prometheus (AMP) | Already in AWS, want IAM-based auth, no separate contract. |
| Self-hosted Mimir/Cortex | Multi-tenant vendor with many sites, willing to run infra. |
| Grafana OSS + Thanos/Mimir | Full control, largest engineering investment. |

The collector's `otlphttp` exporter is unchanged across all four choices.
Only the endpoint URL and auth headers differ.

### 2. Authentication

The lab has none. Every real deployment needs:

- **Per-site credential**: a bearer token or client cert scoped to one
  hospital. Compromise of one site's credential must not affect any other.
- **Rotation policy**: how often, who does it, what happens if a rotation
  fails.
- **Secret storage on-prem**: the collector reads the credential from a
  local secret store (Vault Agent, HashiCorp Vault, AWS Systems Manager
  Parameter Store via SSM Agent, or a filesystem secret managed by the
  vendor's deploy tool). Never commit it.
- **Cloud-side enforcement**: reject any sample that does not carry a
  valid `tenant_id` matching the credential's scope.

### 3. Tenancy and label conventions

This lab hard-codes `hospital_id: hospital-demo` on a single site. Real
deployments must decide:

- **`hospital_id`**: unique per contract or per physical hospital?
  (Contracts with multi-site hospitals sometimes want per-site metrics.)
- **`site_id`** vs **`ward_id`**: how many levels of location granularity?
  Too granular = high cardinality; too coarse = you can't tell one ward
  from another during an incident.
- **`service.name`** and **`service.version`**: keep these in the
  resource attribute allow-list from day one.
- **PHI red lines**: reaffirm patient_id, MRN, DOB, name, SSN, and free-text
  fields are on the block-list. Add anything jurisdiction-specific.

The lab's allow-list is:
```
hospital_id, ward_id, service_version, origin, collector.id, error_class
```
That is a reasonable starting point but not a specification.

### 4. Network policy artifacts

The hospital security reviewer will ask for these documents. Prepare
them before the review:

1. **Firewall rule**: exactly one outbound rule to one hostname on TCP
   443. See [`network-boundary.md`](./network-boundary.md).
2. **DNS**: which vendor-controlled hostname the collector resolves.
3. **TLS**: what CA the collector trusts, and how the vendor rotates
   the ingest certificate.
4. **Data classification**: a table stating that the outbound traffic is
   "aggregated operational metrics, not clinical data" and how the vendor
   enforces that classification (see [`phi-protection.md`](./phi-protection.md)).
5. **Auditability**: the samples of what actually gets emitted. The lab's
   `red-team-phi.sh` output is a good starting artifact.

### 5. On-prem operational ownership

The collector runs on hospital hardware. Someone has to own it.

- **Deploy mechanism**: SSM Agent, Fleet, Ansible, or vendor-specific
  installer. The lab uses `docker compose` — a real vendor typically
  packages the collector as a systemd service or a small Kubernetes
  deployment on a hospital-provided cluster.
- **Upgrade cadence**: when the vendor ships a new collector config or
  new agent version, how does it land on all sites? Manual, self-update,
  or coordinated by hospital IT?
- **Monitoring the monitor**: what alerts fire if the collector itself
  is unhealthy? A missing signal is worse than a bad signal.

### 6. Regulatory and BAA scope

Even aggregate metrics can be sensitive in some jurisdictions.

- **HIPAA (US)**: aggregated non-identifying metrics are typically not
  PHI, but the deployment context (which hospital) can be enough for a
  BAA to be required, especially if the vendor also handles PHI elsewhere.
- **개인정보보호법 / 의료법 (KR)**: 병원 내부 데이터의 국외 이전은 별도 검토가
  필요합니다. 집계 지표라도 "그 병원에서 몇 명 monitoring 중"이 재식별 벡터가
  될 수 있는지, 자문받으세요.
- **GDPR (EU)**: aggregate at the tenant level is usually fine, but very
  small populations plus timing can re-identify. Consider minimum
  cardinality thresholds.

Talk to counsel. This lab is not legal advice.

### 7. What to build first (a suggested order)

If you are starting from zero, this is a reasonable milestone sequence:

1. **Week 0 — Design review**: use this lab as a shared reference.
   Confirm the pattern fits your product. Read PHI, network, offline docs
   with your security lead.
2. **Week 1–2 — Collector proof-of-life**: pick your cloud backend, get
   one hospital-like environment (staging network) to emit metrics
   successfully.
3. **Week 3 — PHI verification harness**: fork this lab's red-team script
   for your real metric shapes. Wire it into CI.
4. **Week 4 — WAN outage verification**: prove the buffering pattern
   works with your chosen backend. Note that some managed backends may
   not accept out-of-order samples by default — either enable that
   setting or shorten your outage promise.
5. **Week 5+ — Auth, tenancy, deploy tooling, alerting, on-call**: these
   are the real work. The lab intentionally stops short of them.

## Two failure modes to plan for from day one

### Silent PHI drift

Someone adds a debug label. It survives review because the reviewer
looked at the code, not at the pipeline. Two weeks later a shared
dashboard shows the drift. This is the failure mode
`red-team-phi.sh` exists for. Wire it into CI on day one, not month six.

### Silent outage backfill drift

Someone tunes the collector's `sending_queue` down because "we hit our
RAM budget on that hospital's collector host." Six weeks later a longer
outage is silently truncated. Wire the WAN outage demo into CI too, and
alert on-call when a hospital's `sending_queue_length` metric grows
above a threshold that indicates the backfill is not draining.

## What this lab intentionally omits (again)

- Alertmanager and any alert routing.
- Traces and logs pipelines (metrics only).
- YACE for AWS service metrics (the parent lab covers that).
- Multi-collector high availability.
- Chaos engineering beyond the two scripted scenarios.

Each of these is a legitimate future extension. All of them are out of
scope of a proof-of-concept lab and belong in a real vendor engineering
project.

## Reading order for a new engineer joining the project

1. `README.md` — what the lab is.
2. `docs/phi-protection.md` — the non-negotiable defense principle.
3. `docs/network-boundary.md` — how the deployment survives a security
   review.
4. `docs/offline-behavior.md` — what happens when the WAN fails.
5. `docs/red-team.md` — how the PHI defense is proven.
6. `docs/applicability.md` — this file — how the pattern turns into a
   real deployment.

That order takes about an hour. After it, an engineer new to the project
should be able to answer "why is the collector there?" without hedging.
