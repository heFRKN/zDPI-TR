# zDPI-TR · Mavinet özel (Discord)

Mavinet gibi yerel internet sağlayıcılarında standart zapret / SplitWire / GoodbyeDPI profilleri Discord'u açamayabiliyor.
Bu sürüm tek bir `.bat` dosyasıdır ve **yalnızca Discord'a** (ve listeye eklediğin sitelere) dokunur.
Oyunlar, tarayıcı ve diğer siteler hiç etkilenmez, ping değişmez, VPN/WARP yoktur.

**[İndir: zDPI-Mavinet.zip](https://github.com/heFRKN/zDPI-TR/releases/tag/mavinet-v1.0.0)**

## Kullanım

1. `zDPI-Mavinet.zip` dosyasını indir ve bir klasöre çıkar.
2. `zDPI-Mavinet.bat` dosyasına çift tıkla, yönetici iznine **Evet** de.
3. Bitti. Hizmet kurulur, Discord kendiliğinden yeniden açılır. Bilgisayar her açıldığında hizmet arka planda kendisi başlar,
   bat'ı bir daha açmana gerek yoktur.

Bat'ı tekrar açarsan menü gelir:

| Tuş | Ne yapar |
| --- | --- |
| 1 | Kur / yeniden kur |
| 2 | Listeye site ekle (adını yaz, hizmet kendini yeniden başlatır) |
| 3 | Listeyi Not Defteri ile aç, kaydedip kapatınca hizmet yeniden başlar |
| 4 | Strateji değiştir (Discord açılmazsa 1→4 sırayla dene) |
| 5 | Kaldır |

Site listesi: `C:\zDPI-Mavinet\liste.txt`. Her satıra bir alan adı yazılır, alt alan adları otomatik dahildir.
Discord alan adları hazır gelir. Ses kanalları için yalnızca Discord ses (UDP) paketlerine müdahale edilir.

## Bilmen gerekenler

- Kurulumda çakışmasın diye eski DPI hizmetleri (`zDPI`, `zapret`, `winws1/2`, `GoodbyeDPI`) durdurulup kaldırılır.
  Ana zDPI-TR uygulamasını kullanıyorsan ikisinden birini seç, aynı anda çalışmazlar.
- Windows Defender `winws.exe`'yi "HackTool" diye silebilir. Hizmet başlamazsa `C:\zDPI-Mavinet` klasörünü Defender
  dışlamalarına ekleyip bat'ı tekrar çalıştır, `1`'e bas.
- Sadece `.bat` dosyasını indirirsen de çalışır: yanında `winws.exe` bulamazsa
  [bol-van/zapret-win-bundle](https://github.com/bol-van/zapret-win-bundle)'dan indirir.

Motor: [zapret](https://github.com/bol-van/zapret) (`winws.exe`, WinDivert). Lisans ve üçüncü taraf bildirimleri ana depodadır.
