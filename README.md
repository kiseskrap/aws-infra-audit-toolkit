# aws-infra-audit-toolkit

Opinionated, read-only audit tools for AWS accounts that host many services across multiple business domains on ECS, RDS, Lambda, and friends.

Built from real-world experience auditing a large multi-service AWS account with dozens of ECS clusters, Aurora databases, and Lambda workloads in a production APAC environment. The patterns generalize.

## Status

Early stage. The first tool (`ecs-overview`) is working and useful today. More tools are tracked in [ROADMAP.md](./ROADMAP.md) and shipped one at a time.

## What problem this solves

When you inherit an AWS account that has grown organically over years, the first questions are always the same:

- How many clusters / services / tasks are actually running?
- Which RDS clusters lack Multi-AZ?
- Which Lambdas are on deprecated runtimes?
- What's the blast radius of changing this security group?
- Are there idle resources still being billed?

The AWS console is fine for any single question but terrible for getting a portfolio view. This toolkit produces opinionated, scannable text reports that you can paste into an incident channel or a doc.

Everything is **read-only**. No mutations.

## Quick start

Requires `awscli` v2, `jq`, and a configured profile.

```bash
git clone git@github.com:kiseskrap/aws-infra-audit-toolkit.git
cd aws-infra-audit-toolkit

# Default profile, default region
./discover/ecs-overview.sh

# Specific profile + region
AWS_PROFILE=staging AWS_REGION=us-east-1 ./discover/ecs-overview.sh

# JSON output for piping into other tools
./discover/ecs-overview.sh --json | jq '.[] | select(.runningTasks == 0)'

# Flag Lambda functions on deprecated or soon-to-deprecate runtimes
./discover/lambda-eol-scanner.py
```

## Example output

```
ECS overview — account 123456789012, region <region>
──────────────────────────────────────────────────────────────────────────
Cluster                                Launch    Svc  Task  Pending  EC2
──────────────────────────────────────────────────────────────────────────
prod-domain-a-cluster                  FARGATE     2     4        0    -
prod-domain-b-cluster                  FARGATE     1     2        0    -
prod-domain-c-cluster                  FARGATE     4     6        0    -
prod-domain-d-cluster                  FARGATE     2     0        0    -   [!] services-exist-but-zero-tasks
staging-cluster                        FARGATE    12    12        0    -
dev-shared-cluster                     EC2        18    16        0    6
AWSBatch-prod-env-xxxxxxxx             -           0     1        2    -   [aws-batch-managed]
──────────────────────────────────────────────────────────────────────────
Summary: 7 clusters, 39 services, 41 running, 2 pending, 6 EC2 instances
Hints:
   1 cluster with services but zero running tasks (investigate)
   1 AWS Batch-managed cluster (do not modify directly)
```

## Tools

| Tool | Status | What it does |
|------|--------|--------------|
| `discover/ecs-overview.sh` | shipped | Cluster/service/task summary with anomaly hints |
| `discover/aurora-ha-audit.sh` | shipped | Flags single-instance Aurora clusters, members crowded in one AZ, and standalone RDS without Multi-AZ |
| `discover/lambda-eol-scanner.py` | shipped | Flags Lambda functions on EOL or near-EOL runtimes |
| `discover/ecr-bloat-report.sh` | planned | Top ECR repos by image count without lifecycle policy |
| `discover/idle-resources.sh` | shipped | Stopped EC2 (with age), empty ECS clusters, ALBs with no targets, unattached EBS, unused EIPs |
| `audit/cost-hotspots.py` | planned | Cost Explorer query + topology-aware ranking |
| `audit/security-baseline.sh` | planned | Open SGs, public S3, IAM users with old keys |

See [ROADMAP.md](./ROADMAP.md) for the full sequence.

## Design principles

- **Read-only.** Every script is safe to run on production accounts.
- **No deps beyond `awscli` + `jq`** for shell tools. Python tools may use `boto3` only.
- **Single-file scripts** where possible. Vendoring `lib/common.sh` is the only exception.
- **Opinionated output.** Default is a human-readable table; `--json` for machines.
- **Anomaly hints, not just data.** The point is to surface what's worth investigating.

## Project layout

```
.
├── discover/   read-only inventory tools — what exists?
├── audit/      opinionated checks — is it healthy?  cost-wise?  secure?
├── lib/        shared bash helpers
└── docs/       longer-form explanations and runbooks
```

## License

MIT — see [LICENSE](./LICENSE).
