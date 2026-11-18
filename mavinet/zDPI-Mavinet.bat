@echo off
setlocal EnableExtensions EnableDelayedExpansion
title zDPI-TR Mavinet Discord

:: ---- Yonetici olarak yeniden baslat ----
net session >nul 2>&1
if errorlevel 1 (
    echo Yonetici izni isteniyor...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "DIR=C:\zDPI-Mavinet"
set "SVC=zDPI-Mavinet"
set "LIST=%DIR%\liste.txt"
set "STRATFILE=%DIR%\strateji.txt"

:: Ilk acilista direkt kur
sc query %SVC% >nul 2>&1
if errorlevel 1 goto install

:menu
cls
echo ==============================================
echo      zDPI-TR  ^|  MAVINET OZEL  ^|  DISCORD
echo ==============================================
call :showstatus
echo.
echo  1 - Kur / Yeniden kur
echo  2 - Listeye site ekle
echo  3 - Listeyi Not Defteri ile ac
echo  4 - Strateji degistir (Discord acilmiyorsa)
echo  5 - Kaldir
echo  0 - Cikis
echo.
choice /c 123450 /n /m "Secim: "
if errorlevel 6 exit /b
if errorlevel 5 goto uninstall
if errorlevel 4 goto strategy
if errorlevel 3 goto editlist
if errorlevel 2 goto addsite
if errorlevel 1 goto install
goto menu

:: =============================================================
:install
cls
echo [1/4] Eski / cakisan servisler durduruluyor...
call :stopall

echo [2/4] zapret dosyalari hazirlaniyor...
call :getfiles
if errorlevel 1 (
    echo.
    echo HATA: winws.exe bulunamadi / indirilemedi.
    echo Windows Defender silmis olabilir, C:\zDPI-Mavinet klasorunu
    echo Defender'a "dislama" olarak ekleyip tekrar dene.
    pause
    goto menu
)

echo [3/4] Site listesi kontrol ediliyor...
if not exist "%LIST%" call :writelist

set "STRAT=1"
if exist "%STRATFILE%" set /p STRAT=<"%STRATFILE%"
call :buildargs

echo [4/4] Servis kuruluyor (strateji %STRAT%)...
sc create %SVC% binPath= "%DIR%\winws.exe %ARGS%" DisplayName= "zDPI-TR Mavinet (Discord)" start= auto >nul
sc description %SVC% "Sadece liste.txt icindeki sitelere DPI bypass uygular." >nul
sc failure %SVC% reset= 0 actions= restart/5000 >nul
sc start %SVC% >nul
timeout /t 2 /nobreak >nul

sc query %SVC% | find "RUNNING" >nul
if errorlevel 1 (
    echo.
    echo HATA: Servis baslamadi. Defender winws.exe'yi engelliyor olabilir.
    echo C:\zDPI-Mavinet klasorunu Defender dislamalarina ekleyip 1'e tekrar bas.
) else (
    echo.
    echo TAMAM! Servis calisiyor ve her acilista otomatik baslayacak.
    call :restartdiscord
    echo Discord acilmazsa menuden 4 ile baska strateji dene.
)
pause
goto menu

:: =============================================================
:addsite
echo.
set "NEW="
set /p "NEW=Eklenecek site (ornek: roblox.com): "
if not defined NEW goto menu
set "NEW=!NEW:https://=!"
set "NEW=!NEW:http://=!"
set "NEW=!NEW:www.=!"
for /f "delims=/ " %%A in ("!NEW!") do set "NEW=%%A"
if not exist "%DIR%" mkdir "%DIR%"
(echo.&echo !NEW!)>>"%LIST%"
echo !NEW! eklendi, servis yeniden baslatiliyor...
call :restart
pause
goto menu

:editlist
if not exist "%DIR%" mkdir "%DIR%"
if not exist "%LIST%" call :writelist
echo Not Defteri acildi. Her satira bir site yaz, kaydet ve kapat.
start /wait notepad "%LIST%"
echo Servis yeniden baslatiliyor...
call :restart
pause
goto menu

:: =============================================================
:strategy
cls
echo Discord acilmiyorsa sirayla dene:
echo.
echo  1 - multisplit + seqovl   (varsayilan, cogu yerde calisir)
echo  2 - fake + multidisorder  (agresif)
echo  3 - fake + multisplit     (autottl, md5sig)
echo  4 - multidisorder sniext  (hafif)
echo.
choice /c 1234 /n /m "Strateji: "
set "S=%errorlevel%"
if not exist "%DIR%" mkdir "%DIR%"
>"%STRATFILE%" echo %S%
goto install

:: =============================================================
:uninstall
echo.
call :stopall
echo Servis kaldirildi.
choice /c EH /n /m "C:\zDPI-Mavinet klasoru de silinsin mi? (E/H): "
if errorlevel 2 goto uninstdone
rd /s /q "%DIR%" 2>nul
echo Klasor silindi.
:uninstdone
pause
goto menu

:: =============================================================
::                      ALT FONKSIYONLAR
:: =============================================================
:buildargs
if "%STRAT%"=="2" (
    set "TCP=--dpi-desync=fake,multidisorder --dpi-desync-split-pos=1,midsld --dpi-desync-fooling=badseq,md5sig --dpi-desync-repeats=6"
) else if "%STRAT%"=="3" (
    set "TCP=--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig"
) else if "%STRAT%"=="4" (
    set "TCP=--dpi-desync=multidisorder --dpi-desync-split-pos=1,sniext+1"
) else (
    set "TCP=--dpi-desync=multisplit --dpi-desync-split-seqovl=681 --dpi-desync-split-pos=1"
)
set "ARGS=--wf-tcp=80,443 --wf-udp=443,50000-65535"
set "ARGS=!ARGS! --filter-tcp=80,443 --hostlist=%LIST% !TCP! --new"
set "ARGS=!ARGS! --filter-udp=443 --hostlist=%LIST% --dpi-desync=fake --dpi-desync-repeats=6 --new"
set "ARGS=!ARGS! --filter-udp=50000-65535 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-repeats=6"
exit /b 0

:stopall
for %%S in (%SVC% zDPI zapret winws1 winws2 GoodbyeDPI) do (
    sc stop %%S >nul 2>&1
    sc delete %%S >nul 2>&1
)
taskkill /f /im winws.exe >nul 2>&1
taskkill /f /im goodbyedpi.exe >nul 2>&1
sc stop WinDivert >nul 2>&1
sc stop WinDivert14 >nul 2>&1
timeout /t 2 /nobreak >nul
exit /b 0

:restart
sc stop %SVC% >nul 2>&1
timeout /t 3 /nobreak >nul
sc start %SVC% >nul 2>&1
timeout /t 1 /nobreak >nul
sc query %SVC% | find "RUNNING" >nul
if errorlevel 1 (echo UYARI: Servis calismiyor, menuden 1 ile yeniden kur.) else (echo Servis calisiyor.)
exit /b 0

:getfiles
if not exist "%DIR%" mkdir "%DIR%"
set "SRC="
if exist "%~dp0winws.exe" set "SRC=%~dp0"
if not defined SRC if exist "%~dp0zapret-winws\winws.exe" set "SRC=%~dp0zapret-winws\"
if not defined SRC for /r "%~dp0." %%F in (winws.exe) do if not defined SRC if exist "%%F" set "SRC=%%~dpF"
if defined SRC (
    if /i "!SRC!"=="%DIR%\" exit /b 0
    xcopy "!SRC!*" "%DIR%\" /E /Y /I /Q >nul
    if exist "%DIR%\winws.exe" exit /b 0
)
if exist "%DIR%\winws.exe" exit /b 0

echo     winws.exe bulunamadi, GitHub'dan indiriliyor (bol-van/zapret-win-bundle)...
set "ZIP=%TEMP%\zapret-win-bundle.zip"
set "EXT=%TEMP%\zapret-win-bundle"
if exist "%EXT%" rd /s /q "%EXT%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest 'https://github.com/bol-van/zapret-win-bundle/archive/refs/heads/master.zip' -OutFile '%ZIP%'; Expand-Archive -Path '%ZIP%' -DestinationPath '%EXT%' -Force"
if not exist "%EXT%\zapret-win-bundle-master\zapret-winws\winws.exe" exit /b 1
xcopy "%EXT%\zapret-win-bundle-master\zapret-winws\*" "%DIR%\" /E /Y /I /Q >nul
del "%ZIP%" >nul 2>&1
rd /s /q "%EXT%" >nul 2>&1
if exist "%DIR%\winws.exe" exit /b 0
exit /b 1

:writelist
> "%LIST%" (
    echo discord.com
    echo discord.gg
    echo discord.co
    echo discord.dev
    echo discord.new
    echo discord.gift
    echo discord.media
    echo discordapp.com
    echo discordapp.net
    echo discordcdn.com
    echo discordstatus.com
    echo dis.gd
)
exit /b 0

:restartdiscord
set "DLNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Discord Inc\Discord.lnk"
set "DUPD=%LOCALAPPDATA%\Discord\Update.exe"
if not exist "%DUPD%" if not exist "%DLNK%" exit /b 0
echo Discord yeniden baslatiliyor...
taskkill /f /im Discord.exe >nul 2>&1
timeout /t 2 /nobreak >nul
:: Discord'u yonetici olmadan ac (explorer uzerinden)
if exist "%DLNK%" (
    explorer.exe "%DLNK%"
) else (
    runas /trustlevel:0x20000 "\"%DUPD%\" --processStart Discord.exe" >nul 2>&1
)
exit /b 0

:showstatus
sc query %SVC% >nul 2>&1
if errorlevel 1 (
    echo  Durum    : KURULU DEGIL
    exit /b 0
)
sc query %SVC% | find "RUNNING" >nul
if errorlevel 1 (echo  Durum    : KURULU ama CALISMIYOR) else (echo  Durum    : CALISIYOR ^(otomatik baslar^))
set "ST=1"
if exist "%STRATFILE%" set /p ST=<"%STRATFILE%"
echo  Strateji : !ST!
echo  Liste    : %LIST%
exit /b 0
