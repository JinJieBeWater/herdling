# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling 是 [Herdr](https://herdr.dev/) 的 macOS 菜单栏配套工具。它展示本机与 SSH 主机上的 Herdr agent、同步状态，并在 [Ghostty](https://ghostty.org/) 或 [Kero](https://kero.sh/) 中打开所选 Session。

## 功能

- 按设备、Session、Space 和 worktree 分组 agent，并保留 Herdr 原始顺序。
- **Activity** 优先显示正常关注项，按 blocked、done、working、最近更新的三个 idle 排列。**Sources** 浏览完整目录，可展开一个来源，也可全部收起。
- 在 agent 的附加操作菜单中勾选 **Mute（静默）**，行使用更轻的标题与状态色，不新增徽标；Activity中该项立即移到普通项之后，取消时恢复普通优先级。鼠标操作不追滚，键盘焦点跟随原目标；真实状态、运行计数和定位能力保留，blocked／done不计入关注汇总。普通状态刷新不挪行，Sources层级不变；本机偏好会记住。
- 浏览期间行位置固定、状态实时更新；重新打开重建名单，失败定位保留原目标以便重试。
- 通过 Herdr Socket 事件流同步本机与远程 Session；必要时使用发现机制和 CLI fallback。
- 在设置中选择 Ghostty 或 Kero，偏好会记住。复用所选终端内匹配的 Herdr client，没有时新建并验证。Ghostty 保留 Tab/Window 设置，Kero 新建 Session。
- 读取 `~/.ssh/config` 中的 SSH 主机，包括 `Include` 文件。
- 支持登录时启动、键盘快捷键、VoiceOver 标签、浅色/深色外观和“减少动态效果”。

## 环境要求

- macOS 15 或更高版本
- Swift 6.2 工具链
- 本机和每台启用的 SSH 主机都已安装 [Herdr](https://herdr.dev/)
- 已安装 [Ghostty](https://ghostty.org/)，或 [Kero](https://kero.sh/) 及其 `kero` CLI，用于打开和聚焦 Session
- 远程主机支持密钥认证或其他非交互式 SSH 登录方式

Herdling 通过 `HERDR_BIN_PATH` 或常见 Homebrew/系统路径查找 `herdr`，通过 `KERO_BIN_PATH`、常见 Homebrew 路径或 Kero app bundle 查找 `kero`。远程命令通过目标主机的 login shell 执行。

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
5. 在 **Terminal → Application** 中选择 **Ghostty** 或 **Kero**。默认仍为 Ghostty；切换只影响后续定位，不改变已有终端 Session。
6. 可在 Settings 录制全局呼出快捷键，默认不设置组合。

Ghostty 使用 AppleScript 自动化，首次操作时按 macOS 提示授权；新 client 可选择 Tab 或 Window。Kero 使用原生 CLI，不需要自动化权限或 Tab/Window 设置。设置只检查所选终端。

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
| 右键点击菜单栏项目 | 打开 Refresh/Settings/Quit 菜单 |
| 右键点击 agent | 选中检查目标，打开固定角落的操作菜单；勾选／取消 Mute 不定位、不改变 seen |
| 点击 Sources 中的设备 | 展开或收起目录；展开一个来源时收起前一个 |
| 点击 agent、worktree、Space 或 Session | 在所选终端中聚焦目标 |
| 全局呼出快捷键（配置后） | 开关面板；预选目标但不直接定位 |
| `↑` / `↓` | 移动选择，不定位 |
| `Enter` | 定位选中目标；来源行只展开或收起目录 |
| Sources 中的 `←` / `→` | 返回父层，或收起 / 展开来源 |
| `Tab` / `Shift-Tab` | 在原生控件间移动焦点 |
| `⌘,` | 打开 Settings |
| 面板内按 `Esc` | 关闭面板 |
| `⌘Q` | 退出 Herdling |

Herdr 定位可能将目标 tab 的所有 pane 标为 seen，并影响同一 Session 的多个 shell client。定位失败也可能已改变焦点，不代表回滚，更不代表任务已处理。最近 idle 按 Herdr 的状态更新时间选取，不是导航历史。

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
- Ghostty 保留 AppleScript 与 terminal/process 验证。Kero 通过 `kero ls --json`、pane 进程关系和 `kero focus` 定位，新建时使用 `kero new`。两者只复用并验证各自的 client，不会回退到另一终端。

## 排障

- **没有本机 Session：** 确认新 shell 中可以执行 `herdr session list --json`。如果 Herdr 安装在其他位置，请设置 `HERDR_BIN_PATH`。
- **SSH Source 一直离线：** 执行上面的 BatchMode 命令。修复 host key、认证、远程 `PATH` 或缺失的 `nc` 后重试。
- **Kero 无法打开或聚焦：** 打开 Kero 并检查 `kero ls --json`。如果安装在其他位置，请设置 `KERO_BIN_PATH`。新 client 启动失败时检查 Herdr 和 SSH 后再重试；失败的 Session 不会自动删除。
- **Ghostty 无法打开或聚焦：** 前往 **系统设置 → 隐私与安全性 → 自动化**，允许 Herdling 控制 Ghostty。
- **无法启用登录时启动：** 从 `.build/Herdling.app` 或其他 app bundle 运行 Herdling，不要使用 `swift run`。

## 许可

Herdling 项目本身目前尚未声明软件许可证。内置 Herdr 标志适用[第三方声明](Resources/THIRD_PARTY_NOTICES.md)以及随附的 [Apache License 2.0 全文](Resources/Herdr-LICENSE.txt)。
