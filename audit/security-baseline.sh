#!/usr/bin/env bash
# audit/security-baseline.sh
#
# Read-only perimeter audit. Three independent checks:
#   - Security groups with 0.0.0.0/0 inbound on non-(80/443) ports
#   - S3 buckets that are effectively public (Block Public Access off AND
#     a public bucket policy or public ACL grant)
#   - IAM users with access keys older than 180 days
#
# Each check runs in isolation — one IAM permission gap or API error in a
# single check is reported and does not abort the others.
#
# Usage:
#   ./audit/security-baseline.sh [--json] [--help]

# shellcheck source=../lib/common.sh
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
source "${SCRIPT_DIR}/../lib/common.sh"

usage() {
  cat <<EOF
security-baseline - perimeter audit (SGs, S3, IAM key age).

Usage:
  ${0##*/} [--json] [--help]

Options:
  --json        emit machine-readable JSON instead of a table
  -h, --help    show this message

Environment:
  AWS_PROFILE   AWS profile to use (default: \$AWS_PROFILE or 'default')
  AWS_REGION    region for the SG check (S3 and IAM are global)
  NO_COLOR=1    disable ANSI colors

Each check is independent. A permission failure on one check is surfaced
in the report header; the others still run.
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

STALE_DAYS=180

# -----------------------------------------------------------------------------
# Check: security groups with 0.0.0.0/0 inbound (only flag IPv4 here; v6 is a
# fair extension but kept out of scope so the report stays scannable).
# -----------------------------------------------------------------------------
check_permissive_sgs() {
  aws ec2 describe-security-groups --output json \
  | jq --argjson safe '[80, 443]' '
    [
      .SecurityGroups[] as $sg |
      ($sg.IpPermissions // [])[] as $perm |
      ($perm.IpRanges // [])[] |
      select(.CidrIp == "0.0.0.0/0") |
      {
        groupId:   $sg.GroupId,
        groupName: $sg.GroupName,
        vpcId:     ($sg.VpcId // "-"),
        protocol:  ($perm.IpProtocol // "-1"),
        fromPort:  $perm.FromPort,
        toPort:    $perm.ToPort,
        cidr:      .CidrIp,
        severity: (
          if $perm.IpProtocol == "-1" then "critical"
          elif ($perm.FromPort // 0) <= 22   and ($perm.ToPort // 65535) >= 22   then "high"
          elif ($perm.FromPort // 0) <= 3389 and ($perm.ToPort // 65535) >= 3389 then "high"
          elif ($perm.FromPort != null) and ($perm.FromPort == $perm.ToPort)
               and ([$perm.FromPort] | inside($safe)) then null
          else "medium" end
        )
      } |
      select(.severity != null)
    ]
    | sort_by(
        (if .severity == "critical" then 0
         elif .severity == "high"   then 1
         else 2 end),
        .groupId
      )
  '
}

# -----------------------------------------------------------------------------
# Check: public S3 buckets. A bucket is treated as "effectively public" when
# Block Public Access is not fully on AND (the bucket policy is computed
# public OR the ACL grants to the AllUsers / AuthenticatedUsers groups).
# Per-bucket calls are slow — emit progress.
# -----------------------------------------------------------------------------
check_public_s3() {
  local buckets_raw
  buckets_raw=$(aws s3api list-buckets --query 'Buckets[].Name' --output text) || return 1
  local buckets
  buckets=$(printf '%s' "$buckets_raw" | tr '\t' '\n')

  local total
  total=$(printf '%s\n' "$buckets" | grep -c . || true)
  if [[ -z "$buckets" || "$total" -eq 0 ]]; then echo "[]"; return 0; fi

  local result_jsonl="" i=0
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue
    i=$(( i + 1 ))
    progress "[2/3] S3: [$i/$total] $b"

    local bpa_json
    bpa_json=$(aws s3api get-public-access-block --bucket "$b" 2>/dev/null) \
      || bpa_json='{"PublicAccessBlockConfiguration":{}}'
    local bpa_all_on
    bpa_all_on=$(printf '%s' "$bpa_json" | jq -r '
      .PublicAccessBlockConfiguration as $c |
      (($c.BlockPublicAcls // false) and
       ($c.IgnorePublicAcls // false) and
       ($c.BlockPublicPolicy // false) and
       ($c.RestrictPublicBuckets // false))
    ')

    local policy_public
    policy_public=$(aws s3api get-bucket-policy-status --bucket "$b" \
      --query 'PolicyStatus.IsPublic' --output text 2>/dev/null) || policy_public=false

    local acl_public
    acl_public=$(aws s3api get-bucket-acl --bucket "$b" --output json 2>/dev/null \
      | jq -r '
        ([.Grants[]?.Grantee.URI // ""]
         | map(select(. == "http://acs.amazonaws.com/groups/global/AllUsers"
                   or . == "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"))
         | length > 0)
      ' 2>/dev/null) || acl_public=false

    local is_public=false
    if [[ "$bpa_all_on" != "true" ]]; then
      [[ "$policy_public" == "True" || "$policy_public" == "true" ]] && is_public=true
      [[ "$acl_public" == "true" ]] && is_public=true
    fi

    if [[ "$is_public" == "true" ]]; then
      local rec
      rec=$(jq -n \
        --arg name "$b" \
        --arg bpa "$bpa_all_on" \
        --arg policy "$policy_public" \
        --arg acl "$acl_public" '
        {
          bucket: $name,
          blockPublicAccess: ($bpa == "true"),
          policyPublic:      ($policy == "True" or $policy == "true"),
          aclPublic:         ($acl == "true"),
          reasons: [
            (if $bpa != "true" then "BPA off" else empty end),
            (if ($policy == "True" or $policy == "true") then "bucket policy public" else empty end),
            (if $acl == "true" then "ACL grants public" else empty end)
          ]
        }')
      result_jsonl+="$rec"$'\n'
    fi
  done <<< "$buckets"

  printf '%s' "$result_jsonl" | jq -s '.'
}

# -----------------------------------------------------------------------------
# Check: stale IAM access keys (> STALE_DAYS old). Per-user list-access-keys
# call — slow on accounts with many IAM users, so emit progress.
# -----------------------------------------------------------------------------
check_stale_iam_keys() {
  local users_raw
  users_raw=$(aws iam list-users --query 'Users[].UserName' --output text) || return 1
  local users
  users=$(printf '%s' "$users_raw" | tr '\t' '\n')

  local total
  total=$(printf '%s\n' "$users" | grep -c . || true)
  if [[ -z "$users" || "$total" -eq 0 ]]; then echo "[]"; return 0; fi

  local result_jsonl="" i=0
  while IFS= read -r u; do
    [[ -z "$u" ]] && continue
    i=$(( i + 1 ))
    progress "[3/3] IAM: [$i/$total] $u"

    local keys
    keys=$(aws iam list-access-keys --user-name "$u" --output json 2>/dev/null) || continue

    local matched
    matched=$(printf '%s' "$keys" | jq -c --arg user "$u" --argjson stale "$STALE_DAYS" '
      .AccessKeyMetadata[]?
      | {
          user:        $user,
          accessKeyId: .AccessKeyId,
          createDate:  .CreateDate,
          status:      .Status,
          ageDays:     ((now - (.CreateDate | fromdateiso8601)) / 86400 | floor)
        }
      | select(.ageDays > $stale)
    ')
    [[ -n "$matched" ]] && result_jsonl+="$matched"$'\n'
  done <<< "$users"

  printf '%s' "$result_jsonl" | jq -s 'sort_by(-.ageDays)'
}

# -----------------------------------------------------------------------------
# Runner — same isolation pattern as discover/idle-resources.sh
# -----------------------------------------------------------------------------
run_check() {
  local fn=$1 items err_file
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

progress "[1/3] security groups..."
sgs=$(run_check check_permissive_sgs)
progress "[2/3] S3 buckets..."
buckets=$(run_check check_public_s3)
progress "[3/3] IAM access keys..."
keys=$(run_check check_stale_iam_keys)
progress_clear

report=$(jq -n \
  --arg account "$account" \
  --arg region  "$region" \
  --argjson sgs     "$sgs" \
  --argjson s3      "$buckets" \
  --argjson keys    "$keys" \
  --argjson stale   "$STALE_DAYS" '
  {
    account: $account,
    region:  $region,
    config:  { staleDays: $stale },
    checks: {
      permissiveSecurityGroups: $sgs,
      publicS3Buckets:          $s3,
      staleIamKeys:             $keys
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
  local label=$1 check_json=$2 status
  status=$(echo "$check_json" | jq -r .status)
  if [[ "$status" != "ok" ]]; then
    local err
    err=$(echo "$check_json" | jq -r .error)
    printf '%s[error]%s %s — %s\n' "$C_RED" "$C_RESET" "$label" "$err" >&2
    return 1
  fi
  return 0
}

printf '%sSecurity baseline%s — account %s, region %s\n' \
  "$C_BOLD" "$C_RESET" "$account" "$region"

# --- SGs ---
section=$(echo "$report" | jq '.checks.permissiveSecurityGroups')
print_header "Security groups with 0.0.0.0/0 inbound (non-80/443)"
if print_check_status "permissiveSecurityGroups" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.groupId, .groupName, .vpcId, .protocol,
       (if .fromPort == null then "all"
        elif .fromPort == .toPort then (.fromPort | tostring)
        else "\(.fromPort)-\(.toPort)" end),
       .severity, .cidr
      ] | @tsv' \
    | while IFS=$'\t' read -r id name vpc proto port sev cidr; do
        color=""
        case "$sev" in
          critical) color="$C_RED" ;;
          high)     color="$C_YELLOW" ;;
        esac
        printf '  %-22s %-30s %-15s %-8s %-10s %s[!] %s%s %s\n' \
          "$id" "$name" "$vpc" "$proto" "$port" "$color" "$sev" "$C_RESET" "$cidr"
      done
  fi
fi

# --- S3 ---
section=$(echo "$report" | jq '.checks.publicS3Buckets')
print_header "S3 buckets effectively public"
if print_check_status "publicS3Buckets" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.bucket, (.reasons | join(", "))] | @tsv' \
    | while IFS=$'\t' read -r b reasons; do
        printf '  %-50s %s[!] %s%s\n' "$b" "$C_RED" "$reasons" "$C_RESET"
      done
  fi
fi

# --- IAM keys ---
section=$(echo "$report" | jq '.checks.staleIamKeys')
print_header "IAM access keys older than $STALE_DAYS days"
if print_check_status "staleIamKeys" "$section"; then
  count=$(echo "$section" | jq '.items | length')
  if (( count == 0 )); then
    printf '%s(none)%s\n' "$C_DIM" "$C_RESET"
  else
    echo "$section" | jq -r '.items[] |
      [.user, .accessKeyId, .status, "\(.ageDays)d", .createDate
      ] | @tsv' \
    | while IFS=$'\t' read -r u k st age created; do
        printf '  %-30s %-22s %-9s %s[!] %s%s %s\n' \
          "$u" "$k" "$st" "$C_YELLOW" "$age" "$C_RESET" "$created"
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

critical=$(echo "$report" | jq '[.checks.permissiveSecurityGroups.items[] | select(.severity == "critical")] | length')
high=$(echo "$report"     | jq '[.checks.permissiveSecurityGroups.items[] | select(.severity == "high")]     | length')
pub_buckets=$(echo "$report" | jq '.checks.publicS3Buckets.items | length')

if (( critical + high + pub_buckets > 0 )); then
  echo
  printf '%sPriorities:%s\n' "$C_BOLD" "$C_RESET"
  (( pub_buckets > 0 )) && printf '   %s%s public S3 bucket(s) — verify intentional, otherwise enable Block Public Access%s\n' "$C_RED" "$pub_buckets" "$C_RESET"
  (( critical > 0 ))    && printf '   %s%s SG rule(s) opening all protocols to 0.0.0.0/0%s\n' "$C_RED" "$critical" "$C_RESET"
  (( high > 0 ))        && printf '   %s%s SG rule(s) exposing SSH/RDP to 0.0.0.0/0%s\n' "$C_YELLOW" "$high" "$C_RESET"
fi
