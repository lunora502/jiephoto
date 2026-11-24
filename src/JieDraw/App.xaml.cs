using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using System.Windows.Forms;

namespace JieDraw;

/// <summary>
/// 应用生命周期：单实例 → 预创建主窗口（注册热键）→ 托盘常驻。
/// 退出只走托盘菜单，保证窗口 Hide 不杀进程。
/// </summary>
public partial class App : System.Windows.Application
{
    private Mutex? _singleInstance;
    private EventWaitHandle? _activateEvent;
    private RegisteredWaitHandle? _activateWait;
    private MainWindow _main = null!;
    private NotifyIcon _tray = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        _singleInstance = new Mutex(initiallyOwned: true, @"Local\JieDraw.Instance", out var isNew);
        if (!isNew)
        {
            // 已有实例在跑：通过命名事件把它唤起到前台，然后自己退出
            try
            {
                using var evt = EventWaitHandle.OpenExisting(@"Local\JieDraw.Activate");
                evt.Set();
                AppLog.Log("second instance -> activated existing");
            }
            catch { }
            Shutdown();
            return;
        }
        _activateEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\JieDraw.Activate");

        base.OnStartup(e);

        DispatcherUnhandledException += (_, args) =>
        {
            AppLog.Log("UNHANDLED: " + args.Exception);
            args.Handled = true; // 常驻应用不崩，异常落日志
        };

        var settings = SettingsStore.Load();

        // 预创建窗口：Show()+Hide() 同帧完成 —— SourceInitialized 走完整创建流程，
        // 热键/消息钩子挂接可靠；ShowInTaskbar=False 且未渲染即隐藏，启动无闪烁
        _main = new MainWindow(settings);
        _main.Show();
        _main.Hide();

        InitTray(settings.Hotkey);
        if (_main.HotkeyConfigured && !_main.HotkeyRegistered)
        {
            _tray.BalloonTipTitle = "捷画 JieDraw";
            _tray.BalloonTipText = $"热键 {settings.Hotkey} 注册失败（可能被占用）。" +
                                   "可点击托盘菜单「设置…」更换热键。";
            _tray.ShowBalloonTip(5000);
        }

        WatchActivate();
        Dispatcher.InvokeAsync(() =>
        {
            CheckUpdateAsync(settings.UpdateUrl);
            AutoStartHelper.EnsureCurrentPath();
            if (settings.WakeHotkey) WakeShortcutHelper.Ensure(settings.Hotkey);
        }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        AppLog.Log($"startup ok, hotkey={settings.Hotkey}");

        // /show 参数（来自快捷键唤醒的 .lnk）：冷启动直接弹画板而非仅驻托盘
        if (e.Args.Contains("/show", StringComparer.OrdinalIgnoreCase))
            Dispatcher.BeginInvoke(() => { try { _main.ShowCanvas(); } catch { } });
    }

    /// <summary>后台线程等待激活事件（二次启动时由新实例触发）。</summary>
    private void WatchActivate()
    {
        _activateWait = ThreadPool.RegisterWaitForSingleObject(_activateEvent!, (_, _) =>
        {
            Dispatcher.BeginInvoke(() => _main.ShowCanvas());
        }, null, Timeout.Infinite, executeOnlyOnce: false);
    }

