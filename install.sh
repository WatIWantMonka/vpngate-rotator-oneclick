#!/usr/bin/env bash
set -euo pipefail

APP_NAME="vpngate-rotator"
ROTATOR_PY="/usr/local/sbin/vpngate-jp-rotator.py"
API_PY="/usr/local/sbin/vpngate-rotator-api.py"
WRAPPER_BIN="/usr/local/bin/vpngate"
UNINSTALL_SH="/usr/local/sbin/vpngate-uninstall.sh"
ROTATOR_CONF="/etc/vpngate-rotator.conf"
API_CONF="/etc/vpngate-rotator-api.conf"
STATE_DIR="/var/lib/vpngate-rotator"
STATE_FILE="$STATE_DIR/state.json"
OPENVPN_LOG="/var/log/vpngate-openvpn.log"
SYSTEMD_ROTATOR_SERVICE="/etc/systemd/system/vpngate-rotator.service"
SYSTEMD_ROTATOR_TIMER="/etc/systemd/system/vpngate-rotator.timer"
SYSTEMD_API_SERVICE="/etc/systemd/system/vpngate-rotator-api.service"
OPENRC_API_SERVICE="/etc/init.d/vpngate-rotator-api"
OPENRC_PERIODIC="/etc/periodic/5min/vpngate-rotator"
CRON_MARK="# vpngate-rotator"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root: sudo bash install.sh"
    exit 1
  fi
}

detect_init_system() {
  if command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
    return
  fi
  if command -v rc-service >/dev/null 2>&1 || [[ -d /etc/openrc ]]; then
    echo "openrc"
    return
  fi
  echo "unknown"
}

detect_pkg_manager() {
  for pm in apt-get apk dnf yum pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then
      echo "$pm"
      return
    fi
  done
  echo ""
}

install_dependencies() {
  local pm
  pm="$(detect_pkg_manager)"
  if [[ -z "$pm" ]]; then
    echo "No supported package manager found. Install dependencies manually: openvpn curl python3 ca-certificates iputils/ping"
    exit 1
  fi

  case "$pm" in
    apt-get)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y openvpn curl python3 iputils-ping ca-certificates
      ;;
    apk)
      apk update
      apk add --no-cache openvpn curl python3 iputils ca-certificates bash
      ;;
    dnf)
      dnf install -y openvpn curl python3 iputils ca-certificates
      ;;
    yum)
      yum install -y openvpn curl python3 iputils ca-certificates
      ;;
    pacman)
      pacman -Sy --noconfirm openvpn curl python iputils ca-certificates
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install openvpn curl python3 iputils ca-certificates
      ;;
    *)
      echo "Unsupported package manager: $pm"
      exit 1
      ;;
  esac

  if command -v update-ca-certificates >/dev/null 2>&1; then
    update-ca-certificates || true
  fi
}

