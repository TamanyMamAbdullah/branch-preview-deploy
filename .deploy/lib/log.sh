#!/usr/bin/env bash
# =============================================================================
# log.sh — logging, grouping, masking, and the job summary.
# MACHINERY. Contains nothing project-specific.
# =============================================================================
# shellcheck shell=bash

# Colours only when attached to a terminal. GitHub Actions is not a tty, so in
# CI this collapses to plain text, which is what the log viewer wants anyway.
if [[ -t 1 ]]; then
  _C_RED=$'\033[31m'; _C_YEL=$'\033[33m'; _C_GRN=$'\033[32m'
  _C_DIM=$'\033[2m';  _C_BLD=$'\033[1m';  _C_OFF=$'\033[0m'
else
  _C_RED=''; _C_YEL=''; _C_GRN=''; _C_DIM=''; _C_BLD=''; _C_OFF=''
fi

_in_actions() { [[ -n "${GITHUB_ACTIONS:-}" ]]; }

log()      { printf '%s\n'            "$*" >&2; }
log_info() { printf '%s─%s %s\n'      "$_C_DIM" "$_C_OFF" "$*" >&2; }
log_ok()   { printf '%s✓%s %s\n'      "$_C_GRN" "$_C_OFF" "$*" >&2; }
log_warn() { printf '%s!%s %s\n'      "$_C_YEL" "$_C_OFF" "$*" >&2; }
log_step() { printf '\n%s%s%s\n'      "$_C_BLD" "$*" "$_C_OFF" >&2; }

# log_err — always the last thing a failing script prints. Loud on purpose.
log_err() {
  printf '%s✗ %s%s\n' "$_C_RED" "$*" "$_C_OFF" >&2
  _in_actions && printf '::error::%s\n' "$*" >&2
  return 0
}

# Collapsible sections in the Actions log. No-ops locally.
# Depth is tracked so die() can close them — GitHub collapses groups by default,
# and a fatal message printed inside one is invisible until you expand it. That
# turned two real failures into "exit code 1" with no visible reason.
_GROUP_DEPTH=0
group_start() {
  _GROUP_DEPTH=$((_GROUP_DEPTH + 1))
  _in_actions && printf '::group::%s\n' "$*" >&2 || log_step "$*"
  return 0
}
group_end() {
  (( _GROUP_DEPTH > 0 )) && _GROUP_DEPTH=$((_GROUP_DEPTH - 1))
  _in_actions && printf '::endgroup::\n' >&2
  return 0
}

# die <message> [exit-code] — report and stop.
# Closes every open group first, so the reason is always visible at the top
# level of the log rather than hidden inside a collapsed section.
die() {
  local msg="$1" code="${2:-1}"
  while (( _GROUP_DEPTH > 0 )); do group_end; done
  log_err "$msg"
  exit "$code"
}

# notice <title> <message> — a run-page annotation.
# Unlike an ordinary log line this is pinned to the top of the run summary page,
# so it is readable without expanding a single group. Reserved for the handful
# of things someone opens the run to find — chiefly the URL.
# Must stay one line: Actions annotations do not accept raw newlines.
notice() {
  local title="$1"; shift
  if _in_actions; then printf '::notice title=%s::%s\n' "$title" "$*" >&2
  else log_ok "$*"; fi
  return 0
}

# -----------------------------------------------------------------------------
# mask <value>
# Registers a value so GitHub scrubs it from every subsequent log line. Call
# this the instant a secret enters a variable — before anything can echo it.
# Short values are skipped: masking something like "1" or "true" would replace
# harmless text all over the log and make it unreadable.
# -----------------------------------------------------------------------------
mask() {
  local v="$1"
  [[ -z "$v" || ${#v} -lt 6 ]] && return 0
  _in_actions && printf '::add-mask::%s\n' "$v" >&2
  return 0
}

# -----------------------------------------------------------------------------
# summary <markdown> — append to the GitHub job summary panel.
# Falls back to stderr when running locally so nothing is silently lost.
# -----------------------------------------------------------------------------
summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
  else
    printf '%s\n' "$*" >&2
  fi
}

# emit <name> <value> — publish an output for later workflow steps, and export
# it for later scripts in the same step.
emit() {
  local name="$1" value="$2"
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
  [[ -n "${GITHUB_ENV:-}"    ]] && printf '%s=%s\n' "$name" "$value" >>"$GITHUB_ENV"
  export "$name=$value"
}

# -----------------------------------------------------------------------------
# jq on Windows ends its output lines with \r\n. Every `while read` loop in
# this machinery would then carry an invisible \r in the value — a map lookup
# for "NODE_ENV\r" quietly returns null, a secret named "JWT_SECRET\r" reads
# as unset. jq's own -b flag exists for exactly this; wrapping it ONCE here
# beats remembering it at every call site. A no-op on Linux, so CI is
# unaffected. (Found by a real validate run on Windows, not by code review.)
# -----------------------------------------------------------------------------
# Feature-detected: an older jq without -b (only found on Linux, where the
# problem doesn't exist) is left exactly as it was.
if command jq -b -n '0' >/dev/null 2>&1; then
  jq() { command jq -b "$@"; }
fi

# require_cmd <cmd...> — fail early and clearly on a missing tool, rather than
# halfway through with a confusing "command not found".
require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]})) && die "missing required command(s): ${missing[*]}"
  return 0
}
