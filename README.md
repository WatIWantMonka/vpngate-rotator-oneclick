# VPNGate Rotator One-Click

Deploy a VPS rotator that keeps switching to low-risk Japan egress IPs from VPNGate:
- Prefer the VPNGate CSV API, and automatically fall back to the VPNGate HTML server list when `api/iphone` returns HTML instead of CSV.
- Check every switch in real time with `IP2Location + IPRegistry` (`no_cache`).
- Only use candidates that pass the strict policy: IPRegistry says residential, and neither database flags the IP as proxy, VPN, cloud, Tor, relay, attacker, or threat.
- Re-check current egress quality every hour.
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
2. `API auth token` for `/status` and `/rotate`
3. `API port` (default: `18082`)

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

## Key Behavior

- All IP quality checks are real-time. No cache is used.
- Japan candidates are shuffled before each rotation so the script does not keep picking the same node.
- If `https://www.vpngate.net/api/iphone/` returns HTML or a form page, the script automatically switches to the HTML fallback at `https://www.vpngate.net/en/` and extracts `do_openvpn.aspx` config links.
- The rotator uses a lock file so manual `/rotate` calls and background health checks do not race each other.
- Before each switch, the script clears old OpenVPN processes, stale pid files, and stale rotate locks.
- The generated OpenVPN config adds `data-ciphers` and `data-ciphers-fallback` so OpenVPN 2.6 can still connect to older VPNGate nodes that require `AES-128-CBC`.
- After a successful switch, the script automatically:
  1. Gets the current public IPv4 with `curl -4 ip.sb`
  2. Queries IP2Location for geo and ASN data
  3. Queries IPRegistry for residential and security flags
  4. Prints a PASS / FAIL report

## Uninstall

```bash
sudo bash install.sh uninstall
# or
vpngate uninstall
```
