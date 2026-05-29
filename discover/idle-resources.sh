#!/usr/bin/env bash
# discover/idle-resources.sh
#
# Surface AWS resources that are likely costing money for no benefit.
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
#   ./discover/idle-resources.sh [--json] [--help]

# shellcheck source=../lib/common.sh
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
idle-resources - find AWS resources likely costing money for no benefit.

Usage:
  ${0##*/} [--json] [--help]

Options:
  --json        emit machine-readable JSON instead of a table
  -h, --help    show this message

Environment:
  AWS_PROFILE   AWS profile to use (default: \$AWS_PROFILE or 'default')
  AWS_REGION    region to query    (default: configured region)
  NO_COLOR=1    disable ANSI colors
EOF
}

OUTPUT=table
for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT=json ;;
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

# -----------------------------------------------------------------------------
# Check functions. Each prints a JSON array on stdout. Exit non-zero on failure
# (stderr is captured by the caller and surfaced in the report).
# -----------------------------------------------------------------------------

check_stopped_ec2() {
  aws ec2 describe-instances \
    --filters "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].{
      id:         InstanceId,
      type:       InstanceType,
      name:       Tags[?Key==`Name`] | [0].Value,
      launched:   LaunchTime,
      stopReason: StateTransitionReason,
      ebsCount:   length(BlockDeviceMappings)
    }' --output json \
  | jq '
    # AWS encodes the stop time inside StateTransitionReason as
    # "User initiated (2025-03-15 14:30:00 GMT)". Extract that, fall back to null.
    def parse_stopped_at:
      (capture("\\((?<d>\\d{4}-\\d{2}-\\d{2}) (?<t>\\d{2}:\\d{2}:\\d{2}) GMT\\)") // null)
      | if . then "\(.d)T\(.t)Z" else null end;

    map(. + {
      stoppedAt: ((.stopReason // "") | parse_stopped_at),
      ageDays: (
        ((.stopReason // "") | parse_stopped_at) as $s
        | if $s then ((now - ($s | fromdateiso8601)) / 86400 | floor) else null end
      )
    })
    | sort_by(-(.ageDays // -1))
  '
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
    batch=$(aws ecs describe-clusters --clusters "${chunk[@]}" \
      --query 'clusters[?activeServicesCount==`0` && runningTasksCount==`0` && pendingTasksCount==`0`].{name: clusterName}' \
      --output json) || return 1
    result=$(jq -n --argjson a "$result" --argjson b "$batch" '$a + $b')
    i=$end
  done
  echo "$result"
}

check_empty_load_balancers() {
  local lbs
  lbs=$(aws elbv2 describe-load-balancers \
    --query 'LoadBalancers[].{name: LoadBalancerName, arn: LoadBalancerArn, type: Type, scheme: Scheme}' \
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

    if [[ -z "$tg_arns_raw" ]]; then
      # LB with no target groups at all — definitely idle
      result=$(jq -n --argjson r "$result" --argjson lb "$lb" '$r + [$lb]')
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
      result=$(jq -n --argjson r "$result" --argjson lb "$lb" '$r + [$lb]')
    fi
  done < <(echo "$lbs" | jq -c '.[]')

  echo "$result"
}

check_available_ebs() {
  aws ec2 describe-volumes \
    --filters "Name=status,Values=available" \
    --query 'Volumes[].{
      id:      VolumeId,
      size:    Size,
      type:    VolumeType,
      az:      AvailabilityZone,
      created: CreateTime
    }' --output json \
  | jq 'sort_by(.created)'
}

check_unused_eips() {
  aws ec2 describe-addresses --output json 2>/dev/null \
  | jq '
    .Addresses
    | map(select(.AssociationId == null))
    | map({publicIp: .PublicIp, allocationId: .AllocationId, domain: .Domain})
  '
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
       "\(.ebsCount) vol"
      ] | @tsv' \
    | while IFS=$'\t' read -r id type name stopped age ebs; do
        flag=""
        if [[ "$age" =~ ^([0-9]+)d$ ]] && (( BASH_REMATCH[1] > 30 )); then
          flag="${C_YELLOW}[!] >30d${C_RESET}"
        fi
        printf '  %-21s %-12s %-25s %-21s %-5s %-6s %s\n' \
          "$id" "$type" "$name" "$stopped" "$age" "$ebs" "$flag"
      done
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
    echo "$section" | jq -r '.items[] | .name' | while read -r n; do
      printf '  %s\n' "$n"
    done
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
    echo "$section" | jq -r '.items[] | [.name, .type, .scheme] | @tsv' \
    | while IFS=$'\t' read -r n t s; do
        printf '  %-40s %-12s %s\n' "$n" "$t" "$s"
      done
  fi
fi

# --- Available EBS ---
section=$(echo "$report" | jq '.checks.availableEbs')
print_header "Available (unattached) EBS volumes"
if print_check_status "availableEbs" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  total_gb=$(echo "$section" | jq '[.items[].size] | add // 0')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.id, .type, "\(.size)GiB", .az, .created] | @tsv' \
    | while IFS=$'\t' read -r id type size az created; do
        printf '  %-22s %-6s %-9s %-15s %s\n' "$id" "$type" "$size" "$az" "$created"
      done
    printf '%s    total: %s GiB across %d volumes%s\n' "$C_DIM" "$total_gb" "$count" "$C_RESET"
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
    echo "$section" | jq -r '.items[] | [.publicIp, .allocationId, .domain] | @tsv' \
    | while IFS=$'\t' read -r ip aid dom; do
        printf '  %-18s %-30s %s\n' "$ip" "$aid" "$dom"
      done
  fi
fi

# --- Summary ---
echo
printf '%sSummary%s\n' "$C_BOLD" "$C_RESET"
echo "$report" | jq -r '
  .checks
  | to_entries[]
  | "  \(.key): \(if .value.status == "ok" then "\(.value.items | length)" else "error (\(.value.error | tostring | .[0:60]))" end)"
'