write_rotator_py() {
cat >"$ROTATOR_PY" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import base64
import csv
import html
import io
import json
import os
import random
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
ROTATE_LOCK_PATH = '/run/vpngate-rotate.lock'
VPNGATE_API = 'https://www.vpngate.net/api/iphone/'
VPNGATE_LIST = 'https://www.vpngate.net/en/'


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


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def acquire_rotate_lock() -> bool:
    try:
        fd = os.open(ROTATE_LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(str(os.getpid()))
        return True
    except FileExistsError:
        try:
            with open(ROTATE_LOCK_PATH, 'r', encoding='utf-8') as f:
                lock_pid = int((f.read() or '0').strip())
            if lock_pid > 0 and pid_alive(lock_pid):
                log(f'rotate skipped: another rotator is active pid={lock_pid}')
                return False
        except Exception:
            pass
        try:
            os.unlink(ROTATE_LOCK_PATH)
        except FileNotFoundError:
            pass
        fd = os.open(ROTATE_LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(str(os.getpid()))
        return True


def release_rotate_lock() -> None:
    try:
        with open(ROTATE_LOCK_PATH, 'r', encoding='utf-8') as f:
            lock_pid = int((f.read() or '0').strip())
        if lock_pid == os.getpid():
            os.unlink(ROTATE_LOCK_PATH)
    except Exception:
        pass


def get_public_ip() -> Optional[str]:
    # Primary source requested by user: curl -4 ip.sb
    try:
        cp = run(['curl', '-4', '-s', 'ip.sb'], timeout=8)
        ip = (cp.stdout or '').strip()
        if re.match(r'^\d+\.\d+\.\d+\.\d+$', ip):
            return ip
    except Exception:
        pass

    for url in ('https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com'):
        try:
            ip = http_get(url, timeout=8).strip()
            if re.match(r'^\d+\.\d+\.\d+\.\d+$', ip):
                return ip
        except Exception:
            pass
    return None


def parse_csv_candidates(raw: str) -> List[Dict[str, str]]:
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
            'source': 'csv',
        })
    return out


def parse_html_candidates(raw: str) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    seen = set()

    for row in re.findall(r'<tr>\s*(.*?)\s*</tr>', raw, flags=re.I | re.S):
        if 'do_openvpn.aspx' not in row:
            continue

        country_m = re.search(
            r"<td[^>]*class='vg_table_row_[01]'[^>]*>.*?<br>\s*([^<]+)\s*</td>",
            row,
            flags=re.I | re.S,
        )
        host_ip_m = re.search(
            r"<td[^>]*class='vg_table_row_[01]'[^>]*>\s*<b>.*?<span[^>]*>([^<]+)</span>.*?"
            r"<br>\s*<span[^>]*>(\d+\.\d+\.\d+\.\d+)</span>",
            row,
            flags=re.I | re.S,
        )
        config_m = re.search(r"href='(do_openvpn\.aspx\?[^']+)'", row, flags=re.I)

        if not country_m or not host_ip_m or not config_m:
            continue

        country = html.unescape(country_m.group(1).strip())
        if country.lower() != 'japan':
            continue

        hostname = html.unescape(host_ip_m.group(1).strip())
        ip = host_ip_m.group(2).strip()
        if ip in seen:
            continue
        seen.add(ip)

        out.append({
            'ip': ip,
            'hostname': hostname,
            'config_page_url': urllib.parse.urljoin(VPNGATE_LIST, html.unescape(config_m.group(1))),
            'source': 'html',
        })

    return out


def fetch_vpngate_candidates(limit: int) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    errors: List[str] = []

    try:
        raw = http_get(VPNGATE_API, timeout=20)
        out = parse_csv_candidates(raw)
        if out:
            log(f'fetched {len(out)} JP candidates via VPNGate CSV API')
    except Exception as e:
        errors.append(f'csv_error={e}')

    if not out:
        try:
            raw = http_get(VPNGATE_LIST, timeout=20)
            out = parse_html_candidates(raw)
            if out:
                log(f'fetched {len(out)} JP candidates via VPNGate HTML fallback')
        except Exception as e:
            errors.append(f'html_error={e}')

    if not out and errors:
        log('candidate source errors: ' + '; '.join(errors))

    random.SystemRandom().shuffle(out)
    return out[:limit]


def ip_quality(ip: str, cfg: Dict[str, str]) -> Dict[str, object]:
    # no_cache: always query both databases in realtime
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
    conn = ipr_data.get('connection', {}) if isinstance(ipr_data, dict) else {}
    company = ipr_data.get('company', {}) if isinstance(ipr_data, dict) else {}

    ipr_proxy = bool(
        sec.get('is_proxy', False)
        or sec.get('is_vpn', False)
        or sec.get('is_tor', False)
        or sec.get('is_relay', False)
        or sec.get('is_anonymous', False)
    )
    ipr_threat = bool(sec.get('is_attacker', False) or sec.get('is_abuser', False) or sec.get('is_threat', False))
    ipr_cloud = bool(sec.get('is_cloud_provider', False))

    conn_type = str(conn.get('type', '') or '').lower()
    company_type = str(company.get('type', '') or '').lower()

    # Residential heuristic: ISP line, not cloud
    residential = (conn_type == 'isp') and (not ipr_cloud) and (company_type in ('', 'isp'))

    flagged = bool(i2l_proxy or ipr_proxy or ipr_cloud or ipr_threat)

    return {
        'ip': ip,
        'flagged': flagged,
        'residential': residential,
        'i2l_proxy': i2l_proxy,
        'ipr_proxy': ipr_proxy,
        'ipr_cloud': ipr_cloud,
        'ipr_threat': ipr_threat,
        'conn_type': conn_type,
        'company_type': company_type,
        'country_code': i2l_data.get('country_code', ''),
        'country_name': i2l_data.get('country_name', ''),
        'region_name': i2l_data.get('region_name', ''),
        'city_name': i2l_data.get('city_name', ''),
        'asn': i2l_data.get('asn', ''),
        'as_name': i2l_data.get('as', ''),
        'checked_at': int(time.time()),
    }


def quality_pass_for_candidate(q: Dict[str, object]) -> bool:
    return bool(q.get('residential', False) and (not q.get('flagged', True)))


def quality_pass_for_egress(q: Dict[str, object], cfg: Dict[str, str]) -> bool:
    # Keep same strict policy for all operations
    return bool(q.get('residential', False) and (not q.get('flagged', True)))


def fetch_openvpn_profile(candidate: Dict[str, str]) -> str:
    ovpn_b64 = candidate.get('ovpn_b64', '').strip()
    if ovpn_b64:
        return base64.b64decode(ovpn_b64).decode('utf-8', errors='ignore')

    config_page_url = candidate.get('config_page_url', '').strip()
    if not config_page_url:
        raise RuntimeError('candidate has no OpenVPN config source')

    page = http_get(config_page_url, timeout=20)
    download_links = re.findall(
        r"href=['\"]([^'\"]*openvpn_download\.aspx[^'\"]+\.ovpn)['\"]",
        page,
        flags=re.I,
    )
    if not download_links:
        raise RuntimeError('OpenVPN download link not found on config page')

    random.SystemRandom().shuffle(download_links)
    last_error: Optional[str] = None
    for link in download_links:
        download_url = urllib.parse.urljoin(VPNGATE_LIST, html.unescape(link))
        try:
            profile = http_get(download_url, timeout=20)
        except Exception as e:
            last_error = str(e)
            continue

        if 'client' in profile and 'remote ' in profile:
            return profile
        last_error = 'downloaded profile did not look like an OpenVPN client config'

    raise RuntimeError(last_error or 'unable to download OpenVPN profile')


def write_openvpn_config(candidate: Dict[str, str]) -> None:
    decoded = fetch_openvpn_profile(candidate)
    extra = """
script-security 2
verb 3
ping 10
ping-restart 30
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC
data-ciphers-fallback AES-128-CBC
auth-nocache
"""
    os.makedirs(os.path.dirname(OPENVPN_CONFIG_PATH), exist_ok=True)
    with open(OPENVPN_CONFIG_PATH, 'w', encoding='utf-8') as f:
        f.write(decoded)
        f.write(extra)


def stop_openvpn() -> None:
    pid = None
    if os.path.exists(OPENVPN_PID_PATH):
        try:
            with open(OPENVPN_PID_PATH, 'r', encoding='utf-8') as f:
                pid = int(f.read().strip())
        except Exception:
            pid = None

    if pid and pid_alive(pid):
        try:
            os.kill(pid, 15)
        except Exception:
            pass

    run(['pkill', '-TERM', '-f', f'openvpn --config {OPENVPN_CONFIG_PATH}'], timeout=5)

    deadline = time.time() + 8
    while time.time() < deadline:
        if not pid or not pid_alive(pid):
            break
        time.sleep(0.5)

    run(['pkill', '-KILL', '-f', f'openvpn --config {OPENVPN_CONFIG_PATH}'], timeout=5)

    try:
        os.unlink(OPENVPN_PID_PATH)
    except FileNotFoundError:
        pass


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
            '--config', OPENVPN_CONFIG_PATH,
            '--daemon',
            '--writepid', OPENVPN_PID_PATH,
            '--log', OPENVPN_LOG_PATH,
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
            fatal_markers = (
                'AUTH_FAILED',
                'Exiting due to fatal error',
                'failed to negotiate cipher with server',
                'process-push-msg-failed',
                'Cannot open TUN/TAP dev',
                'All connections have been connect-retry-max exhausted',
            )
            if any(marker in txt for marker in fatal_markers):
                return False
        except Exception:
            pass
        time.sleep(2)
    return False


def node_reachable(ip: str) -> bool:
    cp = run(['ping', '-c', '2', '-W', '2', ip], timeout=10)
    return cp.returncode == 0


def show_report(cfg: Dict[str, str], state: Dict[str, object], title: str = 'Current Egress') -> None:
    ip = get_public_ip()
    if not ip:
        log('report: cannot determine public IPv4')
        return
    try:
        q = ip_quality(ip, cfg)
    except Exception as e:
        log(f'report: quality query failed: {e}')
        return

    state['last_report'] = q
    write_state(state)

    verdict = 'PASS' if quality_pass_for_egress(q, cfg) else 'FAIL'
    residential = 'YES' if q.get('residential') else 'NO'

    print('')
    print('================ VPNGate Rotate Result ================')
    print(f'{title:<18}: {ip}')
    print(f'Country/City      : {q.get("country_name","-")} / {q.get("city_name","-")}')
    print(f'ASN               : AS{q.get("asn","-")} {q.get("as_name","-")}')
    print(f'IP2Location       : is_proxy={q.get("i2l_proxy")}')
    print(f'IPRegistry Flags  : proxy={q.get("ipr_proxy")} cloud={q.get("ipr_cloud")} threat={q.get("ipr_threat")}')
    print(f'Residential (IPR) : {residential} (connection.type={q.get("conn_type","-")}, company.type={q.get("company_type","-")})')
    print(f'Verdict           : {verdict}')
    print('========================================================')
    print('')


def rotate(cfg: Dict[str, str], state: Dict[str, object], reason: str) -> bool:
    limit = cfg_int(cfg, 'CANDIDATE_LIMIT', 120)
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
                q = ip_quality(ip, cfg)
                log(
                    f'candidate ip={ip} residential={q.get("residential")} '
                    f'i2l_proxy={q.get("i2l_proxy")} ipr_proxy={q.get("ipr_proxy")} '
                    f'ipr_cloud={q.get("ipr_cloud")} ipr_threat={q.get("ipr_threat")}'
                )
                if not quality_pass_for_candidate(q):
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
            show_report(cfg, state, title='Post-Switch Egress')
            return True

        log(f'candidate connect failed ip={ip}')

    log('rotate failed: no suitable candidate connected')
    return False


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument('--force-rotate', action='store_true')
    ap.add_argument('--report', action='store_true')
    args, _ = ap.parse_known_args()

    cfg = load_config(CONFIG_PATH)
    if not cfg:
        log(f'config missing: {CONFIG_PATH}')
        return 2

    interval = cfg_int(cfg, 'QUALITY_CHECK_INTERVAL_SEC', 3600)
    force_switch_interval = cfg_int(cfg, 'FORCE_SWITCH_INTERVAL_SEC', 43200)
    quality_enabled = cfg_bool(cfg, 'ENABLE_IP_QUALITY_CHECK', True)
    state = read_state()

    if args.report:
        show_report(cfg, state, title='Manual Report')
        return 0

    if not acquire_rotate_lock():
        return 0

    try:
        if args.force_rotate:
            return 0 if rotate(cfg, state, 'api_force_rotate') else 1

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
                    q = ip_quality(egress_ip, cfg)
                    state['last_quality_check_at'] = now
                    state['last_egress_quality'] = q
                    write_state(state)
                    if not quality_pass_for_egress(q, cfg):
                        return 0 if rotate(cfg, state, f'egress_quality_bad:{egress_ip}') else 1
                    log(f'quality pass egress_ip={egress_ip}')
                except Exception as e:
                    log(f'quality check failed for egress ip={egress_ip}: {e}')
                    return 1

        log('health check pass')
        return 0
    finally:
        release_rotate_lock()


if __name__ == '__main__':
    raise SystemExit(main())
PYEOF
chmod 755 "$ROTATOR_PY"
}

