# AnyTLS Server Manager

一键安装 [anytls-rs](https://github.com/ssrlive/anytls-rs) 服务端，终端交互式菜单，支持 Linux x86_64 / aarch64。banner 自动显示 GitHub 最新 commit 编号。

## 一键安装

```bash
bash <(curl -sSL https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh)
```

无需参数，启动后进入交互菜单引导安装。如需本地保存：

```bash
curl -sSL https://raw.githubusercontent.com/irasutoya/anytls/main/anytls.sh -o anytls.sh
bash anytls.sh
```

> 管道运行时不支持 `self-update`，本地保存后可正常升级。
> `self-update` 会把脚本写入 `/root/anytls.sh`，后续推荐通过 `bash /root/anytls.sh` 运行。

## 命令行

```bash
# 安装（静默，自动化场景）
bash anytls.sh install <domain> <port> [password]

# 卸载
bash anytls.sh uninstall

# 查看服务状态
bash anytls.sh status

# 升级脚本自身
bash anytls.sh self-update
```

## 客户端配置

安装完成后终端会打印以下配置信息。

### Shadowrocket / V2RayN

```
anytls://<服务器IP>:<端口>?password=<密码>&sni=<域名>
```

> 客户端需开启跳过证书验证（Shadowrocket 开启"allow insecure"，V2RayN 勾选"allowInsecure"）。

### Clash Meta / Mihomo

```yaml
  - name: <服务器IP>
    type: anytls
    server: <服务器IP>
    port: <端口>
    password: "<密码>"
    sni: <域名>
    udp: true
    skip-cert-verify: true
    alpn:
      - h2
      - http/1.1
```

## 文件布局

| 文件 | 用途 |
|---|---|
| `/root/anytls.sh` | 管理脚本本体（self-update 后固定于此） |
| `/root/anytls/anytls-server` | 服务端二进制 |
| `/root/anytls/server.crt` | 服务器证书 |
| `/root/anytls/server.key` | 服务器私钥 (chmod 600) |
| `/root/anytls/ca.crt` | CA 证书（客户端需信任） |
| `/root/anytls/padding.txt` | 流量填充方案 |
| `/etc/systemd/system/anytls-server.service` | systemd 服务单元 |
