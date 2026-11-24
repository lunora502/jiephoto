using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Ink;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace JieDraw;

/// <summary>
/// 画板主窗口：预创建隐藏驻留，热键 Show/Hide（毫秒级）；
/// InkCanvas 负责墨迹（压感+平滑+内建撤销栈），导出按物理像素渲染。
/// </summary>
public partial class MainWindow : Window
{
    private readonly AppSettings _settings;
    private readonly DispatcherTimer _statusTimer;
    private IntPtr _hwnd;
    private bool _hotkeyOk;
    private HwndSource? _hookedSource;

    /// <summary>当前绘制模式（橡皮是 EditingMode，不在此列）。</summary>
    private enum DrawMode { Pen, Marker }
    private DrawMode _mode = DrawMode.Pen;

    /// <summary>选择工具：None=非选择；Lasso=套索（内建）；Rect=框选（矩形橡皮筋）；Click=点选（Ctrl 加选）。</summary>
    private enum SelTool { None, Lasso, Rect, Click }
    private SelTool _selTool = SelTool.None;

    // 框选/点选的鼠标状态
    private bool _marqueeActive;   // 框选橡皮筋拖拽中
    private bool _clickTracking;   // 点选按下跟踪中
    private Point _pressPoint;     // 按下位置（画布 DIP 坐标）

    // 撤销/重做：操作前笔迹快照栈（InkCanvas 无内建 Undo/Redo 公开方法）。
    // 两项加固：
    // 1) _restoring 防重入：还原快照替换 Strokes 集合期间触发的事件不再入栈
    // 2) 300ms 静默期合并：橡皮分割一条笔迹会产生一串事件，按"变更前"状态合并为一个撤销单元
    private readonly Stack<StrokeCollection> _undoStack = new();
    private readonly Stack<StrokeCollection> _redoStack = new();
    private const int MaxUndoDepth = 500;
    private bool _restoring;
    private bool _draftDirty;
    private StrokeCollection? _burstBase;
    private readonly DispatcherTimer _burstTimer;
    private readonly DispatcherTimer _draftTimer; // 笔迹变更后 2.5s 自动存草稿（防崩溃丢墨迹）
    /// <summary>上一稳定状态（上次突发提交/还原后的画布快照）＝ 本次突发的"变更前"基线。
    /// 不从事件参数反推（e.Added 实例与集合元素不一致，Remove 会静默失效导致基线错位）。</summary>
    private StrokeCollection _lastStable = new StrokeCollection();

    public MainWindow(AppSettings settings)
    {
        InitializeComponent();
        _settings = settings;

        Icon = IconFactory.WindowIcon;
        RestoreWindowBounds();
        ApplyDrawingAttributes();
        UpdateEraserShape();

        _burstTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
        _burstTimer.Tick += OnBurstQuiet;

        _draftTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        _draftTimer.Tick += (_, _) => { _draftTimer.Stop(); SaveDraft(); };

        // 事件挂接与草稿恢复必须在全部定时器就绪之后：
        // RestoreDraft 的 Add 会触发 StrokesChanged → OnStrokesChanged 用到 _burstTimer
        HookStrokesChanged();
        RestoreDraft();
        Ink.SelectionMoved += (_, _) => ScheduleDraftSave();
        Ink.SelectionResized += (_, _) => ScheduleDraftSave();

        // 框选/点选：接管 InkCanvas 预览鼠标事件（选择模式下内建套索会抢先）
        Ink.PreviewMouseLeftButtonDown += Ink_PreviewMouseLeftButtonDown;
        Ink.PreviewMouseMove += Ink_PreviewMouseMove;
        Ink.PreviewMouseLeftButtonUp += Ink_PreviewMouseLeftButtonUp;

        // 滚轮（光标在画布上）：循环切换粗细档位，免去来回点工具栏
        PreviewMouseWheel += OnPreviewWheel;

        _statusTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _statusTimer.Tick += (_, _) => { StatusText.Text = ""; _statusTimer.Stop(); };

        SelectInitialUiState();
        UpdateMaximizeGlyph(); // RestoreWindowBounds 可能已恢复最大化状态
        btnPin.IsChecked = _settings.Topmost;             // 先置初值（在接线前，避免触发一次 ApplyPin）
        btnPin.Checked += (_, _) => ApplyPin();           // 真实点击 / 空格 / UIA Toggle 都会走 IsChecked 变化
        btnPin.Unchecked += (_, _) => ApplyPin();
    }

    // ---------- 撤销 / 重做 ----------

    private void HookStrokesChanged() => Ink.Strokes.StrokesChanged += OnStrokesChanged;

    private void OnStrokesChanged(object? sender, StrokeCollectionChangedEventArgs e)
    {
        if (e.Added.Count == 0 && e.Removed.Count == 0) return;
        if (_restoring) return;
        ScheduleDraftSave();

        if (_burstBase is null)
            _burstBase = _lastStable; // 本串突发开始前的画布状态
        _burstTimer.Stop();
        _burstTimer.Start(); // 静默 300ms 后整串提交为一个撤销单元
    }

    private void OnBurstQuiet(object? sender, EventArgs e)
    {
        _burstTimer.Stop();
        CommitBurst();
    }

