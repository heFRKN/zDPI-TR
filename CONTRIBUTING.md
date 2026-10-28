# Geliştirme rehberi

zDPI'yi incelemek, değiştirmek veya kendi sürümünü yapmak isteyenler için. Proje [MIT lisansı](LICENSE) ile
dağıtılır; telif satırını koruduğunuz sürece kodu dilediğiniz gibi kullanabilirsiniz.

## Proje yapısı

```
zDPI-TR/
├─ zDPI.exe               derlenmiş arayüz (her sürümde güncellenir)
├─ core/
│  ├─ zdpi.ps1            motor: kurulum, yöntem bulma, site listesi, DNS, hizmet
│  ├─ winws.exe           zapret v72.13 (değiştirilmemiş)
│  ├─ cygwin1.dll         zapret v72.13 (değiştirilmemiş)
│  ├─ WinDivert.dll       WinDivert 2.2.2 (değiştirilmemiş)
│  └─ WinDivert64.sys     WinDivert 2.2.2 (değiştirilmemiş)
├─ gui/
│  ├─ App.cs              arayüzün tüm kodu (C# 5, .NET Framework 4.8, WPF)
│  ├─ ui.xaml             görünüm: stiller, sekmeler, yardım metni
│  ├─ app.manifest        yönetici izni, DPI ayarları
│  └─ zdpi.ico            logo (build.ps1 üretir)
├─ tools/build.ps1        derleme ve dağıtım paketi
├─ docs/                  README görselleri
└─ README.txt             dağıtım zip'ine giren kısa kullanım notu
```

## Derleme

Gereken tek şey Windows 10/11. Visual Studio veya .NET SDK gerekmez; Windows'la gelen
`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe` kullanılır.

```powershell
# zDPI.exe'yi repo köküne derler (logo da yeniden üretilir)
powershell -ExecutionPolicy Bypass -File tools\build.ps1

# Arayüzü yönetici izni istemeden denemek için (motor eylemleri çalışmaz)
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -AsInvoker -Out $env:TEMP\zdpi-test\zDPI.exe

# Dağıtım paketi: dist\zDPI-vX.Y.Z.zip ve dist\SHA256SUMS.txt
powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Release
```

Derleyici C# 5 olduğu için `$"..."`, `?.`, `nameof`, `out var` gibi yeni söz dizimleri kullanılamaz.
XAML derlenmez; `ui.xaml` exe'ye kaynak olarak gömülür ve açılışta `XamlReader` ile yüklenir. Bu yüzden XAML'de
olay bağlama (`Click="..."`) ve `x:Class` yoktur; elemanlar `x:Name` ile bulunur ve olaylar `App.cs`'te bağlanır.

## Mimari

```
zDPI.exe (yönetici)
   │  powershell -File core\zdpi.ps1 -Action <eylem> -Gui
   ▼
core\zdpi.ps1 ──► C:\Program Files\zDPI\   winws.exe + DLL'ler, liste.txt, strateji.txt
   │                                        (yalnızca yöneticiler yazabilir)
   └─► "zDPI" Windows hizmeti ──► winws.exe --hostlist=liste.txt ...
```

- **Arayüz iş yapmaz,** motoru çağırır ve sonucu gösterir. Hizmet durumu `ServiceController` ile okunur.
- **Hizmet** SYSTEM olarak `C:\Program Files\zDPI` içinden çalışır ve alan adlarını `liste.txt`'den okur.
  Liste kaydedilince motor çalışan hizmeti yeniden başlatır; yeniden kurulum gerekmez.
- **Tek seferlik mod:** motor `prepare` ile hazırlar ve winws parametrelerini yazar; `winws.exe`'yi arayüz başlatır
  ve bir *job object*'e bağlar. Arayüz nasıl kapanırsa kapansın (çökme dahil) winws de kapanır.
- **Yeniden başlatma gerekirse** motor `RunOnce`'a `zDPI.exe --resume` yazar; açılışta kurulum kendiliğinden sürer.

### Motor eylemleri

Yönetici PowerShell'den doğrudan da kullanılabilir:

