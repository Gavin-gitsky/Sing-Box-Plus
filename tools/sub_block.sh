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

# 带凭据+密钥路径的订阅根地址（未配置凭据时退回裸地址）
sub_base(){
  local host="${1:-$PUB_IP}"
  if [[ -z "$SUB_USER" && -f "$SB_DIR/sub.env" ]]; then safe_source_env "$SB_DIR/sub.env" 2>/dev/null || true; fi
  if [[ -n "$SUB_USER" ]]; then
    printf 'http://%s:%s@%s:%s/%s' "$SUB_USER" "$SUB_PASS" "$host" "$SUB_PORT" "$SUB_PATH"
  else
    printf 'http://%s:%s' "$host" "$SUB_PORT"
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
  [[ -n "$SUB_USER" ]] || { SUB_USER="gavin"; changed=1; }
  [[ -n "$SUB_PASS" ]] || { SUB_PASS="$(gen_sub_pass)"; changed=1; }
  [[ -n "$SUB_PATH" ]] || { SUB_PATH="$(gen_sub_path)"; changed=1; }
  [[ "$changed" == "1" ]] && write_sub_env
  return 0
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
  local VMESS_JSON VMESS_JSON_W

  LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality")
  LINKS_DIRECT+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${RS_GR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality")
  LINKS_DIRECT+=("trojan://${UUID}@${host}:${PORT_TROJANR}?security=reality&sni=${RS_TR}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality")
  LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#hysteria2")
  VMESS_JSON=$(printf '{"v":"2","ps":"vmess-ws","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' "$ip" "$PORT_VMESS_WS" "$UUID" "$VMESS_WS_PATH")
  LINKS_DIRECT+=("vmess://$(printf "%s" "$VMESS_JSON" | b64enc)")
  LINKS_DIRECT+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs")
  LINKS_DIRECT+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022}#ss2022")
  LINKS_DIRECT+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS}#ss")
  LINKS_DIRECT+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#tuic-v5")
  LINKS_DIRECT+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS}?insecure=1&sni=${REALITY_SERVER}#anytls")

  LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RS_VRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality-warp")
  LINKS_WARP+=("vless://${UUID}@${host}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${RS_GRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality-warp")
  LINKS_WARP+=("trojan://${UUID}@${host}:${PORT_TROJANR_W}?security=reality&sni=${RS_TRW}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality-warp")
  LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD}")@${host}:${PORT_HY2_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#hysteria2-warp")
  VMESS_JSON_W=$(printf '{"v":"2","ps":"vmess-ws-warp","add":"%s","port":"%s","id":"%s","aid":"0","net":"ws","type":"none","host":"","path":"%s","tls":""}' "$ip" "$PORT_VMESS_WS_W" "$UUID" "$VMESS_WS_PATH")
  LINKS_WARP+=("vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)")
  LINKS_WARP+=("hy2://$(urlenc "${HY2_PWD2}")@${host}:${PORT_HY2_OBFS_W}?insecure=1&allowInsecure=1&sni=${REALITY_SERVER}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs-warp")
  LINKS_WARP+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${host}:${PORT_SS2022_W}#ss2022-warp")
  LINKS_WARP+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${host}:${PORT_SS_W}#ss-warp")
  LINKS_WARP+=("tuic://${UUID}:$(urlenc "${UUID}")@${host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${REALITY_SERVER}#tuic-v5-warp")
  LINKS_WARP+=("anytls://$(urlenc "${ANYTLS_PWD}")@${host}:${PORT_ANYTLS_W}?insecure=1&sni=${REALITY_SERVER}#anytls-warp")

  LINKS_ALL=("${LINKS_DIRECT[@]}" "${LINKS_WARP[@]}")
  return 0
}

