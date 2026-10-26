# 📦 [项目说明](README.md) | [Project](README.en.md) | [اطلاعات پروژه](README.fa.md)

> 项目地址: https://github.com/livingfree2023/nokey
> 
> 如果你只是想换个端口，换个uuid，或者买的新鸡急着去测youtube/speedtest，这个脚本可能非常适合你

![image](https://img.imgdd.com/ce4a1b42-9219-4957-95df-1a67a844b162.png)

各大有名的一键脚本现在~~越来越臃肿，早就忘记了初心~~功能非常强大，选择非常多样

自己把自己的手搓经验撮成一个真的一键脚本，分享一下这个魔改的一键脚本，比一键更激进

不需要域名，既适合会手搓的超级用户，也适合无需过多信息的纯小白，没有花里胡哨，快是我的强项，干就完了

一个命令下去就等结果就好了，不罗嗦，不打扰，速度超快，敢和任何脚本PK ^-^ 输了告诉我，我再改进

实测可在 Alpine Pod（64MB RAM）环境跑起来，适合超低内存场景。

默认不带参数直接从新机器开始安装 Xray VLESS Reality；检测到本机全局 IPv6 地址时，还会在同一 Xray 配置中自动加入 Shadowsocks 2022 入站。魔改功能为
1. 自动跳过不必要的系统环境更新
2. 自动跳过不必要的geodata更新（--force参数可强制更新）
3. 按照官方命令生成UUID/KeyPair
4. 自动找随机空闲端口（10000以上，--port可指定任意）
5. 尽可能自动适配所有linux版本
6. xray-core直接下载预编译二进制（amd64/arm64）
7. 可带参数指定协议栈，UUID，SNI，端口
8. 可查看帮助 --help
9. 只输出极简步骤，详细log输出到log文件
10. 支持X25519
11. 支持`--realm`模式安装Realm转发代理（用`--remote`指定目标地址，`--listen`可选）
12. 支持`--realm-only`模式仅安装Realm（不安装Xray）
13. 自动探测可用的REALITY目标SNI（参考3x-ui的REALITY Target Scanner，验证TLS 1.3 + HTTP/2）
14. 支持`--addsocks`为Xray添加带随机端口、用户名和密码的SOCKS5入站
15. Xray REALITY配置使用`minClientVer: "0.0.0"`兼容旧版客户端
16. 使用`--menu`选择Realm、SOCKS、WARP、BBR、acme.sh证书和Hysteria2
17. 缺少`jq`时，SOCKS和WARP功能会通过系统包管理器自动安装
18. `--default-route` 用菜单选择双栈VPS的 IPv4 / IPv6 出口偏好

> 已测试包括：ubuntu22/debian11/Rocky9.2/CentOS7.6/Fedora30/Alma9.2/alpine3.22，欢迎测试提issue或者报告成功结果

## 食用方式

### 极速安装（在root下）
```
rm -f /usr/local/bin/nokey  # 删除老文件

curl -fsSL -o /usr/local/bin/nokey https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh && chmod +x /usr/local/bin/nokey
```

> **说明**：
> 1. 服务名称已独立为 `nokey.service`（OpenRC: `nokey`），新安装的配置文件存放于 `/usr/local/etc/nokey/nokey.yaml`，不会与系统上已有的官方 Xray 或面板（如 3x-ui）产生服务名与配置文件冲突。
> 2. 推荐通过上述命令安装至 `/usr/local/bin/nokey`，可在所有 Shell（Bash、Zsh、Ash/Sh、Fish）中随时执行 `nokey --menu` 等任意参数命令。

### 功能菜单和独立脚本

不带参数运行`nokey`时，行为保持不变：安装Xray VLESS Reality、BBR和FQ。
需要其他功能时运行菜单：

```
nokey --menu
```

也可以直接使用独立脚本：

```
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.sh) --remote=1.2.3.4:443
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-socks.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-warp.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/bbr.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/acme-cert.sh) --domain=example.com
HYSTERIA_CF_TOKEN=your-cloudflare-token bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com
# 或使用已有证书和私钥：
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com --cert-path=/path/fullchain.pem --key-path=/path/private.key
```

这些脚本会自动加载`nokey-common.sh`。需要JSON配置处理的功能会先检查并安装`jq`。

脚本安装的 `yq` 位于 `/usr/local/libexec/nokey/yq`。安装后会在已有的 `~/.bashrc` 和 `~/.zshrc` 中加入 PATH 设置；新开终端即可直接运行 `yq`，当前终端需执行 `source ~/.bashrc` 或 `source ~/.zshrc`。

默认安装与菜单选项 1 行为相同：有本机全局 IPv6 时，Reality 与 Shadowsocks 2022 自动作为两个入站写入同一 Xray 配置；无 IPv6 时仅安装 Reality。Shadowsocks 使用 `2022-blake3-aes-128-gcm`，仅监听本机全局 IPv6 地址。配置经 Xray 校验并成功重启后输出 `ss://` 链接。

菜单中的acme.sh功能使用Cloudflare DNS验证（输入API token时）或80端口HTTP验证，并把证书安装到`/etc/hysteria/`。Hysteria2默认选择10000以上的随机空闲端口（可用`--port`指定），如果提供Cloudflare token，会优先使用内置ACME DNS验证；否则检测该目录和`~/.acme.sh/`中的证书，找不到时提示输入证书和私钥路径。服务启动成功后，`nokey.url`会保存链接和Mihomo/Clash YAML配置，并输出systemd/OpenRC重启和状态检查命令。

### 场景一：只安装Xray（默认，不带任何参数）
```
nokey
```

### 双栈VPS默认出口

```bash
nokey --default-route
```

菜单可选择 IPv4 优先或 IPv6 优先。TCP 连接会优先尝试所选地址族，必要时尝试另一地址族；UDP 和目标为 IP 地址的连接不保证这种回退。

无人值守时可直接指定：

```bash
nokey --default-route=4
nokey --default-route=6
```

`--netstack=4|6` 选择客户端连接使用的服务器地址；`--default-route` 选择 Xray 访问目标网站时的出口偏好。双栈 DNS 保留 A 和 AAAA 查询。已有配置会先备份并校验，再应用选择。

### 为Xray添加SOCKS5入站
```
nokey --addsocks
```

`--addsocks`是独立模式，不能和其他参数同时使用：

- 新机器没有Xray配置时，会安装Xray并同时生成SOCKS5入站。
- 已有`/usr/local/etc/nokey/nokey.yaml`时，只向`inbounds`追加SOCKS5配置，保留现有入站和出站；最后会重启Nokey服务。脚本会在需要时自动安装并校验 YAML 工具。
- 只有旧版`/usr/local/etc/nokey/nokey.json`时，脚本会将其改名备份至`/usr/local/etc/nokey-legacy.json.*`，提示备份位置，然后按新机器安装并生成YAML配置及SOCKS5入站。旧JSON配置不会迁移。
- SOCKS端口、用户名和密码均自动随机生成。代理地址和下面这种测试命令会输出到终端并写入`nokey.url`：

```
socks5h://USERNAME:PASSWORD@SERVER_IP:PORT
curl --proxy 'socks5h://USERNAME:PASSWORD@SERVER_IP:PORT' https://ipinfo.io
```

> SOCKS5本身不加密，不建议直接暴露在不可信公网。请配合防火墙限制来源地址，并妥善保存`nokey.url`中的凭据。

> `minClientVer: "0.0.0"`允许旧版Xray客户端连接，但旧客户端的TLS指纹可能更容易被识别；这是为兼容性做出的明确取舍。

### 场景二：安装Xray + Realm（同时安装两者）

推荐使用`nokey --menu`中的Realm选项或直接运行`realm.sh`。下面的旧参数仍保留兼容：
```
# 安装Xray和Realm，把443转发到1.2.3.4:443
nokey --realm --remote 1.2.3.4:443

# 指定Realm监听地址
nokey --realm --remote 1.2.3.4:443 --listen 0.0.0.0:8080

# Realm走IPv6
nokey --netstack=6 --realm --remote [2001:db8::1]:443
```

### 场景三：只安装Realm转发代理（不安装Xray）
```
nokey --realm-only --remote 1.2.3.4:443
```

### 其他 
1. 查看帮助
```
nokey --help
```

2. 如果没有ipv4（纯v6的鸡），同时如果warp了ipv4的出口，此时要指定入口为v6，否则连不通（因为v4优先级比v6高）
```
nokey --netstack=6
```

3. 强制更新xray 和 geodata
```
nokey --force
```

4. 仅预览安装流程（不修改系统）
```
nokey --dry-run
```

错误难免，请多指教，我希望能做出适合所有linux版本的，但是自己财力有限，欢迎大佬借我机器调试


## 卸载

```
nokey --remove              # 卸载Xray（如果有Realm也一起卸载）
nokey --realm-only --remove  # 仅卸载Realm
```


_感谢 [crazypeace](https://github.com/crazypeace/)_
_感谢 [@RPRX](https://github.com/RPRX)_
_感谢 [ProjectX](https://github.com/XTLS)_

### 运行日志

`nokey.log` 提供带时间、级别和耗时的脱敏诊断；连接信息保存在 `nokey.url`。两者权限均为 `0600`。需要更细的诊断时使用 `NOKEY_LOG_LEVEL=DEBUG nokey --default-route=4`；支持 `DEBUG`、`INFO`、`WARN`、`ERROR`，默认 `INFO`。