| Eylem | Ne yapar |
| :-- | :-- |
| `-Action install [-Strategy N]` | Çakışan araçları kaldırır, dosyaları doğrulayıp kopyalar, çalışan yöntemi bulur, hizmeti kurar |
| `-Action uninstall [-Purge]` | Hizmeti kaldırır, DNS'i geri alır. Site listesi korunur; `-Purge` onu da siler |
| `-Action list -Domains a.com,b.com [-Dns on\|off]` | Listeyi doğrulayıp kaydeder, çalışan hizmeti yeniden başlatır |
| `-Action prepare [-Strategy N]` | Tek seferlik mod için hazırlar, `##args ...` ile winws parametrelerini yazar |
| `-Action test` | Hizmet, yöntem, DNS ve bağlantı durumunu yazar |

### İlerleme protokolü

`-Gui` verildiğinde motor, normal çıktının arasına `##` ile başlayan satırlar yazar. Arayüz yalnızca bunları okur
(`App.cs` → `OnMarker`). Yeni bir adım eklerseniz iki tarafı birlikte güncelleyin.

| İşaret | Anlamı |
| :-- | :-- |
| `##step clean\|files\|dns\|search\|service\|check\|list` | Şu anki adım |
| `##try 3/13` | Yöntem deneniyor |
| `##args <parametreler>` | Tek seferlik mod için winws parametreleri |
| `##ok` | İşlem başarılı |
| `##untested` | Hizmet kuruldu, bağlantı testi geçmedi |
| `##nomethod` | Hiçbir yöntem çalışmadı |
| `##reboot` | WinDivert sürücüsü takılı, yeniden başlatma gerekli |
| `##integrity` | İkili dosyalar doğrulanamadı |
| `##svcfail`, `##fail` | Hizmet başlatılamadı / genel hata |

## Sık yapılan değişiklikler

**Yöntem eklemek:** `core/zdpi.ps1` içindeki `$Strategies` listesine yeni bir satır ekleyin. Otomatik kurulum
yöntemleri sırayla dener; sık çalışanları üste koyun. Parametreler için
[zapret belgelerine](https://github.com/bol-van/zapret/blob/master/docs/readme.en.md) bakın.

**Varsayılan site listesini değiştirmek:** `core/zdpi.ps1` içindeki `$DefaultDomains` ile `gui/App.cs` içindeki
`DefaultSites` aynı olmalı. Yöntem testi `$TestUrls` adreslerine bağlanarak yapılır; varsayılanları değiştirirseniz
bunları ve `$DnsProbe` / `$DnsProbePrefix` değerlerini de güncelleyin.

**Arayüz metinleri ve görünüm:** `gui/ui.xaml`. Renkler dosyanın başındaki kaynaklarda; marka rengi `#990033`.

**Sürüm çıkarmak:** `core/zdpi.ps1` (`$ZdpiVersion`) ve `gui/App.cs` (`Version`) içindeki sürümü birlikte artırın
(farklıysa derleme durur), `CHANGELOG.md`'yi güncelleyin, `tools\build.ps1 -Release` çalıştırın ve `dist\` içindeki
iki dosyayı GitHub sürümüne ekleyin.

## Güvenlik kuralları

Hizmet SYSTEM yetkisiyle çalıştığı için şu kurallar korunmalı:

- `core/` içindeki ikili dosyalar değiştirilmez. Güncellerken resmi zapret sürümünden alın ve `$Binaries` içindeki
  SHA256 özetlerini resmi `sha256sum.txt` ile güncelleyin.
- SYSTEM olarak çalışan hiçbir şey kullanıcının yazabildiği bir klasörden çalıştırılmaz; her şey
  `C:\Program Files\zDPI`'ye kopyalanıp orada tekrar doğrulanır.
- Kullanıcıdan gelen girdi (site adları vb.) motor tarafında da doğrulanır; arayüzdeki doğrulamaya güvenilmez.
- Yönetici yetkisiyle `%TEMP%` gibi kullanıcı klasörlerine sabit adlı dosya yazılmaz.

## Katkı

1. Depoyu fork'layın ve bir dal açın (`git checkout -b yontem-ekle`).
2. Değişikliğinizi yapın, `tools\build.ps1` ile derleyin ve kendi hattınızda deneyin.
3. Pull request açın; ne değiştiğini ve nasıl denediğinizi (Windows sürümü, bağlantı türü) yazın.

Kod stili: PowerShell'de mevcut adlandırmayı (`Do-Install`, `Save-HostList`) ve ASCII yorumları, C# tarafında
dosyadaki düzeni izleyin. Commit mesajları kısa ve Türkçe: `feat: ...`, `fix: ...`, `docs: ...`.
