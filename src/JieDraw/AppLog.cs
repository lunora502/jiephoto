using System;
using System.IO;
using System.Linq;

namespace JieDraw;

/// <summary>轻量日志：%APPDATA%\JieDraw\trace.log（显隐耗时、异常堆栈）。
/// 超过 1MB 自动截尾保留最近 400 行，防止无限增长。</summary>
public static class AppLog
{
    private const long MaxBytes = 1024 * 1024;
    private const int KeepLines = 400;

    public static void Log(string msg)
    {
        try
        {
            Directory.CreateDirectory(SettingsStore.Dir);
            var path = Path.Combine(SettingsStore.Dir, "trace.log");
            RotateIfNeeded(path);
            File.AppendAllText(path, $"{DateTime.Now:HH:mm:ss.fff} {msg}\r\n");
        }
        catch
        {
            // 日志永不抛出
        }
    }

    private static void RotateIfNeeded(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (fi.Exists && fi.Length > MaxBytes)
            {
                var lines = File.ReadAllLines(path);
                File.WriteAllLines(path, lines.Skip(Math.Max(0, lines.Length - KeepLines)));
            }
        }
        catch
        {
            // 轮转失败不影响主流程
        }
    }
}
