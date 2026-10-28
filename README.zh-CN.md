# Herdling

[English](README.md) | [简体中文](README.zh-CN.md)

Herdling 是 [Herdr](https://herdr.dev/) 的 macOS 菜单栏配套工具。它展示本机与 SSH 主机上的 Herdr agent、同步状态，并在 [Ghostty](https://ghostty.org/) 或 [Kero](https://kero.sh/) 中打开所选 Session。

## 功能

- 按设备、Session、Space 和 worktree 分组 agent，并保留 Herdr 原始顺序。
- **Activity** 按状态优先显示 agent：blocked、done、working、最近更新的三个 idle。**Sources** 浏览完整目录，可展开一个来源，也可全部收起。
- 浏览期间行位置固定、状态实时更新；重新打开重建名单，失败定位保留原目标以便重试。
- 通过 Herdr Socket 事件流同步本机与远程 Session；必要时使用发现机制和 CLI fallback。
- 在设置中选择 Ghostty 或 Kero，偏好会记住。复用所选终端内匹配的 Herdr client，没有时新建并验证。Ghostty 保留 Tab/Window 设置，Kero 新建 Session。
- 读取 `~/.ssh/config` 中的 SSH 主机，包括 `Include` 文件。
- 支持登录时启动、键盘快捷键、VoiceOver 标签、浅色/深色外观和“减少动态效果”。

## 环境要求

- macOS 15 或更高版本
- Xcode 26.2 或更高版本，包含 Swift 6.2 或更新工具链（仅从源码构建时需要；只有 Command Line Tools 不够）
- 本机和每台启用的 SSH 主机都已安装 [Herdr](https://herdr.dev/)
- 已安装 [Ghostty](https://ghostty.org/) 1.4.0 或更高版本，或 [Kero](https://kero.sh/) 及其 `kero` CLI，用于打开和聚焦 Session
- 远程主机支持密钥认证或其他非交互式 SSH 登录方式

Herdling 通过 `HERDR_BIN_PATH` 或常见 Homebrew/系统路径查找 `herdr`，通过 `KERO_BIN_PATH`、常见 Homebrew 路径或 Kero app bundle 查找 `kero`。远程命令通过目标主机的 login shell 执行。

## 构建与运行

在 [Releases](https://github.com/JinJieBeWater/herdling/releases) 查看二进制发行版：Apple Silicon 选择 `arm64`，Intel 选择 `x86_64`。解压后将 `Herdling.app` 移动到 `/Applications`。每个 ZIP 都有对应的 `.sha256` 文件，在下载目录执行 `shasum -a 256 -c <文件名>.zip.sha256` 即可校验。

发行版使用 ad-hoc 签名，没有 Apple Developer ID 证书，也未公证。macOS 可能拦截首次启动。尝试打开后，仅在信任下载来源时，前往 **系统设置 → 隐私与安全性 → 仍要打开** 放行。不要全局关闭 Gatekeeper。

从源码构建：

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

Ghostty 使用 AppleScript 自动化，首次操作时按 macOS 提示授权，并保持 `macos-applescript` 启用（默认值）；新 client 可选择 Tab 或 Window。Kero 使用原生 CLI，不需要自动化权限或 Tab/Window 设置。设置只检查所选终端。

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
| 点击 Sources 中的设备 | 展开或收起目录；展开一个来源时收起前一个 |
| 点击 agent、worktree、Space 或 Session | 在所选终端中聚焦目标 |
| 全局呼出快捷键（配置后） | 开关面板；预选目标但不直接定位 |
| `↑` / `↓` | 移动选择，不定位 |
| `Enter` | 定位选中目标；来源行只展开或收起目录 |
| Sources 中的 `←` / `→` | 返回父层，或收起 / 展开来源 |
| `Tab` / `Shift-Tab` | 在原生控件间移动焦点 |
| `⌘,` | 打开 Settings |
| Settings 中的 `⌘W` | 关闭 Settings 窗口 |
| 面板内按 `Esc` | 关闭面板 |
| `⌘Q` | 退出 Herdling |

Herdr 定位可能将目标 tab 的所有 pane 标为 seen，并影响同一 Session 的多个 shell client。定位失败也可能已改变焦点，不代表回滚，更不代表任务已处理。最近 idle 按 Herdr 的状态更新时间选取，不是导航历史。

## 开发

运行测试：

```bash
bash scripts/test-build-app.sh
swift test --no-parallel
```

构建 release 应用：

```bash
bash scripts/build-app.sh release
```

### 发版

`.github/workflows/release.yml` 在推送 `main`、向 `main` 提交 PR 或手动运行时，分别为 Apple Silicon 和 Intel 测试、构建并验证应用资源打包。这些运行只上传 ZIP 和 SHA-256 文件到 Actions artifacts，不发布 Release。工作流显式选择 Xcode 26.2，以使用 Swift 6.2 和 macOS 26 API。

CI 运行全部自动化测试，覆盖导航、会话状态、进程/Socket 失败与取消、偏好保存和打包，不再运行像素或 OCR 检查。视觉改动和真实终端定位需人工验收；GUI 自动化应使用隔离桌面。

发布时，先将 `Resources/Info.plist` 的 `CFBundleShortVersionString` 设为发行版本，后续版本同时递增 `CFBundleVersion`。提交并推送改动（包括工作流），再给该提交打 Tag：

```bash
git tag -a v0.1.0 -m 'Herdling 0.1.0'
git push origin v0.1.0
```

Tag 必须为 `v<CFBundleShortVersionString>`，不匹配会构建失败。两种架构都验证通过后，工作流自动创建 GitHub Release，附带两份 ZIP、校验文件和自动生成的发行说明。仅使用自动提供的 `GITHUB_TOKEN`，无需 Apple 证书或仓库 secrets。不要提前手动创建 Release，也不要移动已发布的 Tag；修正发行版时使用新版本号。

### 架构

- AppKit 管理 `NSStatusItem` 和非激活式 `NSPanel`；SwiftUI 渲染面板内容。
- 本机与远程 monitor 为每个 Herdr Session 维护一条 NDJSON Socket 流。
- 定期发现新增或删除的 Session；事件流不可用时保留 CLI polling fallback。
- Ghostty 将原生 AppleScript `tty` 与 Herdr client 进程精确匹配，再聚焦稳定 terminal ID；不再修改终端标题或保存终端映射。Kero 通过 `kero ls --json`、pane 进程关系和 `kero focus` 定位，新建时使用 `kero new`。两者只复用并验证各自的 client，不会回退到另一终端。

## 排障

- **没有本机 Session：** 确认新 shell 中可以执行 `herdr session list --json`。如果 Herdr 安装在其他位置，请设置 `HERDR_BIN_PATH`。
- **SSH Source 一直离线：** 执行上面的 BatchMode 命令。修复 host key、认证、远程 `PATH` 或缺失的 `nc` 后重试。
- **Kero 无法打开或聚焦：** 打开 Kero 并检查 `kero ls --json`。如果安装在其他位置，请设置 `KERO_BIN_PATH`。新 client 启动失败时检查 Herdr 和 SSH 后再重试；失败的 Session 不会自动删除。
- **Ghostty 无法打开或聚焦：** 前往 **系统设置 → 隐私与安全性 → 自动化**，允许 Herdling 控制 Ghostty。
- **无法启用登录时启动：** 从 `.build/Herdling.app` 或其他 app bundle 运行 Herdling，不要使用 `swift run`。

## 许可

Herdling 项目本身目前尚未声明软件许可证。内置 Herdr 标志适用[第三方声明](Resources/THIRD_PARTY_NOTICES.md)以及随附的 [Apache License 2.0 全文](Resources/Herdr-LICENSE.txt)。