# ---- 生成：Clash / Mihomo 订阅 ----
gen_clash_sub(){
  load_env || true; load_creds || true; load_ports || true
  [[ -n "$PUB_HOST" ]] || build_links 4 || return 1
  mkdir -p "$SUB_DIR"
  local f="$SUB_DIR/clash.yaml" ip="$PUB_IP"
  local names=() lines=()
  addp(){ names+=("$1"); lines+=("- {$2}"); }
  local i

  # 直连 10
  addp vless-reality "name: 'vless-reality', type: vless, server: '$ip', port: $PORT_VLESSR, uuid: '$UUID', udp: true, tls: true, flow: xtls-rprx-vision, servername: '$RS_VR', client-fingerprint: chrome, network: tcp, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vless-grpc-reality "name: 'vless-grpc-reality', type: vless, server: '$ip', port: $PORT_VLESS_GRPCR, uuid: '$UUID', udp: true, tls: true, servername: '$RS_GR', client-fingerprint: chrome, network: grpc, grpc-opts: {grpc-service-name: '$GRPC_SERVICE'}, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp trojan-reality "name: 'trojan-reality', type: trojan, server: '$ip', port: $PORT_TROJANR, password: '$UUID', udp: true, sni: '$RS_TR', client-fingerprint: chrome, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vmess-ws "name: 'vmess-ws', type: vmess, server: '$ip', port: $PORT_VMESS_WS, uuid: '$UUID', alterId: 0, cipher: auto, udp: true, network: ws, ws-opts: {path: '$VMESS_WS_PATH'}"
  addp hysteria2 "name: 'hysteria2', type: hysteria2, server: '$ip', port: $PORT_HY2, password: '$HY2_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, alpn: [h3], udp: true"
  addp hysteria2-obfs "name: 'hysteria2-obfs', type: hysteria2, server: '$ip', port: $PORT_HY2_OBFS, password: '$HY2_PWD2', obfs: salamander, obfs-password: '$HY2_OBFS_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, alpn: [h3], udp: true"
  addp ss2022 "name: 'ss2022', type: ss, server: '$ip', port: $PORT_SS2022, cipher: 2022-blake3-aes-256-gcm, password: '$SS2022_KEY', udp: true"
  addp ss "name: 'ss', type: ss, server: '$ip', port: $PORT_SS, cipher: aes-256-gcm, password: '$SS_PWD', udp: true"
  addp tuic-v5 "name: 'tuic-v5', type: tuic, server: '$ip', port: $PORT_TUIC, uuid: '$TUIC_UUID', password: '$TUIC_PWD', udp: true, alpn: [h3], skip-cert-verify: true, congestion-controller: bbr"
  addp anytls "name: 'anytls', type: anytls, server: '$ip', port: $PORT_ANYTLS, password: '$ANYTLS_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, udp: true, client-fingerprint: chrome"

  # WARP 10
  addp vless-reality-warp "name: 'vless-reality-warp', type: vless, server: '$ip', port: $PORT_VLESSR_W, uuid: '$UUID', udp: true, tls: true, flow: xtls-rprx-vision, servername: '$RS_VRW', client-fingerprint: chrome, network: tcp, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vless-grpc-reality-warp "name: 'vless-grpc-reality-warp', type: vless, server: '$ip', port: $PORT_VLESS_GRPCR_W, uuid: '$UUID', udp: true, tls: true, servername: '$RS_GRW', client-fingerprint: chrome, network: grpc, grpc-opts: {grpc-service-name: '$GRPC_SERVICE'}, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp trojan-reality-warp "name: 'trojan-reality-warp', type: trojan, server: '$ip', port: $PORT_TROJANR_W, password: '$UUID', udp: true, sni: '$RS_TRW', client-fingerprint: chrome, reality-opts: {public-key: '$REALITY_PUB', short-id: '$REALITY_SID'}"
  addp vmess-ws-warp "name: 'vmess-ws-warp', type: vmess, server: '$ip', port: $PORT_VMESS_WS_W, uuid: '$UUID', alterId: 0, cipher: auto, udp: true, network: ws, ws-opts: {path: '$VMESS_WS_PATH'}"
  addp hysteria2-warp "name: 'hysteria2-warp', type: hysteria2, server: '$ip', port: $PORT_HY2_W, password: '$HY2_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, alpn: [h3], udp: true"
  addp hysteria2-obfs-warp "name: 'hysteria2-obfs-warp', type: hysteria2, server: '$ip', port: $PORT_HY2_OBFS_W, password: '$HY2_PWD2', obfs: salamander, obfs-password: '$HY2_OBFS_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, alpn: [h3], udp: true"
  addp ss2022-warp "name: 'ss2022-warp', type: ss, server: '$ip', port: $PORT_SS2022_W, cipher: 2022-blake3-aes-256-gcm, password: '$SS2022_KEY', udp: true"
  addp ss-warp "name: 'ss-warp', type: ss, server: '$ip', port: $PORT_SS_W, cipher: aes-256-gcm, password: '$SS_PWD', udp: true"
  addp tuic-v5-warp "name: 'tuic-v5-warp', type: tuic, server: '$ip', port: $PORT_TUIC_W, uuid: '$TUIC_UUID', password: '$TUIC_PWD', udp: true, alpn: [h3], skip-cert-verify: true, congestion-controller: bbr"
  addp anytls-warp "name: 'anytls-warp', type: anytls, server: '$ip', port: $PORT_ANYTLS_W, password: '$ANYTLS_PWD', sni: '$REALITY_SERVER', skip-cert-verify: true, udp: true, client-fingerprint: chrome"

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
rules:
  - 'DOMAIN-SUFFIX,cn,DIRECT'
  - 'GEOIP,CN,DIRECT,no-resolve'
  - 'MATCH,漏网之鱼'
EOF
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

  _node(){ # $1 tag $2 json
    jq -n --argjson n "$2" '$n' >>/dev/null
  }

  jq -n \
    --arg ip "$ip" --arg UID "$UUID" --arg PUB "$REALITY_PUB" --arg SID "$REALITY_SID" \
    --arg RSVR "$RS_VR" --arg RSGR "$RS_GR" --arg RSTR "$RS_TR" \
    --arg RSVRW "$RS_VRW" --arg RSGRW "$RS_GRW" --arg RSTRW "$RS_TRW" \
    --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg RSV "$REALITY_SERVER" \
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
      {type:"hysteria2",tag:$t,server:$ip,server_port:$p,password:$pw,
       tls:{enabled:true,insecure:true,alpn:["h3"],server_name:$RSV}};
    def hy2o($t;$p;$pw;$opw;$suffix):
      {type:"hysteria2",tag:$t,server:$ip,server_port:$p,password:$pw,
       obfs:{type:"salamander",password:$opw},
       tls:{enabled:true,insecure:true,alpn:["h3"],server_name:$RSV}};
    def ss2022($t;$p;$suffix):
      {type:"shadowsocks",tag:$t,server:$ip,server_port:$p,method:"2022-blake3-aes-256-gcm",password:$SS2022};
    def ss($t;$p;$suffix):
      {type:"shadowsocks",tag:$t,server:$ip,server_port:$p,method:"aes-256-gcm",password:$SSPWD};
    def tuic($t;$p;$suffix):
      {type:"tuic",tag:$t,server:$ip,server_port:$p,uuid:$TUICUUID,password:$TUICPWD,
       congestion_control:"bbr",tls:{enabled:true,insecure:true,alpn:["h3"],server_name:$RSV}};
    def anytls($t;$p;$suffix):
      {type:"anytls",tag:$t,server:$ip,server_port:$p,password:$ANYTLS,
       tls:{enabled:true,insecure:true,server_name:$RSV}};
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
  gen_clash_sub || true
  gen_singbox_sub || true
  gen_all_sub "${1:-4}" || true
}

# ---- 订阅 HTTP 服务 ----
write_sub_server(){
  mkdir -p "$SUB_DIR"
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
    sys.stderr.write('订阅服务已启动: 0.0.0.0:%d  路径前缀=/%s  认证=%s\n' % (SUB_PORT, SUB_PATH, 'on' if SUB_USER else 'off'))
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
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q -E "active|活跃"; then
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
      6) read -rp "新账号(回车保留 ${SUB_USER:-gavin}): " nu || true
         [[ -n "$nu" ]] && SUB_USER="$nu"
         read -rsp "新密码(回车=随机生成): " npw || true; echo
         if [[ -n "$npw" ]]; then SUB_PASS="$npw"; else SUB_PASS="$(gen_sub_pass)"; fi
         write_sub_env; serve_subs_start; show_subs
         read -rp "回车返回..." _ || true ;;
      7) SUB_PATH="$(gen_sub_path)"; write_sub_env; serve_subs_start; show_subs
         echo -e "  ${C_YELLOW}⚠ 密钥路径已更换，旧订阅链接失效，请到各客户端更新${C_RESET}"
         read -rp "回车返回..." _ || true ;;
      0) return 0 ;;
    esac
  done
}
