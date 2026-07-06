# Incident Triage — What to Do When a Signal Lights Up

The dashboards show *information*. This document shows *decisions*. If
the AWS Services dashboard is telling you something is wrong and you
don't know what to do next, start here.

The document is organized by **the signal you're staring at**, not by
AWS service. When you open the dashboard and one number is not zero,
find that number below and follow the tree.

## Signal: "Lambda — functions with any error (last 15m)" ≥ 1

The stat panel that started this whole document.

### Step 1 — Identify the function (10 seconds)

Look at the **"Lambda — Top functions by errors (last 15m)"** table in
the Triage row directly below the stat. The `function` column is your
suspect. The `error rate` column tells you how severe it is.

If the table is empty but the stat says ≥ 1, you're inside a race
window (the stat updates a bit ahead of the table). Wait 30 seconds
and refresh.

### Step 2 — Judge severity (30 seconds)

Use the `error rate` column:

| Error rate | Interpretation | Action |
| --- | --- | --- |
| < 0.1% | Background noise. Some upstream flakiness always exists. | Nothing. Move on. |
| 0.1 – 1% | Elevated but not on-fire. Might have started earlier and been rolling. | Read logs. Do not page. |
| 1 – 5% | Real. Something changed. | Investigate now. Consider paging the service owner. |
| ≥ 5% | Incident. | Page. Consider rolling back. |

The dashboard's **"Lambda — Error rate % (top 15)"** timeseries has
these thresholds drawn as yellow/red horizontal lines so you can eyeball
severity without doing math.

### Step 3 — Correlate against deploys (10 seconds)

Look for **cyan vertical lines** on the error-rate timeseries panel.

- **Spike starts to the right of a marker** → that deploy is a
  suspect. Hover the marker: the tooltip shows `service` and
  `version`. That version is your rollback candidate.
- **Spike starts to the left of any marker** → not a deploy. Skip
  to Step 4.
- **No markers at all** → your CI is not sending them. Fix that when
  the fire is out — see [`deployment-annotations.md`](./deployment-annotations.md).

### Step 4 — Read the actual logs (60 seconds)

Click the function name in the Top-N table. It opens a
**CloudWatch Logs Insights** query preconfigured for that function and
a 15-minute window filtered to `/ERROR/`. Read the top few stack
traces. You are looking for one of three patterns:

| Pattern | Meaning | Next action |
| --- | --- | --- |
| Same exception on every failure | Deterministic bug, likely a deploy | Roll back the suspect version from Step 3 |
| Timeouts to an upstream (`Task timed out`, `ETIMEDOUT`, `ConnectionTimeoutException`) | Upstream dependency in trouble | Check that upstream's ALB / RDS panels for correlated symptoms |
| Auth denials (`401`, `AccessDenied`, `Signature does not match`) | Credential or IAM change | Check for recent secret rotation or IAM change |

### Step 5 — Decide (10 seconds)

Given Steps 2 – 4, pick one:

- **Nothing**: rate < 0.1% and no pattern.
- **Observe**: rate 0.1 – 1%, expected upstream flake, not deploy-correlated.
- **Investigate**: rate 1 – 5%, single service owner.
- **Rollback**: rate ≥ 5% and correlated with a deploy marker.
- **Broadcast + page**: rate ≥ 5% and either not deploy-correlated or
  the deploy owner is offline.

The total time from "stat is red" to a decision is under 3 minutes if
you follow this in order.

## Signal: "RDS — CPU >= 80% right now" ≥ 1

### The default answer is "probably fine"

The metric this stat is built on is **maximum** CPU across the cluster
over the last data point. Aurora with auto-scaling readers routinely
touches 90%+ during peak-hour scale-out. That is by design.

### Step 1 — Is it peak hour?

Look at the CPU timeseries panel above the stat. Is the current level
part of a familiar diurnal pattern that repeats every day at the same
time? If yes: **stop**. That is the ECS Fargate ASG spinning up more
tasks and each new task claiming DB connections. Move on.

### Step 2 — Is it off-peak?

