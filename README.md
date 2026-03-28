# VPNGate Rotator One-Click

一键在 VPS 部署自动切换日本出口 IP：
- VPNGate API 随机抽取日本 OpenVPN 节点
- 每次换 IP 都实时检测（`no_cache`）：`IP2Location + IPRegistry`
- 仅在满足“IPRegistry 判定家宽 + 两库未标记代理/风险”时才使用节点
- 每 1 小时复检当前出口质量
- 每 12 小时强制轮换
- 提供 API 自助查看状态/强制换 IP
- 提供快捷命令 `vpngate`
- 支持卸载
- 自动识别常见 Linux 发行版（apt/apk/dnf/yum/pacman/zypper）

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/WatIWantMonka/vpngate-rotator-oneclick/refs/heads/main/install.sh -o install.sh
sudo bash install.sh
```

安装时会交互输入：
1. `IPRegistry API Key`
2. `API auth token`（用于 `/status` 和 `/rotate`）
3. `API port`（默认 `18082`，可自定义）

## 快捷命令（安装后）

```bash
vpngate status
vpngate rotate
vpngate ip
vpngate logs
vpngate token
vpngate uninstall
```

## API

- `GET /status`：查看 rotator 当前状态（需 Bearer Token）
- `POST /rotate`：每次调用都强制换 IP（需 Bearer Token）

示例：

```bash
curl -H "Authorization: Bearer <YOUR_TOKEN>" http://<VPS_IP>:<YOUR_PORT>/status
curl -X POST -H "Authorization: Bearer <YOUR_TOKEN>" http://<VPS_IP>:<YOUR_PORT>/rotate
```

## 关键行为

- 所有质量检测都走实时查询（无缓存）。
- 每次成功套上 IP 后，会自动：
  1. `curl -4 ip.sb` 获取当前出口 IP
  2. 查询 IP2Location 基本信息
  3. 查询 IPRegistry 家宽/标记信息
  4. 输出结果面板（PASS/FAIL）

## 卸载

```bash
sudo bash install.sh uninstall
# 或
vpngate uninstall
```
