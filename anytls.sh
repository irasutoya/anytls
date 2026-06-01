#!/usr/bin/env bash
set -euo pipefail

# AnyTLS Server Manager
# Repo: https://github.com/irasutoya/anytls

GH_RELEASE="https://github.com/anytls/anytls-go/releases"
GH_PROXY="https://ghproxy.net/${GH_RELEASE}"
DEF_DOMAIN="gateway.icloud.com"
DEF_PORT=443
FALLBACK_VER="0.0.12"

# Cyberpunk palette
PINK='\033[35m'; CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

die()   { echo -e " ${RED}[-]${NC} $*" >&2; exit 1; }
ok()    { echo -e " ${GREEN}[+]${NC} $*"; }
warn()  { echo -e " ${YELLOW}[!]${NC} $*"; }
step()  { echo -e " ${CYAN}[*]${NC} $*"; }
head()  { echo -e "\n ${PINK}${BOLD}>>${NC} ${BOLD}$*${NC}"; }
dim()   { echo -e " ${DIM}$*${NC}"; }
prompt(){ echo -ne " ${CYAN}[?]${NC} $*"; }

cleanup() {
    local d; for d in "$@"; do rm -rf "$d" 2>/dev/null; done
}

commit_id() {
    local rev; rev=$(curl -sS --max-time 3 "https://api.github.com/repos/irasutoya/anytls/commits/main" 2>/dev/null) || true
    rev=$(echo "$rev" | grep -m1 '"sha"' | cut -d'"' -f4) || true
    rev=${rev:0:7}
    [ -n "$rev" ] && echo "@${rev}" || true
}

banner() {
    local rev; rev=$(commit_id)
    head "AnyTLS Server Manager ${rev}"
}

pkg_mgr() {
    command -v apt-get >/dev/null && { echo "apt-get install -y"; return; }
    command -v dnf >/dev/null    && { echo "dnf install -y"; return; }
    command -v yum >/dev/null    && { echo "yum install -y"; return; }
    command -v apk >/dev/null    && { echo "apk add"; return; }
    echo ""
}

check_deps() {
    local missing=() names=()
    for cmd in curl unzip openssl; do
        command -v "$cmd" >/dev/null || { missing+=("$cmd"); names+=("$cmd"); }
    done
    command -v systemctl >/dev/null || { missing+=("systemd"); names+=("systemd"); }
    [ ${#missing[@]} -eq 0 ] && return 0

    local pm; pm=$(pkg_mgr)
    if [ -n "$pm" ]; then
        warn "缺少依赖: ${names[*]}"
        prompt "是否自动安装？${DIM}[Y/n]${NC} "
        read -r ans
        case "$ans" in n|N|no|NO) die "用户取消" ;; esac
        $pm "${missing[@]}" || die "安装依赖失败"
    else
        die "缺少依赖: ${names[*]}，请手动安装"
    fi
}

detect_asset() {
    local arch; arch=$(uname -m) || die "无法检测系统架构"
    local tag; tag=$(curl -sS --max-time 5 "https://api.github.com/repos/anytls/anytls-go/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4) || tag=""
    local ver=${tag#v}
    if [ -z "$ver" ]; then
        ver=$FALLBACK_VER
        warn "无法获取最新版本，使用 v${ver} 作为 fallback"
    fi

    case "$arch" in
        x86_64|amd64) echo "anytls_${ver}_linux_amd64.zip" ;;
        aarch64|arm64) echo "anytls_${ver}_linux_arm64.zip" ;;
        *) die "不支持的架构: $arch" ;;
    esac
    echo "$ver"
}

download() {
    local asset=$1 ver=$2
    local tag="v${ver}"
    local url="$GH_RELEASE/download/${tag}/${asset}" fallback="$GH_PROXY/download/${tag}/${asset}"
    local tmpdir; tmpdir=$(mktemp -d) || die "创建临时目录失败"
    trap "cleanup '$tmpdir'" EXIT

    step "下载 $asset ..."
    curl -#SL "$url" -o "$tmpdir/$asset" || {
        warn "GitHub 直连失败，尝试代理 ..."
        curl -#SL "$fallback" -o "$tmpdir/$asset" || die "下载失败（直连和代理均不可用）"
    }

    unzip -o "$tmpdir/$asset" -d "$tmpdir" >/dev/null 2>&1 || die "解压失败"
    mkdir -p /root/anytls
    cp -f "$tmpdir/anytls-server" /root/anytls/anytls-server
    chmod +x /root/anytls/anytls-server
    rm -rf "$tmpdir"
    trap - EXIT
    ok "二进制安装完成"
}

