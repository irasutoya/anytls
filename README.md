# AnyTLS Server Manager

一键安装 [anytls-rs](https://github.com/ssrlive/anytls-rs) 服务端，TUI 交互式菜单，支持 Linux x86_64 / aarch64。

## 一键安装

```bash
bash <(curl -sSL https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh)
```

无需参数，启动后进入 TUI 菜单引导安装。

## 命令行

```bash
# 安装（静默，自动化场景）
bash anytls.sh install <domain> <port> [password]

# 卸载
bash anytls.sh uninstall

# 查看状态
bash anytls.sh status

# 升级脚本自身
bash anytls.sh self-update
```

## 客户端配置

安装完成后会打印以下配置信息。

### Shadowrocket / V2RayN

```
anytls://<服务器IP>:<端口>?password=<密码>&sni=<域名>
```

### Clash Meta / Mihomo

```yaml
proxies:
  - name: anytls
    type: anytls
    server: <服务器IP>
    port: <端口>
    password: "<密码>"
    sni: <域名>
    udp: true
    skip-cert-verify: false
    alpn:
      - h2
      - http/1.1
```

CA 证书位于 `/root/anytls/ca.crt`。
Padding scheme 位于 `/root/anytls/padding.txt`。
