# 捷画 JieDraw

按一个全局快捷键，秒开画板，随手画，秒收起。常驻托盘、轻量、快速。
v0.3：草稿自动保存、屏幕批注层、截图进画布、置顶开关、透明导出、开机自启、安装/卸载脚本。

> 详见 [开发文档.md](./开发文档.md)

## 快捷键

| 快捷键 | 作用 |
|---|---|
| `Alt+Q`（默认，可在设置中修改或停用） | 全局 显示/隐藏 画板（应用运行中） |
| `Ctrl+Alt+Q` | **快捷键唤醒**：应用没运行时按下 → Windows 直接启动捷画并弹出画板（开机不自启也能用） |
| `Esc` | 收起画板（笔迹保留） |
| `Ctrl+S` | 保存 PNG 到 `图片\JieDraw\` |
| `Ctrl+Z` / `Ctrl+Y` | 撤销 / 重做（Ctrl+Shift+Z 亦可重做） |
| `Ctrl+C` / `Ctrl+V` | 复制（有选中=选中笔迹，否则整画布）/ 粘贴笔迹或**系统图片** |
| `Ctrl+1/2/3/4/5/6` | 切换 笔 / 荧光笔 / 橡皮 / 框选 / 点选 / 套索 |
| `F11` | 全屏 ↔ 还原（也可双击工具栏空白处或点 □ 按钮） |
| 滚轮（光标在画布上） | 循环切换粗细档位 |

托盘：**左键单击**唤起/收起画板，右键菜单（屏幕批注/设置/退出）；重复双击 exe 会激活已运行的实例。**草稿每 2.5s 自动保存**（崩溃也不丢）、窗口位置/大小/全屏状态记忆。

## 构建与运行

```bash
cd src/JieDraw
dotnet build -c Release
./bin/Release/net8.0-windows/JieDraw.exe   # 启动后常驻托盘，按 Alt+Q 唤起
```

## 屏幕批注（v0.3）

工具栏 ✏ 或托盘「屏幕批注」：整个屏幕变成画布，直接在屏幕上画。工具条上「穿透」一键切换——穿透时操作下层应用，绘制时在屏幕涂鸦；「整屏截图」把屏幕+墨迹存成 PNG；Esc 或 ✕ 退出。

## 设置

点工具栏 **⚙** 或托盘右键 **设置…**：

- **唤起热键**（可选）：点击输入框后直接按下新组合键即改；**清空并保存 = 停用全局热键**（之后托盘双击唤起）；新键被占用自动回滚，即时生效免重启
- **开机自动启动**（默认关）：勾选即写入注册表（HKCU `...\Run`），登录后常驻托盘
- **快捷键唤醒**（默认开，推荐）：开机不自启也不丢快捷键——未运行时按 `Ctrl+Alt+Q` 由系统启动捷画并弹出画板（冷启动 1~2 秒）；运行中仍用应用内热键秒开。写入开始菜单快捷方式，exe 挪位自动修正
- **保存目录**：浏览… 选择（留空 = `图片\JieDraw`）
- **透明背景 PNG**：导出带透明通道（部分聊天工具粘贴会显示黑底，按需开关）

也可手改 `%APPDATA%\JieDraw\settings.json`（`"Hotkey": ""` 即停用）后重启，完整字段示例：

```json
{
  "Hotkey": "Alt+Q",
  "PenColor": "#1A1A1A",
  "PenSize": 4,
  "Topmost": true,
  "SaveDir": "",
  "TransparentExport": false,
  "UpdateUrl": "",
  "WinLeft": 133.3, "WinTop": 100.0,
  "WinWidth": 666.7, "WinHeight": 466.7,
  "WinMaximized": false
}
```

## 安装 / 分发

```powershell
# per-user 安装（免管理员）：复制到 %LOCALAPPDATA%\JieDraw + 快捷方式
powershell -ExecutionPolicy Bypass -File installer\install.ps1 -Launch
# 需要开机自启时加 -AutoStart；卸载：
powershell -ExecutionPolicy Bypass -File installer\uninstall.ps1

# 便携包：dist\JieDraw-0.3.0-portable.zip（解压即用）
```

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File test\smoke-test.ps1          # 显隐/画线管线
powershell -ExecutionPolicy Bypass -File test\uia-test.ps1           # 保存/复制（锁屏可用）
powershell -ExecutionPolicy Bypass -File test\uia-settings-test.ps1  # 设置/停用热键/✕退出
powershell -ExecutionPolicy Bypass -File test\uia-v02-test.ps1       # 全屏/荧光笔/位置记忆/自启
powershell -ExecutionPolicy Bypass -File test\uia-undo-test.ps1     # 画线→撤销→重做（需解锁）
powershell -ExecutionPolicy Bypass -File test\uia-select-paste-test.ps1  # 选择工具/复制粘贴（需解锁）
powershell -ExecutionPolicy Bypass -File test\t1-test.ps1           # 草稿持久化/Del/日志轮转/保存目录
powershell -ExecutionPolicy Bypass -File test\t2-test.ps1           # 置顶/透明导出/截图联动
powershell -ExecutionPolicy Bypass -File test\t3-test.ps1           # 屏幕批注层/安装卸载/更新检查
powershell -ExecutionPolicy Bypass -File test\t4-test.ps1           # 优化项：草稿自动存/单实例激活/滚轮/自愈/贴图
powershell -ExecutionPolicy Bypass -File test\t5-test.ps1           # 快捷键唤醒：.lnk/冷启动/开关（锁屏可用）
powershell -ExecutionPolicy Bypass -File test\e2e-test.ps1           # 真实按键全链路（需解锁）
```