write_api_py() {
cat >"$API_PY" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

CONF = '/etc/vpngate-rotator-api.conf'


def load_conf():
    d = {}
    if os.path.exists(CONF):
        with open(CONF, 'r', encoding='utf-8') as f:
            for ln in f:
                ln = ln.strip()
                if not ln or ln.startswith('#') or '=' not in ln:
                    continue
                k, v = ln.split('=', 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    return d


def run_rotator(force=False):
    cmd = ['/usr/local/sbin/vpngate-jp-rotator.py']
    if force:
        cmd.append('--force-rotate')
    cp = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=420)
    return cp.returncode, cp.stdout


class H(BaseHTTPRequestHandler):
    def _json(self, code, payload):
        b = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _auth(self, cfg):
        token = cfg.get('API_TOKEN', '')
        auth = self.headers.get('Authorization', '')
        if not token or not auth.startswith('Bearer '):
            return False
        return auth[7:] == token

    def do_GET(self):
        cfg = load_conf()
        p = urlparse(self.path).path

        if p == '/status':
            if not self._auth(cfg):
                self._json(401, {'ok': False, 'error': 'unauthorized'})
                return
            state = {}
            try:
                with open('/var/lib/vpngate-rotator/state.json', 'r', encoding='utf-8') as f:
                    state = json.load(f)
            except Exception:
                pass
            self._json(200, {'ok': True, 'state': state, 'ts': int(time.time())})
            return

        self._json(404, {'ok': False, 'error': 'not_found'})

    def do_POST(self):
        cfg = load_conf()
        p = urlparse(self.path).path

        if p != '/rotate':
            self._json(404, {'ok': False, 'error': 'not_found'})
            return

        if not self._auth(cfg):
            self._json(401, {'ok': False, 'error': 'unauthorized'})
            return

        lock = '/run/vpngate-rotate-api.lock'
        cooldown = int(cfg.get('API_COOLDOWN_SEC', '20') or '20')
        now = int(time.time())
        try:
            if os.path.exists(lock):
                with open(lock, 'r', encoding='utf-8') as f:
                    last = int(f.read().strip() or '0')
                if now - last < cooldown:
                    self._json(429, {'ok': False, 'error': 'cooldown', 'retry_after_sec': cooldown - (now - last)})
                    return
        except Exception:
            pass

        with open(lock, 'w', encoding='utf-8') as f:
            f.write(str(now))

        rc, out = run_rotator(force=True)
        self._json(200 if rc == 0 else 500, {'ok': rc == 0, 'forced': True, 'rc': rc, 'output': out[-6000:]})

    def log_message(self, fmt, *args):
        return


def main():
    cfg = load_conf()
    host = cfg.get('API_BIND', '0.0.0.0')
    port = int(cfg.get('API_PORT', '18082') or '18082')
    srv = ThreadingHTTPServer((host, port), H)
    srv.serve_forever()


if __name__ == '__main__':
    main()
PYEOF
chmod 755 "$API_PY"
}

