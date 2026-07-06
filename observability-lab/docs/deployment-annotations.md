# Deployment Annotations — Mark Deploys on the Grafana Timeline

When the Lambda triage panel says "1 function has errors in the last
15 minutes", the very next question is almost always: *"did we deploy
something?"* This doc shows how to make that question answerable in
one glance by drawing a vertical marker on the graphs at each deploy.

Estimated time to wire up: **~10 minutes** (once your CI can reach
your Prometheus endpoint).

## How it works

1. A CI job — or a manual `curl` from your deploy runbook — pushes a
   metric named `deploy_event` to Prometheus **Pushgateway** at the
   moment of deploy.
2. Prometheus scrapes Pushgateway every 15s (the lab's default) and
   persists `deploy_event` samples in its TSDB.
3. Grafana's dashboard-level annotation queries `deploy_event` and
   renders each match as a vertical line across every time-series
   panel on the dashboard.
4. The annotation's tooltip shows `service`, `version`, and `source`
   labels so the operator knows which deploy they're looking at.

Nothing about your production Prometheus setup has to change — you
just need one more scrape target (Pushgateway) and one more Grafana
annotation query.

## Local lab: send a deploy event by hand

The lab's `docker-compose.yml` already runs Pushgateway on port 9091.
From your laptop:

```bash
# Announce a fake deploy of "fishmarket-order-scheduler" version v2.4.1.
# printf guarantees the trailing newline that Prometheus's text format
# requires; heredoc without a trailing newline is a common footgun.
printf 'deploy_event{version="v2.4.1"} %s\n' "$(date +%s)" | \
  curl -s --data-binary @- \
    http://localhost:9091/metrics/job/deploy/service/fishmarket-order-scheduler/env/prod/source/manual
```

Open Grafana → **AWS Services — RDS / Lambda / ALB Overview (YACE)** dashboard.
Within ~30 seconds a **cyan vertical line** appears across every
timeseries panel at "now", tagged
`deploy fishmarket-order-scheduler v2.4.1`.

The panels that previously answered "how bad is the error rate?" now
also answer "did it start when we deployed?"

## Wire it into CI (GitLab example)

In your service's `.gitlab-ci.yml`, after the deploy step:

```yaml
deploy:
  script:
    - ./deploy.sh                # your existing deploy
  after_script:
    # Record a deploy marker in Prometheus so operators can correlate
    # error rates against deployments.
    - |
      SERVICE="${CI_PROJECT_NAME}"
      VERSION="${CI_COMMIT_SHORT_SHA}"
      ENV="prod"
      SOURCE="gitlab-ci"
      PGW="${PGW_URL:-http://prometheus-pushgateway.internal:9091}"
      printf 'deploy_event{version="%s"} %s\n' "${VERSION}" "$(date +%s)" \
        | curl -s --data-binary @- \
          "${PGW}/metrics/job/deploy/service/${SERVICE}/env/${ENV}/source/${SOURCE}"
```

Two design notes:

- **Job label = `deploy`** — every deploy across every service lands
  in one job. That's what makes the annotation query
  `deploy_event` (no filter) sensible.
- **Grouping labels in the path** (`service`, `env`, `source`) —
  Pushgateway groups samples by the URL path. Sending the same
  `service` again replaces the previous row rather than appending;
  that's fine here because Grafana annotations use the sample
  *value* (the epoch we sent) as the marker position, not the
  scrape time.

## Wire it into GitHub Actions

```yaml
      - name: Announce deployment to Prometheus
        env:
          PGW_URL: ${{ secrets.PROMETHEUS_PUSHGATEWAY_URL }}
          SERVICE: ${{ github.event.repository.name }}
          VERSION: ${{ github.sha }}
        run: |
          printf 'deploy_event{version="%s-%s"} %s\n' "${SERVICE:0:12}" "${VERSION:0:7}" "$(date +%s)" \
            | curl -s --data-binary @- \
              "${PGW_URL}/metrics/job/deploy/service/${SERVICE}/env/prod/source/github-actions"
```

## Wire it into a CodeDeploy hook

CodeDeploy calls arbitrary shell hooks. Put this in
`AfterAllowTraffic.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
SERVICE="$(basename $(pwd))"
VERSION="${DEPLOYMENT_ID:-unknown}"
PGW="${PGW_URL:?}"
printf 'deploy_event{version="%s"} %s\n' "${VERSION}" "$(date +%s)" \
  | curl -s --data-binary @- \
    "${PGW}/metrics/job/deploy/service/${SERVICE}/env/prod/source/codedeploy"
```

## Wire it into a Lambda deployment

For pure-Lambda services deployed via `aws lambda update-function-code`,
add a post-step in your deploy script:

```bash
# After: aws lambda update-function-code --function-name fishmarket-order-scheduler ...
printf 'deploy_event{version="%s"} %s\n' "$(git rev-parse --short HEAD)" "$(date +%s)" \
  | curl -s --data-binary @- \
    "http://prometheus-pushgateway.internal:9091/metrics/job/deploy/service/fishmarket-order-scheduler/env/prod/source/shell"
```

## Reading the marker on the dashboard

- **Cyan vertical line** — one deploy.
- **Multiple lines close together** — multiple services deployed in the
  same window. Hover to see which.
- **Error rate spike starts *right of* a marker** — that deploy is a
  suspect. Look at its `version` in the tooltip; that's your rollback
  target.
- **Error rate spike starts *left of* a marker** — the deploy is not
  the cause. Look elsewhere (upstream dependency, config change,
  traffic shift).

## Filtering markers by service

The default annotation shows every deploy. If a dashboard is focused on
one service — say the aws-services dashboard already has a `$lambda_fn`
template variable — you can tighten the annotation to only mark deploys
for the visible functions:

```
deploy_event{service=~"$lambda_fn"}
```

Edit the dashboard's annotation query in Grafana → dashboard settings →
Annotations → Deployments → **Expression**. This gets noisy on a
multi-service dashboard; use it only when the dashboard is scoped.

## Retention

Pushgateway samples live indefinitely by default (they represent the
"most recent deploy" for each grouping). Prometheus retains them for
its own retention window (15d default). If a dashboard time range
extends beyond Prometheus retention, older markers disappear — that is
expected.

To explicitly clear a bad `deploy_event` push:

```bash
curl -X DELETE http://localhost:9091/metrics/job/deploy/service/<name>/env/prod/source/gitlab-ci
```

## What NOT to do

- **Don't** push high-cardinality labels here. Every deploy is one
  sample; if you add `request_id` or `user_id` labels the annotation
  query blows up.
- **Don't** ship deploy events via the same Prometheus you monitor
  Pushgateway health with, if you might lose Pushgateway. Consider
  self-monitoring: `count(deploy_event) < 1` for the last 7 days is a
  signal your CI hook is broken.
- **Don't** confuse markers with alerts. The marker just says "a deploy
  happened"; it doesn't say the deploy is bad. Correlation is a human
  judgment.