gen_password() {
    local hex; hex=$(openssl rand -hex 16 2>/dev/null) || hex=""
    if [ ${#hex} -lt 32 ]; then
        echo "$(date +%s)-0000-4000-8000-$(date +%s | sha256sum | head -c 12)"
        return
    fi
    local h1=${hex:0:8} h2=${hex:8:4} h3=${hex:12:4}
    local h4=${hex:16:4} h5=${hex:20:12}
    local h4_first; printf -v h4_first '%x' $((0x${h4:0:1} & 0x3 | 0x8)) 2>/dev/null || h4_first="8"
    echo "${h1}-${h2}-4${h3:1:3}-${h4_first}${h4:1:3}-${h5}"
}

install_service() {
    local port=$1 password=$2
    cat > /etc/systemd/system/anytls-server.service <<EOF
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=LOG_LEVEL=warn
ExecStart=/root/anytls/anytls-server -l 0.0.0.0:${port} -p ${password}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 重载失败"
    systemctl enable --now anytls-server.service || warn "服务启用失败，请手动检查: journalctl -u anytls-server.service"
    ok "systemd 服务已安装并启动"
}

get_ip() {
    curl -4 -sS --max-time 5 https://ip.sb 2>/dev/null ||
    curl -4 -sS --max-time 5 https://api.ipify.org 2>/dev/null ||
    curl -4 -sS --max-time 5 https://ifconfig.me 2>/dev/null ||
    curl -6 -sS --max-time 5 https://ip.sb 2>/dev/null ||
    hostname -f
}

urlencode() {
    local str="$1" out="" i c
    for ((i=0; i<${#str}; i++)); do
        c="${str:$i:1}"
        case "$c" in [a-zA-Z0-9.~_-]) out+="$c" ;; *) printf -v out '%s%%%02X' "$out" "'$c" ;; esac
    done
    echo "$out"
}

# ===== Actions =====

do_install() {
    [ "$(id -u)" -ne 0 ] && die "请以 root 运行"
    local domain=${1:-} port=${2:-} password=${3:-}

    if [ $# -eq 0 ]; then
        prompt "伪装域名 (SNI) ${DIM}[${DEF_DOMAIN}]${NC}: "
        read -r domain || domain="$DEF_DOMAIN"; domain=${domain:-$DEF_DOMAIN}
        prompt "监听端口 ${DIM}[${DEF_PORT}]${NC}: "
        read -r port || port="$DEF_PORT"; port=${port:-$DEF_PORT}
        prompt "密码（留空自动生成）: "
        read -rs password || password=""; echo
        password=${password:-$(gen_password)}
    fi
    [ -z "$port" ] && port=$DEF_PORT
    [ -z "$password" ] && password=$(gen_password)

    head "初始化部署环境"
    step "检测架构..."
    local asset_info; asset_info=$(detect_asset)
    local asset; asset=$(echo "$asset_info" | head -1)
    local ver; ver=$(echo "$asset_info" | tail -1)
    dim "目标: $asset"

    download "$asset" "$ver"
    install_service "$port" "$password"

    prompt "配置防火墙放行 ${port} 端口？${DIM}[Y/n]${NC}: "
    read -r ans || ans="y"
    case "$ans" in n|N|no|NO) ;; *) config_firewall "$port" ;; esac

    local ip pw_enc; ip=$(get_ip); pw_enc=$(urlencode "$password")
    local share_link="anytls://${ip}:${port}?password=${pw_enc}&sni=${domain}&allowInsecure=1"

    head "AnyTLS 部署完成"
    echo ""
    step "节点信息"
    dim "  地址  ${ip}:${port}"
    dim "  密码  ${password}"
    dim "  SNI   ${domain}"
    echo ""
    step "Shadowrocket / V2RayN"
    dim "  导入链接"
    dim "    ${share_link}"
    echo ""
    step "Clash 配置"
    dim " - name: $ip"
    dim "   type: anytls"
    dim "   server: $ip"
    dim "   port: $port"
    dim "   password: $password"
    dim "   sni: $domain"
    dim "   udp: true"
    dim "   skip-cert-verify: true"
    dim "   alpn:"
    dim "     - h2"
    dim "     - http/1.1"
}

do_uninstall() {
    [ "$(id -u)" -ne 0 ] && die "请以 root 运行"
    systemctl stop anytls-server.service 2>/dev/null || true
    systemctl disable anytls-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/anytls-server.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /root/anytls
    ok "AnyTLS 已卸载"
}

do_status() {
    if [ -f /etc/systemd/system/anytls-server.service ]; then
        systemctl status anytls-server.service 2>&1
    else
        warn "AnyTLS 服务未安装"
    fi
}

# ===== Terminal Menu =====

main_menu() {
    check_deps
    while true; do
        head "操作菜单"
        dim "  1) 安装"
        dim "  2) 卸载"
        dim "  3) 查看状态"
        dim "  0) 退出"
        prompt "请选择 ${DIM}[0-3]${NC}: "
        read -r sel || break
        echo ""
        case "$sel" in
            1) do_install ;;
            2) prompt "确认卸载？${DIM}[y/N]${NC}: "
               read -r ans || ans="n"
               case "$ans" in y|Y|yes|YES) do_uninstall ;; esac ;;
            3) do_status ;;
            0) ok "再见"; exit 0 ;;
        esac
    done
}

# ===== Entry =====
case "${1:-}" in
    install)   shift; check_deps; do_install "$@" ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         check_deps; banner; main_menu ;;
esac
