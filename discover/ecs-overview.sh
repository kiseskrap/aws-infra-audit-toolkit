#!/usr/bin/env bash
# discover/ecs-overview.sh
#
# Read-only summary of ECS clusters, services, and tasks in the current AWS
# account/region. Produces a human-readable table by default, JSON with --json.
#
# Flags anomalies worth investigating:
#   - clusters with services but zero running tasks
#   - AWS Batch-managed clusters (do not modify directly)
#   - EC2-backed clusters with zero registered instances
#
# Usage:
#   ./discover/ecs-overview.sh [--json] [--help]
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
ecs-overview — summarize ECS clusters in the current account/region.

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

CSV / Markdown schema (one row per cluster):
  ClusterName,Launch,Services,RunningTasks,PendingTasks,Ec2Instances,Hints
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

# Fetch all cluster names. We extract the name from the ARN to keep the
# describe-clusters call portable across regions/accounts.
# Avoid `mapfile` for compatibility with macOS bash 3.2.
cluster_names=()
while IFS= read -r line; do
  [[ -n "$line" ]] && cluster_names+=("${line##*/}")
done < <(aws ecs list-clusters --query 'clusterArns[]' --output text | tr '\t' '\n')

if [[ ${#cluster_names[@]} -eq 0 ]]; then
  if [[ "$OUTPUT" == json ]]; then echo '[]'; else info "no ECS clusters in account $account / $region"; fi
  exit 0
fi

# Describe in batches of 100 (the AWS API limit). Build batches by emitting
# describe-clusters JSON per chunk, then concatenate with jq.
batch_size=100
total=${#cluster_names[@]}
describe_clusters_json=$(
  i=0
  while (( i < total )); do
    end=$(( i + batch_size ))
    (( end > total )) && end=$total
    chunk=()
    for (( j=i; j<end; j++ )); do
      chunk+=("${cluster_names[$j]}")
    done
    aws ecs describe-clusters --clusters "${chunk[@]}" \
      --query 'clusters[].{name:clusterName,status:status,svc:activeServicesCount,task:runningTasksCount,pending:pendingTasksCount,ec2:registeredContainerInstancesCount}' \
      --output json
    i=$end
  done | jq -s 'add'
)

# Determine launch type heuristically. ECS doesn't expose this at the cluster
# level — we infer: registered EC2 instances > 0 implies EC2; AWS Batch
# clusters have a recognizable name prefix; everything else is Fargate.
classify='
  def hints:
    [
      (if (.svc > 0 and .task == 0 and (.name | startswith("AWSBatch-") | not)) then "services-exist-but-zero-tasks" else empty end),
      (if (.name | startswith("AWSBatch-")) then "aws-batch-managed" else empty end),
      (if (.svc > 0 and .ec2 == 0 and (.launch == "EC2")) then "ec2-cluster-with-no-instances" else empty end)
    ];

  def launch:
    if (.name | startswith("AWSBatch-")) then "-"
    elif (.ec2 > 0) then "EC2"
    else "FARGATE"
    end;

  map(. + {launch: launch} | . + {hints: hints})
'

clusters_enriched=$(echo "$describe_clusters_json" | jq "$classify")

if [[ "$OUTPUT" == json ]]; then
  echo "$clusters_enriched"
  exit 0
fi

# Build the flat row shape used by CSV / Markdown consumers. Sort order is
# hint-flagged first (same as the table view) so spreadsheets and doc pastes
# put anomalies at the top.
build_flat_rows() {
  echo "$clusters_enriched" | jq '
    sort_by((.hints | length) * -1, .name)
    | map({
        ClusterName:   .name,
        Launch:        .launch,
        Services:      .svc,
        RunningTasks:  .task,
        PendingTasks:  .pending,
        Ec2Instances:  (if .ec2 == 0 then "" else .ec2 end),
        Hints:         (.hints | join(", "))
      })
  '
}
FLAT_COLS="ClusterName,Launch,Services,RunningTasks,PendingTasks,Ec2Instances,Hints"

if [[ "$OUTPUT" == csv ]]; then
  build_flat_rows | format_csv "$FLAT_COLS"
  exit 0
fi
if [[ "$OUTPUT" == md ]]; then
  build_flat_rows | format_md "$FLAT_COLS"
  exit 0
fi

# --- Pretty table ---
# Determine cluster-name column width from data, with a sane min/max.
name_width=$(echo "$clusters_enriched" | jq -r 'map(.name | length) | max // 30')
(( name_width < 30 )) && name_width=30
(( name_width > 60 )) && name_width=60
sep_width=$(( name_width + 38 ))
sep=$(printf '%.0s─' $(seq 1 $sep_width))

printf '%sECS overview%s — account %s, region %s\n' "$C_BOLD" "$C_RESET" "$account" "$region"
printf '%s\n' "$sep"
printf "%-${name_width}s %-8s %4s %5s %8s %4s  %s\n" "Cluster" "Launch" "Svc" "Task" "Pending" "EC2" "Hints"
printf '%s\n' "$sep"

# Sort: hint-flagged first (so anomalies are at the top), then by name.
echo "$clusters_enriched" \
  | jq -r 'sort_by((.hints | length) * -1, .name) | .[] |
      [
        .name,
        .launch,
        (.svc|tostring),
        (.task|tostring),
        (.pending|tostring),
        (if .ec2 == 0 then "-" else (.ec2|tostring) end),
        (.hints | join(", "))
      ] | @tsv' \
  | while IFS=$'\t' read -r name launch svc task pending ec2 hints; do
      if [[ -n "$hints" ]]; then
        printf "%-${name_width}s %-8s %4s %5s %8s %4s  %s[!] %s%s\n" \
          "$name" "$launch" "$svc" "$task" "$pending" "$ec2" \
          "$C_YELLOW" "$hints" "$C_RESET"
      else
        printf "%-${name_width}s %-8s %4s %5s %8s %4s\n" \
          "$name" "$launch" "$svc" "$task" "$pending" "$ec2"
      fi
    done

printf '%s\n' "$sep"

# --- Summary line ---
summary=$(echo "$clusters_enriched" | jq '{
  clusters: length,
  services: (map(.svc) | add),
  running:  (map(.task) | add),
  pending:  (map(.pending) | add),
  ec2:      (map(.ec2) | add),
  flagged:  (map(select(.hints | length > 0)) | length),
  batch_managed: (map(select(.name | startswith("AWSBatch-"))) | length)
}')

printf 'Summary: %s clusters, %s services, %s running, %s pending, %s EC2 instances\n' \
  "$(echo "$summary" | jq -r .clusters)" \
  "$(echo "$summary" | jq -r .services)" \
  "$(echo "$summary" | jq -r .running)" \
  "$(echo "$summary" | jq -r .pending)" \
  "$(echo "$summary" | jq -r .ec2)"

flagged=$(echo "$summary" | jq -r .flagged)
batch=$(echo "$summary" | jq -r .batch_managed)

pluralize() { local n=$1 sing=$2 plur=${3:-${2}s}; (( n == 1 )) && echo "$sing" || echo "$plur"; }

if [[ "$flagged" -gt 0 || "$batch" -gt 0 ]]; then
  echo "Hints:"
  if [[ "$flagged" -gt 0 ]]; then
    zero_task=$(echo "$clusters_enriched" | jq '[.[] | select(.hints | index("services-exist-but-zero-tasks"))] | length')
    if [[ "$zero_task" -gt 0 ]]; then
      printf '   %s %s with services but zero running tasks (investigate)\n' \
        "$zero_task" "$(pluralize "$zero_task" cluster)"
    fi
  fi
  if [[ "$batch" -gt 0 ]]; then
    printf '   %s AWS Batch-managed %s (do not modify directly)\n' \
      "$batch" "$(pluralize "$batch" cluster)"
  fi
fi
