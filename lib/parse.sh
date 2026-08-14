#!/usr/bin/env bash
# parse.sh - XML field extraction (xmllint) + per-measurement parse functions.
#
# Each parse function reads raw XML from stdin into $CW_XML, then populates
# the CW_FIELD_* globals below, which the output layer (lineprotocol.sh /
# health table) consumes. A field stays empty when the tag is missing, so a
# firmware change degrades to "fewer fields", not a crash.

CW_XML=""

# cw_xml_value <xpath> -> first matching value (entities decoded by xmllint)
cw_xml_value() {
  printf '%s' "$CW_XML" | xmllint --xpath "string($1)" - 2>/dev/null
}

# cw_num <value> -> leading numeric token, optional sign + decimals
cw_num() { printf '%s' "$1" | grep -oE '^-?[0-9]+(\.[0-9]+)?' | head -1; }

cw_float() { cw_num "$1"; }

# integers: strip trailing decimals
cw_int() { cw_num "$1" | sed -E 's/\.[0-9]+$//'; }

# ---------------------------------------------------------------------------
# /api/device/signal
# ---------------------------------------------------------------------------
CW_FIELD_RSRP=""; CW_FIELD_RSRQ=""; CW_FIELD_SINR=""; CW_FIELD_RSSI=""
CW_FIELD_BAND=""; CW_FIELD_PCI=""; CW_FIELD_CELL_ID=""; CW_FIELD_PLMN=""
CW_FIELD_UL_BW=""; CW_FIELD_DL_BW=""

cw_parse_signal() {
  CW_XML=$(cat)
  CW_FIELD_RSRP=$(cw_float "$(cw_xml_value '/response/rsrp')")
  CW_FIELD_RSRQ=$(cw_float "$(cw_xml_value '/response/rsrq')")
  CW_FIELD_SINR=$(cw_float "$(cw_xml_value '/response/sinr')")
  CW_FIELD_RSSI=$(cw_float "$(cw_xml_value '/response/rssi')")
  CW_FIELD_BAND=$(cw_int "$(cw_xml_value '/response/band')")
  CW_FIELD_PCI=$(cw_int "$(cw_xml_value '/response/pci')")
  CW_FIELD_CELL_ID=$(cw_int "$(cw_xml_value '/response/cell_id')")
  CW_FIELD_PLMN=$(cw_xml_value '/response/plmn')
  CW_FIELD_UL_BW=$(cw_float "$(cw_xml_value '/response/ulbandwidth')")
  CW_FIELD_DL_BW=$(cw_float "$(cw_xml_value '/response/dlbandwidth')")
}

# ---------------------------------------------------------------------------
# /api/monitoring/status
# ---------------------------------------------------------------------------
# ConnectionStatus (B818 firmware): 900=no service, 901=4G, 902=3G, 903=2G
cw_conn_status_text() {
  case "$1" in
    900) printf 'no_service' ;;
    901) printf '4g' ;;
    902) printf '3g' ;;
    903) printf '2g' ;;
    *)   printf 'unknown' ;;
  esac
}
# CurrentNetworkType -> text (19 reported as LTE on the B818)
cw_net_type_text() {
  case "$1" in
    0)  printf 'no_service' ;;
    1)  printf 'GSM' ;;
    2)  printf 'GPRS' ;;
    3)  printf 'EDGE' ;;
    4)  printf 'WCDMA' ;;
    5)  printf 'HSDPA' ;;
    6)  printf 'HSUPA' ;;
    7)  printf 'HSPA' ;;
    8)  printf 'TDSCDMA' ;;
    9)  printf 'HSPA+' ;;
    15|19) printf 'LTE' ;;
    16) printf 'WIMAX' ;;
    41) printf '5G' ;;
    *)  printf 'unknown' ;;
  esac
}

CW_FIELD_CONN_STATUS=""; CW_FIELD_CONNECTED=""; CW_FIELD_NETWORK_TYPE=""
CW_FIELD_ROAMING=""; CW_FIELD_SIM_STATUS=""; CW_FIELD_SERVICE_STATUS=""
CW_FIELD_SIGNAL_ICON=""

