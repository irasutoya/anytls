# AnyTLS Server Manager

一键安装 [sing-box](https://github.com/SagerNet/sing-box) anytls 服务端，终端交互式菜单，支持 Linux x86_64 / aarch64。banner 自动显示 GitHub 最新 commit 编号。

## 一键安装

```bash
bash <(curl -sSL https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh)
```

无需参数，启动后进入交互菜单引导安装。如需本地保存：

```bash
curl -sSL https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh -o anytls.sh
bash anytls.sh
```

## 命令行

```bash
# 安装（静默，自动化场景）
bash anytls.sh install <domain> <port> [password]

# 卸载
bash anytls.sh uninstall

# 查看服务状态
bash anytls.sh status
```

## 客户端配置

安装完成后终端会打印以下配置信息。

### Shadowrocket / V2RayN

```
anytls://<服务器IP>:<端口>?password=<密码>&sni=<域名>&allowInsecure=1
```

### Clash Meta / Mihomo

```yaml
  - name: <服务器IP>
    type: anytls
    server: <服务器IP>
    port: <端口>
    password: <密码>
    sni: <域名>
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
```

## 文件布局

| 文件 | 用途 |
|---|---|---|
| `/root/anytls/sing-box` | 服务端二进制 |
| `/root/anytls/config.json` | sing-box 配置（anytls inbound） |
| `/root/anytls/ca.crt` | CA 根证书 |
| `/root/anytls/server.crt` | 服务端证书（自签名） |
| `/root/anytls/server.key` | 服务端私钥 |
| `/etc/systemd/system/anytls-server.service` | systemd 服务单元 |
