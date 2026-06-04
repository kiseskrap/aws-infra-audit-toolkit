#!/usr/bin/env bash
# discover/idle-resources.sh
#
# Surface AWS resources that are likely costing money for no benefit, with
# rough monthly cost estimates per item and an optional `--with-cleanup-commands`
# flag that emits (commented-out) AWS CLI remediation commands. The tool itself
# never mutates anything — the user copy-pastes after review.
#
# Categories (each check runs independently — one permission failure or API
# throttle does not stop the others; the affected section reports the error):
#   - Stopped EC2 instances (EBS volumes remain billable)
#   - ECS clusters with zero services AND zero tasks
#   - Load balancers (ALB/NLB) with no registered targets in any target group
#   - Available (unattached) EBS volumes
#   - Allocated but unassociated Elastic IPs
#
# Usage:
#   ./discover/idle-resources.sh [--json] [--with-cleanup-commands] [--help]

# shellcheck source=../lib/common.sh
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
idle-resources - find AWS resources likely costing money for no benefit.

Usage:
  ${0##*/} [--json] [--with-cleanup-commands] [--with-usage] [--help]

Options:
  --json                     emit machine-readable JSON instead of a table
  --with-cleanup-commands    print commented-out AWS CLI remediation commands
                             below each section (no auto-execution)
  --with-usage               cross-check CloudWatch metrics over the last 30
                             days (LB request count). Sharpens the
                             DELETE/INVESTIGATE/KEEP recommendation but adds
                             ~1 API call per LB. Default off
  -h, --help                 show this message

Environment:
  AWS_PROFILE   AWS profile to use (default: \$AWS_PROFILE or 'default')
  AWS_REGION    region to query    (default: configured region)
  NO_COLOR=1    disable ANSI colors

Cost estimates are hardcoded for ap-northeast-2 (Seoul). Numbers are
intentionally rough — use them to rank what to investigate, not to forecast
a bill.
EOF
}

OUTPUT=table
WITH_CLEANUP=0
WITH_USAGE=0
for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT=json ;;
    --with-cleanup-commands) WITH_CLEANUP=1 ;;
    --with-usage) WITH_USAGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

require_cmd aws
require_cmd jq
require_aws_credentials

account=$(aws_account_id)
region=$(aws_region)
[[ -n "$region" ]] || die "no region configured (set AWS_REGION or 'aws configure set region')"

# 30-day window for CloudWatch lookups. Computed via jq for cross-platform
# compatibility — macOS `date -v-30d` and GNU `date -d "30 days ago"` use
# different flags, so just delegate to jq's strftime.
USAGE_END=$(jq -nr 'now | strftime("%Y-%m-%dT%H:%M:%SZ")')
USAGE_START=$(jq -nr '(now - 30*86400) | strftime("%Y-%m-%dT%H:%M:%SZ")')

# Rough monthly cost estimates, ap-northeast-2 (Seoul), USD. These are
# intentionally simplified — ALB/NLB excludes LCU charges, EBS excludes IOPS
# charges, EC2 itself stops billing while stopped (the cost here is the
# still-attached EBS). The point is to rank, not to forecast.
# TODO: pull from the AWS Pricing API and key by .region when more regions
# are supported.
PRICING_JSON='{
  "region": "ap-northeast-2",
  "ebs_per_gb_month": {
    "gp3": 0.0912,
    "gp2": 0.114,
    "io1": 0.142,
    "io2": 0.142,
    "st1": 0.051,
    "sc1": 0.0285,
    "standard": 0.08
  },
  "ebs_fallback_per_gb_month": 0.10,
  "load_balancer_monthly": {
    "application": 18.40,
    "network":     18.40,
    "gateway":     22.05
  },
  "load_balancer_fallback_monthly": 18.40,
  "eip_monthly": 3.65
}'