    /// <summary>提交当前事件串（撤销前也会调用，保证最新操作可立即撤销）。</summary>
    private void CommitBurst()
    {
        if (_burstBase is null) return;
        AppLog.Log($"undo push burst (strokes={_burstBase.Count}) depth={_undoStack.Count + 1}");
        _undoStack.Push(_burstBase);
        if (_undoStack.Count > MaxUndoDepth) TrimUndo();
        _redoStack.Clear();
        _burstBase = null;
        _lastStable = Ink.Strokes.Clone(); // 突发结束，刷新稳定态基线
    }

    private void TrimUndo()
    {
        var keep = _undoStack.Skip(_undoStack.Count - MaxUndoDepth).ToList();
        _undoStack.Clear();
        foreach (var s in keep) _undoStack.Push(s);
    }

    private void ApplySnapshot(StrokeCollection snapshot)
    {
        _restoring = true;
        try
        {
            var restored = new StrokeCollection(snapshot); // 整体替换不重复入栈（有 _restoring 双保险）
            restored.StrokesChanged += OnStrokesChanged;   // 换了集合实例，事件需重挂
            Ink.Strokes = restored;
            _lastStable = restored.Clone();                // 还原也是一种稳定态，刷新基线
        }
        finally
        {
            _restoring = false;
        }
    }

    private void Undo() { CommitBurst(); DoUndo(); ScheduleDraftSave(); }
    private void Redo() { CommitBurst(); DoRedo(); ScheduleDraftSave(); }

    private void ScheduleDraftSave()
    {
        _draftDirty = true;
        _draftTimer.Stop();
        _draftTimer.Start();
    }

    private void DoUndo()
    {
        if (_undoStack.Count == 0) { AppLog.Log("undo: empty stack"); return; }
        _redoStack.Push(Ink.Strokes.Clone());
        var snap = _undoStack.Pop();
        AppLog.Log($"undo: apply {snap.Count} strokes (total now {Ink.Strokes.Count})");
        ApplySnapshot(snap);
    }

    private void DoRedo()
    {
        if (_redoStack.Count == 0) { AppLog.Log("redo: empty stack"); return; }
        _undoStack.Push(Ink.Strokes.Clone());
        var snap = _redoStack.Pop();
        AppLog.Log($"redo: apply {snap.Count} strokes");
        ApplySnapshot(snap);
    }

    private void Undo_Click(object sender, RoutedEventArgs e) => Undo();

    private void Redo_Click(object sender, RoutedEventArgs e) => Redo();

    /// <summary>热键是否注册成功（供托盘 Balloon 提示）。</summary>
    public bool HotkeyRegistered => _hotkeyOk;

    /// <summary>用户是否配置了热键（空串 = 主动停用，属正常状态非错误）。</summary>
    public bool HotkeyConfigured => !string.IsNullOrEmpty(_settings.Hotkey);

    // ---------- 热键链路 ----------

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var src = PresentationSource.FromVisual(this) as HwndSource;
        if (src is null || ReferenceEquals(src, _hookedSource)) return;

        // 窗口句柄重建（少见）时：摘旧钩子、注销旧热键，再挂新的
        _hookedSource?.RemoveHook(WndProc);
        if (_hotkeyOk && _hwnd != IntPtr.Zero) { try { HotkeyService.Unregister(_hwnd); } catch { } }

