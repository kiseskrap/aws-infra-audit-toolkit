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
  ${0##*/} [--json] [--with-cleanup-commands] [--help]

Options:
  --json                     emit machine-readable JSON instead of a table
  --with-cleanup-commands    print commented-out AWS CLI remediation commands
                             below each section (no auto-execution)
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
for arg in "$@"; do
  case "$arg" in
    --json) OUTPUT=json ;;
    --with-cleanup-commands) WITH_CLEANUP=1 ;;
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
      volumeIds:  BlockDeviceMappings[].Ebs.VolumeId
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
    --argjson pricing   "$PRICING_JSON" '
    # AWS encodes the stop time inside StateTransitionReason as
    # "User initiated (2025-03-15 14:30:00 GMT)". Extract that, fall back to null.
    def parse_stopped_at:
      (capture("\\((?<d>\\d{4}-\\d{2}-\\d{2}) (?<t>\\d{2}:\\d{2}:\\d{2}) GMT\\)") // null)
      | if . then "\(.d)T\(.t)Z" else null end;

    ($volumes | map({(.id): .}) | add // {}) as $by_id |

    $instances
    | map(
        ((.volumeIds // []) | map($by_id[.] // {size: 0, type: "unknown"})) as $vols
        | . + {
            ebsCount: ($vols | length),
            ebsGb:    ($vols | map(.size) | add // 0),
            monthlyCostUsd: (
              [ $vols[] |
                .size * ($pricing.ebs_per_gb_month[.type]
                         // $pricing.ebs_fallback_per_gb_month)
              ] | add // 0
            ),
            stoppedAt: ((.stopReason // "") | parse_stopped_at),
            ageDays: (
              ((.stopReason // "") | parse_stopped_at) as $s
              | if $s then ((now - ($s | fromdateiso8601)) / 86400 | floor) else null end
            )
          }
        | del(.volumeIds)
      )
    | sort_by(-(.monthlyCostUsd))
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

  echo "$result" | jq 'sort_by(-(.monthlyCostUsd // 0))'
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
  | jq --argjson pricing "$PRICING_JSON" '
      map(. + {
        monthlyCostUsd: (.size * ($pricing.ebs_per_gb_month[.type]
                                   // $pricing.ebs_fallback_per_gb_month))
      })
      | sort_by(-(.monthlyCostUsd))
    '
}

check_unused_eips() {
  aws ec2 describe-addresses --output json 2>/dev/null \
  | jq --argjson pricing "$PRICING_JSON" '
    .Addresses
    | map(select(.AssociationId == null))
    | map({
        publicIp: .PublicIp,
        allocationId: .AllocationId,
        domain: .Domain,
        monthlyCostUsd: $pricing.eip_monthly
      })
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
       "\(.ebsCount)v/\(.ebsGb)GB",
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo")
      ] | @tsv' \
    | while IFS=$'\t' read -r id type name stopped age ebs cost; do
        flag=""
        if [[ "$age" =~ ^([0-9]+)d$ ]] && (( BASH_REMATCH[1] > 30 )); then
          flag="${C_YELLOW}[!] >30d${C_RESET}"
        fi
        printf '  %-21s %-12s %-25s %-21s %-5s %-10s %-12s %s\n' \
          "$id" "$type" "$name" "$stopped" "$age" "$ebs" "$cost" "$flag"
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
    echo "$section" | jq -r '.items[] | .name' | while read -r n; do
      printf '  %s\n' "$n"
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
      [.name, .type, .scheme,
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo")
      ] | @tsv' \
    | while IFS=$'\t' read -r n t s cost; do
        printf '  %-40s %-12s %-16s %s\n' "$n" "$t" "$s" "$cost"
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
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo")
      ] | @tsv' \
    | while IFS=$'\t' read -r id type size az created cost; do
        printf '  %-22s %-6s %-9s %-15s %-22s %s\n' "$id" "$type" "$size" "$az" "$created" "$cost"
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
       ((.monthlyCostUsd // 0) | "$\(. * 100 | round / 100)/mo")
      ] | @tsv' \
    | while IFS=$'\t' read -r ip aid dom cost; do
        printf '  %-18s %-30s %-8s %s\n' "$ip" "$aid" "$dom" "$cost"
      done
  fi
  if (( WITH_CLEANUP )) && (( count > 0 )); then
    printf '\n%s# Cleanup commands:%s\n' "$C_DIM" "$C_RESET"
    echo "$section" | jq -r '.items[] |
      "#   aws ec2 release-address --allocation-id \(.allocationId)"'
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

total_waste=$(echo "$report" | jq -r '
  [.checks | to_entries[] | select(.value.status == "ok")
   | .value.items[] | (.monthlyCostUsd // 0)]
  | add // 0
  | . * 100 | round / 100
')
printf '%s  estimated monthly waste: ~$%s%s (ap-northeast-2 pricing, rough)\n' \
  "$C_BOLD" "$total_waste" "$C_RESET"

if (( ! WITH_CLEANUP )); then
  printf '%s  rerun with --with-cleanup-commands to print remediation commands%s\n' \
    "$C_DIM" "$C_RESET"
fi
