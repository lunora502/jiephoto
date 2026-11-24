using System;
using System.Runtime.InteropServices;
using System.Windows.Input;

namespace JieDraw;

/// <summary>
/// 全局热键：RegisterHotKey / UnregisterHotKey（OS 级注册，不轮询）。
/// 热键字符串格式："Alt+Q"、"Ctrl+Shift+D"、"Win+F2"。
/// 修饰键：Alt / Ctrl / Shift / Win；主键：WPF Key 枚举名（Q、D1、F2、Space…）。
/// </summary>
public static class HotkeyService
{
    public const int WmHotkey = 0x0312;   // WM_HOTKEY
    public const int Id = 1;              // 本应用只注册一个热键

    private const uint ModAlt = 0x1;
    private const uint ModControl = 0x2;
    private const uint ModShift = 0x4;
    private const uint ModWin = 0x8;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static bool TryRegister(IntPtr hwnd, string spec, out string error)
    {
        error = string.Empty;
        if (!TryParse(spec, out var mods, out var vk))
        {
            error = $"无法解析热键 \"{spec}\"（格式：Alt+Q / Ctrl+Shift+D / Win+F2）";
            return false;
        }
        if (!RegisterHotKey(hwnd, Id, mods, vk))
        {
            error = $"热键 {spec} 注册失败（可能被其他程序占用）";
            return false;
        }
        return true;
    }

    public static void Unregister(IntPtr hwnd) => UnregisterHotKey(hwnd, Id);

    public static bool TryParse(string spec, out uint mods, out uint vk)
    {
        mods = 0;
        vk = 0;
        var parts = spec.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0) return false;

        for (int i = 0; i < parts.Length - 1; i++)
        {
            switch (parts[i].ToLowerInvariant())
            {
                case "alt": mods |= ModAlt; break;
                case "ctrl":
                case "control": mods |= ModControl; break;
                case "shift": mods |= ModShift; break;
                case "win": mods |= ModWin; break;
                default: return false;
            }
        }

        if (!Enum.TryParse<Key>(parts[^1], ignoreCase: true, out var key)) return false;
        vk = (uint)KeyInterop.VirtualKeyFromKey(key);
        return vk != 0;
    }
}
