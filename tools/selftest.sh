#!/usr/bin/env bash
# 本地离线自测：验证订阅生成（无需 VPS / root）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1
export SB_DIR=/tmp/sbtest
rm -rf "$SB_DIR"; mkdir -p "$SB_DIR/cert" "$SB_DIR/sub" "$SB_DIR/data"

cat > "$SB_DIR/env.conf" <<'EOF'
REALITY_SERVER=www.microsoft.com
REALITY_SERVER_PORT=443
GRPC_SERVICE=grpc
VMESS_WS_PATH=/vm
ENABLE_WARP=true
EOF

cat > "$SB_DIR/creds.env" <<'EOF'
UUID=11111111-2222-3333-4444-555555555555
REALITY_PRIV=PRIVKEYxxxx
REALITY_PUB=PUBKEYyyyy
REALITY_SID=abcd1234
RS_VR=swift.org
RS_GR=www.apple.com
RS_TR=yahoo.com
RS_VRW=swift.org
RS_GRW=www.apple.com
RS_TRW=yahoo.com
HY2_PWD=hy2passAAAA
HY2_PWD2=hy2passBBBB
HY2_OBFS_PWD=obfspass1234
SS2022_KEY=SS2022KEY+/=base64
SS_PWD=sspass1234
TUIC_UUID=11111111-2222-3333-4444-555555555555
TUIC_PWD=tuicpass1234
ANYTLS_PWD=anytlspass1234
EOF

# 用真实 reality 密钥对（否则 mihomo 体检会因假公钥报错）
KP=$(/vol1/@apphome/trim.openclaw/data/mihomo/mihomo generate reality-keypair 2>/dev/null)
RPRIV=$(printf '%s\n' "$KP" | awk '/PrivateKey/{print $2}')
RPUB=$(printf '%s\n' "$KP" | awk '/PublicKey/{print $2}')
sed -i "s|^REALITY_PRIV=.*|REALITY_PRIV=${RPRIV}|" "$SB_DIR/creds.env"
sed -i "s|^REALITY_PUB=.*|REALITY_PUB=${RPUB}|" "$SB_DIR/creds.env"
sed -i "s|^SS2022_KEY=.*|SS2022_KEY=$(openssl rand -base64 32)|" "$SB_DIR/creds.env"

cat > "$SB_DIR/ports.env" <<'EOF'
PORT_VLESSR=20001
PORT_VLESS_GRPCR=20002
PORT_TROJANR=20003
PORT_HY2=20004
PORT_VMESS_WS=20005
PORT_HY2_OBFS=20006
PORT_SS2022=20007
PORT_SS=20008
PORT_TUIC=20009
PORT_ANYTLS=20010
PORT_VLESSR_W=20101
PORT_VLESS_GRPCR_W=20102
PORT_TROJANR_W=20103
PORT_HY2_W=20104
PORT_VMESS_WS_W=20105
PORT_HY2_OBFS_W=20106
PORT_SS2022_W=20107
PORT_SS_W=20108
PORT_TUIC_W=20109
PORT_ANYTLS_W=20110
EOF

# 载入被补丁后的脚本（去掉末尾 menu 调用）
sed '$d' sing-box-plus.sh | grep -v '^stty erase' | sed 's/^set -Eeuo pipefail/set +e/' > /tmp/sbp-lib.sh
# shellcheck disable=SC1091
source /tmp/sbp-lib.sh
set +e

get_ip4(){ echo "203.0.113.9"; }
get_ip6(){ echo ""; }

echo "############ gen_subs ############"
gen_subs 4
echo "############ 产物 ############"
ls -la "$SB_DIR/sub"
echo "############ 校验 ############"
python3 - <<'PY'
import yaml, json, sys
c = yaml.safe_load(open('/tmp/sbtest/sub/clash.yaml'))
print("clash proxies:", len(c['proxies']), "groups:", len(c['proxy-groups']), "rules:", len(c['rules']))
print("clash group names:", [g['name'] for g in c['proxy-groups']])
print("first proxy:", json.dumps(c['proxies'][0], ensure_ascii=False))
print("node-select refs ok:", set(c['proxy-groups'][0]['proxies']) <= {p['name'] for p in c['proxies']})
print("no auto groups:", not ({'自动选择','直连节点','WARP节点'} & {g['name'] for g in c['proxy-groups']}))
print("clash default node:", c['proxy-groups'][0]['proxies'][0])
s = json.load(open('/tmp/sbtest/sub/singbox.json'))
print("singbox outbounds:", len(s['outbounds']), "final:", s['route']['final'])
print("singbox groups:", [o['tag'] for o in s['outbounds'] if o['type'] in ('selector','urltest')])
print("singbox default node:", [o.get('default') for o in s['outbounds'] if o.get('tag')=='节点选择'])
tags = [o['tag'] for o in s['outbounds']]
for o in s['outbounds']:
    if o['type'] in ('selector','urltest'):
        miss = [x for x in o['outbounds'] if x not in tags]
        if miss: print("!! dangling refs in", o['tag'], miss)
print("singbox dangling check done")
PY
echo "############ links ############"
wc -l "$SB_DIR/sub/links.txt"
head -2 "$SB_DIR/sub/links.txt"
echo "base64 decode check:"; base64 -d "$SB_DIR/sub/all" | wc -l
echo "############ mihomo 配置体检 ############"
mkdir -p /tmp/sbtest/mihomod
# 复用本机 geo 数据，避免在线下载卡住
cp -f /vol1/@apphome/trim.openclaw/data/mihomo/geoip.metadb /tmp/sbtest/mihomod/ 2>/dev/null || true
cp -f /vol1/@apphome/trim.openclaw/data/mihomo/GeoSite.dat /tmp/sbtest/mihomod/ 2>/dev/null || true
cp -f /vol1/@apphome/trim.openclaw/data/mihomo/geosite.dat /tmp/sbtest/mihomod/geosite.dat 2>/dev/null || true
timeout 60 /vol1/@apphome/trim.openclaw/data/mihomo/mihomo -t -d /tmp/sbtest/mihomod -f "$SB_DIR/sub/clash.yaml" 2>&1 | tail -20
