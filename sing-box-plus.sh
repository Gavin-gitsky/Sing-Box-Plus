#!/usr/bin/env bash
# ============================================================
#  Sing-Box-Plus 管理脚本（20 节点：直连 10 + WARP 10）
#  Version: v4.8.0
#  author：Alvin9999
#  Repo: https://github.com/Alvin9999-newpac/Sing-Box-Plus
# ============================================================

set -Eeuo pipefail

stty erase ^H # 让退格键在终端里正常工作
# ===== [BEGIN] SBP 引导模块 v2.2.0+（包管理器优先 + 二进制回退） =====
# 模式与哨兵
: "${SBP_SOFT:=0}"                               # 1=宽松模式（失败尽量继续），默认 0=严格
: "${SBP_SKIP_DEPS:=0}"                          # 1=启动跳过依赖检查（只在菜单 1) 再装）
: "${SBP_FORCE_DEPS:=0}"                         # 1=强制重新安装依赖
: "${SBP_BIN_ONLY:=0}"                           # 1=强制走二进制模式，不用包管理器
: "${SBP_ROOT:=/var/lib/sing-box-plus}"
: "${SBP_BIN_DIR:=${SBP_ROOT}/bin}"
: "${SBP_DEPS_SENTINEL:=/var/lib/sing-box-plus/.deps_ok}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

# 工具：下载器 + 轻量重试
dl() { # 用法：dl <URL> <OUT_PATH>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    timeout 15 wget -qO "$out" --tries=2 "$url"
  else
    echo "[ERROR] 缺少 curl/wget：无法下载 $url"; return 1
  fi
}
with_retry() { local n=${1:-3}; shift; local i=1; until "$@"; do [ $i -ge "$n" ] && return 1; sleep $((i*2)); i=$((i+1)); done; }

# 工具：架构探测 + jq 静态兜底
detect_goarch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686)    echo 386   ;;
    *)            echo amd64 ;;
  esac
}
ensure_jq_static() {
  command -v jq >/dev/null 2>&1 && return 0
  local arch out="$SBP_BIN_DIR/jq" url alt
  arch="$(detect_goarch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  alt="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  dl "$url" "$out" || { [ "$arch" = amd64 ] && dl "$alt" "$out" || true; }
  chmod +x "$out" 2>/dev/null || true
  command -v jq >/dev/null 2>&1
}

# 工具：核心命令自检
sbp_core_ok() {
  local need=(curl jq tar unzip openssl)
  local b; for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || return 1; done
  return 0
}

# —— 包管理器路径 —— #
sbp_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf      >/dev/null 2>&1; then PM=dnf
  elif command -v yum      >/dev/null 2>&1; then PM=yum
  elif command -v pacman   >/dev/null 2>&1; then PM=pacman
  elif command -v zypper   >/dev/null 2>&1; then PM=zypper
  else PM=unknown; fi
  [ "$PM" = unknown ] && return 1 || return 0
}

# apt 允许发行信息变化（stable→oldstable / Version 变化）
apt_allow_release_change() {
  cat >/etc/apt/apt.conf.d/99allow-releaseinfo-change <<'CONF'
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Version "true";
CONF
}

# 刷新软件仓（含各系兜底）
sbp_pm_refresh() {
  case "$PM" in
    apt)
      apt_allow_release_change
      [[ -f /etc/apt/sources.list ]] && sed -i 's#^deb http://#deb https://#' /etc/apt/sources.list 2>/dev/null || true
      # 修正 bullseye 的 security 行：bullseye/updates → debian-security bullseye-security
      [[ -f /etc/apt/sources.list ]] && sed -i -E 's#^(deb\s+https?://security\.debian\.org)(/debian-security)?\s+bullseye/updates(.*)$#\1/debian-security bullseye-security\3#' /etc/apt/sources.list || true

      local AOPT=""
      curl -6 -fsS --connect-timeout 2 https://deb.debian.org >/dev/null 2>&1 || AOPT='-o Acquire::ForceIPv4=true'

      if ! with_retry 3 apt-get update -y $AOPT; then
        # backports 404 临时注释再试
        sed -i 's#^\([[:space:]]*deb .* bullseye-backports.*\)#\# \1#' /etc/apt/sources.list 2>/dev/null || true
        with_retry 2 apt-get update -y $AOPT -o Acquire::Check-Valid-Until=false || [ "$SBP_SOFT" = 1 ]
      fi
      ;;
    dnf)
      dnf clean metadata || true
      with_retry 3 dnf makecache || [ "$SBP_SOFT" = 1 ]
      ;;
    yum)
      yum clean all || true
      with_retry 3 yum makecache fast || true
      yum install -y epel-release || true   # EL7/老环境便于装 jq 等
      ;;
    pacman)
      pacman-key --init >/dev/null 2>&1 || true
      pacman-key --populate archlinux >/dev/null 2>&1 || true
      with_retry 3 pacman -Syy --noconfirm || [ "$SBP_SOFT" = 1 ]
      ;;
    zypper)
      zypper -n ref || zypper -n ref --force || true
      ;;
  esac
}

# 逐包安装（单个失败不拖累整体）
sbp_pm_install() {
  case "$PM" in
    apt)
      local p; apt-get update -y >/dev/null 2>&1 || true
      for p in "$@"; do apt-get install -y --no-install-recommends "$p" || true; done
      ;;
    dnf)
      local p; for p in "$@"; do dnf install -y "$p" || true; done
      ;;
    yum)
      yum install -y epel-release || true
      local p; for p in "$@"; do yum install -y "$p" || true; done
      ;;
    pacman)
      pacman -Sy --noconfirm || [ "$SBP_SOFT" = 1 ]
      local p; for p in "$@"; do pacman -S --noconfirm --needed "$p" || true; done
      ;;
    zypper)
      zypper -n ref || true
      local p; for p in "$@"; do zypper --non-interactive install "$p" || true; done
      ;;
  esac
}

# 用包管理器装一轮依赖
sbp_install_prereqs_pm() {
  sbp_detect_pm || return 1
  sbp_pm_refresh

  case "$PM" in
    apt)    CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz-utils uuid-runtime iproute2 iptables ufw) ;;
    dnf|yum)CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute iptables iptables-nft firewalld) ;;
    pacman) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables) ;;
    zypper) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables firewalld) ;;
    *) return 1 ;;
  esac

  sbp_pm_install "${CORE[@]}" "${EXTRA[@]}"

  # jq 兜底：安装失败时下载静态 jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "[INFO] 通过包管理器安装 jq 失败，尝试下载静态 jq ..."
    ensure_jq_static || { echo "[ERROR] 无法获取 jq"; return 1; }
  fi

  # 严格模式：核心仍缺则失败
  if ! sbp_core_ok; then
    [ "$SBP_SOFT" = 1 ] || return 1
    echo "[WARN] 核心依赖未就绪（宽松模式继续）"
  fi
  return 0
}

# —— 二进制模式：直接获取 sing-box 可执行文件 —— #
install_singbox_binary() {
  local arch goarch pkg tmp json url fn
  goarch="$(detect_goarch)"
  tmp="$(mktemp -d)" || return 1

  ensure_jq_static || { echo "[ERROR] 无法获取 jq，二进制模式失败"; rm -rf "$tmp"; return 1; }
json="$(with_retry 3 curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/tags/v1.13.7)" || { rm -rf "$tmp"; return 1; }
  url="$(printf '%s' "$json" | jq -r --arg a "$goarch" '
    .assets[] | select(.name|test("linux-" + $a + "\\.(tar\\.(xz|gz)|zip)$")) | .browser_download_url
  ' | head -n1)"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[ERROR] 未找到匹配架构($goarch)的 sing-box 资产"; rm -rf "$tmp"; return 1
  fi

  pkg="$tmp/pkg"
  with_retry 3 dl "$url" "$pkg" || { rm -rf "$tmp"; return 1; }

  case "$url" in
    *.tar.xz)  if command -v xz >/dev/null 2>&1; then tar -xJf "$pkg" -C "$tmp"; else echo "[ERROR] 缺少 xz；请安装 xz/xz-utils 或换 .tar.gz/.zip"; rm -rf "$tmp"; return 1; fi ;;
    *.tar.gz)  tar -xzf "$pkg" -C "$tmp" ;;
    *.zip)     unzip -q "$pkg" -d "$tmp" || { echo "[ERROR] 缺少 unzip"; rm -rf "$tmp"; return 1; } ;;
    *)         echo "[ERROR] 未知包格式：$url"; rm -rf "$tmp"; return 1 ;;
  esac

  fn="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [ -n "$fn" ] || { echo "[ERROR] 包内未找到 sing-box"; rm -rf "$tmp"; return 1; }

  install -m 0755 "$fn" "$SBP_BIN_DIR/sing-box" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "[OK] 已安装 sing-box 到 $SBP_BIN_DIR/sing-box"
}

# 证书兜底（有 openssl 就生成；没有就先跳过，由业务决定是否强制）
ensure_tls_cert() {
  local dir="$SBP_ROOT"
  mkdir -p "$dir"
  if command -v openssl >/dev/null 2>&1; then
    [[ -f "$dir/private.key" ]] || openssl ecparam -genkey -name prime256v1 -out "$dir/private.key" >/dev/null 2>&1
    [[ -f "$dir/cert.pem"    ]] || openssl req -new -x509 -days 36500 -key "$dir/private.key" -out "$dir/cert.pem" -subj "/CN=www.bing.com" >/dev/null 2>&1
  fi
}

# 标记哨兵
sbp_mark_deps_ok() {
  if sbp_core_ok; then
    mkdir -p "$(dirname "$SBP_DEPS_SENTINEL")" && : > "$SBP_DEPS_SENTINEL" || true
  fi
}

# 入口：装依赖 / 二进制回退
sbp_bootstrap() {
  [ "$EUID" -eq 0 ] || { echo "请以 root 运行（或 sudo）"; exit 1; }

  if [ "$SBP_SKIP_DEPS" = 1 ]; then
    echo "[INFO] 已跳过启动时依赖检查（SBP_SKIP_DEPS=1）"
    return 0
  fi

  # 已就绪则跳过
  if [ "$SBP_FORCE_DEPS" != 1 ] && sbp_core_ok && [ -f "$SBP_DEPS_SENTINEL" ] && [ "$SBP_BIN_ONLY" != 1 ]; then
    echo "依赖已安装"
    return 0
  fi

  # 强制二进制模式
  if [ "$SBP_BIN_ONLY" = 1 ]; then
    echo "[INFO] 二进制模式（SBP_BIN_ONLY=1）"
    install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
    ensure_tls_cert
    return 0
  fi

  # 包管理器优先
  if sbp_install_prereqs_pm; then
    sbp_mark_deps_ok
    return 0
  fi

  # 回退到二进制模式
  echo "[WARN] 包管理器依赖安装失败，切换到二进制模式"
  install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
  ensure_tls_cert
}
# ===== [END] SBP 引导模块 v2.2.0+ =====


# ===== 提前设默认，避免 set -u 早期引用未定义变量导致脚本直接退出 =====
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DATA_DIR=${DATA_DIR:-$SB_DIR/data}
CERT_DIR=${CERT_DIR:-$SB_DIR/cert}
WGCF_DIR=${WGCF_DIR:-$SB_DIR/wgcf}

# 功能开关（保持稳定默认）
ENABLE_WARP=${ENABLE_WARP:-true}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
ENABLE_VLESS_GRPCR=${ENABLE_VLESS_GRPCR:-true}
ENABLE_TROJAN_REALITY=${ENABLE_TROJAN_REALITY:-true}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
ENABLE_HY2_OBFS=${ENABLE_HY2_OBFS:-true}
ENABLE_SS2022=${ENABLE_SS2022:-true}
ENABLE_SS=${ENABLE_SS:-true}
ENABLE_TUIC=${ENABLE_TUIC:-true}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-true}

# 常量
SCRIPT_NAME="Sing-Box-Plus 管理脚本"
SCRIPT_VERSION="v4.8.0"
REALITY_SERVER=${REALITY_SERVER:-www.microsoft.com}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT:-443}
# REALITY 偷域名池：每个 reality inbound 安装时各自随机抽一个，抽中后写入 creds.env 持久化，
# 重启/重装不会变（不会让旧客户端链接失效）。空格分隔，全部需满足 TLS1.3 + H2、不重定向、未被墙。
REALITY_SERVERS=${REALITY_SERVERS:-"swift.org yahoo.com www.yahoo.com addons.mozilla.org lovelive-anime.jp www.lovelive-anime.jp one-piece.com www.one-piece.com www.microsoft.com www.apple.com gateway.icloud.com"}
GRPC_SERVICE=${GRPC_SERVICE:-grpc}
VMESS_WS_PATH=${VMESS_WS_PATH:-/vm}

# 兼容 sing-box 1.12.x 的旧 wireguard 出站
export ENABLE_DEPRECATED_WIREGUARD_OUTBOUND=${ENABLE_DEPRECATED_WIREGUARD_OUTBOUND:-true}

# ===== 颜色 =====
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_RED="\033[31m";  C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_MAGENTA="\033[35m"
hr(){ printf "${C_DIM}=============================================================${C_RESET}\n"; }

# ===== 基础工具 =====
info(){ echo -e "[${C_CYAN}信息${C_RESET}] $*"; }
ok(){   echo -e "[${C_GREEN}成功${C_RESET}] $*"; }
warn(){ echo -e "[${C_YELLOW}警告${C_RESET}] $*"; }
err(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; }
die(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; exit 1; }

# --- 架构映射：uname -m -> 发行资产名 ---
arch_map() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l)       echo "armv7" ;;   # 上游无 armv6，回退 armv7
    i386|i686)    echo "386"  ;;
    *)            echo "amd64" ;;
  esac
}

