#!/usr/bin/env bash
# huawei_api.sh - curl wrappers for the Huawei HiLink XML API.
#
# Session model (verified on B818-263 firmware 10.0.5.2(H190SP1C74)):
#   1. GET  /api/webserver/SesTokInfo  -> SesInfo + TokInfo (CSRF token)
#   2. POST /api/user/login            -> <response>OK</response>, Set-Cookie
#      with the real session id, and a '#'-delimited list of ~32 single-use
#      CSRF tokens in the __RequestVerificationToken response header.
#   3. Each authenticated request consumes one token from the queue.
#
# This library assumes a fresh login per run (a run makes <10 requests, well
# under the 32-token budget), so the queue never runs dry mid-run. Tokens
# returned by intermediate responses are captured opportunistically.

CW_BASE=""
CW_SESID=""          # SesInfo from SesTokInfo (used for the login cookie)
CW_CSRF=""           # next token to send as __RequestVerificationToken
CW_TOKEN_QUEUE=()    # queue of single-use tokens
CW_HTTP_CODE=""      # last HTTP status
CW_CURL_EXTRA=()     # e.g. "-k" when --insecure

# Resolved at call time so --host processed after sourcing still applies.
cw_base_url() { printf 'http://%s' "$CW_HOST"; }

# Low-level curl: body -> $CW_BODY_FILE, headers -> $CW_HEADERS_FILE,
# HTTP code -> $CW_HTTP_CODE (callable side-effect, not subshell).
cw_curl() {
  curl -s --max-time "$CW_TIMEOUT" \
    -o "$CW_BODY_FILE" -D "$CW_HEADERS_FILE" \
    -w '%{http_code}' "$@" "${CW_CURL_EXTRA[@]}" > "$CW_TMPDIR/httpcode"
  CW_HTTP_CODE=$(cat "$CW_TMPDIR/httpcode")
}

