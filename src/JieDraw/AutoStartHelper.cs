using System;
using Microsoft.Win32;

namespace JieDraw;

/// <summary>
/// 开机自启：HKCU\Software\Microsoft\Windows\CurrentVersion\Run 下写/删 JieDraw 项。
/// 开关状态以注册表为准（settings.json 不重复存，避免两处状态漂移）。
/// </summary>
internal static class AutoStartHelper
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "JieDraw";

    public static bool IsEnabled()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(ValueName) is string;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>自愈：已开启自启但注册表指向旧 exe 路径（如目录被移动）→ 启动时自动修正。</summary>
    public static void EnsureCurrentPath()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (k?.GetValue(ValueName) is not string v) return; // 未开启自启 → 不动
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            var cur = "\"" + exe + "\"";
            if (!string.Equals(v, cur, StringComparison.OrdinalIgnoreCase))
            {
                k.SetValue(ValueName, cur);
                AppLog.Log($"autostart path healed: {v} -> {cur}");
            }
        }
        catch (Exception ex)
        {
            AppLog.Log("autostart heal failed: " + ex.Message);
        }
    }

    public static void Set(bool enable)
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (k is null) return;
            if (enable)
            {
                var exe = Environment.ProcessPath;
                if (!string.IsNullOrEmpty(exe))
                    k.SetValue(ValueName, "\"" + exe + "\""); // 带引号防路径空格问题
            }
            else
            {
                k.DeleteValue(ValueName, throwOnMissingValue: false);
            }
            AppLog.Log("autostart " + (enable ? "enabled" : "disabled"));
        }
        catch (Exception ex)
        {
            AppLog.Log("autostart failed: " + ex.Message);
        }
    }
}
