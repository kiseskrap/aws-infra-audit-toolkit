#!/usr/bin/env bash
# discover/ecr-bloat-report.sh
#
# Read-only report of ECR repositories ranked by image count, flagging repos
# that have no lifecycle policy configured. Inherited AWS accounts commonly
# accumulate images forever because no one ever set a policy — this surfaces
# the worst offenders so storage cost growth doesn't go silent.
#
# Usage:
#   ./discover/ecr-bloat-report.sh [--json] [--help]
#
# Environment:
#   AWS_PROFILE, AWS_REGION  standard AWS CLI variables
#   NO_COLOR=1               disable colored output

# shellcheck source=../lib/common.sh
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/format.sh
source "${SCRIPT_DIR}/../lib/format.sh"

usage() {
  cat <<EOF
ecr-bloat-report — rank ECR repos by image count and flag missing lifecycle policies.

Usage:
  ${0##*/} [--format <fmt>] [--help]

Options:
  --format FMT  one of: table (default), json, csv, md
  --json        alias for --format json (kept for backward compat)
  -h, --help    show this message

Environment:
  AWS_PROFILE   AWS profile to use (default: \$AWS_PROFILE or 'default')
  AWS_REGION    region to query    (default: configured region)
  NO_COLOR=1    disable ANSI colors

CSV / Markdown schema (one row per repository):
  Repository,Images,Untagged,Lifecycle,Hints
EOF
}

OUTPUT=table
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--format" ]]; then
    OUTPUT=$arg; prev=""
    continue
  fi
  case "$arg" in
    --format) prev=--format ;;
    --json) OUTPUT=json ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done
[[ "$prev" == "--format" ]] && die "--format requires a value (one of: table, json, csv, md)"

case "$OUTPUT" in
  table|json|csv|md) ;;
  *) die "unknown --format '$OUTPUT' (one of: table, json, csv, md)" ;;
esac

require_cmd aws
require_cmd jq
require_aws_credentials

account=$(aws_account_id)
region=$(aws_region)
[[ -n "$region" ]] || die "no region configured (set AWS_REGION or 'aws configure set region')"

repos_raw=$(aws ecr describe-repositories \
  --query 'repositories[].{name:repositoryName,createdAt:createdAt}' \
  --output json)

repo_count=$(echo "$repos_raw" | jq 'length')

if [[ "$repo_count" -eq 0 ]]; then
  if [[ "$OUTPUT" == json ]]; then echo '[]'; else info "no ECR repositories in account $account / $region"; fi
  exit 0
fi

