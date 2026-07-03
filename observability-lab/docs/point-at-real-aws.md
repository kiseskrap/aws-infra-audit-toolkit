# Pointing observability-lab at a Real AWS Account

The parent [README](../README.md) explains what the lab is and gives a
minimal example config. This doc walks through pointing it at a real
production AWS account without exposing your customer resources to the
world.

Estimated time: **~20 minutes**, most of it waiting for the first poll
cycle to complete.

## What you will have when this is done

- A local Prometheus + Grafana stack scraping error / timeout counters
  out of your real CloudWatch Log Groups.
- The **CloudWatch Log Metrics** dashboard (built-in) showing raw
  counters, poll lag, and poll errors.
- The **Team & Service — CloudWatch Log Signals** dashboard rolling those
  same signals up by `team` and `service` so a director can see the
  whole org in one view.
- No customer log group names, service names, or IAM identifiers
  committed to git. The lab's `.gitignore` already blocks the sensitive
  file.

## Prerequisites

- Docker Desktop running.
- AWS credentials configured locally for a **read-only** profile.
  Confirm with:
  ```bash
  aws sts get-caller-identity --profile <your-profile>
  ```
- Read access to at least one CloudWatch Log Group in the target region.

## Step 1 — Create a scoped IAM policy (recommended)

If you can, avoid pointing the exporter at your everyday admin
credentials. Create a read-only IAM user or role scoped to just what
the exporter needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ExporterMinimal",
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

Do **not** grant `logs:PutLogEvents`, `logs:DeleteLogGroup`, or any
`cloudwatch:Put*` — the exporter has no legitimate need to write.

Attach this policy to a dedicated IAM user, generate access keys, and
put them in a new profile in `~/.aws/credentials`:

```ini
[observability-lab-readonly]
aws_access_key_id = AKIA...
aws_secret_access_key = ...
```

## Step 2 — Discover the Log Groups worth watching

Rank your Log Groups by recent traffic. High-traffic groups are the ones
where signal is most valuable:

```bash
aws logs describe-log-groups --region <your-region> \
  --query 'logGroups[?storedBytes > `1000000`].[logGroupName, storedBytes]' \
  --output text \
  | sort -t$'\t' -k2 -n -r \
  | head -20
```

For each candidate Log Group, decide:

- **`service`** label — how you refer to the service in team conversations.
- **`team`** label — which team owns it. This drives the roll-up
  dashboard.
- **`env`** label — usually `prod`; you can also point at `stg` if you
  want a parallel view.
- **`pattern`** and **`filter_pattern`** — start with `ERROR`. Add
  `"Task timed out"` for Lambda targets. Add domain-specific markers
  later (`payment_failed`, `inference_error`, whatever your team already
  greps for in incidents).

## Step 3 — Write `exporters/config.local.json`

Copy the example and edit:

```bash
cd observability-lab
cp exporters/config.example.json exporters/config.local.json
$EDITOR exporters/config.local.json
```

Structure per pattern:

```json
{
  "name": "error",
  "log_group": "/ecs/your-real-log-group",
  "filter_pattern": "ERROR",
  "labels": {
    "env": "prod",
    "service": "your-service-name",
    "team": "your-team-name"
  }
}
```

Any label you add here becomes a Prometheus label. Keep it to
low-cardinality dimensions: `env`, `service`, `team`. Do not put per-user
or per-request IDs here — high-cardinality labels balloon TSDB storage.

Start small: 3–5 patterns covering the highest-signal Log Groups. You
can add more later without restarting anything but the exporter.

## Step 4 — Start the stack

```bash
AWS_PROFILE=observability-lab-readonly \
AWS_REGION=<your-region> \
docker compose up --build
```

The `~/.aws` directory is mounted read-only into the exporter
container, so the same profile you tested with `aws sts` will work
here.

## Step 5 — Confirm the pipeline is flowing

Wait ~45 seconds for the exporter to complete two poll cycles, then
check:

```bash
# The exporter is producing metrics for every configured pattern.
curl -s http://localhost:9108/metrics | grep aws_log_events_matched_total

# Prometheus is scraping them.
curl -s "http://localhost:9090/api/v1/query?query=count(aws_log_poll_lag_seconds)" \
  | python3 -m json.tool
```

