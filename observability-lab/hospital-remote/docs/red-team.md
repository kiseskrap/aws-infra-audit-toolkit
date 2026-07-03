# Red-Team — PHI Defense Verification

The whole hospital-remote design rests on one claim: **PHI cannot cross the
network boundary because the OTel Collector drops it**. This document
describes the automated test that proves that claim, why the design is
testable in the first place, and how to run the test in front of a
security reviewer.

## The claim under test

> Even when the on-prem clinical service tries to emit PHI-shaped metrics
> (through bug, misconfiguration, or malicious insertion), no PHI reaches
> the cloud backend.

Everything below is instrumentation to make that claim falsifiable.

## The three attack vectors

The VitalCare mock, when started with `RED_TEAM_MODE=true`, deliberately
emits three metrics that violate the [PHI protection policy](./phi-protection.md).
Each targets a different defense layer.

| # | Attack | Layer that must block it | Metric name |
|---|---|---|---|
| 1 | Metric NAME contains `patient_id` | Layer 2 — `filter/drop_phi_metrics` | `vitalcare_patient_id_leaked_total` |
| 2 | Metric NAME contains `mrn` | Layer 2 — `filter/drop_phi_metrics` | `vitalcare_mrn_lookups_total` |
| 3 | Metric name is innocent, LABEL contains `patient_id` | Layer 1 — `transform/allowlist` (keep_keys) | `vitalcare_vitals_by_patient_total{patient_id="P1000"}` |

Attacks 1 and 2 exercise the metric-name deny-list. Attack 3 exercises the
label allow-list — the more common failure mode, because most PHI leaks
happen through added labels, not renamed metrics.

## Running the test

Preconditions:

- The stack is already up: `docker compose up -d`
- Cloud Prometheus is reachable at `http://localhost:9091`

Run it:

```bash
cd observability-lab/hospital-remote
./scripts/red-team-phi.sh
```

Expected output on a healthy stack:

```
[red-team] preflight OK — 4 containers running, cloud Prometheus reachable
[red-team] enabling RED_TEAM_MODE on vitalcare-mock…
[red-team] waiting 5s for mock to start emitting…
[red-team] ✅ sanity: vitalcare-mock IS emitting 3 PHI-shaped metrics locally (as intended)
[red-team] waiting 45s for OTel Collector to scrape + export at least twice…
[red-team] checking cloud Prometheus for PHI leakage…
[red-team] ✅ attack 1 blocked: vitalcare_patient_id_leaked_total is NOT in cloud
[red-team] ✅ attack 2 blocked: vitalcare_mrn_lookups_total is NOT in cloud
[red-team] ✅ attack 3 blocked: patient_id label was scrubbed from vitalcare_vitals_by_patient_total
[red-team] restoring vitalcare-mock to normal (RED_TEAM_MODE off)…

[red-team] ✅ PASS — all 3 PHI attack vectors were blocked by the OTel Collector
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | PASS — all defenses held |
| 1 | FAIL — at least one PHI vector reached the cloud (**compliance incident**) |
| 2 | Infrastructure error — stack not up, cloud Prometheus unreachable, docker missing |

## What the script does

1. **Preflight**: confirm docker is on PATH, all four containers are
   running, and cloud Prometheus responds to `/-/ready`.
2. **Enable red-team mode** on the VitalCare mock by restarting it with
   `RED_TEAM_MODE=true` via a compose override file. The override is
   ephemeral (temp file) — the compose config on disk is untouched.
3. **Sanity check**: confirm the mock's local `/metrics` endpoint now
   exposes all three PHI-shaped metrics. This proves the test itself is
   running as intended. If this step fails, the collector was not the
   layer that dropped anything — the test never fired.
4. **Wait** 45 seconds (configurable via `WAIT_SECONDS`) so the OTel
   Collector has at least two 10-second scrape cycles plus export
   batching time.
5. **Query cloud Prometheus** for each attack vector:
   - Attacks 1 and 2: series must not exist at all.
   - Attack 3: the metric name is innocent and may exist, but no series
     may carry a `patient_id` label.
6. **Restore** the mock to normal mode.
7. **Report** and exit with the appropriate code.

## Interpreting a FAIL

A FAIL is a compliance incident, not a bug. The moment even one PHI
metric reaches the cloud, the design's core claim is broken.

Investigation order:

1. **Verify the on-prem side is emitting**: check
   `http://localhost:8081/metrics` while the script is running. If the
   PHI metrics are NOT emitted there, the test infrastructure is broken.
