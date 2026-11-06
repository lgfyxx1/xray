# 安全审计与维护

审计基线：原 main 提交 `d57d17ea9fab5895157031167692691fdf231b5d`，2026-11-06。
已阅读仓库全部两个文件。未发现明确的凭据回传、隐藏用户或挖矿代码；这不等于证明历史服务器未被修改。

## 已修正的问题

| 问题 | 影响 | 修正 |
|---|---|---|
| 节点名称原样写入 `.meta.env`，再由 root source | 命令替换可能执行；空格也会破坏加载 | JSON 保存；旧文件仅当作数据解析，不执行 |
| 安装器从可变 main 下载，SHA256 可选；卸载不校验 | 未经审查的上游脚本直接获得 root 权限 | 固定官方提交和必需 SHA256，安装卸载共用校验 |
| 已有核心就跳过安装 | 重复运行也可能继续使用旧核心 | 每次查询最新官方稳定版，固定版本不得低于安全基线 |
| 配置和私钥归 nobody 所有 | 共享账号可改配置；新版官方 xray 用户无法读取 | root:xray、目录 750、配置/证书 640；元数据/链接 root 600 |
| curl get.acme.sh 管道执行，并拼接 shell 账户配置 | 不固定版本的远程 root 代码；拼接不安全 | 使用发行版 Certbot/DNS 插件；Token 独立 root 600 文件 |
| ACME 备用签发条件链错误 | 注册成功会短路，可能跳过签发却继续安装证书 | 删除错误流程，失败即退出；退出/信号时恢复停下的服务 |
| 直接覆盖配置并重启 | 配置错误导致断网且难以恢复 | 候选核心预检、新配置 run -test、失败恢复核心/配置/服务文件 |
| UFW 检查 active 也匹配 inactive | 错误处理未启用的防火墙 | 精确匹配状态行 |
| 手工拼接 JSON/URI | 名称等输入造成无效配置或链接 | JSON 序列化、URI 编码及结构校验 |
| AsIs 路由仅阻止字面私网 IP | 域名解析后可能访问内网/元数据 | IPOnDemand 加私网、loopback、链路本地和 CGNAT 阻断 |
| 无并发写入锁，服务权限过大 | 更新冲突、服务被攻破后影响扩大 | flock、私有临时目录、原子替换、专用用户和 systemd 沙箱 |

## 官方基线

- 核心：[v26.10.31](https://github.com/XTLS/Xray-core/releases/tag/v26.10.31)，包含 MPTCP 紧急安全修复；服务器仍需通过发行版更新 Linux 内核。
- 安装器：[固定提交](https://github.com/XTLS/Xray-install/blob/04e6f3bd9534811ed901a48c47b2c042dd64eb3a/install-release.sh)，SHA256 `934ecb26ded1089f849ac238d5170f1159fe4b6ca300d4f1e67730bd41fe58cf`。
- 核心 ZIP 必须匹配官方 GitHub Release API 的 SHA256，再交给未修改的官方安装器 `--local` 安装。不回退到镜像、测试版或未验证下载。
- 校验和与文件来自同一 GitHub 信任边界，不代表独立签名或防护上游账户失陷。
- 不安排无人值守核心升级；升级会重启节点。SSH 若经过该节点，请先准备独立通道。

## 迁移与边界

新版 install/update 保留协议、端口、UUID、密码和 Reality 密钥，旧元数据仅作为数据读取并转为 JSON，修正用户/权限，按本工具参数重建配置。手工追加字段不会保留，需先备份人工合并。

旧 TLS 节点升级核心时保留有效证书；随后带邮箱和相应 DNS 凭据执行 migrate-cert。迁移成功后只把指向本节点 SSL 目录的旧 acme.sh 域名配置改为 `.conf.removed`，避免两个客户端互相覆盖。不会执行旧 acme.sh、删除其他域名或共享 cron。

回滚范围为核心、节点目录和单实例服务文件；证书签发账户/记录、发行版包和防火墙规则不属于该范围。卸载保留 Certbot 签发记录和旧 acme.sh 备份。共享的发行版定时器仍可能尝试续期；确认无其他使用方后可用 `certbot delete --cert-name <域名>` 清理。

回滚处理正常错误、配置/启动检查失败及 INT/TERM，不保证断电、磁盘故障、SIGKILL 后自动恢复。仅维护标准单实例 xray.service，拒绝运行中的多实例和非本脚本配置。没有远程服务器访问时，仓库检查不能验证已部署主机、内核或真实链路。应用层私网阻断仍应配合云网络隔离。

## 验证

```bash
bash -n xray-reality.sh tests/linux-smoke.sh
shellcheck xray-reality.sh tests/linux-smoke.sh
XRAY_TEST_BIN=/path/to/verified/official/xray python3 -m unittest discover -s tests -v
```

回归覆盖元数据命令注入、JSON 迁移、非法字段/控制字符/端口/域名、Unicode/IPv6 链接、稳定版/下载源限制及校验失败。八种协议由真实官方核心执行 run -test，测试证书仅在临时目录生成。

GitHub Actions 在 Ubuntu 22.04/24.04 执行检查，并在临时 Ubuntu 24.04 runner 实际调用官方安装器，验证 systemd、用户/文件权限、REALITY/Vision 客户端代理访问公网 HTTPS、故障回滚和重复升级保留凭据。CI 不签发公网证书，也不代表八种客户端/CDN 的端到端兼容性测试。
