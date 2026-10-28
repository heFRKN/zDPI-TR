# zDPI motoru (by FRKN) - MIT lisansi
# zDPI.exe bu betigi cagirir. Komut satirindan da kullanilabilir (yonetici PowerShell):
#   zdpi.ps1 -Action install [-Strategy N]            calisan yontemi bulur, hizmet olarak kurar
#   zdpi.ps1 -Action uninstall [-Purge]               hizmeti kaldirir (-Purge: site listesi dahil her seyi siler)
#   zdpi.ps1 -Action list -Domains a,b [-Dns on|off]  site listesini kaydeder ve calisan hizmete uygular
#   zdpi.ps1 -Action prepare [-Strategy N]            tek seferlik mod icin hazirlar, winws parametrelerini yazar
#   zdpi.ps1 -Action test                             durum ve baglanti testi
param(
    [ValidateSet('install','uninstall','list','prepare','test')]
    [string]$Action = 'test',
    [int]$Strategy = 0,
    # list: virgulle ayrilmis alan adlari. Varsayilanlar her zaman listede kalir.
    [string]$Domains = '',
    # list: sifreli DNS'i ac / kapat. Bos ise dokunulmaz.
    [ValidateSet('','on','off')]
    [string]$Dns = '',
    # uninstall: site listesini de sil
    [switch]$Purge,
    # zDPI.exe tarafindan cagrildiginda: ilerleme isaretleri (##...) yazar
    [switch]$Gui
)

$ZdpiVersion = '2.2.0'
$ErrorActionPreference = 'Continue'
$CoreDir      = $PSScriptRoot
$RootDir      = Split-Path $CoreDir -Parent
$Curl         = Join-Path $env:SystemRoot 'System32\curl.exe'
$ServiceName  = 'zDPI'
$GuiExe       = Join-Path $RootDir 'zDPI.exe'

# Guvenlik: hizmet SYSTEM yetkisiyle calistigi icin winws ve DLL'leri, yalnizca
# yoneticilerin yazabildigi Program Files altina kopyalanir ve oradan calistirilir.
# Kullanicinin yazabildigi indirme klasorunden SYSTEM olarak kod calistirilmaz.
# Durum dosyalari (secilen yontem, DNS kaydi, site listesi) da ayni korumali klasorde tutulur.
$InstallDir   = Join-Path $env:ProgramFiles 'zDPI'
$Exe          = Join-Path $InstallDir 'winws.exe'
$StrategyFile = Join-Path $InstallDir 'strateji.txt'
$DnsMarker    = Join-Path $InstallDir 'dns_degisti.txt'
$DnsKeep      = Join-Path $InstallDir 'dns_kalici.txt'
$ListFile     = Join-Path $InstallDir 'liste.txt'

# Paketteki ikili dosyalarin SHA256 ozetleri. Dosyalar degistirilmisse kurulum yapilmaz.
# Dordu de resmi zapret v72.13 surumunun binaries/windows-x86_64 klasoruyle birebir aynidir:
# https://github.com/bol-van/zapret/releases/tag/v72.13 (sha256sum.txt)
# WinDivert.dll / WinDivert64.sys ayrica resmi WinDivert 2.2.2 (basil00) ile aynidir.
$Binaries = [ordered]@{
    'winws.exe'       = 'A14BFF1DF6234EA555D2E0C61B589F0707C0B12D6C9B7EECCDA76012154996E8'
    'cygwin1.dll'     = '103104A52E5293CE418944725DF19E2BF81AD9269B9A120D71D39028E821499B'
    'WinDivert.dll'   = 'C1E060EE19444A259B2162F8AF0F3FE8C4428A1C6F694DCE20DE194AC8D7D9A2'
    'WinDivert64.sys' = '8DA085332782708D8767BCACE5327A6EC7283C17CFB85E40B03CD2323A90DDC2'
}

