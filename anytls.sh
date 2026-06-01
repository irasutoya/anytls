#!/usr/bin/env bash
set -euo pipefail

# AnyTLS Server Manager
# Repo: https://github.com/irasutoya/anytls

SELF_REPO="https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh"
GH_RELEASE="https://github.com/ssrlive/anytls-rs/releases/latest/download"
DEF_DOMAIN="gateway.icloud.com"
DEF_PORT=443

RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
die() { echo -e "${RED}$*${NC}" >&2; exit 1; }
info() { echo -e "${GREEN}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

pkg_mgr() {
    command -v apt-get >/dev/null && { echo "apt-get install -y"; return; }
    command -v dnf >/dev/null    && { echo "dnf install -y"; return; }
    command -v yum >/dev/null    && { echo "yum install -y"; return; }
    command -v apk >/dev/null    && { echo "apk add"; return; }
    echo ""
}

check_deps() {
    local need_tui=${1:-0} missing=() names=()
    for cmd in curl tar openssl; do
        command -v "$cmd" >/dev/null || { missing+=("$cmd"); names+=("$cmd"); }
    done
    command -v systemctl >/dev/null || { missing+=("systemd"); names+=("systemd"); }
    if [ "$need_tui" = 1 ] && ! command -v whiptail >/dev/null; then
        missing+=(whiptail); names+=(whiptail)
    fi
    [ ${#missing[@]} -eq 0 ] && return 0

    local pm; pm=$(pkg_mgr)
    if [ -n "$pm" ]; then
        warn "缺少依赖: ${names[*]}"
        echo -n "是否自动安装？[Y/n] "; read -r ans
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
    local total; total=$(curl -sI "$url" | grep -i content-length | awk '{print $2}' | tr -d '\r\n' || echo 0)

    if [ "$total" -gt 0 ] && command -v whiptail >/dev/null; then
        (
            curl -sL "$url" -o "$tmpdir/$asset" &
            local cpid=$!
            while kill -0 $cpid 2>/dev/null; do
                sleep 0.3
                local cur; cur=$(stat -c%s "$tmpdir/$asset" 2>/dev/null || echo 0)
                local pct=$((cur * 100 / total)); [ "$pct" -gt 100 ] && pct=100
                echo "$pct"
            done
            echo 100; wait
        ) | whiptail --gauge "正在下载 $asset ..." 6 60 0
    else
        echo "正在下载 $asset ..."
        curl -sL "$url" -o "$tmpdir/$asset" || die "下载失败"
    fi

    tar -xzf "$tmpdir/$asset" -C "$tmpdir" || die "解压失败"
    mkdir -p /root/anytls
    cp -f "$tmpdir/anytls-server" /root/anytls/anytls-server
    chmod +x /root/anytls/anytls-server
    rm -rf "$tmpdir"
    info "✓ 二进制安装完成"
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
    info "✓ 证书已生成"
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
    info "✓ padding scheme 已生成"
}

config_firewall() {
    local port=$1
    if command -v ufw >/dev/null; then
        ufw allow "$port/tcp" >/dev/null 2>&1 && info "✓ ufw 已放行 $port/tcp"
    elif command -v iptables >/dev/null && command -v iptables-save >/dev/null; then
        iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || {
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            info "✓ iptables 已放行 $port/tcp"
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
    info "✓ systemd 服务已安装并启动"
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
    local tui=0; [ $# -eq 0 ] && tui=1

    if [ "$tui" = 1 ]; then
        command -v whiptail >/dev/null || die "TUI 模式需要 whiptail"
        domain=$(whiptail --title "AnyTLS" --inputbox "伪装域名 (SNI)" 8 50 "$DEF_DOMAIN" 3>&1 1>&2 2>&3) || return 1
        port=$(whiptail --title "AnyTLS" --inputbox "监听端口" 8 50 "$DEF_PORT" 3>&1 1>&2 2>&3) || return 1
        password=$(whiptail --title "AnyTLS" --passwordbox "密码（留空自动生成）" 8 50 3>&1 1>&2 2>&3) || return 1
    fi
    [ -z "$port" ] && port=$DEF_PORT
    [ -z "$password" ] && password=$(gen_password)

    warn "检测架构..."
    local asset; asset=$(detect_asset)
    info "目标文件: $asset"

    download "$asset"
    gen_certs "$domain"
    gen_padding_scheme
    install_service "$domain" "$port" "$password" "/root/anytls/padding.txt"

    if [ "$tui" = 1 ]; then
        whiptail --title "AnyTLS" --yesno "是否自动配置防火墙放行 $port 端口？" 8 50 && config_firewall "$port"
    else
        config_firewall "$port"
    fi

    local ip pw_enc; ip=$(get_ip); pw_enc=$(urlencode "$password")
    local share_link="anytls://${ip}:${port}?password=${pw_enc}&sni=${domain}"
    echo ""
    info "======================================"
    info "  AnyTLS 安装完成!"
    info "======================================"
    info "  地址: $ip:$port"
    info "  密码: $password"
    info "  SNI:  $domain"
    echo ""
    info " Shadowrocket / V2RayN 导入链接:"
    info "  $share_link"
    echo ""
    info " Clash Meta / Mihomo 配置:"
    info "  - name: anytls"
    info "    type: anytls"
    info "    server: $ip"
    info "    port: $port"
    info "    password: \"$password\""
    info "    sni: $domain"
    info "    udp: true"
    info "    skip-cert-verify: false"
    info "    alpn:"
    info "      - h2"
    info "      - http/1.1"
    info ""
    info " CA 证书: /root/anytls/ca.crt"
    info " Padding scheme: /root/anytls/padding.txt"
    info "======================================"
}

do_uninstall() {
    [ "$(id -u)" -ne 0 ] && die "请以 root 运行"
    systemctl stop anytls-server.service 2>/dev/null || true
    systemctl disable anytls-server.service 2>/dev/null || true
    rm -f /etc/systemd/system/anytls-server.service
    systemctl daemon-reload 2>/dev/null || true
    rm -rf /root/anytls
    info "✓ AnyTLS 已卸载"
}

do_status() {
    if [ -f /etc/systemd/system/anytls-server.service ]; then
        systemctl status anytls-server.service 2>&1
    else
        echo "AnyTLS 服务未安装"
    fi
}

do_self_update() {
    local tmp; tmp=$(mktemp)
    echo "正在检查更新..."
    curl -sSL "$SELF_REPO" -o "$tmp" || { rm -f "$tmp"; die "下载脚本失败"; }
    cp "$tmp" "$0"
    chmod +x "$0"
    rm -f "$tmp"
    info "✓ 脚本已更新"
    exec "$0" "$@"
}

# ===== TUI Menu =====

main_menu() {
    check_deps 1
    while true; do
        local sel
        sel=$(whiptail --title "AnyTLS 管理脚本" --menu "选择操作:" 15 50 4 \
            "1" "安装" \
            "2" "卸载" \
            "3" "查看状态" \
            "4" "升级脚本" \
            3>&1 1>&2 2>&3) || break
        case "$sel" in
            1) do_install && whiptail --title "AnyTLS" --msgbox "完成，详情见终端输出" 8 40 ;;
            2) if whiptail --title "AnyTLS" --yesno "确认卸载？" 8 40; then do_uninstall; whiptail --title "AnyTLS" --msgbox "卸载完成" 8 40; fi ;;
            3) local st; st=$(do_status 2>&1)
               whiptail --title "AnyTLS 状态" --scrolltext --msgbox "$st" 20 70 ;;
            4) whiptail --title "AnyTLS" --yesno "确认升级脚本？" 8 40 && do_self_update ;;
        esac
    done
}

# ===== Entry =====
case "${1:-}" in
    install)      shift; check_deps 0; do_install "$@" ;;
    uninstall)    check_deps 0; do_uninstall ;;
    status)       check_deps 0; do_status ;;
    self-update|self_update) do_self_update "$@" ;;
    *)            main_menu ;;
esac
