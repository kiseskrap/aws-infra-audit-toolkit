#!/usr/bin/env bash
# lib/format.sh — shared CSV and Markdown table renderers.
#
# Both helpers read a JSON array of objects from stdin and write the
# corresponding text format to stdout. The caller supplies an explicit
# comma-separated column list — column order is stable across runs and not
# at the mercy of jq key-order. Missing fields render as empty cells, not
# "null", so spreadsheets and Markdown viewers don't show literal nulls.
#
# Why a column list and not auto-derived: every audit tool flattens its
# nested per-category data into a unified row schema before formatting, and
# that schema is part of the tool's contract with its FinOps / SRE consumers.
# Forcing it explicit prevents accidental schema drift if a tool's jq pipeline
# starts emitting fields in a different order.
#
# This file is intentionally dependency-free beyond jq, which the toolkit
# already requires.

# Print a CSV table with header. RFC 4180 quoting via jq's @csv builtin.
# Embedded commas, quotes, and newlines in values are handled by jq.
#
#   echo '[{"a":1,"b":"x,y"}]' | format_csv "a,b"
#   → "a","b"
#     1,"x,y"
format_csv() {
  local cols=$1
  jq -r --arg cols "$cols" '
    ($cols | split(",")) as $headers |
    ([$headers] + [.[] | [$headers[] as $h | (.[$h] // "") | tostring]])
    | .[]
    | @csv
  '
}

# Print a GitHub-flavored Markdown pipe table with header + separator row.
# Pipe characters in values are replaced with the HTML entity &#124; — that
# renders as "|" in every Markdown viewer and avoids the jq-regex escape
# ambiguity around backslash-pipe.
#
#   echo '[{"a":1,"b":"x|y"}]' | format_md "a,b"
#   → | a | b |
#     | --- | --- |
#     | 1 | x&#124;y |
format_md() {
  local cols=$1
  jq -r --arg cols "$cols" '
    ($cols | split(",")) as $headers |
    (
      "| " + ($headers | join(" | ")) + " |",
      "| " + ($headers | map("---") | join(" | ")) + " |"
    ),
    (.[] | "| " + ([$headers[] as $h | ((.[$h] // "") | tostring | gsub("\\|"; "&#124;"))] | join(" | ")) + " |")
  '
}