Open the dashboards:

- <http://localhost:3000> (admin / admin) → **Dashboards** →
  **Team & Service — CloudWatch Log Signals**
- The same folder also has **CloudWatch Log Metrics** for the raw view.

You should see one row per configured pattern in the "Service inventory"
table at the bottom of the team dashboard. If a service you expected is
missing from that table, it is missing from `config.local.json`.

## Step 6 — Interpret the first hour of data

The three signals to watch first:

| Panel | What it tells you |
|---|---|
| **Poll errors (1h)** | Should be 0. Non-zero means the exporter cannot reach CloudWatch — IAM, network, or a misspelled Log Group name. Fix this before anything else. |
| **Max poll lag** | Should stay well under 30s. Sustained higher values mean either CloudWatch API is slow or you're hitting throttling — reduce `poll_interval_seconds` or shard patterns across multiple exporter instances. |
| **Matched events per second** | This is your product signal. Baseline what "normal" looks like for a quiet hour, then alert on breaches. |

## Step 7 — Iterate on filter patterns

The default `ERROR` pattern is generic. Over the first week, tune it
based on what you see:

- **Too noisy** (thousands of matches per second): filter more specifically.
  Example — instead of matching every `ERROR`, match
  `ERROR AND NOT healthcheck`.
- **Too quiet** (zero matches across days): either your service really
  is quiet, or your log format doesn't include the token `ERROR`. Look
  at raw logs in CloudWatch Logs Insights to see what your app actually
  writes.
- **Domain-specific patterns** (payment failures, order timeouts,
  inference errors): add these as new patterns with their own `name`.
  The dashboard's "by pattern" panel will split them out automatically.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Poll errors > 0, `last_error` says `AccessDeniedException` | IAM policy missing `logs:FilterLogEvents` | Update the policy in Step 1 |
| Poll errors > 0, `last_error` says `ResourceNotFoundException` | Log Group name typo, or wrong region | Check exact name with `aws logs describe-log-groups` |
| Grafana panel shows "no data" but exporter has metrics | Wrong datasource UID in dashboard, or Prometheus not scraping | Grafana → **Explore** with Prometheus datasource, query `aws_log_poll_lag_seconds` |
| Exporter container exits immediately | Config JSON is malformed | `docker compose logs cloudwatch-log-metrics --tail 20` — Python will print a stack trace |
| CloudWatch API throttling | Too many patterns polling too frequently | Increase `poll_interval_seconds` to 60, or split patterns across two exporter instances with different configs |
| High cost in AWS bill | `FilterLogEvents` costs money per invocation on very large log groups | Reduce `lookback_seconds`, tighten `filter_pattern` at the CloudWatch side, or pre-aggregate with a metric filter |

## What NOT to commit

The following files carry information about your real infrastructure and
must not land in a public repository:

- `exporters/config.local.json` — Log Group names + your team's service
  taxonomy. Already blocked by `.gitignore`.
- Any Grafana dashboard you save with **specific service names** in
  panel titles. If a panel says "fishmarket-payment-monitoring", that
  is a service name you probably do not want indexed by GitHub. Prefer
  panel titles that describe the *shape* of the query
  ("by service — top 10") and let the labels populate at runtime.
- IAM access keys. Store them in `~/.aws/credentials` or an SSO login
  profile, never in the repo.

## What to do next

- Add Loki + Promtail if you want raw log exploration alongside the
  derived metrics. This lab already runs Loki; wiring Promtail to
  forward CloudWatch Logs is the next natural extension.
- Add [YACE](https://github.com/prometheus-community/yet-another-cloudwatch-exporter)
  for CloudWatch **service** metrics (RDS, ALB, ECS, SQS, Lambda) —
  see the parent README's "What This Lab Measures" section.
- Compare panel-by-panel with your existing Datadog dashboards to see
  what OSS can reproduce and where Datadog still adds meaningful
  leverage. That comparison is the TPM deliverable this lab exists to
  support.
- Extend patterns to include domain-specific business signals
  (`payment_failed`, `order_timeout`, `oauth_denied`) so incidents are
  detectable in Prometheus first, not only in Datadog.
