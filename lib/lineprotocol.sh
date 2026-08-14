#!/usr/bin/env bash
# lineprotocol.sh - InfluxDB line-protocol construction + health output.
#
# Output is buffered in $CW_OUT and printed exactly once by the caller, so a
# nonzero exit never leaks partial/garbage onto stdout (Telegraf contract).

CW_OUT=""
CW_FIELDS=""
CW_TAGS=""        # ",key=value,key2=value2" set once per run
CW_TS=""          # single ns timestamp per run, set by main
CW_EMITTED=0      # set when at least one measurement was successfully built

cw_buf() { CW_OUT="${CW_OUT}${1}\n"; }

# escape tag key/value: , = " space
cw_esc_tag() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/ /\\ /g' -e 's/,/\\,/g' \
    -e 's/=/\\=/g' -e 's/"/\\"/g'
}

# escape incoming string FIELD value: " and \
cw_esc_fstr() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# accumulate one field, only when the value is present
cw_field_float() { [ -n "$2" ] && CW_FIELDS="${CW_FIELDS:+$CW_FIELDS,}$1=$2"; }
cw_field_int()   { [ -n "$2" ] && CW_FIELDS="${CW_FIELDS:+$CW_FIELDS,}$1=$2i"; }
cw_field_str() {
  local esc
  [ -n "$2" ] || return 0
  esc=$(cw_esc_fstr "$2")
  CW_FIELDS="${CW_FIELDS:+$CW_FIELDS,}$1=\"$esc\""
}

# cw_lp_emit <group>  -> "prefix_group<tags> fields <ts>"
cw_lp_emit() {
  CW_EMITTED=1
  cw_buf "${CW_PREFIX}_${1}${CW_TAGS} ${CW_FIELDS} ${CW_TS}"
}

# ---------------------------------------------------------------------------
# measurement builders
# ---------------------------------------------------------------------------
cw_lp_signal() {
  CW_FIELDS=""
  cw_field_float rsrp "$CW_FIELD_RSRP"
  cw_field_float rsrq "$CW_FIELD_RSRQ"
  cw_field_float sinr "$CW_FIELD_SINR"
  cw_field_float rssi "$CW_FIELD_RSSI"
  cw_field_int band "$CW_FIELD_BAND"
  cw_field_int pci "$CW_FIELD_PCI"
  cw_field_int cell_id "$CW_FIELD_CELL_ID"
  cw_field_str plmn "$CW_FIELD_PLMN"
  cw_field_float upload_bandwidth_mhz "$CW_FIELD_UL_BW"
  cw_field_float download_bandwidth_mhz "$CW_FIELD_DL_BW"
  [ -n "$CW_FIELDS" ] && cw_lp_emit signal
}

cw_lp_connection() {
  CW_FIELDS=""
  cw_field_str network_type "$CW_FIELD_NETWORK_TYPE"
  cw_field_str operator "$CW_FIELD_OPERATOR"
  cw_field_str connection_status "$CW_FIELD_CONN_STATUS"
  cw_field_int connected "$CW_FIELD_CONNECTED"
  cw_field_int roaming "$CW_FIELD_ROAMING"
  cw_field_int session_duration_s "$CW_FIELD_SESSION_DURATION_S"
  cw_field_int upload_bps "$CW_FIELD_UP_BPS"
  cw_field_int download_bps "$CW_FIELD_DOWN_BPS"
  [ -n "$CW_FIELDS" ] && cw_lp_emit connection
}

cw_lp_traffic() {
  CW_FIELDS=""
  cw_field_int session_upload_bytes "$CW_FIELD_SESSION_UP"
  cw_field_int session_download_bytes "$CW_FIELD_SESSION_DOWN"
  cw_field_int total_upload_bytes "$CW_FIELD_TOTAL_UP"
  cw_field_int total_download_bytes "$CW_FIELD_TOTAL_DOWN"
  cw_field_int total_connect_time_s "$CW_FIELD_TOTAL_DURATION_S"
  [ -n "$CW_FIELDS" ] && cw_lp_emit traffic
}

cw_lp_device() {
  CW_FIELDS=""
  cw_field_str serial "$CW_FIELD_SERIAL"
  cw_field_str hardware_version "$CW_FIELD_HW_VERSION"
  cw_field_str software_version "$CW_FIELD_SW_VERSION"
  cw_field_str webui_version "$CW_FIELD_WEBUI_VERSION"
  cw_field_str workmode "$CW_FIELD_WORKMODE"
  cw_field_int uptime "$CW_FIELD_UPTIME"
  cw_field_str mac "$CW_FIELD_MAC"
  [ -n "$CW_FIELDS" ] && cw_lp_emit device
}

# ---------------------------------------------------------------------------
# health output (human-readable)
# ---------------------------------------------------------------------------
cw_health() {
  printf 'CellWatch %s — %s (%s)\n' "$CELLWATCH_VERSION" "${CW_FIELD_DEVICE_NAME:-?}" "$CW_HOST"
  printf '  Signal:      RSRP %s dBm | RSRQ %s dB | SINR %s dB | RSSI %s dBm\n' \
    "${CW_FIELD_RSRP:--}" "${CW_FIELD_RSRQ:--}" "${CW_FIELD_SINR:--}" "${CW_FIELD_RSSI:--}"
  printf '  Cell:        band %s | PCI %s | cell id %s | PLMN %s | BW ul/dl %s/%s MHz\n' \
    "${CW_FIELD_BAND:--}" "${CW_FIELD_PCI:--}" "${CW_FIELD_CELL_ID:--}" "${CW_FIELD_PLMN:--}" \
    "${CW_FIELD_UL_BW:--}" "${CW_FIELD_DL_BW:--}"
  printf '  Connection:  %s via %s | connected=%s | roaming=%s | session %ss\n' \
    "${CW_FIELD_NETWORK_TYPE:--}" "${CW_FIELD_OPERATOR:--}" "${CW_FIELD_CONNECTED:--}" \
    "${CW_FIELD_ROAMING:--}" "${CW_FIELD_SESSION_DURATION_S:--}"
  printf '  Traffic:     session up/down %s/%s B | total up/down %s/%s B | up/down %s/%s Bps\n' \
    "${CW_FIELD_SESSION_UP:--}" "${CW_FIELD_SESSION_DOWN:--}" \
    "${CW_FIELD_TOTAL_UP:--}" "${CW_FIELD_TOTAL_DOWN:--}" \
    "${CW_FIELD_UP_BPS:--}" "${CW_FIELD_DOWN_BPS:--}"
  printf '  Device:      %s | sw %s | hw %s | webui %s | uptime %ss\n' \
    "${CW_FIELD_SERIAL:--}" "${CW_FIELD_SW_VERSION:--}" "${CW_FIELD_HW_VERSION:--}" \
    "${CW_FIELD_WEBUI_VERSION:--}" "${CW_FIELD_UPTIME:--}"
}