        _hookedSource = src;
        _hwnd = src.Handle;
        src.AddHook(WndProc);
        if (HotkeyConfigured)
        {
            _hotkeyOk = HotkeyService.TryRegister(_hwnd, _settings.Hotkey, out var err);
            if (!_hotkeyOk) AppLog.Log(err);
        }
        else
        {
            AppLog.Log("hotkey disabled by settings"); // 主动停用：仅托盘/设置入口可用
        }
        AppLog.Log($"hotkey ready hwnd=0x{_hwnd.ToInt64():X}");
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == HotkeyService.WmHotkey && wParam.ToInt32() == HotkeyService.Id)
        {
            handled = true;
            var sw = Stopwatch.StartNew();
            Dispatcher.BeginInvoke(() =>
            {
                ToggleFromHotkey();
                AppLog.Log($"hotkey -> {(IsVisible ? "show" : "hide")} in {sw.ElapsedMilliseconds}ms");
            });
        }
        return IntPtr.Zero;
    }

    /// <summary>热键/托盘入口：显示或隐藏（内容始终保留）。</summary>
    public void ToggleFromHotkey()
    {
        if (IsVisible)
        {
            HideCanvas();
            return;
        }
        ShowCanvas();
    }

    /// <summary>显示画板（热键/托盘/单实例激活共用）：置顶归位 + 抢前台。</summary>
    public void ShowCanvas()
    {
        Show();
        Topmost = _settings.Topmost;
        EnsureTopmostStyle(_settings.Topmost);
        Activate();
        try { HotkeyService.SetForegroundWindow(_hwnd); } catch { }
    }

    public void ShutdownCleanup()
    {
        SaveWindowBounds();
        SaveDraft();
        try { if (_hwnd != IntPtr.Zero) HotkeyService.Unregister(_hwnd); } catch { }
    }

    // ---------- 窗口几何：位置/大小/最大化记忆 ----------

    /// <summary>启动时恢复上次窗口几何；已保存位置至少部分落在当前虚拟屏内才恢复。</summary>
    private void RestoreWindowBounds()
    {
        if (_settings.WinWidth is not double w || _settings.WinHeight is not double h
            || _settings.WinLeft is not double l || _settings.WinTop is not double t)
            return; // 首次运行 → XAML 的 CenterScreen
        if (w < MinWidth || h < MinHeight) return;

        var vsL = SystemParameters.VirtualScreenLeft;
        var vsT = SystemParameters.VirtualScreenTop;
        var vsR = vsL + SystemParameters.VirtualScreenWidth;
        var vsB = vsT + SystemParameters.VirtualScreenHeight;
        // 拔掉显示器后旧坐标可能整体在屏外：要求标题区（上缘 100px 条带）至少在虚拟屏内
        if (l + 60 > vsR || t + 60 > vsB || l + w - 60 < vsL || t >= vsB) return;

        WindowStartupLocation = WindowStartupLocation.Manual;
        Left = l; Top = t; Width = w; Height = h;
        if (_settings.WinMaximized) WindowState = WindowState.Maximized;
    }

    /// <summary>持久化当前几何；最大化时用 RestoreBounds 记录"还原态"。</summary>
    private void SaveWindowBounds()
    {
        if (WindowState == WindowState.Maximized)
        {
            var rb = RestoreBounds; // 正常态边界（窗口已显示过，必然有效）
            _settings.WinLeft = rb.Left; _settings.WinTop = rb.Top;
            _settings.WinWidth = rb.Width; _settings.WinHeight = rb.Height;
            _settings.WinMaximized = true;
        }
        else
        {
            _settings.WinLeft = Left; _settings.WinTop = Top;
            _settings.WinWidth = Width; _settings.WinHeight = Height;
            _settings.WinMaximized = false;
        }
        SettingsStore.Save(_settings);
    }

    /// <summary>收起画板（保存窗口几何 + 笔迹草稿）。</summary>
    private void HideCanvas()
    {
        Hide();
        SaveWindowBounds();
        SaveDraft();
    }

    // ---------- 草稿持久化 ----------

    private static string DraftPath => Path.Combine(SettingsStore.Dir, "draft.isf");

    /// <summary>收起/退出时把笔迹序列化到 draft.isf，下次启动自动恢复（"随手记"不断线）。</summary>
    private void SaveDraft()
    {
        if (!_draftDirty) return;
        _draftTimer.Stop();
        try
        {
            Directory.CreateDirectory(SettingsStore.Dir);
            using (var fs = File.Create(DraftPath)) Ink.Strokes.Save(fs);
            _draftDirty = false;
        }
        catch (Exception ex)
        {
            AppLog.Log("draft save failed: " + ex.Message);
        }
    }

    private void RestoreDraft()
    {
        try
        {
            if (!File.Exists(DraftPath)) return;
            using var fs = File.OpenRead(DraftPath);
            var sc = new StrokeCollection(fs);
            if (sc.Count == 0) return;
            Ink.Strokes.Add(sc);
            _draftTimer.Stop();
            _draftDirty = false;
            AppLog.Log($"draft restored: {sc.Count} strokes");
        }
        catch (Exception ex)
        {
            AppLog.Log("draft restore failed: " + ex); // 全栈便于定位
        }
    }

    // ---------- 画笔状态 ----------

    /// <summary>按当前模式（笔/荧光笔）+ 设置的色/粗细生成 DrawingAttributes。</summary>
    private void ApplyDrawingAttributes()
    {
        var color = (Color)ColorConverter.ConvertFromString(_settings.PenColor);
        if (_mode == DrawMode.Marker)
        {
            // 荧光笔：半透明叠加、矩形笔尖、随粗细档位放大、不吃压感
            var size = Math.Max(12.0, _settings.PenSize * 4);
            Ink.DefaultDrawingAttributes = new DrawingAttributes
            {
                Color = color,
                Width = size, Height = size,
                IsHighlighter = true,
                FitToCurve = false,
                IgnorePressure = true,
                StylusTip = StylusTip.Rectangle
            };
        }
        else
        {
            Ink.DefaultDrawingAttributes = new DrawingAttributes
            {
                Color = color,
                Width = _settings.PenSize,
                Height = _settings.PenSize,
                FitToCurve = true,          // 贝塞尔平滑手抖
                IgnorePressure = false,     // 手写笔压感生效
                StylusTip = StylusTip.Ellipse
            };
        }
    }

    private void UpdateEraserShape()
    {
        Ink.EraserShape = new System.Windows.Ink.RectangleStylusShape(
            _settings.PenSize * 6, _settings.PenSize * 6);
    }

    private void SelectInitialUiState()
    {
        foreach (var rb in new[] { cBlack, cRed, cBlue, cGreen, cOrange })
            rb.IsChecked = (string)rb.Tag! == _settings.PenColor;
        if (cBlack.IsChecked != true && cRed.IsChecked != true && cBlue.IsChecked != true
            && cGreen.IsChecked != true && cOrange.IsChecked != true)
            cBlack.IsChecked = true;

        SyncSizeRadios();

        mPen.IsChecked = true;
        Ink.EditingMode = InkCanvasEditingMode.Ink;
    }

    // ---------- 工具栏事件 ----------

    private void Color_Click(object sender, RoutedEventArgs e)
    {
        _settings.PenColor = (string)((FrameworkElement)sender).Tag!;
        EnsureInkMode();
        ApplyDrawingAttributes();
        SettingsStore.Save(_settings);
    }

    private void Size_Click(object sender, RoutedEventArgs e)
    {
        _settings.PenSize = int.Parse((string)((FrameworkElement)sender).Tag!);
        // 橡皮模式下只调整橡皮尺寸，不跳回笔（其余模式更新画笔属性，保持当前编辑模式）
        if (Ink.EditingMode == InkCanvasEditingMode.EraseByPoint)
        {
            UpdateEraserShape();
        }
        else
        {
            ApplyDrawingAttributes();
            UpdateEraserShape();
        }
        SettingsStore.Save(_settings);
    }

    private void Mode_Click(object sender, RoutedEventArgs e)
    {
        ApplyMode((string)((FrameworkElement)sender).Tag!);
    }

    /// <summary>切换到指定模式并同步芯片选中态（工具栏点击与 Ctrl+1-6 快捷键共用）。</summary>
    private void ApplyMode(string tag)
    {
        EndMarquee();
        switch (tag)
        {
            case "erase":
                _selTool = SelTool.None;
                Ink.EditingMode = InkCanvasEditingMode.EraseByPoint;
                mErase.IsChecked = true;
                break;
            case "rect":
                _selTool = SelTool.Rect;
                Ink.EditingMode = InkCanvasEditingMode.Select; // 选中集仍在：可拖动/调柄
                mRect.IsChecked = true;
                break;
            case "click":
                _selTool = SelTool.Click;
                Ink.EditingMode = InkCanvasEditingMode.Select;
                mClick.IsChecked = true;
                break;
            case "lasso":
                _selTool = SelTool.Lasso;
                Ink.EditingMode = InkCanvasEditingMode.Select; // 内建套索圈选
                mLasso.IsChecked = true;
                break;
            default:
                _selTool = SelTool.None;
                _mode = tag == "marker" ? DrawMode.Marker : DrawMode.Pen;
                Ink.EditingMode = InkCanvasEditingMode.Ink;
                (_mode == DrawMode.Marker ? mMarker : mPen).IsChecked = true;
                ApplyDrawingAttributes();
                break;
        }
    }

    // ---------- 框选 / 点选 ----------

    private void Ink_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (_selTool != SelTool.Rect && _selTool != SelTool.Click) return;
        var p = e.GetPosition(Ink);

        // 点在既有选区/控制柄上：放行给内建逻辑（拖动、缩放选择）
        if (Ink.HitTestSelection(p) != InkCanvasSelectionHitResult.None) return;

        // 其余按下全部接管（阻断内建套索），框选拖橡皮筋 / 点选等抬起定夺
        e.Handled = true;
        _pressPoint = p;
        Ink.CaptureMouse();
        if (_selTool == SelTool.Rect)
        {
            _marqueeActive = true;
            UpdateMarquee(p, p);
            MarqueeRect.Visibility = Visibility.Visible;
        }
        else
        {
            _clickTracking = true;
        }
    }

    private void Ink_PreviewMouseMove(object sender, MouseEventArgs e)
    {
        if (!_marqueeActive) return;
        UpdateMarquee(_pressPoint, e.GetPosition(Ink));
    }

    private void Ink_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (_marqueeActive)
        {
            _marqueeActive = false;
            Ink.ReleaseMouseCapture();
            var p = e.GetPosition(Ink);
            MarqueeRect.Visibility = Visibility.Collapsed;

            var rect = new Rect(_pressPoint, p);
            var hit = new StrokeCollection();
            foreach (var s in Ink.Strokes)
                if (s.GetBounds().IntersectsWith(rect)) hit.Add(s);
            Ink.Select(hit);
            Flash(hit.Count > 0 ? $"已框选 {hit.Count} 项（可拖动）" : "未选中笔迹");
        }
        else if (_clickTracking)
        {
            _clickTracking = false;
            Ink.ReleaseMouseCapture();
            var p = e.GetPosition(Ink);

            var clicked = new StrokeCollection();
            foreach (var s in Ink.Strokes)
                if (IsPointNearStroke(p, s)) clicked.Add(s);

            if (clicked.Count == 0)
            {
                Ink.Select(new StrokeCollection()); // 点空白 → 清除选择
                return;
            }

            bool additive = Keyboard.Modifiers is ModifierKeys.Control or ModifierKeys.Shift;
            if (additive)
            {
                // Ctrl/Shift+点击：在既有选择中加选/减选。
                // 注意必须用 Ink.Strokes 的原实例——Clone 出来的实例 Ink.Select() 按引用匹配不上
                var cur = new StrokeCollection();
                foreach (var s in Ink.GetSelectedStrokes()) cur.Add(s);
                foreach (var s in clicked)
                {
                    if (cur.IndexOf(s) >= 0) cur.Remove(s); else cur.Add(s);
                }
                Ink.Select(cur);
                Flash($"已选中 {cur.Count} 项");
            }
            else
            {
                Ink.Select(clicked);
                Flash("已选中 1 项（Ctrl+点击加选）");
            }
        }
    }

    /// <summary>滚轮循环切换粗细档位（细 2 → 中 4 → 粗 8）。</summary>
    private void OnPreviewWheel(object sender, MouseWheelEventArgs e)
    {
        if (!Ink.IsMouseOver) return;
        int[] sizes = { 2, 4, 8 };
        int idx = Array.IndexOf(sizes, _settings.PenSize);
        if (idx < 0) idx = 1;
        int next = Math.Clamp(idx + (e.Delta > 0 ? 1 : -1), 0, sizes.Length - 1);
        e.Handled = true;
        if (next == idx) return;

        _settings.PenSize = sizes[next];
        if (Ink.EditingMode == InkCanvasEditingMode.EraseByPoint)
            UpdateEraserShape(); // 橡皮模式只改橡皮尺寸（同 Size_Click 逻辑）
        else
            ApplyDrawingAttributes();
        UpdateEraserShape();
        SyncSizeRadios();
        SettingsStore.Save(_settings);
        Flash($"粗细 {_settings.PenSize}（滚轮）");
    }

    private void SyncSizeRadios()
    {
        foreach (var rb in new[] { s1, s2, s3 })
            rb.IsChecked = (string)rb.Tag! == _settings.PenSize.ToString();
    }

    /// <summary>点选命中判定：点到笔迹任一采样点距离 ≤6 DIP 即命中。
    /// 内建 HitTest(Point) 容差是亚像素级，鼠标点细线几乎必 miss，不可用。</summary>
    private static bool IsPointNearStroke(Point p, System.Windows.Ink.Stroke s)
    {
        foreach (var sp in s.StylusPoints)
        {
            var dx = sp.X - p.X; var dy = sp.Y - p.Y;
            if (dx * dx + dy * dy <= 36) return true; // 6^2
        }
        return false;
    }

    private void UpdateMarquee(Point a, Point b)
    {
        var r = new Rect(a, b);
        MarqueeRect.Margin = new Thickness(r.X, r.Y, 0, 0);
        MarqueeRect.Width = Math.Max(1, r.Width);
        MarqueeRect.Height = Math.Max(1, r.Height);
    }

    private void EndMarquee()
    {
        _marqueeActive = false;
        _clickTracking = false;
        MarqueeRect.Visibility = Visibility.Collapsed;
        if (Ink.IsMouseCaptured) Ink.ReleaseMouseCapture();
    }

    /// <summary>橡皮状态下点了颜色/粗细/荧光笔 → 回到对应的绘制模式（保持当前笔种）。</summary>
    private void EnsureInkMode()
    {
        if (Ink.EditingMode == InkCanvasEditingMode.Ink) return;
        (_mode == DrawMode.Marker ? mMarker : mPen).IsChecked = true;
        Ink.EditingMode = InkCanvasEditingMode.Ink;
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (Ink.Strokes.Count == 0) return;
        Ink.Strokes.Clear(); // StrokesChanged 会压入清空前快照 → 清空可撤销
        ScheduleDraftSave();
        Flash("已清空");
    }

    private void Hide_Click(object sender, RoutedEventArgs e) => HideCanvas();

    private void Close_Click(object sender, RoutedEventArgs e) =>
        System.Windows.Application.Current.Shutdown(); // 收起=保留内容常驻；✕=退出应用

    // ---------- 最大化 / 全屏 ----------

    /// <summary>最大化/还原切换（WindowChrome 让无边框窗口最大化时正确避开任务栏）。</summary>
    private void ToggleFullscreen()
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        UpdateMaximizeGlyph();
    }

    /// <summary>随窗口状态切换浏览器式图标：□ 最大化 / ❐ 还原。</summary>
    private void UpdateMaximizeGlyph()
    {
        btnMaximize.Content = WindowState == WindowState.Maximized ? "\uE923" : "\uE922";
    }

    private void Maximize_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();

    /// <summary>屏幕批注：全屏透明覆盖，直接在屏幕上画（Epic Pen 式）。Esc/✕ 退出。</summary>
    private void Annotate_Click(object sender, RoutedEventArgs e)
    {
        HideCanvas(); // 画板先收起，避免与覆盖层抢焦点
        new AnnotateWindow().Show();
    }

    // ---------- 置顶开关 ----------

    private void ApplyPin()
    {
        _settings.Topmost = btnPin.IsChecked == true;
        Topmost = _settings.Topmost;
        EnsureTopmostStyle(_settings.Topmost); // WPF Topmost=false 实测可能残留 WS_EX_TOPMOST 位，显式归位
        SettingsStore.Save(_settings);
        Flash(_settings.Topmost ? "画板已置顶" : "画板已取消置顶（不再遮挡其他窗口）");
    }

    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);

    /// <summary>显式把窗口放进/移出置顶层（-1 TOPMOST / -2 NOTOPMOST），不改位置大小不抢焦点。</summary>
    private void EnsureTopmostStyle(bool topmost)
    {
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10;
        try { SetWindowPos(_hwnd, (IntPtr)(topmost ? -1 : -2), 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE); }
        catch { }
    }

    // ---------- 截图联动 ----------

    /// <summary>隐藏画板 → 全屏遮罩拖框截屏 → 底图放进画布，直接用墨迹标注。</summary>
    private void Screenshot_Click(object sender, RoutedEventArgs e)
    {
        HideCanvas(); // 自己先出镜
        var overlay = new ScreenshotOverlayWindow();
        overlay.ShowDialog();
        var bmp = overlay.Captured;
        AppLog.Log($"screenshot: dialog done, captured={(bmp is null ? "null" : bmp.Width + "x" + bmp.Height)}");
        if (bmp is null) { Flash("已取消截图"); ShowCanvasAfterOverlay(); return; }
        AddScreenshotToCanvas(bmp);
        ShowCanvasAfterOverlay();
    }

    private void ShowCanvasAfterOverlay()
    {
        if (!IsVisible)
        {
            Show();
            Topmost = _settings.Topmost;
            Activate();
            try { HotkeyService.SetForegroundWindow(_hwnd); } catch { }
        }
    }

    /// <summary>截图按比例缩放放入画布中央（InkCanvas 子元素在墨迹下层，标注覆盖其上）。</summary>
    private void AddScreenshotToCanvas(System.Drawing.Bitmap bmp)
    {
        var hBmp = bmp.GetHbitmap();
        try
        {
            var bs = Imaging.CreateBitmapSourceFromHBitmap(
                hBmp, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            bs.Freeze();
            double scale = Math.Min(Ink.ActualWidth / bs.Width, Ink.ActualHeight / bs.Height);
            if (scale > 1) scale = 1;
            var img = new System.Windows.Controls.Image
            {
                Source = bs,
                Width = bs.Width * scale,
                Height = bs.Height * scale
            };
            Ink.Children.Add(img);
            var left = Math.Max(0, (Ink.ActualWidth - img.Width) / 2);
            var top = Math.Max(0, (Ink.ActualHeight - img.Height) / 2);
            System.Windows.Controls.Canvas.SetLeft(img, left);
            System.Windows.Controls.Canvas.SetTop(img, top);
            AppLog.Log($"screenshot: image on canvas {img.Width:F0}x{img.Height:F0} at {left:F0},{top:F0}");
            Flash("截图已放入画布，可直接在上方标注；保存 PNG 会包含截图");
        }
        finally
        {
            DeleteObject(hBmp); // CreateBitmapSourceFromHBitmap 已复制像素，立即释放防 GDI 泄漏
        }
    }

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr hObject);

    // ---------- 设置 ----------

    /// <summary>打开设置窗口（工具栏 ⚙ 与托盘菜单共用入口）。</summary>
    public void OpenSettingsUi()
    {
        AppLog.Log("settings: opening");
        var win = new SettingsWindow(_settings) { Owner = this };
        var result = win.ShowDialog();
        if (result != true) return;

        bool changed = false;
        if (win.NewHotkey != _settings.Hotkey)
        {
            ApplyHotkey(win.NewHotkey); // ApplyHotkey 内部保存设置
        }
        if (win.AutoStartNew != AutoStartHelper.IsEnabled())
        {
            AutoStartHelper.Set(win.AutoStartNew);
            changed = true;
        }
        if (win.SaveDirNew != _settings.SaveDir)
        {
            _settings.SaveDir = win.SaveDirNew;
            changed = true;
        }
        if (win.TransparentNew != _settings.TransparentExport)
        {
            _settings.TransparentExport = win.TransparentNew;
            changed = true;
        }
        if (win.WakeNew != _settings.WakeHotkey)
        {
            _settings.WakeHotkey = win.WakeNew;
            if (win.WakeNew) WakeShortcutHelper.Ensure(_settings.Hotkey);
            else WakeShortcutHelper.Remove();
            changed = true;
        }
        if (changed)
        {
            SettingsStore.Save(_settings);
            Flash("设置已更新");
        }
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => OpenSettingsUi();

    /// <summary>换绑全局热键：空串=停用；否则先注销旧的再注册新的，失败自动回滚旧热键。</summary>
    private void ApplyHotkey(string spec)
    {
        HotkeyService.Unregister(_hwnd);
        _hotkeyOk = false;

        if (string.IsNullOrEmpty(spec))
        {
            _settings.Hotkey = "";
            SettingsStore.Save(_settings);
            (System.Windows.Application.Current as App)?.RefreshTrayText("");
            Flash("已停用全局热键（托盘双击仍可唤起）");
            AppLog.Log("hotkey disabled");
            return;
        }

        if (HotkeyService.TryRegister(_hwnd, spec, out var err))
        {
            _settings.Hotkey = spec;
            SettingsStore.Save(_settings);
            (System.Windows.Application.Current as App)?.RefreshTrayText(spec);
            if (_settings.WakeHotkey)
                WakeShortcutHelper.Ensure(spec); // 应用热键若为 Ctrl+Alt+X，唤醒快捷键同步为同组合
            Flash("热键已更新为 " + spec);
            AppLog.Log("hotkey changed to " + spec);
            return;
        }

        // 新热键被占用：回滚旧热键，保持可用
        if (HotkeyService.TryRegister(_hwnd, _settings.Hotkey, out var rollbackErr))
            _hotkeyOk = true;
        AppLog.Log($"{err}; rollback: {(_hotkeyOk ? "ok" : rollbackErr)}");
        Flash("注册失败（被占用？），已保留 " + _settings.Hotkey);
    }

    private void Copy_Click(object sender, RoutedEventArgs e) => DoCopy();

    private void Paste_Click(object sender, RoutedEventArgs e) => PasteFromClipboard();

    /// <summary>复制：有框选时只复制选中笔迹（矢量 ISF，可粘贴回画布），否则复制整画布白底 PNG。</summary>
    private void DoCopy()
    {
        if (Ink.GetSelectedStrokes().Count > 0)
        {
            try
            {
                Ink.CopySelection();
                Flash("已复制选中的笔迹");
                return;
            }
            catch (Exception ex)
            {
                AppLog.Log("copy strokes failed: " + ex);
            }
        }
        CopyToClipboard(); // 无选中 → 整画布 PNG
    }

    /// <summary>粘贴：ISF 笔迹（本应用复制的）→ 画布中央可拖动；系统图片 → 底图入画布标注。</summary>
    private void PasteFromClipboard()
    {
        try
        {
            if (Ink.CanPaste())
            {
                var before = new HashSet<System.Windows.Ink.Stroke>(Ink.Strokes);
                Ink.Paste(new Point(
                    Math.Max(0, Ink.ActualWidth / 2 - 120),
                    Math.Max(0, Ink.ActualHeight / 2 - 90)));
                var added = Ink.Strokes.Where(s => !before.Contains(s)).ToList();
                if (added.Count > 0)
                {
                    Ink.Select(new StrokeCollection(added));
                    Ink.EditingMode = InkCanvasEditingMode.Select;
                    _selTool = SelTool.Lasso; // 粘贴后自然进入选择态，可拖动
                    mLasso.IsChecked = true;
                }
                Flash("已粘贴，可拖动到合适位置（Ctrl+Z 撤销）");
                return;
            }

            // 系统图片（截图工具/浏览器复制的位图）→ 底图入画布
            if (Clipboard.ContainsImage())
            {
                var bs = Clipboard.GetImage();
                if (bs is null) { Flash("剪贴板图片读取失败"); return; }
                bs.Freeze();
                if (bs.Width < 5 || bs.Height < 5) { Flash("剪贴板图片尺寸无效"); return; }
                double scale = Math.Min(Ink.ActualWidth / bs.Width, Ink.ActualHeight / bs.Height);
                if (scale > 1) scale = 1;
                var img = new System.Windows.Controls.Image
                {
                    Source = bs,
                    Width = bs.Width * scale,
                    Height = bs.Height * scale
                };
                Ink.Children.Add(img);
                System.Windows.Controls.Canvas.SetLeft(img, Math.Max(0, (Ink.ActualWidth - img.Width) / 2));
                System.Windows.Controls.Canvas.SetTop(img, Math.Max(0, (Ink.ActualHeight - img.Height) / 2));
                AppLog.Log($"paste: image {bs.Width:F0}x{bs.Height:F0} -> canvas");
                Flash("已粘贴图片，可直接在上方标注");
                return;
            }

            Flash("剪贴板没有可粘贴的内容");
        }
        catch (Exception ex)
        {
            AppLog.Log("paste failed: " + ex);
            Flash("粘贴失败");
        }
    }

    private void Save_Click(object sender, RoutedEventArgs e) => SavePng();

    private void ToolBar_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        // 按钮自身吃掉按下事件，能走到这里的一定是工具栏空白处
        if (e.ClickCount == 2)
        {
            ToggleFullscreen(); // 双击工具栏 = 全屏/还原（标准窗口习惯）
            return;
        }
        try { DragMove(); } catch { }
    }

    // ---------- 窗口级快捷键 ----------

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        base.OnPreviewKeyDown(e);
        if (e.Key == Key.Escape)
        {
            HideCanvas();
            e.Handled = true;
        }
        else if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control)
        {
            SavePng();
            e.Handled = true;
        }
        else if (e.Key == Key.F11)
        {
            ToggleFullscreen();
            e.Handled = true;
        }
        else if (e.Key == Key.Z && Keyboard.Modifiers == ModifierKeys.Control
                 && Keyboard.Modifiers != (ModifierKeys.Control | ModifierKeys.Shift))
        {
            Undo();
            e.Handled = true;
        }
        else if (e.Key == Key.Y && Keyboard.Modifiers == ModifierKeys.Control
             || e.Key == Key.Z && Keyboard.Modifiers == (ModifierKeys.Control | ModifierKeys.Shift))
        {
            Redo();
            e.Handled = true;
        }
        else if (e.Key == Key.C && Keyboard.Modifiers == ModifierKeys.Control)
        {
            DoCopy();
            e.Handled = true;
        }
        else if (e.Key == Key.V && Keyboard.Modifiers == ModifierKeys.Control)
        {
            PasteFromClipboard();
            e.Handled = true;
        }
        else if (e.Key == Key.Delete && Ink.GetSelectedStrokes().Count > 0)
        {
            var sel = Ink.GetSelectedStrokes();
            foreach (var s in sel) Ink.Strokes.Remove(s); // StrokesChanged 入撤销栈，可 Ctrl+Z
            Flash($"已删除 {sel.Count} 项（Ctrl+Z 撤销）");
            e.Handled = true;
        }
        else if (e.Key == Key.A && Keyboard.Modifiers == ModifierKeys.Control)
        {
            Ink.Select(Ink.Strokes);
            if (Ink.EditingMode != InkCanvasEditingMode.Select) ApplyMode("lasso"); // 非选择模式 → 切到套索呈现选区
            Flash($"已全选 {Ink.Strokes.Count} 项（Del 删除）");
            e.Handled = true;
        }
        else if (Keyboard.Modifiers == ModifierKeys.Control)
        {
            // Ctrl+1..6：笔/荧光笔/橡皮/框选/点选/套索（工具栏芯片同一逻辑）
            switch (e.Key)
            {
                case Key.D1 or Key.NumPad1: ApplyMode("ink"); e.Handled = true; break;
                case Key.D2 or Key.NumPad2: ApplyMode("marker"); e.Handled = true; break;
                case Key.D3 or Key.NumPad3: ApplyMode("erase"); e.Handled = true; break;
                case Key.D4 or Key.NumPad4: ApplyMode("rect"); e.Handled = true; break;
                case Key.D5 or Key.NumPad5: ApplyMode("click"); e.Handled = true; break;
                case Key.D6 or Key.NumPad6: ApplyMode("lasso"); e.Handled = true; break;
            }
        }
    }

    // ---------- 导出 ----------

    /// <summary>按物理像素渲染画布（高 DPI 下导出依然清晰）。</summary>
    private RenderTargetBitmap? RenderCanvas()
    {
        if (Ink.ActualWidth < 1 || Ink.ActualHeight < 1) return null;
        var m = PresentationSource.FromVisual(this)!.CompositionTarget!.TransformToDevice;
        var rtb = new RenderTargetBitmap(
            (int)Math.Ceiling(Ink.ActualWidth * m.M11),
            (int)Math.Ceiling(Ink.ActualHeight * m.M22),
            96 * m.M11, 96 * m.M22, PixelFormats.Pbgra32);
        // 直接 Render(Ink)/VisualBrush 会把选择框（adorner 层）也渲染进导出图，
        // 因此逐项绘制：底色（可选透明）+ 截图子元素 + 笔迹，只含内容不含装饰
        var dv = new DrawingVisual();
        using (var dc = dv.RenderOpen())
        {
            if (!_settings.TransparentExport)
                dc.DrawRectangle(Brushes.White, null,
                    new Rect(0, 0, Ink.ActualWidth, Ink.ActualHeight));
            foreach (var child in Ink.Children.OfType<System.Windows.Controls.Image>())
            {
                if (child.Source is BitmapSource bs && !double.IsNaN(System.Windows.Controls.Canvas.GetLeft(child)))
                    dc.DrawImage(bs, new Rect(
                        System.Windows.Controls.Canvas.GetLeft(child),
                        System.Windows.Controls.Canvas.GetTop(child),
                        child.Width, child.Height));
            }
            foreach (var s in Ink.Strokes)
                s.Draw(dc, s.DrawingAttributes);
        }
        rtb.Render(dv);
        return rtb;
    }

    private void SavePng()
    {
        try
        {
            var rtb = RenderCanvas();
            if (rtb is null) { Flash("画布尚未就绪"); return; }

            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            var file = PngExport.Save(_settings.SaveDir, "JieDraw", enc.Save);

            Flash("已保存 " + file);
            AppLog.Log("saved " + file);
        }
        catch (Exception ex)
        {
            AppLog.Log("save failed: " + ex);
            Flash("保存失败");
        }
    }

    private bool _clipboardBusy;

    /// <summary>异步复制：剪贴板被占用时退避重试，不阻塞 UI 线程（锁屏下 OpenClipboard 必失败，重试后提示）。</summary>
    private async void CopyToClipboard()
    {
        if (_clipboardBusy) return;
        _clipboardBusy = true;
        try
        {
            var rtb = RenderCanvas();
            if (rtb is null) { Flash("画布尚未就绪"); return; }

            for (int attempt = 1; attempt <= 4; attempt++)
            {
                try
                {
                    Clipboard.SetImage(rtb);
                    Flash("已复制到剪贴板");
                    return;
                }
                catch (COMException ex) when (attempt < 4)
                {
                    AppLog.Log($"clipboard busy, retry {attempt}: {ex.Message}");
                    await Task.Delay(150 * attempt); // await 回 UI 上下文，不阻塞消息泵
                }
            }
            Flash("复制失败");
        }
        catch (Exception ex)
        {
            AppLog.Log("copy failed: " + ex);
            Flash("复制失败");
        }
        finally
        {
            _clipboardBusy = false;
        }
    }

    private void Flash(string msg)
    {
        StatusText.Text = msg;
        _statusTimer.Stop();
        _statusTimer.Start();
    }
}
