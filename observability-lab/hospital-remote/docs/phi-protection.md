# PHI Protection

The purpose of this document is to make the PHI (Protected Health Information)
handling of this lab **explicit and reviewable**. Read this before extending
the pipeline.

## Principle

**PHI never leaves the hospital network. Only aggregated, non-identifying
operational metrics are forwarded to the cloud backend.**

That principle is enforced in three layers, from earliest to latest. Any one
of them alone would be insufficient. Together they form defense in depth.

## Layer 1 — At the service (VitalCare mock)

The clinical service is responsible for **not creating PHI-shaped metrics in
the first place**.

Rules enforced in `vitalcare_mock.py`:

- Label set is fixed to `hospital_id`, `ward_id`, `service_version`,
  `error_class`. Any new label requires a code change and code review.
- No patient identifiers (patient_id, MRN, name, DOB, SSN) appear as label
  values or metric names.
- No vital-sign values (heart rate, SpO₂, blood pressure) are used as label
  values. They may appear as histogram bucket boundaries only if the boundary
  set is standard clinical ranges shared across all patients.
- Error messages are converted to a **bounded** `error_class` label value
  before they touch a metric. Free-form exception text is not exposed.
- The `/metrics` endpoint is served on the on-prem management network only,
  not on the patient-facing interface.

## Layer 2 — At the OTel Collector

The collector runs inside the hospital and is the **enforcement point** for
what is allowed to leave.

Rules enforced in `on-prem/otel-collector/config.yaml`:

- **Allow-list processor** — `attributes/allowlist`: only the labels
  `hospital_id`, `ward_id`, `service_version`, `origin`, `collector.id` may
  cross the boundary. Everything else is dropped.
- **Filter processor** — `filter/drop_phi_metrics`: any metric whose *name*
  matches PHI cues (`_patient_id_`, `_mrn_`, `_name`, `_ssn`) is dropped
  entirely. This is a belt-and-braces defense against accidental service
  changes.
- **Batching** — reduces outbound request count and gives the operator a
  natural rate-limit choke point.
- **Debug exporter** with sampling — samples 1 of every 200 batches to the
  collector's own log so the operator can spot-check what is being emitted.

## Layer 3 — At the ingest endpoint (cloud side)

The cloud backend can enforce independent policy:

- Reject any incoming sample whose label set is a superset of the allow-list.
  (Requires a proxy or a Mimir/Cortex rule; not implemented in this lab.)
- Rate-limit per `hospital_id` tenant.
- Audit-log all writes with `hospital_id`, sample count, and sample age.

## Audit and detection

Two signals help the operator detect a policy drift:

1. **The Grafana dashboard's "PHI protection audit" panel** lists the label
   set observed on VitalCare metrics. If an unexpected label appears there,
   Layer 1 or Layer 2 has drifted.
2. **Collector logs** at the debug exporter sample rate. If an unexpected
   metric name reaches the logs, someone renamed a service metric without
   updating Layer 2.

Neither signal is a substitute for code review, but both fail loud enough to
notice.

## What does NOT belong in this pipeline

- **Raw waveform data.** Waveforms must stay on-prem. Store them in a local
  time-series or dedicated clinical archive.
- **Raw log lines.** Even if scrubbed, logs are the wrong shape for this
  channel. Use a local log store for logs. If a metric derived from log
  matches (like "5xx count") is needed, compute it locally and export the
  aggregate.
- **Any per-patient dimension.** No `patient_id`, no ward-level breakdown
  finer than the ward as a whole. If a metric would produce cardinality > 100
  distinct series per ward, redesign it.
- **Trace spans with clinical payloads.** If traces are added later, apply
  the same allow-list to span attributes and drop request/response bodies.

## Red team exercise

To confirm the pipeline works, deliberately try to emit PHI-shaped metrics:

1. Add a metric `vitalcare_patient_id_debug` in `vitalcare_mock.py`.
2. Restart the mock.
3. Confirm it appears at <http://localhost:8081/metrics>.
4. Wait one collector scrape cycle.
5. Confirm it does **not** appear in cloud Prometheus at
   <http://localhost:9091>.

If it does appear, the collector filter is misconfigured. That is an incident.
Record the finding and fix the config.

## Regulatory context (informational, not legal advice)

- **HIPAA (US)** — the aggregate metrics defined in this lab are unlikely to
  be individually identifiable, but the deployment context (which hospital,
  which vendor) matters. A Business Associate Agreement (BAA) may still be
  required for the cloud backend depending on the payload.
- **개인정보보호법 / 의료법 (KR)** — 병원 안에서 생성된 진료 정보의 국외 이전 및
  집계 지표의 취급 기준은 의료기관/변호사 검토가 필요합니다. 본 lab은 기술적
  구현 예시이며 법적 판단이 아닙니다.
- **GDPR (EU)** — pseudonymized aggregate is generally out of scope, but
  hospital-level tenancy plus timing patterns can be a re-identification
  vector at low population sizes.

If the deployment lands in any regulated jurisdiction, the pipeline design
here is a starting point for a compliance review, not a substitute for one.
