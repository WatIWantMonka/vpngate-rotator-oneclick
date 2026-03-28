# VPNGate Rotator One-Click

在 Debian/Ubuntu VPS 上一键部署自动切换日本 VPNGate OpenVPN 出口 IP：
- VPNGate API 拉取日本节点（支持 OpenVPN）
- ip2location + ipregistry 双重质量过滤
- 节点不可用自动切换
- 每 1 小时复检出口质量
- 每 12 小时强制换 IP

## Install (One Command)

在 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/WatIWantMonka/vpngate-rotator-oneclick/refs/heads/main/install.sh -o install.sh
sudo bash install.sh
```

安装脚本只会交互询问一个参数：
- `IPRegistry API Key`

安装时会自动安装依赖（无需预装 OpenVPN）：
- `openvpn`
- `curl`
- `python3`
- `iputils-ping`
- `ca-certificates`

## What It Deploys

- 主程序：`/usr/local/sbin/vpngate-jp-rotator.py`
- 配置：`/etc/vpngate-rotator.conf`
- 服务：`/etc/systemd/system/vpngate-rotator.service`
- 定时器：`/etc/systemd/system/vpngate-rotator.timer`
- 状态缓存：`/var/lib/vpngate-rotator/state.json`
- OpenVPN 日志：`/var/log/vpngate-openvpn.log`

## Default Behavior

- 每 5 分钟巡检一次（systemd timer）
- OpenVPN 进程掉线 -> 自动切换节点
- 当前节点 ping 不通 -> 自动切换节点
- 每 1 小时检查当前出口 IP 质量
- 每 12 小时强制切换一次出口 IP

默认关键参数在 `/etc/vpngate-rotator.conf`：

```ini
ENABLE_IP_QUALITY_CHECK=1
QUALITY_CACHE_TTL_SEC=86400
REJECT_ONLY_WHEN_PROXY_AND_HIGH_RISK=1
RISK_SCORE_THRESHOLD=75
CANDIDATE_LIMIT=20
OPENVPN_CONNECT_WAIT=50
QUALITY_CHECK_INTERVAL_SEC=3600
FORCE_SWITCH_INTERVAL_SEC=43200
```

## Useful Commands

查看定时器：

```bash
systemctl status vpngate-rotator.timer --no-pager
```

查看最近执行日志：

```bash
journalctl -u vpngate-rotator.service -n 100 --no-pager
```

查看 OpenVPN 进程：

```bash
ps -ef | grep '[o]penvpn'
```

查看当前状态：

```bash
cat /var/lib/vpngate-rotator/state.json
```

## Notes

- 服务单元使用 `KillMode=process`，避免脚本退出时误杀后台 OpenVPN。
- 本方案是出口 IP 轮换，不是入口 IP（VPS 公网 IP 不会变）。
- VPNGate 是公共节点池，稳定性会波动，自动切换是设计的一部分。