write_wrapper_bin() {
cat >"$WRAPPER_BIN" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail

API_CONF="/etc/vpngate-rotator-api.conf"
ROTATOR_PY="/usr/local/sbin/vpngate-jp-rotator.py"
UNINSTALL_SH="/usr/local/sbin/vpngate-uninstall.sh"

get_conf() {
  local key="$1"
  awk -F= -v k="$key" '$1==k{print $2}' "$API_CONF" | tail -n 1
}

require_installed() {
  if [[ ! -f "$API_CONF" ]] || [[ ! -f "$ROTATOR_PY" ]]; then
    echo "vpngate is not installed. Run: sudo bash install.sh"
    exit 1
  fi
}

cmd_help() {
  cat <<EOF
vpngate commands:
  vpngate status      Show current rotator state
  vpngate rotate      Force rotate to a new JP residential-style IP
  vpngate ip          Show current egress IP quality report
  vpngate logs        Show recent service logs
  vpngate token       Print configured API token
  vpngate uninstall   Uninstall vpngate rotator
EOF
}

cmd_status() {
  require_installed
  local token port
  token="$(get_conf API_TOKEN)"
  port="$(get_conf API_PORT)"
  curl -s -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/status"
  echo
}

cmd_rotate() {
  require_installed
  local token port
  token="$(get_conf API_TOKEN)"
  port="$(get_conf API_PORT)"
  curl -s -X POST -H "Authorization: Bearer ${token}" "http://127.0.0.1:${port}/rotate"
  echo
}

cmd_ip() {
  require_installed
  python3 "$ROTATOR_PY" --report
}

cmd_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u vpngate-rotator.service -u vpngate-rotator-api.service -n 120 --no-pager
  else
    tail -n 120 /var/log/vpngate-openvpn.log 2>/dev/null || true
  fi
}