# Ayni WinDivert surucusunu kullanan ve zDPI ile cakisan hizmetler/surecler.
# NOT: "WinDivert" surucu hizmetine ASLA dokunulmaz. Kullanimdayken silinirse surucu
# STOP_PENDING durumunda takilir ve yeniden baslatana kadar hicbir DPI araci calisamaz.
$ConflictServices = 'zDPI','zDPI_Service','FailureStudioDPI','ZapretSuperonline','zapret','winws1','winws2','GoodbyeDPI'
$ConflictProcs    = 'winws','goodbyedpi'

# Varsayilan liste ve yontem testinde kullanilan adresler. zDPI.exe'deki DefaultSites ile ayni olmali.
$DefaultDomains = 'discord.com,discord.gg,discordapp.com,discordapp.net,discord.media,discordcdn.com,discordstatus.com'
$TestUrls       = 'https://discord.com','https://gateway.discord.gg','https://cdn.discordapp.com'
$DnsProbe       = 'discord.com'
$DnsProbePrefix = '162.159.*'   # varsayilan alan adlarinin dogru adres blogu

# Tek seferlik mod: tum sitelerde TLS/HTTP ve QUIC, sesli sohbet portlarinda STUN ve IP Discovery.
$BaseArgs = '--wf-tcp=80,443 --wf-udp=443,19294-19344,50000-50100 ' +
            '--filter-udp=443 --filter-l7=quic --dpi-desync=fake --dpi-desync-repeats=6 --new ' +
            '--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-repeats=6 --new ' +
            '--filter-tcp=80,443 '

# Hizmet: TLS/HTTP ve QUIC yalnizca site listesindeki (liste.txt) alan adlarinda; alt alan
# adlari otomatik eslesir. Ses portlarinda STUN degil, yalnizca IP Discovery paketleri islenir.
$HostListArg = '--hostlist="' + $ListFile + '"'
$ServiceBaseArgs = '--wf-tcp=80,443 --wf-udp=443,19294-19344,50000-50100 ' +
                   '--filter-udp=443 --filter-l7=quic ' + $HostListArg + ' --dpi-desync=fake --dpi-desync-repeats=6 --new ' +
                   '--filter-udp=19294-19344,50000-50100 --filter-l7=discord --dpi-desync=fake --dpi-desync-repeats=6 --new ' +
                   '--filter-tcp=80,443 --filter-l7=http,tls ' + $HostListArg + ' '

# TCP yontemleri. Otomatik modda bu sirayla denenir, ilk calisan secilir.
$Strategies = @(
    @{ Name = 'Standart (fake+split, autottl, md5sig)'; Args = '--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --dpi-desync-repeats=6' }
    @{ Name = 'Klasik (fake, md5sig)';                  Args = '--dpi-desync=fake --dpi-desync-fooling=md5sig' }
    @{ Name = 'Klasik TTL 3 (fake, md5sig)';            Args = '--dpi-desync=fake --dpi-desync-fooling=md5sig --dpi-desync-ttl=3' }
    @{ Name = 'Fake+Split (badseq)';                    Args = '--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq --dpi-desync-repeats=6' }
    @{ Name = 'Agresif Fake+Disorder (badseq)';         Args = '--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq --dpi-desync-repeats=6' }
    @{ Name = 'Seqovl Split';                           Args = '--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1' }
    @{ Name = 'Fake TTL 3';                             Args = '--dpi-desync=fake --dpi-desync-ttl=3' }
    @{ Name = 'Fake TTL 4 (fiber/VDSL)';                Args = '--dpi-desync=fake --dpi-desync-ttl=4' }
    @{ Name = 'Fake+Split TTL 5';                       Args = '--dpi-desync=fake,multisplit --dpi-desync-split-pos=2 --dpi-desync-ttl=5' }
    @{ Name = 'Disorder (fake paketsiz)';               Args = '--dpi-desync=multidisorder --dpi-desync-split-pos=1,midsld' }
    @{ Name = 'SNI Split (fake paketsiz)';              Args = '--dpi-desync=multisplit --dpi-desync-split-pos=1,sniext+1' }
    @{ Name = 'FakedSplit (badseq)';                    Args = '--dpi-desync=fakedsplit --dpi-desync-split-pos=1 --dpi-desync-fooling=badseq' }
    @{ Name = 'Fake TLS Mod (badseq)';                  Args = '--dpi-desync=fake --dpi-desync-fooling=badseq --dpi-desync-repeats=6 --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com' }
)

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

