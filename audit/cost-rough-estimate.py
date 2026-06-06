#!/usr/bin/env python3
"""Read-only list-price cost estimator from inventory.

A complement to ``audit/cost-hotspots.py``. Where cost-hotspots needs
``ce:GetCostAndUsage`` in the billing-enabled account, this tool runs
with only standard read-only IAM and answers a different question:

  "Given the resources I can see right now, what would the catalog
   on-demand price say they cost per month?"

The number is intentionally an upper bound — actual bills are usually
lower because of Savings Plans, Reserved Instances, and private pricing
(EDP). The gap between this estimate and the cost-hotspots actual is a
useful signal on its own: a small gap means the account is paying close
to list, a large gap means committed-use discounts are working.

Categories covered (each is independent — one permission gap or API
error only blanks that category):

  - EC2 (running instances; per-instance-type on-demand rate)
  - RDS (DB instances; on-demand rate by class)
  - EBS (volumes by type and size, $/GB-month)
  - ELB (ALB + NLB + GLB base hours, LCU charges excluded)
  - EIP (unassociated only; associated EIPs on running instances are free)

Usage:
  ./audit/cost-rough-estimate.py [--format {table|json|csv|md}] [--help]

Environment:
  AWS_PROFILE, AWS_REGION/AWS_DEFAULT_REGION  standard AWS SDK variables
  NO_COLOR=1                                  disable colored output

CSV / Markdown schema (one row per category):
  Category,MonthlyCostUsd,ResourceCount,AvgPerResourceUsd,Note

IAM:
  pricing:GetProducts        global
  ec2:Describe*              for EC2/EBS/EIP counts
  rds:DescribeDBInstances    for RDS counts
  elasticloadbalancing:Describe*  for ELB counts

  Each category catches its own errors and reports `?` instead of
  aborting the run, so an account with mixed permissions still gets
  a partial estimate.

Honest limits documented in the report header:
  - List price ≠ actual bill (no RI / Savings Plans / private pricing).
  - Inventory-driven, not usage-driven: a half-idle m5.large costs the
    same here as a fully-loaded one. Pair with discover/idle-resources
    for the other half of the picture.
  - Region-scoped: multi-region accounts only see this region's resources.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

# Allow `from lib.format import ...` when invoked as `./audit/cost-rough-estimate.py`.
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


# Pricing API is global and always lives in us-east-1.
PRICING_REGION = "us-east-1"

# Average hours per month. Used to multiply hourly rates. 24 * 365.25 / 12.
HOURS_PER_MONTH = 730.0

# Pricing API expects "location" as a human-friendly name, not a region code.
# Maintained by hand because AWS does not expose a region→location lookup.
# Covers the regions most users will hit; an unmapped region falls back to
# skipping each category with a clear note rather than guessing.
REGION_TO_LOCATION = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-1": "US West (N. California)",
    "us-west-2": "US West (Oregon)",
    "ca-central-1": "Canada (Central)",
    "sa-east-1": "South America (Sao Paulo)",
    "ap-northeast-1": "Asia Pacific (Tokyo)",
    "ap-northeast-2": "Asia Pacific (Seoul)",
    "ap-northeast-3": "Asia Pacific (Osaka)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
    "ap-southeast-2": "Asia Pacific (Sydney)",
    "ap-south-1": "Asia Pacific (Mumbai)",
    "eu-west-1": "EU (Ireland)",
    "eu-west-2": "EU (London)",
    "eu-west-3": "EU (Paris)",
    "eu-central-1": "EU (Frankfurt)",
    "eu-north-1": "EU (Stockholm)",
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
        description="Estimate monthly cost from inventory using AWS Pricing list rates.",
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
    args = parser.parse_args()
    if args.json:
        args.format = "json"
    return args


def session_region(session: "boto3.session.Session") -> str:
    region = (
        session.region_name
        or os.environ.get("AWS_REGION")
        or os.environ.get("AWS_DEFAULT_REGION")
    )
    if not region:
        die("no region configured (set AWS_REGION or configure your AWS profile)")
    return region


def _first_ondemand_price(item: dict[str, Any]) -> float | None:
    """Walk the standard Pricing API nesting to a USD per-unit number.

    The Pricing API returns the catalog as a deeply nested dict; the
    OnDemand term contains a priceDimensions map with one or more entries
    (usage tiers, etc.). For the rates we care about — instance-hour,
    GB-month, LB-hour — there's exactly one dimension. Take the first
    USD price we find; ignore zero-priced fallthroughs that some entries
    use as anchors.
    """
    for term in item.get("terms", {}).get("OnDemand", {}).values():
        for dim in term.get("priceDimensions", {}).values():
            usd = dim.get("pricePerUnit", {}).get("USD")
            if usd is None:
                continue
            try:
                price = float(usd)
            except (TypeError, ValueError):
                continue
            if price > 0:
                return price
    return None


def _pricing_lookup(
    pricing: Any,
    service_code: str,
    filters: list[dict[str, str]],
) -> float | None:
    """Return the first non-zero USD on-demand rate matching `filters`."""
    paginator = pricing.get_paginator("get_products")
    for page in paginator.paginate(ServiceCode=service_code, Filters=filters):
        for raw in page.get("PriceList", []):
            item = json.loads(raw)
            price = _first_ondemand_price(item)
            if price is not None:
                return price
    return None


# -----------------------------------------------------------------------------
# Per-category counters and pricers.
# Each returns (monthlyCostUsd, count, breakdown) or raises a ClientError /
# BotoCoreError that the caller turns into a category-level "?" entry.
# -----------------------------------------------------------------------------


def estimate_ec2(
    session: "boto3.session.Session",
    pricing: Any,
    location: str,
) -> dict[str, Any]:
    """Sum running EC2 instances × on-demand Linux/Shared rate per instance type."""
    ec2 = session.client("ec2")
    by_type: dict[str, int] = {}
    for page in ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}]
    ):
        for reservation in page.get("Reservations", []):
            for inst in reservation.get("Instances", []):
                t = inst.get("InstanceType", "unknown")
                by_type[t] = by_type.get(t, 0) + 1

    breakdown: dict[str, dict[str, float]] = {}
    total = 0.0
    count = 0
    for itype, n in sorted(by_type.items()):
        rate = _pricing_lookup(
            pricing,
            "AmazonEC2",
            [
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": itype},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": "Linux"},
                {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "preInstalledSw", "Value": "NA"},
                {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
            ],
        )
        unit = (rate * HOURS_PER_MONTH) if rate is not None else None
        line = (unit * n) if unit is not None else None
        breakdown[itype] = {
            "count": n,
            "unitMonthlyUsd": round(unit, 2) if unit is not None else None,
            "monthlyUsd": round(line, 2) if line is not None else None,
        }
        if line is not None:
            total += line
        count += n
    return {"monthlyCostUsd": round(total, 2), "resourceCount": count, "breakdown": breakdown}


def estimate_rds(
    session: "boto3.session.Session",
    pricing: Any,
    location: str,
) -> dict[str, Any]:
    """Sum DB instances × on-demand rate per instance class+engine.

    Aurora cluster nodes show up as DB instances here, so no separate
    cluster pass is needed for the cost side. Engine matters for
    pricing (postgres vs mysql vs Aurora differ), so the breakdown
    keys are "class|engine".
    """
    rds = session.client("rds")
    by_combo: dict[str, dict[str, str | int]] = {}
    for page in rds.get_paginator("describe_db_instances").paginate():
        for db in page.get("DBInstances", []):
            cls = db.get("DBInstanceClass", "unknown")
            engine = db.get("Engine", "unknown")
            key = f"{cls}|{engine}"
            if key not in by_combo:
                by_combo[key] = {"class": cls, "engine": engine, "count": 0}
            by_combo[key]["count"] = int(by_combo[key]["count"]) + 1

    breakdown: dict[str, dict[str, float | None]] = {}
    total = 0.0
    count = 0
    for key, info in sorted(by_combo.items()):
        cls = str(info["class"])
        engine = str(info["engine"])
        n = int(info["count"])
        rate = _pricing_lookup(
            pricing,
            "AmazonRDS",
            [
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": cls},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                {"Type": "TERM_MATCH", "Field": "databaseEngine", "Value": _rds_engine_for_pricing(engine)},
                {"Type": "TERM_MATCH", "Field": "deploymentOption", "Value": "Single-AZ"},
            ],
        )
        unit = (rate * HOURS_PER_MONTH) if rate is not None else None
        line = (unit * n) if unit is not None else None
        breakdown[key] = {
            "count": n,
            "unitMonthlyUsd": round(unit, 2) if unit is not None else None,
            "monthlyUsd": round(line, 2) if line is not None else None,
        }
        if line is not None:
            total += line
        count += n
    return {"monthlyCostUsd": round(total, 2), "resourceCount": count, "breakdown": breakdown}


def _rds_engine_for_pricing(engine: str) -> str:
    """Translate boto3 engine names to Pricing API ``databaseEngine`` values.

    Pricing groups engines coarsely; mapping a few common boto3 ids
    here covers the bulk of estimates. Unmapped engines pass through
    unchanged and probably won't match a price — the catch in the
    caller turns that into a `?` line, which is honest.
    """
    mapping = {
        "postgres": "PostgreSQL",
        "aurora-postgresql": "Aurora PostgreSQL",
        "aurora-mysql": "Aurora MySQL",
        "mysql": "MySQL",
        "mariadb": "MariaDB",
        "oracle-ee": "Oracle",
        "oracle-se2": "Oracle",
        "sqlserver-ex": "SQL Server",
        "sqlserver-se": "SQL Server",
        "sqlserver-ee": "SQL Server",
    }
    return mapping.get(engine, engine)


# EBS Pricing API ``volumeApiName`` for each boto3 ``VolumeType``.
EBS_PRICING_NAME = {
    "gp2": "gp2",
    "gp3": "gp3",
    "io1": "io1",
    "io2": "io2",
    "st1": "st1",
    "sc1": "sc1",
    "standard": "standard",
}


def estimate_ebs(
    session: "boto3.session.Session",
    pricing: Any,
    location: str,
) -> dict[str, Any]:
    """Sum EBS volume size × GB-month rate per volume type.

    IOPS and throughput charges (gp3 baseline, io1/io2 provisioned) are
    out of scope for this estimate — they're a noticeable line item
    only on specific workloads and the catalog lookup gets considerably
    more complex. Documented in the report.
    """
    ec2 = session.client("ec2")
    by_type: dict[str, dict[str, int]] = {}
    for page in ec2.get_paginator("describe_volumes").paginate():
        for vol in page.get("Volumes", []):
            t = vol.get("VolumeType", "unknown")
            size = int(vol.get("Size") or 0)
            if t not in by_type:
                by_type[t] = {"count": 0, "totalGb": 0}
            by_type[t]["count"] += 1
            by_type[t]["totalGb"] += size

    breakdown: dict[str, dict[str, float | None]] = {}
    total = 0.0
    count = 0
    for vtype, info in sorted(by_type.items()):
        pricing_name = EBS_PRICING_NAME.get(vtype, vtype)
        rate = _pricing_lookup(
            pricing,
            "AmazonEC2",
            [
                {"Type": "TERM_MATCH", "Field": "productFamily", "Value": "Storage"},
                {"Type": "TERM_MATCH", "Field": "volumeApiName", "Value": pricing_name},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
            ],
        )
        line = (rate * info["totalGb"]) if rate is not None else None
        breakdown[vtype] = {
            "count": info["count"],
            "totalGb": info["totalGb"],
            "unitGbMonthUsd": round(rate, 4) if rate is not None else None,
            "monthlyUsd": round(line, 2) if line is not None else None,
        }
        if line is not None:
            total += line
        count += info["count"]
    return {"monthlyCostUsd": round(total, 2), "resourceCount": count, "breakdown": breakdown}


ELB_PRODUCT_FAMILY = {
    "application": "Load Balancer-Application",
    "network": "Load Balancer-Network",
    "gateway": "Load Balancer-Gateway",
}


def estimate_elb(
    session: "boto3.session.Session",
    pricing: Any,
    location: str,
) -> dict[str, Any]:
    """Sum load balancers × hourly base rate per type.

    LCU charges scale with traffic and are deliberately out of scope —
    only the fixed hourly base is included here. Looked up by
    ``productFamily`` (Application/Network/Gateway) + ``location`` so
    the filter stays region-independent (per-region ``usagetype`` codes
    like ``APN2-LoadBalancerUsage`` are not stable across all regions).
    """
    elbv2 = session.client("elbv2")
    by_type: dict[str, int] = {}
    for page in elbv2.get_paginator("describe_load_balancers").paginate():
        for lb in page.get("LoadBalancers", []):
            t = lb.get("Type", "unknown")
            by_type[t] = by_type.get(t, 0) + 1

    breakdown: dict[str, dict[str, float | None]] = {}
    total = 0.0
    count = 0
    for lb_type, n in sorted(by_type.items()):
        family = ELB_PRODUCT_FAMILY.get(lb_type)
        rate = None
        if family is not None:
            rate = _pricing_lookup(
                pricing,
                "AWSELB",
                [
                    {"Type": "TERM_MATCH", "Field": "productFamily", "Value": family},
                    {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                ],
            )
        unit = (rate * HOURS_PER_MONTH) if rate is not None else None
        line = (unit * n) if unit is not None else None
        breakdown[lb_type] = {
            "count": n,
            "unitMonthlyUsd": round(unit, 2) if unit is not None else None,
            "monthlyUsd": round(line, 2) if line is not None else None,
        }
        if line is not None:
            total += line
        count += n
    return {"monthlyCostUsd": round(total, 2), "resourceCount": count, "breakdown": breakdown}


def estimate_eip(
    session: "boto3.session.Session",
    pricing: Any,
    location: str,
) -> dict[str, Any]:
    """Sum *unassociated* Elastic IPs × hourly idle rate.

    Associated EIPs on running instances are free; AWS charges only
    when an EIP is allocated but not in use. The unused-EIP cost is
    consistently ~$3.65/month per address but we fetch it from the
    catalog so the number stays correct if pricing changes.
    """
    ec2 = session.client("ec2")
    addresses = ec2.describe_addresses().get("Addresses", [])
    unassoc = [a for a in addresses if not a.get("AssociationId")]
    n = len(unassoc)

    rate = _pricing_lookup(
        pricing,
        "AmazonEC2",
        [
            {"Type": "TERM_MATCH", "Field": "productFamily", "Value": "IP Address"},
            {"Type": "TERM_MATCH", "Field": "location", "Value": location},
            {"Type": "TERM_MATCH", "Field": "group", "Value": "ElasticIP:IdleAddress"},
        ],
    )
    unit = (rate * HOURS_PER_MONTH) if rate is not None else None
    line = (unit * n) if unit is not None else None
    return {
        "monthlyCostUsd": round(line, 2) if line is not None else 0.0,
        "resourceCount": n,
        "breakdown": {
            "unassociated": {
                "count": n,
                "unitMonthlyUsd": round(unit, 2) if unit is not None else None,
                "monthlyUsd": round(line, 2) if line is not None else None,
            }
        },
    }


CATEGORIES: list[tuple[str, Callable[..., dict[str, Any]]]] = [
    ("EC2", estimate_ec2),
    ("RDS", estimate_rds),
    ("EBS", estimate_ebs),
    ("ELB", estimate_elb),
    ("EIP", estimate_eip),
]


def gather_estimates(
    session: "boto3.session.Session", pricing: Any, location: str
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for name, fn in CATEGORIES:
        try:
            result = fn(session, pricing, location)
            note = ""
            if result["resourceCount"] > 0 and result["monthlyCostUsd"] == 0.0:
                note = "no pricing match"
            rows.append(
                {
                    "category": name,
                    "monthlyCostUsd": result["monthlyCostUsd"],
                    "resourceCount": result["resourceCount"],
                    "avgPerResourceUsd": (
                        round(result["monthlyCostUsd"] / result["resourceCount"], 2)
                        if result["resourceCount"] > 0
                        and result["monthlyCostUsd"] > 0
                        else None
                    ),
                    "note": note,
                    "breakdown": result["breakdown"],
                }
            )
        except (BotoCoreError, ClientError) as exc:
            print(f"[warn] {name}: {exc}", file=sys.stderr)
            rows.append(
                {
                    "category": name,
                    "monthlyCostUsd": None,
                    "resourceCount": None,
                    "avgPerResourceUsd": None,
                    "note": "access denied / api error",
                    "breakdown": {},
                }
            )
    rows.sort(
        key=lambda r: (r["monthlyCostUsd"] if r["monthlyCostUsd"] is not None else -1.0),
        reverse=True,
    )
    return rows


FLAT_COLUMNS = (
    "Category",
    "MonthlyCostUsd",
    "ResourceCount",
    "AvgPerResourceUsd",
    "Note",
)


def flat_rows(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "Category": r["category"],
            "MonthlyCostUsd": "" if r["monthlyCostUsd"] is None else f"{r['monthlyCostUsd']:.2f}",
            "ResourceCount": "" if r["resourceCount"] is None else r["resourceCount"],
            "AvgPerResourceUsd": ""
            if r["avgPerResourceUsd"] is None
            else f"{r['avgPerResourceUsd']:.2f}",
            "Note": r["note"],
        }
        for r in rows
    ]


def print_table(
    rows: list[dict[str, Any]],
    account_id: str,
    region: str,
    location: str,
    colors: Colors,
) -> None:
    print(
        f"{colors.bold}Cost rough estimate{colors.reset} (list price) — "
        f"account {account_id}, region {region}"
    )
    print(f"Pricing location: {location}")
    print(
        f"{colors.dim}List price; excludes RI / Savings Plans / private pricing. "
        f"Inventory-driven; idle resources cost the same here as fully used ones.{colors.reset}"
    )

    sep = "─" * 70
    print(sep)
    print(f"{'Category':<10} {'Cost (USD)':>12} {'Count':>7} {'Avg/res':>10}  Note")
    print(sep)
    for r in rows:
        cost = "?" if r["monthlyCostUsd"] is None else f"{r['monthlyCostUsd']:.2f}"
        count = "?" if r["resourceCount"] is None else str(r["resourceCount"])
        avg = "-" if r["avgPerResourceUsd"] is None else f"{r['avgPerResourceUsd']:.2f}"
        note_marker = ""
        if r["note"]:
            note_marker = f"{colors.yellow}[!] {r['note']}{colors.reset}"
        print(
            f"{r['category']:<10} {cost:>12} {count:>7} {avg:>10}  {note_marker}"
        )
    print(sep)

    total = sum(
        r["monthlyCostUsd"] for r in rows if r["monthlyCostUsd"] is not None
    )
    blanks = sum(1 for r in rows if r["monthlyCostUsd"] is None)
    suffix = f" ({blanks} category/categories unavailable)" if blanks else ""
    print(f"Total (where priced): ${total:,.2f}/month{suffix}")


def main() -> None:
    args = parse_args()
    colors = Colors(enabled=sys.stdout.isatty() and not os.environ.get("NO_COLOR"))

    if BOTO3_IMPORT_ERROR is not None:
        die("required Python package not found: boto3")

    try:
        session = boto3.Session()
        region = session_region(session)
        location = REGION_TO_LOCATION.get(region)
        if location is None:
            die(
                f"no Pricing API location mapping for region '{region}'. "
                "Add it to REGION_TO_LOCATION in audit/cost-rough-estimate.py "
                "(see https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/billing-what-is.html#billing-regions)."
            )
        account_id = session.client("sts").get_caller_identity()["Account"]
        pricing = session.client("pricing", region_name=PRICING_REGION)
        rows = gather_estimates(session, pricing, location)
    except NoCredentialsError:
        die("AWS credentials are not configured or invalid")
    except (BotoCoreError, ClientError) as exc:
        die(str(exc))

    if args.format == "json":
        print(
            json.dumps(
                {
                    "generatedAt": datetime.utcnow().replace(microsecond=0).isoformat()
                    + "Z",
                    "account": account_id,
                    "region": region,
                    "location": location,
                    "categories": rows,
                    "summary": {
                        "totalCostUsd": round(
                            sum(
                                r["monthlyCostUsd"]
                                for r in rows
                                if r["monthlyCostUsd"] is not None
                            ),
                            2,
                        ),
                        "categoriesPriced": sum(
                            1 for r in rows if r["monthlyCostUsd"] is not None
                        ),
                        "categoriesUnavailable": sum(
                            1 for r in rows if r["monthlyCostUsd"] is None
                        ),
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

    print_table(rows, account_id, region, location, colors)


if __name__ == "__main__":
    main()
