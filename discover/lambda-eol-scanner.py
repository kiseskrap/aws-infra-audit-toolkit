#!/usr/bin/env python3
"""Read-only Lambda runtime EOL scanner.

Lists Lambda functions in the current account/region and flags runtimes that
are already deprecated or within the warning window.

Usage:
  ./discover/lambda-eol-scanner.py [--json] [--help]

Environment:
  AWS_PROFILE, AWS_REGION/AWS_DEFAULT_REGION  standard AWS SDK variables
  NO_COLOR=1                                  disable colored output
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime
from typing import Any

try:
    import boto3
    from botocore.exceptions import BotoCoreError, ClientError, NoCredentialsError
except ImportError as exc:  # pragma: no cover - depends on local environment
    boto3 = None  # type: ignore[assignment]
    BotoCoreError = ClientError = NoCredentialsError = Exception  # type: ignore[misc,assignment]
    BOTO3_IMPORT_ERROR = exc
else:
    BOTO3_IMPORT_ERROR = None


WARN_DAYS = 180

# Based on the AWS Lambda runtimes table, checked 2026-05-23:
# https://docs.aws.amazon.com/lambda/latest/dg/lambda-runtimes.html
RUNTIME_DEPRECATIONS = {
    "nodejs24.x": "2028-04-30",
    "nodejs22.x": "2027-04-30",
    "nodejs20.x": "2026-04-30",
    "nodejs18.x": "2025-09-01",
    "nodejs16.x": "2024-06-12",
    "nodejs14.x": "2023-12-04",
    "nodejs12.x": "2023-03-31",
    "nodejs10.x": "2021-07-30",
    "python3.14": "2029-06-30",
    "python3.13": "2029-06-30",
    "python3.12": "2028-10-31",
    "python3.11": "2027-06-30",
    "python3.10": "2026-10-31",
    "python3.9": "2025-12-15",
    "python3.8": "2024-10-14",
    "python3.7": "2023-12-04",
    "python3.6": "2022-07-18",
    "python2.7": "2021-07-15",
    "java25": "2029-06-30",
    "java21": "2029-06-30",
    "java17": "2027-06-30",
    "java11": "2027-06-30",
    "java8.al2": "2027-06-30",
    "java8": "2024-01-08",
    "dotnet10": "2028-11-14",
    "dotnet9": "2026-11-10",
    "dotnet8": "2026-11-10",
    "dotnet6": "2024-12-20",
    "dotnet7": "2024-05-14",
    "dotnet5.0": "2022-05-10",
    "dotnetcore3.1": "2023-04-03",
    "dotnetcore2.1": "2022-01-05",
    "ruby4.0": "2029-03-31",
    "ruby3.4": "2028-03-31",
    "ruby3.3": "2027-03-31",
    "ruby3.2": "2026-03-31",
    "ruby2.7": "2023-12-07",
    "ruby2.5": "2021-07-30",
    "provided.al2023": "2029-06-30",
    "provided.al2": "2026-07-31",
    "provided": "2024-01-08",
    "go1.x": "2024-01-08",
}


class Colors:
    def __init__(self, enabled: bool) -> None:
        self.reset = "\033[0m" if enabled else ""
        self.bold = "\033[1m" if enabled else ""
        self.yellow = "\033[33m" if enabled else ""
        self.red = "\033[31m" if enabled else ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Flag Lambda functions on EOL or near-EOL runtimes."
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="emit machine-readable JSON instead of a table",
    )
    return parser.parse_args()


def die(message: str) -> None:
    print(f"[error] {message}", file=sys.stderr)
    sys.exit(1)


def runtime_status(runtime: str | None, today: date) -> dict[str, Any]:
    if not runtime:
        return {
            "status": "unknown",
            "daysUntilDeprecation": None,
            "deprecationDate": None,
            "hint": "container-image-or-missing-runtime",
        }

    deprecation_raw = RUNTIME_DEPRECATIONS.get(runtime)
    if not deprecation_raw:
        return {
            "status": "unknown",
            "daysUntilDeprecation": None,
            "deprecationDate": None,
            "hint": "runtime-not-in-local-calendar",
        }

    deprecation_date = date.fromisoformat(deprecation_raw)
    days = (deprecation_date - today).days
    if days < 0:
        status = "eol"
        hint = "runtime-deprecated"
    elif days <= WARN_DAYS:
        status = "warn"
        hint = "runtime-deprecates-within-180-days"
    else:
        status = "ok"
        hint = ""

    return {
        "status": status,
        "daysUntilDeprecation": days,
        "deprecationDate": deprecation_raw,
        "hint": hint,
    }


def session_region(session: boto3.session.Session) -> str:
    region = session.region_name or os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
    if not region:
        die("no region configured (set AWS_REGION or configure your AWS profile)")
    return region


def _progress(message: str) -> None:
    """Write an in-place status line to stderr, only when stderr is a TTY.

    Mirrors lib/common.sh's progress() so JSON pipelines and CI runs stay
    quiet but interactive users see something move during pagination.
    """
    if sys.stderr.isatty():
        sys.stderr.write(f"\r\033[K{message}")
        sys.stderr.flush()


def _progress_clear() -> None:
    if sys.stderr.isatty():
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()


def fetch_functions(session: boto3.session.Session) -> list[dict[str, Any]]:
    client = session.client("lambda")
    paginator = client.get_paginator("list_functions")
    functions: list[dict[str, Any]] = []

    for page_num, page in enumerate(paginator.paginate(), start=1):
        for fn in page.get("Functions", []):
            runtime = fn.get("Runtime")
            status = runtime_status(runtime, date.today())
            functions.append(
                {
                    "functionName": fn.get("FunctionName", ""),
                    "runtime": runtime,
                    "status": status["status"],
                    "deprecationDate": status["deprecationDate"],
                    "daysUntilDeprecation": status["daysUntilDeprecation"],
                    "lastModified": fn.get("LastModified", ""),
                    "packageType": fn.get("PackageType", ""),
                    "architectures": fn.get("Architectures", []),
                    "hint": status["hint"],
                }
            )
        _progress(f"scanned {len(functions)} functions (page {page_num})")

    _progress_clear()
    return functions


def summarize(functions: list[dict[str, Any]]) -> dict[str, int]:
    return {
        "total": len(functions),
        "eol": sum(1 for fn in functions if fn["status"] == "eol"),
        "warn": sum(1 for fn in functions if fn["status"] == "warn"),
        "ok": sum(1 for fn in functions if fn["status"] == "ok"),
        "unknown": sum(1 for fn in functions if fn["status"] == "unknown"),
    }


def print_table(
    functions: list[dict[str, Any]],
    account_id: str,
    region: str,
    colors: Colors,
) -> None:
    if not functions:
        print(f"no Lambda functions in account {account_id} / {region}", file=sys.stderr)
        return

    rows = sorted(
        functions,
        key=lambda fn: (
            {"eol": 0, "warn": 1, "unknown": 2, "ok": 3}.get(fn["status"], 4),
            fn["functionName"],
        ),
    )

    name_width = min(max(max(len(fn["functionName"]) for fn in rows), 24), 60)
    sep_width = name_width + 64
    sep = "-" * sep_width

    print(f"{colors.bold}Lambda runtime EOL scanner{colors.reset} - account {account_id}, region {region}")
    print(sep)
    print(
        f"{'Function':<{name_width}} {'Runtime':<14} {'Status':<7} "
        f"{'Deprecates':<12} {'Days':>6}  Hint"
    )
    print(sep)

    for fn in rows:
        name = fn["functionName"]
        if len(name) > name_width:
            name = f"{name[: name_width - 1]}~"

        status = fn["status"]
        status_color = colors.red if status == "eol" else colors.yellow if status == "warn" else ""
        reset = colors.reset if status_color else ""
        days = fn["daysUntilDeprecation"]
        print(
            f"{name:<{name_width}} "
            f"{(fn['runtime'] or '-'):14.14} "
            f"{status_color}{status:<7}{reset} "
            f"{(fn['deprecationDate'] or '-'):12.12} "
            f"{str(days) if days is not None else '-':>6}  "
            f"{fn['hint']}"
        )

    print(sep)
    summary = summarize(functions)
    print(
        "Summary: "
        f"{summary['total']} functions, "
        f"{summary['eol']} EOL, "
        f"{summary['warn']} near EOL, "
        f"{summary['unknown']} unknown/container, "
        f"{summary['ok']} OK"
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
        functions = fetch_functions(session)
    except NoCredentialsError:
        die("AWS credentials are not configured or invalid")
    except (BotoCoreError, ClientError) as exc:
        die(str(exc))

    if args.json:
        print(
            json.dumps(
                {
                    "generatedAt": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
                    "account": account_id,
                    "region": region,
                    "summary": summarize(functions),
                    "functions": sorted(
                        functions,
                        key=lambda fn: (fn["status"], fn["functionName"]),
                    ),
                },
                indent=2,
                sort_keys=True,
            )
        )
        return

    print_table(functions, account_id, region, colors)


if __name__ == "__main__":
    main()
