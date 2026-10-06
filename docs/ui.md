# UI & Design System

Herdling 的界面规范。设计语言来自 [Tinycast](https://tinycast.dev/)（`abue-ammar/tinycast`，AGPL-3.0）；本文档只描述**Herdling 自己的**取值与结构，两者同名但数值独立。

改任何 view body、`Theme` 取值或面板外观前先读本文。`Sources/Herdling/DesignSystem/Theme.swift` 是 token 的唯一来源。

---

## 平台分档

- **macOS 15 是地板**：底部渐隐靠 `onScrollGeometryChange`（15+），低于它行会被 footer 硬切，所以没有"低版本悄悄少一块"这回事。
- **macOS 26 是视觉层级的分档**：面板玻璃由 `NSGlassEffectView` 提供（26+），以下退回 `.menu` 材质 + scrim。面板照常工作，只是少一层折射。

## 一眼看过去

Herdling 是一个**菜单栏下拉面板**：无边框面板，表面就是系统 behind-window 模糊之上压一层 scrim；没有灰底照排。面板上的墨色走固定 alpha ramp。列表贴着面板，滚到底部时**渐隐**，不硬切。浮动控件（footer 胶囊、圆形按钮）是 Liquid Glass，**主表面永远不是玻璃**。

暗色是基准，亮色是同一套几何配反转的墨。

五条承重规则，按优先级：

1. **表面 = scrim 压在 behind-window 模糊上。** 不用实底、不用灰。
2. **一套 alpha ramp。** 暗面白墨、亮面黑墨，同一组 stops。
3. **只有一层玻璃。** 面板是 NSGlassEffectView；除了浮动控件，视图里不再叠第二层 `glassEffect`。
4. **边缘渐隐，不裁切。** 列表与 footer 之间没有分隔线，只有渐隐。
5. **面板是唯一的玻璃表面。** 它由 `StatusItemController` 挂在窗口上的 `NSGlassEffectView` 提供；分组、卡片、行、footer 全是 ramp 填充。（footer 曾经也有玻璃：tinycast 的 footer 装着主操作所以挣得到，而这里没有主操作，于是撤掉了。）

---

## 不可动的不变量

- **颜色只从 `Theme.Colors` 取。** `ramp(dark:light:)`（一个 alpha，亮暗反转）或 `adaptive(dark:light:)`（两个显式 `NSColor`，给不纯反转的场景）。视图里不写 `Color.white.opacity(…)`、`.gray`、`NSColor.windowBackgroundColor`。
- **不叠玻璃。** 分组不是玻璃板，面板是唯一的玻璃表面。折叠/展开靠 header 行的 fill 与间距。
- **不用固定字号。** 只有系统文字样式，`Theme.Typography` 里具名。写死 11.5pt 是回归。
- **测量出来的高度属于窗口，不属于 view。** 面板高度由 `PanelHeightBridge` 驱动；新加条带（footer）必须把自己的高度算进 `PanelHeightMeasurement`，否则窗口会矮一截。
- **一行只有两级信息。** 标题 `textPrimary` + 尾部读数 `textSecondary`，读数里不再有第二种颜色：数字和状态词同色。一行里出现三种灰，读起来就是"这几个字为什么不一样"。
- **header 的尾部只放一个读数。** 分支名是标题的**副标**（紧跟标题、`lg` 间距），不是读数：它曾和计数一起塞在尾部簇里，同色同字号、只隔 10pt，于是两者被读成一句话（`docs/assessment-consulting 2 idle`），而标题与这堆东西之间空出 160pt。现在是 tinycast 的行文法：`字形 ─ 标题 ─ 副标 ─…─ 尾部读数`。
- **图标要填满它的盘子。** tile 的字形是 `size * 0.64`（tinycast 是 14pt 落在 22pt 盘子里）。0.55 会让盘子空掉、圆角变成整行最显眼的东西。
- **状态色是语义，不是装饰。** `StatusPalette` 已按亮/暗 + 高对比度四路自适应，不要用 `Theme.Colors` 里的中性色去替换它。
- **可访问性与 Reduce Motion 一直保留。** 每个折叠动画都走 `AccordionMotion.animation(reduceMotion:)`，每个图标 `accessibilityHidden`，每行有 `accessibilityLabel`/`Hint`。
- **交互不变。** 重做外观不改行为：折叠状态持久化、悬停清理、错误行的 retry/dismiss、点击焦点行为都保持原样，除非任务本身就是改它。
- **展开状态归 store，不归 view。** `expanded.source` / `expanded.recent` 由 `SessionStore` 通过它注入的 `defaults` 读写。用 `@AppStorage` 会让 view 绕过 store 写进标准域：既测不了，也会在 harness 里污染用户偏好。
- **原生滚动条是 overlay 的。** `AppDelegate` 启动时把 `AppleShowScrollBars` 设成 `WhenScrolling`：legacy 滚动条会在透明面板里占掉右侧一条 gutter，footer 的右边缘就会比左边缘往里缩。

---

## Tokens

`Theme` 是唯一事实源。有 token 就不要写 magic number。

### Spacing

`xxs 2` · `xs 4` · `sm 6` · `md 8` · `lg 10` · `xl 12`

行内容左右内缩 `md`；列表水平内缩 `md`；行内图标→文字间距 `lg`；相邻 keycap 之间 `xxs`。

分组之间用 `sectionSpacing`（12）；header 与它第一行之间没有额外间距——header 自己就是一行，行的下内缩 `rowVertical` 已经是那个间隙。

节奏的三个 token，行、标签、层级都用它们，不各写各的：

- `rowVertical 8` — 每行的上下呼吸。所有行高都等于 `rowIcon + rowVertical * 2` = **38pt**，这就是"所有行同高"的算式。38 是 tinycast 配 `.body` 文字的行高（26 槽 + 两侧 `sm`）；32 时两行 17pt 文字之间只剩 19.5pt 空气，对照 tinycast 的 25.5 就显得挤。
- `indent 6` — 一层嵌套的内容内缩。
- `labelBand 26` — 空间标签这种非交互标签的整条带高：比它的文字高，比一行矮，正好把上下两组分开；等高等于行高时它会读成又一行。


### Radius

`panel 26` · `row 10` · `tile 6` · `keyCap 6`

**表面圆，内容方。** 面板 26、footer 胶囊、菜单与弹层是"表面"；行填充 10、tile 6、keycap 6 是"内容"。这是 tinycast 的原始分工（它就是 panel 26 / row 10 / tile 6），也是 macOS 的：窗口角圆、列表行方、图标方角圆。

两条不能越过的线，都有断言钉着：**填充和盘子的半径不得达到自身高度的一半**——32pt 行配 16 会变成药丸，22pt 盘子配 11 会变成圆盘，而圆盘在 macOS 语义里是头像，不是分类标记。

角上那个 8pt 处的行填充与面板角因此**不同心**（26 与 10，理想 18）。tinycast 也有这个问题，只是它的角上放的是搜索框而不是行；这里选择同一种取舍：让分工干净，而不是让一个内容形状去承担表面的几何。系统 `Form` 自己的卡片角不需要 token。

一律 `RoundedRectangle(cornerRadius:, style: .continuous)`，绝不用 `.circular`。

`panel 26` 是 tinycast 的取值，对 420pt 的下拉面板同样成立：它是整个面板最显眼的签名。

**同心圆角**：两个圆角相邻且同时可见时，内圆角 = 外圆角 − 间距。面板内的卡片不贴面板边，行填充也不算表面的角——这条规则在 Herdling 里没有适用的场合，因为角上那个元素是内容而不是表面。

### Size

`panelWidth 420` · `panelMinHeight 100` · `panelTopMargin 0` · `panelBottomMargin 16` · `panelScreenFraction 0.85` · `footerHeight 52` · `barButtonHeight 28` · `footerControl 36` · `rowIcon 22` · `rowMinHeight 26` · `actionPill 20` · `refreshGlyph 16` · `progressIndicator 12` · `tileGlyphRatio 0.64` · `keyCap 18` · `chevron 12` · `fadeOvershoot 24` · `menuBarGlyphWidth 11` · `menuBarGlyphHeight 13` · `settingsWidth 560` · `settingsHeight 560` · `settingsMinHeight 420` · `settingsRowIcon 20`

`rowIcon` 是行首图标的**固定槽位**。比槽位小的 glyph（状态点）居中放进槽位，而不是把槽位缩到自身大小 —— 这样每行的标题都从同一个 x 开始，展开/折叠时列不会左右跳。

### Typography

只用系统文字样式。

| token | 取值 | 用在哪 |
| --- | --- | --- |
| `rowTitle` | `.body` | agent / worktree / session 标题 |
| `rowTrailing` | `.callout` | 活动摘要、状态词、右侧 kind 标签 |
| `sectionHeader` | `.subheadline.weight(.medium)` | 分组标题 |
| `groupLabel` | `.caption` | space 标签、分支名、keycap、副标题 |
| `bar` | `.callout.weight(.medium)` | footer 药丸标签 |
| `mono` | `.caption.monospaced()` | 分支名（`.design(.monospaced)`） |

### Glyphs

SF Symbol 的显式字号，也是 token：`status 11 semibold` · `chevron 10 semibold` · `actionSymbol 9 semibold` · `focusArrow 10` · `refresh 12 medium` · `emptyState 15 medium` · `menuBar 11 medium` · `menuBarDigit 11 semibold monospaced`

菜单栏那三个是菜单栏自己的尺度（画进 image，不是画在面板里），所以自带数字，不借行的。

### Colors — alpha ramp

| token | 暗 | 亮 | 用在哪 |
| --- | --- | --- | --- |
| `panelScrim` | black **0.40** | white **0.55** | 面板 scrim，压在玻璃上 |
| `selection` | white 0.10 | black 0.09 | 展开中的分组 header、键盘选中行 |
| `rowHover` | white 0.05 | black 0.045 | 鼠标悬停填充（永远比 selection 淡） |
| `controlSurface` | white 0.10 | black 0.08 | keycap 填充（图标 tile 另取 tint 自身 12%） |
| `textPrimary` | white 1.00 | black 1.00 | 行标题、正文 |
| `textSecondary` | white 0.60 | black 0.60 | 次要标签、状态词 |
| `textTertiary` | white 0.40 | black 0.42 | 分支名、占位、keycap 文字 |
| `tileFillAlpha` | — | — | 盘子承载自身 tint 的强度（0.12） |
| `glassTint` | — | — | 面板玻璃自己的 tint（white 0.04），scrim 之前 |
| `fadeFloor` | — | — | 底部渐隐最深只到 0.25：行留影子，不消失 |

**色相**（`Theme.Hue`）按色相命名而不是按角色：来源是蓝、设置行也是蓝，一个 token 两处用。`indigo`（Recent）· `blue` · `purple`（SSH）· `orange`（警示）· `green`。**本地/SSH 的判断只在 `SourceInfo.rosterSymbol` / `rosterTint` 里写一次**——它曾经散在三个调用点，其中两个已经漂移。

`panelScrim` 是 ramp 的**逆向**（暗面压暗、亮面提亮），所以它是 `adaptive` 对，不是 `ramp`。

`StatusPalette`（`AgentStatusPresentation.swift`）不在 `Theme` 里，它是状态的语义色，自带四路自适应。

**选中永远赢过悬停。** 一行同时悬停和展开时，填充取 `selection`。

### Duration

`expand 0.18`

折叠动画用 `.smooth(duration: expand)`；悬停填充不带动画（tinycast 的行悬停是即时切换）。

---

## 面板结构

来源：`StatusItemController.swift`、`UI/AgentListView.swift`、`UI/PanelFooter.swift`。

- **窗口**：无边框 `NSPanel`，`isOpaque = false`、`backgroundColor = .clear`、`.popUpMenu` level、`hasShadow`、`animationBehavior = .none`。位置贴着菜单栏 item 下沿，左右被屏幕可见区域夹住（`StatusItemController.panelOrigin` 已实现，不改）。
- **表面配方**，顺序固定：
  1. macOS 26+：`NSGlassEffectView(style: .regular)` 作为窗口 contentView，`cornerRadius = panel`；
  2. 内容根视图盖一层 `panelScrim`；
  3. 最后 `.clipShape(RoundedRectangle(panel, .continuous))`。
  26 以下回落到 `NSVisualEffectView(material: .menu)`，同样盖 scrim。**scrim 在玻璃之上、内容之下**；顺序反了亮色模式会脏。
- **列表底部只留 `xs`(4)。** 分隔列表与 footer 的是渐隐，不是 padding；padding 的另一个职责只是别让最后一行贴到面板下缘，而行自己还有 `rowVertical` 8pt。给到 `md`(8) 时，那 8pt 读起来像"少了半行"。
- **footer 的余量是从几何下限反推的，不是选出来的。** 圆钮是 `footerControl` 36（= 药丸高 28 + 两侧 `xs`），带高 52，所以上下各余 8pt。**下面那 8pt 是下限**：面板圆角 26，圆钮左缘在 x=8，面板边缘在该处比面板底缘高 `26 − √(26² − 18²) ≈ 7.2pt`；余量小于 7.2，圆钮的左下角会被圆角切掉。`PanelLayoutTests` 把这条不等式写成了断言，所以调带高时越界会被拦下。
- **列表占满面板。** footer 用 `.safeAreaInset(edge: .bottom)` 作为透明 overlay 浮在列表上，列表从它下面穿过并在底边渐隐。header 与列表之间**没有分隔线**。
- **footer (`footerHeight 52`)**：左侧一个圆形刷新钮（`footerControl` 见方），右侧一枚 `Settings ⌘,` 药丸。
  - **不用玻璃。** tinycast 的 footer 装着主操作（"Open Application ↵"），那块玻璃是它挣来的；Herdling 的 footer 里没有主操作，一块亮玻璃在这里会比列表本身还响。控件静止时**无底**，指针来了才出 `rowHover` 胶囊——它读作 chrome，不读作召唤。
  - **只有 Settings。** Quit 不在这里：应用菜单（⌘Q）和状态项右键菜单各有一份，再往面板的黄金位置放第三份，等于把"退出"抬到 roster 之上。
  - 文字用 `textSecondary`，keycap 用 `textTertiary`。
  - 圆钮用 `footerControl`（36 = 药丸高 28 + 两侧 `xs`），**不用** `barButtonHeight`（28）：28 的圆配 36 的药丸，左边会看成一个小一号的控件。
  - footer 的高度是钉死的：条带本身 `.fixedSize(vertical: true)`，圆钮是 `footerControl` 见方的固定 frame。safe-area inset 给的 slot 会随面板高度动画变高，不钉住的话圆形按钮会被拉成椭圆。

---

## 行、选中、悬停

来源：`UI/Roster/RosterSections.swift`、`UI/Roster/RosterNesting.swift`、`UI/Roster/RosterPieces.swift`。

界面分三层：`UI/AgentListView.swift` 只管呈现（滚动、footer、折叠状态机），`UI/Roster/RosterSections.swift` 是两个顶层分组，`UI/Roster/RosterNesting.swift` 是 source 内部的四层嵌套，`UI/Roster/RosterPieces.swift` 是它们共用的行词汇（header 形状、图标槽、尾部读数、可折叠体）。跨文件组合，所以这些类型是 internal 而非 file-private——单 target 的 app，不对外暴露。

- 行是 `HStack(spacing: lg)`：行首固定 `rowIcon` 槽位、标题（`rowTitle`，`lineLimit(1)`）、可选副标、可选尾部读数，`Spacer`。内缩 `.horizontal md` + `.vertical sm`。
- 背景是 `RoundedRectangle(row, .continuous)`，fill 的优先级 **selection → hover → clear**。
- 悬停状态住在**行**里，不在列表里：鼠标扫过时只重绘进出那几行。
- 面板重新打开时清掉遗留的悬停（`panelIsOpen` 环境值，行为保持现状）。
- 缩进靠内容内缩，高亮仍按行自身盒子铺满 —— 缩进行不会得到一段空白高亮。
- **空态**（`RosterEmptyState`）是居中的图标 + 一句话，两行之间 `xs`。它不占一行的位置，也不缩进：空的是"这一组没有东西"，不是"有一行空的行"。
- **错误行**也走同一套：左侧 `tile`（橙色 `exclamationmark.triangle.fill`）、文字 `rowTrailing`、尾部用 `RosterActionPill`（裸着、悬停才出 `rowHover` 胶囊）。不用带边框的系统按钮——那是另一种语言。

- **尾部只有一列。** 摘要、计数、焦点箭头、chevron 全部收在同一个右缘（没有 chevron 的行用 `chevron` 槽位预留）。谁在自己的 trailing 里自己写 `Spacer`，谁就贴左——那样两种行的右边界会错开十几点。

### 行首图标

三种，共用一个槽位：

- **tile**（分组、来源、error）：`tile` 圆角方块填 `tint.opacity(0.1)`，glyph 用 tint 本身，14pt。取代旧的"白圆盘 + `drawingGroup()` 光栅化"。
- **状态点**（`StatusIndicator`）：状态语义色的小 glyph，居中在槽位里。
- 两者都不参与玻璃渲染，因此不再需要预先光栅化。


### 分组 header

- 一行可点击的 header：`DisclosureChevron` + tile + 标题 + 尾部活动摘要。
- 字体 `sectionHeader`，标题色 `textPrimary`；摘要 `rowTrailing`，`textSecondary`。
- 填充：悬停 `rowHover`；**展开中保持 `selection`**，指针离开也保持 —— 分组一直标着"打开"。
- header 与第一行之间只隔 `sectionHeaderBottom`；分组之间隔 `sectionSpacing`。没有分隔线、没有底板。
- 折叠动画走 `AccordionMotion`，高度由实测内容高度驱动（`AccordionBody` 保持现状）。

### 嵌套层级

来源 → session → space → worktree → agent 是数据的固有深度，用 token 表达：

- session header：`rowTitle`，`textSecondary`；
- 空间（多分支）：安静 caption + `textSecondary`，它领的是 worktree 行，所以比它们的字形左移一级（`indent`）；
- 空间（只有主 worktree）：**用普通的 header 行**（`GroupHeaderRow`，`isExpanded: nil`，无 chevron、无 selection 填充）。Herdr 给每个 workspace 一个叫 `Main` 的 worktree，没有分支的空间会得到一排一模一样的 `Main`；那一行没有信息，但**不能只是删掉**——删掉组就没有头了。它与 worktree 行同一档：同样的状态字形、同样 `.body.weight(.medium)`、同样的尾部读数列，**点击行为也同一档**（在 Ghostty 打开这个 workspace），外观与行为都不分叉。
  - 粗体标题的含义是「直接领 agent」；多分支的空间用安静 caption，因为它领的是 worktree 行。
  - 判定问结构（`RosterSpace.isOnlyItsPrimaryWorktree`），不是显示名，所以 herdr 改名叫不出错。
- worktree：`rowTitle.weight(.medium)`，缩进 `indent`；
- agent：`rowTitle`，在 worktree 基础上再缩进一级 `indent`，尾部是悬停才出现的焦点箭头。

每一级都只加 `indent`，所以列是 0 / 6 / 12 这样等距的。加载中的那一行也走同一套行文法：spinner 放进共享图标槽，句子落在标题列上。

---

## 状态呈现

- 徽章/图标用状态语义色（`StatusPalette` 的 blocked 与 `controlAccentColor` 的 working）。
- 纯文字状态（`done` / `ready` / `unknown`）走 `textSecondary`，不染色：注意力应该只被 blocked 与 working 抓住。
- 分组摘要写数量 + 状态词（"2 needs you · 1 working"），数字 `textPrimary`，状态词 `textSecondary`。

---

## 边缘渐隐

来源：`DesignSystem/Scrolling/OverflowFade.swift`。

列表下沿被 footer 压住时用一个 `LinearGradient` mask 渐隐：

- 底部带 = `footerHeight + 24` = **76pt**：渐隐从 footer 背后开始，不是从它的上沿开始，所以行是"渗进"footer 下面，而不是被 footer 切掉。
- 有 **alpha floor 0.25**：滚到底时最深也只到 25%，行仍留一层影子；列表静止贴边时（下溢出为 0）完全不遮。
- 只在内容确实可滚动时加 mask。
- mask 不改布局，因此与 `PanelHeightMeasurement` 无冲突。
- 不引入 `scrollEdgeEffectStyle`：在透明面板里它画出一块有硬边的矩形。

不用 tinycast 的 `edgeDissolve`：那条曲线的带长是按它的 header/footer 双条带量出来的，Herdling 只有底部一条。

---

## Settings 窗口

来源：`SettingsWindowController.swift`、`SettingsView.swift`。

Settings 是**自己的 `NSWindow`**，不是面板里的一个子页面。

- 尺寸 `settingsWidth 560`，高度由内容决定；有真实红绿灯与系统 titlebar 带；`titlebarAppearsTransparent = false`，让 AppKit 自己画那条带；`isMovableByWindowBackground = false`。
- 内容是一个 `Form` + `.formStyle(.grouped)`：卡片、行内缩、hairline 都是系统画的，读起来和"系统设置"一致。
- **单栏，无侧边栏。** tinycast 用 `NavigationSplitView` 是因为它有一打以上 pane；Herdling 只有四组。等到 pane 超过五个再加，别提前加。
- 一行的 label 是 `SettingsLabel`：可选 20pt 图标 tile + 标题 + 副标题。外面包 stock 控件（`Toggle` / `Picker` / `LabeledContent`），不要手搓带内边距的 `HStack`。
- 尾部要放**自定义**控件（如快捷键录制器）时不要用 `LabeledContent`：它会把值包进一个可选中文本框，吞掉点击。只读值（权限状态那种）用 `LabeledContent` 就对了。
- 一个被关掉的东西要读起来就是关的：开关关着的行，图标 tile 取 `textTertiary` 色；要禁用整行时用 `.disabled(...)` 加 `.opacity(0.45)`——裸 `.disabled` 会让标题留在全强度上。
- 标题/副标题的用词省着用：副标题只在标题漏掉一个后果或限制时出现，不复述标题。
- 关闭设置窗口回到面板：面板不因此打开或关闭。

`⌘,` 打开设置（应用菜单已绑定）；面板内的 `Esc` 只负责关面板。

---

## 给改 UI 的 agent

- **从渲染截图下手，不猜数值。** 改完在浅色桌面壁纸上截图：透明与圆角裁切的 bug 只在亮壁纸上现形。
- **间距和位置要有断言，不能靠眼睛。** `swift test --filter RosterRenderTests` 会用真实 AppKit 布局把面板、footer、Settings 渲染成 PNG（`/tmp/herdling-render`）；`PanelLayoutTests` 则把行高、footer 高度、footer 左右 margin 钉成数字。截图看感觉，断言看回归。
  - 离屏渲染要用 `NSHostingView` + `NSWindow`，**不要用 `ImageRenderer`**：它不跑 `onPreferenceChange`，所有测量出来的高度都是 0，手风琴会渲染成空的。
- **不要加没被要求的行为。** 重做外观就是重做外观。
- **新取值进 `Theme`**，视图里不留 magic number。
- **共享语法保持共享。** 行内缩、fill 优先级、分组 header 样式、keycap 样式只写一份，分叉是 bug 不是特性。
- **字面量会被测试拦住。** `DesignTokenTests` 扫 `Sources/Herdling`：颜色、字号、内边距、frame、opacity、动画时长里任何裸字面量都算失败，只有 `Theme.swift`（token 本身）和 `HerdrBrand.swift`（512pt 品牌图标， artwork 不是界面）豁免。新值先进 `Theme` 再用。
- **用真实工具链构建验证。** 编不过 Swift 6 严格模式的设计改动不算做完。
