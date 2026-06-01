#!/usr/bin/env bash
set -euo pipefail

# AnyTLS Server Manager
# Repo: https://github.com/irasutoya/anytls

SELF_REPO_BASE="https://github.com/irasutoya/anytls"
SELF_REPO="${SELF_REPO_BASE}/raw/main/anytls.sh"
GH_RELEASE="https://github.com/ssrlive/anytls-rs/releases/latest/download"
DEF_DOMAIN="gateway.icloud.com"
DEF_PORT=443

# Cyberpunk palette
PINK='\033[35m'; CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'
RED='\033[31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

die()  { echo -e " ${RED}[-]${NC} $*" >&2; exit 1; }
ok()   { echo -e " ${GREEN}[+]${NC} $*"; }
warn() { echo -e " ${YELLOW}[!]${NC} $*"; }
step() { echo -e " ${CYAN}[*]${NC} $*"; }
head() { echo -e "\n ${PINK}${BOLD}>>${NC} ${BOLD}$*${NC}"; }
dim()  { echo -e " ${DIM}$*${NC}"; }

commit_id() {
    local rev=""
    rev=$(git rev-parse --short HEAD 2>/dev/null) || rev=""
    if [ -z "$rev" ]; then
        rev=$(curl -sS --max-time 3 "https://api.github.com/repos/irasutoya/anytls/commits/main" | grep -m1 '"sha"' | cut -d'"' -f4 | head -c 7) 2>/dev/null || rev=""
    fi
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
    for cmd in curl tar openssl; do
        command -v "$cmd" >/dev/null || { missing+=("$cmd"); names+=("$cmd"); }
    done
    command -v systemctl >/dev/null || { missing+=("systemd"); names+=("systemd"); }
    [ ${#missing[@]} -eq 0 ] && return 0

    local pm; pm=$(pkg_mgr)
    if [ -n "$pm" ]; then
        warn "缺少依赖: ${names[*]}"
        echo -ne " ${CYAN}[?]${NC} 是否自动安装？${DIM}[Y/n]${NC} "
        read -r ans
        case "$ans" in n|N|no|NO) die "用户取消" ;; esac
        $pm "${missing[@]}" || die "安装依赖失败"
    else
        die "缺少依赖: ${names[*]}，请手动安装"
    fi
}

detect_asset() {
    local arch; arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)
            local asset="anytls-x86_64-unknown-linux-musl.tar.gz"
            local code; code=$(curl -s -o /dev/null -w "%{http_code}" "$GH_RELEASE/$asset")
            [ "$code" = 200 ] && { echo "$asset"; return; }
            echo "anytls-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64|arm64)
            echo "anytls-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) die "不支持的架构: $arch" ;;
    esac
}

download() {
    local asset=$1 url="$GH_RELEASE/$asset"
    local tmpdir; tmpdir=$(mktemp -d)

    step "下载 $asset ..."
    curl -#SL "$url" -o "$tmpdir/$asset" || die "下载失败"

    tar -xzf "$tmpdir/$asset" -C "$tmpdir" || die "解压失败"
    mkdir -p /root/anytls
    cp -f "$tmpdir/anytls-server" /root/anytls/anytls-server
    chmod +x /root/anytls/anytls-server
    rm -rf "$tmpdir"
    ok "二进制安装完成"
}

gen_password() {
    local hex; hex=$(openssl rand -hex 16)
    local h1=${hex:0:8} h2=${hex:8:4} h3=${hex:12:4}
    local h4=${hex:16:4} h5=${hex:20:12}
    local h4_first; printf -v h4_first '%x' $((0x${h4:0:1} & 0x3 | 0x8))
    echo "${h1}-${h2}-4${h3:1:3}-${h4_first}${h4:1:3}-${h5}"
}

gen_certs() {
    local domain=$1
    openssl genrsa -out /root/anytls/ca.key 4096 2>/dev/null
    openssl req -x509 -new -nodes -key /root/anytls/ca.key -sha256 -days 3650 \
        -subj "/C=US/O=Apple Inc./CN=Apple Root CA" -out /root/anytls/ca.crt 2>/dev/null
    openssl genrsa -out /root/anytls/server.key 2048 2>/dev/null
    openssl req -new -key /root/anytls/server.key \
        -subj "/C=US/ST=California/L=Cupertino/O=Apple Inc./CN=$domain" \
        -out /root/anytls/server.csr 2>/dev/null
    echo "subjectAltName=DNS:$domain" > /root/anytls/server.ext
    openssl x509 -req -in /root/anytls/server.csr -CA /root/anytls/ca.crt -CAkey /root/anytls/ca.key \
        -CAcreateserial -out /root/anytls/server.crt -days 3650 -sha256 \
        -extfile /root/anytls/server.ext 2>/dev/null
    rm -f /root/anytls/server.csr /root/anytls/server.ext /root/anytls/ca.srl /root/anytls/ca.key
    chmod 600 /root/anytls/server.key
    chmod 644 /root/anytls/ca.crt /root/anytls/server.crt
    ok "证书已生成"
}