# Extract a header value from the last response (case-insensitive name).
cw_header_value() {
  local name=$1
  grep -i "^$name:" "$CW_HEADERS_FILE" 2>/dev/null \
    | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

# If the last response carried fresh CSRF tokens, adopt them as the queue.
cw_refresh_token_queue_if_present() {
  local val
  val=$(cw_header_value "__RequestVerificationToken")
  [ -z "$val" ] && val=$(cw_header_value "__RequestVerificationTokenone")
  [ -z "$val" ] && return 0
  CW_TOKEN_QUEUE=()
  for t in $(printf '%s' "$val" | tr '#' ' '); do
    CW_TOKEN_QUEUE=("${CW_TOKEN_QUEUE[@]}" "$t")
  done
  debug "refreshed token queue from response header (${#CW_TOKEN_QUEUE[@]} tokens)"
}

# Fetch a fresh SesInfo/TokInfo pair. Sets CW_SESID and CW_CSRF.
cw_fetch_ses_token() {
  cw_curl "$(cw_base_url)/api/webserver/SesTokInfo"
  [ "$CW_HTTP_CODE" = "200" ] || return 1
  local resp
  resp=$(cat "$CW_BODY_FILE")
  echo "$resp" | grep -q '<error>' && return 1
  CW_SESID=$(printf '%s' "$resp" | xmllint --xpath 'string(/response/SesInfo)' - 2>/dev/null)
  CW_CSRF=$(printf '%s' "$resp" | xmllint --xpath 'string(/response/TokInfo)' - 2>/dev/null)
  CW_TOKEN_QUEUE=()
  [ -n "$CW_SESID" ] && [ -n "$CW_CSRF" ]
}

# Ensure a token is available for the next request.
cw_next_token() {
  if [ "${#CW_TOKEN_QUEUE[@]}" -gt 0 ]; then
    CW_CSRF="${CW_TOKEN_QUEUE[0]}"
    CW_TOKEN_QUEUE=("${CW_TOKEN_QUEUE[@]:1}")
  else
    cw_fetch_ses_token || return 1
  fi
  debug "token in use: ${CW_CSRF:0:6}... (queue ${#CW_TOKEN_QUEUE[@]})"
}

# cw_login <user> <pass> <scheme> where scheme in {sha256,plain}.
#   sha256 -> password_type 4, hashed per cw_login_password
#   plain  -> password_type 3, base64(plaintext) for legacy firmwares
# Returns 0 on success. On failure sets CW_LOGIN_CODE and returns 1.
CW_LOGIN_CODE=""; CW_LOGIN_WAIT=""
cw_login() {
  local user=$1 pw=$2 scheme=$3 body pw_enc pwtype resp
  if ! cw_fetch_ses_token; then
    CW_LOGIN_CODE="CONNECT"
    return 1
  fi
  if [ "$scheme" = "plain" ]; then
    pw_enc=$(cw_login_password_plain "$pw")
    pwtype=3
  else
    pw_enc=$(cw_login_password "$user" "$pw" "$CW_CSRF")
    pwtype=4
  fi
  body="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Username>$user</Username><Password>$pw_enc</Password><password_type>$pwtype</password_type></request>"
  debug "POST /api/user/login (scheme=$scheme, host=$CW_HOST)"
  cw_curl -X POST "$(cw_base_url)/api/user/login" \
    -H "Cookie: SessionID=$CW_SESID" \
    -H "__RequestVerificationToken: $CW_CSRF" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -c "$CW_COOKIE_JAR" \
    -d "$body"
  resp=$(cat "$CW_BODY_FILE")
  if echo "$resp" | grep -q '<response>OK</response>'; then
    CW_LOGIN_CODE="OK"
    cw_refresh_token_queue_if_present
    return 0
  fi
  CW_LOGIN_CODE=$(printf '%s' "$resp" | xmllint --xpath 'string(/error/code)' - 2>/dev/null)
  CW_LOGIN_WAIT=$(printf '%s' "$resp" | xmllint --xpath 'string(/error/waittime)' - 2>/dev/null)
  debug "login failed: code=$CW_LOGIN_CODE waittime=$CW_LOGIN_WAIT body=$(printf '%s' "$resp" | tr -d '\n')"
  return 1
}

# cw_logout — best-effort session teardown; never affects exit code.
cw_logout() {
  cw_next_token 2>/dev/null || return 0
  local body="<?xml version=\"1.0\" encoding=\"UTF-8\"?><request><Logout>1</Logout></request>"
  cw_curl -X POST "$(cw_base_url)/api/user/logout" \
    -H "__RequestVerificationToken: $CW_CSRF" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -b "$CW_COOKIE_JAR" -c "$CW_COOKIE_JAR" \
    -d "$body" >/dev/null 2>&1 || true
  debug "logged out"
}

# cw_api_get <path> — authenticated GET. Prints response body on success.
# Retries once on auth/CSRF-class errors using a fresh token.
cw_api_get() {
  local path=$1 attempt resp code
  for attempt in 1 2; do
    cw_next_token || return 1
    debug "GET $path (attempt $attempt)"
    cw_curl "$(cw_base_url)$path" \
      -H "__RequestVerificationToken: $CW_CSRF" \
      -b "$CW_COOKIE_JAR"
    resp=$(cat "$CW_BODY_FILE")
    if ! echo "$resp" | grep -q '<error>'; then
      cw_refresh_token_queue_if_present
      printf '%s' "$resp"
      return 0
    fi
    code=$(printf '%s' "$resp" | xmllint --xpath 'string(/error/code)' - 2>/dev/null)
    case "$code" in
      125001|125002|100002|100003)
        debug "transient error $code on $path; retrying"
        CW_TOKEN_QUEUE=()
        sleep 0.3 ;;
      *)
        debug "API error $code on $path"
        return 1 ;;
    esac
  done
  return 1
}
