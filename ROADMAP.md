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

- [ ] `audit/cost-hotspots.py` — Cost Explorer query (last 30 days, by service) joined with topology data; ranks where to look first.
- [ ] `audit/security-baseline.sh` — Permissive security groups (0.0.0.0/0 inbound on non-80/443), public S3 buckets, IAM users with access keys older than 180 days.
- [ ] `audit/cross-env-leak-check.sh` — Detects when staging and production share the same Redis, S3 bucket, or OpenSearch domain (a real failure mode I've seen).

## v0.4 — project hygiene

Things a maintainer would expect.

- [ ] `CONTRIBUTING.md`
- [ ] `.github/workflows/lint.yml` — shellcheck + ruff on every PR
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
- [ ] Markdown report mode (`--format md`) for pasting into team docs.

## v1.0 — release

- [ ] Polish, full test coverage, tag `v1.0.0`.
- [ ] Write `docs/case-study.md` walking through a real-ish audit (using synthetic account).

## Out of scope (intentionally)

- Anything that mutates resources. Use Terraform or AWS Config for remediation.
- Multi-account organization sweeps. Run the toolkit per account with the right profile instead.
- Real-time monitoring. CloudWatch, Datadog, etc. already do this.
