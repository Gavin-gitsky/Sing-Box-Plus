# Sing-Box-Plus · 订阅增强版（fork）

基于 [Alvin9999-newpac/Sing-Box-Plus](https://github.com/Alvin9999-newpac/Sing-Box-Plus) 的增强分支：
**在原脚本「按协议逐条打印分享链接」的基础上，新增 —— 一条链接导入全部 20 个节点。**

## 新增能力

| 能力 | 说明 |
|---|---|
| 🧩 Clash / Mihomo 订阅 | `http://IP:2088/clash` — 20 节点 + 5 个策略组 + CN 分流 + CN DoH 兜底 DNS |
| 🧩 sing-box 订阅 | `http://IP:2088/singbox` — 客户端配置，20 outbounds + selector/urltest + 规则 |
| 📦 通用聚合订阅 | `http://IP:2088/all` — 全部 20 条链接的 base64（v2rayN / 小火箭 / Shadowrocket 直接导入） |
| 🖥 聚合页 | `http://IP:2088/` — 一个页面列出全部 20 条链接 + 三个订阅地址，点一下复制 |
| 🧷 分组订阅 | `/direct`（仅直连 10）、`/warp`（仅 WARP 10）、`/links.txt`（明文） |
| ⚙️ 订阅服务 | 内置 systemd 托管静态服务（python3 优先，busybox 兜底），默认端口 **2088**，可在菜单里改 |
| 🔄 自动同步 | 安装完成 / 一键换端口后，订阅自动重新生成 |

> 上游原有的 20 个节点（直连 10 + WARP 10：VLESS Reality / VLESS gRPC Reality / Trojan Reality /
> VMess WS / Hysteria2 / Hysteria2+OBFS / SS2022 / SS / TUIC v5 / AnyTLS）与「逐条分享链接」功能**完全保留**。

## 使用

```bash
# 直连（VPS 在境外一般没问题）
wget -O sing-box-plus.sh https://raw.githubusercontent.com/Gavin-gitsky/Sing-Box-Plus/main/sing-box-plus.sh
chmod +x sing-box-plus.sh && bash sing-box-plus.sh
```

> 国内服务器拉不动 raw.githubusercontent.com 的话，换镜像：
> ```bash
> wget -O sing-box-plus.sh https://gh-proxy.com/https://raw.githubusercontent.com/Gavin-gitsky/Sing-Box-Plus/main/sing-box-plus.sh
> chmod +x sing-box-plus.sh && bash sing-box-plus.sh
> ```
> 或直接从 [Releases](https://github.com/Gavin-gitsky/Sing-Box-Plus/releases/latest) 下载 `sing-box-plus.sh` 再上传到服务器。

```
 1) 安装/部署（20 节点）      ← 装完自动生成订阅并启动订阅服务
 2) 查看分享链接（IPv4）
 6) 查看分享链接（IPv6）
 3) 重启服务
 4) 一键更换所有端口          ← 换完自动重生成订阅
 5) 一键开启 BBR
 7) 订阅链接（Clash / sing-box / 聚合）   ← 新增
 8) 卸载
 0) 退出
```

进入 `7)` 可：重新生成订阅 / 查看订阅链接 / 启动·重启·停止订阅服务 / 修改订阅端口。

> ⚠️ 记得把订阅端口（默认 2088/TCP）放行到云厂商「安全组」——脚本只能放行系统防火墙。

## 客户端导入

- **Clash / Mihomo**（Clash Verge、Mihomo Party、OpenClash…）：订阅地址填 `http://IP:2088/clash`
- **sing-box**（SFA / SFI / SFM / Hiddify…）：填 `http://IP:2088/singbox`
- **v2rayN / 小火箭 / Shadowrocket / v2rayNG**：填 `http://IP:2088/all`
- 想手动挑节点：打开 `http://IP:2088/` 逐个复制

## 与上游保持同步

订阅模块与主脚本解耦，上游更新后一条命令重新打补丁：

```bash
curl -fsSL -o upstream-orig.sh \
  https://raw.githubusercontent.com/Alvin9999-newpac/Sing-Box-Plus/main/sing-box-plus.sh
python3 tools/apply_sub_patch.py upstream-orig.sh tools/sub_block.sh sing-box-plus.sh
```

## 本地自测（无需 VPS / root）

```bash
bash tools/selftest.sh
```

会造一套假凭据 → 生成三份订阅 → 校验 YAML/JSON 结构 + 引用完整性 →
（若本机有 mihomo）用 `mihomo -t` 对生成的 Clash 配置做真实体检。

## 已知说明

- Clash 订阅里 `GEOIP,CN,DIRECT` 需要客户端有 geoip 数据（mihomo 会自动下载；国内网络建议配好代理后再拉）。
- Hysteria2 / TUIC 用自签证书 → 订阅里默认 `skip-cert-verify: true`（与上游分享链接的 `insecure=1` 一致）。
- 订阅服务是**明文 HTTP**。公网裸奔的订阅地址 = 谁拿到谁用，建议：
  1. 改个不显眼的端口；2. 或在前面挂 Nginx/Caddy 加路径密钥与 TLS。
  （后续可加 `?token=` 校验，见 Roadmap）
- 端口 2088 仅用于**拉订阅**，与 20 个节点端口无冲突。

## Roadmap

- [ ] 订阅路径 token 校验（`/clash?t=xxxx`）
- [ ] 订阅服务可选 HTTPS（Caddy 自动证书）
- [ ] 支持 Clash `rule-providers`（按需下载规则集，省内存）
- [ ] 换端口时自动同步 Cloudflare / 云安全组（API）
