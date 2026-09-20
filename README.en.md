# 📦 [项目说明](README.md) | [Project](README.en.md) | [اطلاعات پروژه](README.fa.md)

> Repository: https://github.com/livingfree2023/nokey

Many popular "one-click" scripts nowadays have become ~~bloated~~ feature-rich, ~~lost their original purpose~~ very advanced.

So I decided to package my own DIY experience into a **truly** one-click script and share it.

This modified script is even more aggressive than standard one-clicks—so what should I call it? Zero-click? Well, you do still have to press Enter… but if scripts that require 101 keystrokes still call themselves "one-click," I’ll shamelessly call mine "**NoKey**."

No domain required. Perfect for both seasoned users who love tinkering and total beginners who want a hassle-free setup.

Run a single command, sit back, and wait. No chatter, no fuss—super fast. Ready to race any other script 🚀 Speed is my specialty.

> In testing, even a modest 1vCPU/1GB RAM VPS completed setup in under 20 seconds. Ideal for busy users.
> Also verified to run on an Alpine pod with only 64MB RAM.

---

# ⚙️ Features (without passing any parameters, it goes from a fresh machine to installing BBR + FQ)

1. Skips unnecessary `apt` updates automatically  
2. Skips redundant `geodata` updates  
3. Generates UUID/KeyPair using official commands  
4. Auto-detects a random free port  
5. Adapts across multiple Linux distributions  
6. Downloads prebuilt Xray binaries directly (amd64/arm64)  
7. Accepts parameters for protocol stack, UUID, SNI, port  
8. Shows help with `--help`  
9. Outputs only minimal steps—detailed logs saved to a file  
10. Generates QR codes  
11. `--menu` opens the Realm, SOCKS, WARP, Sing-box, BBR, acme.sh certificate, and Hysteria2 feature menu
12. Feature implementations are separate scripts and can be run with one-liners
13. Auto-probes a feasible REALITY target SNI (mirrors 3x-ui's REALITY Target Scanner; verifies TLS 1.3 + HTTP/2)
14. Installs `jq` automatically before JSON-based SOCKS/WARP operations when missing

---

# 📦 Why binaries are downloaded from this repo

`nokey.sh` downloads `xray_amd64/xray_arm64/realm_amd64/realm_arm64/geoip.dat/geosite.dat` from this repository's Releases instead of pulling and extracting official ZIP packages during install.

Why:

1. Lower CPU and RAM usage during install, which improves success rate on tiny instances (especially Alpine low-memory pods).
2. Fewer external dependencies and a shorter install path.
3. More controlled install inputs instead of executing a heavier install chain on the target host.

These release assets are generated/synced by GitHub Actions. See: [`./.github/workflows/blank.yml`](.github/workflows/blank.yml).

---

# 🧑‍🍳 How to Use (as root)

```bash
curl -fsSL -o /usr/local/bin/nokey https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh && chmod +x /usr/local/bin/nokey && nokey
```

## Feature menu and standalone scripts

Running `nokey` without parameters keeps the original behavior: Xray VLESS + Reality, BBR, and FQ setup.

```bash
nokey --menu
```

The features can also be run directly without installing the scripts first:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.sh) --remote=1.2.3.4:443
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-socks.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-warp.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/singbox.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/bbr.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/acme-cert.sh) --domain=example.com
HYSTERIA_CF_TOKEN=your-cloudflare-token bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com
# Or use an existing certificate and private key:
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com --cert-path=/path/fullchain.pem --key-path=/path/private.key
```

Each entrypoint loads `nokey-common.sh`; JSON-based features install `jq` through the detected package manager when it is missing.

The acme.sh menu entry uses Cloudflare DNS validation when a token is entered, otherwise it uses standalone HTTP-01 on port 80. Hysteria2 chooses a random free port above 10000 by default (`--port` overrides it). Providing `HYSTERIA_CF_TOKEN` or entering a token uses Hysteria's built-in ACME DNS challenge; otherwise it detects certificates under `/etc/hysteria/` and `~/.acme.sh/`, then asks for certificate and key paths if needed. After the service is active, `nokey.url` contains a `hysteria2://` share URL and a Mihomo/Clash YAML proxy entry, followed by systemd/OpenRC restart and status commands.

---

# 🔍 Dry-run (preview without changing system)

```bash
nokey --dry-run
```

---

# 🔁 Realm relay proxy

### Scenario 1 — Install Realm

Use `nokey --menu` or `realm.sh`. The old combined flags remain available for compatibility.
```bash
# Install Xray and Realm, forward local 443 to 1.2.3.4:443
nokey --realm --remote 1.2.3.4:443

# With custom listen address
nokey --realm --remote 1.2.3.4:443 --listen 0.0.0.0:8080

# Over IPv6
nokey --netstack=6 --realm --remote [2001:db8::1]:443
```

### Scenario 2 — Install Xray only (default, no flags needed)
```bash
nokey
```

### Scenario 3 — Install Realm only (without Xray)
```bash
nokey --realm-only --remote 1.2.3.4:443
```

---

# 🧹 Uninstall

```bash
nokey --remove              # uninstall Xray (also Realm if installed)
nokey --realm-only --remove  # uninstall Realm only
```

---

# ⭐ Please give it a star :)

Mistakes are inevitable—feedback is welcome!

_Forked from https://github.com/crazypeace/ — thanks to the original author._

---

If you’d like, I can help you write a localized README that switches between this translation and the original using links or folders. Just say the word!
