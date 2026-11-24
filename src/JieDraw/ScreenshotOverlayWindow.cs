using System;
using System.Drawing;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Point = System.Windows.Point;
using Color = System.Windows.Media.Color;

namespace JieDraw;

/// <summary>
/// 截图覆盖层：主屏全屏置顶半透明变暗，拖出矩形后把该屏幕区域捕获为 Bitmap。
/// 捕获时把窗口 Opacity 置 0（不能用 Hide——模态会话会提前结束），等 DWM 合成后再截。
/// Esc 取消。MVP 范围：主显示器。
/// </summary>
public sealed class ScreenshotOverlayWindow : Window
{
    private readonly System.Windows.Shapes.Rectangle _rect;
    private Point? _start;
    private bool _finishing;

    public Bitmap? Captured { get; private set; }

    public ScreenshotOverlayWindow()
    {
        Title = "捷画 截图";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = new SolidColorBrush(Color.FromArgb(70, 0, 0, 0)); // 全屏变暗
        Cursor = Cursors.Cross;
        WindowStartupLocation = WindowStartupLocation.Manual;
        // Win32 虚拟屏坐标系以主屏左上角为原点 (0,0)，覆盖主屏即从 0,0 开始
        Left = 0;
        Top = 0;

        _rect = new System.Windows.Shapes.Rectangle
        {
            Stroke = new SolidColorBrush(Color.FromRgb(26, 115, 232)),
            StrokeThickness = 2,
            Fill = new SolidColorBrush(Color.FromArgb(40, 26, 115, 232)),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
            SnapsToDevicePixels = true
        };
        var hint = new TextBlock
        {
            Text = "拖出截图区域，松开即截；Esc 取消",
            Foreground = new SolidColorBrush(Color.FromRgb(232, 234, 237)),
            FontSize = 15,
            Margin = new Thickness(0, 26, 0, 0),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top
        };
        Content = new Grid { Children = { hint, _rect } };

        PreviewMouseLeftButtonDown += OnDown;
        PreviewMouseMove += OnMove;
        PreviewMouseLeftButtonUp += OnUp;
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { Captured = null; Close(); }
        };
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        if (_finishing) return;
        _start = e.GetPosition(this);
        UpdateRect(_start.Value, _start.Value);
        _rect.Visibility = Visibility.Visible;
        CaptureMouse();
        e.Handled = true;
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (_start is Point s) UpdateRect(s, e.GetPosition(this));
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (_start is null || _finishing) return;
        ReleaseMouseCapture();
        var rect = new Rect(_start.Value, e.GetPosition(this));
        _start = null;
        _rect.Visibility = Visibility.Collapsed;
        e.Handled = true;

        if (rect.Width < 5 || rect.Height < 5) { AppLog.Log($"screenshot: rect too small {rect.Width}x{rect.Height}"); Close(); return; }

        // 隐身（Opacity=0 保持模态会话），等 DWM 合成一帧后捕获，避免遮罩入镜
        _finishing = true;
        AppLog.Log($"screenshot: finishing rect={rect.Width:F0}x{rect.Height:F0}");
        Opacity = 0;
        IsHitTestVisible = false;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            System.Threading.Thread.Sleep(300); // 给 DWM 合成时间
            try
            {
                Captured = CaptureScreenRect(rect);
                AppLog.Log($"screenshot: captured {Captured.Width}x{Captured.Height}");
            }
            catch (Exception ex)
            {
                AppLog.Log("screenshot capture failed: " + ex);
                Captured = null;
            }
            Close();
        });
    }

    private void UpdateRect(Point a, Point b)
    {
        var r = new Rect(a, b);
        _rect.Margin = new Thickness(r.X, r.Y, 0, 0);
        _rect.Width = Math.Max(1, r.Width);
        _rect.Height = Math.Max(1, r.Height);
    }

    private Bitmap CaptureScreenRect(Rect dipRect)
    {
        var m = PresentationSource.FromVisual(this)!.CompositionTarget!.TransformToDevice;
        var x = (int)Math.Round((Left + dipRect.X) * m.M11);
        var y = (int)Math.Round((Top + dipRect.Y) * m.M22);
        var w = (int)Math.Round(dipRect.Width * m.M11);
        var h = (int)Math.Round(dipRect.Height * m.M22);
        if (w < 1 || h < 1) throw new InvalidOperationException("empty capture rect");

        var bmp = new Bitmap(w, h);
        using (var g = Graphics.FromImage(bmp))
        {
            g.CopyFromScreen(x, y, 0, 0, new System.Drawing.Size(w, h));
        }
        return bmp;
    }
}
