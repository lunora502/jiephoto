using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Point = System.Windows.Point;
using Color = System.Windows.Media.Color;

namespace JieDraw;

/// <summary>
/// 屏幕批注层（v0.3 主功能）：覆盖整个虚拟屏的透明窗口，直接在屏幕上画（Epic Pen 式）。
/// 迷你工具条为独立窗口（穿透时必须仍可点击）：穿透/绘制切换、颜色、粗细、橡皮、
/// 撤销（移除最后一笔）、清空、整屏截图保存、退出。穿透 = WS_EX_TRANSPARENT。Esc 退出。
/// 整屏截图 = 隐藏工具条后直接 CopyFromScreen（墨迹已由覆盖层渲染在屏上，无需合成）。
/// </summary>
public sealed class AnnotateWindow : Window
{
    private const int GwlExStyle = -20;
    private const int WsExTransparent = 0x20;
    private const int WsExLayered = 0x80000;

    private InkCanvas _ink = null!;
    private Window _toolbar = null!;
    private TextBlock _tbStatus = null!;
    private Button _btnMode = null!;
    private IntPtr _hwnd;
    private bool _passthrough;
    private readonly DispatcherTimer _statusTimer;

    private int _penSize = 4;
    private Color _penColor = Color.FromRgb(90, 156, 248); // 与图标同源的亮蓝
    private bool _erasing;

