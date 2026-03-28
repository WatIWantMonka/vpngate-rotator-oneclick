# VPNGate JP Rotator (One-Click)

在 Debian/Ubuntu VPS 上一键部署：
- 从 VPNGate API 拉取日本 OpenVPN 节点
- 用 ip2location + ipregistry 做 IP 质量过滤
- 自动连接可用节点
- 每 5 分钟巡检（进程/节点连通性）
- 每 1 小时复检出口 IP 质量
- 每 12 小时强制换一次 IP

## 1) 使用方式（在 VPS 上执行）

```bash
curl -fsSL <YOUR_RAW_GITHUB_URL>/install.sh -o install.sh
sudo bash install.sh
```

脚本只会询问一个输入：
- `IPRegistry API Key`

## 2) 默认配置

配置文件：`/etc/vpngate-rotator.conf`

- `CANDIDATE_LIMIT=20`
- `QUALITY_CHECK_INTERVAL_SEC=3600`
- `FORCE_SWITCH_INTERVAL_SEC=43200`
- `RISK_SCORE_THRESHOLD=75`
- `REJECT_ONLY_WHEN_PROXY_AND_HIGH_RISK=1`

## 3) 常用排查命令

```bash
systemctl status vpngate-rotator.timer --no-pager
journalctl -u vpngate-rotator.service -n 80 --no-pager
ps -ef | grep '[o]penvpn'
cat /var/lib/vpngate-rotator/state.json
```

## 4) 重要实现说明

`vpngate-rotator.service` 使用了：
- `Type=oneshot`
- `KillMode=process`

这是为了防止 systemd 在脚本结束时把后台 `openvpn --daemon` 一并杀掉。
