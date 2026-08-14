#!/usr/bin/env bash
# auth.sh - Huawei HiLink login password construction.
# Confirmed against B818-263 firmware 10.0.5.2(H190SP1C74):
#   password_type=4  -> base64( hexlower(sha256( user + base64(hexlower(sha256(pw))) + token ) ) )
#   token            -> TokInfo from /api/webserver/SesTokInfo (NOT the session id)

# Lowercase hex SHA-256 of the argument string. Portable across GNU/BSD/openssl.
cw_sha256hex() {
  local input=$1 out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(printf '%s' "$input" | sha256sum)
    printf '%s' "${out%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$(printf '%s' "$input" | shasum -a 256 | awk '{print $1}')"
  else
    printf '%s' "$(printf '%s' "$input" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')"
  fi
}

# base64 of a string, single line (BSD base64 may wrap; strip newlines).
cw_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# cw_login_password <username> <password> <token>   -> modern (type 4)
cw_login_password() {
  local user=$1 pw=$2 token=$3 inner h
  inner=$(cw_b64 "$(cw_sha256hex "$pw")")
  h=$(cw_sha256hex "${user}${inner}${token}")
  cw_b64 "$h"
}

# cw_login_password_plain <password>  -> legacy plaintext (type 3)
cw_login_password_plain() { cw_b64 "$1"; }
