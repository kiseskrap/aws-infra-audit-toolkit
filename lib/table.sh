#!/usr/bin/env bash
# lib/table.sh — shared ASCII table-rendering helpers.
#
# Most discovery and audit tools render a pretty table after sorting their
# rows by hint count (rows with annotations float to the top). The helpers
# below extract the pieces that were copy-pasted across tools:
#
#   - table_col_width   data-driven column width with [min, max] clamp
#   - table_sep         horizontal separator of N "─" characters
#   - sort_by_hints     jq snippet for the hint-flagged sort
#   - table_section_header
#                       bold label + matching underline for tools that
#                       render multiple sub-tables in one run
#
# Dependency-free beyond jq, which the toolkit already requires. This file
# does NOT source lib/common.sh — callers do that and provide C_BOLD /
# C_RESET in their environment; the helpers fall back to empty strings when
# those aren't set, so a tool that opted out of colors still gets sane output.

# Compute a column width from a JSON array of objects.
#
#   table_col_width JSON_ARRAY EXPR MIN [MAX]
#
# EXPR is a jq selector (e.g. .name) evaluated per item; the helper takes
# the longest result, clamps it to MIN/MAX, and prints the resulting width.
# When MAX is omitted (or 0) the upper bound is unconstrained — useful for
# fields like RDS instance class whose maximum length is naturally bounded
# but you don't want to truncate.
#
#   width=$(table_col_width "$rows" .name 30 60)
table_col_width() {
  local json=$1 expr=$2 min=$3 max=${4:-0}
  local width
  width=$(echo "$json" | jq -r "map(${expr} | length) | max // ${min}")
  (( width < min )) && width=$min
  (( max > 0 && width > max )) && width=$max
  printf '%s\n' "$width"
}

# Print a horizontal separator of N "─" characters followed by a newline.
# Suitable for direct printing or capture via command substitution (the
# trailing newline is stripped by $()).
#
#   table_sep 60
#   sep=$(table_sep 60)
table_sep() {
  printf '%.0s─' $(seq 1 "$1")
  printf '\n'
}

# Print a jq snippet that sorts a row array by hint count (more hints first)
# with ties broken by the supplied identifier expression.
#
#   echo "$rows" | jq -r "$(sort_by_hints .name) | .[] | ..."
sort_by_hints() {
  printf 'sort_by((.hints | length) * -1, %s)' "$1"
}

# Print a bold section header with an underline of dashes matching the
# label length. Used by tools that emit multiple labeled sub-tables in
# one run (idle-resources, security-baseline).
#
# Reads C_BOLD / C_RESET from the caller's environment when present; falls
# back to empty so non-TTY / NO_COLOR runs still produce clean output.
#
#   table_section_header "Stopped EC2 instances (>30d)"
table_section_header() {
  local label=$1
  printf '\n%s%s%s\n' "${C_BOLD:-}" "$label" "${C_RESET:-}"
  printf '%s\n' "$(printf '%.0s─' $(seq 1 ${#label}))"
}
