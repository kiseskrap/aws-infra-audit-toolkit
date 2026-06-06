#!/usr/bin/env python3
"""Read-only Cost Explorer hotspot ranker.

Pulls the last 30 days of cost from AWS Cost Explorer grouped by service,
joins it with resource counts from the same account, and ranks services by
"where to look first". The cost per resource is the single most useful
number on the report — a $900/month service with three resources is a
very different conversation than the same $900 spread over 1,500
resources.

Cost Explorer lives in us-east-1 regardless of the resource region. The
counters use the user's configured region for regional services (ECS,
RDS, Lambda, EC2, EBS, EIP, ECR); accounts with multi-region resources
will see only the configured region's resource counts but the full bill.

Usage:
  ./audit/cost-hotspots.py [--format {table|json|csv|md}] [--days N] [--help]

Environment:
  AWS_PROFILE, AWS_REGION/AWS_DEFAULT_REGION  standard AWS SDK variables
  NO_COLOR=1                                  disable colored output

CSV / Markdown schema (one row per service):
  Service,DisplayName,MonthlyCostUsd,ResourceCount,AvgPerResourceUsd,Hints

IAM:
  ce:GetCostAndUsage  required (in the billing-enabled account)
  Each resource counter degrades to "?" if its IAM check fails — one
  permission gap does not abort the report.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any, Callable

# Allow `from lib.format import ...` when invoked as `./audit/cost-hotspots.py`.
_REPO_ROOT = Path(__file__).resolve().parent.parent
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from lib.format import format_csv, format_md  # noqa: E402

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except ImportError as exc:  # pragma: no cover - depends on local environment
    boto3 = None  # type: ignore[assignment]
    BotoCoreError = ClientError = NoCredentialsError = Exception  # type: ignore[misc,assignment]
    BOTO3_IMPORT_ERROR = exc
else:
    BOTO3_IMPORT_ERROR = None


# Cost Explorer is a global API — always in us-east-1 regardless of resource region.
CE_REGION = "us-east-1"

# Per-resource cost ceiling above which we flag the row as "expensive per unit".
# Tuned so noisy services (S3, CloudWatch) don't get the hint while genuinely
# concentrated cost (Aurora, OpenSearch, dedicated EC2) does.
HIGH_AVG_THRESHOLD_USD = 200.0

# Cost Explorer SERVICE names → (short display name, counter key).
# Multiple Cost Explorer service names can map to the same counter when AWS
# splits a service for billing purposes (notably EC2 — compute hours and
# EBS/EIP land under different group names).
SERVICE_DISPLAY = {
    "Amazon Elastic Compute Cloud - Compute": "EC2 - Compute",
    "EC2 - Other": "EC2 - Other",
    "Amazon Relational Database Service": "RDS",
    "AWS Lambda": "Lambda",
    "Amazon Elastic Container Service": "ECS",
    "Amazon EC2 Container Registry (ECR)": "ECR",
    "Amazon Simple Storage Service": "S3",
    "Amazon CloudFront": "CloudFront",
    "Amazon Route 53": "Route 53",
    "AWS Key Management Service": "KMS",
    "AmazonCloudWatch": "CloudWatch",
    "Amazon Simple Notification Service": "SNS",
    "Amazon Simple Queue Service": "SQS",
}

# Short display name → resource counter key. Counter results are reusable
# (RDS count joins to both "Amazon Relational Database Service" rows even
# if AWS later splits them).
COUNTERS_BY_DISPLAY = {
    "EC2 - Compute": "ec2_running",
    "EC2 - Other": "ec2_other",
    "RDS": "rds_total",
    "Lambda": "lambda_functions",
    "ECS": "ecs_clusters",
    "ECR": "ecr_repos",
}


class Colors:
    def __init__(self, enabled: bool) -> None:
        self.reset = "\033[0m" if enabled else ""
        self.bold = "\033[1m" if enabled else ""
        self.dim = "\033[2m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""


def die(message: str) -> None:
    print(f"[error] {message}", file=sys.stderr)
    sys.exit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Rank AWS services by 30-day cost, joined with topology counts.",
    )
    parser.add_argument(
        "--format",
        choices=["table", "json", "csv", "md"],
        default="table",
        help="output format (default: table)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="alias for --format json (kept for backward compat)",
    )
    parser.add_argument(
        "--days",
        type=int,
        default=30,
        help="lookback window in days (default: 30)",
    )
    args = parser.parse_args()
    if args.json:
        args.format = "json"
    if args.days <= 0:
        die("--days must be a positive integer")
    return args


def _safe_count(label: str, fn: Callable[[], int]) -> int | None:
    """Run a counter; return ``None`` (renders as "?") on access denied or API error.

    A single missing permission shouldn't blank the whole report — we still
    want every service row, even if its count column reads ``?``.
    """
    try:
        return fn()
    except (BotoCoreError, ClientError) as exc:
        print(f"[warn] {label}: {exc}", file=sys.stderr)
        return None


def count_lambda_functions(session: "boto3.session.Session") -> int:
    client = session.client("lambda")
    paginator = client.get_paginator("list_functions")
    return sum(len(page.get("Functions", [])) for page in paginator.paginate())


def count_rds_total(session: "boto3.session.Session") -> int:
    client = session.client("rds")
    instances = sum(
        len(p.get("DBInstances", []))
        for p in client.get_paginator("describe_db_instances").paginate()
    )
    clusters = sum(
        len(p.get("DBClusters", []))
        for p in client.get_paginator("describe_db_clusters").paginate()
    )
    return instances + clusters


def count_ecs_clusters(session: "boto3.session.Session") -> int:
    client = session.client("ecs")
    return sum(
        len(p.get("clusterArns", []))
        for p in client.get_paginator("list_clusters").paginate()
    )


def count_ec2_running(session: "boto3.session.Session") -> int:
    client = session.client("ec2")
    paginator = client.get_paginator("describe_instances")
    total = 0
    for page in paginator.paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page.get("Reservations", []):
            total += len(reservation.get("Instances", []))
    return total


def count_ec2_other(session: "boto3.session.Session") -> int:
    """EBS volumes + Elastic IPs + load balancers.

    AWS bills EBS, EIP, and LB under "EC2 - Other" in Cost Explorer, so the
    join is one number — three sub-queries summed. NAT gateways belong here
    too but are out of scope for this first pass; surfacing them properly
    needs the per-NAT data-processed metric, not just a count.
    """
    ec2 = session.client("ec2")
    volumes = sum(
        len(p.get("Volumes", []))
        for p in ec2.get_paginator("describe_volumes").paginate()
    )
    addresses = len(ec2.describe_addresses().get("Addresses", []))
    elbv2 = session.client("elbv2")
    lbs = sum(
        len(p.get("LoadBalancers", []))
        for p in elbv2.get_paginator("describe_load_balancers").paginate()
    )
    return volumes + addresses + lbs


def count_ecr_repos(session: "boto3.session.Session") -> int:
    client = session.client("ecr")
    return sum(
        len(p.get("repositories", []))
        for p in client.get_paginator("describe_repositories").paginate()
    )


COUNTER_FUNCTIONS: dict[str, Callable[["boto3.session.Session"], int]] = {
    "ec2_running": count_ec2_running,
    "ec2_other": count_ec2_other,
    "rds_total": count_rds_total,
    "lambda_functions": count_lambda_functions,
    "ecs_clusters": count_ecs_clusters,
    "ecr_repos": count_ecr_repos,
}


def session_region(session: "boto3.session.Session") -> str:
    region = (
        session.region_name
        or os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
    )
    if not region:
        die("no region configured (set AWS_REGION or configure your AWS profile)")
    return region


def fetch_service_costs(
    session: "boto3.session.Session", days: int
) -> tuple[dict[str, float], dict[str, str]]:
    """Sum DAILY UnblendedCost over the trailing `days` window, grouped by service.

    Returns ({service_name: usd_total}, {"start": iso, "end": iso}).
    """
    ce = session.client("ce", region_name=CE_REGION)
    end = date.today() + timedelta(days=1)
    start = end - timedelta(days=days)

    try:
        totals: dict[str, float] = {}
        kwargs: dict[str, Any] = {
            "TimePeriod": {"Start": start.isoformat(), "End": end.isoformat()},
            "Granularity": "DAILY",
            "Metrics": ["UnblendedCost"],
            "GroupBy": [{"Type": "DIMENSION", "Key": "SERVICE"}],
        }
        while True:
            resp = ce.get_cost_and_usage(**kwargs)
            for day in resp.get("ResultsByTime", []):
                for group in day.get("Groups", []):
                    name = group["Keys"][0]
                    amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
                    totals[name] = totals.get(name, 0.0) + amount
            token = resp.get("NextPageToken")
            if not token:
                break
            kwargs["NextPageToken"] = token
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("AccessDeniedException", "AccessDenied"):
            die(
                "Cost Explorer access denied. This tool requires "
                "ce:GetCostAndUsage in the billing-enabled account. "
                "If you don't have billing access, use "
                "audit/cost-rough-estimate.py (issue #18) for a list-price "
                "estimate that runs with only standard read-only IAM."
            )
        if code == "DataUnavailableException":
            die("Cost Explorer returned no data — has it been enabled for this account?")
        die(f"Cost Explorer error: {exc}")

    window = {"start": start.isoformat(), "end": end.isoformat()}
    return totals, window


def gather_counts(
    session: "boto3.session.Session", needed: set[str]
) -> dict[str, int | None]:
    """Run only the counter functions we need. Missing permissions → None."""
    counts: dict[str, int | None] = {}
    for key in needed:
        fn = COUNTER_FUNCTIONS.get(key)
        if fn is None:
            continue
        counts[key] = _safe_count(key, lambda fn=fn: fn(session))
    return counts


def compute_hints(
    cost: float, counter_key: str | None, count: int | None
) -> list[str]:
    hints: list[str] = []
    if count is None and counter_key is None and cost > 0:
        hints.append("no-counter-for-service")
    if count is not None and count > 0 and cost / count >= HIGH_AVG_THRESHOLD_USD:
        hints.append(f"high-avg-per-resource (>=${HIGH_AVG_THRESHOLD_USD:.0f}/mo)")
    if count is not None and count == 0 and cost > 0:
        hints.append("billed-but-no-resources-here")
    return hints


def build_rows(
    costs: dict[str, float], counts: dict[str, int | None]
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for service, cost in costs.items():
        display = SERVICE_DISPLAY.get(service, service)
        counter_key = COUNTERS_BY_DISPLAY.get(display)
        count = counts.get(counter_key) if counter_key else None
        avg = (cost / count) if (count is not None and count > 0) else None
        rows.append(
            {
                "service": service,
                "displayName": display,
                "monthlyCostUsd": round(cost, 2),
                "resourceCount": count,
                "avgPerResourceUsd": round(avg, 2) if avg is not None else None,
                "hints": compute_hints(cost, counter_key, count),
            }
        )
    rows.sort(key=lambda r: r["monthlyCostUsd"], reverse=True)
    return rows


FLAT_COLUMNS = (
    "Service",
    "DisplayName",
    "MonthlyCostUsd",
    "ResourceCount",
    "AvgPerResourceUsd",
    "Hints",
)


def flat_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "Service": r["service"],
            "DisplayName": r["displayName"],
            "MonthlyCostUsd": f"{r['monthlyCostUsd']:.2f}",
            "ResourceCount": "" if r["resourceCount"] is None else r["resourceCount"],
            "AvgPerResourceUsd": ""
            if r["avgPerResourceUsd"] is None
            else f"{r['avgPerResourceUsd']:.2f}",
            "Hints": ", ".join(r["hints"]),
        }
        for r in rows
    ]


def print_table(
    rows: list[dict[str, Any]],
    account_id: str,
    region: str,
    window: dict[str, str],
    colors: Colors,
) -> None:
    print(
        f"{colors.bold}Cost hotspots{colors.reset} — account {account_id}, "
        f"region {region} (CE in {CE_REGION})"
    )
    print(f"Window: {window['start']} → {window['end']} (exclusive)")

    if not rows:
        print("no service costs in the window — Cost Explorer returned no data.")
        return

    display_width = min(max(max(len(r["displayName"]) for r in rows), 14), 28)
    sep_width = display_width + 60
    sep = "─" * sep_width

    print(sep)
    print(
        f"{'Service':<{display_width}} {'Cost (USD)':>12} {'Count':>7} "
        f"{'Avg/res':>10}  Hints"
    )
    print(sep)

    for r in rows:
        name = r["displayName"]
        if len(name) > display_width:
            name = name[: display_width - 1] + "~"
        cost = f"{r['monthlyCostUsd']:.2f}"
        count = "?" if r["resourceCount"] is None else str(r["resourceCount"])
        avg = "-" if r["avgPerResourceUsd"] is None else f"{r['avgPerResourceUsd']:.2f}"
        hints = ", ".join(r["hints"])
        hint_marker = f"{colors.yellow}[!] {hints}{colors.reset}" if hints else ""
        print(
            f"{name:<{display_width}} {cost:>12} {count:>7} {avg:>10}  {hint_marker}"
        )

    print(sep)
    total = sum(r["monthlyCostUsd"] for r in rows)
    print(
        f"Total {len(rows)} services, ${total:,.2f} over "
        f"{(date.fromisoformat(window['end']) - date.fromisoformat(window['start'])).days} days"
    )


def main() -> None:
    args = parse_args()
    colors = Colors(enabled=sys.stdout.isatty() and not os.environ.get("NO_COLOR"))

    if BOTO3_IMPORT_ERROR is not None:
        die("required Python package not found: boto3")

    try:
        session = boto3.Session()
        region = session_region(session)
        account_id = session.client("sts").get_caller_identity()["Account"]
        costs, window = fetch_service_costs(session, args.days)
    except NoCredentialsError:
        die("AWS credentials are not configured or invalid")
    except (BotoCoreError, ClientError) as exc:
        die(str(exc))

    needed_counters = {
        COUNTERS_BY_DISPLAY[SERVICE_DISPLAY[svc]]
        for svc in costs
        if SERVICE_DISPLAY.get(svc) in COUNTERS_BY_DISPLAY
    }
    counts = gather_counts(session, needed_counters)
    rows = build_rows(costs, counts)

    if args.format == "json":
        print(
            json.dumps(
                {
                    "generatedAt": datetime.utcnow().replace(microsecond=0).isoformat()
                    + "Z",
                    "account": account_id,
                    "region": region,
                    "window": window,
                    "services": rows,
                    "summary": {
                        "servicesAnalyzed": len(rows),
                        "totalCostUsd": round(
                            sum(r["monthlyCostUsd"] for r in rows), 2
                        ),
                        "topService": rows[0]["service"] if rows else None,
                    },
                },
                indent=2,
                sort_keys=True,
            )
        )
        return

    if args.format == "csv":
        print(format_csv(flat_rows(rows), FLAT_COLUMNS))
        return

    if args.format == "md":
        print(format_md(flat_rows(rows), FLAT_COLUMNS))
        return

    print_table(rows, account_id, region, window, colors)


if __name__ == "__main__":
    main()
