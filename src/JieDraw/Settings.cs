using System;
using System.IO;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace JieDraw;

/// <summary>应用设置（%APPDATA%\JieDraw\settings.json）。</summary>
public sealed class AppSettings
{
    public string Hotkey { get; set; } = "Alt+Q";
    public string PenColor { get; set; } = "#1A1A1A";
    public int PenSize { get; set; } = 4;
    public bool Topmost { get; set; } = true;
    /// <summary>导出目录；空 = 默认 图片\JieDraw\。</summary>
    public string SaveDir { get; set; } = "";

    /// <summary>导出 PNG 是否透明背景（无选中复制/保存时生效）。</summary>
    public bool TransparentExport { get; set; } = false;

    /// <summary>更新检查地址；空 = 不检查。支持 http(s):// 与 file://。</summary>
    public string UpdateUrl { get; set; } = "";

    /// <summary>快捷键唤醒：开始菜单 .lnk 热键（Ctrl+Alt+Q），未运行时按下由系统启动。
    /// 默认开——配合"开机自启默认关"，实现不占后台也能快捷键唤起。</summary>
    public bool WakeHotkey { get; set; } = true;

    // 窗口几何记忆（WPF 逻辑单位；null = 从未保存，走居中）
    public double? WinLeft { get; set; }
    public double? WinTop { get; set; }
    public double? WinWidth { get; set; }
    public double? WinHeight { get; set; }
    public bool WinMaximized { get; set; }
}

public static class SettingsStore
{
    public static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "JieDraw");

    private static string FilePath => Path.Combine(Dir, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var s = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath));
                if (s is not null) return s;
            }
        }
        catch
        {
            // 设置损坏时回落默认值
        }
        return new AppSettings();
    }

    public static void Save(AppSettings s)
    {
        try
        {
            Directory.CreateDirectory(Dir);
            // 宽松编码：+ 号等不被转义成 \uXXXX，保持文件人类可读、可直接手改
            var opts = new JsonSerializerOptions
            {
                WriteIndented = true,
                Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
            };
            File.WriteAllText(FilePath, JsonSerializer.Serialize(s, opts));
        }
        catch
        {
            // 写失败不打断交互，下次修改再写
        }
    }
}
