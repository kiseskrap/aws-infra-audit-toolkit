# AWS Observability Lab

Local observability proof of concept for AWS workloads that already emit
CloudWatch metrics and logs.

This lab is intentionally small: it does not try to replace Datadog in one
step. It shows which parts of an AWS observability workflow can be rebuilt with
open standards and local open-source tools:

- Prometheus for time-series metrics.
- Grafana for dashboards.
- Loki for log exploration.
- A custom OpenMetrics exporter that converts CloudWatch Logs matches into
  Prometheus-readable counters.

The result is useful as a TPM-style evaluation artifact: it documents scope,
trade-offs, and a working MVP that engineering teams can extend or reject with
clear evidence.

## Architecture

```text
CloudWatch Logs
      |
      | filter_log_events
      v
cloudwatch-log-metrics exporter  --->  /metrics  --->  Prometheus
                                                        |
                                                        v
                                                     Grafana

CloudWatch Metrics  --->  CloudWatch exporter/YACE  --->  Prometheus
```

Prometheus is not a log database. The exporter only publishes numbers derived
from logs, such as matched error counts and polling lag. Raw log exploration
should use Loki, CloudWatch Logs Insights, or an existing vendor tool.

## Quick Start

From the repository root:

```bash
cd observability-lab
cp exporters/config.example.json exporters/config.local.json

# Edit exporters/config.local.json for your real log groups and patterns.
AWS_PROFILE=prod AWS_REGION=ap-northeast-2 docker compose up --build
```

Open Grafana at <http://localhost:3000>.

Default local credentials:

- Username: `admin`
- Password: `admin`

Prometheus is available at <http://localhost:9090>.

> First time here? See **[docs/onboarding.md](./docs/onboarding.md)** — a
> hands-on 30-minute tutorial from first run to first alert.
>
> On-prem clinical scenario? See **[hospital-remote/](./hospital-remote/)** — a
> sub-lab that simulates a hospital service forwarding PHI-free operational
> metrics to a remote cloud backend over a single outbound endpoint.

## AWS Permissions

The exporter is read-only. The minimum useful permissions are:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:FilterLogEvents",
        "logs:DescribeLogGroups",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

For CloudWatch service metrics, add a dedicated CloudWatch exporter such as
YACE and grant the required `cloudwatch:GetMetricData` and service discovery
permissions for the resources you want to monitor.

## What This Lab Measures

The included exporter turns configured CloudWatch Logs filter patterns into
OpenMetrics counters:

```text
aws_log_events_matched_total{log_group="/aws/ecs/api",pattern="error",service="api"} 12
aws_log_poll_lag_seconds{log_group="/aws/ecs/api",pattern="error",service="api"} 3
aws_log_poll_errors_total{log_group="/aws/ecs/api",pattern="error",service="api"} 0
```

Good first patterns:

- `ERROR`
- `Exception`
- `Task timed out`
- `5xx`
- Domain-specific failure markers such as `payment_failed` or `inference_error`

## TPM Evaluation Notes

This lab is a decision artifact, not just a dashboard demo.

Questions it helps answer:

- Which Datadog dashboards can be approximated with OSS tools?
- Which signals are native CloudWatch metrics versus log-derived metrics?
- Which log patterns are stable enough to become SLO or alert inputs?
- What operational risks appear when polling CloudWatch Logs locally?
- Where does Datadog still provide meaningful leverage?

Expected conclusion:

- Prometheus/Grafana are strong for standard service metrics and alertable
  numeric signals.
- Loki or CloudWatch Logs Insights should remain responsible for raw logs.
- Datadog remains stronger for hosted correlation, retention, managed
  integrations, and low-maintenance team adoption.
- A local OSS stack is valuable for audits, cost-sensitive environments,
  portability reviews, and vendor lock-in analysis.

## Files

```text
observability-lab/
├── docker-compose.yml
├── exporters/
│   ├── Dockerfile
│   ├── cloudwatch_log_metrics.py
│   ├── config.example.json
│   └── requirements.txt
├── grafana/
│   └── provisioning/
│       ├── dashboards/
│       │   ├── dashboards.yml
│       │   └── cloudwatch-log-metrics.json
│       └── datasources/
│           └── datasources.yml
└── prometheus/
    └── prometheus.yml
```

## Known Limits

- Polling CloudWatch Logs is not the same as a streaming pipeline.
- Restarts reset in-memory counters unless Prometheus has already scraped them.
- Large log groups can hit API throttling if the polling window is too wide.
- High-cardinality labels should be avoided. Keep labels to environment,
  service, log group, and pattern.
- This lab intentionally avoids write actions in AWS.

