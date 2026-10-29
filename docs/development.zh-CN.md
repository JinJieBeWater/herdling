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
- 通过 Herdr Socket 事件流同步本机与远程 Session；必要时使用发现机制和 CLI fallback。
- 在设置中选择 Ghostty 或 Kero，偏好会记住。复用所选终端内匹配的 Herdr client，没有时新建并验证。Ghostty 保留 Tab/Window 设置，Kero 新建 Session。
- 支持登录时启动、键盘操作、VoiceOver 标签、浅色/深色外观和“减少动态效果”。

Herdling 通过 `HERDR_BIN_PATH` 或常见 Homebrew/系统路径查找 `herdr`，通过 `KERO_BIN_PATH`、常见 Homebrew 路径或 Kero app bundle 查找 `kero`。远程命令通过目标主机的 login shell 执行。

设置只检查所选终端。Kero 不使用 Tab/Window 设置。Debug 构建不启动更新器。

## 远程主机

Herdling 使用 `~/.ssh/config` 中命名的 `Host` 条目，忽略通配符和否定条目。每台启用的主机必须：

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
- 本机与远程 monitor 为每个 Herdr Session 维护一条 NDJSON Socket 流。
- 定期发现新增或删除的 Session；事件流不可用时保留 CLI polling fallback。
- Ghostty 将原生 AppleScript `tty` 与 Herdr client 进程精确匹配，再聚焦稳定 terminal ID；不再修改终端标题或保存终端映射。Kero 通过 `kero ls --json`、pane 进程关系和 `kero focus` 定位，新建时使用 `kero new`。两者只复用并验证各自的 client，不会回退到另一终端。

## 排障

- **没有本机 Session：** 确认新 shell 中可以执行 `herdr session list --json`。如果 Herdr 安装在其他位置，请设置 `HERDR_BIN_PATH`。
- **SSH Source 一直离线：** 执行上面的 BatchMode 命令。修复 host key、认证、远程 `PATH` 或缺失的 `nc` 后重试。
- **Kero 无法打开或聚焦：** 打开 Kero 并检查 `kero ls --json`。如果安装在其他位置，请设置 `KERO_BIN_PATH`。新 client 启动失败时检查 Herdr 和 SSH 后再重试；失败的 Session 不会自动删除。
- **Ghostty 无法打开或聚焦：** 前往 **系统设置 → 隐私与安全性 → 自动化**，允许 Herdling 控制 Ghostty。
- **无法启用登录时启动：** 从 `.build/Herdling.app` 或其他 app bundle 运行 Herdling，不要使用 `swift run`。