cw_parse_status() {
  CW_XML=$(cat)
  CW_FIELD_CONN_STATUS=$(cw_xml_value '/response/ConnectionStatus')
  CW_FIELD_SIGNAL_ICON=$(cw_xml_value '/response/SignalIcon')
  CW_FIELD_ROAMING=$(cw_xml_value '/response/RoamingStatus')
  CW_FIELD_SIM_STATUS=$(cw_xml_value '/response/SimStatus')
  CW_FIELD_SERVICE_STATUS=$(cw_xml_value '/response/ServiceStatus')
  CW_FIELD_NETWORK_TYPE=$(cw_net_type_text "$(cw_xml_value '/response/CurrentNetworkType')")
  case "$CW_FIELD_CONN_STATUS" in
    901|902|903) CW_FIELD_CONNECTED=1 ;;
    *)           CW_FIELD_CONNECTED=0 ;;
  esac
  [ "$CW_FIELD_SIM_STATUS" = "1" ] || CW_FIELD_CONNECTED=0
}

# ---------------------------------------------------------------------------
# /api/net/current-plmn
# ---------------------------------------------------------------------------
CW_FIELD_OPERATOR=""

cw_parse_plmn() {
  CW_XML=$(cat)
  CW_FIELD_OPERATOR=$(cw_xml_value '/response/FullName')
}

# ---------------------------------------------------------------------------
# /api/monitoring/traffic-statistics  (cumulative counters: bytes + seconds)
# ---------------------------------------------------------------------------
CW_FIELD_SESSION_DURATION_S=""; CW_FIELD_SESSION_UP=""; CW_FIELD_SESSION_DOWN=""
CW_FIELD_TOTAL_UP=""; CW_FIELD_TOTAL_DOWN=""; CW_FIELD_TOTAL_DURATION_S=""
CW_FIELD_UP_BPS=""; CW_FIELD_DOWN_BPS=""

cw_parse_traffic() {
  CW_XML=$(cat)
  CW_FIELD_SESSION_DURATION_S=$(cw_int "$(cw_xml_value '/response/CurrentConnectTime')")
  CW_FIELD_SESSION_UP=$(cw_int "$(cw_xml_value '/response/CurrentUpload')")
  CW_FIELD_SESSION_DOWN=$(cw_int "$(cw_xml_value '/response/CurrentDownload')")
  CW_FIELD_TOTAL_UP=$(cw_int "$(cw_xml_value '/response/TotalUpload')")
  CW_FIELD_TOTAL_DOWN=$(cw_int "$(cw_xml_value '/response/TotalDownload')")
  CW_FIELD_TOTAL_DURATION_S=$(cw_int "$(cw_xml_value '/response/TotalConnectTime')")
  CW_FIELD_UP_BPS=$(cw_int "$(cw_xml_value '/response/CurrentUploadRate')")
  CW_FIELD_DOWN_BPS=$(cw_int "$(cw_xml_value '/response/CurrentDownloadRate')")
}

# ---------------------------------------------------------------------------
# /api/device/information   (static-ish; IMEI/IMSI/ICCID are intentionally
# never exposed by the output layer)
# ---------------------------------------------------------------------------
CW_FIELD_DEVICE_NAME=""; CW_FIELD_SERIAL=""; CW_FIELD_HW_VERSION=""
CW_FIELD_SW_VERSION=""; CW_FIELD_WEBUI_VERSION=""; CW_FIELD_WORKMODE=""
CW_FIELD_UPTIME=""; CW_FIELD_MAC=""

cw_parse_device() {
  CW_XML=$(cat)
  CW_FIELD_DEVICE_NAME=$(cw_xml_value '/response/DeviceName')
  CW_FIELD_SERIAL=$(cw_xml_value '/response/SerialNumber')
  CW_FIELD_HW_VERSION=$(cw_xml_value '/response/HardwareVersion')
  CW_FIELD_SW_VERSION=$(cw_xml_value '/response/SoftwareVersion')
  CW_FIELD_WEBUI_VERSION=$(cw_xml_value '/response/WebUIVersion')
  CW_FIELD_WORKMODE=$(cw_xml_value '/response/workmode')
  CW_FIELD_UPTIME=$(cw_int "$(cw_xml_value '/response/uptime')")
  CW_FIELD_MAC=$(cw_xml_value '/response/MacAddress1')
}