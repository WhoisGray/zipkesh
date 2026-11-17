# شروع سریع Zipkesh

این پوشه را روی مک باز کن و Terminal را داخل آن اجرا کن. نصب محلی:

```sh
bash install.sh
```

حداقل macOS 13 لازم است. نصب‌کننده پیش‌نیازها را هم بررسی و نصب می‌کند؛ روی
مک تازه ممکن است تأیید ابزارهای Apple یا رمز مدیر سیستم لازم شود.

پس از نصب، در Finder فایل‌ها را انتخاب کن و از کلیک راست → Quick Actions
یا Services → Zipkesh — Encrypt Archive وارد شو.

- راهنمای فارسی: [README.fa.md](README.fa.md)
- راهنمای انگلیسی: [README.md](README.md)
- انتشار از ابتدا تا Release، همراه دستورهای gh: [docs/PUBLISH.md](docs/PUBLISH.md)
- نتیجهٔ تست‌ها و بررسی‌های باقی‌ماندهٔ macOS: [docs/TESTING.md](docs/TESTING.md)
- تصویر README: [docs/assets/hero.png](docs/assets/hero.png)
- تصویر Social Preview گیت‌هاب: [docs/assets/social.png](docs/assets/social.png)

برای آرشیو خصوصی از ZIP AES-256 یا 7z استفاده کن. Finder نمی‌تواند این دو فرمت
را استخراج کند؛ Keka یا 7-Zip لازم است. گزینهٔ ZIP قدیمی رمزگذاری ضعیف‌تری دارد.
برای پسورد فارسی 7z را انتخاب کن.

بستهٔ سورس با ۲۴ تست روی Linux بررسی شده است. ساخت رابط و نصب واقعی در Finder
هنوز در این محیط اجرا نشده‌اند؛ CI و چک‌لیست تست macOS همراه پروژه هستند.
هیچ ریپو یا Release از طرف این بسته در گیت‌هاب منتشر نشده است. تا تگ v1.0.0
را منتشر نکنی، دستور نصب اینترنتی README کار نمی‌کند؛ از نصب محلی بالا استفاده کن.
