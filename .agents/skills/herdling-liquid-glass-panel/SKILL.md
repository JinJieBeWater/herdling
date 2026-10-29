---
name: herdling-liquid-glass-panel
description: "Native Herdling panel verification. Use for Liquid Glass edge artifacts, hover captures, or overlay scrollbar fading and drag issues; not general macOS development or Settings."
---

# Herdling 面板验收

## 流程

1. 以下路径均相对仓库根目录。先读 `docs/ui.md`；取值查 `Sources/Herdling/DesignSystem/Theme.swift`，玻璃实现查 `Sources/Herdling/DesignSystem/PanelChrome.swift`，窗口状态查 `Sources/Herdling/StatusItemController.swift`。按当前规范验收，不从历史截图恢复样式。
2. 原生输入放在隔离桌面与自有 fixture 中，复用 `Tests/HerdlingTests/PreviewFixtures.swift` 的无后端、独立偏好设置。真实桌面玻璃对照另行获准后再做；仅浏览，不点击定位项、发送 Enter 或改用户偏好。
3. 验收应用包时，通过 LaunchServices 启动自有测试 bundle 并核对 PID；若会复用用户正在运行的实例，返回隔离 fixture，不重跑二进制或重启该实例。按自有 PID 和最新 bounds 筛选窗口，排除 tooltip，坐标从当前窗口推导。
4. 等折叠动画和窗口 bounds 稳定后再测量。独立 fixture 的初次 fittingSize 可能只有折叠高度；完整高度取当前 `PanelContentHeightKey` 的布局结果。记录 OS、appearance、key/active 状态、实际指针位置和位图比例。锁屏或激活失败时停止输入验收。
5. 截图存入新的 `.build/` 子目录；配对保存窗口图与带外边距的屏幕图。交互式截图可能改变焦点；离屏图不证明真实玻璃效果。对照保持相同尺寸、底图和逻辑比例，每次只改一个变量。

## 玻璃边缘

- **方形外框**：先比较 key/non-key、玻璃/非玻璃状态，区分内容与玻璃绘制问题；检查 `PanelChrome.swift` 的玻璃根层裁剪。截图时失焦可能隐藏症状，不能据此宣布修复。保留键盘能力，并在调整窗口高度后复验。
- **圆形明暗边**：与方形外框分开排查。在新建自有窗口中分别对照 shadow、tint 与底图；去掉阴影曾在 macOS 27 的暗色对照中减轻边线，但不是通用修复或改产品阴影的授权。

## 悬停与字形

- 移动指针和截图在同一次自动化操作中完成，检查真实高亮像素，而非只记录目标坐标；指针漂移、面板隐藏或窗口失焦的样本作废。独立控件的 hover 成功不替代完整玻璃面板验收。
- 合成 Control-click 后，给后续普通 CGEvent 显式清空 modifiers；残留 Control 曾使 Escape/Return 透传，伪装成选择故障。
- 比较字形前统一位图逻辑比例；槽位间距不等于墨迹间距。透明渲染探针若含选择底色，先在 `backgroundAlpha < 1` 时用 `(compositeAlpha - backgroundAlpha) / (1 - backgroundAlpha)` 去除底色，再比较 glyph alpha；屏幕截图不能直接套这个公式。

## 滚动条

- 实现入口是 `Sources/Herdling/DesignSystem/RosterScrollbar.swift`。`NSScroller.alphaValue == 1` 不证明 thumb 可见：AppKit 会单独淡出其绘制。用实际像素检查显隐；普通窗口的 hover reveal 与玻璃面板可能不同。
- 物理滚轮探针先记录收到的 `NSEvent.scrollingDeltaY` 和内容 offset；自然滚动偏好可能翻转合成事件方向。向上滚但已在顶部的零位移不能证明路由失效。验收后恢复原滚动位置。

## 完成

按涉及行为选择现存的 `NavigationBrowserTests` 或 `RosterScrollbarTests`，命令入口查 `README.md`。交付截图路径、复现状态、对照结论与未覆盖项；无原生证据时明确标为未验证，不用测试通过代替视觉结论。