# Arayuz icin ilerleme isareti (##adim). Yalnizca -Gui ile yazilir; protokol CONTRIBUTING.md'de.
function Mark([string]$k) { if ($Gui) { Write-Host ('##' + $k) } }

function Show-Header([string]$title) {
    Write-Host ''
    Write-Host ("  zDPI " + $ZdpiVersion + " - " + $title) -ForegroundColor Cyan
    Write-Host ''
}

function Get-FullArgs([int]$idx, [switch]$Service) {
    if ($Service) { return $ServiceBaseArgs + $Strategies[$idx - 1].Args }
    return $BaseArgs + $Strategies[$idx - 1].Args
}

function Get-SavedStrategy {
    try {
        $n = [int](Get-Content $StrategyFile -ErrorAction Stop | Select-Object -First 1)
        if ($n -ge 1 -and $n -le $Strategies.Count) { return $n }
    } catch {}
    return 0
}

function Test-FileHash([string]$path, [string]$expected) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    return ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $expected)
}

# Korumali kurulum klasorunu olusturur.
function Ensure-InstallDir {
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        # Program Files'in varsayilan izinlerine don: yalnizca yoneticiler ve SYSTEM yazabilir
        icacls.exe $InstallDir /reset /T /Q | Out-Null
        return $true
    } catch {
        Say ("    [-] Kurulum klasoru olusturulamadi: " + $_.Exception.Message) Red
        return $false
    }
}

# Paketteki ikili dosyalari dogrular ve korumali kurulum klasorune kopyalar.
function Install-Binaries {
    Say '[*] Dosyalar dogrulaniyor ve korumali klasore kopyalaniyor...'
    foreach ($name in $Binaries.Keys) {
        if (-not (Test-FileHash (Join-Path $CoreDir $name) $Binaries[$name])) {
            Say ("    [-] core\$name eksik, bozuk veya degistirilmis! Paketi yeniden indirin.") Red
            Mark 'integrity'
            return $false
        }
    }
    if (-not (Ensure-InstallDir)) { Mark 'fail'; return $false }
    try {
        foreach ($name in $Binaries.Keys) {
            $dst = Join-Path $InstallDir $name
            if (Test-FileHash $dst $Binaries[$name]) { continue }
            Copy-Item -LiteralPath (Join-Path $CoreDir $name) -Destination $dst -Force -ErrorAction Stop
        }
    } catch {
        Say ("    [-] Kurulum klasorune kopyalanamadi: " + $_.Exception.Message) Red
        Mark 'fail'
        return $false
    }
    # Kopyalama sirasinda araya girilmediginden emin olmak icin hedefte tekrar dogrula
    foreach ($name in $Binaries.Keys) {
        if (-not (Test-FileHash (Join-Path $InstallDir $name) $Binaries[$name])) {
            Say ("    [-] $InstallDir\$name dogrulanamadi.") Red
            Mark 'integrity'
            return $false
        }
    }
    Say ("    [+] Dosyalar dogrulandi: " + $InstallDir) Green
    return $true
}

# ---------------------------------------------------------------- site listesi

$DomainPattern = '^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$'

function Read-HostList {
    if (Test-Path -LiteralPath $ListFile) { return @(Get-Content -LiteralPath $ListFile) }
    return @()
}

# Varsayilanlar + verilen alan adlarini dogrulayip liste.txt'ye yazar.
# Gecersiz satirlar atlanir; hizmet SYSTEM olarak okudugu icin dosya korumali klasordedir.
function Save-HostList([string[]]$extra) {
    $list = @()
    foreach ($d in @($DefaultDomains -split ',') + @($extra)) {
        $d = ([string]$d).Trim().ToLowerInvariant()
        if ($d -match $DomainPattern -and $list -notcontains $d) { $list += $d }
    }
    Set-Content -LiteralPath $ListFile -Value $list -Encoding ASCII
}

