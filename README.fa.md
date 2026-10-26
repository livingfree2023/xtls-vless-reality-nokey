# 📦 [项目说明](README.md) | [Project](README.en.md) | [اطلاعات پروژه](README.fa.md)

> آدرس مخزن: https://github.com/livingfree2023/nokey

اسکریپت‌های معروف «با یک کلیک» این روزها بیشتر ~~سنگین و پیچیده~~ شده‌اند، پر از امکانات و ~~خیلی وقت است از هدف اصلی‌شان دور شده‌اند~~ بسیار پیشرفته هستند.

من تجربه شخصی خودم رو جمع کردم و یک اسکریپت واقعی «با یک کلیک» ساختم تا با شما به اشتراک بگذارم.

این اسکریپت تغییریافته حتی از اسکریپت‌های معمولی تندروتر است—پس اسمش چی باشه؟ صفر کلیک؟ خب، هنوز باید کلید Enter رو فشار بدید... ولی وقتی اسکریپت‌هایی با ۱۰۱ بار فشار دادن کلید خودشون رو «با یک کلیک» می‌نامند، من هم با افتخار اسمش رو می‌ذارم "**NoKey**" یا «بدون کلید».

نیاز به دامنه ندارد. هم برای کاربران حرفه‌ای مناسب است، هم برای افراد مبتدی که دنبال راه‌اندازی سریع و آسان هستند.

یک دستور وارد کن، منتظر بمون. بی‌حرف اضافه، بی‌مزاحمت—سرعت بسیار بالا. آماده رقابت با هر اسکریپتی 🚀 سرعت تخصص منه.

> تست‌شده: سرور مجازی با ۱ vCPU و ۱ گیگ رم در کمتر از ۲۰ ثانیه نصب را کامل کرد. مناسب برای افراد پرمشغله.
> همچنین روی Alpine Pod با فقط ۶۴MB RAM هم تست شده و اجرا می‌شود.

---

# ⚙️ امکانات (بدون نیاز به پارامتر، از ماشین جدید تا نصب BBR + FQ)

1. به‌صورت خودکار از آپدیت‌های غیرضروری apt می‌گذرد  
2. از آپدیت‌های غیرضروری geodata عبور می‌کند  
3. با دستورات رسمی UUID و KeyPair را تولید می‌کند  
4. پورت آزاد تصادفی را پیدا می‌کند  
5. با نسخه‌های مختلف لینوکس سازگار است  
6. باینری آماده xray را مستقیم دانلود می‌کند (amd64/arm64)  
7. امکان تنظیم پروتکل، UUID، SNI، و پورت با پارامترها  
8. نمایش راهنما با `--help`  
9. فقط مراحل ساده را نشان می‌دهد—لاگ کامل در فایل ذخیره می‌شود  
10. تولید QR کد
11. گزینه `--menu` برای انتخاب Realm، SOCKS، Shadowsocks، WARP، BBR، گواهی acme.sh و Hysteria2
12. هر قابلیت به‌صورت اسکریپت مستقل نیز قابل اجراست
13. انتخاب خودکار SNI هدف REALITY مناسب (الهام‌گرفته از REALITY Target Scanner پروژه 3x-ui؛ بررسی TLS 1.3 و HTTP/2)
14. در صورت نبودن `jq`، قابلیت‌های JSONمحور آن را خودکار نصب می‌کنند
15. گزینهٔ `--default-route` اولویت خروجی IPv4 یا IPv6 را در VPS دوپشته انتخاب می‌کند

---

# 📦 چرا باینری‌ها از همین مخزن دانلود می‌شوند

`nokey.sh` فایل‌های `xray_amd64/xray_arm64/realm_amd64/realm_arm64/geoip.dat/geosite.dat` را از Releases همین مخزن دانلود می‌کند، به‌جای اینکه هنگام نصب ZIP رسمی را دریافت و extract کند.

دلایل:

1. مصرف کمتر CPU و RAM هنگام نصب، مخصوصاً برای محیط‌های کم‌منابع مثل Alpine Pod.
2. وابستگی کمتر به منابع خارجی و مسیر نصب کوتاه‌تر و پایدارتر.
3. ورودی نصب قابل‌کنترل‌تر، به‌جای اجرای زنجیره نصب سنگین روی خود سرور مقصد.

این فایل‌های Release با GitHub Actions ساخته/همگام‌سازی می‌شوند. مسیر workflow: [`./.github/workflows/blank.yml`](.github/workflows/blank.yml).

---

# 🧑‍🍳 روش استفاده (با دسترسی root)

```bash
curl -fsSL -o /usr/local/bin/nokey https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/nokey.sh && chmod +x /usr/local/bin/nokey && nokey
```

> **نکته**:
> نام سرویس به `nokey.service` (در OpenRC: `nokey`) و مسیر فایل تنظیمات جدید به `/usr/local/etc/nokey/nokey.yaml` تغییر یافته است تا از تداخل با سرویس‌های دیگر Xray جلوگیری شود. اسکریپت ابزار YAML تأییدشده را هنگام نیاز به‌طور خودکار نصب می‌کند؛ نصب‌های JSON قدیمی همان قالب را حفظ می‌کنند.

## منوی قابلیت‌ها و اسکریپت‌های مستقل

