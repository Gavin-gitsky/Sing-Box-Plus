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
| 🔐 访问控制 | HTTP Basic 账号密码 + 随机密钥路径（默认开启，**账号/密码/路径均随机生成**，链接形如 `http://<账号>:<密码>@IP:2088/<随机token>/clash`）|
| 🔒 TLS 真证书（可选） | 配一个域名+Cloudflare Token，一键签 Let's Encrypt 证书：订阅走 HTTPS，且 hy2/tuic/anytls 换真证书、**去 insecure**（消除 v2rayN 的中间人警告）|
| ⚙️ 订阅服务 | 内置 systemd 托管服务（python3），默认端口 **2088**，菜单里可改端口/账号/密钥路径 |
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
 9) TLS / 域名（真证书：订阅HTTPS + 节点）   ← 新增
 8) 卸载
 0) 退出
```

进入 `7)` 可：重新生成订阅 / 查看订阅链接 / 启动·重启·停止订阅服务 / 修改订阅端口 / 修改账号密码 / 重置密钥路径。

进入 `9)` 可：申请/更新证书、关闭 TLS（回退自签）。

> 💡 **快捷命令**：脚本首次运行会自动把自身软链到 `/usr/local/bin/singbox`，以后直接输入 `singbox` 就能打开本菜单（幂等，重复运行不重复装）。

> ⚠️ 记得把订阅端口（默认 2088/TCP）放行到云厂商「安全组」——脚本只能放行系统防火墙。

## 🔐 访问控制（默认开启）

订阅服务自带两层门，防止链接被人撞到/泄露后白嫖：

1. **HTTP Basic 账号密码**：**账号与密码均在首次安装时随机生成**（不是写死的，避免仓库里泄露用户名）；未带凭据一律 `401`。
2. **随机密钥路径**：所有订阅挂在 `http://IP:端口/<随机token>/...` 下，根路径直接 `404`，扫不到。

最终链接形如（客户端直接整条粘贴即可，账号密码在菜单 `2` 里直接给你）：

```
http://<账号>:<密码>@IP:2088/<token>/clash      # Clash / Mihomo
http://<账号>:<密码>@IP:2088/<token>/singbox   # sing-box
http://<账号>:<密码>@IP:2088/<token>/all       # v2rayN / 小火箭
```

> 账号/密码/密钥路径存在 `/opt/sing-box/sub.env`，随时可在 `7) 订阅链接` 菜单里改（改了需到各客户端更新订阅地址）。
> ⚠️ 链接本身就含密码，谁拿到谁能用——请勿外发；如需更稳，建议后面挂反代上 TLS。

## 🔒 TLS 真证书（可选，默认关闭）

默认用自签证书，节点里带 `insecure=1`/`skip-cert-verify`。若想彻底消除「不安全/中间人」警告，可一键切真证书（**需一个子域，且域名在 Cloudflare 托管**）：

1. 在 Cloudflare 给子域（如 `node.example.com`）加 A 记录 → 你的 VPS IP；
   > ⚠️ 该 A 记录必须是 **灰云（DNS only）**，开了小黄云（代理）会导致节点全断。
2. 备一个 CF API Token（权限 `Zone → DNS → Edit`，建法见下）——**这一步最容易踩坑**；
3. 主菜单 `9) TLS / 域名` → `1)` 填入域名/邮箱/Token → 自动用 acme.sh 走 **DNS-01** 签发 Let's Encrypt 证书（**不占 80/443**），并配好自动续期+重载。
   - 可顺带填「额外域名/SAN」（空格分隔），例如 `*.example.com node.example.com` —— 一张证书同时覆盖主域+子域；
   - 已经签过的，改 SAN 不用重填 Token：`9) → 3) 追加/修改 SAN 并重签`（复用 `tls.env` 里已存的 Token）；
   - `9)` 菜单顶部会直接显示**当前证书实际覆盖的域名列表**，方便核对。

效果（自动完成）：
- 订阅服务切 HTTPS；
- 8 个 TLS 节点（hy2 / hy2-obfs / tuic / anytls，直连+WARP）改用域名 + **去掉 insecure / skip-cert-verify**；
- 客户端需**重导一次**订阅。

> 域名/Token 存在 `/opt/sing-box/tls.env`（权限 600），不进仓库、不写死。想关掉走 `9) → 2)` 回退自签。

### 🔑 CF API Token 怎么建（照抄即可）

1. 登录 Cloudflare → 右上**头像** → `My Profile` → **`API Tokens`** → **`Create Token`**；
2. 选模板 **`Edit zone DNS`**（或 `Create Custom Token`），关键是这一行权限：
   - **Permissions：`Zone` → `DNS` → `Edit`**
3. **`Zone Resources`：`Include` → `Specific zone` → 选中你的域名**（这一步千万别漏，漏了就报 `Zone not found`）；
4. `Client IP Address Filtering`、`TTL` **全部留空**（填了的话换机器/换 IP 就失效）；
5. 建好后 **Token 只显示一次**，立刻复制保存。

**注意项（踩过坑的）**

