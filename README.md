# CellWatch

Scraper for Huawei HiLink LTE modem/routers (B818, B535, E5xxx), written in
**bash + curl + xmllint**. Polls the router's internal XML API and emits either
InfluxDB line protocol (for Telegraf's `exec` input) or a human-readable
status table.

Runs identically on macOS (ships bash 3.2) and Linux (bash 4/5). The auth flow
and field names were verified live against a B818-263 on firmware
`10.0.5.2(H190SP1C74)` (Optus).

## Requirements

- `bash` 3.2+ (portable subset; no bash-4-only features used)
- `curl`
- `xmllint` (macOS: built-in at `/usr/bin/xmllint`.
  Debian/Ubuntu: `apt install libxml2-utils`. RHEL: `dnf install libxml2`.)
- `base64` and `sha256sum` (fallback to `shasum`/`openssl` if absent)
- `jq` is **not** required — every endpoint on this firmware returns XML

## Setup

```sh
cp cellwatch /usr/local/bin/cellwatch
chmod 755 /usr/local/bin/cellwatch
printf 'your-password\n' | sudo tee /etc/cellwatch/pass >/dev/null
sudo chmod 600 /etc/cellwatch/pass
```

## Configuration

Settings like the router IP and password can live in a config file instead of
CLI flags. The script loads, in order of precedence:

1. CLI flags (highest)
2. config file
3. built-in defaults (lowest)

Config search: `--config <file>`, or a `cellwatch.conf` sitting next to the
script (i.e. the repo's main directory). Copy the committed example and edit:

```sh
cp cellwatch.conf.example cellwatch.conf
chmod 600 cellwatch.conf
```

Example contents:

```sh
HOST="192.168.8.1"
USER="admin"
PASSWORD_FILE="/etc/cellwatch/pass"   # preferred over PASSWORD
#PASSWORD="your-password"
PASSWORD_HASH="auto"                  # auto|sha256|plain
MEASUREMENT_PREFIX="cellwatch"
TIMEOUT="5"
#INSECURE="1"
#NO_LOGOUT="1"
#DEBUG="1"
```

## Usage

```
cellwatch [--host IP] [--user USER] --password-file FILE
           [--health | --telegraf] [options]
```

| Flag | Default | Notes |
|---|---|---|
| `--host` | `192.168.8.1` | Router IP |
| `--user` | `admin` | Login username |
| `--password` | — | Inline password (warns: visible in `ps`) |
| `--password-file` | — | Preferred; `chmod 600` it |
| `--health` | default | Human-readable table to stdout |
| `--telegraf` | — | InfluxDB line protocol to stdout |
| `--password-hash` | `auto` | `auto`, `sha256`, or `plain` (legacy) |
| `--measurement-prefix` | `cellwatch` | Line-protocol measurement prefix |
| `--timeout` | `5` | Per-request curl timeout, seconds |
| `--insecure` | off | Add `-k` for self-signed HTTPS |
| `--no-logout` | off | Skip the logout call at the end of a run |
| `--debug` | off | Raw API detail to **stderr** (never stdout) |
| `--version` / `--help` | — | Version / usage |

Default mode (neither `--health` nor `--telegraf`) is `--health`.

### Examples

```sh
cellwatch --health --password-file /etc/cellwatch/pass
cellwatch --telegraf --host 192.168.8.1 --user admin --password-file /etc/cellwatch/pass
```

Sample `--health`:

```
CellWatch 0.1.0 — B818-263 (192.168.8.1)
  Signal:      RSRP -97 dBm | RSRQ -12.0 dB | SINR -5 dB | RSSI -63 dBm
  Cell:        band 1 | PCI 390 | cell id 25188931 | PLMN 50502 | BW ul/dl 20/20 MHz
  Connection:  LTE via YES OPTUS | connected=1 | roaming=0 | session 11320s
  Traffic:     session up/down 719331/829343 B | total up/down 10726295/50743841 B | up/down 0/29 Bps
  Device:      VNNDW00000000000 | sw 10.0.5.2(H190SP1C74) | hw WL3B818M | webui WEBUI 10.0.5.2(W2SP2C74) | uptime 11338s
```

Sample `--telegraf`:

```
cellwatch_signal,host=192.168.8.1,device_name=B818-263 rsrp=-97,rsrq=-12.0,sinr=-5,rssi=-63,band=1i,pci=390i,cell_id=25188931i,plmn="50502",upload_bandwidth_mhz=20,download_bandwidth_mhz=20 1786693523333400000
cellwatch_connection,host=192.168.8.1,device_name=B818-263 network_type="LTE",operator="YES OPTUS",connection_status="901",connected=1i,roaming=0i,session_duration_s=11328i,upload_bps=58i,download_bps=58i 1786693523333400000
cellwatch_traffic,host=192.168.8.1,device_name=B818-263 session_upload_bytes=719871i,session_download_bytes=829807i,total_upload_bytes=10726835i,total_download_bytes=50744305i,total_connect_time_s=16832i 1786693523333400000
cellwatch_device,host=192.168.8.1,device_name=B818-263 serial="VNNDW00000000000",hardware_version="WL3B818M",software_version="10.0.5.2(H190SP1C74)",uptime=11338i 1786693523333400000
```

## Exit codes (Telegraf contract)

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | Cannot reach router (connect/timeout) |
| `3` | Auth failed (bad credentials, locked account, broken token flow) |
| `4` | Auth OK but no usable data returned (endpoints produced no fields) |

On any nonzero exit: **nothing** is printed to stdout and the reason goes to
stderr. Line-protocol output is buffered and written only when the whole run
succeeds, so a bad poll can never inject garbage into the Telegraf stream.

## Telegraf wiring

See [`cellwatch-telegraf.conf.example`](cellwatch-telegraf.conf.example) at the
repo root. A 30s `[[inputs.exec]]` block emits all four measurements. The mostly-static
`cellwatch_device` measurement rides along for simplicity; it is cheap (one
extra API call).

## Data model

Each `--telegraf` run prints **one InfluxDB line-protocol line per measurement**
on stdout; all lines share the poll's nanosecond timestamp. Telegraf's `exec`
input with `data_format = "influx"` parses every newline-separated line as a
separate point and writes them all in the same poll — so the four lines
of one run become four series (each an InfluxDB point per field set),
not a single merged row.

Every point is tagged with `host` (router IP) and `device_name`.

### `cellwatch_signal` — signal quality (gauge)

| field | type | notes |
|---|---|---|
| `rsrp` | float | dBm (Optus 4G: good > -90, yellow to -105, poor < -105) |
| `rsrq` | float | dB |
| `sinr` | float | dB |
| `rssi` | float | dBm |
| `band` | int | LTE band |
| `pci` | int | physical cell id |
| `cell_id` | int | eNB+cell |
| `plmn` | string | network code, e.g. `"50502"` |
| `upload_bandwidth_mhz` | float | channel width |
| `download_bandwidth_mhz` | float | channel width |

### `cellwatch_connection` — link status (gauge)

| field | type | notes |
|---|---|---|
| `network_type` | string | `LTE` / `3G` / … |
| `operator` | string | e.g. `"YES OPTUS"` |
| `connection_status` | string | `900` no service, `901` 4G, `902` 3G, `903` 2G |
| `connected` | int | `1`/`0` |
| `roaming` | int | `1`/`0` |
| `session_duration_s` | int | seconds since last reconnect — a drop to near 0 means the modem reconnected (failover event) |
| `upload_bps` | int | instantaneous |
| `download_bps` | int | instantaneous |

### `cellwatch_traffic` — cumulative counters

Rate graphs: wrap any of these with Grafana `non_negative_derivative()`;
reset on router reboot is handled automatically.

| field | type | notes |
|---|---|---|
| `session_upload_bytes` | int | since current connection |
| `session_download_bytes` | int | since current connection |
| `total_upload_bytes` | int | since router reset/reboot |
| `total_download_bytes` | int | since router reset/reboot |
| `total_connect_time_s` | int | since router reset/reboot |

### `cellwatch_device` — mostly static (polled every run, cheap)

| field | type |
|---|---|
| `serial` | string |
| `hardware_version` | string |
| `software_version` | string |
| `webui_version` | string |
| `workmode` | string |
| `uptime` | int, seconds |
| `mac` | string |

IMEI, IMSI, ICCID, and IP/SN sensitive identifiers are **never** written to
Influx. WiFi-radio and CA-mode state are omitted: those endpoints return
`100003` (not supported) on this firmware — the unit is a bridged modem with
WiFi disabled.

## Security

- Use `--password-file` (or `PASSWORD_FILE` in config), not `--password`;
  the file should be `chmod 600` and owned by whatever user runs Telegraf.
  A `cellwatch.conf` holding `PASSWORD` must also be `chmod 600`.
- Credentials and the CSRF token are never logged even with `--debug`.
- Every run opens a session, polls, then logs out (unless `--no-logout`) and
  removes its temp cookie jar, so repeated polls don't pile up sessions on the
  router (Huawei firmware caps concurrent sessions).

### Publishing this repo publicly

Before pushing anywhere public, make sure this stays true:

- `cellwatch.conf` (secrets) is gitignored — verify it is **not** staged.
- `dev/` (design docs + screenshots of the real router's web UI, which show
  serial/IMEI) is gitignored.
- Commit `.gitignore` **first**, or `dev/` and `cellwatch.conf` would leak on
  the first push.
- `test/` (parser tests + `test/fixtures/*.xml`) is safe to commit — the
  fixtures are sanitized (fictional serial, IMEI, MACs, DNS). If you ever
  re-capture fixtures from a live device, scrub `SerialNumber`, `Imei`,
  `Imsi`, `Iccid`, `MacAddress*`, `wan_dns_address` before committing.

Double-check with `git status` that no real credentials or identifiers are
staged before you commit.

## Testing

Offline parser tests run without touching the router:

```sh
bash test/run_tests.sh
```

Fixtures in `test/fixtures/` are saved raw responses from the real device
(`device_signal`, `monitoring_status`, `traffic_statistics`,
`device_information`, `current_plmn`, `state_login`).

## How the auth works (for the curious)

Confirmed against this B818 (`password_type=4`):

```
inner = base64( hex(sha256(password)) )                      # lowercase hex, as text
final = base64( hex(sha256( username + inner + token )) )    # token = TokInfo
```

Login returns a `#`-delimited list of ~32 single-use CSRF tokens; each request
consumes one. A fresh login is performed per run, so the queue never runs dry
mid-poll, and `--password-hash auto` falls back to legacy plaintext (`type 3`)
if the modern scheme is rejected.

## License

[AGPL-3.0](LICENSE).