# Changelog

All notable changes to this project will be documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] — 2026-06-06

### Added
- `lib/format.py` — Python equivalent of `lib/format.sh`. Standard-library only (no extra deps); preserves the same contract: caller-supplied stable column order, `None` renders as empty cells, lists flatten with `", "`, CSV uses RFC 4180 quoting, Markdown escapes `|` as `&#124;`.
- `lib/table.sh` — shared ASCII table-rendering helpers. `table_col_width` (data-driven column width with min/optional-max clamp), `table_sep` (horizontal separator of N `─` characters), `sort_by_hints` (jq snippet emitter for the standard hint-flagged sort), and `table_section_header` (bold section label + matching underline, used by multi-section tools). Dependency-free beyond jq.
- `audit/cost-hotspots.py` — ranks AWS services by the last 30 days of Cost Explorer spend, joined with per-service topology counts (Lambda functions, RDS instances + clusters, ECS clusters, running EC2 instances, EBS volumes + EIPs + LBs aggregated under "EC2 - Other", ECR repos). Surfaces `high-avg-per-resource (>=$200/mo)` when concentration is high, `no-counter-for-service` for services billed without a locally-known counter (S3, CloudFront, etc.), and `billed-but-no-resources-here` when an account has cost in a region with zero counted resources. Requires `ce:GetCostAndUsage` in the billing-enabled account; degrades gracefully with a pointer to `audit/cost-rough-estimate.py` for accounts without billing IAM. Each counter is isolated — one permission gap renders `?` in that row and does not abort the report. Supports `--format {table|json|csv|md}` and `--days N` (default 30).
- `audit/cost-rough-estimate.py` — list-price monthly cost estimate from inventory × AWS Pricing API rates. Five categories: EC2 (running instances by type), RDS (DB instances by class + engine), EBS (volumes by type and size, GB-month), ELB (ALB/NLB/GLB base hourly), and unassociated EIPs. Runs with only standard read-only IAM — no billing access required, making it the right tool when `cost-hotspots` cannot be used. Each category is isolated; one permission gap renders `?` in that row. The report header explicitly states list-price-only and inventory-driven (so RI/Savings Plans/private discounts are not visible and over-provisioned-but-lightly-used resources read as full price). Region resolution maintained via a `REGION_TO_LOCATION` map covering all standard commercial regions; unmapped regions exit with an explicit instruction. Same `--format {table|json|csv|md}` contract as every other tool. JSON output includes per-category `breakdown` so spreadsheet users can drill into which instance types / volume types are driving the line.

### Changed
- `discover/lambda-eol-scanner.py` — now uses unified `--format {table|json|csv|md}` (with `--json` kept as a backward-compatible alias for `--format json`). Closes the multi-format migration umbrella so every shipped tool now shares the same output flag and a documented flat schema. Flat columns: `FunctionName,Runtime,Status,DeprecationDate,DaysUntilDeprecation,LastModified,PackageType,Architectures,Hint`.
- `discover/ecs-overview.sh`, `discover/aurora-ha-audit.sh`, `discover/ecr-bloat-report.sh` — table rendering now uses `lib/table.sh` (`table_col_width`, `table_sep`, and `sort_by_hints` where applicable). Behavior is unchanged; the per-tool table block shrinks from ~5–8 lines to 2. The hint-flagged sort is implemented as a two-pass jq pipeline so the row-render jq body can stay single-quoted (no shell-escape clutter).
- `discover/idle-resources.sh`, `audit/security-baseline.sh` — drop the locally-defined `print_header()` (identical between the two) in favor of `table_section_header` from `lib/table.sh`.

## [0.3.0] — 2026-06-05

### Added
- `audit/security-baseline.sh` — perimeter sanity audit. Three independent checks: security groups with `0.0.0.0/0` inbound on non-(80/443) ports (severity-classified: critical for `-1`/all-protocols, high for SSH/RDP exposure, medium otherwise), S3 buckets effectively public (Block Public Access off AND a public bucket policy or ACL grant), and IAM users with access keys older than 180 days. Each check runs independently — one IAM permission gap or API error in a single check is reported and does not abort the others. Read-only.
- `lib/format.sh` — shared CSV (`format_csv`) and Markdown (`format_md`) renderers used by tools that support `--format csv` / `--format md`. CSV is RFC 4180-quoted via jq's `@csv`; Markdown replaces pipe characters in values with `&#124;` to avoid jq-regex escape ambiguity. Column order is explicit per call so schemas stay stable across runs.
- Unified `--format {table|json|csv|md}` flag across every tool (`discover/ecs-overview.sh`, `discover/aurora-ha-audit.sh`, `discover/ecr-bloat-report.sh`, `discover/idle-resources.sh`, `audit/security-baseline.sh`). `--json` kept as backward-compatible alias for `--format json` on each. Per-tool flat schemas documented in `--help`.

### Changed
- `discover/idle-resources.sh` — major depth pass:
  - Estimated monthly cost per item (ap-northeast-2 hardcoded pricing: per-type EBS GB rates, ALB/NLB base ~$18.40, EIP ~$3.65). Stopped EC2 enriches with attached EBS sizes via a batched `describe-volumes` to compute the still-billable cost.
  - `--with-cleanup-commands` flag prints commented-out AWS CLI remediation commands per section — strictly no auto-execution.
  - Cross-section **Top monthly waste** ranking that aggregates every non-zero-cost item across all five categories. Also exposed as `topWaste` in `--json`.
  - Canonical `tags.owner` / `tags.env` / `tags.createdAt` surfacing as a `└─ owner=X env=Y age=Nd` continuation line. Case-insensitive lookup, tolerant of AWS's shape inconsistency ({Key,Value} for EC2/EBS/EIP/ELB vs {key,value} for ECS). LBs fetch tags via a single batched `elbv2 describe-tags` call after the empty-set is known.
  - 0–100 `confidence` score and `DELETE` / `INVESTIGATE` / `KEEP` `recommendation` per item, derived from age, monthly cost, and an optional 30-day CloudWatch usage signal. Summary appends `recommendations: N DELETE / N INVESTIGATE / N KEEP`.
  - `--with-usage` flag pulls `RequestCount` (ALB) / `ActiveFlowCount` (NLB) over the last 30 days per empty load balancer. Empty LBs with measured zero traffic over 30d move from `INVESTIGATE` to `DELETE`.

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

[Unreleased]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/releases/tag/v0.1.0