# ---------------------------------------------------------------- temizlik

function Stop-Conflicts([switch]$DeleteServices) {
    foreach ($s in $ConflictServices) {
        if (Get-Service -Name $s -ErrorAction SilentlyContinue) {
            sc.exe stop $s 2>&1 | Out-Null
            if ($DeleteServices) { sc.exe delete $s 2>&1 | Out-Null }
        }
    }
    foreach ($t in 'zDPI','zDPI_Autostart') { schtasks.exe /Delete /TN $t /F 2>&1 | Out-Null }
    Get-Process -Name $ConflictProcs -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    # Surecler kapanip WinDivert tutamaclari birakilana kadar bekle
    for ($i = 0; $i -lt 20 -and (Get-Process -Name $ConflictProcs -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 250
    }
}

# ---------------------------------------------------------------- WinDivert

function Test-WinDivertStuck {
    $q = sc.exe query WinDivert 2>&1 | Out-String
    return ($q -match 'STOP_PENDING')
}

# Surucu takiliysa tek care yeniden baslatmak. Acilista kurulum zDPI.exe ile kendiliginden devam eder.
function Request-Reboot {
    Say '  [!] WinDivert surucusu takili (STOP_PENDING). Bilgisayari yeniden baslatin;' Red
    Say '      kurulum acilista kendiliginden devam edecek.' Yellow
    try {
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'zDPI_Kurulum' `
            -Value ('"' + $GuiExe + '" --resume') -PropertyType String -Force | Out-Null
    } catch {}
    Mark 'reboot'
}

# ---------------------------------------------------------------- DNS

function Test-DnsOk {
    # Zehirlenmis DNS, varsayilan alan adi icin baska ya da bos adres dondurur.
    try {
        $ips = Resolve-DnsName -Name $DnsProbe -Type A -DnsOnly -QuickTimeout -ErrorAction Stop |
               Where-Object { $_.Type -eq 'A' } | ForEach-Object { $_.IPAddress }
        return [bool]($ips | Where-Object { $_ -like $DnsProbePrefix })
    } catch { return $false }
}

function Enable-SecureDns {
    # Windows'un yerlesik sifreli DNS'i (DoH, 1.1.1.1). Saglayicinin 53. port
    # mudahalesinden etkilenmez. Tum aktif fiziksel adaptorlere uygulanir.
    $servers = '1.1.1.1','1.0.0.1'
    foreach ($s in $servers) {
        try {
            if (Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue) {
                Set-DnsClientDohServerAddress -ServerAddress $s -DohTemplate 'https://cloudflare-dns.com/dns-query' -AutoUpgrade $true -AllowFallbackToUdp $false -ErrorAction Stop | Out-Null
            } else {
                Add-DnsClientDohServerAddress -ServerAddress $s -DohTemplate 'https://cloudflare-dns.com/dns-query' -AutoUpgrade $true -AllowFallbackToUdp $false -ErrorAction Stop | Out-Null
            }
        } catch {}
    }
    $changed = @()
    $adapters = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up'
    foreach ($a in $adapters) {
        Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers -ErrorAction SilentlyContinue
        foreach ($s in $servers) {
            $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$($a.InterfaceGuid)\DohInterfaceSettings\Doh\$s"
            try {
                New-Item -Path $k -Force -ErrorAction Stop | Out-Null
                New-ItemProperty -Path $k -Name 'DohFlags' -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null
            } catch {}
        }
        $changed += $a.InterfaceGuid
    }
    if ($changed) { $changed | Set-Content -Path $DnsMarker -Encoding ASCII }
    ipconfig.exe /flushdns | Out-Null
    Start-Sleep -Seconds 1
}

function Restore-Dns {
    if (-not (Test-Path -LiteralPath $DnsMarker)) { return }
    foreach ($line in Get-Content -LiteralPath $DnsMarker) {
        # Yalnizca gecerli bir adaptor GUID'i kabul edilir. Dosyaya yazilmis baska bir deger
        # ile registry'de yetkili (recurse) silme yapilmasini onler.
        $guid = $line.Trim()
        if ($guid -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') { continue }
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object InterfaceGuid -eq $guid
        if ($a) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue }
        Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$guid\DohInterfaceSettings" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $DnsMarker -Force -ErrorAction SilentlyContinue
    foreach ($s in '1.1.1.1','1.0.0.1') {
        Set-DnsClientDohServerAddress -ServerAddress $s -AutoUpgrade $false -AllowFallbackToUdp $false -ErrorAction SilentlyContinue | Out-Null
    }
    ipconfig.exe /flushdns | Out-Null
    Say '  [+] DNS ayarlari varsayilana (DHCP) donduruldu.' Green
}

function Ensure-Dns {
    Say '[*] DNS kontrol ediliyor...'
    if (Test-DnsOk) { Say '    [+] DNS saglam.' Green; return }
    Say '    [!] DNS engelli/zehirli. Sifreli DNS aciliyor...' Yellow
    Enable-SecureDns
    if (Test-DnsOk) { Say '    [+] Sifreli DNS aktif.' Green }
    else { Say '    [-] DNS hala dogru cozmuyor. Yine de devam ediliyor.' Red }
}

# ---------------------------------------------------------------- baglanti testi

function Test-Url([string]$u) {
    & $Curl -s -o NUL --connect-timeout 4 -m 7 $u 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-Target {
    foreach ($u in $TestUrls) { if (-not (Test-Url $u)) { return $false } }
    return $true
}

# ---------------------------------------------------------------- yontem

# Yontemi gecici olarak calistirip test adreslerine erisilebiliyor mu bakar.
# Donus: 'ok' | 'fail' | 'driver' (winws baslayamadi)
function Try-Strategy([int]$idx, [switch]$Service) {
    # Hata ciktisi korumali klasore yazilir (kullanicinin %TEMP%'ine yonetici olarak
    # sabit isimli dosya yazmak sembolik link saldirisina acik olurdu).
    $err = Join-Path $InstallDir 'winws_hata.txt'
    $p = Start-Process -FilePath $Exe -ArgumentList (Get-FullArgs $idx -Service:$Service) -WorkingDirectory $InstallDir `
         -WindowStyle Hidden -PassThru -RedirectStandardError $err
    Start-Sleep -Milliseconds 1500
    if ($p.HasExited) {
        $script:LastWinwsError = (Get-Content $err -Raw -ErrorAction SilentlyContinue)
        return 'driver'
    }
    $ok = Test-Target
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    $p.WaitForExit(3000) | Out-Null
    Start-Sleep -Milliseconds 400
    if ($ok) { return 'ok' } else { return 'fail' }
}

# Calisan yontemi bulur. Once kayitli olani, sonra hepsini sirayla dener.
# Donus: yontem no | 0 (hicbiri olmadi) | -1 (surucu takili) | -2 (winws hatasi)
function Find-Strategy([switch]$Service) {
    $order = @()
    $saved = Get-SavedStrategy
    if ($saved) { $order += $saved }
    $order += (1..$Strategies.Count | Where-Object { $_ -ne $saved })

    Say '[*] Hattinizda calisan yontem araniyor (1-2 dakika surebilir)...'
    $n = 0
    foreach ($i in $order) {
        $n++
        Mark ("try {0}/{1}" -f $n, $order.Count)
        Write-Host ("    [{0,2}/{1}] {2,-42} " -f $n, $order.Count, $Strategies[$i - 1].Name) -NoNewline
        switch (Try-Strategy $i -Service:$Service) {
            'ok'     { Write-Host 'CALISIYOR' -ForegroundColor Green; return $i }
            'fail'   { Write-Host 'olmadi' -ForegroundColor DarkGray }
            'driver' {
                Write-Host 'HATA' -ForegroundColor Red
                if (Test-WinDivertStuck) { return -1 }
                Say ("    winws hatasi: " + $script:LastWinwsError) Red
                return -2
            }
        }
    }
    return 0
}

# Istenen yontemi dogrular ya da calisani arar. Basarisizsa 0 doner.
function Resolve-Strategy([int]$requested, [switch]$Service) {
    if ($requested -ge 1 -and $requested -le $Strategies.Count) {
        if (Test-WinDivertStuck) { Request-Reboot; return 0 }
        return $requested
    }
    if (Test-Target) {
        Say '[*] Test adresleri zaten erisilebilir. Kayitli ya da varsayilan yontem kullanilacak.' Yellow
        if (Test-WinDivertStuck) { Request-Reboot; return 0 }
        $s = Get-SavedStrategy
        if ($s) { return $s } else { return 1 }
    }
    $idx = Find-Strategy -Service:$Service
    if ($idx -eq -1) { Request-Reboot; return 0 }
    if ($idx -eq -2) { Mark 'fail'; return 0 }
    if ($idx -eq 0) {
        Mark 'nomethod'
        Say '  [-] Hicbir yontem calismadi. Acik VPN / DPI araclarini kapatip tekrar deneyin.' Red
        return 0
    }
    Set-Content -Path $StrategyFile -Value $idx -Encoding ASCII
    return $idx
}

# Kurulumdan sonra sesli sohbet uygulamasi aciksa yeni baglantilarla acilsin diye yeniden baslatilir.
function Restart-ChatApp {
    $procs = Get-Process -Name Discord, DiscordCanary, DiscordPTB -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    # Yonetici olarak acilmasin diye explorer uzerinden (normal kullanici) baslatilir
    $lnk = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter 'Discord.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($lnk) { Start-Process explorer.exe -ArgumentList ('"' + $lnk.FullName + '"') }
}

# ---------------------------------------------------------------- eylemler

function Do-Install([int]$requested) {
    Show-Header 'HIZMET KURULUMU'
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'zDPI_Kurulum' -ErrorAction SilentlyContinue

    Mark 'step clean'
    Say '[*] Eski hizmetler ve cakisan DPI araclari kaldiriliyor...'
    Stop-Conflicts -DeleteServices
    Mark 'step files'
    if (-not (Install-Binaries)) { return }
    Save-HostList (Read-HostList)
    # Sifreli DNS kullanici tarafindan bilerek acildiysa (dns_kalici.txt) dokunulmaz.
    if (-not (Test-Path -LiteralPath $DnsKeep)) { Restore-Dns }

    Mark 'step search'
    $idx = Resolve-Strategy $requested -Service
    if ($idx -le 0) { return }
    if ($requested -ge 1) { Set-Content -Path $StrategyFile -Value $idx -Encoding ASCII }

    Mark 'step service'
    Say ('[*] Hizmet kuruluyor: ' + $Strategies[$idx - 1].Name)
    $bin = '"' + $Exe + '" ' + (Get-FullArgs $idx -Service)
    try {
        New-Service -Name $ServiceName -BinaryPathName $bin -DisplayName 'zDPI Bypass Service' `
            -Description ('zDPI by FRKN - ' + $Strategies[$idx - 1].Name) `
            -StartupType Automatic -ErrorAction Stop | Out-Null
    } catch {
        Say ("    [-] Hizmet olusturulamadi: " + $_.Exception.Message) Red
        Mark 'svcfail'
        return
    }
    # Cokerse 5 sn sonra kendini yeniden baslatsin
    sc.exe failure $ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/10000 | Out-Null
    Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Say '    [-] Hizmet baslatilamadi.' Red
        if (Test-WinDivertStuck) { Request-Reboot } else { Mark 'svcfail' }
        return
    }

    Mark 'step check'
    Say '[*] Son kontrol yapiliyor...'
    $ok = Test-Target
    Restart-ChatApp
    if ($ok) { Mark 'ok'; Say '[+] Kurulum tamamlandi. Hizmet her acilista kendiliginden baslar.' Green }
    else { Mark 'untested'; Say '[!] Hizmet kuruldu ama baglanti testi gecmedi.' Yellow }
}

function Do-Uninstall {
    Show-Header 'HIZMETI KALDIR'
    Stop-Conflicts -DeleteServices
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'zDPI_Kurulum' -ErrorAction SilentlyContinue
    Restore-Dns
    Remove-Item -LiteralPath $DnsKeep -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $InstallDir) {
        # Site listesi korunur; yeniden kurulumda ayni liste kullanilir. -Purge her seyi siler.
        Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $Purge -or $_.Name -ne 'liste.txt' } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        if ($Purge) { Remove-Item -LiteralPath $InstallDir -Force -ErrorAction SilentlyContinue }
    }
    ipconfig.exe /flushdns | Out-Null
    Say '[+] Hizmet kaldirildi.' Green
    Mark 'ok'
}

