# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling 是 [Herdr](https://herdr.dev/) 的 macOS 菜单栏配套工具。它展示本机与 SSH 主机上的 Herdr agent、同步状态，并在 [Ghostty](https://ghostty.org/) 中打开所选 Session。

## 功能

- 按设备、Session、Space 和 worktree 分组 agent，并保留 Herdr 原始顺序。
- 在 **Recent** 中显示 blocked、done、working 和近期 idle 的 agent。idle 项保留 10 分钟。
- 通过 Herdr Socket 事件流同步本机与远程 Session；必要时使用发现机制和 CLI fallback。
- 尽量复用现有 Ghostty Herdr client。新 client 默认在 Tab 中打开，也可在设置中改为 Window。
- 读取 `~/.ssh/config` 中的 SSH 主机，包括 `Include` 文件。
- 支持登录时启动、键盘快捷键、VoiceOver 标签、浅色/深色外观和“减少动态效果”。

## 环境要求

- macOS 14 或更高版本
- Swift 6.2 工具链
- 本机和每台启用的 SSH 主机都已安装 [Herdr](https://herdr.dev/)
- 已安装 [Ghostty](https://ghostty.org/)，用于打开和聚焦 Session
- 远程主机支持密钥认证或其他非交互式 SSH 登录方式

Herdling 通过 `HERDR_BIN_PATH` 或常见 Homebrew/系统路径查找 `herdr`。远程命令通过目标主机的 login shell 执行。

## 构建与运行

项目暂未提供经过签名和公证的二进制发行版。请从源码构建：

```bash
git clone https://github.com/JinJieBeWater/herdling.git
cd herdling
bash scripts/build-app.sh release
open .build/Herdling.app
```

脚本会在 `.build/Herdling.app` 生成使用 ad-hoc 签名的应用。启用登录时启动前，请将应用移动到 `/Applications` 等固定位置。

开发构建：

```bash
bash scripts/build-app.sh
open .build/Herdling.app
```

## 配置

1. 启动至少一个 Herdr Session。
2. 从菜单栏打开 Herdling。
3. 按 `⌘,` 或右键点击菜单栏项目，打开 **Settings**。
4. 在 **SSH Sources** 中启用需要的 SSH alias。
5. 选择新的 Ghostty client 使用 Tab 还是 Window。

首次操作 Ghostty 时，macOS 可能请求自动化权限。权限状态会显示在 Settings 中。

### 远程主机

Herdling 使用 `~/.ssh/config` 中命名的 `Host` 条目，忽略通配符和否定条目。每台启用的主机必须：

- 无需交互式密码提示即可连接；
- 能通过 login shell 找到 `herdr`；
- 提供支持 Unix domain socket 的 `nc`。

启用前先检查连接：

```bash
ssh -o BatchMode=yes my-server '$SHELL -lc "herdr session list --json"'
```

## 操作

| 操作 | 结果 |
| --- | --- |
| 左键点击菜单栏项目 | 打开或关闭 agent 列表 |
| 右键点击菜单栏项目 | 打开 Settings/Quit 菜单 |
| 点击 Recent 或设备 | 展开该区段并收起此前区段 |
| 点击 agent、worktree、Space 或 Session | 在 Ghostty 中聚焦目标 |
| `⌘,` | 打开 Settings |
| `Esc` | 从 Settings 返回，再次按下关闭面板 |
| `⌘Q` | 退出 Herdling |

## 开发

运行测试：

```bash
swift test
```

将 warning 视为 error：

```bash
swift test -Xswiftc -warnings-as-errors
```

构建 release 应用：

```bash
bash scripts/build-app.sh release
```

### 架构

- AppKit 管理 `NSStatusItem` 和非激活式 `NSPanel`；SwiftUI 渲染面板内容。
- 本机与远程 monitor 为每个 Herdr Session 维护一条 NDJSON Socket 流。
- 定期发现新增或删除的 Session；事件流不可用时保留 CLI polling fallback。
- Ghostty 激活逻辑使用 AppleScript，并验证 terminal/process，复用正确 client，避免重复创建 Tab 或 Window。

## 排障

- **没有本机 Session：** 确认新 shell 中可以执行 `herdr session list --json`。如果 Herdr 安装在其他位置，请设置 `HERDR_BIN_PATH`。
- **SSH Source 一直离线：** 执行上面的 BatchMode 命令。修复 host key、认证、远程 `PATH` 或缺失的 `nc` 后重试。
- **Ghostty 无法打开或聚焦：** 前往 **系统设置 → 隐私与安全性 → 自动化**，允许 Herdling 控制 Ghostty。
- **无法启用登录时启动：** 从 `.build/Herdling.app` 或其他 app bundle 运行 Herdling，不要使用 `swift run`。

## 许可

Herdling 项目本身目前尚未声明软件许可证。内置 Herdr 标志适用[第三方声明](Resources/THIRD_PARTY_NOTICES.md)以及随附的 [Apache License 2.0 全文](Resources/Herdr-LICENSE.txt)。