cmd_token() {
  require_installed
  echo "$(get_conf API_TOKEN)"
}

cmd_uninstall() {
  if [[ -x "$UNINSTALL_SH" ]]; then
    "$UNINSTALL_SH"
  else
    echo "Uninstall script not found: $UNINSTALL_SH"
    exit 1
  fi
}

case "${1:-help}" in
  status) cmd_status ;;
  rotate) cmd_rotate ;;
  ip) cmd_ip ;;
  logs) cmd_logs ;;
  token) cmd_token ;;
  uninstall) cmd_uninstall ;;
  help|--help|-h) cmd_help ;;
  *)
    echo "Unknown command: ${1:-}"
    cmd_help
    exit 1
    ;;
esac
SHEOF
chmod 755 "$WRAPPER_BIN"
}

write_uninstall_script() {
cat >"$UNINSTALL_SH" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail

ROTATOR_PY="/usr/local/sbin/vpngate-jp-rotator.py"
API_PY="/usr/local/sbin/vpngate-rotator-api.py"
WRAPPER_BIN="/usr/local/bin/vpngate"
UNINSTALL_SH="/usr/local/sbin/vpngate-uninstall.sh"
ROTATOR_CONF="/etc/vpngate-rotator.conf"
API_CONF="/etc/vpngate-rotator-api.conf"
STATE_DIR="/var/lib/vpngate-rotator"
SYSTEMD_ROTATOR_SERVICE="/etc/systemd/system/vpngate-rotator.service"
SYSTEMD_ROTATOR_TIMER="/etc/systemd/system/vpngate-rotator.timer"
SYSTEMD_API_SERVICE="/etc/systemd/system/vpngate-rotator-api.service"
OPENRC_API_SERVICE="/etc/init.d/vpngate-rotator-api"
OPENRC_PERIODIC="/etc/periodic/5min/vpngate-rotator"
CRON_MARK="# vpngate-rotator"

if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now vpngate-rotator.timer >/dev/null 2>&1 || true
  systemctl disable --now vpngate-rotator-api.service >/dev/null 2>&1 || true
  systemctl stop vpngate-rotator.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
fi

if command -v rc-service >/dev/null 2>&1 || [[ -d /etc/openrc ]]; then
  rc-service vpngate-rotator-api stop >/dev/null 2>&1 || true
  rc-update del vpngate-rotator-api default >/dev/null 2>&1 || true
fi

rm -f "$SYSTEMD_ROTATOR_SERVICE" "$SYSTEMD_ROTATOR_TIMER" "$SYSTEMD_API_SERVICE"
rm -f "$OPENRC_API_SERVICE" "$OPENRC_PERIODIC"

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
fi

if command -v crontab >/dev/null 2>&1; then
  crontab -l 2>/dev/null | grep -v "$CRON_MARK" | crontab - || true
fi

pkill -f "$API_PY" >/dev/null 2>&1 || true
pkill -f "openvpn --config /etc/openvpn/vpngate-current.ovpn" >/dev/null 2>&1 || true

rm -f "$ROTATOR_PY" "$API_PY" "$WRAPPER_BIN" "$ROTATOR_CONF" "$API_CONF"
rm -rf "$STATE_DIR"
rm -f /etc/openvpn/vpngate-current.ovpn /run/vpngate-openvpn.pid /run/vpngate-rotate-api.lock

rm -f "$UNINSTALL_SH"

echo "vpngate rotator uninstalled."
SHEOF
chmod 755 "$UNINSTALL_SH"
}

