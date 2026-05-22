#!/usr/bin/env bash
# discover/aurora-ha-audit.sh
#
# Read-only audit of RDS/Aurora high-availability posture. Flags:
#   - Aurora clusters with only one member (no failover target)
#   - Aurora clusters whose members all live in the same Availability Zone
#   - Standalone RDS instances with Multi-AZ disabled
#
# Usage:
#   ./discover/aurora-ha-audit.sh [--json] [--help]
#
# Environment:
#   AWS_PROFILE, AWS_REGION  standard AWS CLI variables
#   NO_COLOR=1               disable colored output

# shellcheck source=../lib/common.sh
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
aurora-ha-audit — flag RDS/Aurora resources with HA gaps.

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

# Pull clusters and instances in a single pass each. RDS accounts rarely have
# enough of either to require pagination handling beyond what the CLI does
# automatically.
clusters_raw=$(aws rds describe-db-clusters \
  --query 'DBClusters[].{id:DBClusterIdentifier,engine:Engine,version:EngineVersion,members:DBClusterMembers[].DBInstanceIdentifier}' \
  --output json)

instances_raw=$(aws rds describe-db-instances \
  --query 'DBInstances[].{id:DBInstanceIdentifier,class:DBInstanceClass,engine:Engine,version:EngineVersion,multiAz:MultiAZ,az:AvailabilityZone,clusterId:DBClusterIdentifier}' \
  --output json)

cluster_count=$(echo "$clusters_raw" | jq 'length')
instance_count=$(echo "$instances_raw" | jq 'length')

if [[ "$cluster_count" -eq 0 && "$instance_count" -eq 0 ]]; then
  if [[ "$OUTPUT" == json ]]; then
    echo '[]'
  else
    info "no RDS resources in account $account / $region"
  fi
  exit 0
fi

# Enrich: for each Aurora cluster, look up its members in the instance list to
# discover AZ distribution and instance class. For standalone RDS instances
# (those with no DBClusterIdentifier), check Multi-AZ.
enriched=$(jq -n \
  --argjson clusters "$clusters_raw" \
  --argjson instances "$instances_raw" '
    # Lookup: instance id -> instance record.
    ($instances | map({(.id): .}) | add // {}) as $by_id |

    # Aurora clusters
    ($clusters | map(
      . + {
        type: "aurora-cluster",
        memberCount: (.members | length),
        azs: ([.members[] | $by_id[.].az] | map(select(. != null)) | unique | length),
        class: ((.members[0] // null) | if . then ($by_id[.].class // "-") else "-" end)
      }
    ) | map(. + {
      hints: [
        (if .memberCount == 1 then "single-instance-cluster" else empty end),
        (if .memberCount > 1 and .azs == 1 then "all-members-same-az" else empty end)
      ]
    })) as $cluster_records |

    # Standalone RDS instances (no parent cluster)
    ($instances | map(select(.clusterId == null)) | map({
      id, engine, version, class,
      type: "rds-instance",
      memberCount: 1,
      azs: (if .multiAz then 2 else 1 end),
      multiAz,
      hints: (if .multiAz then [] else ["multi-az-disabled"] end)
    })) as $standalone_records |

    $cluster_records + $standalone_records
  ')

if [[ "$OUTPUT" == json ]]; then
  echo "$enriched"
  exit 0
fi

# --- Pretty table ---
id_width=$(echo "$enriched" | jq -r 'map(.id | length) | max // 20')
(( id_width < 20 )) && id_width=20
(( id_width > 50 )) && id_width=50

class_width=$(echo "$enriched" | jq -r 'map(.class | length) | max // 12')
(( class_width < 12 )) && class_width=12

sep_width=$(( id_width + class_width + 50 ))
sep=$(printf '%.0s─' $(seq 1 $sep_width))

printf '%sRDS/Aurora HA audit%s — account %s, region %s\n' "$C_BOLD" "$C_RESET" "$account" "$region"
printf '%s\n' "$sep"
printf "%-${id_width}s %-15s %-15s %-${class_width}s %4s %4s  %s\n" \
  "Identifier" "Type" "Engine" "Class" "Mbr" "AZs" "Hints"
printf '%s\n' "$sep"

# Sort: hint-flagged first, then by id.
echo "$enriched" \
  | jq -r 'sort_by((.hints | length) * -1, .id) | .[] |
      [
        .id,
        .type,
        .engine,
        .class,
        (.memberCount | tostring),
        (.azs | tostring),
        (.hints | join(", "))
      ] | @tsv' \
  | while IFS=$'\t' read -r id type engine class members azs hints; do
      if [[ -n "$hints" ]]; then
        printf "%-${id_width}s %-15s %-15s %-${class_width}s %4s %4s  %s[!] %s%s\n" \
          "$id" "$type" "$engine" "$class" "$members" "$azs" \
          "$C_YELLOW" "$hints" "$C_RESET"
      else
        printf "%-${id_width}s %-15s %-15s %-${class_width}s %4s %4s\n" \
          "$id" "$type" "$engine" "$class" "$members" "$azs"
      fi
    done

printf '%s\n' "$sep"

# --- Summary ---
summary=$(echo "$enriched" | jq '{
  total: length,
  clusters: (map(select(.type == "aurora-cluster")) | length),
  instances: (map(select(.type == "rds-instance")) | length),
  flagged: (map(select(.hints | length > 0)) | length),
  single_instance_cluster: (map(select(.hints | index("single-instance-cluster"))) | length),
  same_az_cluster:         (map(select(.hints | index("all-members-same-az"))) | length),
  multi_az_disabled:       (map(select(.hints | index("multi-az-disabled"))) | length)
}')

pluralize() { local n=$1 sing=$2 plur=${3:-${2}s}; (( n == 1 )) && echo "$sing" || echo "$plur"; }

total=$(echo "$summary" | jq -r .total)
clusters=$(echo "$summary" | jq -r .clusters)
instances=$(echo "$summary" | jq -r .instances)
flagged=$(echo "$summary" | jq -r .flagged)

printf 'Summary: %s %s (%s Aurora %s, %s standalone %s), %s with HA gaps\n' \
  "$total" "$(pluralize "$total" resource)" \
  "$clusters" "$(pluralize "$clusters" cluster)" \
  "$instances" "$(pluralize "$instances" instance)" \
  "$flagged"

if [[ "$flagged" -gt 0 ]]; then
  echo "Hints:"
  sic=$(echo "$summary" | jq -r .single_instance_cluster)
  saz=$(echo "$summary" | jq -r .same_az_cluster)
  mad=$(echo "$summary" | jq -r .multi_az_disabled)
  (( sic > 0 )) && printf '   %s single-instance Aurora %s (no failover target)\n' \
    "$sic" "$(pluralize "$sic" cluster)"
  (( saz > 0 )) && printf '   %s Aurora %s with all members in the same AZ\n' \
    "$saz" "$(pluralize "$saz" cluster)"
  (( mad > 0 )) && printf '   %s standalone RDS %s without Multi-AZ\n' \
    "$mad" "$(pluralize "$mad" instance)"
fi