    public AnnotateWindow()
    {
        Title = "捷画 屏幕批注";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = SystemParameters.VirtualScreenLeft;
        Top = SystemParameters.VirtualScreenTop;
        Width = SystemParameters.VirtualScreenWidth;
        Height = SystemParameters.VirtualScreenHeight;

        _ink = new InkCanvas { Background = Brushes.Transparent };
        ApplyAnnoPen();
        Content = _ink;

        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Exit(); };
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            ShowToolbar();
        };
        Closed += (_, _) => CloseToolbar();

        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _statusTimer.Tick += (_, _) => { _tbStatus.Text = ""; _statusTimer.Stop(); };
    }

    private void ApplyAnnoPen()
    {
        _ink.DefaultDrawingAttributes = new System.Windows.Ink.DrawingAttributes
        {
            Color = _penColor,
            Width = _penSize,
            Height = _penSize,
            FitToCurve = true,
            StylusTip = System.Windows.Ink.StylusTip.Ellipse
        };
    }

    private void InkModeInk()
    {
        _erasing = false;
        _ink.EditingMode = InkCanvasEditingMode.Ink;
        ApplyAnnoPen();
    }

    private void InkModeErase()
    {
        _erasing = true;
        _ink.EditingMode = InkCanvasEditingMode.EraseByPoint;
        _ink.EraserShape = new System.Windows.Ink.RectangleStylusShape(_penSize * 4, _penSize * 4);
    }

    // ---------- 迷你工具条（独立窗口：穿透时它必须仍可点击） ----------

    private void ShowToolbar()
    {
        _toolbar = new Window
        {
            Title = "捷画 批注工具",
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            ShowInTaskbar = false,
            Topmost = true,
            AllowsTransparency = true,
            SizeToContent = SizeToContent.WidthAndHeight,
            WindowStartupLocation = WindowStartupLocation.Manual,
            Left = SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth / 2 - 320,
            Top = SystemParameters.VirtualScreenTop + 8
        };

        _tbStatus = new TextBlock
        {
            Foreground = new SolidColorBrush(Color.FromRgb(138, 180, 248)),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(6, 0, 0, 0)
        };
        _btnMode = MakeTextButton("穿透", "点击后鼠标穿透覆盖层、可操作下层应用；再点恢复绘制", (_, _) => TogglePassthrough());

        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(10, 6, 10, 6) };
        panel.Children.Add(_btnMode);
        panel.Children.Add(Sep());

        // 颜色点
        var colorButtons = new Button[5];
        Color[] colors = {
            Color.FromRgb(90, 156, 248), Color.FromRgb(229, 72, 77), Color.FromRgb(46, 158, 91),
            Color.FromRgb(245, 158, 11), Color.FromRgb(232, 234, 237) };
        for (int i = 0; i < colors.Length; i++)
        {
            var idx = i;
            var c = colors[i];
            var b = MakeCircleButton(c, null, 14);
            b.Click += (_, _) =>
            {
                _penColor = c;
                if (!_erasing) ApplyAnnoPen();
                Highlight(colorButtons, b);
                Flash("颜色已切换");
            };
            colorButtons[idx] = b;
            panel.Children.Add(b);
        }
        Highlight(colorButtons, colorButtons[0]); // 默认色高亮

        panel.Children.Add(Sep());
        var sizeButtons = new Button[3];
        int[] sizes = { 3, 5, 9 };
        for (int i = 0; i < sizes.Length; i++)
        {
            var idx = i;
            var s = sizes[i];
            var b = MakeCircleButton(Color.FromRgb(232, 234, 237), null, s + 3);
            b.Click += (_, _) =>
            {
                _penSize = s;
                if (!_erasing) ApplyAnnoPen(); else InkModeErase();
                Highlight(sizeButtons, b);
                Flash("粗细已切换");
            };
            sizeButtons[idx] = b;
            panel.Children.Add(b);
        }
        Highlight(sizeButtons, sizeButtons[1]); // 默认中号

        panel.Children.Add(Sep());
        panel.Children.Add(MakeTextButton("橡皮", "擦除墨迹", (_, _) => { InkModeErase(); Flash("橡皮模式"); }));
        panel.Children.Add(MakeGlyphButton("\uE7A7", "撤销上一笔", (_, _) =>
        {
            if (_ink.Strokes.Count > 0) _ink.Strokes.RemoveAt(_ink.Strokes.Count - 1);
        }));
        panel.Children.Add(MakeGlyphButton("\uE74D", "清空全部墨迹", (_, _) => { _ink.Strokes.Clear(); Flash("已清空"); }));

        panel.Children.Add(Sep());
        panel.Children.Add(MakeTextButton("整屏截图", "隐藏工具条并保存整屏（含墨迹）PNG", (_, _) => SaveScreen()));
        panel.Children.Add(MakeGlyphButton("\uE8BB", "退出屏幕批注 (Esc)", (_, _) => Exit()));
        panel.Children.Add(_tbStatus);

        _toolbar.Content = new Border
        {
            Background = new SolidColorBrush(Color.FromRgb(32, 33, 36)),
            BorderBrush = new SolidColorBrush(Color.FromRgb(47, 49, 54)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Child = panel
        };
        _toolbar.Show();
        _toolbar.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle, () =>
        {
            _toolbar.Left = SystemParameters.VirtualScreenLeft +
                            (SystemParameters.VirtualScreenWidth - _toolbar.ActualWidth) / 2;
        });
    }

    private static void Highlight(Button[] buttons, Button selected)
    {
        foreach (var b in buttons)
            b.Background = new SolidColorBrush(ReferenceEquals(b, selected)
                ? Color.FromRgb(74, 78, 85)
                : Color.FromArgb(0, 0, 0, 0));
    }

    private static UIElement Sep() => new Border
    {
        Width = 1,
        Height = 22,
        Background = new SolidColorBrush(Color.FromRgb(60, 64, 67)),
        Margin = new Thickness(7, 0, 7, 0)
    };

    private Button MakeGlyphButton(string glyph, string tooltip, RoutedEventHandler onClick)
    {
        var b = new Button
        {
            Content = glyph,
            FontFamily = new FontFamily("Segoe MDL2 Assets"),
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(232, 234, 237)),
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(9, 5, 9, 5),
            Cursor = Cursors.Hand,
            ToolTip = tooltip
        };
        b.Click += onClick;
        return b;
    }

    private Button MakeTextButton(string text, string tooltip, RoutedEventHandler onClick)
    {
        var b = new Button
        {
            Content = text,
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(232, 234, 237)),
            Background = new SolidColorBrush(Color.FromRgb(60, 64, 67)),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(9, 5, 9, 5),
            Cursor = Cursors.Hand,
            ToolTip = tooltip
        };
        b.Click += onClick;
        return b;
    }

    private Button MakeCircleButton(Color fill, string? tooltip, double dotSize)
    {
        var b = new Button
        {
            Content = new Ellipse { Width = dotSize, Height = dotSize, Fill = new SolidColorBrush(fill) },
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(7, 5, 7, 5),
            Cursor = Cursors.Hand,
            ToolTip = tooltip ?? ""
        };
        return b;
    }

    private void Flash(string msg)
    {
        _tbStatus.Text = msg;
        _statusTimer.Stop();
        _statusTimer.Start();
    }

    // ---------- 穿透 ----------

    private void TogglePassthrough()
    {
        _passthrough = !_passthrough;
        var ex = GetWindowLong(_hwnd, GwlExStyle);
        SetWindowLong(_hwnd, GwlExStyle,
            _passthrough ? (ex | WsExTransparent | WsExLayered) : ((ex | WsExLayered) & ~WsExTransparent));
        _btnMode.Content = _passthrough ? "绘制" : "穿透";
        _btnMode.Background = new SolidColorBrush(_passthrough
            ? Color.FromRgb(30, 111, 217)
            : Color.FromRgb(60, 64, 67));
        Flash(_passthrough ? "已穿透：可操作下层应用，工具条仍可点" : "已恢复绘制");
    }

    [DllImport("user32.dll")]
    private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    // ---------- 整屏截图（墨迹已渲染在屏上，直接抓屏即可） ----------

    private void SaveScreen()
    {
        const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);

        _toolbar.Hide();
        System.Threading.Thread.Sleep(350); // 等工具条从屏幕消失（DWM 合成）
        try
        {
            using var bmp = new System.Drawing.Bitmap(vw, vh);
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(vx, vy, 0, 0, new System.Drawing.Size(vw, vh));
            }
            var file = PngExport.Save(SettingsStore.Load().SaveDir, "JieDraw_Screen",
                stream => bmp.Save(stream, System.Drawing.Imaging.ImageFormat.Png));
            AppLog.Log("screen annotate saved: " + file);
            FlashAfterShow("已保存 " + System.IO.Path.GetFileName(file));
        }
        catch (Exception ex)
        {
            AppLog.Log("screen save failed: " + ex);
            FlashAfterShow("保存失败");
        }
        finally
        {
            _toolbar.Show();
        }
    }

    private void FlashAfterShow(string msg) => Dispatcher.BeginInvoke(DispatcherPriority.Background, () => Flash(msg));

    private void Exit()
    {
        CloseToolbar();
        Close();
    }

    private void CloseToolbar()
    {
        try { _toolbar?.Close(); } catch { }
    }
}