- ❌ **不要用 Global API Key**（账号级密钥，不安全且 acme 的 `dns_cf` 不认它）；
- ❌ 粘贴时**别带前后空格 / 换行**（脚本已会自动去掉首尾空白，但尽量别粘错）；
- ⚠️ 域名必须**已托管在本 CF 账号**（NS 已切到 Cloudflare，可用 `dig NS 你的域名` 核对），否则拿不到该 zone；
- ⚠️ **DNS-01 不需要你手动配 `_acme-challenge` 的 TXT**，acme.sh 会自动加、签完自动删；
- ⚠️ 通配符要写成 **`*.example.com`**（`example.com` 本身要单独再写一个 `-d`，菜单里直接空格分隔两个即可）；
- ⚠️ **别同时写 `*.example.com` 和它的子域**（如 `node.example.com`）——Let's Encrypt 会报 `redundant with a wildcard domain`；本脚本**已自动去重**（识别到通配符就丢掉被它覆盖的子域），但填写时选一种更干净；
- ⚠️ 如果加了 SAN 只想改覆盖范围：`9) → 3)` 重签即可，**不用重新填 Token**；
- 🔁 证书到期前 acme.sh 会**自动续期并重载服务**，无需手动管。

**常见报错对照**

| 报错 | 原因 |
| --- | --- |
| `Invalid request headers` / `Unable to validate token` | Token 粘错/带空格、权限不对、或用了 Global API Key |
| `Zone not found` / `No zone found for ...` | `Zone Resources` 没选中该域名，或域名不在这个 CF 账号 |
| `Error add txt for domain` | 该域名不是本账号的 zone，或 Token 只有 Read 权限 |
| `redundant with a wildcard domain in the same request` | 一张证书里既写了 `*.example.com` 又写了它的子域（脚本已自动去重，不会再现） |

## 🧭 客户端分流（已内置，开箱即用）

订阅里已经带好了「国内直连 / 国外走节点」的分流，**客户端不用自己配规则**：

- **sing-box 订阅**：用 `geosite-cn` + `geoip-cn` 规则集，命中→`direct`；国内域名走国内 DNS，其余走代理 DNS
- **Clash / Mihomo 订阅**：用 `rule-providers`（`cn_domain` + `cn_ipcidr`，mrs 格式），命中→`DIRECT`；另含内网/保留地址直连
- **规则库由本机订阅服务直接分发**（`/<token>/rules/*`，该路径**免认证**，内容是公开的 geosite/geoip 列表）
  → 客户端**不需要翻墙去 GitHub 拉规则**，也不会因为拉不到规则而启动失败
- 规则每 7 天自动刷新一次（重新生成订阅时会检查）；也可手动：主菜单 `7) 订阅链接` → `8) 更新分流规则库并重生成订阅`
- 若规则库缺失（离线/下载失败）→ **自动退回简单分流**（`.cn` 域名 + 私有 IP 直连），不会让客户端配置失效

> 为什么不把「直连」判定放服务端：国内流量会先绕到 VPS 再“直连”，延迟/流量/隐私全亏，且变成海外 IP 访问国内站。所以——**“进不进代理”放客户端，“走哪个出口”放服务端**（WARP 出口就属于后者）。

**出口选择：一律手动，不做自动**
- 默认出口 = 「节点选择」里的**第一个具体节点**（不落到 `自动选择`），客户端里随时可切（含 `WARP节点`）
- 服务端**不会**自动挑节点、也不做“自动 WARP 分流”——选哪个走哪个，完全听你的
- 理由：`url-test` 按延迟挑出的节点，可能延迟低但带宽差；自己试过的节点最靠谱
- 想少一个选项：直接删掉订阅里的 `自动选择` / `直连节点` / `WARP节点` 三个分组名即可（不影响 20 个节点本体）

## 客户端导入

- **Clash / Mihomo**（Clash Verge、Mihomo Party、OpenClash…）：订阅地址填 `http://<账号>:<密码>@IP:2088/<token>/clash`
- **sing-box**（SFA / SFI / SFM / Hiddify…）：填 `http://<账号>:<密码>@IP:2088/<token>/singbox`
- **v2rayN / 小火箭 / Shadowrocket / v2rayNG**：填 `http://<账号>:<密码>@IP:2088/<token>/all`
- 想手动挑节点：打开 `http://<账号>:<密码>@IP:2088/<token>/` 逐个复制（浏览器会弹登录框）

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

- ~~Clash 订阅里 `GEOIP,CN,DIRECT` 需要客户端有 geoip 数据~~ → 已改为 `rule-providers`（mrs，由本机分发），**不再依赖客户端本地 geo 数据**；若规则库缺失则退回旧的 `GEOIP,CN` 写法。
- Hysteria2 / TUIC 用自签证书 → 订阅里默认 `skip-cert-verify: true`（与上游分享链接的 `insecure=1` 一致）。
- 订阅服务已内置 **Basic 认证 + 随机密钥路径**；若仍不放心，可再挂 Nginx/Caddy 加 TLS（见 Roadmap）。
- 端口 2088 仅用于**拉订阅**，与 20 个节点端口无冲突。

## Roadmap

- [x] 订阅路径 token 校验 + Basic 认证（已落地）
- [x] 订阅服务可选 HTTPS + 节点真证书（acme.sh DNS-01，已落地）
- [ ] 支持 Clash `rule-providers`（按需下载规则集，省内存）
- [ ] 换端口时自动同步 Cloudflare / 云安全组（API）
