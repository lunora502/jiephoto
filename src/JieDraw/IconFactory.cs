using System;
using System.Drawing;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media.Imaging;

namespace JieDraw;

/// <summary>
/// 图标：统一取自 Assets/icon.ico（exe 图标同源）。pack:// 加载失败时回落到运行时绘制。
/// </summary>
public static class IconFactory
{
    private static Icon? _tray;
    private static BitmapSource? _window;

    public static Icon TrayIcon => _tray ??= CreateTrayIcon();
    public static BitmapSource WindowIcon => _window ??= CreateWindowIcon();

    private static Uri IconUri => new("pack://application:,,,/Assets/icon.ico");

    private static Icon CreateTrayIcon()
    {
        try
        {
            var st = System.Windows.Application.GetResourceStream(IconUri)!.Stream;
            return new Icon(st);
        }
        catch
        {
            return DrawFallbackIcon();
        }
    }

    private static BitmapSource CreateWindowIcon()
    {
        try
        {
            var bmp = new BitmapImage();
            bmp.BeginInit();
            bmp.UriSource = IconUri;
            bmp.CacheOption = BitmapCacheOption.OnLoad;
            bmp.EndInit();
            bmp.Freeze();
            return bmp;
        }
        catch
        {
            using var fallback = DrawFallbackIcon();
            var bs = Imaging.CreateBitmapSourceFromHBitmap(
                fallback.ToBitmap().GetHbitmap(), IntPtr.Zero, Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            bs.Freeze();
            return bs;
        }
    }

    /// <summary>兜底：深色圆底 + 白色涂鸦笔迹（与正式图标同设计语言的简化版）。</summary>
    private static Icon DrawFallbackIcon()
    {
        using var bmp = new System.Drawing.Bitmap(64, 64);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var bg = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 32, 33, 36));
            g.FillEllipse(bg, 2, 2, 60, 60);
            var pts = new[] {
                new System.Drawing.PointF(16, 44), new System.Drawing.PointF(26, 22),
                new System.Drawing.PointF(38, 40), new System.Drawing.PointF(48, 20) };
            using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 6f)
            {
                StartCap = System.Drawing.Drawing2D.LineCap.Round,
                EndCap = System.Drawing.Drawing2D.LineCap.Round,
                LineJoin = System.Drawing.Drawing2D.LineJoin.Round
            };
            g.DrawCurve(pen, pts);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