write_config_files() {
  local ipregistry_key="$1"
  local api_token="$2"
  local api_port="$3"

  cat >"$ROTATOR_CONF" <<EOF
ENABLE_IP_QUALITY_CHECK=1
IPREGISTRY_API_KEY=${ipregistry_key}
CANDIDATE_LIMIT=120
OPENVPN_CONNECT_WAIT=50
QUALITY_CHECK_INTERVAL_SEC=3600
FORCE_SWITCH_INTERVAL_SEC=43200
EOF
  chmod 640 "$ROTATOR_CONF"

  cat >"$API_CONF" <<EOF
API_TOKEN=${api_token}
API_BIND=0.0.0.0
API_PORT=${api_port}
API_COOLDOWN_SEC=20
EOF
  chmod 600 "$API_CONF"
}

setup_systemd() {
cat >"$SYSTEMD_ROTATOR_SERVICE" <<'SVCEOF'
[Unit]
Description=VPNGate JP Rotator health check and auto switch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vpngate-jp-rotator.py
KillMode=process
SVCEOF

cat >"$SYSTEMD_ROTATOR_TIMER" <<'TIMEREOF'
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

cat >"$SYSTEMD_API_SERVICE" <<'APISVCEOF'
[Unit]
Description=VPNGate Rotator Self-Service API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/sbin/vpngate-rotator-api.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
APISVCEOF

  systemctl daemon-reload
  systemctl enable --now vpngate-rotator.timer
  systemctl enable --now vpngate-rotator-api.service
  systemctl start vpngate-rotator.service >/dev/null 2>&1 || true
}