# --- 依赖安装：兼容 apt / yum / dnf / apk / pacman / zypper ---
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  ((${#miss[@]}==0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" || apt-get install -y --no-install-recommends "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${miss[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${miss[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${miss[@]}"
  else
    err "无法自动安装依赖：${miss[*]}，请手动安装后重试"
    return 1
  fi
}

b64enc(){ base64 -w 0 2>/dev/null || base64; }
urlenc(){ # 纯 bash urlencode（不依赖 python）
  local s="$1" out="" c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out "%s%%%02X" "$out" "'$c" ;;
    esac
  done
  printf "%s" "$out"
}

safe_source_env(){ # 安全 source，忽略不存在文件
  local f="$1"; [[ -f "$f" ]] || return 1
  set +u; # 避免未定义变量报错
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

# 避免 `cmd | grep -q` 在 pipefail 下“假失败”：grep -q 一命中就退出 → 上游收到 SIGPIPE(141) → 管道整体算失败
pipe_has(){ # 用法: cmd | pipe_has "正则"
  local pat="$1" buf
  buf=$(cat)
  [[ "$buf" =~ $pat ]]
}

# 端口是否在 LISTEN（ss/netstat，精确匹配端口号，避免 :4000 误命中 :40000；不走管道）
port_listening(){
  local p="${1:-}" out=""
  [[ -n "$p" ]] || return 1
  out=$(ss -lntp 2>/dev/null || true)
  [[ -z "$out" ]] && out=$(netstat -lntp 2>/dev/null || true)
  [[ "$out" =~ :${p}([^0-9]|$) ]]
}

get_ip4(){ # 多源获取公网 IPv4
  local ip
  ip=$(curl -4 -fsSL ipv4.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-127.0.0.1}"
}

get_ip6(){ # 多源获取公网 IPv6（无 IPv6 则返回空）
  local ip
  ip=$(curl -6 -fsSL ipv6.icanhazip.com 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -6 -fsSL ip.sb 2>/dev/null || true)
  echo "${ip:-}"
}

# 兼容旧调用：默认返回 IPv4
get_ip(){ get_ip4; }

# URI/分享链接里：IPv6 需要用 [addr] 包起来
fmt_host_for_uri(){
  local ip="$1"
  [[ "$ip" == *:* ]] && printf '[%s]' "$ip" || printf '%s' "$ip"
}

is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; }

ensure_dirs(){ mkdir -p "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$WGCF_DIR"; }

# ===== 端口（20 个互不重复） =====
PORTS=()
gen_port() {
  while :; do
    p=$(( ( RANDOM % 55536 ) + 10000 ))
    [[ $p -le 65535 ]] || continue
    [[ " ${PORTS[*]-} " != *" $p "* ]] && { PORTS+=("$p"); echo "$p"; return; }
  done
}
rand_ports_reset(){ PORTS=(); }

PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

save_ports(){ cat > "$SB_DIR/ports.env" <<EOF
PORT_VLESSR=$PORT_VLESSR
PORT_VLESS_GRPCR=$PORT_VLESS_GRPCR
PORT_TROJANR=$PORT_TROJANR
PORT_HY2=$PORT_HY2
PORT_VMESS_WS=$PORT_VMESS_WS
PORT_HY2_OBFS=$PORT_HY2_OBFS
PORT_SS2022=$PORT_SS2022
PORT_SS=$PORT_SS
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_VLESSR_W=$PORT_VLESSR_W
PORT_VLESS_GRPCR_W=$PORT_VLESS_GRPCR_W
PORT_TROJANR_W=$PORT_TROJANR_W
PORT_HY2_W=$PORT_HY2_W
PORT_VMESS_WS_W=$PORT_VMESS_WS_W
PORT_HY2_OBFS_W=$PORT_HY2_OBFS_W
PORT_SS2022_W=$PORT_SS2022_W
PORT_SS_W=$PORT_SS_W
PORT_TUIC_W=$PORT_TUIC_W
PORT_ANYTLS_W=$PORT_ANYTLS_W
EOF
}
load_ports(){ safe_source_env "$SB_DIR/ports.env" || return 1; }

save_all_ports(){
  rand_ports_reset
  for v in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
           PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
    [[ -n "${!v:-}" ]] && PORTS+=("${!v}")
  done
  [[ -z "${PORT_VLESSR:-}" ]] && PORT_VLESSR=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR:-}" ]] && PORT_VLESS_GRPCR=$(gen_port)
  [[ -z "${PORT_TROJANR:-}" ]] && PORT_TROJANR=$(gen_port)
  [[ -z "${PORT_HY2:-}" ]] && PORT_HY2=$(gen_port)
  [[ -z "${PORT_VMESS_WS:-}" ]] && PORT_VMESS_WS=$(gen_port)
  [[ -z "${PORT_HY2_OBFS:-}" ]] && PORT_HY2_OBFS=$(gen_port)
  [[ -z "${PORT_SS2022:-}" ]] && PORT_SS2022=$(gen_port)
  [[ -z "${PORT_SS:-}" ]] && PORT_SS=$(gen_port)
  [[ -z "${PORT_TUIC:-}" ]] && PORT_TUIC=$(gen_port)
  [[ -z "${PORT_ANYTLS:-}" ]] && PORT_ANYTLS=$(gen_port)
  [[ -z "${PORT_VLESSR_W:-}" ]] && PORT_VLESSR_W=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR_W:-}" ]] && PORT_VLESS_GRPCR_W=$(gen_port)
  [[ -z "${PORT_TROJANR_W:-}" ]] && PORT_TROJANR_W=$(gen_port)
  [[ -z "${PORT_HY2_W:-}" ]] && PORT_HY2_W=$(gen_port)
  [[ -z "${PORT_VMESS_WS_W:-}" ]] && PORT_VMESS_WS_W=$(gen_port)
  [[ -z "${PORT_HY2_OBFS_W:-}" ]] && PORT_HY2_OBFS_W=$(gen_port) || true
  [[ -z "${PORT_SS2022_W:-}" ]] && PORT_SS2022_W=$(gen_port)
  [[ -z "${PORT_SS_W:-}" ]] && PORT_SS_W=$(gen_port)
  [[ -z "${PORT_TUIC_W:-}" ]] && PORT_TUIC_W=$(gen_port)
  [[ -z "${PORT_ANYTLS_W:-}" ]] && PORT_ANYTLS_W=$(gen_port)
  save_ports
}

# ===== env / creds / warp =====
save_env(){ cat > "$SB_DIR/env.conf" <<EOF
BIN_PATH=$BIN_PATH
ENABLE_VLESS_REALITY=$ENABLE_VLESS_REALITY
ENABLE_VLESS_GRPCR=$ENABLE_VLESS_GRPCR
ENABLE_TROJAN_REALITY=$ENABLE_TROJAN_REALITY
ENABLE_HYSTERIA2=$ENABLE_HYSTERIA2
ENABLE_VMESS_WS=$ENABLE_VMESS_WS
ENABLE_HY2_OBFS=$ENABLE_HY2_OBFS
ENABLE_SS2022=$ENABLE_SS2022
ENABLE_SS=$ENABLE_SS
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_WARP=$ENABLE_WARP
REALITY_SERVER=$REALITY_SERVER
REALITY_SERVER_PORT=$REALITY_SERVER_PORT
GRPC_SERVICE=$GRPC_SERVICE
VMESS_WS_PATH=$VMESS_WS_PATH
EOF
}
load_env(){ safe_source_env "$SB_DIR/env.conf" || true; }

save_creds(){ cat > "$SB_DIR/creds.env" <<EOF
UUID=$UUID
HY2_PWD=$HY2_PWD
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SID=$REALITY_SID
HY2_PWD2=$HY2_PWD2
HY2_OBFS_PWD=$HY2_OBFS_PWD
SS2022_KEY=$SS2022_KEY
SS_PWD=$SS_PWD
TUIC_UUID=$TUIC_UUID
TUIC_PWD=$TUIC_PWD
ANYTLS_PWD=$ANYTLS_PWD
RS_VR=$RS_VR
RS_GR=$RS_GR
RS_TR=$RS_TR
RS_VRW=$RS_VRW
RS_GRW=$RS_GRW
RS_TRW=$RS_TRW
EOF
}
load_creds(){ safe_source_env "$SB_DIR/creds.env" || return 1; }

save_warp(){ cat > "$SB_DIR/warp.env" <<EOF
WARP_PRIVATE_KEY=$WARP_PRIVATE_KEY
WARP_PEER_PUBLIC_KEY=$WARP_PEER_PUBLIC_KEY
WARP_ENDPOINT_HOST=$WARP_ENDPOINT_HOST
WARP_ENDPOINT_PORT=$WARP_ENDPOINT_PORT
WARP_ADDRESS_V4=$WARP_ADDRESS_V4
WARP_ADDRESS_V6=$WARP_ADDRESS_V6
WARP_RESERVED_1=$WARP_RESERVED_1
WARP_RESERVED_2=$WARP_RESERVED_2
WARP_RESERVED_3=$WARP_RESERVED_3
EOF
}
load_warp(){ safe_source_env "$SB_DIR/warp.env" || return 1; }

# 生成 8 字节十六进制（16 个 hex 字符）
rand_hex8(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 | tr -d "\n"
  else
    # 兜底：没有 openssl 时用 hexdump
    hexdump -v -n 8 -e '1/1 "%02x"' /dev/urandom
  fi
}
rand_b64_32(){ openssl rand -base64 32 | tr -d "\n"; }

# 从 REALITY_SERVERS 池里随机抽一个域名（池为空则回退到 REALITY_SERVER）
pick_reality(){
  local arr=($REALITY_SERVERS); local n=${#arr[@]}
  (( n == 0 )) && { printf '%s' "$REALITY_SERVER"; return; }
  printf '%s' "${arr[$((RANDOM % n))]}"
}

gen_uuid(){
  local u=""
  if [[ -x "$BIN_PATH" ]]; then u=$("$BIN_PATH" generate uuid 2>/dev/null | head -n1); fi
  if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen | head -n1); fi
  if [[ -z "$u" ]]; then u=$(cat /proc/sys/kernel/random/uuid | head -n1); fi
  printf '%s' "$u" | tr -d '\r\n'
}
gen_reality(){ "$BIN_PATH" generate reality-keypair; }

mk_cert(){
  local crt="$CERT_DIR/fullchain.pem" key="$CERT_DIR/key.pem"
  if [[ ! -s "$crt" || ! -s "$key" ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout "$key" -out "$crt" -subj "/CN=$REALITY_SERVER" \
      -addext "subjectAltName=DNS:$REALITY_SERVER" >/dev/null 2>&1
  fi
CRT_SHA256=$(openssl x509 -in "$crt" -fingerprint -sha256 -noout \
  | sed 's/.*Fingerprint=//;s/://g' | tr 'A-F' 'a-f')
}

ensure_creds(){
  [[ -z "${UUID:-}" ]] && UUID=$(gen_uuid)
  is_uuid "$UUID" || UUID=$(gen_uuid)
  [[ -z "${HY2_PWD:-}" ]] && HY2_PWD=$(rand_b64_32)
  if [[ -z "${REALITY_PRIV:-}" || -z "${REALITY_PUB:-}" || -z "${REALITY_SID:-}" ]]; then
    readarray -t RKP < <(gen_reality)
    REALITY_PRIV=$(printf "%s\n" "${RKP[@]}" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(printf "%s\n" "${RKP[@]}" | awk '/PublicKey/{print $2}')
    REALITY_SID=$(rand_hex8)
  fi
  [[ -z "${HY2_PWD2:-}" ]] && HY2_PWD2=$(rand_b64_32)
  [[ -z "${HY2_OBFS_PWD:-}" ]] && HY2_OBFS_PWD=$(openssl rand -base64 16 | tr -d "\n")
  [[ -z "${SS2022_KEY:-}" ]] && SS2022_KEY=$(rand_b64_32)
  [[ -z "${SS_PWD:-}" ]] && SS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  TUIC_UUID="$UUID"; TUIC_PWD="$UUID"
  [[ -z "${ANYTLS_PWD:-}" ]] && ANYTLS_PWD=$(rand_b64_32)
  # 每个 reality inbound 独立随机偷一个域名（首次安装抽取后持久化）
  [[ -z "${RS_VR:-}"  ]] && RS_VR=$(pick_reality)    # vless-reality
  [[ -z "${RS_GR:-}"  ]] && RS_GR=$(pick_reality)    # vless-grpc-reality
  [[ -z "${RS_TR:-}"  ]] && RS_TR=$(pick_reality)    # trojan-reality
  [[ -z "${RS_VRW:-}" ]] && RS_VRW=$(pick_reality)   # vless-reality-warp
  [[ -z "${RS_GRW:-}" ]] && RS_GRW=$(pick_reality)   # vless-grpc-reality-warp
  [[ -z "${RS_TRW:-}" ]] && RS_TRW=$(pick_reality)   # trojan-reality-warp
  save_creds
}

# ===== WARP（wgcf） =====
WGCF_BIN=/usr/local/bin/wgcf
install_wgcf_disabled(){
  [[ -x "$WGCF_BIN" ]] && return 0
  local GOA url tmp
  case "$(arch_map)" in
    amd64) GOA=amd64;; arm64) GOA=arm64;; armv7) GOA=armv7;; 386) GOA=386;; *) GOA=amd64;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | jq -r ".assets[] | select(.name|test(\"linux_${GOA}$\")) | .browser_download_url" | head -n1)
  [[ -n "$url" ]] || { warn "获取 wgcf 下载地址失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/wgcf"
  install -m0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf "$tmp"
}

