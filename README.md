# VPNGate Rotator One-Click

Rotate through VPNGate nodes with live IP quality checks and selectable region pools.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/WatIWantMonka/vpngate-rotator-oneclick/refs/heads/main/install.sh -o install.sh
sudo bash install.sh
```

Install flow:
1. Choose target pool mode: `jp` (default) or `custom`.
2. In `custom` mode, the installer fetches currently available VPNGate country pools and asks for target country codes.
3. Optionally set target cities or regions as a comma-separated filter.
4. Enter `IPRegistry`, `IPAPI.is`, and optional `Scamalytics` credentials.
5. Enter the local API token and port.

## Target Pool

- `jp` mode locks the country pool to `JP`.
- `custom` mode uses the selected country code list such as `KR,US,DE`.
- City filtering is optional and matches `city_name` or `region_name` from live geo lookups.
- Candidate checks are always live. No cache is used.

## Quality Rules

A candidate is accepted only when:
- `IPAPI.is` says `is_datacenter`, `is_tor`, `is_vpn`, `is_proxy`, and `is_abuser` are all `false`.
- `IPAPI.is` `company.abuser_score` and `asn.abuser_score` are both `Very Low`.
- `IPRegistry` still looks residential and not proxy/cloud/threat.
- `Scamalytics` is either disabled or returns `Fraud Score <= 10`.

`IP2Location` is used only for geo and ASN display.

## Commands

```bash
vpngate status
vpngate rotate
vpngate ip
vpngate logs
vpngate token
vpngate regions
vpngate settings
vpngate settings region
vpngate settings keys
vpngate settings api
vpngate uninstall
```

## API

The generated API binds to `127.0.0.1` by default.

```bash
curl -H "Authorization: Bearer <YOUR_TOKEN>" http://127.0.0.1:<YOUR_PORT>/status
curl -X POST -H "Authorization: Bearer <YOUR_TOKEN>" http://127.0.0.1:<YOUR_PORT>/rotate
```

## Automatic Behavior

- The timer runs every 5 minutes.
- Automatic rotation happens when the OpenVPN process is down, the current VPNGate node is unreachable, or the 12-hour force interval elapses.
- If a live tunnel blackholes IPv4, the rotator tears it down and retries candidate fetch with the native route.

## Uninstall

```bash
sudo bash install.sh uninstall
# or
vpngate uninstall
```
