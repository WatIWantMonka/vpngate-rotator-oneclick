# VPNGate Rotator One-Click

Deploy a VPS rotator that keeps switching to low-risk Japan egress IPs from VPNGate:
- Prefer the VPNGate CSV API, and automatically fall back to the VPNGate HTML server list when `api/iphone` returns HTML instead of CSV.
- Check every candidate in real time with `IPAPI.is + IPRegistry` as the live pre-screen.
- Only after the pre-screen passes, call `Scamalytics` when it is configured.
- Use `IP2Location` for geo, ASN, city, and basic IP information only. It is not used for quality decisions.
- Reject a candidate immediately when any of these `IPAPI.is` flags is bad: `is_tor`, `is_vpn`, `is_proxy`, `is_abuser`, or `is_datacenter`.
- Require both `IPAPI.is` abuser scores to be `Very Low`: `company.abuser_score` and `asn.abuser_score`.
- Use `IPRegistry` together with `IPAPI.is is_datacenter` to judge whether the IP looks residential.
- If Scamalytics is configured, reject a candidate immediately when `Fraud Score > 10`.
- Force a rotation every 12 hours.
- Expose a self-service API for status and forced rotation.
- Install the `vpngate` helper command.
- Support uninstall.
- Support common Linux package managers (`apt`, `apk`, `dnf`, `yum`, `pacman`, `zypper`).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/WatIWantMonka/vpngate-rotator-oneclick/refs/heads/main/install.sh -o install.sh
sudo bash install.sh
```

The installer will ask for:
1. `IPRegistry API Key`
2. `IPAPI.is user key`
3. `Scamalytics node` (`api11` or `api12`, optional)
4. `Scamalytics username` (required only when a Scamalytics node is set)
5. `Scamalytics key` (required only when a Scamalytics node is set)
6. `API auth token` for `/status` and `/rotate`
7. `API port` (default: `18082`)

If you do not have Scamalytics credentials, leave the Scamalytics node empty and the script will use only the live `IPAPI.is + IPRegistry` pre-screen.

## Helper Commands

```bash
vpngate status
vpngate rotate
vpngate ip
vpngate logs
vpngate token
vpngate uninstall
```

## API

- `GET /status`: return current rotator state. Requires Bearer Token.
- `POST /rotate`: force a new rotation every time. Requires Bearer Token.

Examples:

```bash
curl -H "Authorization: Bearer <YOUR_TOKEN>" http://<VPS_IP>:<YOUR_PORT>/status
curl -X POST -H "Authorization: Bearer <YOUR_TOKEN>" http://<VPS_IP>:<YOUR_PORT>/rotate
```

## Quality Pipeline

The decision path is now:
1. Fetch Japan VPNGate candidates.
2. Query `IPAPI.is` live.
3. Query `IPRegistry` live.
4. Pass the pre-screen only when both sources still look safe and residential.
5. Only then call `Scamalytics` when configured.
6. Reject immediately if `Fraud Score > 10`.
7. Use `IP2Location` only for geo and IP information in reports.
8. Connect only when the candidate still passes the full policy.

## Automatic Behavior

- All IP quality checks are live API calls. No cache is used anywhere.
- The timer still runs every 5 minutes, but the script no longer performs periodic quality re-checks on the current egress IP.
- Automatic switching now happens when:
  - the OpenVPN process is down
  - the current VPNGate server IP is unreachable
  - the forced rotation interval elapses (`FORCE_SWITCH_INTERVAL_SEC=43200`, which is 12 hours)
- Japan candidates are shuffled before each rotation so the script does not keep picking the same node.
- If `https://www.vpngate.net/api/iphone/` returns HTML or a form page, the script automatically switches to the HTML fallback at `https://www.vpngate.net/en/` and extracts `do_openvpn.aspx` config links.
- The rotator uses a lock file so manual `/rotate` calls and background health checks do not race each other.
- Before each switch, the script clears old OpenVPN processes, stale pid files, and stale rotate locks.
- The generated OpenVPN config adds `data-ciphers` and `data-ciphers-fallback` so OpenVPN 2.6 can still connect to older VPNGate nodes that require `AES-128-CBC`.

## Report Output

The report shows:
- IP2Location geo and ASN information
- `IPAPI.is` risk flags and both abuser score levels
- `IPRegistry` flags and residential decision
- `Scamalytics` score and block result when Scamalytics is enabled

## Uninstall

```bash
sudo bash install.sh uninstall
# or
vpngate uninstall
```
