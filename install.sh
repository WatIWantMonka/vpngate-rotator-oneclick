#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash install.sh"
  exit 1
fi

read -r -p "Enter IPRegistry API Key: " IPREGISTRY_API_KEY
if [[ -z "${IPREGISTRY_API_KEY}" ]]; then
  echo "IPRegistry API Key is required."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y openvpn curl python3 iputils-ping ca-certificates

install -d -m 755 /usr/local/sbin
install -d -m 755 /etc/openvpn
install -d -m 755 /var/lib/vpngate-rotator

cat >/usr/local/sbin/vpngate-jp-rotator.py <<'PYEOF'
#!/usr/bin/env python3
import base64
import csv
import io
import json
import os
import re
import subprocess
import time
import urllib.parse
import urllib.request
from typing import Dict, List, Optional

CONFIG_PATH = '/etc/vpngate-rotator.conf'
STATE_PATH = '/var/lib/vpngate-rotator/state.json'
OPENVPN_CONFIG_PATH = '/etc/openvpn/vpngate-current.ovpn'
OPENVPN_PID_PATH = '/run/vpngate-openvpn.pid'
OPENVPN_LOG_PATH = '/var/log/vpngate-openvpn.log'
VPNGATE_API = 'https://www.vpngate.net/api/iphone/'


def log(msg: str) -> None:
    print(f'[vpngate-rotator] {msg}', flush=True)


def load_config(path: str) -> Dict[str, str]:
    cfg: Dict[str, str] = {}
    if not os.path.exists(path):
        return cfg
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg


def cfg_bool(cfg: Dict[str, str], key: str, default: bool) -> bool:
    val = cfg.get(key)
    if val is None:
        return default
    return val.lower() in ('1', 'true', 'yes', 'on')


def cfg_int(cfg: Dict[str, str], key: str, default: int) -> int:
    try:
        return int(cfg.get(key, str(default)))
    except ValueError:
        return default


