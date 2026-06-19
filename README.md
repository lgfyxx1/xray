# xray-reality

多协议 Xray 一键部署脚本，底层调用 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 官方安装器。

脚本安装时会尝试启用 Linux `BBR` 拥塞控制；如果当前内核不支持，会自动跳过。

## 支持协议

| # | 协议 | 是否需要域名 | 特点 |
|---|---|---|---|
| 1 | VLESS + TCP + Reality | ❌ | **推荐**，最优秀的防封锁 |
| 2 | Shadowsocks + WS + TLS | ✅ | SS 隐藏于 HTTPS，防主动探测 |
| 3 | VLESS + WS + TLS | ✅ | CDN 友好 |
| 4 | VLESS + gRPC + TLS | ✅ | CDN 友好，低延迟 |
| 5 | VMess + WS + TLS | ✅ | 兼容性最广 |
| 6 | VMess + gRPC + TLS | ✅ | |
| 7 | Trojan + WS + TLS | ✅ | |
| 8 | Trojan + gRPC + TLS | ✅ | |

> 纯明文 Shadowsocks 可被 GFW 主动探测识别。本脚本的 Shadowsocks 强制走 WebSocket+TLS，流量完全融入 HTTPS，无法被区分。

TLS 协议会自动通过 **acme.sh + Let's Encrypt** 申请证书，需要：
- 域名 DNS A 记录指向服务器 IP
- 80 端口空闲（申请证书时临时占用）
- 如果 80 端口被 nginx 占用，可先停 nginx，或使用 `ACME_STOP_SERVICES=nginx` 让脚本申请证书时临时停启
- TLS/CDN 协议默认监听 443；如果 nginx 也占用 443，需要先调整或停止 nginx，或改用 Cloudflare 支持的其他 HTTPS 端口
- 如果域名托管在 Cloudflare，推荐使用 `ACME_DNS=cloudflare` 改走 DNS 验证，不占用 80 端口

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o /tmp/xr.sh && sudo bash /tmp/xr.sh
```

Cloudflare DNS 验证示例：

```bash
curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o /tmp/xr.sh
ACME_EMAIL=you@example.com CF_Token=your_cloudflare_api_token ACME_DNS=cloudflare REALITY_PORT=8443 FORCE=1 bash /tmp/xr.sh
```

安装时会弹出协议选择菜单。

> `bash <(curl ...)` 写法依赖 `/dev/fd`，部分 VPS 内核未挂载会报错，请使用上面的写法。

## 安装后管理

安装成功后脚本自动复制到 `/usr/local/bin/xr`，输入 `xr` 打开管理菜单：

```
╔══════════════════════════════════════════════════╗
║  Xray 管理脚本 v2.0.0                           ║
╚══════════════════════════════════════════════════╝

  协议：vless-reality         端口：43210
  地址：1.2.3.4               状态：● 运行中

  ─────── 节点管理 ────────────────────────────
  1. 查看节点信息 + 二维码
  2. 修改端口
  3. 重新生成 UUID
  4. 修改伪装目标 (SNI)
  5. 修改节点名称

  ─────── 服务管理 ────────────────────────────
  6. 重启 Xray
  7. 查看日志（最近 50 条）
  8. 查看服务状态

  ─────── 系统操作 ────────────────────────────
  9. 升级 Xray
  10. 卸载 Xray

  0. 退出
```

## 命令速查

```bash
xr              # 打开交互式管理菜单
xr info         # 节点信息 + 分享链接 + 二维码
xr status       # 服务状态
xr logs [N]     # 最近 N 条日志
xr bbr          # 查看 BBR 状态
xr enable-bbr   # 启用 BBR
xr restart      # 重启
xr update       # 升级 Xray
xr delete-node  # 删除当前节点配置，保留 Xray 程序
xr uninstall    # 卸载
xr edit-port    # 修改端口
xr edit-uuid    # 重新生成 UUID / 密码
xr edit-dest    # 修改伪装目标（仅 Reality）
xr edit-name    # 修改节点名称
```

## 可选环境变量

| 变量 | 说明 |
|---|---|
| `PROTOCOL=vless-reality` | 跳过选择菜单，直接指定协议 |
| `REALITY_PORT=443` | 端口（TLS 协议默认 443，Reality 默认随机） |
| `REALITY_DEST=www.apple.com` | Reality 伪装目标 |
| `REALITY_ADDR=1.2.3.4` | 分享链接服务器地址 |
| `REALITY_NAME=MyNode` | 节点名称 |
| `XRAY_DOMAIN=my.domain` | TLS 协议域名 |
| `XRAY_SS_METHOD=aes-256-gcm` | Shadowsocks 加密方式 |
| `XRAY_VERSION=v26.3.27` | 固定 Xray 版本 |
| `ACME_EMAIL=you@example.com` | 必填，acme.sh 注册 ACME 账户使用的真实邮箱 |
| `ACME_DNS=cloudflare` | 使用 Cloudflare DNS API 做证书验证，不占用 80 端口 |
| `ACME_STOP_SERVICES=nginx` | 申请证书前临时停止服务，申请后恢复 |
| `CF_Token=...` | Cloudflare API Token，供 `dns_cf` 验证使用 |
| `CF_Zone_ID=...` | 可选，Cloudflare Zone ID |
| `CF_Account_ID=...` | 可选，Cloudflare Account ID |
| `FORCE=1` | 已有配置时强制重建 |

## License

MIT