# —— Base64 清理 + 补齐：去掉引号/空白，长度 %4==2 补“==”，%4==3 补“=” ——
pad_b64(){
  local s="${1:-}"
  # 去引号/空格/回车
  s="$(printf '%s' "$s" | tr -d '\r\n\" ')"
  # 去掉已有尾随 =，按需重加
  s="${s%%=*}"
  local rem=$(( ${#s} % 4 ))
  if   (( rem == 2 )); then s="${s}=="
  elif (( rem == 3 )); then s="${s}="
  fi
  printf '%s' "$s"
}


# ===== WARP（官方 warp-cli，proxy 模式）一键安装/修复 =====
# 说明：
# - 本脚本强制使用官方 cloudflare-warp (warp-cli) 提供本地 SOCKS5 (默认 127.0.0.1:40000)
# - sing-box 的 tag=warp 出站固定走该 SOCKS5
WARP_SOCKS_HOST="${WARP_SOCKS_HOST:-127.0.0.1}"
WARP_SOCKS_PORT="${WARP_SOCKS_PORT:-40000}"

install_warpcli(){
  command -v warp-cli >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    info "安装 cloudflare-warp (Debian/Ubuntu)..."
    apt-get update -y
    apt-get install -y curl gpg lsb-release ca-certificates >/dev/null 2>&1 || true
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main"       > /etc/apt/sources.list.d/cloudflare-client.list
    apt-get update -y
    apt-get install -y cloudflare-warp
  elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
    info "安装 cloudflare-warp (CentOS/RHEL)..."
    curl -fsSl https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo | tee /etc/yum.repos.d/cloudflare-warp.repo >/dev/null
    if command -v dnf >/dev/null 2>&1; then
      dnf install -y cloudflare-warp
    else
      yum install -y cloudflare-warp
    fi
  else
    err "未识别的包管理器，无法自动安装 cloudflare-warp"
    return 1
  fi

  command -v warp-cli >/dev/null 2>&1
}

ensure_warpcli_proxy(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  install_warpcli || return 1

  systemctl enable --now warp-svc >/dev/null 2>&1 || true

  # 已注册则跳过；未注册则自动同意条款
  if ! warp-cli registration show >/dev/null 2>&1; then
    info "正在初始化 Cloudflare WARP"

    # warp-cli 强制检测 TTY，非 TTY 拒绝输入，需模拟真实终端注入 y
    # 优先级：python3 pty（最可靠）→ expect → 安装 python3 兜底
    _warp_reg_ok=0

    if command -v python3 >/dev/null 2>&1; then
      python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF

    elif command -v expect >/dev/null 2>&1; then
      expect -c '
        spawn warp-cli registration new
        expect -re {[yY]/[nN]}
        send "y\r"
        expect eof
      ' >/dev/null 2>&1 && _warp_reg_ok=1 || true

    else
      # 尝试安装 python3（兜底）
      warn "未找到 python3/expect，尝试安装 python3..."
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y python3 >/dev/null 2>&1 || true
      elif command -v dnf >/dev/null 2>&1; then
        dnf install -y python3 >/dev/null 2>&1 || true
      elif command -v yum >/dev/null 2>&1; then
        yum install -y python3 >/dev/null 2>&1 || true
      elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm python >/dev/null 2>&1 || true
      elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install python3 >/dev/null 2>&1 || true
      fi

      if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PYEOF' 2>/dev/null && _warp_reg_ok=1 || true
import pty, os, time, select, sys

def run():
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("warp-cli", ["warp-cli", "registration", "new"])
    else:
        answered = False
        for _ in range(30):
            r, _, _ = select.select([fd], [], [], 1)
            if r:
                try:
                    data = os.read(fd, 4096).decode(errors="ignore")
                except OSError:
                    break
                if not answered and ("y/N" in data or "y/n" in data):
                    time.sleep(0.2)
                    os.write(fd, b"y\n")
                    answered = True
                if "Success" in data:
                    sys.exit(0)
            try:
                ret = os.waitpid(pid, os.WNOHANG)
                if ret[0] != 0:
                    break
            except ChildProcessError:
                break
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass
        sys.exit(1)

run()
PYEOF
      else
        err "无法自动完成 WARP 注册（缺少 python3/expect），请手动运行：warp-cli registration new"
        return 1
      fi
    fi

    sleep 2
    if ! warp-cli registration show >/dev/null 2>&1; then
      err "WARP 注册失败，请手动运行：warp-cli registration new"; return 1
    fi
  fi

  # proxy 模式：不改系统默认路由
  warp-cli mode proxy >/dev/null 2>&1 || true
  # 新版 warp-cli（2024+）支持显式指定代理端口，防止默认端口与脚本预期不一致
  warp-cli proxy port "$WARP_SOCKS_PORT" >/dev/null 2>&1 || true

  # 连接
  warp-cli connect >/dev/null 2>&1 || return 1

  # 等待 socks 端口就绪 + 真实探测 warp=on（新版 warp-cli 拉起代理可能要 30~60s，
  # 原来的固定 12s 会"假失败"：端口稍后才起，但脚本已经报错返回）
  local socks_ok=0 i trace
  for i in {1..60}; do
    if port_listening "$WARP_SOCKS_PORT"; then
      trace=$(curl -fsSL --max-time 8 --proxy "socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}" https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
      if [[ "$trace" == *"warp=on"* ]]; then
        socks_ok=1; break
      fi
    fi
    (( i % 15 == 0 )) && info "等待 WARP 代理就绪…（已 ${i}s / 最多 60s）"
    sleep 1
  done

  if (( socks_ok )); then
    ok "WARP proxy 已就绪：socks5://${WARP_SOCKS_HOST}:${WARP_SOCKS_PORT}"
    return 0
  fi

  # 探测失败只告警（不再硬失败）：端口在但没探测到 warp=on 属于"还在连"，端口不在才是真异常
  if port_listening "$WARP_SOCKS_PORT"; then
    warn "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 在监听，但未探测到 warp=on（可能仍在连接，稍后会自动就绪；WARP 节点暂不可用）"
  else
    warn "WARP SOCKS5 端口 ${WARP_SOCKS_PORT} 未监听（warp-svc/warp-cli 可能未正常工作；WARP 节点暂不可用）"
    systemctl status warp-svc --no-pager 2>/dev/null | head -40 || true
  fi
  warp-cli status 2>/dev/null | head -5 || true
  return 1
}

# ===== WARP（wgcf）配置生成/修复（已废弃/不再默认使用，保留旧代码以兼容历史） =====

ensure_wgcf_profile(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  # 先尝试读取旧 env，并做一次规范化补齐
  if load_warp 2>/dev/null; then
    WARP_PRIVATE_KEY="$(pad_b64 "${WARP_PRIVATE_KEY:-}")"
    WARP_PEER_PUBLIC_KEY="$(pad_b64 "${WARP_PEER_PUBLIC_KEY:-}")"
    # 允许之前没写 reserved，给默认 0
    : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"
    save_warp
    # 如果关键字段都在，就直接用旧的（已经补齐），无需重建
    if [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_PEER_PUBLIC_KEY" && -n "${WARP_ENDPOINT_HOST:-}" && -n "${WARP_ENDPOINT_PORT:-}" ]]; then
      return 0
    fi
  fi

  # 走到这里说明旧 env 不完整；开始用 wgcf 重建
  install_wgcf_disabled || { warn "wgcf 安装失败，禁用 WARP 节点"; ENABLE_WARP=false; save_env; return 0; }

  local wd="$SB_DIR/wgcf"; mkdir -p "$wd"
  if [[ ! -f "$wd/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$wd/wgcf-account.toml" >/dev/null
  fi
  "$WGCF_BIN" generate --config "$wd/wgcf-account.toml" --profile "$wd/wgcf-profile.conf" >/dev/null

  local prof="$wd/wgcf-profile.conf"
  # 提取并规范化
  WARP_PRIVATE_KEY="$(pad_b64 "$(awk -F'= *' '/^PrivateKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"
  WARP_PEER_PUBLIC_KEY="$(pad_b64 "$(awk -F'= *' '/^PublicKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"

  # Endpoint 可能是域名或 [IPv6]:port
  local ep host port
  ep="$(awk -F'= *' '/^Endpoint/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  if [[ "$ep" =~ ^\[(.+)\]:(.+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; else host="${ep%:*}"; port="${ep##*:}"; fi
  WARP_ENDPOINT_HOST="$host"
  WARP_ENDPOINT_PORT="$port"

  # 内网地址与 reserved
  local ad rs
  ad="$(awk -F'= *' '/^Address/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_ADDRESS_V4="${ad%%,*}"
  WARP_ADDRESS_V6="${ad##*,}"
  rs="$(awk -F'= *' '/^Reserved/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_RESERVED_1="${rs%%,*}"; rs="${rs#*,}"
  WARP_RESERVED_2="${rs%%,*}"; WARP_RESERVED_3="${rs##*,}"
  : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"

  save_warp
}

# ===== 依赖与安装 =====
install_deps(){
  apt-get update -y >/dev/null 2>&1 || true
  apt-get install -y ca-certificates curl wget jq tar iproute2 openssl coreutils uuid-runtime >/dev/null 2>&1 || true
}

# ===== 安装 / 更新 sing-box（GitHub Releases）=====
install_singbox() {

  # 已安装则直接返回
  if command -v "$BIN_PATH" >/dev/null 2>&1; then
    info "检测到 sing-box: $("$BIN_PATH" version | head -n1)"
    return 0
  fi

  # 依赖
  ensure_deps curl jq tar || return 1
  command -v xz >/dev/null 2>&1 || ensure_deps xz-utils >/dev/null 2>&1 || true
  command -v unzip >/dev/null 2>&1 || ensure_deps unzip   >/dev/null 2>&1 || true

  local repo="SagerNet/sing-box"
  local tag="${SINGBOX_TAG:-v1.13.7}"   # 允许用环境变量固定版本，如 v1.13.7
  local arch; arch="$(arch_map)"
  local api url tmp pkg re rel_url

  info "下载 sing-box (${arch}) ..."

  # 取 release JSON
  if [[ "$tag" = "latest" ]]; then
    rel_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi

  # 资产名匹配：兼容 tar.gz / tar.xz / zip
  # 典型名称：sing-box-1.12.7-linux-amd64.tar.gz
  re="^sing-box-.*-linux-${arch}\\.(tar\\.(gz|xz)|zip)$"

  # 先在目标 release 里找；找不到再从所有 releases 里兜底
  url="$(curl -fsSL "$rel_url" | jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1)"
  if [[ -z "$url" ]]; then
    url="$(curl -fsSL "https://api.github.com/repos/${repo}/releases" \
           | jq -r --arg re "$re" '[ .[] | .assets[] | select(.name | test($re)) | .browser_download_url ][0]')"
  fi
  [[ -n "$url" ]] || { err "下载 sing-box 失败：未匹配到发行包（arch=${arch} tag=${tag})"; return 1; }


  tmp="$(mktemp -d)"; pkg="${tmp}/pkg"
  if ! curl -fL --retry 3 --retry-delay 5 --connect-timeout 15 -o "$pkg" "$url"; then
    rm -rf "$tmp"; err "下载 sing-box 失败"; return 1
  fi

  # 解压
  if echo "$url" | grep -qE '\.tar\.gz$|\.tgz$'; then
    tar -xzf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.tar\.xz$'; then
    tar -xJf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.zip$'; then
    unzip -q "$pkg" -d "$tmp"
  else
    rm -rf "$tmp"; err "未知包格式：$url"; return 1
  fi

  # 找到二进制并安装
  local bin
  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [[ -n "$bin" ]] || { rm -rf "$tmp"; err "解压失败：未找到 sing-box 可执行文件"; return 1; }

  install -m 0755 "$bin" "$BIN_PATH"
  rm -rf "$tmp"
  info "安装完成：$("$BIN_PATH" version | head -n1)"
}

# ===== systemd =====
write_systemd(){ cat > "/etc/systemd/system/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Sing-Box (Native 20 nodes)
After=network-online.target warp-svc.service
Wants=network-online.target warp-svc.service
Requires=network-online.target

[Service]
Type=simple
Environment=ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true
ExecStart=${BIN_PATH} run -c ${CONF_JSON} -D ${DATA_DIR}
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
}

# ===== 写 config.json（使用你提供的稳定配置逻辑） =====
write_config(){
  ensure_dirs; load_env || true; load_creds || true; load_ports || true
  ensure_creds; save_all_ports; mk_cert
  [[ "$ENABLE_WARP" == "true" ]] && { ensure_warpcli_proxy || true; }   # WARP 异常不再拖垮配置生成

  local CRT="$CERT_DIR/fullchain.pem" KEY="$CERT_DIR/key.pem"
  jq -n \
  --arg RS "$REALITY_SERVER" --argjson RSP "${REALITY_SERVER_PORT:-443}" --arg UID "$UUID" \
  --arg WSHOST "$WARP_SOCKS_HOST" --argjson WSPORT "$WARP_SOCKS_PORT" \
  --arg RPR "$REALITY_PRIV" --arg RPB "$REALITY_PUB" --arg SID "$REALITY_SID" \
  --arg RS_VR "$RS_VR" --arg RS_GR "$RS_GR" --arg RS_TR "$RS_TR" \
  --arg RS_VRW "$RS_VRW" --arg RS_GRW "$RS_GRW" --arg RS_TRW "$RS_TRW" \
  --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
  --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg CRT "$CRT" --arg KEY "$KEY" \
  --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" --arg ANYTLSPWD "$ANYTLS_PWD" \
  --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
  --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
  --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" --argjson P10 "$PORT_ANYTLS" \
  --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
  --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
  --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" --argjson PW10 "$PORT_ANYTLS_W" \
  --arg ENABLE_WARP "$ENABLE_WARP" \
  --arg WPRIV "${WARP_PRIVATE_KEY:-}" --arg WPPUB "${WARP_PEER_PUBLIC_KEY:-}" \
  --arg WHOST "${WARP_ENDPOINT_HOST:-}" --argjson WPORT "${WARP_ENDPOINT_PORT:-0}" \
  --arg W4 "${WARP_ADDRESS_V4:-}" --arg W6 "${WARP_ADDRESS_V6:-}" \
  --argjson WR1 "${WARP_RESERVED_1:-0}" --argjson WR2 "${WARP_RESERVED_2:-0}" --argjson WR3 "${WARP_RESERVED_3:-0}" \
  '
  def inbound_vless($port; $rs): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_vless_flow($port; $rs): {type:"vless", listen:"::", listen_port:$port, users:[{uuid:$UID, flow:"xtls-rprx-vision"}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_trojan($port; $rs): {type:"trojan", listen:"::", listen_port:$port, users:[{password:$UID}], tls:{enabled:true, server_name:$rs, reality:{enabled:true, handshake:{server:$rs, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}};
  def inbound_hy2($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY2}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};
  def inbound_vmess_ws($port): {type:"vmess", listen:"::", listen_port:$port, users:[{uuid:$UID}], transport:{type:"ws", path:$VMWS}};
  def inbound_hy2_obfs($port): {type:"hysteria2", listen:"::", listen_port:$port, users:[{name:"hy2", password:$HY22}], obfs:{type:"salamander", password:$HY2O}, tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_ss2022($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"2022-blake3-aes-256-gcm", password:$SS2022};
  def inbound_ss($port): {type:"shadowsocks", listen:"::", listen_port:$port, method:"aes-256-gcm", password:$SSPWD};
  def inbound_tuic($port): {type:"tuic", listen:"::", listen_port:$port, users:[{uuid:$TUICUUID, password:$TUICPWD}], congestion_control:"bbr", tls:{enabled:true, certificate_path:$CRT, key_path:$KEY, alpn:["h3"]}};
  def inbound_anytls($port): {type:"anytls", listen:"::", listen_port:$port, users:[{name:"anytls", password:$ANYTLSPWD}], tls:{enabled:true, certificate_path:$CRT, key_path:$KEY}};

  def warp_outbound:
    {type:"socks", tag:"warp", server:$WSHOST, server_port:$WSPORT};


  {
    log:{level:"info", timestamp:true},
  dns:{ servers:[ {type:"https", tag:"dns-remote", server:"1.1.1.1", server_port:443, path:"/dns-query"}, {type:"udp", tag:"dns-local", server:"8.8.8.8"} ], strategy:"prefer_ipv4" },
  inbounds:[
      (inbound_vless_flow($P1; $RS_VR) + {tag:"vless-reality"}),
      (inbound_vless($P2; $RS_GR) + {tag:"vless-grpcr", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($P3; $RS_TR) + {tag:"trojan-reality"}),
      (inbound_hy2($P4) + {tag:"hy2"}),
      (inbound_vmess_ws($P5) + {tag:"vmess-ws"}),
      (inbound_hy2_obfs($P6) + {tag:"hy2-obfs"}),
      (inbound_ss2022($P7) + {tag:"ss2022"}),
      (inbound_ss($P8) + {tag:"ss"}),
      (inbound_tuic($P9) + {tag:"tuic-v5"}),
      (inbound_anytls($P10) + {tag:"anytls"}),

      (inbound_vless_flow($PW1; $RS_VRW) + {tag:"vless-reality-warp"}),
      (inbound_vless($PW2; $RS_GRW) + {tag:"vless-grpcr-warp", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($PW3; $RS_TRW) + {tag:"trojan-reality-warp"}),
      (inbound_hy2($PW4) + {tag:"hy2-warp"}),
      (inbound_vmess_ws($PW5) + {tag:"vmess-ws-warp"}),
      (inbound_hy2_obfs($PW6) + {tag:"hy2-obfs-warp"}),
      (inbound_ss2022($PW7) + {tag:"ss2022-warp"}),
      (inbound_ss($PW8) + {tag:"ss-warp"}),
      (inbound_tuic($PW9) + {tag:"tuic-v5-warp"}),
      (inbound_anytls($PW10) + {tag:"anytls-warp"})
    ],
    outbounds: (
      if $ENABLE_WARP=="true" then
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}, warp_outbound]
      else
        [{type:"direct", tag:"direct"}, {type:"block", tag:"block"}]
      end
    ),
    route: (
      if $ENABLE_WARP=="true" then
        { default_domain_resolver:"dns-remote", rules:[
            { inbound: ["vless-reality-warp","vless-grpcr-warp","trojan-reality-warp","hy2-warp","vmess-ws-warp","hy2-obfs-warp","ss2022-warp","ss-warp","tuic-v5-warp","anytls-warp"], outbound:"warp" }
          ],
          final:"direct"
        }
      else
        { final:"direct" }
      end
    )
  }' > "$CONF_JSON"
  save_env
}

# ===== 防火墙 =====
open_firewall(){
  local rules=()
  rules+=("${PORT_VLESSR}/tcp" "${PORT_VLESS_GRPCR}/tcp" "${PORT_TROJANR}/tcp" "${PORT_VMESS_WS}/tcp")
  rules+=("${PORT_HY2}/udp" "${PORT_HY2_OBFS}/udp" "${PORT_TUIC}/udp")
  rules+=("${PORT_SS2022}/tcp" "${PORT_SS2022}/udp" "${PORT_SS}/tcp" "${PORT_SS}/udp")
  rules+=("${PORT_ANYTLS}/tcp")
  rules+=("${PORT_VLESSR_W}/tcp" "${PORT_VLESS_GRPCR_W}/tcp" "${PORT_TROJANR_W}/tcp" "${PORT_VMESS_WS_W}/tcp")
  rules+=("${PORT_HY2_W}/udp" "${PORT_HY2_OBFS_W}/udp" "${PORT_TUIC_W}/udp")
  rules+=("${PORT_SS2022_W}/tcp" "${PORT_SS2022_W}/udp" "${PORT_SS_W}/tcp" "${PORT_SS_W}/udp")
  rules+=("${PORT_ANYTLS_W}/tcp")

  if command -v ufw >/dev/null 2>&1 && ufw status | pipe_has "active|活跃"; then
    for r in "${rules[@]}"; do ufw allow "$r" >/dev/null 2>&1 || true; done
    ufw reload >/dev/null 2>&1 || true

  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    for r in "${rules[@]}"; do firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true

  else
    local p proto
    for r in "${rules[@]}"; do
      p="${r%/*}"; proto="${r#*/}"

      # IPv4
      if [[ "$proto" == tcp ]]; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
      fi
      if [[ "$proto" == udp ]]; then
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
      fi

      # IPv6（关键补全）
      if command -v ip6tables >/dev/null 2>&1; then
        if [[ "$proto" == tcp ]]; then
          ip6tables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$p" -j ACCEPT
        fi
        if [[ "$proto" == udp ]]; then
          ip6tables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p udp --dport "$p" -j ACCEPT
        fi
      fi
    done

    # 保存（netfilter-persistent 通常会把 v4/v6 一起保存）
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# ===== 分享链接（分组输出 + 提示） =====
print_links_grouped(){
  load_env || true; load_creds || true; load_ports || true
  build_links "${1:-4}" || return 1
  local host="$PUB_HOST" ip="$PUB_IP" l sbase
  sbase="$(sub_base "$ip")"
  echo -e "${C_BLUE}${C_BOLD}分享链接（20 个）${C_RESET}"
  hr
  echo -e "${C_CYAN}${C_BOLD}【直连节点（10）】${C_RESET}（vless-reality / vless-grpc-reality / trojan-reality / vmess-ws / hy2 / hy2-obfs / ss2022 / ss / tuic / anytls）"
  for l in "${LINKS_DIRECT[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_CYAN}${C_BOLD}【WARP 节点（10）】${C_RESET}（同上 10 种，带 -warp）"
  echo -e "${C_DIM}说明：带 -warp 的 10 个节点走 Cloudflare WARP 出口，流媒体解锁更友好${C_RESET}"
  for l in "${LINKS_WARP[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_MAGENTA}${C_BOLD}📦 一条链接导入全部 20 个节点（聚合订阅）${C_RESET}"
  echo -e "  Clash/Mihomo 订阅 : ${sbase}/clash"
  echo -e "  sing-box 订阅     : ${sbase}/singbox"
  echo -e "  通用聚合(base64)  : ${sbase}/all"
  echo -e "  聚合页(全部链接)  : ${sbase}/"
  echo -e "${C_DIM}  订阅服务未启动？主菜单选 7) 订阅链接 一键启动${C_RESET}"
  hr
  if ! tls_on; then
  echo -e "${C_YELLOW}📌 如果你使用 v2rayN/Xray-core v26.2.6+，hysteria2 节点的 allowInsecure 已被移除，${C_RESET}"
  echo -e "${C_YELLOW}   请改用以下 pinnedPeerCertSha256 节点：${C_RESET}"
  echo "  hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?sni=${REALITY_SERVER}&pcs=${CRT_SHA256}#hysteria2-pinnedPeerCertSha256"
  echo "  hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?sni=${REALITY_SERVER}&pcs=${CRT_SHA256}#hysteria2-warp-pinnedPeerCertSha256"
  fi
  hr
}

# ===== BBR =====
enable_bbr(){
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用"
  else
    echo "net.core.default_qdisc=fq" >/etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    info "已尝试开启 BBR（如内核不支持需自行升级）"
  fi
}

# ===== 显示状态与 banner =====
sb_service_state(){
  systemctl is-active --quiet "${SYSTEMD_SERVICE:-sing-box.service}" && echo -e "${C_GREEN}运行中${C_RESET}" || echo -e "${C_RED}未运行/未安装${C_RESET}"
}
bbr_state(){
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo -e "${C_GREEN}已启用 BBR${C_RESET}" || echo -e "${C_RED}未启用 BBR${C_RESET}"
}

banner(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}🚀 ${SCRIPT_NAME} ${SCRIPT_VERSION} 🚀${C_RESET}"
  echo -e "${C_CYAN} 脚本更新地址: https://github.com/Alvin9999-newpac/Sing-Box-Plus${C_RESET}"
  echo -e "${C_MAGENTA} 订阅增强版：一键生成 Clash / sing-box / 聚合订阅（20 节点一条链接）${C_RESET}"

  hr
  echo -e "系统加速状态：$(bbr_state)"
  echo -e "Sing-Box 启动状态：$(sb_service_state)"
  hr
  echo -e "  ${C_BLUE}1)${C_RESET} 安装/部署（20 节点）"
  echo -e "  ${C_GREEN}2)${C_RESET} 查看分享链接（IPv4）"
  echo -e "  ${C_GREEN}3)${C_RESET} 查看分享链接（IPv6）"
  echo -e "  ${C_GREEN}4)${C_RESET} 重启服务"
  echo -e "  ${C_GREEN}5)${C_RESET} 一键更换所有端口"
  echo -e "  ${C_GREEN}6)${C_RESET} 一键开启 BBR"
  echo -e "  ${C_GREEN}7)${C_RESET} 订阅链接（Clash / sing-box / 聚合）"
  echo -e "  ${C_GREEN}8)${C_RESET} TLS / 域名（真证书：订阅HTTPS + 节点）"
  echo -e "  ${C_RED}9)${C_RESET} 卸载"
  echo -e "  ${C_RED}0)${C_RESET} 退出"
  hr
}

# ===== 业务流程 =====
restart_service(){
  systemctl restart "${SYSTEMD_SERVICE}" || die "重启失败"
  systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,6p' || true
}

rotate_ports(){
  ensure_installed_or_hint || return 0
  load_ports || true
  rand_ports_reset

  # 清空 20 项端口变量，触发重新分配不重复端口
  PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
  PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
  PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
  PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

  save_all_ports          # 重新生成并保存 20 个不重复端口
  write_config            # 用新端口重写 /opt/sing-box/config.json
  open_firewall           # ★ 新增：把“当前配置中的端口”全部放行
  systemctl restart "${SYSTEMD_SERVICE}"
  gen_subs 4 || true                                    # 端口变了，同步重生成订阅

  info "已更换端口并重启（订阅已同步更新）。"
  read -p "回车返回..." _ || true
}


uninstall_all(){
  systemctl stop "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SYSTEMD_SERVICE}"
  systemctl daemon-reload
  rm -rf "$SB_DIR"
  echo -e "${C_GREEN}已卸载并清理完成。${C_RESET}"
  exit 0
}

deploy_native(){
  install_deps
  install_singbox
  write_config
  info "检查配置 ..."
  "$BIN_PATH" check -c "$CONF_JSON"
  info "写入并启用 systemd 服务 ..."
  write_systemd
  systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
  open_firewall
  echo; echo -e "${C_BOLD}${C_GREEN}★ 部署完成（20 节点）${C_RESET}"; echo
  # 打印链接并直接退出
  print_links_grouped 4
  exit 0
}

ensure_installed_or_hint(){
  if [[ ! -f "$CONF_JSON" ]]; then
    warn "尚未安装，请先选择 1) 安装/部署（20 节点）"
    return 1
  fi
  return 0
}

# ============================================================
#  订阅模块（Clash / sing-box / 聚合页）—— fork 增强
#  依赖：脚本已装 jq/curl；订阅服务用 python3 或 busybox httpd
# ============================================================
safe_source_env "$SB_DIR/sub.env" 2>/dev/null || true
SUB_DIR=${SUB_DIR:-$SB_DIR/sub}
SUB_PORT=${SUB_PORT:-2088}
SUB_SERVICE=${SUB_SERVICE:-sbp-sub.service}
SUB_USER=${SUB_USER:-}
SUB_PASS=${SUB_PASS:-}
SUB_PATH=${SUB_PATH:-}

# ---- 订阅访问凭据 / 密钥路径 ----
rand_hex(){ if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$1"; else head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; fi; }
gen_sub_pass(){ tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16; }
gen_sub_path(){ rand_hex 16; }
gen_sub_user(){ printf 'u%s' "$(rand_hex 4)"; }

# 带凭据+密钥路径的订阅根地址（未配置凭据时退回裸地址）
sub_base(){
  local host="${1:-$PUB_IP}" scheme="http"
  if [[ -z "$SUB_USER" && -f "$SB_DIR/sub.env" ]]; then safe_source_env "$SB_DIR/sub.env" 2>/dev/null || true; fi
  if tls_on; then host="$TLS_DOMAIN"; scheme="https"; fi
  if [[ -n "$SUB_USER" ]]; then
    printf '%s://%s:%s@%s:%s/%s' "$scheme" "$SUB_USER" "$SUB_PASS" "$host" "$SUB_PORT" "$SUB_PATH"
  else
    printf '%s://%s:%s' "$scheme" "$host" "$SUB_PORT"
  fi
}

write_sub_env(){
  mkdir -p "$SB_DIR"
  local tmp; tmp="$(mktemp "${SB_DIR}/sub.env.XXXXXX")"
  { { [[ -f "$SB_DIR/sub.env" ]] && grep -v -E '^(SUB_PORT|SUB_USER|SUB_PASS|SUB_PATH)=' "$SB_DIR/sub.env" || true; } \
    ; printf 'SUB_PORT=%s\nSUB_USER=%s\nSUB_PASS=%s\nSUB_PATH=%s\n' "$SUB_PORT" "$SUB_USER" "$SUB_PASS" "$SUB_PATH"; } > "$tmp"
  mv "$tmp" "$SB_DIR/sub.env"
}

ensure_sub_secrets(){
  local changed=0
  [[ -n "$SUB_USER" ]] || { SUB_USER="$(gen_sub_user)"; changed=1; }
  [[ -n "$SUB_PASS" ]] || { SUB_PASS="$(gen_sub_pass)"; changed=1; }
  [[ -n "$SUB_PATH" ]] || { SUB_PATH="$(gen_sub_path)"; changed=1; }
  [[ "$changed" == "1" ]] && write_sub_env
  return 0
}

# ---- TLS（真证书）配置：默认关闭，配了才启用 ----
safe_source_env "$SB_DIR/tls.env" 2>/dev/null || true
TLS_DOMAIN=${TLS_DOMAIN:-}
TLS_EMAIL=${TLS_EMAIL:-}
TLS_CF_TOKEN=${TLS_CF_TOKEN:-}
TLS_SAN=${TLS_SAN:-}

write_tls_env(){
  mkdir -p "$SB_DIR"
  local tmp; tmp="$(mktemp "${SB_DIR}/tls.env.XXXXXX")"
  printf 'TLS_DOMAIN=%s\nTLS_EMAIL=%s\nTLS_CF_TOKEN=%s\nTLS_SAN=%s\n' "$TLS_DOMAIN" "$TLS_EMAIL" "$TLS_CF_TOKEN" "$TLS_SAN" > "$tmp"
  mv "$tmp" "$SB_DIR/tls.env"; chmod 600 "$SB_DIR/tls.env" 2>/dev/null || true
}

# 真证书是否已就绪：域名非空 + 证书存在且 SAN 匹配域名
tls_on(){
  [[ -n "${TLS_DOMAIN:-}" ]] || return 1
  [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/key.pem" ]] || return 1
  openssl x509 -in "$CERT_DIR/fullchain.pem" -noout -checkhost "$TLS_DOMAIN" >/dev/null 2>&1
}
tls_sni(){ if tls_on; then printf '%s' "$TLS_DOMAIN"; else printf '%s' "$REALITY_SERVER"; fi; }

acme_install(){
  local ac="$HOME/.acme.sh/acme.sh"
  [[ -x "$ac" ]] && return 0
  info "安装 acme.sh ..."
  curl -fsS --max-time 60 https://get.acme.sh -o /tmp/acme_install.sh 2>/dev/null \
    || curl -fsS --max-time 60 https://gh-proxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o /tmp/acme_direct.sh 2>/dev/null \
    || true
  if [[ -s /tmp/acme_install.sh ]]; then sh /tmp/acme_install.sh email="$TLS_EMAIL" >/dev/null 2>&1 || true; fi
  if [[ ! -x "$ac" && -s /tmp/acme_direct.sh ]]; then mkdir -p "$HOME/.acme.sh"; cp /tmp/acme_direct.sh "$ac"; chmod +x "$ac"; fi
  [[ -x "$ac" ]] || { err "acme.sh 安装失败（检查网络）"; return 1; }
}

cf_token_hint(){
  echo -e "  ${C_DIM}┌─ 创建 Cloudflare API Token（DNS-01 用）────────────────────${C_RESET}"
  echo -e "  ${C_DIM}│ 1) 控制台右上头像 → My Profile → API Tokens → Create Token${C_RESET}"
  echo -e "  ${C_DIM}│ 2) 用模板「Edit zone DNS」，或自定义：Permissions = Zone / DNS / Edit${C_RESET}"
  echo -e "  ${C_DIM}│ 3) Zone Resources = Include → Specific zone → 选中你的域名（必选！）${C_RESET}"
  echo -e "  ${C_DIM}│ 4) Client IP Address Filtering / TTL 都留空，否则换机换IP就失效${C_RESET}"
  echo -e "  ${C_DIM}│ 5) ⚠ 不要用 Global API Key（不兼容）；Token 只显示一次，建好立刻复制${C_RESET}"
  echo -e "  ${C_DIM}│ 6) 粘贴时别带前后空格/换行；域名必须已托管在本 CF 账号（NS 已切）${C_RESET}"
  echo -e "  ${C_DIM}│ 7) DNS-01 会自动加 _acme-challenge 的 TXT 记录，无需你手动配 A 记录${C_RESET}"
  echo -e "  ${C_DIM}└─ 常见报错：Invalid/Unable to validate token=粘错或权限不对 · Zone not found=Zone Resources 没选对${C_RESET}"
}

acme_issue(){
  acme_install || return 1
  local ac="$HOME/.acme.sh/acme.sh"
  export CF_Token="$TLS_CF_TOKEN"
  local san; local -a doms=("$TLS_DOMAIN") final=() dargs=()
  local IFS=','
  for san in $TLS_SAN; do
    san="${san// /}"
    [[ -n "$san" && "$san" != "$TLS_DOMAIN" ]] && doms+=("$san")
  done
  # 去掉被同一张证书里通配符覆盖的子域（否则 Let's Encrypt 报 redundant with a wildcard domain）
  local d w covered
  for d in "${doms[@]}"; do
    covered=0
    case "$d" in
      \*.*) ;;
      *) for w in "${doms[@]}"; do case "$w" in \*.*) [[ "$d" == *".${w#\*.}" ]] && { covered=1; break; } ;; esac; done ;;
    esac
    (( covered )) || final+=("$d")
  done
  for d in "${final[@]}"; do dargs+=(-d "$d"); done
  if [[ ${#dargs[@]} -gt 2 ]]; then
    info "向 Let's Encrypt 申请证书：${final[*]}（DNS-01，走 Cloudflare API，不占 80/443）"
  else
    info "向 Let's Encrypt 申请证书：$TLS_DOMAIN （DNS-01，走 Cloudflare API，不占 80/443）"
  fi
  "$ac" --issue --dns dns_cf "${dargs[@]}" --keylength ec-256 --server letsencrypt || {
    err "证书申请失败，逐项核对："
    err "  ① 域名已托管在本 CF 账号（NS 已切到 Cloudflare，可用 dig NS 域名 确认）"
    err "  ② Token 权限 = Zone→DNS→Edit，且 Zone Resources 里勾选了这个域名"
    err "  ③ 粘贴的 Token 无前后空格/换行；没用 Global API Key；Token 未过期/未撤销"
    err "  ④ 通配符要写成 *.域名；子域无需提前配 A 记录（DNS-01 只加 TXT）"
    err "  ⑤ 别同时写 *.域名 和 它的子域（LE 会报 redundant，本脚本已自动去重）"
    cf_token_hint
    return 1; }
  "$ac" --install-cert -d "$TLS_DOMAIN" --ecc \
    --key-file "$CERT_DIR/key.pem" --fullchain-file "$CERT_DIR/fullchain.pem" \
    --reloadcmd "systemctl restart ${SUB_SERVICE} >/dev/null 2>&1 || true; systemctl restart ${SYSTEMD_SERVICE} >/dev/null 2>&1 || true" \
    || { err "证书安装失败"; return 1; }
  ok "证书已安装到 $CERT_DIR/ （acme.sh 已配自动续期+重载）"
}

# ---- 统一构建 20 个节点链接（分享 & 聚合订阅复用） ----
PUB_MODE=""; PUB_IP=""; PUB_HOST=""
LINKS_DIRECT=(); LINKS_WARP=(); LINKS_ALL=()

build_links(){
  load_env || true; load_creds || true; load_ports || true
  ensure_dirs; mk_cert
  local mode="${1:-4}" ip host
  if [[ "$mode" == "6" ]]; then
    ip="$(get_ip6)"
    if [[ -z "$ip" ]]; then warn "未检测到公网 IPv6，自动回退到 IPv4"; ip="$(get_ip4)"; mode="4"; fi
  else
    ip="$(get_ip4)"
  fi
  [[ -z "$ip" ]] && { err "无法获取公网 IP"; return 1; }
  host="$(fmt_host_for_uri "$ip")"
  PUB_MODE="$mode"; PUB_IP="$ip"; PUB_HOST="$host"
  LINKS_DIRECT=(); LINKS_WARP=(); LINKS_ALL=()
  # TLS 真证书模式：hy2/tuic/anytls 改用域名 + 去 insecure
  local TH="$host" TSNI="$REALITY_SERVER" TOPT="insecure=1&allowInsecure=1&" AOPT="insecure=1&"
  if tls_on; then TH="$TLS_DOMAIN"; TSNI="$TLS_DOMAIN"; TOPT=""; AOPT=""; fi
  local VMESS_JSON VMESS_JSON_W

  LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality")
  LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${RS_GR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality")
  LINKS_DIRECT+=("trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${RS_TR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality")
  LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD}")@${TH}:${PORT_HY2}?${TOPT}sni=${TSNI}#hysteria2")
  VMESS_JSON=$(printf '{"v":"2","ps":"vmess-ws","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' "$ip" "$PORT_VMESS_WS" "$UUID" "$VMESS_WS_PATH")
  LINKS_DIRECT+=("vmess://$(printf "%s" "$VMESS_JSON" | b64enc)")
  LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD2}")@${TH}:${PORT_HY2_OBFS}?${TOPT}sni=${TSNI}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs")
  LINKS_DIRECT+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#ss2022")
  LINKS_DIRECT+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#ss")
  LINKS_DIRECT+=("tuic://${UUID}:$(urlenc "${UUID}")@${TH}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&${TOPT}sni=${TSNI}#tuic-v5")
  LINKS_DIRECT+=("anytls://$(urlenc "${ANYTLS_PWD}")@${TH}:${PORT_ANYTLS}?${AOPT}sni=${TSNI}#anytls")

  LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality-warp")
  LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${RS_GRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality-warp")
  LINKS_WARP+=("trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${RS_TRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality-warp")
  LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD}")@${TH}:${PORT_HY2_W}?${TOPT}sni=${TSNI}#hysteria2-warp")
  VMESS_JSON_W=$(printf '{"v":"2","ps":"vmess-ws-warp","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' "$ip" "$PORT_VMESS_WS_W" "$UUID" "$VMESS_WS_PATH")
  LINKS_WARP+=("vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)")
  LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD2}")@${TH}:${PORT_HY2_OBFS_W}?${TOPT}sni=${TSNI}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs-warp")
  LINKS_WARP+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#ss2022-warp")
  LINKS_WARP+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#ss-warp")
  LINKS_WARP+=("tuic://${UUID}:$(urlenc "${UUID}")@${TH}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&${TOPT}sni=${TSNI}#tuic-v5-warp")
  LINKS_WARP+=("anytls://$(urlenc "${ANYTLS_PWD}")@${TH}:${PORT_ANYTLS_W}?${AOPT}sni=${TSNI}#anytls-warp")

  LINKS_ALL=("${LINKS_DIRECT[@]}" "${LINKS_WARP[@]}")
  return 0
}

# ---- 生成：Clash / Mihomo 订阅 ----
# ===== 客户端分流规则库（自建分发：客户端无需翻墙取规则）=====
# 订阅目录下 rules/ 存放 geosite/geoip 规则库，由本机订阅服务直接分发（rules 路径免认证，内容是公开列表）
RULES_DIR_NAME="rules"
SUB_RULES_DIR(){ printf '%s/%s' "$SUB_DIR" "$RULES_DIR_NAME"; }

sub_rules_url(){ # $1=文件名 → 客户端可直取的规则库 URL（不含凭据；rules/ 免认证）
  local host="${PUB_IP:-}" scheme="http"
  if tls_on; then host="$TLS_DOMAIN"; scheme="https"; fi
  printf '%s://%s:%s/%s/rules/%s' "$scheme" "$host" "$SUB_PORT" "$SUB_PATH" "$1"
}

_dl_rule(){ # $1=目标文件 $2..=镜像 URL（依次尝试）
  local out="$1"; shift
  local u tmp="${out}.part"
  for u in "$@"; do
    rm -f "$tmp"
    if curl -fsSL --max-time 60 -o "$tmp" "$u" 2>/dev/null && [[ -s "$tmp" ]] && (( $(stat -c%s "$tmp" 2>/dev/null || echo 0) > 1024 )); then
      mv -f "$tmp" "$out"; return 0
    fi
  done
  rm -f "$tmp"; return 1
}

ensure_rule_files(){ # 下载/刷新客户端分流规则库；FORCE_RULES=1 强制刷新
  RULE_KIT=0; RULE_MIHOMO=0
  local rd; rd="$(SUB_RULES_DIR)"; mkdir -p "$rd" || return 1
  local maxage=$((7 * 24 * 3600)) need=0 f oldest
  for f in geosite-cn.srs geoip-cn.srs mihomo-cn-domain.mrs mihomo-cn-ip.mrs; do
    [[ -s "$rd/$f" ]] || need=1
  done
  if (( ! need )) && (( ${FORCE_RULES:-0} )); then need=1; fi
  if (( ! need )); then
    oldest=$(stat -c %Y "$rd"/geosite-cn.srs "$rd"/geoip-cn.srs "$rd"/mihomo-cn-domain.mrs "$rd"/mihomo-cn-ip.mrs 2>/dev/null | sort -n | head -1)
    (( $(date +%s) - ${oldest:-0} > maxage )) && need=1
  fi
  if (( need )); then
    info "更新客户端分流规则库（geosite/geoip，约 200KB）…"
    _dl_rule "$rd/geosite-cn.srs" \
      "https://gh-proxy.com/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" \
      "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" \
      "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/rule-set/geosite-cn.srs" || true
    _dl_rule "$rd/geoip-cn.srs" \
      "https://gh-proxy.com/https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" \
      "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" \
      "https://testingcf.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/rule-set/geoip-cn.srs" || true
    _dl_rule "$rd/mihomo-cn-domain.mrs" \
      "https://gh-proxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs" \
      "https://ghproxy.net/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs" \
      "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs" || true
    _dl_rule "$rd/mihomo-cn-ip.mrs" \
      "https://gh-proxy.com/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs" \
      "https://ghproxy.net/https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs" \
      "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.mrs" || true
  fi
  if [[ -s "$rd/geosite-cn.srs" && -s "$rd/geoip-cn.srs" ]]; then
    RULE_KIT=1; ok "sing-box 分流规则库就绪（geosite-cn + geoip-cn）"
  else
    warn "sing-box 规则库缺失，订阅退回简单分流（.cn/私有 IP 直连）"
  fi
  if [[ -s "$rd/mihomo-cn-domain.mrs" && -s "$rd/mihomo-cn-ip.mrs" ]]; then
    RULE_MIHOMO=1; ok "mihomo 分流规则库就绪（cn 域名 + cn IP）"
  else
    warn "mihomo 规则库缺失，Clash 订阅退回简单分流"
  fi
  return 0
}

gen_clash_sub(){
  load_env || true; load_creds || true; load_ports || true
  [[ -n "$PUB_HOST" ]] || build_links 4 || return 1
  mkdir -p "$SUB_DIR"
  local f="$SUB_DIR/clash.yaml" ip="$PUB_IP"
  local names=() lines=()
  # TLS 真证书模式：hy2/tuic/anytls 用域名 + 去 skip-cert-verify
  local CH="$ip" CS="$REALITY_SERVER" CSK=", skip-cert-verify: true" TUICS=""
  if tls_on; then CH="$TLS_DOMAIN"; CS="$TLS_DOMAIN"; CSK=""; TUICS=", sni: '$TLS_DOMAIN'"; fi
  addp(){ names+=("$1"); lines+=("- {$2}"); }
  local i

  # 直连 10
  addp vless-reality "name: 'vless-reality', type: vless, server: '$ip', port: $PORT_VLESSR, uuid: '$UUID', udp: true, tls: true, flow: xtls-rprx-vision, servername: '$RS_VR', client-fingerprint: chrome, network: tcp, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vless-grpc-reality "name: 'vless-grpc-reality', type: vless, server: '$ip', port: $PORT_VLESS_GRPCR, uuid: '$UUID', udp: true, tls: true, servername: '$RS_GR', client-fingerprint: chrome, network: grpc, grpc-opts: {grpc-service-name: '$GRPC_SERVICE'}, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp trojan-reality "name: 'trojan-reality', type: trojan, server: '$ip', port: $PORT_TROJANR, password: '$UUID', udp: true, sni: '$RS_TR', client-fingerprint: chrome, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vmess-ws "name: 'vmess-ws', type: vmess, server: '$ip', port: $PORT_VMESS_WS, uuid: '$UUID', alterId: 0, cipher: auto, udp: true, network: ws, ws-opts: {path: '$VMESS_WS_PATH'}"
  addp hysteria2 "name: 'hysteria2', type: hysteria2, server: '$CH', port: $PORT_HY2, password: '$HY2_PWD', sni: '$CS'${CSK}, alpn: [h3], udp: true"
  addp hysteria2-obfs "name: 'hysteria2-obfs', type: hysteria2, server: '$CH', port: $PORT_HY2_OBFS, password: '$HY2_PWD2', obfs: salamander, obfs-password: '$HY2_OBFS_PWD', sni: '$CS'${CSK}, alpn: [h3], udp: true"
  addp ss2022 "name: 'ss2022', type: ss, server: '$ip', port: $PORT_SS2022, cipher: 2022-blake3-aes-256-gcm, password: '$SS2022_KEY', udp: true"
  addp ss "name: 'ss', type: ss, server: '$ip', port: $PORT_SS, cipher: aes-256-gcm, password: '$SS_PWD', udp: true"
  addp tuic-v5 "name: 'tuic-v5', type: tuic, server: '$CH', port: $PORT_TUIC, uuid: '$TUIC_UUID', password: '$TUIC_PWD', udp: true, alpn: [h3]${CSK}${TUICS}, congestion-controller: bbr"
  addp anytls "name: 'anytls', type: anytls, server: '$CH', port: $PORT_ANYTLS, password: '$ANYTLS_PWD', sni: '$CS'${CSK}, udp: true, client-fingerprint: chrome"

  # WARP 10
  addp vless-reality-warp "name: 'vless-reality-warp', type: vless, server: '$ip', port: $PORT_VLESSR_W, uuid: '$UUID', udp: true, tls: true, flow: xtls-rprx-vision, servername: '$RS_VRW', client-fingerprint: chrome, network: tcp, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vless-grpc-reality-warp "name: 'vless-grpc-reality-warp', type: vless, server: '$ip', port: $PORT_VLESS_GRPCR_W, uuid: '$UUID', udp: true, tls: true, servername: '$RS_GRW', client-fingerprint: chrome, network: grpc, grpc-opts: {grpc-service-name: '$GRPC_SERVICE'}, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp trojan-reality-warp "name: 'trojan-reality-warp', type: trojan, server: '$ip', port: $PORT_TROJANR_W, password: '$UUID', udp: true, sni: '$RS_TRW', client-fingerprint: chrome, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vmess-ws-warp "name: 'vmess-ws-warp', type: vmess, server: '$ip', port: $PORT_VMESS_WS_W, uuid: '$UUID', alterId: 0, cipher: auto, udp: true, network: ws, ws-opts: {path: '$VMESS_WS_PATH'}"
  addp hysteria2-warp "name: 'hysteria2-warp', type: hysteria2, server: '$CH', port: $PORT_HY2_W, password: '$HY2_PWD', sni: '$CS'${CSK}, alpn: [h3], udp: true"
  addp hysteria2-obfs-warp "name: 'hysteria2-obfs-warp', type: hysteria2, server: '$CH', port: $PORT_HY2_OBFS_W, password: '$HY2_PWD2', obfs: salamander, obfs-password: '$HY2_OBFS_PWD', sni: '$CS'${CSK}, alpn: [h3], udp: true"
  addp ss2022-warp "name: 'ss2022-warp', type: ss, server: '$ip', port: $PORT_SS2022_W, cipher: 2022-blake3-aes-256-gcm, password: '$SS2022_KEY', udp: true"
  addp ss-warp "name: 'ss-warp', type: ss, server: '$ip', port: $PORT_SS_W, cipher: aes-256-gcm, password: '$SS_PWD', udp: true"
  addp tuic-v5-warp "name: 'tuic-v5-warp', type: tuic, server: '$CH', port: $PORT_TUIC_W, uuid: '$TUIC_UUID', password: '$TUIC_PWD', udp: true, alpn: [h3]${CSK}${TUICS}, congestion-controller: bbr"
  addp anytls-warp "name: 'anytls-warp', type: anytls, server: '$CH', port: $PORT_ANYTLS_W, password: '$ANYTLS_PWD', sni: '$CS'${CSK}, udp: true, client-fingerprint: chrome"

  local allinner directinner warpinner alljoined directjoined warpjoined
  allinner=$(printf "'%s', " "${names[@]}"); allinner="${allinner%, }"
  directinner=$(printf "'%s', " "${names[@]:0:10}"); directinner="${directinner%, }"
  warpinner=$(printf "'%s', " "${names[@]:10:10}"); warpinner="${warpinner%, }"
  alljoined="[${allinner}]"
  directjoined="[${directinner}]"
  warpjoined="[${warpinner}]"

  {
    cat <<EOF
# Clash / Mihomo 订阅 —— 由 Sing-Box-Plus 一键脚本生成
# 服务器: ${ip}   生成时间: $(date '+%Y-%m-%d %H:%M:%S')
mixed-port: 7890
allow-lan: false
bind-address: '*'
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
external-controller: 127.0.0.1:9090
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  respect-rules: false
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - https://223.5.5.5/dns-query
    - https://doh.pub/dns-query
  proxy-server-nameserver:
    - https://223.5.5.5/dns-query
proxies:
EOF
    printf '%s\n' "${lines[@]}"
    cat <<EOF
proxy-groups:
  - {name: '节点选择', type: select, proxies: ['自动选择', '直连节点', 'WARP节点', ${allinner}]}
  - {name: '自动选择', type: url-test, url: 'http://www.gstatic.com/generate_204', interval: 300, tolerance: 50, proxies: ${alljoined}}
  - {name: '直连节点', type: select, proxies: ${directjoined}}
  - {name: 'WARP节点', type: select, proxies: ${warpjoined}}
  - {name: '漏网之鱼', type: select, proxies: ['节点选择', '直连节点', '自动选择', DIRECT]}
EOF
    if (( ${RULE_MIHOMO:-0} )); then
      local u_dom u_ip
      u_dom="$(sub_rules_url mihomo-cn-domain.mrs)"; u_ip="$(sub_rules_url mihomo-cn-ip.mrs)"
      cat <<EOF
rule-providers:
  cn_domain:
    type: http
    behavior: domain
    format: mrs
    url: '$u_dom'
    path: ./ruleset/cn_domain.mrs
    interval: 604800
  cn_ipcidr:
    type: http
    behavior: ipcidr
    format: mrs
    url: '$u_ip'
    path: ./ruleset/cn_ipcidr.mrs
    interval: 604800
rules:
  # 内网/保留地址直连（不走代理）
  - 'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'
  - 'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'
  - 'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve'
  - 'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve'
  - 'IP-CIDR,100.64.0.0/10,DIRECT,no-resolve'
  # 国内域名/IP 直连（规则库由本订阅服务分发，无需客户端额外下载）
  - 'RULE-SET,cn_domain,DIRECT'
  - 'RULE-SET,cn_ipcidr,DIRECT'
  - 'DOMAIN-SUFFIX,cn,DIRECT'
  - 'MATCH,漏网之鱼'
EOF
    else
      cat <<EOF
rules:
  - 'DOMAIN-SUFFIX,cn,DIRECT'
  - 'GEOIP,CN,DIRECT,no-resolve'
  - 'MATCH,漏网之鱼'
EOF
    fi
  } > "$f"
  ok "已生成 Clash 订阅: $f"
}

# ---- 生成：sing-box 订阅（客户端配置） ----
gen_singbox_sub(){
  load_env || true; load_creds || true; load_ports || true
  [[ -n "$PUB_HOST" ]] || build_links 4 || return 1
  mkdir -p "$SUB_DIR"
  local f="$SUB_DIR/singbox.json" ip="$PUB_IP"
  local tags=()
  local direct_tags=() warp_tags=()
  local TH="$ip" TS="$REALITY_SERVER" INC="true"
  if tls_on; then TH="$TLS_DOMAIN"; TS="$TLS_DOMAIN"; INC="false"; fi

  _node(){ # $1 tag $2 json
    jq -n --argjson n "$2" '$n' >>/dev/null
  }

  jq -n \
    --arg ip "$ip" --arg UID "$UUID" --arg PUB "$REALITY_PUB" --arg SID "$REALITY_SID" \
    --arg RSVR "$RS_VR" --arg RSGR "$RS_GR" --arg RSTR "$RS_TR" \
    --arg RSVRW "$RS_VRW" --arg RSGRW "$RS_GRW" --arg RSTRW "$RS_TRW" \
    --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg RSV "$REALITY_SERVER" \
    --arg TH "$TH" --arg TS "$TS" --argjson INC "$INC" \
    --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
    --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" \
    --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" --arg ANYTLS "$ANYTLS_PWD" \
    --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
    --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
    --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" --argjson P10 "$PORT_ANYTLS" \
    --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
    --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
    --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" --argjson PW10 "$PORT_ANYTLS_W" \
    '
    def vless_r($t;$p;$s;$warp):
      {type:"vless",tag:$t,server:$ip,server_port:$p,uuid:$UID,flow:"xtls-rprx-vision",
       tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"},
            reality:{enabled:true,public_key:$PUB,short_id:$SID}}};
    def vless_g($t;$p;$s):
      {type:"vless",tag:$t,server:$ip,server_port:$p,uuid:$UID,
       tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"},
            reality:{enabled:true,public_key:$PUB,short_id:$SID}},
       transport:{type:"grpc",service_name:$GRPC}};
    def trojan_r($t;$p;$s):
      {type:"trojan",tag:$t,server:$ip,server_port:$p,password:$UID,
       tls:{enabled:true,server_name:$s,utls:{enabled:true,fingerprint:"chrome"},
            reality:{enabled:true,public_key:$PUB,short_id:$SID}}};
    def vmess_w($t;$p;$suffix):
      {type:"vmess",tag:$t,server:$ip,server_port:$p,uuid:$UID,security:"auto",
       transport:{type:"ws",path:$VMWS}};
    def hy2($t;$p;$pw;$suffix):
      {type:"hysteria2",tag:$t,server:$TH,server_port:$p,password:$pw,
       tls:{enabled:true,insecure:$INC,alpn:["h3"],server_name:$TS}};
    def hy2o($t;$p;$pw;$opw;$suffix):
      {type:"hysteria2",tag:$t,server:$TH,server_port:$p,password:$pw,
       obfs:{type:"salamander",password:$opw},
       tls:{enabled:true,insecure:$INC,alpn:["h3"],server_name:$TS}};
    def ss2022($t;$p;$suffix):
      {type:"shadowsocks",tag:$t,server:$ip,server_port:$p,method:"2022-blake3-aes-256-gcm",password:$SS2022};
    def ss($t;$p;$suffix):
      {type:"shadowsocks",tag:$t,server:$ip,server_port:$p,method:"aes-256-gcm",password:$SSPWD};
    def tuic($t;$p;$suffix):
      {type:"tuic",tag:$t,server:$TH,server_port:$p,uuid:$TUICUUID,password:$TUICPWD,
       congestion_control:"bbr",tls:{enabled:true,insecure:$INC,alpn:["h3"],server_name:$TS}};
    def anytls($t;$p;$suffix):
      {type:"anytls",tag:$t,server:$TH,server_port:$p,password:$ANYTLS,
       tls:{enabled:true,insecure:$INC,server_name:$TS}};
    def all_names: ["vless-reality","vless-grpc-reality","trojan-reality","vmess-ws","hysteria2","hysteria2-obfs","ss2022","ss","tuic-v5","anytls",
                    "vless-reality-warp","vless-grpc-reality-warp","trojan-reality-warp","vmess-ws-warp","hysteria2-warp","hysteria2-obfs-warp","ss2022-warp","ss-warp","tuic-v5-warp","anytls-warp"];
    def direct_names: ["vless-reality","vless-grpc-reality","trojan-reality","vmess-ws","hysteria2","hysteria2-obfs","ss2022","ss","tuic-v5","anytls"];
    def warp_names: ["vless-reality-warp","vless-grpc-reality-warp","trojan-reality-warp","vmess-ws-warp","hysteria2-warp","hysteria2-obfs-warp","ss2022-warp","ss-warp","tuic-v5-warp","anytls-warp"];
    {
      log:{level:"info",timestamp:true},
      dns:{servers:[{type:"udp",server:"223.5.5.5",tag:"dns-cn"},{type:"udp",server:"119.29.29.29",tag:"dns-cn2"},{type:"https",server:"1.1.1.1",detour:"节点选择",tag:"dns-remote"}]},
      inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:7890}],
      outbounds:
        [ vless_r("vless-reality";$P1;$RSVR;"")
        , vless_g("vless-grpc-reality";$P2;$RSGR)
        , trojan_r("trojan-reality";$P3;$RSTR)
        , vmess_w("vmess-ws";$P5;"")
        , hy2("hysteria2";$P4;$HY2;"")
        , hy2o("hysteria2-obfs";$P6;$HY22;$HY2O;"")
        , ss2022("ss2022";$P7;"")
        , ss("ss";$P8;"")
        , tuic("tuic-v5";$P9;"")
        , anytls("anytls";$P10;"")
        , vless_r("vless-reality-warp";$PW1;$RSVRW;"")
        , vless_g("vless-grpc-reality-warp";$PW2;$RSGRW)
        , trojan_r("trojan-reality-warp";$PW3;$RSTRW)
        , vmess_w("vmess-ws-warp";$PW5;"")
        , hy2("hysteria2-warp";$PW4;$HY2;"")
        , hy2o("hysteria2-obfs-warp";$PW6;$HY22;$HY2O;"")
        , ss2022("ss2022-warp";$PW7;"")
        , ss("ss-warp";$PW8;"")
        , tuic("tuic-v5-warp";$PW9;"")
        , anytls("anytls-warp";$PW10;"")
        , {type:"selector",tag:"节点选择",outbounds:(["自动选择","直连节点","WARP节点"] + all_names),default:"自动选择"}
        , {type:"urltest",tag:"自动选择",outbounds:all_names,url:"http://www.gstatic.com/generate_204",interval:"5m",tolerance:50}
        , {type:"selector",tag:"直连节点",outbounds:direct_names}
        , {type:"selector",tag:"WARP节点",outbounds:warp_names}
        , {type:"direct",tag:"direct"}
        ],
      route:{
        rules:[
          {action:"sniff"},
          {protocol:"dns",action:"hijack-dns"},
          {domain_suffix:[".cn"],outbound:"direct"},
          {ip_is_private:true,outbound:"direct"}
        ],
        final:"节点选择",
        default_domain_resolver:{server:"dns-cn"}
      }
    }' > "$f"
  # ---- 客户端分流：国内域名/IP 直连（规则库由本订阅服务分发；缺失则保留上面的简单规则）----
  if (( ${RULE_KIT:-0} )); then
    local u_geo u_ip
    u_geo="$(sub_rules_url geosite-cn.srs)"; u_ip="$(sub_rules_url geoip-cn.srs)"
    jq --arg ug "$u_geo" --arg ui "$u_ip" '
      .dns.rules = [
        {rule_set:["geosite-cn"],server:"dns-cn"},
        {domain_suffix:[".cn"],server:"dns-cn"}
      ]
      | .dns.final = "dns-remote"
      | .route.rule_set = [
          {type:"remote",tag:"geosite-cn",format:"binary",url:$ug,download_detour:"direct",update_interval:"7d"},
          {type:"remote",tag:"geoip-cn",format:"binary",url:$ui,download_detour:"direct",update_interval:"7d"}
        ]
      | .route.rules = [
          {action:"sniff"},
          {protocol:"dns",action:"hijack-dns"},
          {ip_is_private:true,outbound:"direct"},
          {rule_set:["geosite-cn"],outbound:"direct"},
          {rule_set:["geoip-cn"],outbound:"direct"},
          {domain_suffix:[".cn"],outbound:"direct"}
        ]
    ' "$f" > "$f.new" && mv -f "$f.new" "$f" || warn "sing-box 分流规则写入失败，保留简单分流"
  fi
  if jq -e . "$f" >/dev/null 2>&1; then ok "已生成 sing-box 订阅: $f"; else err "sing-box 订阅生成失败（JSON 校验未通过）"; return 1; fi
}

# ---- 生成：聚合（明文 + base64 + 索引页） ----
gen_all_sub(){
  [[ -n "$PUB_HOST" ]] || build_links "${1:-4}" || return 1
  mkdir -p "$SUB_DIR"
  printf '%s\n' "${LINKS_ALL[@]}" > "$SUB_DIR/links.txt"
  b64enc < "$SUB_DIR/links.txt" > "$SUB_DIR/all"
  printf '%s\n' "${LINKS_DIRECT[@]}" > "$SUB_DIR/direct.txt"
  printf '%s\n' "${LINKS_WARP[@]}" > "$SUB_DIR/warp.txt"
  b64enc < "$SUB_DIR/direct.txt" > "$SUB_DIR/direct"
  b64enc < "$SUB_DIR/warp.txt" > "$SUB_DIR/warp"

  ensure_sub_secrets
  local host="$PUB_IP" base i=1 n
  base="$(sub_base)"
  {
    cat <<EOF
<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sing-Box-Plus 聚合订阅</title>
<style>
 body{font-family:-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif;background:#0f1115;color:#e6e6e6;margin:0;padding:18px}
 h1{font-size:20px;margin:0 0 6px} .sub{color:#8b949e;font-size:13px;margin-bottom:14px}
 .card{background:#171a21;border:1px solid #232833;border-radius:10px;padding:14px;margin:0 0 14px}
 .card h2{font-size:15px;margin:0 0 10px;color:#7ee787}
 a.btn{display:inline-block;background:#1f6feb;color:#fff;text-decoration:none;padding:8px 12px;border-radius:8px;font-size:13px;margin:0 8px 8px 0}
 a.btn.alt{background:#238636} a.btn.gray{background:#30363d}
 code{background:#0b0e13;padding:2px 6px;border-radius:6px;font-size:12px;color:#c9d1d9;word-break:break-all}
 .item{background:#0b0e13;border-radius:8px;padding:8px 10px;margin-bottom:6px;font-size:12px;display:flex;gap:8px;align-items:center}
 .item span{flex:1;word-break:break-all;color:#c9d1d9}
 .item button{background:#30363d;color:#e6e6e6;border:0;border-radius:6px;padding:4px 8px;font-size:12px;cursor:pointer}
</style></head><body>
<h1>Sing-Box-Plus · 聚合订阅</h1>
<div class="sub">服务器 <b>${PUB_IP}</b> · 生成时间 $(date '+%Y-%m-%d %H:%M:%S') · 共 20 个节点（直连 10 + WARP 10）</div>

<div class="card"><h2>一键订阅（推荐）</h2>
 <div style="color:#8b949e;font-size:12px;margin-bottom:8px">Clash / Mihomo（含全部 20 节点 + 分组 + 分流规则）</div>
 <a class="btn" href="${base}/clash" target="_blank">复制 Clash 订阅链接</a>
 <code id="u1">${base}/clash</code>
 <div style="color:#8b949e;font-size:12px;margin:12px 0 8px">sing-box（客户端配置，含全部 20 节点）</div>
 <a class="btn alt" href="${base}/singbox" target="_blank">复制 sing-box 订阅链接</a>
 <code id="u2">${base}/singbox</code>
 <div style="color:#8b949e;font-size:12px;margin:12px 0 8px">通用聚合（全部 20 条链接的 base64，v2rayN / Shadowrocket / 小火箭 均可直接导入）</div>
 <a class="btn gray" href="${base}/all" target="_blank">复制聚合订阅链接</a>
 <code id="u3">${base}/all</code>
</div>

<div class="card"><h2>全部节点链接（直连 10）</h2>
EOF
    for l in "${LINKS_DIRECT[@]}"; do
      printf ' <div class="item"><span>%s</span><button onclick="cp(this)">复制</button></div>\n' "$l"
    done
    echo ' </div><div class="card"><h2>全部节点链接（WARP 10）</h2>'
    for l in "${LINKS_WARP[@]}"; do
      printf ' <div class="item"><span>%s</span><button onclick="cp(this)">复制</button></div>\n' "$l"
    done
    cat <<EOF
 </div>
<script>
function cp(b){var t=b.previousElementSibling.innerText;navigator.clipboard&&navigator.clipboard.writeText(t);b.innerText='已复制';setTimeout(function(){b.innerText='复制'},1200);}
</script></body></html>
EOF
  } > "$SUB_DIR/index.html"
  ok "已生成聚合页: $SUB_DIR/index.html （明文 links.txt / base64 all）"
}

gen_subs(){
  build_links "${1:-4}" || return 1
  ensure_sub_secrets
  ensure_rule_files || true          # 客户端分流规则库（缺失则自动退回简单规则）
  gen_clash_sub || true
  gen_singbox_sub || true
  gen_all_sub "${1:-4}" || true
}

# ---- 订阅 HTTP 服务 ----
write_sub_server(){
  mkdir -p "$SUB_DIR"
  local TLS_UNIT_CERT="" TLS_UNIT_KEY=""
  if tls_on; then TLS_UNIT_CERT="$CERT_DIR/fullchain.pem"; TLS_UNIT_KEY="$CERT_DIR/key.pem"; fi
  cat > "$SB_DIR/sub-server.py" <<'EOS'
#!/usr/bin/env python3
# Sing-Box-Plus 订阅服务：HTTP Basic 认证 + 密钥路径 + 短链接别名（/clash、/singbox）
import os, sys, base64
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

SUB_DIR  = os.environ.get('SUB_DIR', '/opt/sing-box/sub')
SUB_PORT = int(os.environ.get('SUB_PORT', '2088'))
SUB_USER = os.environ.get('SUB_USER', '')
SUB_PASS = os.environ.get('SUB_PASS', '')
SUB_PATH = os.environ.get('SUB_PATH', '').strip('/')
ALIAS = {'clash': 'clash.yaml', 'singbox': 'singbox.json'}

class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=SUB_DIR, **kw)

    def log_message(self, fmt, *args):
        sys.stderr.write('%s - [%s] %s\n' % (self.address_string(), self.log_date_time_string(), fmt % args))

    def _authed(self):
        # rules/ 目录（分流规则库）免认证：内容是公开的 geosite/geoip 列表，客户端取用不应依赖凭据
        p = self.path.split('?', 1)[0]
        if SUB_PATH and p.startswith('/' + SUB_PATH + '/rules/'):
            return True
        if not SUB_USER and not SUB_PASS:
            return True
        h = self.headers.get('Authorization', '')
        if not h.startswith('Basic '):
            return False
        try:
            raw = base64.b64decode(h[6:].strip()).decode('utf-8')
        except Exception:
            return False
        u, _, p = raw.partition(':')
        return u == SUB_USER and p == SUB_PASS

    def _gate(self):
        if self._authed():
            return True
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="sub"')
        self.send_header('Content-Length', '0')
        self.end_headers()
        return False

    def _rewrite(self):
        path = self.path.split('?', 1)[0]
        if SUB_PATH:
            if path == '/' + SUB_PATH or path == '/' + SUB_PATH + '/':
                path = '/'
            elif path.startswith('/' + SUB_PATH + '/'):
                path = path[len(SUB_PATH) + 1:]
            else:
                return None
        seg = path.lstrip('/')
        if seg in ALIAS:
            path = '/' + ALIAS[seg]
        return path

    def _prepare(self):
        if not self._gate():
            return False
        new = self._rewrite()
        if new is None:
            self.send_error(404, 'Not Found')
            return False
        if new == '/' or new.endswith('/'):
            new = '/index.html'
        self.path = new
        return True

    def do_GET(self):
        if self._prepare():
            try:
                super().do_GET()
            except (BrokenPipeError, ConnectionResetError):
                pass

    def do_HEAD(self):
        if self._prepare():
            try:
                super().do_HEAD()
            except (BrokenPipeError, ConnectionResetError):
                pass

    def list_directory(self, path):
        self.send_error(403, 'Forbidden')
        return None

if __name__ == '__main__':
    if not os.path.isdir(SUB_DIR):
        sys.stderr.write('SUB_DIR 不存在: %s\n' % SUB_DIR)
        sys.exit(1)
    srv = ThreadingHTTPServer(('0.0.0.0', SUB_PORT), Handler)
    tls_cert = os.environ.get('TLS_CERT', '')
    tls_key = os.environ.get('TLS_KEY', '')
    scheme = 'http'
    if tls_cert and tls_key and os.path.exists(tls_cert) and os.path.exists(tls_key):
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(tls_cert, tls_key)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        scheme = 'https'
    sys.stderr.write('订阅服务已启动: %s://0.0.0.0:%d  路径前缀=/%s  认证=%s\n' % (scheme, SUB_PORT, SUB_PATH, 'on' if SUB_USER else 'off'))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
EOS
  chmod +x "$SB_DIR/sub-server.py"

  cat > "/etc/systemd/system/${SUB_SERVICE}" <<EOS
[Unit]
Description=Sing-Box-Plus Subscription Server
After=network.target

[Service]
Type=simple
Environment=SUB_DIR=${SUB_DIR}
Environment=SUB_PORT=${SUB_PORT}
Environment=SUB_USER=${SUB_USER}
Environment=SUB_PASS=${SUB_PASS}
Environment=SUB_PATH=${SUB_PATH}
Environment=TLS_CERT=${TLS_UNIT_CERT}
Environment=TLS_KEY=${TLS_UNIT_KEY}
ExecStart=/usr/bin/env python3 ${SB_DIR}/sub-server.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOS
  systemctl daemon-reload
  systemctl enable "${SUB_SERVICE}" >/dev/null 2>&1 || true
}

serve_subs_start(){
  ensure_sub_secrets
  write_sub_server
  systemctl restart "${SUB_SERVICE}" >/dev/null 2>&1 || true
  if systemctl is-active --quiet "${SUB_SERVICE}"; then ok "订阅服务已启动（端口 ${SUB_PORT}）"; else warn "订阅服务启动失败，请查看: journalctl -u ${SUB_SERVICE} -n 50"; fi
  open_sub_firewall
}

serve_subs_stop(){
  systemctl stop "${SUB_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable "${SUB_SERVICE}" >/dev/null 2>&1 || true
  info "订阅服务已停止"
}

open_sub_firewall(){
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | pipe_has "active|活跃"; then
    ufw allow "${SUB_PORT}/tcp" >/dev/null 2>&1 || true; ufw reload >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${SUB_PORT}/tcp" >/dev/null 2>&1 || true; firewall-cmd --reload >/dev/null 2>&1 || true
  else
    iptables -C INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || true
    command -v ip6tables >/dev/null 2>&1 && { ip6tables -C INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p tcp --dport "$SUB_PORT" -j ACCEPT 2>/dev/null; }
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

show_subs(){
  build_links 4 || return 1
  ensure_sub_secrets
  local st; st=$(systemctl is-active "${SUB_SERVICE}" 2>/dev/null || echo inactive)
  local base; base="$(sub_base)"
  hr
  echo -e "${C_BLUE}${C_BOLD}📦 聚合订阅（一个链接包含全部 20 个节点）${C_RESET}"
  hr
  echo -e "  ${C_GREEN}聚合页（所有链接一目了然）${C_RESET}  ${base}/"
  echo -e "  ${C_GREEN}Clash / Mihomo 订阅        ${C_RESET}  ${base}/clash"
  echo -e "  ${C_GREEN}sing-box 订阅              ${C_RESET}  ${base}/singbox"
  echo -e "  ${C_GREEN}通用订阅（base64 全部）     ${C_RESET}  ${base}/all"
  echo -e "  ${C_DIM}仅直连: /direct   仅WARP: /warp   明文: /links.txt${C_RESET}"
  hr
  echo -e "  订阅服务状态: ${st}    端口: ${SUB_PORT}"
  echo -e "  ${C_DIM}访问账号: ${SUB_USER:-未设置}   密钥路径: /${SUB_PATH:-无}${C_RESET}"
  hr
}

# ---- 订阅菜单 ----
sub_menu(){
  while true; do
    build_links 4 >/dev/null 2>&1 || true
    local st; st=$(systemctl is-active "${SUB_SERVICE}" 2>/dev/null || echo inactive)
    hr
    echo -e " ${C_CYAN}📦 订阅服务（Clash / sing-box / 聚合）${C_RESET}"
    hr
    echo -e "  服务状态: ${st}   端口: ${SUB_PORT}   IP: ${PUB_IP:-未知}"
    hr
    echo -e "  ${C_GREEN}1)${C_RESET} 重新生成订阅（Clash + sing-box + 聚合页）"
    echo -e "  ${C_GREEN}2)${C_RESET} 查看订阅链接"
    echo -e "  ${C_GREEN}3)${C_RESET} 启动/重启订阅服务"
    echo -e "  ${C_GREEN}4)${C_RESET} 停止订阅服务"
    echo -e "  ${C_GREEN}5)${C_RESET} 修改订阅端口"
    echo -e "  ${C_GREEN}6)${C_RESET} 修改订阅账号密码"
    echo -e "  ${C_GREEN}7)${C_RESET} 重置密钥路径（换新 token）"
    echo -e "  ${C_GREEN}8)${C_RESET} 更新分流规则库（geosite/geoip）并重生成订阅"
    echo -e "  ${C_RED}0)${C_RESET} 返回主菜单"
    hr
    read -rp "选择: " sop || true
    case "${sop:-}" in
      1) gen_subs 4; read -rp "回车返回..." _ || true ;;
      2) show_subs; read -rp "回车返回..." _ || true ;;
      3) serve_subs_start; read -rp "回车返回..." _ || true ;;
      4) serve_subs_stop; read -rp "回车返回..." _ || true ;;
      5) read -rp "新端口(1024-65535): " np || true
         if [[ "$np" =~ ^[0-9]+$ ]] && [ "$np" -ge 1024 ] && [ "$np" -le 65535 ]; then
           SUB_PORT="$np"; write_sub_env; serve_subs_start; show_subs
         else warn "端口不合法"; fi
         read -rp "回车返回..." _ || true ;;
      6) read -rp "新账号(回车保留当前): " nu || true
         [[ -n "$nu" ]] && SUB_USER="$nu"
         read -rsp "新密码(回车=随机生成): " npw || true; echo
         if [[ -n "$npw" ]]; then SUB_PASS="$npw"; else SUB_PASS="$(gen_sub_pass)"; fi
         write_sub_env; serve_subs_start; show_subs
         read -rp "回车返回..." _ || true ;;
      7) SUB_PATH="$(gen_sub_path)"; write_sub_env; serve_subs_start; show_subs
         echo -e "  ${C_YELLOW}⚠ 密钥路径已更换，旧订阅链接失效，请到各客户端更新${C_RESET}"
         read -rp "回车返回..." _ || true ;;
      8) FORCE_RULES=1 ensure_rule_files; gen_subs 4; read -rp "回车返回..." _ || true ;;
      0) return 0 ;;
    esac
  done
}

# ---- TLS / 域名设置菜单 ----
tls_menu(){
  while true; do
    local crt="$CERT_DIR/fullchain.pem" csubj="" cexp=""
    if [[ -s "$crt" ]]; then
      csubj=$(openssl x509 -in "$crt" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
      cexp=$(openssl x509 -in "$crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    fi
    hr
    echo -e " ${C_CYAN}🔒 TLS / 域名（真证书）${C_RESET}"
    hr
    if tls_on; then echo -e "  状态: ${C_GREEN}已启用（订阅 HTTPS + 节点真证书）${C_RESET}"; else echo -e "  状态: ${C_DIM}未启用（使用自签证书，节点需 insecure）${C_RESET}"; fi
    echo -e "  域名: ${TLS_DOMAIN:-（未设置）}"
    if [[ -n "$TLS_SAN" ]]; then echo -e "  额外域名(SAN): ${TLS_SAN//,/, }"; else echo -e "  额外域名(SAN): （无）"; fi
    echo -e "  ${C_DIM}证书主体: ${csubj:-—}    到期: ${cexp:-—}${C_RESET}"
    if [[ -s "$crt" ]]; then
      echo -e "  ${C_DIM}证书覆盖: $(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' ' | tr '\n' ' ')${C_RESET}"
    fi
    hr
    echo -e "  ${C_GREEN}1)${C_RESET} 申请 / 更新证书（DNS-01，走 Cloudflare）"
    echo -e "  ${C_GREEN}3)${C_RESET} 追加/修改 SAN 并重签（复用已存 Token）"
    echo -e "  ${C_GREEN}2)${C_RESET} 关闭 TLS（回退自签证书）"
    echo -e "  ${C_RED}0)${C_RESET} 返回主菜单"
    hr
    read -rp "选择: " top || true
    case "${top:-}" in
      1) read -rp "域名 (如 node.ezynode.net): " td || true
         [[ -n "$td" ]] || { warn "域名不能为空"; read -rp "回车返回..." _ || true; continue; }
         read -rp "邮箱 (Let's Encrypt 通知用): " te || true
         cf_token_hint
         read -rsp "Cloudflare API Token (Zone:DNS:Edit): " tk || true; echo
         tk="${tk//[$'\r'$'\n']/}"; tk="${tk#"${tk%%[![:space:]]*}"}"; tk="${tk%"${tk##*[![:space:]]}"}"
         [[ -n "$tk" ]] || { warn "Token 不能为空"; read -rp "回车返回..." _ || true; continue; }
         read -rp "额外域名/SAN（空格分隔，可留空；如 *.ezylink.cc.cd node.ezylink.cc.cd）: " ts || true
         TLS_DOMAIN="$td"; TLS_EMAIL="$te"; TLS_CF_TOKEN="$tk"; TLS_SAN="${ts// /,}"; write_tls_env
         if acme_issue; then
           write_sub_server; systemctl restart "${SUB_SERVICE}" >/dev/null 2>&1 || true
           systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
           gen_subs 4 || true
           ok "TLS 已启用：订阅走 HTTPS，hy2/tuic/anytls 换真证书"
           show_subs
         fi
         read -rp "回车返回..." _ || true ;;
      3) [[ -n "$TLS_DOMAIN" && -n "$TLS_CF_TOKEN" ]] || { warn "尚未配置域名/Token，请先用 1) 申请"; read -rp "回车返回..." _ || true; continue; }
         read -rp "额外域名/SAN（空格分隔，留空=仅主域名；支持 *.域名）: " ts || true
         TLS_SAN="${ts// /,}"; write_tls_env
         if acme_issue; then
           systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
           gen_subs 4 || true
           ok "证书已重签：覆盖 ${TLS_DOMAIN}${TLS_SAN:+ + ${TLS_SAN//,/, }}"
           show_subs
         fi
         read -rp "回车返回..." _ || true ;;
      2) TLS_DOMAIN=""; TLS_EMAIL=""; TLS_CF_TOKEN=""; TLS_SAN=""; write_tls_env
         rm -f "$CERT_DIR/fullchain.pem" "$CERT_DIR/key.pem"; mk_cert
         write_sub_server; systemctl restart "${SUB_SERVICE}" >/dev/null 2>&1 || true
         systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
         gen_subs 4 || true
         ok "已关闭 TLS，回退自签证书（节点恢复 insecure）"
         read -rp "回车返回..." _ || true ;;
      0) return 0 ;;
    esac
  done
}

# ---- 快捷命令：自动安装 singbox 软链（输入 singbox 即打开本菜单） ----
ensure_shortcut(){
  local dir="${SBP_SHORTCUT_DIR:-/usr/local/bin}" target self
  self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
  [[ -n "$self" && -f "$self" ]] || return 0
  case "$(basename "$self")" in
    *.sh|singbox|*sing-box*|*sing*box*) : ;;
    *) return 0 ;;
  esac
  target="$dir/singbox"
  [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0
  [[ -x "$self" ]] || chmod +x "$self" 2>/dev/null || true
  [[ "$(readlink -f -- "$target" 2>/dev/null || true)" == "$self" ]] && return 0
  ln -sf "$self" "$target" 2>/dev/null || return 0
  ok "已装好快捷命令：以后直接输入 ${C_CYAN}singbox${C_RESET} 就能打开本菜单"
}

# ===== 菜单 =====
menu(){
  ensure_shortcut || true
  banner
  read -rp "选择: " op || true
  case "${op:-}" in
  1)
  sbp_bootstrap                                     # 依赖/二进制回退
  set +e                                            # ← 关闭严格退出，避免中途被杀掉
  echo -e "${C_BLUE}[信息] 正在检查 sing-box 安装状态...${C_RESET}"
  install_singbox            || true
  ensure_warpcli_proxy        || true
  write_config               || { echo "[ERR] 生成配置失败"; }
  write_systemd              || true
  open_firewall              || true
  systemctl restart "${SYSTEMD_SERVICE}" || true
  gen_subs 4 || true                                    # 生成 Clash/sing-box/聚合订阅
  serve_subs_start || true                              # 启动订阅服务
  set -e                                            # ← 恢复严格模式
  print_links_grouped
  exit 0                                          # ← 打印后直接退出
  ;;
  2) if ensure_installed_or_hint; then print_links_grouped 4; exit 0; fi ;;
  3) if ensure_installed_or_hint; then print_links_grouped 6; exit 0; fi ;;
  4) if ensure_installed_or_hint; then restart_service; fi; read -rp "回车返回..." _ || true; menu ;;
  5) if ensure_installed_or_hint; then rotate_ports; fi; menu ;;
  6) enable_bbr; read -rp "回车返回..." _ || true; menu ;;
  7) sub_menu; read -rp "回车返回..." _ || true; menu ;;
  8) tls_menu; read -rp "回车返回..." _ || true; menu ;;
  9) uninstall_all ;; # 直接退出
  0) exit 0 ;;
  *) menu ;;
  esac
}

# ===== 入口 =====
menu