If the elevated CPU is off-peak (e.g. 3am on a weekday), then something
is running that should not be:

- A batch job with an unindexed query.
- A cache miss storm draining every request to DB.
- A stuck migration or replication job.

Cross-reference with the **"RDS — DatabaseConnections"** panel: if
connections are also unusually high, an app is holding open sessions
it shouldn't.

### Step 3 — Which cluster?

Hover the max CPU timeseries. The legend tells you which
`dimension_DBClusterIdentifier`. Now you know which service is on the
other end.

### Step 4 — Decide

- **Peak hour, familiar pattern** → nothing.
- **Off-peak, one cluster** → look at that cluster's app service logs
  for the last hour. Frequently a scheduled job.
- **Off-peak, all clusters** → likely a shared upstream (secret
  rotation, DNS change, network hiccup). Broadcast.

## Signal: ALB — 5xx rate line is climbing

### Step 1 — Which LB?

Look at the **"ALB — 5xx rate by LB (per 5m)"** panel. The legend
identifies the LB. From the LB name you can identify the backend
service.

### Step 2 — Is the backend also symptomatic?

The 5xx you see on the ALB is caused by the backend returning them.
Go to the backend's Lambda panels (if Lambda) or its ECS Fargate logs
(if ECS). If those are quiet and the ALB is loud, look for a health
check regression (5xx from health checks alone can move this line).

### Step 3 — Response time also elevated?

Check **"ALB — Target response time (avg)"** on the same LB. If both
5xx AND latency are up, backend is saturated. If only 5xx is up,
backend has a functional error (not a resource one).

### Step 4 — Decide

- **5xx up, backend Lambda errors up** → treat as a Lambda incident,
  follow the Lambda signal tree above.
- **5xx up, latency also up** → backend saturation. Scale out or
  identify the slow path.
- **5xx up alone** → health check or a specific code path returning
  errors. Read backend logs for the correlated window.

## Signal: everything is flat and green

Congratulations. Move on. This dashboard is not where you find
proactive problems; that is what SLO burn rate alerts and error
tracking (Datadog Error Tracking, Sentry, etc.) are for.

## Cross-cutting patterns you will see repeatedly

### The "spike-with-marker" pattern

Any spike whose leading edge starts within a few minutes of a cyan
deployment marker is deploy-caused **until proven otherwise**. The
default action is **rollback first, root-cause second**. The
production win from a fast rollback is almost always larger than the
learning delay from a slower forensic pass.

### The "spike-without-marker" pattern

Two common causes: (1) an upstream dependency (external API, another
team's service) had an incident, or (2) traffic shape changed (a
partner started sending 10× the usual volume). Both should show up in
your logs as a specific error class dominating the ratio; when it
doesn't, look upstream.

### The "gradual drift" pattern

Not a spike but a slow rise over hours or days. Usually **not** an
incident. Usually a leak — connection pool leak, memory leak,
disk-full drift. Open a ticket, do not page. Add an SLO burn rate
alert if you don't have one.

## What this document is NOT

- Not a substitute for team-specific runbooks. Your service's known
  failure modes go in your team's runbook, not here.
- Not a substitute for pager rotations. When a signal says "page",
  actually page — this document assumes the on-call is you and
  someone has to make a call.
- Not exhaustive. Real dashboards grow more panels over time, and
  each new panel needs a paragraph here. This document is meant to
  be edited as the dashboard grows.

## How to extend this document

When you add a new stat panel to any dashboard, add a matching
"Signal: ..." section here with the 5-step tree filled in. The
5 steps are always:

1. **Identify** the specific resource behind the number.
2. **Judge** severity (with concrete thresholds).
3. **Correlate** with deploys or traffic shifts.
4. **Read** the relevant logs.
5. **Decide** among a small set of actions.

If your new stat can't be triaged in ≤ 3 minutes with a 5-step tree,
it is probably the wrong metric to have on a dashboard — either the
metric is too vague, or the panel needs additional context (an
adjacent table, a link out, a threshold color) added.