    /// <summary>
    /// 更新检查（客户端机制）：UpdateUrl 支持 http(s):// 与 file://（离线可测）。
    /// 返回 {"Version":"x.y.z","Url":"..."}；Version 大于当前 → 托盘气泡提示。静默失败不打扰。
    /// </summary>
    private void CheckUpdateAsync(string updateUrl)
    {
        if (string.IsNullOrWhiteSpace(updateUrl)) return;
        Task.Run(() =>
        {
            try
            {
                string json;
                if (updateUrl.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
                    json = File.ReadAllText(new Uri(updateUrl).LocalPath);
                else
                {
                    using var http = new System.Net.Http.HttpClient { Timeout = TimeSpan.FromSeconds(5) };
                    json = http.GetStringAsync(updateUrl).GetAwaiter().GetResult();
                }
                var doc = System.Text.Json.JsonDocument.Parse(json);
                var ver = doc.RootElement.GetProperty("Version").GetString();
                var url = doc.RootElement.TryGetProperty("Url", out var u) ? u.GetString() ?? "" : "";
                var cur = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version;
                if (ver is not null && cur is not null && new Version(ver) > cur)
                {
                    AppLog.Log($"update available: {ver} (current {cur}) -> {url}");
                    Dispatcher.BeginInvoke(() =>
                    {
                        _tray.BalloonTipTitle = "捷画 JieDraw";
                        _tray.BalloonTipText = $"发现新版本 {ver}（当前 {cur.ToString(3)}）。下载地址：{url}";
                        _tray.ShowBalloonTip(6000);
                    });
                }
                else
                {
                    AppLog.Log("update check: up to date");
                }
            }
            catch (Exception ex)
            {
                AppLog.Log("update check failed: " + ex.Message);
            }
        });
    }

    private void InitTray(string hotkey)
    {
        _tray = new NotifyIcon
        {
            Icon = IconFactory.TrayIcon,
            Text = "捷画 JieDraw（" + hotkey + "）",
            Visible = true
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("打开画板（" + hotkey + "）", null, (_, _) => Toggle());
        menu.Items.Add("屏幕批注", null, (_, _) => OpenAnnotate());
        menu.Items.Add("设置…", null, (_, _) => OpenSettings());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Shutdown());

        _tray.ContextMenuStrip = menu;
        // 左键单击 = 显示/隐藏画板（Windows 惯例）；右键 = 菜单。
        // 不再挂 DoubleClick：单击已切换，双击会触发两次互相抵消
        _tray.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) Toggle();
        };
    }

    /// <summary>托盘屏幕批注入口。</summary>
    private void OpenAnnotate() => Dispatcher.BeginInvoke(() =>
    {
        try
        {
            if (_main.IsVisible) _main.Hide();
            new AnnotateWindow().Show();
        }
        catch (Exception ex) { AppLog.Log("annotate open failed: " + ex); }
    });

    /// <summary>托盘菜单设置入口：唤起画板并打开设置窗口。</summary>
    private void OpenSettings() => Dispatcher.BeginInvoke(() =>
    {
        if (!_main.IsVisible) _main.ToggleFromHotkey();
        _main.OpenSettingsUi();
    });

    /// <summary>热键变更后刷新托盘提示与菜单文案（空串 = 已停用热键）。</summary>
    public void RefreshTrayText(string hotkey)
    {
        _tray.Text = string.IsNullOrEmpty(hotkey) ? "捷画 JieDraw（热键已停用）" : "捷画 JieDraw（" + hotkey + "）";
        if (_tray.ContextMenuStrip?.Items.Count > 0 && _tray.ContextMenuStrip.Items[0] is ToolStripMenuItem openItem)
            openItem.Text = string.IsNullOrEmpty(hotkey) ? "打开画板" : "打开画板（" + hotkey + "）";
    }

    private void Toggle() => Dispatcher.BeginInvoke(() => _main.ToggleFromHotkey());

    protected override void OnExit(ExitEventArgs e)
    {
        // 统一退出清理：无论从托盘「退出」还是画布 ✕ 触发 Shutdown 都走这里
        // （单实例互斥退出的路径上 _main/_tray 尚未创建，需判空）
        try
        {
            if (_tray is not null) { _tray.Visible = false; _tray.Dispose(); }
            _main?.ShutdownCleanup();
        }
        catch
        {
            // 退出路径尽力清理
        }
        _singleInstance?.Dispose();
        _activateWait?.Unregister(null);
        _activateEvent?.Dispose();
        base.OnExit(e);
    }
}
