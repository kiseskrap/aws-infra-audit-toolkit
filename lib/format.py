"""Shared CSV and Markdown table renderers for Python tools.

Parallel to ``lib/format.sh``: callers supply an explicit column list so the
output schema stays stable across runs and isn't at the mercy of dict
iteration order. Missing fields render as empty cells (not the string
``"None"``) so spreadsheets and Markdown viewers don't show literal nulls.

This file is intentionally dependency-free beyond the standard library.
"""

from __future__ import annotations

import csv
import io
from collections.abc import Iterable, Sequence
from typing import Any


def _cell(value: Any) -> str:
    """Coerce a single cell value to its rendered string form.

    ``None`` becomes ``""`` rather than ``"None"``. Lists are flattened with
    ``", "`` so a row stays a single cell — relevant for fields like Lambda
    architectures that AWS returns as a list of one or two items.
    """
    if value is None:
        return ""
    if isinstance(value, list):
        return ", ".join(_cell(item) for item in value)
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value)


def format_csv(rows: Iterable[dict[str, Any]], columns: Sequence[str]) -> str:
    """Render rows as RFC 4180-quoted CSV with a header row.

    Embedded commas, quotes, and newlines in values are handled by the
    standard library's ``csv`` module.
    """
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    writer.writerow(columns)
    for row in rows:
        writer.writerow([_cell(row.get(col)) for col in columns])
    return buf.getvalue().rstrip("\n")


def format_md(rows: Iterable[dict[str, Any]], columns: Sequence[str]) -> str:
    """Render rows as a GitHub-flavored Markdown pipe table.

    Pipe characters in values become the HTML entity ``&#124;`` — which
    renders as ``|`` in every Markdown viewer and avoids breaking the table.
    """
    lines = [
        "| " + " | ".join(columns) + " |",
        "| " + " | ".join("---" for _ in columns) + " |",
    ]
    for row in rows:
        cells = [_cell(row.get(col)).replace("|", "&#124;") for col in columns]
        lines.append("| " + " | ".join(cells) + " |")
    return "\n".join(lines)