function Do-SetList([string]$csv, [string]$dns) {
    Show-Header 'SITE LISTESI'
    Mark 'step list'
    if (-not (Ensure-InstallDir)) { Mark 'fail'; return }
    Save-HostList ($csv -split ',')
    Say ("[+] Liste kaydedildi (" + (Read-HostList).Count + " site).") Green
    if ($dns -eq 'on') {
        Mark 'step dns'
        Enable-SecureDns
        Set-Content -LiteralPath $DnsKeep -Value 1 -Encoding ASCII
        Say '[+] Sifreli DNS acildi.' Green
    } elseif ($dns -eq 'off') {
        Mark 'step dns'
        Remove-Item -LiteralPath $DnsKeep -Force -ErrorAction SilentlyContinue
        Restore-Dns
    }
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $img = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName" -ErrorAction SilentlyContinue).ImagePath
        if ($img -notlike '*--hostlist=*') {
            # Eski surumle kurulan hizmet listeyi okumaz; kayitli yontemle yeniden kurulur.
            Do-Install (Get-SavedStrategy)
            return
        }
        # Durdurulmus hizmet (or. tek seferlik mod acik) baslatilmaz, iki winws cakisir.
        if ($svc.Status -eq 'Running') {
            Say '[*] Hizmet yeni listeyle yeniden baslatiliyor...'
            Restart-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
    }
    Mark 'ok'
}

