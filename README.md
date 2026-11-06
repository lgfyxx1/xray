# Xray 节点安装与管理

基于 [XTLS/Xray-core](https://github.com/XTLS/Xray-core) 和未修改的 [官方 Xray-install](https://github.com/XTLS/Xray-install)。本仓库提供协议配置、证书、分享链接和管理菜单。

**v3.0.0 安全更新：** 修复 root 元数据命令注入、安装器验证、服务权限、证书安装和失败回滚。详见 [SECURITY.md](SECURITY.md)。截至 2026-11-06，官方最新稳定版为 **v26.10.31**；安装时实时查询官方最新稳定版，不允许低于这一安全基线。

## 系统与协议

支持 systemd、Bash 4+、Python 3 的现代 Linux，架构 x86_64 / aarch64。优先 Debian 12+、Ubuntu 22.04+；兼容提供对应依赖的 dnf/yum、zypper、pacman 系统。Alpine/OpenRC 和第三方面板不在支持范围。

| 协议 | 自有域名 | 客户端要求 |
|---|---|---|
| VLESS + RAW(TCP) + REALITY + Vision | 无需 | 支持 REALITY / Vision，默认推荐 |
| Shadowsocks + WS + TLS | 需要 | 支持 v2ray-plugin，不能按普通 SS 导入 |
| VLESS + WS + TLS | 需要 | 支持 WS/TLS |
| VLESS + gRPC + TLS | 需要 | 支持 gRPC/TLS |
| VMess + WS + TLS | 需要 | 支持 VMess/WS/TLS |
| VMess + gRPC + TLS | 需要 | 支持 VMess/gRPC/TLS |
| Trojan + WS + TLS | 需要 | 支持 Trojan/WS/TLS |
| Trojan + gRPC + TLS | 需要 | 支持 Trojan/gRPC/TLS |

本次保留原八种协议。WS/gRPC 仍受官方核心支持，但上游已提示逐步采用 XHTTP。客户端/CDN 须支持对应传输和端口；TLS 不保证流量不可识别。默认监听 IPv4，IPv6 专用主机需自行调整 listen 和防火墙。

## 安装与旧节点升级

下载到私有临时目录，查看脚本后用 root 执行：

```bash
XR_TMP=$(mktemp -d)
curl -q --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o "$XR_TMP/xr.sh" &&
  sudo bash "$XR_TMP/xr.sh" install
rm -rf "$XR_TMP"
```

首次安装显示协议菜单；已有本脚本节点会升级官方核心，保留原参数，并安装新版 xr。缺少本脚本元数据的配置会拒绝覆盖。不要用 FORCE=1 做普通升级。仓库更新不会自动改变运行中的 VPS，须在对应服务器执行上述步骤。

升级会重启节点。SSH 若经过该节点，请用独立 SSH 或云控制台执行。先备份 /usr/local/etc/xray，尤其是手工改过配置的节点；新配置会按本工具参数重建，手工字段不会保留。

安装器固定官方提交并强制验证 SHA256；核心只接受官方稳定 Release，强制验证其 SHA256，再交给官方安装器部署。不执行远程 shell 管道，不回退到未校验文件。

## 新建节点

以下示例先按上面的方式下载脚本，在删除临时目录前执行：

```bash
sudo env PROTOCOL=vless-reality REALITY_PORT=443 \
  REALITY_DEST=www.microsoft.com REALITY_NAME=MyNode \
  bash "$XR_TMP/xr.sh" install
```

REALITY 目标须适合该协议。默认会测量候选目标的 TLS 连接时间，仍需用实际客户端测试。未设置 REALITY_ADDR 时通过第三方公网 IP 服务探测；可显式设置避免探测。自行在云安全组开放节点 TCP 端口。

TLS 节点使用发行版 Certbot + Let's Encrypt。standalone 验证要求域名直接指向服务器、80/tcp 可达且签发时空闲；节点端口默认 443：

```bash
sudo env PROTOCOL=vless-ws-tls XRAY_DOMAIN=node.example.com \
  ACME_EMAIL=you@example.com bash "$XR_TMP/xr.sh" install
```

Cloudflare DNS 验证不占用 80 端口。使用仅对目标 Zone 有 DNS 编辑/读取权限的 Token，避免保存到 shell 历史：

```bash
read -rs -p 'Cloudflare API Token: ' CF_Token; echo
export CF_Token
sudo --preserve-env=CF_Token env PROTOCOL=vless-ws-tls XRAY_DOMAIN=node.example.com \
  ACME_EMAIL=you@example.com ACME_DNS=cloudflare \
  bash "$XR_TMP/xr.sh" install
unset CF_Token
```

DNS 插件自动安装支持已配置 apt/dnf/yum 软件源；包缺失则失败，不添加未知源。CF_Zone_ID/CF_Account_ID 不再需要。Token 位于 root 600 的 /etc/letsencrypt/xray-cloudflare.ini；节点配置/证书为 root:xray 640，服务用户不能修改。

## 旧 TLS 证书续期迁移

先升级核心，再迁移证书：

```bash
sudo env ACME_EMAIL=you@example.com xr migrate-cert
# DNS 模式另加 ACME_DNS=cloudflare 和 CF_Token
```

nginx 占用 80 时可加 ACME_STOP_SERVICES=nginx，签发时临时停止并在退出时恢复；自动续期使用相应 pre/post hooks。每天由 xray-cert-renew.timer 检查本域名，成功后刷新副本，并在节点运行时重启 Xray。

```bash
sudo systemctl status xray-cert-renew.timer
sudo certbot renew --cert-name node.example.com --dry-run
```

旧 acme.sh 的本域名配置在迁移成功后改为 .conf.removed，避免覆盖新证书；其他域名、账户和共享 cron 不自动删除。实际签发/续期依赖公网 DNS 与 CA，CI 不伪造成功。

## 管理命令

| 命令 | 功能 |
|---|---|
| sudo xr | 交互菜单 |
| sudo xr info | 信息、分享链接、终端二维码 |
| sudo xr status / sudo xr logs [N] | 状态 / 日志 |
| sudo xr restart | 检查配置后重启 |
| sudo xr update | 最新官方稳定核心，保留参数 |
| sudo xr migrate-cert | 旧 TLS 节点迁移 Certbot 续期 |
| sudo xr edit-port | 修改端口、检查占用 |
| sudo xr edit-uuid | 更新 UUID 或密码，须同步客户端 |
| sudo xr edit-dest | 修改 REALITY 目标/SNI |
| sudo xr edit-name | 修改名称，支持中文、空格 |
| sudo xr bbr / sudo xr enable-bbr | 查看 / 启用 BBR |
| sudo xr delete-node | 确认后删节点，保留核心 |
| sudo xr uninstall | 确认后用已校验官方安装器卸载 |

xr update 更新核心；更新管理脚本需重新下载本仓库脚本。默认不安排无人值守核心升级，避免不受控的协议兼容变化和断线。

## 环境变量

| 变量 | 用途 |
|---|---|
| PROTOCOL | 见 bash xray-reality.sh help 的协议标识 |
| REALITY_PORT | 1–65535，无前导零；TLS 默认443，REALITY 默认随机 |
| REALITY_DEST | REALITY 目标域名，目标端口443 |
| REALITY_ADDR | 分享地址；IPv4、IPv6 或域名 |
| REALITY_NAME | 节点名称 |
| XRAY_DOMAIN | TLS 域名 |
| XRAY_SS_METHOD | aes-256-gcm / aes-128-gcm / chacha20-poly1305 |
| XRAY_VERSION=v26.10.31 | 固定不低于安全基线的官方稳定版，留空取 latest |
| ACME_EMAIL | 真实证书联系邮箱 |
| ACME_DNS=cloudflare | DNS 验证 |
| CF_Token | Cloudflare API Token |
| ACME_STOP_SERVICES=nginx | standalone 临时停止服务，逗号分隔 |
| ENABLE_BBR=0 | 不修改拥塞控制；默认尝试启用已有 BBR |
| FORCE=1 | 明确重建并更换凭据，不用于普通升级 |

BBR 只用现有内核模块，不装第三方内核。不会自动开启 UFW 或改 SSH；已有活动 UFW/firewalld 会添加节点 TCP 规则，云安全组及 HTTP 验证用80/tcp 需自行放行。

## 验证与许可证

见 [安全审计及测试范围](SECURITY.md)。八种配置均由真实官方核心执行 run -test：

```bash
XRAY_TEST_BIN=/path/to/verified/official/xray python3 -m unittest discover -s tests -v
```

MIT。Xray-core、官方安装器、Certbot 分别遵循上游许可证。

