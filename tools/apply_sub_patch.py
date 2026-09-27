#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把「订阅增强模块」打进上游 sing-box-plus.sh，生成 fork 版脚本。
用法: python3 apply_sub_patch.py <上游脚本> <订阅模块> <输出脚本>
可重复执行（每次以上游为准重新生成，便于跟进上游更新）。
"""
import sys, re

NEW_PRINT = r'''print_links_grouped(){
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
'''


def main():
    upstream, blockf, out = sys.argv[1], sys.argv[2], sys.argv[3]
    src = open(upstream, encoding="utf-8").read()
    block = open(blockf, encoding="utf-8").read()

    # 0) 版本标记
    src = src.replace(
        'SCRIPT_VERSION="${SCRIPT_VERSION:-',
        'SCRIPT_VERSION="${SCRIPT_VERSION:-',
    )

    # 1) 模块插入到「菜单」之前
    marker = "# ===== 菜单 ====="
    if marker not in src:
        sys.exit("找不到菜单标记")
    src = src.replace(marker, block + "\n" + marker, 1)

    # 2) 用 build_links 版重写 print_links_grouped
    start = src.index("print_links_grouped(){")
    end = src.index("# ===== BBR =====")
    src = src[:start] + NEW_PRINT + "\n" + src[end:]

    # 3) banner 增加 7) 菜单项 + fork 标记
    old_bbr = 'echo -e "  ${C_GREEN}5)${C_RESET} 一键开启 BBR"'
    if old_bbr not in src:
        sys.exit("找不到 banner 锚点")
    src = src.replace(old_bbr, old_bbr +
                      '\n  echo -e "  ${C_MAGENTA}7)${C_RESET} 订阅链接（Clash / sing-box / 聚合）"'
                      '\n  echo -e "  ${C_MAGENTA}9)${C_RESET} TLS / 域名（真证书：订阅HTTPS + 节点）"', 1)
    old_url = 'echo -e "${C_CYAN} 脚本更新地址: https://github.com/Alvin9999-newpac/Sing-Box-Plus${C_RESET}"'
    src = src.replace(old_url, old_url +
                      '\n  echo -e "${C_MAGENTA} 订阅增强版：一键生成 Clash / sing-box / 聚合订阅（20 节点一条链接）${C_RESET}"', 1)

    # 4) 主菜单 7) 入口
    old_case = '5) enable_bbr; read -rp "回车返回..." _ || true; menu ;;'
    if old_case not in src:
        sys.exit("找不到菜单 case 锚点")
    src = src.replace(old_case, old_case +
                      '\n    7) sub_menu; read -rp "回车返回..." _ || true; menu ;;'
                      '\n    9) tls_menu; read -rp "回车返回..." _ || true; menu ;;', 1)

    # 4.5) 进入菜单前自动安装 singbox 快捷命令（幂等）
    old_menu = 'menu(){\n  banner'
    if old_menu not in src:
        sys.exit("找不到 menu 锚点")
    src = src.replace(old_menu, 'menu(){\n  ensure_shortcut || true\n  banner', 1)

    # 5) 安装流程结束后自动生成订阅并起服务
    old_inst = 'systemctl restart "${SYSTEMD_SERVICE}" || true\n  set -e'
    if old_inst not in src:
        sys.exit("找不到安装流程锚点")
    src = src.replace(old_inst,
                      'systemctl restart "${SYSTEMD_SERVICE}" || true\n'
                      '  gen_subs 4 || true                                    # 生成 Clash/sing-box/聚合订阅\n'
                      '  serve_subs_start || true                              # 启动订阅服务\n'
                      '  set -e', 1)

    # 6) 更换端口后重生成订阅
    old_rot = '  systemctl restart "${SYSTEMD_SERVICE}"\n\n  info "已更换端口并重启。"'
    if old_rot not in src:
        sys.exit("找不到换端口锚点")
    src = src.replace(old_rot,
                      '  systemctl restart "${SYSTEMD_SERVICE}"\n'
                      '  gen_subs 4 || true                                    # 端口变了，同步重生成订阅\n\n'
                      '  info "已更换端口并重启（订阅已同步更新）。"', 1)

    with open(out, "w", encoding="utf-8") as f:
        f.write(src)
    print("patched ->", out, len(src), "bytes")


if __name__ == "__main__":
    main()
