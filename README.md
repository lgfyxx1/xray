# xray-reality

多协议 Xray 一键部署脚本，底层调用 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 官方安装器。

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

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o /tmp/xr.sh && sudo bash /tmp/xr.sh
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
xr restart      # 重启
xr update       # 升级 Xray
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
| `FORCE=1` | 已有配置时强制重建 |

## License

MIT
