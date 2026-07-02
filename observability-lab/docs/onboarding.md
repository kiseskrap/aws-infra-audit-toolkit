# Onboarding — 5 Minute Hands-on Tutorial

> The main [README](../README.md) explains *what this lab is* and *why*. This
> document is the hands-on entry point: run the stack, see the first dashboard,
> add your first custom metric, wire up your first alert.
>
> Estimated time end-to-end: **~30 minutes** (the "5-minute" milestone is
> reaching the first dashboard).

---

## Prerequisites

Before you start:

- Docker Desktop (or equivalent) — running
- ~2 GB free RAM for the local stack
- AWS credentials for a **read-only** profile (see [Minimum IAM](#minimum-iam))
- One CloudWatch Log Group you can read

Confirm with:

```bash
docker --version
aws sts get-caller-identity --profile <your-profile>
aws logs describe-log-groups --profile <your-profile> --region <your-region> \
  --log-group-name-prefix / --max-items 1
```

If any command fails, fix that first. The rest of this guide assumes all three work.

---

## Step 1 — First run (5 minutes)

```bash
cd observability-lab
cp exporters/config.example.json exporters/config.local.json
AWS_PROFILE=<your-profile> AWS_REGION=<your-region> docker compose up --build
```

The example config polls two Log Groups that will not exist in your account.
That's fine for the first run — the exporter will report `aws_log_poll_errors_total > 0`,
which is a real signal you can see in Prometheus.

Open three tabs:

| Service | URL | Purpose |
|---|---|---|
| Grafana | <http://localhost:3000> (admin / admin) | Dashboards |
| Prometheus | <http://localhost:9090> | Raw query + target health |
| Exporter `/metrics` | <http://localhost:9108/metrics> | See exported metrics directly |

**Success criteria for Step 1**: Grafana loads. Prometheus **Status → Targets** shows
`cloudwatch-log-metrics` in `UP` state.

---

## Step 2 — Your first dashboard (already provisioned)

Grafana comes pre-provisioned with the `CloudWatch Log Metrics` dashboard.

1. Grafana → **Dashboards** (left rail)
2. Open **CloudWatch Log Metrics**
3. Expect: empty or `no data` panels — you have not scraped real Log Groups yet.

**Success criteria for Step 2**: You can see the dashboard structure. The
panels have the correct panel titles and PromQL queries. Don't fix the "no data"
yet — that's Step 3.

---

## Step 3 — Your first real pattern (10 minutes)

Edit `exporters/config.local.json`. Replace both patterns with **one real Log Group**
from your account. Start simple:

```json
{
  "poll_interval_seconds": 30,
  "lookback_seconds": 300,
  "patterns": [
    {
      "name": "error",
      "log_group": "/aws/ecs/<your-real-service>",
      "filter_pattern": "ERROR",
      "labels": {
        "env": "prod",
        "service": "<your-real-service>"
      }
    }
  ]
}
```

Restart just the exporter:

```bash
docker compose restart cloudwatch-log-metrics
```

Wait ~1 minute for two poll cycles. Then check:

```bash
curl -s http://localhost:9108/metrics | grep aws_log_events_matched_total
```

You should see a real number, not zero. If it is zero, either your Log Group has
no `ERROR` in the last 5 minutes (normal, good problem) or the filter pattern
does not match (bad — check CloudWatch Logs Insights directly).

**Success criteria for Step 3**: `aws_log_events_matched_total` returns a real
counter for your service. Grafana dashboard now shows a non-empty time series.

---

## Step 4 — Your first PromQL query (5 minutes)

Prometheus UI → **Graph** tab. Type each query and press Execute:

| Query | What it tells you |
|---|---|
| `aws_log_events_matched_total` | Cumulative match count per label set |
| `rate(aws_log_events_matched_total[5m])` | Errors per second, 5-minute average |
| `sum by (service) (rate(aws_log_events_matched_total[5m]))` | Aggregated per service — good for a top-N panel |
| `aws_log_poll_lag_seconds` | How stale the exporter's view is (should be small) |
| `rate(aws_log_poll_errors_total[5m]) > 0` | Non-zero means the exporter is failing to poll |

The last query is the seed of your first alert.

**Success criteria for Step 4**: You can explain in one sentence what each
query measures. Bookmark Prometheus at least once.

---

## Step 5 — Your first alert (10 minutes)

Prometheus in this lab does not have a rules file yet. Create one:

```bash
mkdir -p prometheus/rules
cat > prometheus/rules/exporter-health.yml <<'EOF'
groups:
  - name: exporter-health
    interval: 30s
    rules:
      - alert: CloudWatchLogPollFailing
        expr: rate(aws_log_poll_errors_total[5m]) > 0
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "cloudwatch-log-metrics exporter is failing to poll"
          description: |
            Log group {{ $labels.log_group }} pattern {{ $labels.pattern }}
            has been returning errors for over 2 minutes. Check exporter logs:
            docker compose logs cloudwatch-log-metrics --tail 50
EOF
```

Load the rules file in `prometheus/prometheus.yml`:

```yaml
# Add near the top, sibling of global:
rule_files:
  - /etc/prometheus/rules/*.yml
```

Mount the rules directory. In `docker-compose.yml`, add to the `prometheus`
service volumes:

```yaml
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro   # <-- add this line
```

Restart Prometheus:

```bash
docker compose restart prometheus
```

Prometheus → **Alerts** tab should now show `CloudWatchLogPollFailing` (in
either the `inactive` or `pending` state depending on whether your exporter
is healthy).

**Success criteria for Step 5**: You see the alert rule listed and its state
reflects reality. This lab intentionally does not include Alertmanager — that
is the next escalation and belongs in a follow-up doc.

---

## Step 6 — Break it on purpose

To convince yourself the pipeline is real, break the exporter and watch the
alert fire:

```bash
# In config.local.json, point one pattern at a Log Group that does not exist:
"log_group": "/aws/ecs/definitely-does-not-exist"
docker compose restart cloudwatch-log-metrics
```

Within ~2 minutes, `aws_log_poll_errors_total` should climb and the
`CloudWatchLogPollFailing` alert should move to `firing`.

Fix by pointing back to a real Log Group and restarting the exporter.

---

## Minimum IAM

The exporter is read-only. Create a policy with **only** these actions:

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

Do **not** grant `logs:PutLogEvents`, `logs:DeleteLogGroup`, or any `cloudwatch:Put*` —
this lab has no legitimate need to write.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Grafana shows `no data` even after Step 3 | Filter pattern does not match any real log lines | Test the pattern in CloudWatch Logs Insights first: `filter @message like /ERROR/` |
| `aws_log_poll_errors_total` grows constantly | IAM permission missing, or Log Group name has a typo | `docker compose logs cloudwatch-log-metrics --tail 50` — look for `AccessDenied` or `ResourceNotFoundException` |
| Prometheus target `DOWN` | Exporter container not running | `docker compose ps` — check the exporter is `Up`. Otherwise inspect its logs. |
| High memory use | `lookback_seconds` too large or too many high-cardinality patterns | Reduce to `300` (5 minutes). Keep labels to `env`, `service`, `log_group`, `pattern`. |
| Alert never fires when you break the pipeline | Rule file not mounted, or Prometheus not restarted | Prometheus → **Status → Rule Groups** should list your rule. If empty, the volume mount is wrong. |

---

## What to do after this tutorial

You now have:

- ✅ Running local Prometheus + Grafana + custom exporter
- ✅ One real Log Group producing real metrics
- ✅ One PromQL query you understand
- ✅ One alert rule that you have seen fire

Reasonable next moves:

1. **Add 2–3 more patterns** — one per real service. Keep to `env / service / log_group / pattern` labels.
2. **Add YACE** (CloudWatch service metrics exporter) alongside this one for
   RDS/ALB/ECS built-in metrics. See [YACE docs](https://github.com/prometheus-community/yet-another-cloudwatch-exporter).
3. **Add Loki + Promtail** for raw log exploration (out of scope for this lab —
   the main README explicitly says Prometheus is not a log DB).
4. **Compare with Datadog side-by-side**: pick one Datadog dashboard for your
   service, reproduce it here, note gaps. That comparison is the TPM
   deliverable this lab exists to support.
5. **Do not** run this exporter as your production monitoring. It is a lab —
   in-memory counters, no HA, no persistent storage. For production either
   invest in a proper Prometheus setup (Thanos/Cortex/Mimir) or keep using
   Datadog.

---

## Reference

- Lab overview and TPM evaluation notes: [README.md](../README.md)
- Toolkit roadmap: [`../../ROADMAP.md`](../../ROADMAP.md) — this lab is v0.7
- Related project: [`observability-playbook`](https://github.com/kiseskrap/observability-playbook) —
  the Datadog side of the same evaluation
