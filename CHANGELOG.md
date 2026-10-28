# Changelog

Bu projedeki önemli değişiklikler bu dosyada listelenir.
Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/), sürümleme [SemVer](https://semver.org/lang/tr/) esaslıdır.

## [2.2.0] - 2026-10-28

Bu depo 2.2.0 ile sıfırdan başlar. 2.1.0 ve öncesi eski depoda yayınlanmıştı.

### Eklendi
- **zDPI.exe arayüzü:** Üç sekme: Durum (hizmeti kur / kaldır, tek seferlik mod), Siteler (site listesi,
  şifreli DNS) ve Nasıl kullanılır. Ek kurulum gerektirmez (.NET Framework 4.8), Windows 11'de sistemin cam
  efektini kullanır, boştayken işlemci kullanmaz.
- **Site listesi:** Hizmet alan adlarını `C:\Program Files\zDPI\liste.txt` dosyasından okur. Liste kaydedilince
  çalışan hizmet yeni listeyle yeniden başlar. Varsayılan alan adları her zaman listededir, alt alan adları otomatik dahildir.
- **Şifreli DNS anahtarı:** Siteler sekmesinden açılıp kapatılır; hizmet yeniden kurulduğunda korunur.
- Motor eylemleri: `list`, `prepare`, `uninstall -Purge` ve arayüz için `-Gui` ilerleme protokolü.
- `tools/build.ps1`: tek komutla exe ve dağıtım zip'i. `CONTRIBUTING.md`: mimari ve geliştirme rehberi.

### Değişti
- Dağıtım paketi yalnızca `zDPI.exe` ve `core/` içerir; `.cmd` dosyaları kaldırıldı.
- Sürücü takıldığında yeniden başlatma sonrası kurulum `zDPI.exe --resume` ile kendiliğinden devam eder.
- Tek seferlik mod arayüze bağlıdır; arayüz kapanınca durur ve kurulu hizmet kaldığı yerden devam eder.
- Hizmet kaldırılınca site listesi korunur.
- Eski sürümle kurulmuş hizmet, liste ilk kaydedildiğinde kayıtlı yöntemle otomatik olarak yeniden kurulur.

[2.2.0]: https://github.com/heFRKN/zDPI-TR/releases/tag/v2.2.0
