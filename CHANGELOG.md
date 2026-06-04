# Changelog

All notable changes to this project will be documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `audit/security-baseline.sh` — perimeter sanity audit. Three independent checks: security groups with `0.0.0.0/0` inbound on non-(80/443) ports (severity-classified: critical for `-1`/all-protocols, high for SSH/RDP exposure, medium otherwise), S3 buckets effectively public (Block Public Access off AND a public bucket policy or ACL grant), and IAM users with access keys older than 180 days. Each check runs independently — one IAM permission gap or API error in a single check is reported and does not abort the others. Read-only; supports `--json`.

### Changed
- `discover/idle-resources.sh` — each item now carries an estimated monthly cost (ap-northeast-2 hardcoded pricing: per-type EBS GB rates, ALB/NLB base ~$18.40, EIP ~$3.65). Stopped EC2 enriches with attached EBS sizes via a batched `describe-volumes` to compute the still-billable cost. Summary appends `estimated monthly waste`. Adds `--with-cleanup-commands` flag that prints commented-out AWS CLI remediation commands per section — strictly no auto-execution, preserving the read-only guarantee.
- `discover/idle-resources.sh` — appended a cross-section **Top monthly waste** ranking that aggregates every non-zero-cost item across all categories and lists the top 10 by `$/mo` desc. Same data also exposed as `topWaste` in `--json` output so downstream consumers can rank without re-computing.
- `discover/idle-resources.sh` — each idle item now carries `tags.owner` / `tags.env` / `tags.createdAt`, surfaced as a compact `└─ owner=X env=Y age=Nd` continuation line under the primary row when tag data is available. Lookup is case-insensitive and tolerant of AWS's shape inconsistency ({Key,Value} for EC2/EBS/EIP/ELB vs {key,value} for ECS). LBs fetch tags in a single batched `elbv2 describe-tags` call (≤20 ARNs each) after the empty-set is known, so the extra calls are proportional to actionable findings, not total LB count. Full `tags` object exposed in `--json` for every item.

## [0.2.0] — 2026-05-30

### Added
- `discover/aurora-ha-audit.sh` — flags Aurora clusters with a single member, clusters whose members all live in the same AZ, and standalone RDS instances with Multi-AZ disabled. Read-only; supports `--json`.
- `discover/lambda-eol-scanner.py` — lists Lambda functions and classifies runtimes as EOL, near-EOL, OK, or unknown/container. Read-only; supports `--json`.
- `discover/idle-resources.sh` — surfaces likely-wasted resources across five categories (stopped EC2 with age, empty ECS clusters, load balancers with no registered targets, available EBS volumes, unassociated Elastic IPs). Each check runs independently so a single permission failure does not stop the others. Read-only; supports `--json`.
- `discover/ecr-bloat-report.sh` — lists ECR repositories sorted by image count and flags repos with no lifecycle policy (a common source of silent storage cost growth in inherited accounts). Surfaces untagged image counts, classifies each unmanaged repo by bloat pattern (`untagged-heavy`, `frequent-deploy`, `ephemeral-env`) so the right lifecycle rule is obvious, and degrades gracefully when individual repo lookups fail. Read-only; supports `--json`. See README's "Reading the report" section for triage guidance.
- `lib/common.sh` — `progress` / `progress_clear` helpers for tools that loop over many resources. Output goes to stderr only when stderr is a TTY, so `--json` pipelines and CI runs stay quiet.

### Changed
- `discover/ecr-bloat-report.sh`, `discover/idle-resources.sh`, `discover/lambda-eol-scanner.py` now print a per-resource (or per-check) progress line on stderr during long scans, so the tools no longer look frozen on accounts with many repos / load balancers / Lambda functions.

### CI
- `.github/workflows/lint.yml` — runs `shellcheck` against all `**/*.sh` and `ruff check` against the Python tools on every push to `main` and every PR.

## [0.1.0]

### Added
- Initial project scaffold (README, LICENSE, ROADMAP, CHANGELOG).
- `discover/ecs-overview.sh` — ECS cluster/service/task summary with anomaly hints; supports `--json` output and `AWS_PROFILE`/`AWS_REGION` env vars.
- `lib/common.sh` — shared bash helpers (colors, error handling, dependency checks).

[Unreleased]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/releases/tag/v0.1.0
