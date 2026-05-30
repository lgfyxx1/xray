# xray-reality

贴近官方的 Xray VLESS-Reality 一键部署脚本。底层调用 [XTLS/Xray-install](https://github.com/XTLS/Xray-install) 官方安装器（自带 SHA256 二进制校验），支持安装后 `xr` 命令管理节点。

## 一键安装（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o /tmp/xr.sh && sudo bash /tmp/xr.sh
```

> `bash <(curl ...)` 写法依赖 `/dev/fd`，部分 VPS/容器内核未挂载该路径会报错，请使用上面的下载再执行写法。

### 加固版（先校验 SHA256 再执行）

```bash
curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh -o /tmp/xr.sh
echo "$(curl -fsSL https://raw.githubusercontent.com/lgfyxx1/xray/main/xray-reality.sh | sha256sum | awk '{print $1}')  /tmp/xr.sh" | sha256sum -c -
sudo bash /tmp/xr.sh
```

## 安装后管理

安装成功后脚本自动把自身复制到 `/usr/local/bin/xr`，之后随时：

```bash
xr              # 等同于 xr info，显示节点信息 + 分享链接 + 二维码
xr info         # 显示节点信息
xr status       # Xray 服务状态
xr logs [N]     # 最近 N 条日志（默认 50）
xr update       # 升级 Xray 到最新稳定版
xr uninstall    # 卸载 Xray 并清除配置
```

## 可选环境变量

| 变量 | 说明 |
|---|---|
| `REALITY_PORT=443` | 指定端口（默认随机 30000-50000） |
| `REALITY_DEST=www.apple.com` | 指定伪装目标（默认自动测速选最快） |
| `REALITY_ADDR=1.2.3.4` | 分享链接里的服务器地址（默认自动获取公网 IP） |
| `REALITY_NAME=MyNode` | 节点名称（默认 `Reality-<addr>`） |
| `XRAY_VERSION=v26.3.27` | 固定 Xray 版本（默认装最新） |
| `XRAY_INSTALLER_SHA256=<hex>` | 钉住官方 install-release.sh SHA256（强烈建议） |
| `FORCE=1` | 已有配置时也强制重建 |

## 安全说明

- 底层调用 XTLS 官方 `install-release.sh`，自带 SHA256 dgst 校验二进制
- 全程 HTTPS + TLS 1.2+，不写 `~/.bashrc`，不安装 `jq`，不动 NTP
- Xray 以 `nobody` 运行（官方默认），配置文件 `600` 权限
- 分享链接中含 UUID/公钥，本地文件已设 `600`

## License

MIT
