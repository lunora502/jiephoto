using System;
using System.IO;

namespace JieDraw;

/// <summary>
/// 快捷键唤醒：利用开始菜单 .lnk 的"快捷键"属性（Explorer 全局注册，无需应用常驻）实现
/// "默认开机不自启、也能按快捷键唤起"——应用未运行时按 Ctrl+Alt+Q 由 Windows 启动捷画
/// （.lnk 带 /show 参数 → 启动即弹画板）；已运行时按它走二启激活逻辑唤出画板。
/// 注意：Explorer 对 .lnk 快捷键要求 Ctrl+Alt+X 组合，故独立于应用内热键（可任意组合）。
/// </summary>
internal static class WakeShortcutHelper
{
    private static string ShortcutPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.Programs),
        "捷画 JieDraw.lnk");

    private const string FallbackHotkey = "Ctrl+Alt+Q";

    /// <summary>应用内热键若已是 Ctrl+Alt+X 形式则复用同一组合，否则回落 Ctrl+Alt+Q。</summary>
    public static string DeriveHotkey(string? appHotkey)
    {
        if (!string.IsNullOrEmpty(appHotkey))
        {
            var parts = appHotkey.Split('+');
            if (parts.Length == 3
                && parts[0].Equals("Ctrl", StringComparison.OrdinalIgnoreCase)
                && parts[1].Equals("Alt", StringComparison.OrdinalIgnoreCase))
                return "Ctrl+Alt+" + parts[2].ToUpperInvariant();
        }
        return FallbackHotkey;
    }

    /// <summary>创建/更新开始菜单快捷方式（幂等，路径自愈：exe 挪位后下次启动自动修正）。</summary>
    public static void Ensure(string? appHotkey)
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            var shellType = Type.GetTypeFromProgID("WScript.Shell")!;
            dynamic shell = Activator.CreateInstance(shellType)!;
            dynamic sc = shell.CreateShortcut(ShortcutPath);
            sc.TargetPath = exe;
            sc.Arguments = "/show";                       // 冷启动直接弹画板，而非仅驻托盘
            sc.WorkingDirectory = Path.GetDirectoryName(exe)!;
            sc.Hotkey = DeriveHotkey(appHotkey);
            sc.IconLocation = exe + ",0";
            sc.Description = "捷画 JieDraw（快捷键唤醒）";
            sc.Save();
            AppLog.Log("wake shortcut ensured: " + ShortcutPath + " hotkey=" + DeriveHotkey(appHotkey));
        }
        catch (Exception ex)
        {
            AppLog.Log("wake shortcut ensure failed: " + ex.Message);
        }
    }

    public static void Remove()
    {
        try
        {
            if (File.Exists(ShortcutPath))
            {
                File.Delete(ShortcutPath);
                AppLog.Log("wake shortcut removed");
            }
        }
        catch (Exception ex)
        {
            AppLog.Log("wake shortcut remove failed: " + ex.Message);
        }
    }
}