def read_state() -> Dict[str, object]:
    if not os.path.exists(STATE_PATH):
        return {}
    try:
        with open(STATE_PATH, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return {}


def write_state(state: Dict[str, object]) -> None:
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    with open(STATE_PATH, 'w', encoding='utf-8') as f:
        json.dump(state, f)


def http_get(url: str, timeout: int = 15) -> str:
    req = urllib.request.Request(url, headers={'User-Agent': 'vpngate-rotator/1.0'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', errors='ignore')


def run(cmd: List[str], timeout: int = 30) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)


def get_public_ip() -> Optional[str]:
    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com'):
        try:
            ip = http_get(url, timeout=8).strip()
            if re.match(r'^\d+\.\d+\.\d+\.\d+$', ip):
                return ip
        except Exception:
            pass
    return None


def fetch_vpngate_candidates(limit: int) -> List[Dict[str, str]]:
    raw = http_get(VPNGATE_API, timeout=20)
    lines = []
    for ln in raw.splitlines():
        if not ln or ln.startswith('*'):
            continue
        if ln.startswith('#HostName'):
            lines.append(ln[1:])
            continue
        if ln.startswith('#'):
            continue
        lines.append(ln)
    if not lines:
        return []

    rows = list(csv.DictReader(io.StringIO(chr(10).join(lines))))
    out: List[Dict[str, str]] = []
    for r in rows:
        if (r.get('CountryShort') or '').upper() != 'JP':
            continue
        ip = (r.get('IP') or '').strip()
        ovpn_b64 = (r.get('OpenVPN_ConfigData_Base64') or '').strip()
        if not ip or not ovpn_b64:
            continue
        if not re.match(r'^\d+\.\d+\.\d+\.\d+$', ip):
            continue
        out.append({
            'ip': ip,
            'hostname': (r.get('HostName') or '').strip(),
            'ovpn_b64': ovpn_b64,
        })
    return out[:limit]


def ip_quality(ip: str, cfg: Dict[str, str], state: Dict[str, object]) -> Dict[str, object]:
    cache_ttl = cfg_int(cfg, 'QUALITY_CACHE_TTL_SEC', 86400)
    cache = state.setdefault('quality_cache', {})
    if isinstance(cache, dict):
        rec = cache.get(ip)
        if isinstance(rec, dict):
            ts = int(rec.get('checked_at', 0) or 0)
            if int(time.time()) - ts < cache_ttl:
                return rec
    else:
        state['quality_cache'] = {}
        cache = state['quality_cache']

    i2l_url = 'https://api.ip2location.io/?ip=' + urllib.parse.quote(ip, safe='')
    i2l_data = json.loads(http_get(i2l_url, timeout=12))
    i2l_proxy = bool(i2l_data.get('is_proxy', False))

    ipr_key = cfg.get('IPREGISTRY_API_KEY', '').strip()
    if not ipr_key:
        raise RuntimeError('IPREGISTRY_API_KEY is empty')

    ipr_url = (
        'https://api.ipregistry.co/'
        + urllib.parse.quote(ip, safe='')
        + '?key='
        + urllib.parse.quote(ipr_key, safe='')
    )
    ipr_data = json.loads(http_get(ipr_url, timeout=12))
    sec = ipr_data.get('security', {}) if isinstance(ipr_data, dict) else {}

    ipr_proxy = bool(
        sec.get('is_proxy', False)
        or sec.get('is_vpn', False)
        or sec.get('is_tor', False)
        or sec.get('is_relay', False)
        or sec.get('is_anonymous', False)
    )
    ipr_threat = bool(sec.get('is_attacker', False) or sec.get('is_abuser', False) or sec.get('is_threat', False))
    ipr_cloud = bool(sec.get('is_cloud_provider', False))

    proxy_like = i2l_proxy or ipr_proxy or ipr_cloud
    if ipr_threat:
        fraud_score = 100
    elif proxy_like:
        fraud_score = 90
    else:
        fraud_score = 0

    result = {
        'proxy_like': proxy_like,
        'fraud_score': fraud_score,
        'source': 'ip2location+ipregistry',
        'i2l_proxy': i2l_proxy,
        'ipr_proxy': ipr_proxy,
        'ipr_cloud': ipr_cloud,
        'ipr_threat': ipr_threat,
        'checked_at': int(time.time()),
    }
    cache[ip] = result
    write_state(state)
    return result


def passes_quality(ip: str, cfg: Dict[str, str], state: Dict[str, object]) -> bool:
    q = ip_quality(ip, cfg, state)
    threshold = cfg_int(cfg, 'RISK_SCORE_THRESHOLD', 75)
    require_both = cfg_bool(cfg, 'REJECT_ONLY_WHEN_PROXY_AND_HIGH_RISK', True)
    if require_both:
        reject = bool(q['proxy_like']) and int(q['fraud_score']) >= threshold
    else:
        reject = bool(q['proxy_like']) or int(q['fraud_score']) >= threshold
    log(
        f'quality ip={ip} source={q.get("source")} i2l_proxy={q.get("i2l_proxy")} '
        f'ipr_proxy={q.get("ipr_proxy")} ipr_cloud={q.get("ipr_cloud")} '
        f'ipr_threat={q.get("ipr_threat")} score={q["fraud_score"]} reject={reject}'
    )
    return not reject


def write_openvpn_config(candidate: Dict[str, str]) -> None:
    decoded = base64.b64decode(candidate['ovpn_b64']).decode('utf-8', errors='ignore')
    extra = """
script-security 2
verb 3
ping 10
ping-restart 30
"""
    os.makedirs(os.path.dirname(OPENVPN_CONFIG_PATH), exist_ok=True)
    with open(OPENVPN_CONFIG_PATH, 'w', encoding='utf-8') as f:
        f.write(decoded)
        f.write(extra)


def stop_openvpn() -> None:
    if os.path.exists(OPENVPN_PID_PATH):
        try:
            with open(OPENVPN_PID_PATH, 'r', encoding='utf-8') as f:
                pid = int(f.read().strip())
            os.kill(pid, 15)
            time.sleep(2)
        except Exception:
            pass
    run(['pkill', '-f', f'openvpn --config {OPENVPN_CONFIG_PATH}'], timeout=5)


def is_process_alive() -> bool:
    if not os.path.exists(OPENVPN_PID_PATH):
        return False
    try:
        with open(OPENVPN_PID_PATH, 'r', encoding='utf-8') as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def start_openvpn_and_wait(wait_seconds: int) -> bool:
    run(['truncate', '-s', '0', OPENVPN_LOG_PATH], timeout=5)
    cp = run(
        [
            'openvpn',
            '--config',
            OPENVPN_CONFIG_PATH,
            '--daemon',
            '--writepid',
            OPENVPN_PID_PATH,
            '--log',
            OPENVPN_LOG_PATH,
        ],
        timeout=20,
    )
    if cp.returncode != 0:
        log(f'openvpn start failed: {cp.stderr.strip()}')
        return False

    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        try:
            with open(OPENVPN_LOG_PATH, 'r', encoding='utf-8', errors='ignore') as f:
                txt = f.read()
            if 'Initialization Sequence Completed' in txt:
                return True
            if 'AUTH_FAILED' in txt or 'Exiting due to fatal error' in txt:
                return False
        except Exception:
            pass
        time.sleep(2)
    return False


def node_reachable(ip: str) -> bool:
    cp = run(['ping', '-c', '2', '-W', '2', ip], timeout=10)
    return cp.returncode == 0


def rotate(cfg: Dict[str, str], state: Dict[str, object], reason: str) -> bool:
    limit = cfg_int(cfg, 'CANDIDATE_LIMIT', 20)
    wait_seconds = cfg_int(cfg, 'OPENVPN_CONNECT_WAIT', 50)
    quality_enabled = cfg_bool(cfg, 'ENABLE_IP_QUALITY_CHECK', True)

    log(f'rotate reason={reason}')
    candidates = fetch_vpngate_candidates(limit)
    if not candidates:
        log('no JP candidates from VPNGate')
        return False

    for c in candidates:
        ip = c['ip']
        if quality_enabled:
            try:
                if not passes_quality(ip, cfg, state):
                    continue
            except Exception as e:
                log(f'skip candidate {ip}, quality_error={e}')
                continue

        stop_openvpn()
        write_openvpn_config(c)
        if start_openvpn_and_wait(wait_seconds):
            state['current_server_ip'] = ip
            state['current_server_host'] = c.get('hostname', '')
            state['last_switch_at'] = int(time.time())
            state['last_quality_check_at'] = int(time.time())
            write_state(state)
            log(f'switched to {ip} host={c.get("hostname", "-")}')
            return True
        log(f'candidate connect failed ip={ip}')

    log('rotate failed: no candidate connected')
    return False


def main() -> int:
    cfg = load_config(CONFIG_PATH)
    if not cfg:
        log(f'config missing: {CONFIG_PATH}')
        return 2

    interval = cfg_int(cfg, 'QUALITY_CHECK_INTERVAL_SEC', 3600)
    force_switch_interval = cfg_int(cfg, 'FORCE_SWITCH_INTERVAL_SEC', 43200)
    quality_enabled = cfg_bool(cfg, 'ENABLE_IP_QUALITY_CHECK', True)
    state = read_state()

    current_server_ip = str(state.get('current_server_ip', ''))
    now = int(time.time())

    if not is_process_alive():
        return 0 if rotate(cfg, state, 'openvpn_process_down') else 1

    last_switch = int(state.get('last_switch_at', 0) or 0)
    if force_switch_interval > 0 and last_switch > 0 and now - last_switch >= force_switch_interval:
        return 0 if rotate(cfg, state, f'force_interval_elapsed:{force_switch_interval}s') else 1

    if current_server_ip and not node_reachable(current_server_ip):
        return 0 if rotate(cfg, state, 'server_ping_fail') else 1

    if quality_enabled:
        last_q = int(state.get('last_quality_check_at', 0) or 0)
        if now - last_q >= interval:
            egress_ip = get_public_ip()
            if not egress_ip:
                return 0 if rotate(cfg, state, 'egress_ip_unknown') else 1
            try:
                if not passes_quality(egress_ip, cfg, state):
                    return 0 if rotate(cfg, state, f'egress_quality_bad:{egress_ip}') else 1
                state['last_quality_check_at'] = now
                write_state(state)
                log(f'quality pass egress_ip={egress_ip}')
            except Exception as e:
                log(f'quality check failed for egress ip={egress_ip}: {e}')
                return 1

    log('health check pass')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
PYEOF

chmod 755 /usr/local/sbin/vpngate-jp-rotator.py

cat >/etc/vpngate-rotator.conf <<CFGEOF
ENABLE_IP_QUALITY_CHECK=1
QUALITY_CACHE_TTL_SEC=86400
IPREGISTRY_API_KEY=${IPREGISTRY_API_KEY}
REJECT_ONLY_WHEN_PROXY_AND_HIGH_RISK=1
RISK_SCORE_THRESHOLD=75
CANDIDATE_LIMIT=20
OPENVPN_CONNECT_WAIT=50
QUALITY_CHECK_INTERVAL_SEC=3600
FORCE_SWITCH_INTERVAL_SEC=43200
CFGEOF

chmod 640 /etc/vpngate-rotator.conf

cat >/etc/systemd/system/vpngate-rotator.service <<'SVCEOF'
[Unit]
Description=VPNGate JP Rotator health check and auto switch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpngate-jp-rotator.py
KillMode=process
SVCEOF

cat >/etc/systemd/system/vpngate-rotator.timer <<'TIMEREOF'
[Unit]
Description=Run VPNGate rotator every 5 minutes

[Timer]
OnBootSec=45s
OnUnitActiveSec=5min
Unit=vpngate-rotator.service
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now vpngate-rotator.timer
systemctl start vpngate-rotator.service || true

echo
echo "Install finished."
echo "Check status:"
echo "  systemctl status vpngate-rotator.timer --no-pager"
echo "  journalctl -u vpngate-rotator.service -n 50 --no-pager"
echo "  ps -ef | grep '[o]penvpn'"

