# 开发与排障

[English](development.md) | [简体中文](development.zh-CN.md) · [返回 Herdling](../README.zh-CN.md)

## 从源码构建

需要 macOS 15 或更高版本，以及 Xcode 26.2 或更高版本（含 Swift 6.2 或更新工具链）。只有 Command Line Tools 不够。

```bash
git clone https://github.com/JinJieBeWater/herdling.git
cd herdling
bash scripts/build-app.sh release
open .build/Herdling.app
```

脚本会在 `.build/Herdling.app` 生成使用 ad-hoc 签名的 Universal2 应用，包含完整 Sparkle 运行时。启用登录时启动前，请将应用移动到 `/Applications` 等固定位置。

开发构建：

```bash
bash scripts/build-app.sh
open .build/Herdling.app
```

## 运行行为

- 浏览期间行位置固定、状态实时更新；重新打开重建名单，失败定位保留原目标以便重试。
- 同时监控旧版 Herdr 和 Herdr Core。旧版本机与远程 Session 通过 Socket 事件流同步，必要时使用发现机制和 CLI fallback；Core 使用独立的 Socket 连接和 machine 目录。
- 在设置中为旧版 Herdr 选择 Ghostty 或 Kero，复用匹配 client，没有时新建并验证。Core 固定通过原生 Herdr App 聚焦 pane、将 App 置前，不受该偏好影响；失败时不自动改用另一个应用。
- 支持登录时启动、键盘操作、VoiceOver 标签、浅色/深色外观和“减少动态效果”。

Herdling 通过 `HERDR_BIN_PATH` 或常见 Homebrew/系统路径查找 `herdr`，通过 `KERO_BIN_PATH`、常见 Homebrew 路径或 Kero app bundle 查找 `kero`。远程命令通过目标主机的 login shell 执行。

设置只检查所选终端。Kero 不使用 Tab/Window 设置。Debug 构建不启动更新器。

## 运行时边界

旧版 Herdr 和 Core 各自保留身份、连接与健康状态。未使用的运行时没有启动，不会让另一套显示为离线。同名、相同目录或相同短终端 ID，不会把不同运行时或不同 Core 的目标合并。Core 终端归属于运行它的 Core；当前 machine 地址只是访问路线，不是全局唯一身份。

Sources 保留旧版 Session/Space/worktree 目录，并在设备下列出 Core 终端，不虚构 Session 或 Main worktree。Core Activity 使用 Herdr App 状态；没有 App 状态的终端保留在 Sources。同一终端即使带有多条 Core 状态记录，也只列一项。缺失或未知报告不等于 idle，终端进程结束也不等于 agent done。

Core 原始报告与 Herdr App 结合 seen 得出的 Done/Idle 不同。Core 状态通过 `events.subscribe` 接收；App 的已查看变化由 macOS 文件系统通知监听 `view.json`，收到通知后再从 App 控制接口读取权威状态。跳转后及 Core 变化时也会读取，没有 App 状态轮询定时器。直接在 App 中查看终端也能同步，不依赖 Core 状态事件。不会仅凭点击就清除提示，也不另建未读队列。App 无法验证或读取时，Core Activity 暂不显示；Core 原生目录仍保留在 Sources。

文件监听只用来触发刷新，支持原子替换，不从文件内容推断 agent 状态。`view.json` 是 App 0.1.10 的内部持久化文件，并非公开事件 API；上游变更或 App 保存失败可能导致通知缺失。重新打开 Herdling 会重新读取初始快照。详见[源码调查](herdr-app-seen-events.md)。

观测只连接已有的 Core 和 App 端点，不启动任何一个。用户明确点击 Core 目标时可以启动 Herdr App，App 自身启动流程可能启动 Core。Herdling 不在 Ghostty 或 Kero 中为 Core 执行 attach。

Herdr App 控制端点是 `$HERDR_APP_HOME/herdr-app.sock`，默认为 `~/.config/herdr-app/herdr-app.sock`。App 0.1.10 的 IPC 不提供 CoreID，因此通过原生 socket peer PID，以及 App 直接启动的 Core connector 与所选 Core server 的实际 Unix socket 链接确认绑定，不能只匹配短终端 ID 或配置路径。跳转验证 Core 目标、聚焦已有 App pane、将 App 置前，并回读 space/tab/pane/terminal 与真正的前台应用。

端点发现遵循 `HC_SOCKET`、`HC_SESSION`、XDG 路径和 Core 顶层 `socket` 设置。配置读取支持单行引号字符串；不支持的 TOML 形式需显式设置 `HC_SOCKET`。首次排序使用 Core 状态时间；App 不提供时间戳，后续 App 状态转换使用观测时间，相同快照不会不断刷新 idle 新近程度。机器健康最多滞后一次 15 秒的本地刷新间隔。

