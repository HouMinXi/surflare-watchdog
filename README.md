# surflare-watchdog

Surflare VPN 守护脚本，适用于 Linux 笔记本。解决两个问题：

1. **假连接**：Surflare UI 显示已连接，但实际出口已回落到本地 ISP（静默隧道故障）
2. **合盖唤醒**：打开笔记本后 VPN 未自动重连

## 功能

- 每 60 秒检测出口 IP 国家，连续 2 次异常自动重连
- 系统从休眠/挂起唤醒后立即重连（`systemd-sleep` 钩子）
- 重连前先 `surflare disconnect` 清理 nftables tproxy 规则和 iproute2 策略路由，避免网络被锁死
- `flock` 互斥锁防止 watchdog 与唤醒钩子并发冲突
- 日志写入 `/dev/kmsg`，通过 `dmesg` 查看，不产生日志文件
- 固定连接节点，重连后节点不变

## 依赖

| 命令 | 包名 |
|------|------|
| `curl` | curl |
| `killall` | psmisc |
| `pgrep` | procps-ng / procps |
| `flock` | util-linux |
| `nm-online` | NetworkManager（可选，缺失时 fallback sleep 15s） |
| `surflare` / `surflare-proxy` | Surflare 安装包 |

## 安装

```bash
# 1. 克隆
git clone git@github.com:HouMinXi/surflare-watchdog.git
cd surflare-watchdog

# 2. 赋予执行权限
chmod +x surflare_watchdog.sh

# 3. 安装唤醒钩子（一次性）
sudo ln -sf "$(pwd)/surflare_watchdog.sh" \
    /etc/systemd/system-sleep/surflare-resume.sh
```

## 使用

```bash
# 启动 watchdog（后台运行）
sudo /path/to/surflare_watchdog.sh &

# 停止
sudo pkill -f surflare_watchdog.sh

# 查看日志
sudo dmesg | grep surflare
sudo dmesg -w | grep surflare   # 实时
```

## 配置

编辑脚本顶部的三个变量：

```bash
NODE="public_16"   # 固定服务器 tag（从 surflare nodes 获取）
CHECK_INTERVAL=60  # 检测间隔（秒）
FAIL_THRESHOLD=2   # 连续失败 N 次才触发重连
```

## 日志示例

```
[Apr12 09:01] surflare_watchdog: watchdog 启动，节点: public_16，检测间隔: 60s，失败阈值: 2
[Apr12 09:03] surflare_watchdog: 出口异常（CN），连续第 2 次
[Apr12 09:03] surflare_watchdog: 优雅断开，清理 nftables 规则和策略路由...
[Apr12 09:03] surflare_watchdog: 连接到 public_16（daemon 接管）...
[Apr12 09:03] surflare_watchdog: 重连后出口: US
```

## 适配发行版

Fedora、Ubuntu、Debian、Arch、openSUSE 等主流 systemd Linux 发行版。
