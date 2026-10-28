// zDPI arayuzu (by FRKN)
// Tum is core\zdpi.ps1 motorunda yapilir; arayuz motoru cagirir, ilerleme isaretlerini (##...)
// okur ve durumu gosterir. Tek seferlik modda winws'i arayuz baslatir ve bir is nesnesine
// baglar: arayuz hangi sekilde kapanirsa kapansin winws de kapanir.
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Markup;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using Microsoft.Win32;
using Ellipse = System.Windows.Shapes.Ellipse;
using Path = System.Windows.Shapes.Path;

namespace Zdpi
{
    public class SiteItem
    {
        public string Name { get; set; }
        public string Display { get; set; }
        public bool Locked { get; set; }
        public bool First { get; set; }
        public Visibility LockVisibility { get { return Locked ? Visibility.Visible : Visibility.Collapsed; } }
        public Visibility RemoveVisibility { get { return Locked ? Visibility.Collapsed : Visibility.Visible; } }
        public Visibility SeparatorVisibility { get { return First ? Visibility.Collapsed : Visibility.Visible; } }
    }

    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct Margins { public int Left, Right, Top, Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimit
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimit
        {
            public BasicLimit Basic;
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr proc, IntPtr min, IntPtr max);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attr, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int cls, ref ExtendedLimit info, int size);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr handle);

        // Bos bellegi isletim sistemine geri verir (pencere arka plandayken RAM kullanimi duser).
        public static void Trim()
        {
            SetProcessWorkingSetSize(GetCurrentProcess(), (IntPtr)(-1), (IntPtr)(-1));
        }

        // Is nesnesi kapaninca icindeki surec de kapanir (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE).
        public static IntPtr CreateKillOnCloseJob(IntPtr process)
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return IntPtr.Zero;
            var info = new ExtendedLimit();
            info.Basic.LimitFlags = 0x2000;
            if (!SetInformationJobObject(job, 9, ref info, Marshal.SizeOf(typeof(ExtendedLimit))) ||
                !AssignProcessToJobObject(job, process))
            {
                CloseHandle(job);
                return IntPtr.Zero;
            }
            return job;
        }

        public static int OsBuild()
        {
            try
            {
                using (var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion"))
                    return int.Parse((string)k.GetValue("CurrentBuildNumber"), CultureInfo.InvariantCulture);
            }
            catch { return 0; }
        }
    }

    class Shell
    {
        const string Version = "2.2.0";
        const string ServiceName = "zDPI";

        const string RepoUrl = "https://github.com/heFRKN/zDPI-TR";

        // Motordaki varsayilan alan adlariyla ayni olmali (zdpi.ps1, $DefaultDomains).
        static readonly string[] DefaultSites = {
            "discord.com", "discord.gg", "discordapp.com", "discordapp.net",
            "discord.media", "discordcdn.com", "discordstatus.com"
        };
        static readonly Regex DomainRx = new Regex(
            @"^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$", RegexOptions.CultureInvariant);

        static readonly Brush Green = Freeze(new SolidColorBrush(Color.FromRgb(0x32, 0xD7, 0x4B)));
        static readonly Brush Amber = Freeze(new SolidColorBrush(Color.FromRgb(0xFF, 0xD6, 0x0A)));
        static readonly Brush Gray = Freeze(new SolidColorBrush(Color.FromRgb(0x8E, 0x8E, 0x93)));
        static readonly Brush Soft = Freeze(new SolidColorBrush(Color.FromRgb(0xA1, 0xA1, 0xA6)));
        static readonly Brush Error = Freeze(new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x81)));

        public readonly Window Window;
        readonly string script, installDir, listFile, dnsMarker;
        readonly List<string> userSites = new List<string>();
        readonly ObservableCollection<SiteItem> sites = new ObservableCollection<SiteItem>();

        Button primaryBtn, secondaryBtn, addBtn, saveBtn;
        TextBlock statusTitle, statusSub, notice, hint, placeholder, sitesCaption;
        TextBlock infoService, infoOneShot, infoSites, infoDns;
        Ellipse dot;
        Path spinner;
        RotateTransform spinRotate;
        Border tint, segThumb;
        Grid segHost;
        TranslateTransform segTx;
        Button[] tabs;
        FrameworkElement[] panels;
        TextBox input;
        CheckBox dnsSwitch;

        int tab, savedCount;
        bool busy, rebootPending, svcInstalled, svcRunning, dnsOnDisk, listDirty, engineMissing;
        string busyTitle, busyStep, noticeText, preparedArgs;
        bool noticeIsError;
        Process oneShot;
        IntPtr job;

        // resume: surucu takildigi icin yeniden baslatildiysa kurulum acilista kendiliginden devam eder
        public Shell(bool resume)
        {
            string root = AppDomain.CurrentDomain.BaseDirectory;
            script = System.IO.Path.Combine(root, @"core\zdpi.ps1");
            installDir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "zDPI");
            listFile = System.IO.Path.Combine(installDir, "liste.txt");
            dnsMarker = System.IO.Path.Combine(installDir, "dns_degisti.txt");
            engineMissing = !File.Exists(script);

            using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("ui.xaml"))
                Window = (Window)XamlReader.Load(s);

            primaryBtn = Find<Button>("PrimaryBtn");
            secondaryBtn = Find<Button>("SecondaryBtn");
            addBtn = Find<Button>("AddBtn");
            saveBtn = Find<Button>("SaveBtn");
            statusTitle = Find<TextBlock>("StatusTitle");
            statusSub = Find<TextBlock>("StatusSub");
            notice = Find<TextBlock>("Notice");
            hint = Find<TextBlock>("Hint");
            placeholder = Find<TextBlock>("Placeholder");
            sitesCaption = Find<TextBlock>("SitesCaption");
            infoService = Find<TextBlock>("InfoService");
            infoOneShot = Find<TextBlock>("InfoOneShot");
            infoSites = Find<TextBlock>("InfoSites");
            infoDns = Find<TextBlock>("InfoDns");
            dot = Find<Ellipse>("Dot");
            spinner = Find<Path>("Spinner");
            spinRotate = Find<RotateTransform>("SpinRotate");
            tint = Find<Border>("Tint");
            segThumb = Find<Border>("SegThumb");
            segHost = Find<Grid>("SegHost");
            segTx = Find<TranslateTransform>("SegTx");
            tabs = new[] { Find<Button>("Tab0"), Find<Button>("Tab1"), Find<Button>("Tab2") };
            panels = new[] { Find<FrameworkElement>("StatusTab"), Find<FrameworkElement>("SitesTab"), Find<FrameworkElement>("HelpTab") };
            input = Find<TextBox>("Input");
            dnsSwitch = Find<CheckBox>("DnsSwitch");
            Find<Run>("Version").Text = "zDPI " + Version + "  ·  by FRKN  ·  MIT lisansı";
            // Tarayici yonetici olarak acilmasin diye link explorer uzerinden (normal kullanici) acilir
            Find<Hyperlink>("SourceLink").Click += delegate { Process.Start("explorer.exe", RepoUrl); };
            Find<ItemsControl>("SiteList").ItemsSource = sites;

            Find<Button>("CloseBtn").Click += delegate { Window.Close(); };
            Find<Button>("MinBtn").Click += delegate { Window.WindowState = WindowState.Minimized; };
            primaryBtn.Click += delegate { OnPrimary(); };
            secondaryBtn.Click += delegate { OnSecondary(); };
            for (int i = 0; i < tabs.Length; i++)
            {
                int n = i;
                tabs[i].Click += delegate { SelectTab(n); };
            }
            segHost.SizeChanged += delegate
            {
                segThumb.Width = segHost.ActualWidth / tabs.Length;
                segTx.BeginAnimation(TranslateTransform.XProperty, null);
                segTx.X = tab * segThumb.Width;
            };
            addBtn.Click += delegate { AddSite(); };
            saveBtn.Click += delegate { SaveList(); };
            dnsSwitch.Click += delegate { Render(); };
            input.TextChanged += delegate { placeholder.Visibility = input.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed; };
            input.KeyDown += (s, e) => { if (e.Key == Key.Enter) AddSite(); };
            Find<ItemsControl>("SiteList").AddHandler(ButtonBase.ClickEvent, new RoutedEventHandler(OnSiteClick));

            Window.MouseLeftButtonDown += delegate { try { Window.DragMove(); } catch (InvalidOperationException) { } };
            Window.SourceInitialized += delegate { ApplyBackdrop(); };
            Window.Activated += delegate { if (!busy) Refresh(); };
            Window.StateChanged += delegate { if (Window.WindowState == WindowState.Minimized) Native.Trim(); };
            Window.ContentRendered += delegate
            {
                if (resume && !engineMissing && !busy) Install();
                Window.Dispatcher.BeginInvoke(new Action(Native.Trim), DispatcherPriority.ApplicationIdle);
            };
            Window.Closing += delegate { if (oneShot != null) StopOneShot(true); };

            LoadSites();
            Refresh();
            dnsSwitch.IsChecked = dnsOnDisk;
            UpdateTabs();
        }

        T Find<T>(string name) where T : class { return (T)Window.FindName(name); }

        static Brush Freeze(Brush b) { b.Freeze(); return b; }

        // Windows 11'de pencere arkasi sistemin akrilik camiyla bulaniklasir; Windows 10'da duz koyu zemin kalir.
        void ApplyBackdrop()
        {
            IntPtr hwnd = new WindowInteropHelper(Window).Handle;
            int on = 1, round = 2, border = 0x00383838;
            Native.DwmSetWindowAttribute(hwnd, 20, ref on, 4);       // koyu cerceve
            Native.DwmSetWindowAttribute(hwnd, 33, ref round, 4);    // yuvarlak koseler
            Native.DwmSetWindowAttribute(hwnd, 34, ref border, 4);   // ince kenar rengi
            if (Native.OsBuild() < 22621) return;

            HwndSource.FromHwnd(hwnd).CompositionTarget.BackgroundColor = Colors.Transparent;
            Window.Background = Brushes.Transparent;
            var m = new Native.Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            Native.DwmExtendFrameIntoClientArea(hwnd, ref m);
            int acrylic = 3;
            Native.DwmSetWindowAttribute(hwnd, 38, ref acrylic, 4);
            tint.Background = Freeze(new SolidColorBrush(Color.FromArgb(0x66, 0x14, 0x14, 0x16)));
        }

        // ------------------------------------------------------------ durum

        bool OneShotRunning { get { return oneShot != null; } }

        void Refresh()
        {
            svcInstalled = svcRunning = false;
            try
            {
                using (var sc = new ServiceController(ServiceName))
                {
                    var st = sc.Status;
                    svcInstalled = true;
                    svcRunning = st == ServiceControllerStatus.Running || st == ServiceControllerStatus.StartPending;
                }
            }
            catch (InvalidOperationException) { }
            dnsOnDisk = File.Exists(dnsMarker);
            Render();
        }

        void Render()
        {
            string title, sub;
            Brush dotBrush = Gray;
            if (engineMissing)
            {
                // Zip icinden acilinca Windows yalnizca exe'yi cikarir, core klasoru gelmez
                title = "Zip'i çıkartın";
                sub = "core klasörü bulunamadı. Zip'e sağ tıklayıp \"Tümünü ayıkla\" deyin, zDPI.exe'yi çıkan klasörden açın.";
            }
            else if (busy) { title = busyTitle; sub = busyStep; }
            else if (OneShotRunning) { title = "Açık"; sub = "Tek seferlik mod, tüm sitelerde"; dotBrush = Green; }
            else if (svcRunning) { title = "Açık"; sub = "Hizmet arka planda çalışıyor"; dotBrush = Green; }
            else if (svcInstalled) { title = "Durdu"; sub = "Hizmet kurulu ama çalışmıyor"; dotBrush = Amber; }
            else { title = "Kapalı"; sub = "Henüz kurulmadı"; }

            statusTitle.Text = title;
            statusSub.Text = sub;
            dot.Fill = dotBrush;
            SetSpinner(busy);

            notice.Visibility = string.IsNullOrEmpty(noticeText) ? Visibility.Collapsed : Visibility.Visible;
            notice.Text = noticeText;
            notice.Foreground = noticeIsError ? Error : Soft;

            infoService.Text = !svcInstalled ? "Kurulu değil" : svcRunning ? "Çalışıyor" : OneShotRunning ? "Duraklatıldı" : "Durdu";
            infoOneShot.Text = OneShotRunning ? "Açık" : "Kapalı";
            infoSites.Text = savedCount + " site";
            infoDns.Text = dnsOnDisk ? "Açık" : "Kapalı";

            if (rebootPending) SetButton(primaryBtn, "Yeniden başlat", true);
            else if (svcInstalled) SetButton(primaryBtn, "Hizmeti kaldır", false);
            else SetButton(primaryBtn, "Hizmeti kur", true);
            secondaryBtn.Content = OneShotRunning ? "Tek seferlik modu durdur" : "Tek seferlik başlat";

            if (rebootPending) hint.Text = "Bilgisayar yeniden başladıktan sonra kurulum kendiliğinden devam eder.";
            else if (OneShotRunning) hint.Text = "Tek seferlik mod bu pencere kapanınca durur; kurulu hizmet varsa kaldığı yerden devam eder.";
            else if (svcInstalled) hint.Text = "Hizmet her açılışta kendiliğinden başlar. Kaldırırsanız site listeniz saklanır.";
            else hint.Text = "Hizmet bir kez kurulur ve her açılışta kendiliğinden başlar. Tek seferlik mod yalnızca bu pencere açıkken çalışır.";

            if (svcRunning) sitesCaption.Text = "Hizmet çalışıyor. Kaydettiğinizde yeni listeyle hemen yeniden başlar, yeniden kurmanız gerekmez.";
            else if (svcInstalled && OneShotRunning) sitesCaption.Text = "Tek seferlik mod açık. Kaydettiğiniz liste, tek seferlik mod kapanıp hizmet devam edince geçerli olur.";
            else if (svcInstalled) sitesCaption.Text = "Hizmet şu an çalışmıyor. Başladığında bu liste kullanılır.";
            else sitesCaption.Text = "Hizmet kurulduğunda bu liste kullanılır. Alt adresler otomatik dahildir.";

            bool idle = !busy && !engineMissing;
            primaryBtn.IsEnabled = idle;
            secondaryBtn.IsEnabled = idle && !rebootPending;
            saveBtn.IsEnabled = idle && (listDirty || dnsSwitch.IsChecked != dnsOnDisk);
        }

        void SetButton(Button b, string title, bool primary)
        {
            b.Content = title;
            b.Style = (Style)Window.Resources[primary ? "PrimaryButton" : "GlassButton"];
        }

        // Donen animasyon yalnizca islem surerken calisir; bosta CPU kullanimi sifirdir.
        void SetSpinner(bool on)
        {
            if (on == (spinner.Visibility == Visibility.Visible)) return;
            spinner.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            dot.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
            if (on)
            {
                var a = new DoubleAnimation(0, 360, TimeSpan.FromSeconds(0.9)) { RepeatBehavior = RepeatBehavior.Forever };
                Timeline.SetDesiredFrameRate(a, 30);
                spinRotate.BeginAnimation(RotateTransform.AngleProperty, a);
            }
            else spinRotate.BeginAnimation(RotateTransform.AngleProperty, null);
        }

        void ShowNotice(string text, bool error)
        {
            noticeText = text;
            noticeIsError = error;
        }

        // ------------------------------------------------------------ motor

        void RunEngine(string args, string title, Action done)
        {
            busy = true;
            busyTitle = title;
            busyStep = "Hazırlanıyor";
            noticeText = null;
            Render();

            var psi = new ProcessStartInfo(
                System.IO.Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"),
                "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\" " + args + " -Gui");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardInput = true;

            Process p;
            try { p = Process.Start(psi); }
            catch (Exception)
            {
                busy = false;
                ShowNotice("Motor başlatılamadı.", true);
                Render();
                return;
            }
            p.StandardInput.Close();
            p.OutputDataReceived += (s, e) =>
            {
                if (e.Data == null || !e.Data.StartsWith("##", StringComparison.Ordinal)) return;
                string m = e.Data.Substring(2).Trim();
                Window.Dispatcher.BeginInvoke(new Action(() => OnMarker(m)));
            };
            p.ErrorDataReceived += delegate { };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();

            ThreadPool.QueueUserWorkItem(delegate
            {
                p.WaitForExit();
                p.Dispose();
                Window.Dispatcher.BeginInvoke(new Action(() =>
                {
                    busy = false;
                    Refresh();
                    if (done != null) done();
                    Render();
                    Native.Trim();
                }));
            });
        }

        void OnMarker(string m)
        {
            if (m.StartsWith("try ", StringComparison.Ordinal)) busyStep = "Yöntem deneniyor · " + m.Substring(4);
            else if (m.StartsWith("args ", StringComparison.Ordinal)) preparedArgs = m.Substring(5);
            else switch (m)
            {
                case "step clean":   busyStep = "Çakışan uygulamalar kapatılıyor"; break;
                case "step files":   busyStep = "Dosyalar doğrulanıyor"; break;
                case "step dns":     busyStep = "DNS kontrol ediliyor"; break;
                case "step search":  busyStep = "Çalışan yöntem aranıyor"; break;
                case "step service": busyStep = "Hizmet kuruluyor"; break;
                case "step check":   busyStep = "Bağlantı test ediliyor"; break;
                case "step list":    busyStep = "Liste kaydediliyor"; break;
                case "reboot":
                    rebootPending = true;
                    ShowNotice("Ağ sürücüsü takılı kaldı. Bilgisayarı yeniden başlatın, kurulum açılışta devam eder.", true);
                    break;
                case "integrity": ShowNotice("Dosyalar doğrulanamadı. Paketi yeniden indirin.", true); break;
                case "nomethod":  ShowNotice("Çalışan yöntem bulunamadı. Açık VPN veya benzeri uygulamaları kapatıp tekrar deneyin.", true); break;
                case "untested":  ShowNotice("Hizmet kuruldu, ancak bağlantı testi geçmedi.", true); break;
                case "svcfail":   ShowNotice("Hizmet başlatılamadı.", true); break;
                case "fail":      ShowNotice("İşlem tamamlanamadı.", true); break;
            }
            Render();
        }

        // ------------------------------------------------------------ eylemler

        void OnPrimary()
        {
            if (busy) return;
            if (rebootPending)
            {
                Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 3") { UseShellExecute = false, CreateNoWindow = true });
                return;
            }
            if (svcInstalled)
            {
                RunEngine("-Action uninstall", "Kaldırılıyor", () =>
                {
                    if (!svcInstalled) ShowNotice("Hizmet kaldırıldı.", false);
                });
                return;
            }
            Install();
        }

        void Install()
        {
            if (OneShotRunning) StopOneShot(false);
            RunEngine("-Action install", "Kuruluyor", () =>
            {
                if (noticeText != null) return;
                if (svcRunning) ShowNotice("Hizmet kuruldu, açılışta otomatik başlar.", false);
                else ShowNotice("Kurulum tamamlanamadı.", true);
            });
        }

        void OnSecondary()
        {
            if (busy) return;
            if (OneShotRunning)
            {
                StopOneShot(true);
                ShowNotice("Tek seferlik mod kapatıldı.", false);
                Refresh();
                return;
            }
            preparedArgs = null;
            RunEngine("-Action prepare", "Başlatılıyor", () =>
            {
                if (preparedArgs != null) LaunchOneShot(preparedArgs);
                else if (noticeText == null) ShowNotice("Başlatılamadı.", true);
            });
        }

        void LaunchOneShot(string args)
        {
            var psi = new ProcessStartInfo(System.IO.Path.Combine(installDir, "winws.exe"), args);
            psi.WorkingDirectory = installDir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process p;
            try { p = Process.Start(psi); }
            catch (Exception)
            {
                ShowNotice("Başlatılamadı.", true);
                return;
            }
            job = Native.CreateKillOnCloseJob(p.Handle);
            oneShot = p;
            p.EnableRaisingEvents = true;
            p.Exited += delegate
            {
                Window.Dispatcher.BeginInvoke(new Action(() =>
                {
                    // StopOneShot ile kapatildiysa oneShot zaten bos ya da baska bir surec.
                    if (oneShot != p) return;
                    ReleaseOneShot();
                    if (!busy) ShowNotice("Tek seferlik mod beklenmedik şekilde kapandı.", true);
                    Refresh();
                }));
            };
        }

        void StopOneShot(bool resumeService)
        {
            Process p = oneShot;
            oneShot = null;
            if (job != IntPtr.Zero) { Native.CloseHandle(job); job = IntPtr.Zero; }
            else try { p.Kill(); } catch (Exception) { }
            try { p.WaitForExit(3000); } catch (Exception) { }
            p.Dispose();
            if (!resumeService) return;
            // Tek seferlik mod kurulu hizmeti durdurmustu; kaldigi yerden devam etsin.
            try
            {
                using (var sc = new ServiceController(ServiceName))
                    if (sc.StartType == ServiceStartMode.Automatic && sc.Status == ServiceControllerStatus.Stopped) sc.Start();
            }
            catch (Exception) { }
        }

        void ReleaseOneShot()
        {
            if (job != IntPtr.Zero) { Native.CloseHandle(job); job = IntPtr.Zero; }
            if (oneShot != null) { oneShot.Dispose(); oneShot = null; }
        }

        // ------------------------------------------------------------ site listesi

        void LoadSites()
        {
            userSites.Clear();
            listDirty = false;
            try
            {
                if (File.Exists(listFile))
                    foreach (string line in File.ReadAllLines(listFile))
                    {
                        string d = line.Trim().ToLowerInvariant();
                        if (DomainRx.IsMatch(d) && Array.IndexOf(DefaultSites, d) < 0 && !userSites.Contains(d)) userSites.Add(d);
                    }
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
            savedCount = userSites.Count + DefaultSites.Length;
            RebuildSites();
        }

        void RebuildSites()
        {
            sites.Clear();
            foreach (string d in userSites) sites.Add(new SiteItem { Name = d, Display = ToUnicode(d), First = sites.Count == 0 });
            foreach (string d in DefaultSites) sites.Add(new SiteItem { Name = d, Display = d, Locked = true, First = sites.Count == 0 });
        }

        // Listede "xn--rnek-zha3y.com" yerine "örnek.com" gosterilir; dosyaya ASCII yazilir.
        static string ToUnicode(string d)
        {
            try { return new IdnMapping().GetUnicode(d); }
            catch (ArgumentException) { return d; }
        }

        // "https://www.site.com/yol" gibi girisleri "site.com" bicimine indirir.
        static string NormalizeDomain(string raw)
        {
            string s = raw.Trim().ToLowerInvariant();
            int i = s.IndexOf("://", StringComparison.Ordinal);
            if (i >= 0) s = s.Substring(i + 3);
            i = s.IndexOfAny(new[] { '/', '?', '#' });
            if (i >= 0) s = s.Substring(0, i);
            i = s.LastIndexOf('@');
            if (i >= 0) s = s.Substring(i + 1);
            i = s.IndexOf(':');
            if (i >= 0) s = s.Substring(0, i);
            s = s.Trim('.');
            if (s.StartsWith("*.", StringComparison.Ordinal)) s = s.Substring(2);
            if (s.StartsWith("www.", StringComparison.Ordinal)) s = s.Substring(4);
            try { s = new IdnMapping().GetAscii(s); }
            catch (ArgumentException) { return null; }
            return DomainRx.IsMatch(s) ? s : null;
        }

        void AddSite()
        {
            if (input.Text.Trim().Length == 0) return;
            string d = NormalizeDomain(input.Text);
            if (d == null) { FlashInput("Geçerli bir adres yazın"); return; }
            if (userSites.Contains(d) || Array.IndexOf(DefaultSites, d) >= 0) { FlashInput("Zaten listede"); return; }
            userSites.Insert(0, d);
            RebuildSites();
            input.Clear();
            listDirty = true;
            Render();
        }

        void FlashInput(string message)
        {
            input.Clear();
            placeholder.Text = message;
            placeholder.Foreground = Error;
            var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1.8) };
            t.Tick += delegate
            {
                t.Stop();
                placeholder.Text = "site.com";
                placeholder.Foreground = (Brush)Window.Resources["Text3"];
            };
            t.Start();
        }

        void OnSiteClick(object sender, RoutedEventArgs e)
        {
            var b = e.OriginalSource as Button;
            var item = b == null ? null : b.DataContext as SiteItem;
            if (item == null || item.Locked) return;
            userSites.Remove(item.Name);
            RebuildSites();
            listDirty = true;
            Render();
        }

        void SaveList()
        {
            if (busy) return;
            string args = "-Action list -Domains \"" + (userSites.Count > 0 ? string.Join(",", userSites) : "none") + "\"";
            bool dnsWanted = dnsSwitch.IsChecked == true;
            if (dnsWanted != dnsOnDisk) args += " -Dns " + (dnsWanted ? "on" : "off");
            SelectTab(0);
            RunEngine(args, "Uygulanıyor", () =>
            {
                LoadSites();
                dnsSwitch.IsChecked = dnsOnDisk;
                if (noticeText != null) return;
                if (svcRunning) ShowNotice("Liste uygulandı, hizmet yeni listeyle çalışıyor.", false);
                else if (svcInstalled && OneShotRunning) ShowNotice("Liste kaydedildi, tek seferlik mod kapanınca geçerli olur.", false);
                else if (svcInstalled) ShowNotice("Liste kaydedildi.", false);
                else ShowNotice("Liste kaydedildi, hizmet kurulunca geçerli olur.", false);
            });
        }

        // ------------------------------------------------------------ sekmeler

        void SelectTab(int n)
        {
            if (n == tab) return;
            panels[tab].Visibility = Visibility.Collapsed;
            var p = panels[n];
            p.Visibility = Visibility.Visible;
            var tx = new TranslateTransform();
            p.RenderTransform = tx;
            Animate(p, UIElement.OpacityProperty, 0, 1, 200);
            Animate(tx, TranslateTransform.YProperty, 6, 0, 240);
            Animate(segTx, TranslateTransform.XProperty, segTx.X, n * segThumb.Width, 260);
            tab = n;
            UpdateTabs();

            if (n == 1)
            {
                // Kaydedilmemis degisiklik yoksa listeyi diskten tazele
                if (!listDirty && !busy) { LoadSites(); dnsSwitch.IsChecked = dnsOnDisk; Render(); }
                input.Focus();
            }
            else Keyboard.ClearFocus();
        }

        void UpdateTabs()
        {
            for (int i = 0; i < tabs.Length; i++)
            {
                tabs[i].Foreground = i == tab ? Brushes.White : Soft;
                tabs[i].FontWeight = i == tab ? FontWeights.SemiBold : FontWeights.Normal;
            }
        }

        static DoubleAnimation Animate(IAnimatable target, DependencyProperty prop, double from, double to, int ms)
        {
            var a = new DoubleAnimation(from, to, TimeSpan.FromMilliseconds(ms))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            target.BeginAnimation(prop, a);
            return a;
        }
    }

    static class Program
    {
        [STAThread]
        static void Main(string[] args)
        {
            bool created;
            using (new Mutex(true, @"Local\zDPI.Gui", out created))
            {
                if (!created)
                {
                    IntPtr h = Native.FindWindow(null, "zDPI");
                    if (h != IntPtr.Zero) { Native.ShowWindow(h, 9); Native.SetForegroundWindow(h); }
                    return;
                }
                // Arayuz statik; GPU yerine yazilimla cizmek bellek kullanimini yaklasik yariya indirir.
                // Cam efekti DWM'de cizildigi icin bundan etkilenmez.
                RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;
                var app = new Application { ShutdownMode = ShutdownMode.OnMainWindowClose };
                var shell = new Shell(Array.IndexOf(args, "--resume") >= 0);
                app.Run(shell.Window);
            }
        }
    }
}