# jq helper — case-insensitive canonical tag extraction. AWS responses are
# inconsistent: EC2/EBS/EIP/ELB use {Key,Value}, ECS uses {key,value}. The
# helper tolerates both so each check can call canonical_tags(.tags) uniformly.
# Also exposes age_days(iso) for createdAt → age in days, swallowing parse
# errors so a malformed timestamp doesn't break the whole report.
TAG_HELPER='
def _tag_value(tags; want):
  (tags // [])
  | map({k: ((.Key // .key) // ""), v: ((.Value // .value) // "")})
  | map(select((.k | ascii_downcase) == (want | ascii_downcase)))
  | first | (.v // null);

def canonical_tags(tags):
  {
    owner:     (_tag_value(tags; "owner") // _tag_value(tags; "team") // _tag_value(tags; "owneremail")),
    env:       (_tag_value(tags; "environment") // _tag_value(tags; "env") // _tag_value(tags; "stage")),
    createdAt: (_tag_value(tags; "createdat") // _tag_value(tags; "created") // _tag_value(tags; "creationdate")),
    name:      _tag_value(tags; "name")
  };

def age_days(iso):
  if iso == null then null
  else
    # Normalize AWS timestamp variants jq fromdateiso8601 cannot parse:
    # convert "+00:00" → "Z" first, then strip fractional seconds. Order
    # matters — stripping fractional seconds before the offset fix would
    # leave the "+00:00" suffix intact and still fail to parse.
    (iso | tostring
         | sub("\\+00:00$"; "Z")
         | sub("\\.[0-9]+Z$"; "Z"))
    | (try fromdateiso8601 catch null)
    | if . == null then null else ((now - .) / 86400 | floor) end
  end;

def tag_summary(t; age):
  [
    (if t.owner then "owner=\(t.owner)" else empty end),
    (if t.env   then "env=\(t.env)"     else empty end),
    (if age    then "age=\(age)d"      else empty end)
  ] | if length == 0 then null else join(" ") end;
'

# jq helper — turn an item record into a {confidence, recommendation} pair.
# The inputs are loose: ageDays/monthlyCostUsd/usage30d/tags fields that
# each check fills in to whatever degree it can. usage30d is the key signal —
# null means "we did not measure" (default for LBs without --with-usage),
# 0 means "definitively no traffic" (intrinsic to stopped EC2 / unattached EBS
# / unassociated EIP / empty ECS cluster, and to LBs that did measure 0).
#
# The scoring is intentionally simple and transparent so the field can read
# the algorithm in one screen. It ranks; it does not predict.
CONFIDENCE_HELPER='
def score_record:
  ((.ageDays // 0) | if type == "number" then . else 0 end)        as $age  |
  ((.monthlyCostUsd // 0) | if type == "number" then . else 0 end) as $cost |
  .usage30d                                                          as $u    |
  (
    50
    + (if $u == 0 then 30 else 0 end)
    + (if $age >= 90 then 20 elif $age >= 30 then 10 else 0 end)
    + (if $cost > 0 then 5 else 0 end)
  ) as $raw |
  ($raw | if . > 100 then 100 elif . < 0 then 0 else . end) as $score |
  {
    confidence: $score,
    recommendation: (
      if $score >= 80 then "DELETE"
      elif $score >= 50 then "INVESTIGATE"
      else "KEEP" end
    )
  };
'

# Fetch the 30-day Sum of the relevant CloudWatch metric for one load
# balancer. ALB → RequestCount, NLB → ActiveFlowCount. Prints a JSON number
# (or 0 if no datapoints), or "null" when the LB type is unrecognized or
# the API call fails — null signals "did not measure" to the scorer so it
# avoids giving the "zero traffic" boost on missing data.
fetch_lb_usage30d() {
  local arn=$1
  local dim_value=${arn##*loadbalancer/}
  local ns metric
  case "$dim_value" in
    app/*) ns="AWS/ApplicationELB"; metric="RequestCount"   ;;
    net/*) ns="AWS/NetworkELB";     metric="ActiveFlowCount" ;;
    *)     printf 'null'; return 0 ;;
  esac
  local result
  if ! result=$(aws cloudwatch get-metric-statistics \
        --namespace "$ns" \
        --metric-name "$metric" \
        --start-time "$USAGE_START" \
        --end-time "$USAGE_END" \
        --period 86400 \
        --statistics Sum \
        --dimensions "Name=LoadBalancer,Value=$dim_value" \
        --query 'Datapoints[].Sum' \
        --output json 2>/dev/null); then
    printf 'null'
    return 0
  fi
  printf '%s' "$result" | jq 'add // 0' 2>/dev/null || printf 'null'
}

# -----------------------------------------------------------------------------
# Check functions. Each prints a JSON array on stdout. Exit non-zero on failure
# (stderr is captured by the caller and surfaced in the report).
# -----------------------------------------------------------------------------

check_stopped_ec2() {
  local instances
  instances=$(aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].{
      id:         InstanceId,
      type:       InstanceType,
      name:       Tags[?Key==`Name`] | [0].Value,
      launched:   LaunchTime,
      stopReason: StateTransitionReason,
      volumeIds:  BlockDeviceMappings[].Ebs.VolumeId,
      rawTags:    Tags
    }' --output json) || return 1

  # Stopped EC2 is free; the cost is its still-attached EBS. Fetch sizes/types
  # for every referenced volume in one batched call so we can compute a real
  # monthly estimate per instance.
  local vol_ids
  vol_ids=$(echo "$instances" | jq -r '[.[].volumeIds // [] | .[]] | unique | .[]')

  local volumes='[]'
  if [[ -n "$vol_ids" ]]; then
    local vol_args=()
    while IFS= read -r v; do [[ -n "$v" ]] && vol_args+=("$v"); done <<< "$vol_ids"
    volumes=$(aws ec2 describe-volumes --volume-ids "${vol_args[@]}" \
      --query 'Volumes[].{id:VolumeId,size:Size,type:VolumeType}' \
      --output json) || return 1
  fi

  jq -n \
    --argjson instances "$instances" \
    --argjson volumes   "$volumes" \
    --argjson pricing   "$PRICING_JSON" "
    $TAG_HELPER

    # AWS encodes the stop time inside StateTransitionReason as
    # \"User initiated (2025-03-15 14:30:00 GMT)\". Extract that, fall back to null.
    def parse_stopped_at:
      (capture(\"\\\\((?<d>\\\\d{4}-\\\\d{2}-\\\\d{2}) (?<t>\\\\d{2}:\\\\d{2}:\\\\d{2}) GMT\\\\)\") // null)
      | if . then \"\\(.d)T\\(.t)Z\" else null end;

    (\$volumes | map({(.id): .}) | add // {}) as \$by_id |

    \$instances
    | map(
        ((.volumeIds // []) | map(\$by_id[.] // {size: 0, type: \"unknown\"})) as \$vols
        | . + {
            ebsCount: (\$vols | length),
            ebsGb:    (\$vols | map(.size) | add // 0),
            monthlyCostUsd: (
              [ \$vols[] |
                .size * (\$pricing.ebs_per_gb_month[.type]
                         // \$pricing.ebs_fallback_per_gb_month)
              ] | add // 0
            ),
            stoppedAt: ((.stopReason // \"\") | parse_stopped_at),
            ageDays: (
              ((.stopReason // \"\") | parse_stopped_at) as \$s
              | if \$s then ((now - (\$s | fromdateiso8601)) / 86400 | floor) else null end
            ),
            tags:     canonical_tags(.rawTags),
            usage30d: 0
          }
        | del(.volumeIds, .rawTags)
      )
    | sort_by(-(.monthlyCostUsd))
  "
}

check_empty_ecs_clusters() {
  local arns_raw
  arns_raw=$(aws ecs list-clusters --query 'clusterArns[]' --output text) || return 1

  local names=()
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    local name="${line##*/}"
    # AWS Batch manages its own clusters — never report those as "empty".
    [[ "$name" == AWSBatch-* ]] && continue
    names+=("$name")
  done < <(echo "$arns_raw" | tr '\t' '\n')

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "[]"; return 0
  fi

  # Describe in batches of 100 (AWS API limit).
  local result="[]"
  local total=${#names[@]}
  local i=0
  while (( i < total )); do
    local end=$(( i + 100 ))
    (( end > total )) && end=$total
    local chunk=()
    for (( j=i; j<end; j++ )); do
      chunk+=("${names[$j]}")
    done
    local batch
    batch=$(aws ecs describe-clusters --clusters "${chunk[@]}" --include TAGS \
      --query 'clusters[?activeServicesCount==`0` && runningTasksCount==`0` && pendingTasksCount==`0`].{name: clusterName, rawTags: tags}' \
      --output json) || return 1
    result=$(jq -n --argjson a "$result" --argjson b "$batch" '$a + $b')
    i=$end
  done
  echo "$result" | jq "
    $TAG_HELPER
    map(. + {tags: canonical_tags(.rawTags), usage30d: 0} | del(.rawTags))
  "
}

check_empty_load_balancers() {
  local lbs
  lbs=$(aws elbv2 describe-load-balancers \
    --query 'LoadBalancers[].{name: LoadBalancerName, arn: LoadBalancerArn, type: Type, scheme: Scheme, createdAt: CreatedTime}' \
    --output json) || return 1

  local count
  count=$(echo "$lbs" | jq 'length')
  if (( count == 0 )); then echo "[]"; return 0; fi

  local result="[]"
  local i=0
  while IFS= read -r lb; do
    local arn name
    arn=$(echo "$lb" | jq -r .arn)
    name=$(echo "$lb" | jq -r .name)
    i=$(( i + 1 ))
    progress "[3/5] load balancers: [$i/$count] $name"

    local tg_arns_raw
    tg_arns_raw=$(aws elbv2 describe-target-groups \
      --load-balancer-arn "$arn" \
      --query 'TargetGroups[].TargetGroupArn' --output text 2>/dev/null) || continue

    local enriched
    enriched=$(jq -n --argjson lb "$lb" --argjson pricing "$PRICING_JSON" '
      $lb + {
        monthlyCostUsd: ($pricing.load_balancer_monthly[$lb.type]
                          // $pricing.load_balancer_fallback_monthly)
      }')

    if [[ -z "$tg_arns_raw" ]]; then
      # LB with no target groups at all — definitely idle
      result=$(jq -n --argjson r "$result" --argjson lb "$enriched" '$r + [$lb]')
      continue
    fi

    local total_targets=0
    while IFS= read -r tg_arn; do
      [[ -z "$tg_arn" ]] && continue
      local n
      n=$(aws elbv2 describe-target-health --target-group-arn "$tg_arn" \
        --query 'length(TargetHealthDescriptions)' --output text 2>/dev/null) || continue
      total_targets=$(( total_targets + n ))
    done < <(echo "$tg_arns_raw" | tr '\t' '\n')

    if (( total_targets == 0 )); then
      result=$(jq -n --argjson r "$result" --argjson lb "$enriched" '$r + [$lb]')
    fi
  done < <(echo "$lbs" | jq -c '.[]')

  # ELB v2 doesn't surface tags in describe-load-balancers — fetch them in a
  # single batched call (max 20 ARNs each) and merge in. Only for the empty
  # ones, not every LB, so the extra calls are proportional to actionable
  # findings.
  local arns
  arns=$(echo "$result" | jq -r '.[].arn')
  local tags_map='{}'
  if [[ -n "$arns" ]]; then
    local arn_arr=()
    while IFS= read -r a; do [[ -n "$a" ]] && arn_arr+=("$a"); done <<< "$arns"
    local fetched='[]'
    local total=${#arn_arr[@]}
    local idx=0
    while (( idx < total )); do
      local batch_end=$(( idx + 20 ))
      (( batch_end > total )) && batch_end=$total
      local chunk=()
      for (( j=idx; j<batch_end; j++ )); do chunk+=("${arn_arr[$j]}"); done
      local b
      b=$(aws elbv2 describe-tags --resource-arns "${chunk[@]}" \
        --query 'TagDescriptions[].{arn:ResourceArn,tags:Tags}' --output json 2>/dev/null) || break
      fetched=$(jq -n --argjson a "$fetched" --argjson b "$b" '$a + $b')
      idx=$batch_end
    done
    tags_map=$(echo "$fetched" | jq 'map({(.arn): .tags}) | add // {}')
  fi

  # Optionally pull a 30-day usage signal per LB. This is the only category
  # where the idle state alone (no targets) doesn't fully imply zero usage —
  # callers can still hit the LB directly. The metric tells us if anyone is.
  local usage_map='{}'
  if (( WITH_USAGE )); then
    local usage_pairs="" arns_for_usage
    arns_for_usage=$(echo "$result" | jq -r '.[].arn')
    local i=0
    local lb_count
    lb_count=$(echo "$result" | jq 'length')
    while IFS= read -r arn; do
      [[ -z "$arn" ]] && continue
      i=$(( i + 1 ))
      progress "[3/5] load balancers: [$i/$lb_count] usage lookup"
      local u
      u=$(fetch_lb_usage30d "$arn")
      usage_pairs+="$(jq -nc --arg a "$arn" --argjson u "$u" '{($a): $u}')"$'\n'
    done <<< "$arns_for_usage"
    usage_map=$(printf '%s' "$usage_pairs" | jq -s 'add // {}')
  fi

  echo "$result" | jq --argjson tagsmap "$tags_map" --argjson usagemap "$usage_map" --argjson with_usage "$WITH_USAGE" "
    $TAG_HELPER
    map(. + {
      tags:     canonical_tags(\$tagsmap[.arn] // []),
      usage30d: (if \$with_usage == 1 then (\$usagemap[.arn]) else null end)
    })
    | sort_by(-(.monthlyCostUsd // 0))
  "
}

check_available_ebs() {
  aws ec2 describe-volumes \
    --filters "Name=status,Values=available" \
    --query 'Volumes[].{
      id:      VolumeId,
      size:    Size,
      type:    VolumeType,
      az:      AvailabilityZone,
      created: CreateTime,
      rawTags: Tags
    }' --output json \
  | jq --argjson pricing "$PRICING_JSON" "
      $TAG_HELPER
      map(. + {
        monthlyCostUsd: (.size * (\$pricing.ebs_per_gb_month[.type]
                                   // \$pricing.ebs_fallback_per_gb_month)),
        tags:     canonical_tags(.rawTags),
        ageDays:  age_days(.created),
        usage30d: 0
      } | del(.rawTags))
      | sort_by(-(.monthlyCostUsd))
    "
}

check_unused_eips() {
  aws ec2 describe-addresses --output json 2>/dev/null \
  | jq --argjson pricing "$PRICING_JSON" "
    $TAG_HELPER
    .Addresses
    | map(select(.AssociationId == null))
    | map({
        publicIp:       .PublicIp,
        allocationId:   .AllocationId,
        domain:         .Domain,
        monthlyCostUsd: \$pricing.eip_monthly,
        tags:           canonical_tags(.Tags),
        usage30d:       0
      })
  "
}


# -----------------------------------------------------------------------------
# Runner: isolate each check, capture errors, build a unified JSON document.
# -----------------------------------------------------------------------------

run_check() {
  local fn=$1
  local items err_file
  err_file=$(mktemp)
  if items=$($fn 2>"$err_file"); then
    rm -f "$err_file"
    jq -n --argjson items "$items" '{status: "ok", error: null, items: $items}'
  else
    local err
    err=$(cat "$err_file")
    rm -f "$err_file"
    jq -n --arg err "$err" '{status: "error", error: $err, items: []}'
  fi
}

# Run each check explicitly so we can surface per-check progress on stderr.
# The slowest is empty_load_balancers (N×M API calls), which also reports
# per-LB progress from inside its loop — the outer progress here just shows
# which check is currently active.
progress "[1/5] stopped EC2 instances..."
stopped_ec2=$(run_check check_stopped_ec2)
progress "[2/5] empty ECS clusters..."
empty_ecs=$(run_check check_empty_ecs_clusters)
progress "[3/5] load balancers..."
empty_lbs=$(run_check check_empty_load_balancers)
progress "[4/5] available EBS volumes..."
available_ebs=$(run_check check_available_ebs)
progress "[5/5] unassociated Elastic IPs..."
unused_eips=$(run_check check_unused_eips)
progress_clear

report=$(jq -n \
  --arg account "$account" \
  --arg region  "$region" \
  --argjson stoppedEc2          "$stopped_ec2" \
  --argjson emptyEcsClusters    "$empty_ecs" \
  --argjson emptyLoadBalancers  "$empty_lbs" \
  --argjson availableEbs        "$available_ebs" \
  --argjson unusedEips          "$unused_eips" '
  {
    account: $account,
    region: $region,
    checks: {
      stoppedEc2:         $stoppedEc2,
      emptyEcsClusters:   $emptyEcsClusters,
      emptyLoadBalancers: $emptyLoadBalancers,
      availableEbs:       $availableEbs,
      unusedEips:         $unusedEips
    }
  }')

# Apply the deletion-confidence scorer to every item across every check, in
# one jq pass. Each check has already set usage30d / ageDays / cost / tags
# to whatever degree it could; score_record only consumes what's there.
report=$(echo "$report" | jq "
  $CONFIDENCE_HELPER
  .checks.stoppedEc2.items         |= map(. + score_record) |
  .checks.emptyEcsClusters.items   |= map(. + score_record) |
  .checks.emptyLoadBalancers.items |= map(. + score_record) |
  .checks.availableEbs.items       |= map(. + score_record) |
  .checks.unusedEips.items         |= map(. + score_record)
")

# Cross-section ranking by monthly cost. Per-section ordering is type-locked,
# so the cross-cut view here surfaces where the cleanup budget should actually
# go first — often a $9 EBS or a single $18 ALB beats a dozen $0.10 noise rows.
report=$(echo "$report" | jq '. + {
  topWaste: (
    ([(.checks.stoppedEc2.items         // [])[] | {type: "EC2-stopped",      id: .id,                       name: (.name // "-"),                cost: (.monthlyCostUsd // 0), recommendation: .recommendation}]
   + [(.checks.emptyLoadBalancers.items // [])[] | {type: "LB-empty",         id: (.arn // .name),           name: .name,                          cost: (.monthlyCostUsd // 0), recommendation: .recommendation}]
   + [(.checks.availableEbs.items       // [])[] | {type: "EBS-unattached",   id: .id,                       name: "\(.size)GiB \(.type)",         cost: (.monthlyCostUsd // 0), recommendation: .recommendation}]
   + [(.checks.unusedEips.items         // [])[] | {type: "EIP-unused",       id: .allocationId,             name: .publicIp,                      cost: (.monthlyCostUsd // 0), recommendation: .recommendation}]
    )
    | map(select(.cost > 0))
    | sort_by(-.cost)
    | .[0:10]
  )
}')

if [[ "$OUTPUT" == json ]]; then
  echo "$report"
  exit 0
fi

# -----------------------------------------------------------------------------
# Table renderer
# -----------------------------------------------------------------------------

print_header() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
  printf '%s\n' "$(printf '%.0s─' $(seq 1 ${#1}))"
}

print_check_status() {
  local label=$1
  local check_json=$2
  local status
  status=$(echo "$check_json" | jq -r .status)
  if [[ "$status" != "ok" ]]; then
    local err
    err=$(echo "$check_json" | jq -r .error)
    printf '%s[error]%s %s — %s\n' "$C_RED" "$C_RESET" "$label" "$err" >&2
    return 1
  fi
  return 0
}

# Emit a dim continuation line under a primary table row when there's tag info
# worth showing. Centralizes the format so all five sections stay visually
# consistent. Empty arg → no-op (clean rows stay one line).
print_tag_line() {
  local tagsum=$1
  # Important: do NOT let an empty tagsum bubble out as exit 1 — set -e +
  # pipefail in common.sh would then kill the surrounding `jq | while read`
  # pipeline after the very first row.
  if [[ -n "$tagsum" ]]; then
    printf '%s       └─ %s%s\n' "$C_DIM" "$tagsum" "$C_RESET"
  fi
  return 0
}

# Format a deletion-confidence recommendation with the right color. KEEP is
# dim (avoid drawing the eye), INVESTIGATE is yellow, DELETE is green. Empty
# input prints "-" so column widths stay aligned. Always returns 0 so the
# caller's pipeline survives.
fmt_recommendation() {
  local r=$1
  case "$r" in
    DELETE)      printf '%sDELETE%s'      "$C_GREEN"  "$C_RESET" ;;
    INVESTIGATE) printf '%sINVESTIGATE%s' "$C_YELLOW" "$C_RESET" ;;
    KEEP)        printf '%sKEEP%s'        "$C_DIM"    "$C_RESET" ;;
    *)           printf '-' ;;
  esac
  return 0
}

# Header
printf '%sIdle resources audit%s — account %s, region %s\n' \
  "$C_BOLD" "$C_RESET" "$account" "$region"

# --- Stopped EC2 ---
section=$(echo "$report" | jq '.checks.stoppedEc2')
print_header "Stopped EC2 instances"
if print_check_status "stoppedEc2" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.id, .type, (.name // "-"), (.stoppedAt // "?"),
       (if .ageDays then "\(.ageDays)d" else "?" end),
       "\(.ebsCount)v/\(.ebsGb)GB",
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo"),
       (.recommendation // ""),
       (
         [
           (if .tags.owner then "owner=\(.tags.owner)" else empty end),
           (if .tags.env   then "env=\(.tags.env)"     else empty end)
         ] | join(" ")
       )
      ] | @tsv' \
    | while IFS=$'\t' read -r id type name stopped age ebs cost rec tagsum; do
        rec_fmt=$(fmt_recommendation "$rec")
        printf '  %-21s %-12s %-25s %-21s %-5s %-10s %-12s %s\n' \
          "$id" "$type" "$name" "$stopped" "$age" "$ebs" "$cost" "$rec_fmt"
        print_tag_line "$tagsum"
      done
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands (REVIEW each — terminating destroys data on attached EBS):%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws ec2 terminate-instances --instance-ids \(.id)"'
  fi
fi

# --- Empty ECS clusters ---
section=$(echo "$report" | jq '.checks.emptyEcsClusters')
print_header "Empty ECS clusters (no services, no tasks)"
if print_check_status "emptyEcsClusters" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.name,
       (.recommendation // ""),
       (
         [
           (if .tags.owner then "owner=\(.tags.owner)" else empty end),
           (if .tags.env   then "env=\(.tags.env)"     else empty end)
         ] | join(" ")
       )
      ] | @tsv' \
    | while IFS=$'\t' read -r n rec tagsum; do
        rec_fmt=$(fmt_recommendation "$rec")
        printf '  %-50s %s\n' "$n" "$rec_fmt"
        print_tag_line "$tagsum"
      done
    printf '%s    (empty clusters have no direct cost; flagged as resource sprawl)%s\n' "$C_DIM" "$C_RESET"
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands:%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws ecs delete-cluster --cluster \(.name)"'
  fi
fi

# --- Empty load balancers ---
section=$(echo "$report" | jq '.checks.emptyLoadBalancers')
print_header "Load balancers with no registered targets"
if print_check_status "emptyLoadBalancers" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      # Guard against parse failures: parse first, then only compute age when
      # the result is a real epoch. ELB CreatedTime comes through as
      # "...Z+00:00" with fractional seconds; jq fromdateiso8601 needs the
      # offset converted to Z and the fractional seconds stripped, in that
      # order.
      (((.createdAt // "")
         | sub("\\+00:00$"; "Z")
         | sub("\\.[0-9]+Z$"; "Z")
         | (try fromdateiso8601 catch null))) as $epoch |
      [.name, .type, .scheme,
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo"),
       (.recommendation // ""),
       (.usage30d
         | if . == null then ""
           elif . == 0 then "req30d=0"
           else "req30d=\(.)" end),
       (
         [
           (if .tags.owner then "owner=\(.tags.owner)" else empty end),
           (if .tags.env   then "env=\(.tags.env)"     else empty end),
           (if $epoch then
              (((now - $epoch) / 86400 | floor) as $d
               | if $d > 0 then "age=\($d)d" else empty end)
            else empty end)
         ] | join(" ")
       )
      ] | @tsv' \
    | while IFS=$'\t' read -r n t s cost rec usage tagsum; do
        rec_fmt=$(fmt_recommendation "$rec")
        printf '  %-40s %-12s %-16s %-10s %s %s\n' "$n" "$t" "$s" "$cost" "$rec_fmt" "$usage"
        print_tag_line "$tagsum"
      done
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands:%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws elbv2 delete-load-balancer --load-balancer-arn \(.arn)"'
  fi
fi

# --- Available EBS ---
section=$(echo "$report" | jq '.checks.availableEbs')
print_header "Available (unattached) EBS volumes"
if print_check_status "availableEbs" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  total_gb=$(echo "$section" | jq '[.items[].size] | add // 0')
  total_cost=$(echo "$section" | jq '([.items[].monthlyCostUsd] | add // 0) | . * 100 | round / 100')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.id, .type, "\(.size)GiB", .az, .created,
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo"),
       (.recommendation // ""),
       (
         [
           (if .tags.owner then "owner=\(.tags.owner)" else empty end),
           (if .tags.env   then "env=\(.tags.env)"     else empty end),
           (if .ageDays    then "age=\(.ageDays)d"     else empty end)
         ] | join(" ")
       )
      ] | @tsv' \
    | while IFS=$'\t' read -r id type size az created cost rec tagsum; do
        rec_fmt=$(fmt_recommendation "$rec")
        printf '  %-22s %-6s %-9s %-15s %-22s %-10s %s\n' \
          "$id" "$type" "$size" "$az" "$created" "$cost" "$rec_fmt"
        print_tag_line "$tagsum"
      done
    printf '%s    total: %s GiB across %d volumes, ~$%s/mo%s\n' \
      "$C_DIM" "$total_gb" "$count" "$total_cost" "$C_RESET"
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands (snapshots recommended before delete):%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws ec2 delete-volume --volume-id \(.id)"'
  fi
fi

# --- Unused EIPs ---
section=$(echo "$report" | jq '.checks.unusedEips')
print_header "Unassociated Elastic IPs"
if print_check_status "unusedEips" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.publicIp, .allocationId, .domain,
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo"),
       (.recommendation // ""),
       (
         [
           (if .tags.owner then "owner=\(.tags.owner)" else empty end),
           (if .tags.env   then "env=\(.tags.env)"     else empty end)
         ] | join(" ")
       )
      ] | @tsv' \
    | while IFS=$'\t' read -r ip aid dom cost rec tagsum; do
        rec_fmt=$(fmt_recommendation "$rec")
        printf '  %-18s %-30s %-8s %-10s %s\n' "$ip" "$aid" "$dom" "$cost" "$rec_fmt"
        print_tag_line "$tagsum"
      done
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands:%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws ec2 release-address --allocation-id \(.allocationId)"'
  fi
fi

# --- Top monthly waste (cross-section ranking) ---
top_count=$(echo "$report" | jq '.topWaste | length')
if (( top_count > 0 )); then
  print_header "Top monthly waste (across all categories)"
  rank=0
  echo "$report" | jq -r '.topWaste[] |
    [.type, .id, .name,
     ((.cost // 0) | "$\(. * 100 | round / 100)/mo"),
     (.recommendation // "")
    ] | @tsv' \
  | while IFS=$'\t' read -r type id name cost rec; do
      rank=$(( rank + 1 ))
      rec_fmt=$(fmt_recommendation "$rec")
      printf '  %2d. %-17s %-46.46s %-26.26s %-10s %s\n' \
        "$rank" "$type" "$id" "$name" "$cost" "$rec_fmt"
    done
fi

# --- Summary ---
echo
printf '%sSummary%s\n' "$C_BOLD" "$C_RESET"
echo "$report" | jq -r '
  .checks
  | to_entries[]
  | "  \(.key): \(if .value.status == "ok" then "\(.value.items | length)" else "error (\(.value.error | tostring | .[0:60]))" end)"
'

total_waste=$(echo "$report" | jq -r '
  [.checks | to_entries[] | select(.value.status == "ok")
   | .value.items[] | (.monthlyCostUsd // 0)]
  | add // 0
  | . * 100 | round / 100
')
printf '%s  estimated monthly waste: ~$%s%s (ap-northeast-2 pricing, rough)\n' \
  "$C_BOLD" "$total_waste" "$C_RESET"

# Deletion-confidence breakdown: how many of the flagged items are recommended
# for DELETE / INVESTIGATE / KEEP. Helps the reader see at a glance whether
# this is a "do it now" report or a "needs review" report.
rec_counts=$(echo "$report" | jq -r '
  [.checks | to_entries[] | select(.value.status == "ok")
   | .value.items[] | .recommendation]
  | {
      del:  (map(select(. == "DELETE"))      | length),
      inv:  (map(select(. == "INVESTIGATE")) | length),
      keep: (map(select(. == "KEEP"))        | length)
    }
  | "\(.del) \(.inv) \(.keep)"
')
# common.sh sets IFS to $'\n\t' — space won't split here without the explicit
# override, which would lump all three counts into r_del and break the line.
IFS=' ' read -r r_del r_inv r_keep <<< "$rec_counts"
printf '%s  recommendations: %s%s DELETE%s / %s%s INVESTIGATE%s / %s%s KEEP%s\n' \
  "$C_BOLD" \
  "$C_GREEN" "$r_del" "$C_RESET" \
  "$C_YELLOW" "$r_inv" "$C_RESET" \
  "$C_DIM" "$r_keep" "$C_RESET"

if (( ! WITH_USAGE )); then
  printf '%s  rerun with --with-usage to cross-check load-balancer request counts%s\n' \
    "$C_DIM" "$C_RESET"
fi
if (( ! WITH_CLEANUP )); then
  printf '%s  rerun with --with-cleanup-commands to print remediation commands%s\n' \
    "$C_DIM" "$C_RESET"
fi
