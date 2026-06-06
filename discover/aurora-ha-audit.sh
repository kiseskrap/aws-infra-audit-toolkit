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
# shellcheck source=../lib/format.sh
source "${SCRIPT_DIR}/../lib/format.sh"
# shellcheck source=../lib/table.sh
source "${SCRIPT_DIR}/../lib/table.sh"

usage() {
  cat <<EOF
aurora-ha-audit — flag RDS/Aurora resources with HA gaps.

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

CSV / Markdown schema (one row per cluster or standalone instance):
  Identifier,Type,Engine,Version,Class,Members,Azs,Hints
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

# CSV / Markdown: hint-flagged first (same as table) so HA gaps are at the
# top of a spreadsheet open or doc paste.
build_flat_rows() {
  echo "$enriched" \
    | jq "$(sort_by_hints .id)" \
    | jq 'map({
        Identifier: .id,
        Type:       .type,
        Engine:     .engine,
        Version:    .version,
        Class:      .class,
        Members:    .memberCount,
        Azs:        .azs,
        Hints:      (.hints | join(", "))
      })'
}
FLAT_COLS="Identifier,Type,Engine,Version,Class,Members,Azs,Hints"

if [[ "$OUTPUT" == csv ]]; then
  build_flat_rows | format_csv "$FLAT_COLS"
  exit 0
fi
if [[ "$OUTPUT" == md ]]; then
  build_flat_rows | format_md "$FLAT_COLS"
  exit 0
fi

# --- Pretty table ---
id_width=$(table_col_width "$enriched" .id 20 50)
class_width=$(table_col_width "$enriched" .class 12)
sep_width=$(( id_width + class_width + 50 ))
sep=$(table_sep "$sep_width")

printf '%sRDS/Aurora HA audit%s — account %s, region %s\n' "$C_BOLD" "$C_RESET" "$account" "$region"
printf '%s\n' "$sep"
printf "%-${id_width}s %-15s %-15s %-${class_width}s %4s %4s  %s\n" \
  "Identifier" "Type" "Engine" "Class" "Mbr" "AZs" "Hints"
printf '%s\n' "$sep"

# Sort: hint-flagged first, then by id.
echo "$enriched" \
  | jq "$(sort_by_hints .id)" \
  | jq -r '.[] |
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