# Tek seferlik mod: hazirlar ve winws parametrelerini yazar. winws'i zDPI.exe kendisi
# baslatir, boylece arayuz kapaninca winws de kapanir.
function Do-Prepare([int]$requested) {
    Show-Header 'TEK SEFERLIK MOD'
    Mark 'step clean'
    Stop-Conflicts
    Mark 'step files'
    if (-not (Install-Binaries)) { return }
    Mark 'step dns'
    Ensure-Dns
    Mark 'step search'
    $idx = Resolve-Strategy $requested
    if ($idx -le 0) { return }
    Mark ('args ' + (Get-FullArgs $idx))
}

function Do-Test {
    Show-Header 'DURUM'
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) { Say ("  Hizmet    : " + $svc.Status) $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Red' }) }
    else      { Say  '  Hizmet    : Kurulu degil' Yellow }
    $running = [bool](Get-Process winws -ErrorAction SilentlyContinue)
    Say ("  winws     : " + $(if ($running) { 'Calisiyor' } else { 'Calismiyor' })) $(if ($running) { 'Green' } else { 'Red' })
    $s = Get-SavedStrategy
    if ($s) { Say ("  Yontem    : " + $s + " - " + $Strategies[$s - 1].Name) }
    Say ("  Site      : " + (Read-HostList).Count)
    if (Test-DnsOk) { Say '  DNS       : Saglam' Green } else { Say '  DNS       : Engelli / zehirli' Red }
    if (Test-WinDivertStuck) { Say '  WinDivert : TAKILI - bilgisayari yeniden baslatin!' Red }
    Write-Host ''
    foreach ($u in $TestUrls) {
        Write-Host ("  {0,-34} " -f $u) -NoNewline
        if (Test-Url $u) { Write-Host 'ERISILEBILIR' -ForegroundColor Green } else { Write-Host 'ERISILEMEDI' -ForegroundColor Red }
    }
    Write-Host ''
}

switch ($Action) {
    'install'   { Do-Install $Strategy }
    'uninstall' { Do-Uninstall }
    'list'      { Do-SetList $Domains $Dns }
    'prepare'   { Do-Prepare $Strategy }
    'test'      { Do-Test }
}
