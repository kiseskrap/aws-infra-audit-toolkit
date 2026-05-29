#!/usr/bin/env bash
# lib/common.sh — shared helpers. Source this from any tool in the toolkit.
#
# Provides:
#   - safe defaults (set -euo pipefail, IFS)
#   - color helpers that auto-disable when stdout is not a TTY or NO_COLOR is set
#   - require_cmd, require_aws_credentials
#   - die, warn, info
#
# This file is intentionally dependency-free (only bash builtins + coreutils).

set -euo pipefail
IFS=$'\n\t'

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  readonly C_RESET=$'\033[0m'
  readonly C_BOLD=$'\033[1m'
  readonly C_DIM=$'\033[2m'
  readonly C_RED=$'\033[31m'
  readonly C_YELLOW=$'\033[33m'
  readonly C_GREEN=$'\033[32m'
  readonly C_CYAN=$'\033[36m'
else
  readonly C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_YELLOW="" C_GREEN="" C_CYAN=""
fi

info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Snapshot the original stderr to FD 9 at source time. This is what progress()
# writes to, so per-resource updates survive subshells that later redirect
# stderr (e.g. `items=$(check 2>"$errfile")` used by idle-resources.sh to
# capture per-check failures). If stderr was already redirected before we
# sourced this file (NO TTY at invocation), -t 9 will be false and progress()
# becomes a no-op — which is the behavior we want for JSON pipelines and CI.
exec 9>&2

# progress: write an in-place status update to the original stderr, but only
# when that stream is a TTY. CI runs, JSON pipelines, and `2>file` redirects
# stay quiet — only an interactive user sees the spinner.
#   progress "[3/47] scanning my-repo"
progress() {
  [[ -t 9 ]] || return 0
  printf '\r\033[K%s%s%s' "${C_DIM}" "$*" "${C_RESET}" >&9
}

# progress_clear: erase the last progress line so the report below starts on a
# clean line. Safe to call even when nothing was printed.
progress_clear() {
  [[ -t 9 ]] || return 0
  printf '\r\033[K' >&9
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
}

require_aws_credentials() {
  require_cmd aws
  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    die "AWS credentials are not configured or invalid. Set AWS_PROFILE or run 'aws configure'."
  fi
}

aws_account_id() {
  aws sts get-caller-identity --query Account --output text
}

aws_region() {
  printf '%s' "${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null || true)}}"
}