Core 定位沿用 [App 0.1.10](https://github.com/herdrdev/herdr-app/tree/v0.1.10) 自身的 `pane.focus` 与 seen 行为。没有已有 App pane 的终端会明确失败，不替后台 worker 改标签、创建 pane 或切换布局。App 未公开实际渲染的可见性树；刻意隐藏或自定义布局仍遵循 App 自身行为，不由 Herdling 另造可见性规则。

## 远程主机

**SSH Sources 只控制旧版 Herdr。** 修改这些选择不会增删或断开 Core machine。Core 沿用自身已配置的 machine，请通过 Core 自身的工具管理。

对于旧版 Session，Herdling 使用 `~/.ssh/config` 中命名的 `Host` 条目，忽略通配符和否定条目。每台启用的主机必须：

- 无需交互式密码提示即可连接；
- 能通过 login shell 找到 `herdr`；
- 提供支持 Unix domain socket 的 `nc`。

启用前先检查连接：

```bash
ssh -o BatchMode=yes my-server '$SHELL -lc "herdr session list --json"'
```

## 测试

运行测试：

```bash
bash scripts/test-build-app.sh
swift test --no-parallel
```

## 发版

`.github/workflows/release.yml` 在推送 `main`、向 `main` 提交 PR 或手动运行时，测试、构建并验证一个 Universal2 应用，上传应用 ZIP 到 Actions artifacts，不发布 Release。macOS runner 显式选择 Xcode 26.2，以使用 Swift 6.2 和 macOS 26 API。Intel 部分做交叉编译、架构、签名和可搬移依赖检查，CI 不在 Intel Mac 上执行它。

CI 运行全部自动化测试和打包失败回归。发布工具使用临时密钥实际生成并验证 feed 和归档，检查 tag、密钥与版本错误，并拒绝内容被修改的归档和 feed。PR 构建拿不到生产签名密钥。不运行像素或 OCR 检查；真实升级和终端定位使用隔离桌面验收。

维护者需配置仓库 secret **`SPARKLE_PRIVATE_KEY`**，内容为 Sparkle 官方 `generate_keys` 导出的私钥 seed；对应公钥必须与 `Resources/Info.plist` 的 `SUPublicEDKey` 一致。`scripts/fetch-sparkle-tools.sh` 用版本和 SHA-256 固定官方工具。本仓库密钥保存在维护者 Keychain 的 `dev.herdr.Herdling` account 下，应在仓库外另做安全备份；不要提交私钥，也不要把它上传为 artifact。此发布路径不使用 Apple 证书或公证凭据。

发布时，先将 `Resources/Info.plist` 的 `CFBundleShortVersionString` 设为发行版本，后续版本同时递增 `CFBundleVersion`。提交并推送改动（包括工作流），再给该提交打 Tag：

```bash
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
git tag -a "v$version" -m "Herdling $version"
git push origin "v$version"
```

Tag 必须为 `v<CFBundleShortVersionString>`，发行版本和 build 都必须大于最新 Release。串行的 macOS 发布 job 还原已验证应用、生成发行说明，再由 `scripts/prepare-release.sh` 在 `.build/release` 生成 ZIP、校验文件和签名 `appcast.xml`。三份资产全部上传到 draft 并核对名称、大小后，才发布为 Latest。缺密钥或检查失败就停止，不降级发布未签名包。不要提前手动创建 Release，也不要移动已发布的 Tag；修正发行版时使用新版本号。

固定 feed 为 `https://github.com/JinJieBeWater/herdling/releases/latest/download/appcast.xml`。每个 feed 仅包含当次发行版，指向带 tag 的不可变 ZIP 地址；没有分架构 feed、旧包同步或差分更新。

## 架构

- AppKit 管理 `NSStatusItem` 和非激活式 `NSPanel`；SwiftUI 渲染面板内容。
- 旧版本机与远程 monitor 为每个 Herdr Session 维护一条 NDJSON Socket 流。定期发现新增或删除的 Session，事件流不可用时保留 CLI polling fallback。
- Core 使用独立的生命周期/machine monitor 与终端目录。身份由所属 Core ID 和原生终端 ID 共同确定；独立的原生 App 观测提供派生活动状态与定位路径。
- Ghostty 将原生 AppleScript `tty` 与旧版 client 进程匹配，再聚焦稳定 terminal ID；不改标题或保存映射。Kero 通过 `kero ls --json`、pane 进程关系和 `kero focus` 定位，使用 `kero new` 新建旧版 client。两者均不处理 Core 目标。

## 排障

- **没有旧版本机 Session：** 确认新 shell 中可以执行 `herdr session list --json`。如果旧版 Herdr 安装在其他位置，请设置 `HERDR_BIN_PATH`。
- **旧版 SSH Source 一直离线：** 执行上面的 BatchMode 命令。修复 host key、认证、远程 `PATH` 或缺失的 `nc` 后重试。
- **Core 来源不可用：** 检查想监控的 Core 是否已运行，以及它的 machine 是否已连接。旧版 SSH Sources 选择不能修复 Core 连接。没有状态报告的终端列在 Sources，因此 Activity 为空本身不代表 Core 离线。
- **Core 状态或定位不可用：** 打开连接到同一 Core 的 Herdr App，检查 `herdr-app ls` / `herdr-app status`；目标需要已有 App pane。App 连接不同 Core、原生绑定不可读或缺少 pane 都应报错，不转而打开 Kero。非默认 App profile 还需检查 `HERDR_APP_HOME`。
- **Kero 无法打开或聚焦：** 打开 Kero 并检查 `kero ls --json`。如果安装在其他位置，请设置 `KERO_BIN_PATH`。检查旧版 Herdr 连接后重试；失败的 Session 不会自动删除。
- **Ghostty 无法打开或聚焦：** 前往 **系统设置 → 隐私与安全性 → 自动化**，允许 Herdling 控制 Ghostty。
- **无法启用登录时启动：** 从 `.build/Herdling.app` 或其他 app bundle 运行 Herdling，不要使用 `swift run`。
