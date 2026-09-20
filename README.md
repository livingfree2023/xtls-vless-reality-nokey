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

默认不带参数直接从新机器开始到装完BBR+FQ，魔改功能为
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
13. 支持`--singbox`模式同时安装Xray和Sing-box，或用`--singbox-only`仅安装Sing-box
14. 自动探测可用的REALITY目标SNI（参考3x-ui的REALITY Target Scanner，验证TLS 1.3 + HTTP/2）
15. 支持`--addsocks`为Xray添加带随机端口、用户名和密码的SOCKS5入站
16. Xray REALITY配置使用`minClientVer: "0.0.0"`兼容旧版客户端
17. 使用`--menu`选择Realm、SOCKS、WARP、Sing-box、BBR、acme.sh证书和Hysteria2
18. 缺少`jq`时，SOCKS和WARP功能会通过系统包管理器自动安装

> 已测试包括：ubuntu22/debian11/Rocky9.2/CentOS7.6/Fedora30/Alma9.2/alpine3.22，欢迎测试提issue或者报告成功结果

## 食用方式

### 极速安装（在root下）
```
rm -f /usr/local/bin/nokey  # 删除老文件

curl -fsSL -o /usr/local/bin/nokey https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh && chmod +x /usr/local/bin/nokey
```

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
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/singbox.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/bbr.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/acme-cert.sh) --domain=example.com
HYSTERIA_CF_TOKEN=your-cloudflare-token bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com
# 或使用已有证书和私钥：
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com --cert-path=/path/fullchain.pem --key-path=/path/private.key
```

这些脚本会自动加载`nokey-common.sh`。需要JSON配置处理的功能会先检查并安装`jq`。

菜单中的acme.sh功能使用Cloudflare DNS验证（输入API token时）或80端口HTTP验证，并把证书安装到`/etc/hysteria/`。Hysteria2默认选择10000以上的随机空闲端口（可用`--port`指定），如果提供Cloudflare token，会优先使用内置ACME DNS验证；否则检测该目录和`~/.acme.sh/`中的证书，找不到时提示输入证书和私钥路径。服务启动成功后，`nokey.url`会保存链接和Mihomo/Clash YAML配置，并输出systemd/OpenRC重启和状态检查命令。

### 场景一：只安装Xray（默认，不带任何参数）
```
nokey
```

### 为Xray添加SOCKS5入站
```
nokey --addsocks
```

`--addsocks`是独立模式，不能和其他参数同时使用：

- 新机器没有Xray配置时，会安装Xray并同时生成SOCKS5入站。
- 已有`/usr/local/etc/xray/config.json`时，只向`inbounds`追加SOCKS5配置，保留现有入站和出站；无论服务当前运行还是停止，最后都会重启Xray。
- SOCKS端口、用户名和密码均自动随机生成。代理地址和下面这种测试命令会输出到终端并写入`nokey.url`：

```
socks5h://USERNAME:PASSWORD@SERVER_IP:PORT
curl --proxy 'socks5h://USERNAME:PASSWORD@SERVER_IP:PORT' https://ipinfo.io
```

> SOCKS5本身不加密，不建议直接暴露在不可信公网。请配合防火墙限制来源地址，并妥善保存`nokey.url`和`nokey.log`中的凭据。

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

### 场景四：安装Xray + Sing-box（VLESS Reality Vision）
```
# 同时安装Xray和Sing-box；两者自动使用不同的入站端口
nokey --singbox

# 安装Xray + Sing-box + Realm转发代理
nokey --singbox --realm --remote 1.2.3.4:443

# 指定Xray端口和共用UUID；Sing-box端口仍自动选择以避免冲突
nokey --singbox --port 12345 --uuid "your-uuid-here"

# 指定SNI域名
nokey --singbox --domain www.example.com

# 仅预览安装流程
nokey --singbox --dry-run
```

### 场景五：仅安装Sing-box（不安装Xray）
```
nokey --singbox-only
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
nokey --singbox --remove     # 卸载Xray和Sing-box（如果有Realm也一起卸载）
nokey --singbox-only --remove # 仅卸载Sing-box
```


## 为什么从本仓库下载二进制

`nokey.sh` 默认从本仓库 Releases 下载 `xray_amd64/xray_arm64/realm_amd64/realm_arm64/sing-box_amd64/sing-box_arm64/geoip.dat/geosite.dat`，而不是安装时去官方仓库临时拉取并解压 ZIP。这样做的目的：

1. 减少安装阶段的 CPU 和内存开销，提升低配机器成功率（尤其是 Alpine 小内存 Pod）。
2. 降低外部依赖数量，让安装链路更短、更稳定。
3. 保证安装输入可控，避免每次现场执行复杂安装脚本。

这些发布文件由 GitHub Action 自动同步生成，流程见：[`./.github/workflows/blank.yml`](.github/workflows/blank.yml)。


_感谢 [crazypeace](https://github.com/crazypeace/)_
_感谢 [@RPRX](https://github.com/RPRX)_
_感谢 [ProjectX](https://github.com/XTLS)_