# For each repo, count images and probe its lifecycle policy. Repos are
# independent — a single failure on one repo (throttle, transient API error)
# is reported as "unknown" rather than aborting the whole report.
records_jsonl=""
i=0
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  i=$(( i + 1 ))
  progress "[$i/$repo_count] scanning $name"

  if images_json=$(aws ecr list-images --repository-name "$name" --output json 2>/dev/null); then
    total=$(echo "$images_json"    | jq '[.imageIds[]] | length')
    untagged=$(echo "$images_json" | jq '[.imageIds[] | select(has("imageTag") | not)] | length')
  else
    total=-1
    untagged=-1
  fi

  # get-lifecycle-policy raises LifecyclePolicyNotFoundException when no policy
  # is configured — that's the case we want to surface. Anything else (denied,
  # throttled) is reported as "unknown" so missing IAM doesn't masquerade as
  # an absent policy.
  if lc_err=$(aws ecr get-lifecycle-policy --repository-name "$name" 2>&1 >/dev/null); then
    lifecycle=present
  elif printf '%s' "$lc_err" | grep -q LifecyclePolicyNotFoundException; then
    lifecycle=absent
  else
    lifecycle=unknown
  fi

  rec=$(jq -n \
    --arg name "$name" \
    --argjson total "$total" \
    --argjson untagged "$untagged" \
    --arg lifecycle "$lifecycle" '
    # Pattern hints only fire when a policy is missing (or unknown) AND the
    # repo is large enough for the ratios to be meaningful — small repos
    # produce noisy classifications.
    #   untagged-heavy : >50% untagged → set a "delete untagged after N days" policy
    #   frequent-deploy: ≥100 images, <10% untagged → tag-keep-last-N policy
    #   ephemeral-env  : dev/develop/stage/staging in name → safe to be aggressive
    ($total > 0) as $has_images
    | (if $has_images then ($untagged / $total) else 0 end) as $untagged_ratio
    | {
      name: $name,
      images: $total,
      untagged: $untagged,
      lifecycle: $lifecycle,
      hints: (
        [
          (if $lifecycle == "absent"  then "no-lifecycle-policy"    else empty end),
          (if $lifecycle == "unknown" then "lifecycle-check-failed" else empty end),
          (if $total == -1            then "list-images-failed"     else empty end)
        ]
        + (if ($lifecycle != "present") and ($total >= 10) then
            [
              (if ($untagged_ratio > 0.5) then "untagged-heavy" else empty end),
              (if ($total >= 100 and $untagged_ratio < 0.1) then "frequent-deploy" else empty end),
              (if ($name | test("^(dev|develop|stage|staging)-"))
                  or ($name | test("/(dev|develop|stage|staging)/"))
                then "ephemeral-env" else empty end)
            ]
          else [] end)
      )
    }')
  records_jsonl+="$rec"$'\n'
done < <(echo "$repos_raw" | jq -r '.[].name')

progress_clear

# Sort by image count desc, ties broken by name for stable output.
enriched=$(printf '%s' "$records_jsonl" | jq -s 'sort_by(-.images, .name)')

if [[ "$OUTPUT" == json ]]; then
  echo "$enriched"
  exit 0
fi

# CSV / Markdown: rows in the same order as the table (image count desc).
build_flat_rows() {
  echo "$enriched" | jq '
    map({
      Repository: .name,
      Images:     .images,
      Untagged:   .untagged,
      Lifecycle:  .lifecycle,
      Hints:      (.hints | join(", "))
    })
  '
}
FLAT_COLS="Repository,Images,Untagged,Lifecycle,Hints"

if [[ "$OUTPUT" == csv ]]; then
  build_flat_rows | format_csv "$FLAT_COLS"
  exit 0
fi
if [[ "$OUTPUT" == md ]]; then
  build_flat_rows | format_md "$FLAT_COLS"
  exit 0
fi

# --- Pretty table ---
name_width=$(echo "$enriched" | jq -r 'map(.name | length) | max // 30')
(( name_width < 30 )) && name_width=30
(( name_width > 60 )) && name_width=60
sep_width=$(( name_width + 42 ))
sep=$(printf '%.0s─' $(seq 1 $sep_width))

printf '%sECR bloat report%s — account %s, region %s\n' "$C_BOLD" "$C_RESET" "$account" "$region"
printf '%s\n' "$sep"
printf "%-${name_width}s %7s %9s %-9s  %s\n" "Repository" "Images" "Untagged" "Lifecycle" "Hints"
printf '%s\n' "$sep"

echo "$enriched" \
  | jq -r '.[] |
      [
        .name,
        (if .images == -1 then "?" else (.images|tostring) end),
        (if .untagged == -1 then "?" else (.untagged|tostring) end),
        .lifecycle,
        (.hints | join(", "))
      ] | @tsv' \
  | while IFS=$'\t' read -r name images untagged lifecycle hints; do
      if [[ -n "$hints" ]]; then
        printf "%-${name_width}s %7s %9s %-9s  %s[!] %s%s\n" \
          "$name" "$images" "$untagged" "$lifecycle" \
          "$C_YELLOW" "$hints" "$C_RESET"
      else
        printf "%-${name_width}s %7s %9s %-9s\n" \
          "$name" "$images" "$untagged" "$lifecycle"
      fi
    done

printf '%s\n' "$sep"

# --- Summary ---
summary=$(echo "$enriched" | jq '{
  repos:    length,
  images:   (map(select(.images   >= 0) | .images)   | add // 0),
  untagged: (map(select(.untagged >= 0) | .untagged) | add // 0),
  no_lifecycle:      (map(select(.lifecycle == "absent"))  | length),
  unknown_lifecycle: (map(select(.lifecycle == "unknown")) | length),
  list_failed:       (map(select(.images == -1))           | length),
  untagged_heavy:    (map(select(.hints | index("untagged-heavy")))  | length),
  frequent_deploy:   (map(select(.hints | index("frequent-deploy"))) | length),
  ephemeral_env:     (map(select(.hints | index("ephemeral-env")))   | length)
}')

pluralize() { local n=$1 sing=$2 plur=${3:-${2}s}; (( n == 1 )) && echo "$sing" || echo "$plur"; }

repos=$(echo "$summary"   | jq -r .repos)
images=$(echo "$summary"  | jq -r .images)
untag=$(echo "$summary"   | jq -r .untagged)
no_lc=$(echo "$summary"   | jq -r .no_lifecycle)
unk_lc=$(echo "$summary"  | jq -r .unknown_lifecycle)
listfail=$(echo "$summary"| jq -r .list_failed)

printf 'Summary: %s %s, %s images (%s untagged)\n' \
  "$repos" "$(pluralize "$repos" repository repositories)" \
  "$images" "$untag"

ut_heavy=$(echo "$summary"  | jq -r .untagged_heavy)
freq_dep=$(echo "$summary"  | jq -r .frequent_deploy)
eph_env=$(echo "$summary"   | jq -r .ephemeral_env)

if (( no_lc > 0 || unk_lc > 0 || listfail > 0 )); then
  echo "Hints:"
  (( no_lc > 0 )) && printf '   %s %s without a lifecycle policy (images accumulate indefinitely)\n' \
    "$no_lc" "$(pluralize "$no_lc" repository repositories)"
  (( unk_lc > 0 )) && printf '   %s %s where the lifecycle check failed (permission or throttle)\n' \
    "$unk_lc" "$(pluralize "$unk_lc" repository repositories)"
  (( listfail > 0 )) && printf '   %s %s where image listing failed\n' \
    "$listfail" "$(pluralize "$listfail" repository repositories)"
fi

if (( ut_heavy > 0 || freq_dep > 0 || eph_env > 0 )); then
  echo "Patterns (among unmanaged repos):"
  (( ut_heavy > 0 )) && printf '   %s untagged-heavy   — set "delete untagged after N days" lifecycle\n' "$ut_heavy"
  (( freq_dep > 0 )) && printf '   %s frequent-deploy  — set "keep last N tagged images" lifecycle\n'    "$freq_dep"
  (( eph_env > 0 ))  && printf '   %s ephemeral-env    — non-prod naming; safe to set aggressive retention\n' "$eph_env"
fi