gen_padding_scheme() {
    cat > /root/anytls/padding.txt <<EOF
stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000
EOF
    chmod 644 /root/anytls/padding.txt
    ok "padding scheme 已生成"
}

config_firewall() {
    local port=$1
    if command -v ufw >/dev/null; then
        ufw allow "$port/tcp" >/dev/null 2>&1 && ok "ufw 已放行 $port/tcp"
    elif command -v iptables >/dev/null && command -v iptables-save >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || {
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            ok "iptables 已放行 $port/tcp"
        }
    fi
}

install_service() {
    local domain=$1 port=$2 password=$3 padding=$4
    cat > /etc/systemd/system/anytls-server.service <<EOF
[Unit]
Description=AnyTLS Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/root/anytls/anytls-server -l 0.0.0.0:${port} -p ${password} --sni ${domain} --cert /root/anytls/server.crt --key /root/anytls/server.key --padding-scheme ${padding} --log warn
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now anytls-server.service
    ok "systemd 服务已安装并启动"
}

get_ip() {
    curl -4 -sS --max-time 5 https://ip.sb 2>/dev/null ||
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
        echo -ne " ${CYAN}[?]${NC} 伪装域名 (SNI) ${DIM}[${DEF_DOMAIN}]${NC}: "
        read -r domain; domain=${domain:-$DEF_DOMAIN}
        echo -ne " ${CYAN}[?]${NC} 监听端口 ${DIM}[${DEF_PORT}]${NC}: "
        read -r port; port=${port:-$DEF_PORT}
        echo -ne " ${CYAN}[?]${NC} 密码（留空自动生成）: "
        read -rs password; echo
        password=${password:-$(gen_password)}
    fi
    [ -z "$port" ] && port=$DEF_PORT
    [ -z "$password" ] && password=$(gen_password)

    head "初始化部署環境"
    step "检测架构..."
    local asset; asset=$(detect_asset)
    dim "目标: $asset"

    download "$asset"
    gen_certs "$domain"
    gen_padding_scheme
    install_service "$domain" "$port" "$password" "/root/anytls/padding.txt"

    echo -ne " ${CYAN}[?]${NC} 配置防火墙放行 ${port} 端口？${DIM}[Y/n]${NC}: "
    read -r ans
    case "$ans" in n|N|no|NO) ;; *) config_firewall "$port" ;; esac

    local ip pw_enc; ip=$(get_ip); pw_enc=$(urlencode "$password")
    local share_link="anytls://${ip}:${port}?password=${pw_enc}&sni=${domain}"

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
    step "配置"
    local clash_file="/root/anytls/clash-proxy.yaml"
    cat > "$clash_file" <<EOF
  - name: anytls
    type: anytls
    server: $ip
    port: $port
    password: "$password"
    sni: $domain
    udp: true
    skip-cert-verify: false
    alpn:
      - h2
      - http/1.1
EOF
    chmod 644 "$clash_file"
    dim "  配置文件"
    dim "    $clash_file"
    echo ""
    step "本地文件"
    dim "  CA 证书     /root/anytls/ca.crt"
    dim "  Padding     /root/anytls/padding.txt"
    echo ""
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

do_self_update() {
    local tmp; tmp=$(mktemp)
    echo "正在检查更新..."
    curl -sSL "$SELF_REPO" -o "$tmp" || { rm -f "$tmp"; die "下载脚本失败"; }
    cp "$tmp" "$0"
    chmod +x "$0"
    rm -f "$tmp"
    ok "脚本已更新"
    exec "$0" "$@"
}

# ===== Terminal Menu =====

main_menu() {
    check_deps
    while true; do
        echo ""
        head "操作菜单"
        dim "  1) 安装"
        dim "  2) 卸载"
        dim "  3) 查看状态"
        dim "  4) 升级脚本"
        dim "  0) 退出"
        echo -ne " ${CYAN}[?]${NC} 请选择 ${DIM}[0-4]${NC}: "
        read -r sel
        echo ""
        case "$sel" in
            1) do_install ;;
            2) echo -ne " ${CYAN}[?]${NC} 确认卸载？${DIM}[y/N]${NC}: "
               read -r ans
               case "$ans" in y|Y|yes|YES) do_uninstall ;; esac ;;
            3) do_status ;;
            4) echo -ne " ${CYAN}[?]${NC} 确认升级脚本？${DIM}[y/N]${NC}: "
               read -r ans
               case "$ans" in y|Y|yes|YES) do_self_update ;; esac ;;
            0) ok "再见"; exit 0 ;;
        esac
    done
}

# ===== Entry =====
case "${1:-}" in
    install)      shift; do_install "$@" ;;
    uninstall)    do_uninstall ;;
    status)       do_status ;;
    self-update|self_update) do_self_update "$@" ;;
    *)            check_deps; banner; main_menu ;;
esac
