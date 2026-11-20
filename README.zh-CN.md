# VLC RT Marker（中文）

**在 VLC 里用两个键记住播放位置、随手跳回。**

按 <kbd>R</kbd> 记住当前位置，按 <kbd>T</kbd> 跳回去。换文件自动清空保存点，不会跳到上一条视频里。

```
R  →  保存  (0:09.501)
T  →  跳转  (0:09.501)
```

不装服务、不建计划任务、不改注册表、不需要管理员权限，也没有常驻托盘程序。

[English](README.md)

---

## 为什么需要它

VLC 3 本身没有"标记 + 回跳"的快捷键：

- **扩展**（视图 → 扩展）没有键盘 API，能挂的回调只有
  `activate / deactivate / menu / trigger_menu / input_changed / meta_changed / playing_changed`，
  既没有按键事件也没有定时器。
- **偏好设置 → 热键** 是封闭的内置动作清单，插件动作进不去。
- 内置的**播放列表书签**（`Ctrl+F1` / `F1`）是整场会话共享的内存值、不按文件区分，
  而且在 3.0.23 上实测没有响应。

所以按键必须来自 VLC 之外，而"读时间 / 跳转"这部分留在 VLC 内。

## 环境要求

| | |
|---|---|
| 系统 | Windows 10 / 11 (x64) |
| VLC | **3.x**，实测 **3.0.23 / 3.0.24**；VLC 4.x **不支持** |
| PowerShell | 5.1（系统自带），不需要额外模块 |
| 权限 | 不需要管理员，全部写在 `%APPDATA%` 下 |

兼容性：

| 环境 | 状态 |
|---|---|
| Windows 11 | 已验证 |
| Windows 10 | 预期可用，维护者未实测 |
| VLC 3.0.23 | **已验证**（开发环境） |
| VLC 3.0.24 | **已验证**（从 3.0.23 原地升级，配置沿用） |
| 其他 VLC 3.x | 预期可用（`vlc.net` / `vlc.var` / `vlc.input` 在 3.x 内稳定） |
| VLC 4.x | **不支持** |
| 便携版 VLC | 手动配置，见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |

## 安装

1. 下载 Release 包（或 clone 本仓库）。
2. **先手动打开一次 VLC 再关掉** —— 这会生成 `%APPDATA%\vlc\vlcrc`。
3. 执行：

   ```powershell
   powershell -ExecutionPolicy Bypass -File installer\install.ps1
   ```

4. 打开 VLC 播放任意文件，按 <kbd>R</kbd> 再按 <kbd>T</kbd>。

安装脚本会把"写了哪些文件、改了哪几个 vlcrc 键"全部打印出来，并在 `vlcrc` 旁边留一份带时间戳的备份。

## 使用

| 按键 | 作用 |
|---|---|
| <kbd>R</kbd> | 保存当前位置（覆盖上一次） |
| <kbd>T</kbd> | 跳回保存点；没有保存点时不动作，只写日志 |

**只有 VLC 是前台窗口时**按键才生效，所以在别的程序里打 R / T 不会误触。

## 配置

`%APPDATA%\vlc\rt-marker\keys.json`

```json
{
  "save": "R",
  "jump": "T",
  "tips": false
}
```

- `save` / `jump`：`A`–`Z`、`0`–`9`、`F1`–`F12`、`NUMPAD0`–`NUMPAD9`、`SPACE`、`ENTER`、`TAB`、
  `BACKSPACE`、`CAPSLOCK`、`INSERT`、`DELETE`、`HOME`、`END`、`PAGEUP`、`PAGEDOWN`、方向键，
  以及 `; / \ [ ] ' , . - =`
- `tips`：`false` 只写日志；`true` 额外弹托盘气泡

`%APPDATA%\vlc\rt-marker\port.txt` 是本地控制端口（默认 `4212`）。端口被占用时用
`install.ps1 -Port <端口>` 改。

改完这两个文件都要重启 VLC。

## 日志

```
%TEMP%\vlc-rt-marker.log    守护进程：按键、保存、跳转、连接状态
%TEMP%\rt-rc.log            Lua 侧：收到的命令、换片事件、监听状态
```

## 工作原理

```
VLC（vlcrc: extraintf=luaintf, lua-intf=rt-rc）
 └─ rt-rc.lua  随 VLC 启动运行
      ├─ 监听 127.0.0.1:4212（vlc.net.listen_tcp + accept/poll/recv）
      ├─ 提供 get_time / get_length / seek <秒> / status / play_next / add
      └─ 监听成功后，拉起隐藏的守护进程

vlc-rt-marker.ps1  隐藏窗口的 PowerShell
      ├─ GetAsyncKeyState 轮询 R/T（仅在 vlc.exe 为前台时动作）
      ├─ 向 Lua 服务端要位置、发跳转
      └─ vlc.exe 消失约 8 秒后自行退出
```

VLC 3 只能加载**一个** `extraintf` 模块，所以让 Lua 接口占用这个槽位，
并在里面实现守护进程需要的那几条 RC 命令。完整推导、失败路径和 API 验证记录见
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File installer\uninstall.ps1
```

停止守护、删除本项目安装的文件，并且**只**还原 `vlcrc` 里的 `extraintf` 和 `lua-intf`，
其余 VLC 设置（包括你自己改过的）一律不动。

## 安全与隐私

见 [SECURITY.md](SECURITY.md)。一句话：只监听回环地址、不联网、不上报、不开机自启、
不装服务、不改注册表、不申请管理员；辅助进程只在 VLC 运行期间存在。

## 目录结构

```
src/          rt-rc.lua · vlc-rt-marker.ps1 · rt-launch.vbs · keys.json
installer/    install.ps1 · uninstall.ps1 · selftest.ps1
docs/         ARCHITECTURE.md · TROUBLESHOOTING.md · AUDIT.md
.github/      Issue 模板 · 语法检查工作流
```

## 许可证

MIT，见 [LICENSE](LICENSE)。
