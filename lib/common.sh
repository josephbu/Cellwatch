#!/usr/bin/env bash
# common.sh - shared helpers: exit codes, logging, cleanup, portable timestamp.
# Written for bash 3.2+ compatibility (macOS ships 3.2, Linux VMs ship 5.x).

CELLWATCH_VERSION="0.1.0"

# Exit codes (contract with Telegraf's exec input):
#   0  success
#   2  connection / timeout to router
#   3  auth failed (bad credentials or broken token flow)
#   4  unexpected API response shape (firmware changed / partial data)
CW_EXIT_OK=0
CW_EXIT_CONNECT=2
CW_EXIT_AUTH=3
CW_EXIT_SHAPE=4

# Global runtime state, set by main and the lib modules.
CW_HOST="${CW_HOST:-192.168.8.1}"
CW_TIMEOUT="${CW_TIMEOUT:-5}"
CW_DEBUG="${CW_DEBUG:-0}"
CW_TMPDIR=""
CW_COOKIE_JAR=""
CW_HEADERS_FILE=""
CW_BODY_FILE=""

# ---------------------------------------------------------------------------
# Logging: all diagnostics go to stderr; stdout is reserved for data output
# (health table / line protocol), keeping Telegraf streams clean.
# ---------------------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }

debug() {
  [ "$CW_DEBUG" = "1" ] && log "[debug] $*"
  return 0
}

warn() { log "[warn] $*"; }

# die <exit_code> <message...>  -> reason on stderr, nothing on stdout
die() {
  local code=$1
  shift
  log "[error] $*"
  exit "$code"
}

# ---------------------------------------------------------------------------
# Temp dir + trap cleanup. Every run creates a private tmpdir removed on exit.
# ---------------------------------------------------------------------------
cw_setup_tmpdir() {
  CW_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/cellwatch.XXXXXX") || die "$CW_EXIT_CONNECT" "cannot create temp dir"
  CW_COOKIE_JAR="$CW_TMPDIR/cookies"
  CW_HEADERS_FILE="$CW_TMPDIR/headers"
  CW_BODY_FILE="$CW_TMPDIR/body"
}

cw_cleanup() {
  local rc=$?
  if [ -n "$CW_TMPDIR" ] && [ -d "$CW_TMPDIR" ]; then
    rm -rf "$CW_TMPDIR"
  fi
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Nanosecond timestamp for InfluxDB line protocol.
# macOS BSD `date` lacks %N; fall back to second precision scaled to ns.
# ---------------------------------------------------------------------------
cw_timestamp_ns() {
  local t
  t=$(date +%s%N 2>/dev/null)
  case "$t" in
    *[!0-9]*|"") printf '%s000000000' "$(date +%s)" ;;
    *) printf '%s' "$t" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency check.
# ---------------------------------------------------------------------------
cw_check_deps() {
  local missing=""
  for bin in curl base64; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      missing="$missing $bin"
    fi
  done
  if ! command -v xmllint >/dev/null 2>&1; then
    missing="$missing xmllint"
  fi
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    missing="$missing sha256sum/shasum"
  fi
  if [ -n "$missing" ]; then
    die "$CW_EXIT_CONNECT" "missing dependencies:${missing} (need curl, xmllint, base64, sha256sum/shasum)"
  fi
}