2. **Inspect the collector config**: open
   `on-prem/otel-collector/config.yaml`. Confirm:
   - `transform/allowlist` uses `keep_keys` and the allow-list matches
     the current metric label design.
   - `filter/drop_phi_metrics` uses OTTL `IsMatch(name, ...)` (not the
     older `name matches ...` syntax).
   - The processor order in the metrics pipeline is
     `resource/tag → transform/allowlist → filter/drop_phi_metrics → batch`.
3. **Inspect stale samples**: cloud Prometheus has a 6-hour local
   retention in this lab. If a previous test run left samples with
   different labels, restart the cloud side:
   `docker compose restart cloud-prometheus`.
4. **Repeat** the test. If it still fails, treat it as a real config
   defect and fix the collector.

## Using it in a security review

This test is designed to be run **in front of** a compliance reviewer.
The script prints one line per assertion, so the review conversation is
short:

- Reviewer: "How do you know PHI cannot leave?"
- You: `./scripts/red-team-phi.sh`
- Reviewer sees three green checks and PASS.
- Reviewer asks about a specific attack (e.g. adding a label). You
  extend the test to cover that vector.

The important quality is not that the test is exhaustive today, but that
it is **easy to add new vectors** as the design evolves. Every new metric
should come with a red-team case that proves its labels do not leak.

## CI integration

The script is CI-friendly: no interactive prompts, deterministic exit
codes, all state confined to the local docker compose stack.

This repository ships a ready-to-run GitHub Actions workflow at
[`.github/workflows/hospital-remote.yml`](../../../.github/workflows/hospital-remote.yml).
It runs both the red-team script and the WAN outage demo on any pull
request that touches the sub-lab. A change to the collector config that
regresses either defense will fail the job — the point of the workflow
is to make regressions loud.

The workflow triggers on `push` to `main` and on any `pull_request` that
touches `observability-lab/hospital-remote/**` or the workflow file
itself. Two jobs run in parallel (`red-team-phi` and `wan-outage-buffering`),
each on its own runner with its own docker compose stack.

Local reproduction:

```bash
cd observability-lab/hospital-remote
docker compose up -d --build
./scripts/red-team-phi.sh   # should exit 0
docker compose down -v
```

## Extending the test

The current three vectors are illustrative, not exhaustive. Reasonable
next additions:

- **Attack 4** — very high cardinality: a legitimate label (e.g.
  `ward_id`) with 10,000 distinct values. Not PHI, but a cost and
  reliability threat. Assert cardinality stays under a policy limit.
- **Attack 5** — free-form error message as a label value. Confirm the
  `error_class` allow-list normalizes it to a bounded set.
- **Attack 6** — resource attribute injection at the collector receiver
  level. Confirm the resource-level `keep_keys` drops it.
- **Attack 7** — traces (once traces are added). Assert span attributes
  containing patient IDs are dropped by an equivalent transform on the
  traces pipeline.

Each new attack is one metric definition in `vitalcare_mock.py` under
`RED_TEAM_MODE` and one new check in `red-team-phi.sh`.

## Why this is worth the effort

Most PHI incidents in vendor deployments look the same in postmortem:

> "We added a debug label six months ago and forgot to review it. It
> shipped to production. A customer saw it in a shared dashboard."

The red-team script exists so that "we forgot to review it" is caught by
CI on the pull request. The claim in this lab's README that "PHI cannot
cross the boundary" is a promise. This script is the receipt.
