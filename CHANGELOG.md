# Changelog

All notable changes to this project will be documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `discover/aurora-ha-audit.sh` — flags Aurora clusters with a single member, clusters whose members all live in the same AZ, and standalone RDS instances with Multi-AZ disabled. Read-only; supports `--json`.
- `discover/lambda-eol-scanner.py` — lists Lambda functions and classifies runtimes as EOL, near-EOL, OK, or unknown/container. Read-only; supports `--json`.

## [0.1.0]

### Added
- Initial project scaffold (README, LICENSE, ROADMAP, CHANGELOG).
- `discover/ecs-overview.sh` — ECS cluster/service/task summary with anomaly hints; supports `--json` output and `AWS_PROFILE`/`AWS_REGION` env vars.
- `lib/common.sh` — shared bash helpers (colors, error handling, dependency checks).

[Unreleased]: https://github.com/kiseskrap/aws-infra-audit-toolkit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kiseskrap/aws-infra-audit-toolkit/releases/tag/v0.1.0
