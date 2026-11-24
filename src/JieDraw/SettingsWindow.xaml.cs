using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace JieDraw;

/// <summary>
/// 设置窗口（v0.2：热键自定义）。捕获框接管 PreviewKeyDown，
/// 用户直接按下组合键即完成输入；保存时校验格式并要求至少一个修饰键。
/// </summary>
public partial class SettingsWindow : Window
{
    private string? _captured;

    /// <summary>用户最终确认的设置（DialogResult=true 时有效；Hotkey 空串=停用）。</summary>
    public string NewHotkey { get; private set; } = "";
    public bool AutoStartNew { get; private set; }
    public string SaveDirNew { get; private set; } = "";
    public bool TransparentNew { get; private set; }
    public bool WakeNew { get; private set; }

    public SettingsWindow(AppSettings s)
    {
        InitializeComponent();
        NewHotkey = s.Hotkey;
        SaveDirNew = s.SaveDir;
        HotkeyBox.Text = s.Hotkey;
        SaveDirBox.Text = s.SaveDir;
        ChkTransparent.IsChecked = s.TransparentExport;
        ChkAutoStart.IsChecked = AutoStartHelper.IsEnabled();
        ChkWake.IsChecked = s.WakeHotkey;
        VersionText.Text = "捷画 JieDraw v" +
            (System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "?");
        // 不自动聚焦捕获框：热键配置是可选项，打开设置≠必须配置
    }

    private void BrowseSaveDir_Click(object sender, RoutedEventArgs e)
    {
        // using System.Windows.Forms 的对话框；WPF STA 线程可直接使用
        using var dlg = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "选择捷画的图片保存目录（留空则使用 图片\\JieDraw）",
            ShowNewFolderButton = true
        };
        if (dlg.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            SaveDirBox.Text = dlg.SelectedPath;
    }

    private void HotkeyBox_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        e.Handled = true; // 捕获框内一切按键都被接管，不可打字

        var key = e.Key == Key.System ? e.SystemKey : e.Key; // Alt 组合键走 SystemKey
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
                 or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
            return; // 纯修饰键按下：等主键

        if (key == Key.Escape) { Close(); return; }   // Esc = 取消设置
        if (key == Key.Enter) { Ok_Click(sender, e); return; }

        // 组合：Keyboard.Modifiers 反映当前按住的修饰键
        var spec = ModifierSpec(Keyboard.Modifiers) + key.ToString();
        _captured = spec;
        HotkeyBox.Text = spec;
        ErrorText.Text = "";
    }

    private static string ModifierSpec(ModifierKeys m)
    {
        var s = "";
        if (m.HasFlag(ModifierKeys.Control)) s += "Ctrl+";
        if (m.HasFlag(ModifierKeys.Alt)) s += "Alt+";
        if (m.HasFlag(ModifierKeys.Shift)) s += "Shift+";
        if (m.HasFlag(ModifierKeys.Windows)) s += "Win+";
        return s;
    }

    private void Ok_Click(object? sender, RoutedEventArgs e)
    {
        var spec = _captured ?? HotkeyBox.Text.Trim();
        AutoStartNew = ChkAutoStart.IsChecked == true;
        SaveDirNew = SaveDirBox.Text.Trim();
        TransparentNew = ChkTransparent.IsChecked == true;
        WakeNew = ChkWake.IsChecked == true;

        // 清空保存 = 停用全局热键（不强制配置，之后仍可从托盘/⚙ 重新开启）
        if (string.IsNullOrEmpty(spec))
        {
            NewHotkey = "";
            DialogResult = true;
            Close();
            return;
        }

        if (!spec.Contains('+'))
        {
            ErrorText.Text = "热键需包含 Alt / Ctrl / Shift / Win 中至少一个修饰键（否则会吞掉单键输入）";
            return;
        }
        if (!HotkeyService.TryParse(spec, out _, out _))
        {
            ErrorText.Text = $"无法识别热键 \"{spec}\"，请重按组合键";
            return;
        }

        NewHotkey = spec;
        DialogResult = true;
        Close();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();
}