setup_openrc() {
cat >"$OPENRC_API_SERVICE" <<'OPEOF'
#!/sbin/openrc-run
name="vpngate-rotator-api"
command="/usr/bin/python3"
command_args="/usr/local/sbin/vpngate-rotator-api.py"
pidfile="/run/vpngate-rotator-api.pid"
command_background=true

depend() {
  need net
}
OPEOF
  chmod 755 "$OPENRC_API_SERVICE"

  cat >"$OPENRC_PERIODIC" <<'PEOF'
#!/bin/sh
/usr/local/sbin/vpngate-jp-rotator.py >/dev/null 2>&1
PEOF
  chmod 755 "$OPENRC_PERIODIC"

  rc-update add vpngate-rotator-api default >/dev/null 2>&1 || true
  rc-service vpngate-rotator-api restart >/dev/null 2>&1 || rc-service vpngate-rotator-api start >/dev/null 2>&1 || true

  rc-update add crond default >/dev/null 2>&1 || true
  rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true

  "$ROTATOR_PY" >/dev/null 2>&1 || true
}

setup_fallback_scheduler() {
  if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "$CRON_MARK"; echo "*/5 * * * * ${ROTATOR_PY} >/dev/null 2>&1 ${CRON_MARK}") | crontab -
  fi
  nohup /usr/bin/python3 "$API_PY" >/var/log/vpngate-rotator-api.log 2>&1 &
  "$ROTATOR_PY" >/dev/null 2>&1 || true
}

install_all() {
  local ipregistry_key api_token api_port init_sys

  read -r -p "Enter IPRegistry API Key: " ipregistry_key
  if [[ -z "$ipregistry_key" ]]; then
    echo "IPRegistry API Key is required."
    exit 1
  fi

  read -r -p "Enter API auth token (used by /status and /rotate): " api_token
  if [[ -z "$api_token" ]]; then
    echo "API auth token is required."
    exit 1
  fi

  read -r -p "Enter API port (default 18082): " api_port
  api_port="${api_port:-18082}"
  if ! [[ "$api_port" =~ ^[0-9]+$ ]] || (( api_port < 1 || api_port > 65535 )); then
    echo "API port must be an integer between 1 and 65535."
    exit 1
  fi

  install_dependencies

  install -d -m 755 /usr/local/sbin
  install -d -m 755 /etc/openvpn
  install -d -m 755 "$STATE_DIR"

  write_rotator_py
  write_api_py
  write_wrapper_bin
  write_uninstall_script
  write_config_files "$ipregistry_key" "$api_token" "$api_port"

  init_sys="$(detect_init_system)"
  case "$init_sys" in
    systemd)
      setup_systemd
      ;;
    openrc)
      setup_openrc
      ;;
    *)
      setup_fallback_scheduler
      ;;
  esac

  echo
  echo "Install finished."
  echo "Quick command: vpngate"
  echo
  echo "Examples:"
  echo "  vpngate status"
  echo "  vpngate rotate"
  echo "  vpngate ip"
  echo "  vpngate logs"
  echo
  echo "Direct API (port 18082):"
  echo "  curl -H 'Authorization: Bearer ${api_token}' http://<VPS_IP>:${api_port}/status"
  echo "  curl -X POST -H 'Authorization: Bearer ${api_token}' http://<VPS_IP>:${api_port}/rotate"
}

main() {
  require_root
  case "${1:-install}" in
    install)
      install_all
      ;;
    uninstall)
      if [[ -x "$UNINSTALL_SH" ]]; then
        "$UNINSTALL_SH"
      else
        echo "No uninstall script found. Nothing to do."
      fi
      ;;
    *)
      echo "Usage: bash install.sh [install|uninstall]"
      exit 1
      ;;
  esac
}

main "${1:-install}"
