# Roadmap

Each unchecked item is a future commit. Items are sequenced to deliver incremental value — a user adopting the toolkit early should get something useful in week 1, week 2, etc., rather than waiting for a "complete" v1.

## v0.2 — round out discovery

Read-only inventory tools that answer "what exists?"

- [x] `discover/aurora-ha-audit.sh` — RDS/Aurora clusters lacking Multi-AZ or running as a single instance. Flags writers without read replicas.
- [x] `discover/lambda-eol-scanner.py` — Lambda functions on EOL or near-EOL runtimes (nodejs12/14/16, python3.7/3.8, etc.). Cross-references AWS's published EOL calendar.
- [x] `discover/ecr-bloat-report.sh` — Top ECR repos by image count, flags those without a lifecycle policy.
- [x] `discover/idle-resources.sh` — Stopped EC2 (with EBS still attached), empty ECS clusters, unused ALBs, unattached EBS volumes, unused EIPs.

## v0.3 — opinionated audits

Tools that move from "what exists" to "is it healthy?"

- [x] `audit/cost-hotspots.py` — Cost Explorer query (last 30 days, by service) joined with topology data; ranks where to look first.
- [x] `audit/security-baseline.sh` — Permissive security groups (0.0.0.0/0 inbound on non-80/443), public S3 buckets, IAM users with access keys older than 180 days.
- [ ] `audit/cross-env-leak-check.sh` — Detects when staging and production share the same Redis, S3 bucket, or OpenSearch domain (a real failure mode I've seen).

## v0.4 — cost insight + maintainer foundations

Cost-aware audit tooling plus the maintainer-experience scaffolding that
makes the project feel like a real OSS project to drop into.

- [x] `audit/cost-rough-estimate.py` — list-price estimate from inventory × AWS Pricing API (EC2, RDS, EBS, ELB, EIP). Runs without billing IAM as a complement to `cost-hotspots.py`.
- [ ] `CONTRIBUTING.md`
- [x] `.github/workflows/lint.yml` — shellcheck + ruff on every PR
- [ ] `.github/ISSUE_TEMPLATE/` — feature_request.md and bug_report.md
- [ ] `tests/` — bats-core tests for shell scripts, pytest for Python
- [ ] Pre-commit hooks (`.pre-commit-config.yaml`)

## v0.5 — usability

- [ ] `Dockerfile` and `docker run`-friendly invocation (carries awscli+jq+python so users don't need local installs)
- [ ] `Makefile` with a few common recipes (`make audit`, `make discover`)
- [ ] Colored TTY output, `--no-color` flag, plays nicely with `less -R`
- [ ] `--region all` to fan out across all enabled regions

## v0.6 — depth

- [ ] `audit/ecs-task-rightsizing.py` — Compares task definition CPU/memory vs actual CloudWatch utilization, suggests downsizing.
- [ ] `audit/rds-rightsizing.py` — Same idea for RDS instance classes.

## v0.7 — observability lab

- [x] `observability-lab/` — Local Prometheus, Grafana, Loki, and CloudWatch Logs OpenMetrics exporter proof of concept.
- [ ] Add an optional CloudWatch service metrics exporter profile for ECS, RDS, Lambda, ALB, and SQS metrics.
- [ ] Add alerting examples for log-derived error rates and exporter polling lag.
- [ ] Add a Datadog-to-OSS dashboard comparison note.

## v1.0 — release

- [ ] Polish, full test coverage, tag `v1.0.0`.
- [ ] Write `docs/case-study.md` walking through a real-ish audit (using synthetic account).

## Out of scope (intentionally)

- Anything that mutates resources. Use Terraform or AWS Config for remediation.
- Multi-account organization sweeps. Run the toolkit per account with the right profile instead.
- Hosted real-time monitoring replacement. CloudWatch, Datadog, etc. already
  do this; the observability lab is for local evaluation and portability work.