اجرای `nokey` بدون پارامتر Xray VLESS Reality را به‌همراه BBR و FQ نصب می‌کند. اگر VPS آدرس IPv6 عمومی محلی داشته باشد، یک ورودی Shadowsocks 2022 نیز در همان پیکربندی Xray اضافه می‌شود. گزینهٔ ۱ منو همین رفتار را دارد؛ گزینهٔ ۹ Shadowsocks را به پیکربندی Xray موجود اضافه می‌کند.

```bash
nokey --menu
```

قابلیت‌ها را می‌توان مستقیماً نیز اجرا کرد:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/realm.sh) --remote=1.2.3.4:443
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-socks.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/xray-warp.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/bbr.sh)
bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/acme-cert.sh) --domain=example.com
HYSTERIA_CF_TOKEN=your-cloudflare-token bash <(curl -fsSL https://raw.githubusercontent.com/livingfree2023/nokey/refs/heads/main/hysteria2.sh) --domain=example.com
```

اسکریپت‌ها فایل مشترک `nokey-common.sh` را بارگذاری می‌کنند و قابلیت‌های JSONمحور در صورت نیاز `jq` را از مدیر بسته سیستم نصب می‌کنند.

گزینه acme.sh در منو، در صورت وارد کردن توکن Cloudflare از DNS-01 و در غیر این صورت از HTTP-01 مستقل روی پورت ۸۰ استفاده می‌کند و گواهی را در `/etc/hysteria/` قرار می‌دهد. Hysteria2 به‌صورت پیش‌فرض یک پورت آزاد تصادفی بالاتر از ۱۰۰۰۰ انتخاب می‌کند و با `--port` قابل تغییر است. برای Hysteria2، با ارائه `HYSTERIA_CF_TOKEN` یا وارد کردن توکن، ACME داخلی Hysteria از DNS-01 استفاده می‌کند؛ در غیر این صورت ابتدا مسیرهای `/etc/hysteria/` و `~/.acme.sh/` بررسی شده و سپس مسیر گواهی و کلید خصوصی پرسیده می‌شود. پس از فعال شدن سرویس، لینک `hysteria2://`، تنظیمات YAML سازگار با Mihomo/Clash و دستورات راه‌اندازی مجدد و بررسی وضعیت systemd/OpenRC در `nokey.url` نمایش داده می‌شوند.

---

# 🌐 خروجی پیش‌فرض در VPS دوپشته

```bash
nokey --default-route
```

در منو می‌توانید اولویت IPv4 یا IPv6 را انتخاب کنید. اتصال‌های TCP ابتدا خانوادهٔ آدرس انتخاب‌شده را امتحان می‌کنند و در صورت نیاز می‌توانند به خانوادهٔ دیگر برگردند. این بازگشت برای UDP یا مقصدهایی که مستقیماً آدرس IP هستند تضمین نمی‌شود.

برای اجرای بدون تعامل:

```bash
nokey --default-route=4
nokey --default-route=6
```

گزینهٔ `--netstack=4|6` آدرس سروری را انتخاب می‌کند که کلاینت به آن متصل می‌شود. گزینهٔ `--default-route` اولویت خروجی Xray به وب‌سایت مقصد را تعیین می‌کند. DNS دوپشته هر دو پرس‌وجوی A و AAAA را حفظ می‌کند. پیش از اعمال انتخاب، از تنظیمات موجود پشتیبان گرفته و اعتبار آن بررسی می‌شود.

---

# 🔍 پیش‌نمایش بدون تغییر سیستم (dry-run)

```bash
nokey --dry-run
```

---

# 🔁 رله Realm

### سناریوی ۱ — نصب Realm

از `nokey --menu` یا `realm.sh` استفاده کنید. پارامترهای قدیمی برای سازگاری حفظ شده‌اند.
```bash
# نصب Xray و Realm، انتقال پورت محلی 443 به 1.2.3.4:443
nokey --realm --remote 1.2.3.4:443

# با آدرس دلخواه
nokey --realm --remote 1.2.3.4:443 --listen 0.0.0.0:8080

# با IPv6
nokey --netstack=6 --realm --remote [2001:db8::1]:443
```

### سناریوی ۲ — فقط نصب Xray (پیش‌فرض، بدون نیاز به پارامتر)
```bash
nokey
```

### سناریوی ۳ — فقط نصب Realm (بدون Xray)
```bash
nokey --realm-only --remote 1.2.3.4:443
```

---

# 🧹 حذف

```bash
nokey --remove              # حذف Xray (همراه با Realm در صورت نصب)
nokey --realm-only --remove  # حذف فقط Realm
```

---

# ⭐ لطفاً ستاره بدهید :)

اشتباه اجتناب‌ناپذیر است—ممنون بابت راهنمایی‌ها!

_فورک شده از https://github.com/crazypeace/ — با تشکر از نویسنده اصلی_

### گزارش عیب‌یابی

فایل `nokey.log` رویدادهای پاک‌سازی‌شده با زمان، سطح و مدت اجرا را ثبت می‌کند. اطلاعات اتصال در `nokey.url` ذخیره می‌شود و دسترسی هر دو فایل `0600` است. برای جزئیات بیشتر `NOKEY_LOG_LEVEL=DEBUG` را تنظیم کنید؛ سطوح `DEBUG`، `INFO` (پیش‌فرض)، `WARN` و `ERROR` پشتیبانی می‌شوند.
