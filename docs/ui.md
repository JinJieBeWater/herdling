# UI & Design System

Herdling 的界面规范。设计语言来自 [Tinycast](https://tinycast.dev/)（`abue-ammar/tinycast`，AGPL-3.0）；本文档只描述**Herdling 自己的**取值与结构，两者同名但数值独立。

改任何 view body、`Theme` 取值或面板外观前先读本文。`Sources/Herdling/DesignSystem/Theme.swift` 是 token 的唯一来源。

---

## 平台分档

- **macOS 15 是地板**：滚动边缘渐隐使用 `onScrollGeometryChange`（15+）。
- **macOS 26 是视觉层级的分档**：面板玻璃由 `NSGlassEffectView` 提供（26+），以下退回 `.menu` 材质 + scrim。面板照常工作，只是少一层折射。

## 一眼看过去

Herdling 是一个**只展示列表的菜单栏下拉面板**：无边框面板，系统玻璃或材质之上压一层 scrim；没有灰底照排。面板上的墨色走固定 alpha ramp。内容溢出时底边渐隐。刷新、设置和退出放在状态项右键菜单，不设独立底栏。

暗色是基准，亮色是同一套几何配反转的墨。

五条承重规则，按优先级：

1. **表面 = scrim 压在 behind-window 模糊上。** 不用实底、不用灰。
2. **一套 alpha ramp。** 暗面白墨、亮面黑墨，同一组 stops。
3. **只有一层玻璃。** 面板是 NSGlassEffectView，视图中不叠第二层 `glassEffect`。
4. **边缘渐隐。** 内容超过窗口时淡出底边；滚到底时恢复实色。
5. **分组与行用 ramp 填充。** 不画独立玻璃板或操作工具栏。

---

## 不可动的不变量

- **颜色只从 `Theme.Colors` 取。** `ramp(dark:light:)`（一个 alpha，亮暗反转）或 `adaptive(dark:light:)`（两个显式 `NSColor`，给不纯反转的场景）。视图里不写 `Color.white.opacity(…)`、`.gray`、`NSColor.windowBackgroundColor`。
- **不叠玻璃。** 分组不是玻璃板，面板是唯一的玻璃表面。折叠/展开靠 header 行的 fill 与间距。
- **不用固定字号。** 只有系统文字样式，`Theme.Typography` 里具名。写死 11.5pt 是回归。
- **测量出来的高度属于窗口，不属于 view。** 列表通过 `PanelContentHeightKey` 发布包含内缩的完整高度，`PanelHeightBridge` 驱动窗口；不再叠加固定操作条高度。
- **一行只有两级信息。** 标题 `textPrimary` + 尾部读数 `textSecondary`，读数里不再有第二种颜色：数字和状态词同色。一行里出现三种灰，读起来就是"这几个字为什么不一样"。
- **header 的尾部只放一个读数。** 分支名是标题的**副标**（紧跟标题、`lg` 间距），不是读数：它曾和计数一起塞在尾部簇里，同色同字号、只隔 10pt，于是两者被读成一句话（`docs/assessment-consulting 2 idle`），而标题与这堆东西之间空出 160pt。现在是 tinycast 的行文法：`字形 ─ 标题 ─ 副标 ─…─ 尾部读数`。
- **前导图标按 Tinycast 的角色区分字重。** 分组、来源、状态、错误和 Settings 共用 `RowSymbol`：22pt 透明槽位中的 14pt Regular 单色 glyph；导航使用 14pt Medium 和独立14pt槽。来源用中性色，状态和告警保留语义色。没有底板、描边或独立圆角。
- **状态色是语义，不是装饰。** `StatusPalette` 已按亮/暗 + 高对比度四路自适应，不要用 `Theme.Colors` 里的中性色去替换它。
- **可访问性与 Reduce Motion 一直保留。** 每个折叠动画都走 `AccordionMotion.animation(reduceMotion:)`，每个图标 `accessibilityHidden`，每行有 `accessibilityLabel`/`Hint`。
- **交互不变。** 重做外观不改行为：折叠状态持久化、悬停清理、错误行的 retry/dismiss、点击焦点行为都保持原样，除非任务本身就是改它。
- **来源展开偏好归 store。** `expanded.source` 由 `SessionStore` 通过注入的 `defaults` 读写。快速入口不折叠；不再使用 `expanded.recent`。用 `@AppStorage` 会绕过 store，污染用户偏好与测试。
- **原生滚动条是 overlay 的。** `AppDelegate` 启动时把 `AppleShowScrollBars` 设成 `WhenScrolling`，避免 legacy 滚动条在透明面板右侧占据固定 gutter。

---

## Tokens

`Theme` 是唯一事实源。有 token 就不要写 magic number。

### Spacing

`xxs 2` · `xs 4` · `sm 6` · `md 8` · `lg 10` · `xl 12`

行内容左右内缩 `md`；列表水平内缩 `panelInset`。

行内、行间、组间各有预算，不能用增大行内 padding 代替高亮之间的分隔：

| token | 用途 |
| --- | --- |
| `rowVertical 5` | 正文上下内缩，22pt 槽位形成 32pt 行框；空间 caption 也占这一行高 |
| `sectionHeaderVertical 8` | 来源顶层标题上下内缩，保持 38pt |
| `rowGap 2` | 同组正文行、树内标题与第一行子项之间；正文中心节奏为 34pt |
| `sectionBodyGap 4` | 顶层标题与展开正文之间；放在折叠体内，收起时一起消失 |
| `navigationHeaderGap 4` | 固定视图顶栏与列表之间；不靠行内 padding 隔开两块背景 |
| `groupGap 8` | 相邻来源子组、session、空间和 worktree 组之间 |
| `sectionSpacing 4` | 顶层 section 之间；展开前后均为 4pt，组内间距不变，不加尾部 padding |
| `rowContentGap 6` | 前导图标槽与标题之间；标题副标和尾部槽位仍用 `lg` |
| `indent 12` | 每个可见树层级的内容内缩；来源顶层标题是 section 容器，不额外消耗一层 |

正文的字号保持系统 `.body`，不是按 iOS 的 17pt 推算行高。当前 macOS 默认 body 实测 13pt；字体与行框高度是两件事。

快速入口的两行身份使用 `quickRowHeight 40`，顶部视图切换使用 `navigationHeaderHeight 38`；不是给全部目录行增加行高。


### Radius

`panel 26` · `panelContent 18`（`panel − panelInset`）· `row 10` · `navigationControl 8`

按相邻轮廓分配圆角，不让所有元素使用同一个半径：

| 元素 | 规则 |
| --- | --- |
| 面板 | 26pt；玻璃根层裁剪与 SwiftUI 都用连续曲线 |
| 贴顶首行高亮 | 顶部与左右都内缩 `panelInset`（8pt）；上两角 18pt，下两角保留 10pt |
| 贴底末行高亮 | 底部与左右同样内缩 8pt；下两角 18pt，上两角保留 10pt |
| 普通行与内部相邻角 | 10pt，32pt 正文行高下不做成胶囊 |
| 顶栏选项 | 28pt视觉表面居于38pt点击区中央，8pt圆角；不贴外层轮廓 |
| 前导图标 | 透明槽位，不绘制底板，因此没有图标底板圆角 |
| 行内操作 | 高 20pt 的胶囊，保留动作按钮与内容行的区别 |
| Settings 分组与系统控件 | 由原生 `Form`、Picker、Toggle 绘制，不覆盖系统圆角 |

列表内容整体用 18pt 连续圆角裁切，再统一内缩 8pt；各行自身仍画 10pt 圆角。顶部切换行与列表共用这个边界，计入完整测量高度。首末边界跟随真实内容，不沿树逐层传递位置标记。这不是要求所有嵌套元素都同心；图标和行内按钮仍使用各自规则。

圆角矩形统一 `.continuous`；内容边界由整体裁切处理，不把首末行四角一起放大。独立的圆形／胶囊控件保留各自形状。

### Size

`panelWidth 420` · `panelMinHeight 100` · `panelTopMargin 0` · `panelBottomMargin 16` · `panelScreenFraction 0.85` · `rowIcon 22` · `rowMinHeight 32` · `actionPill 20` · `progressIndicator 12` · `chevron 12` · `scrollFadeHeight 24` · `menuBarGlyphWidth 11` · `menuBarGlyphHeight 13` · `settingsWidth 560` · `settingsHeight 560` · `settingsMinHeight 420`

`rowIcon` 是行首图标的**固定槽位**。比槽位小的 glyph（状态点）居中放进槽位，而不是把槽位缩到自身大小 —— 这样每行的标题都从同一个 x 开始，展开/折叠时列不会左右跳。导航不参与目录标题列，使用独立 `navigationIcon 14`；`navigationControlHeight 28`只决定表面，`navigationHeaderHeight 38`仍决定点击区与测量高度。

### Typography

只用系统文字样式。

| token | 取值 | 用在哪 |
| --- | --- | --- |
| `rowTitle` | `.body` | agent / worktree 标题 |
| `rowTrailing` | `.callout` | 活动摘要、状态词、右侧 kind 标签 |
| `sectionHeader` | `.subheadline.weight(.medium)` | 分组标题 |
| `groupLabel` | `.caption` | space 标签、分支名、副标题 |
| `mono` | `.caption.monospaced()` | 分支名（`.design(.monospaced)`） |

### Glyphs

SF Symbol 的显式字号，也是 token：`leading 11 semibold` · `chevron 10 semibold` · `actionSymbol 9 semibold` · `focusArrow 10` · `emptyState 15 medium` · `menuBar 11 medium` · `menuBarDigit 11 semibold monospaced`

菜单栏那三个是菜单栏自己的尺度（画进 image，不是画在面板里），所以自带数字，不借行的。

### Colors — alpha ramp

| token | 暗 | 亮 | 用在哪 |
| --- | --- | --- | --- |
| `panelScrim` | black **0.40** | white **0.55** | 面板 scrim，压在玻璃上 |
| `selection` | white 0.10 | black 0.09 | 当前视图、展开中的分组 header、可用的键盘选中行 |
| `rowHover` | white 0.05 | black 0.045 | 鼠标悬停填充（永远比 selection 淡） |
| `textPrimary` | white 1.00 | black 1.00 | 行标题、正文 |
| `textSecondary` | white 0.60 | black 0.60 | 次要标签、状态词 |
| `textTertiary` | white 0.40 | black 0.42 | 占位、快捷键提示 |
| `glassTint` | — | — | 面板玻璃自己的 tint（white 0.04），scrim 之前 |
| `fadeFloor` | — | — | 底部渐隐最深只到 0.25：行留影子，不消失 |

**色相**（`Theme.Hue`）按色相命名而不是按角色：`blue` · `purple` · `orange`（警示）· `green`。设置和状态需要强调时使用语义色；来源不再用蓝／紫区分，本机和 SSH 靠符号、文字及辅助功能表达，均使用 `textSecondary`。**本地/SSH 的符号判断只在 `SourceInfo.rosterSymbol` 里写一次**。

`panelScrim` 是 ramp 的**逆向**（暗面压暗、亮面提亮），所以它是 `adaptive` 对，不是 `ramp`。

`StatusPalette`（`AgentStatusPresentation.swift`）不在 `Theme` 里，它是状态的语义色，自带四路自适应。

**选中永远赢过悬停。** 一行同时悬停和展开时，填充取 `selection`。

### Duration

`expand 0.18`

折叠动画用 `.smooth(duration: expand)`；悬停填充不带动画（tinycast 的行悬停是即时切换）。

---

## 面板结构

来源：`StatusItemController.swift`、`UI/AgentListView.swift`。

- **窗口**：无边框 `NSPanel`，`isOpaque = false`、`backgroundColor = .clear`、`.popUpMenu` level、`hasShadow`、`animationBehavior = .none`。位置贴着菜单栏 item 下沿，左右被屏幕可见区域夹住（`StatusItemController.panelOrigin` 已实现，不改）。
- **表面配方**，顺序固定：
  1. macOS 26+：`NSGlassEffectView(style: .regular)` 作为窗口 contentView，`cornerRadius = panel`；
  2. 内容根视图盖一层 `panelScrim`；
  3. 最后 `.clipShape(RoundedRectangle(panel, .continuous))`。
  26 以下回落到 `NSVisualEffectView(material: .menu)`，同样盖 scrim。**scrim 在玻璃之上、内容之下**；顺序反了亮色模式会脏。
- **玻璃根层也裁圆角。** `NSGlassEffectView.cornerRadius` 与 SwiftUI 的 `clipShape` 不足以约束 key window 状态下的全部玻璃绘制；玻璃根 `CALayer` 用同一个 `Theme.Radius.panel`、与 SwiftUI 一致的 `.continuous` 曲线，并启用 `masksToBounds`。保留键盘焦点和窗口阴影。验收时面板必须仍是 key window：失焦会让矩形痕迹消失，截图可能因此漏报。
- **列表四边统一内缩 `panelInset`（8pt）。** 首行上角与末行下角跟随面板内轮廓，内部相邻角保持普通行形状；不留操作条或 safe-area 占位。
- **菜单操作独立于列表。** 右键或 Control-click 状态项打开原生菜单：Refresh、Settings、分隔线、Quit Herdling。刷新期间禁用 Refresh，并防止重复启动。Settings 的 `⌘,` 和退出的 `⌘Q` 继续通过应用菜单提供。

---

## 行、选中、悬停

### 查看与定位

行为与验收范围见 [Agent 查看与定位设计](agent-navigation-design.md)。HTML 原型不代替原生验收。

- 顶栏用 **Activity / Sources** 互斥视图切换，左对齐，两个选项之间保留 xs（4pt）。Activity 用波形图标表示状态动态，Sources 用服务器图标表示本机和 SSH 来源；14pt Medium 裸字形使用独立14pt槽，后接6pt布局间距和8pt水平内缩，没有图标盘。当前选项复用selection；未选中项保持透明，悬停仅提亮图标与文字。28pt视觉表面居于38pt点击区中央，8pt圆角；没有整条底板、共用轨道、下划线、常驻边框或第二层玻璃，也不出现两个并列底色块。每次打开进入 Activity：在线 blocked → done → working → 最近三个 idle；各等级按 Herdr 的状态更新时间由新到旧，同时间保留来源快照顺序。整个列表平铺，不显示分组标题或额外数量；idle 不依赖成功定位记录。
- 顶栏选项使用系统 callout Regular（macOS 默认12pt），两项及选中前后的字号、字重相同；选中靠底色与文字明暗区分。列表标题仍为 body，分组标题仍为 subheadline Medium。
- 顶栏离线提示显示橙色网络图标和 `1 offline` 这类短文案，help/辅助功能提供来源名称与状态；覆盖部分 Session 不可用的来源。文案不挤进12pt数字槽。快速列表不再放整行离线警告。右侧不显示重复的 working、ready，左侧状态图标与完整辅助功能状态保留；Needs input、Completed、Opening、不可用状态与 Retry 保留。
- **顶部与行共用边界，不强迫同一标题列。** 控件只保留一层md内容内缩；短导航组合按自身光学间距排布，目录仍保留22pt槽和原标题列。整条顶栏保持透明。空摘要不参与尾部布局，Retry与状态数量的右缘保持一致。
- 顶栏与列表之间保留 navigationHeaderGap，参与完整高度测量。快速列表空态只是一行次级文字，占40pt；不再加大图标、working 数量或重复的 Sources 入口。空快照有新状态时显示简短 reopen 提示，不自动插入新目标。
- 副标题默认只显示工作区，本机来源名及 default Session 隐去。远程、非默认 Session 或同名目标需要区分时补齐身份；完整 ID 始终保留在 help/辅助功能中。
- **Sources** 复用来源→Session→Space/worktree→agent 的目录和来源展开偏好。最多展开一个，允许全部收起：有效已保存来源优先，空偏好保持全部收起，失效偏好回退到第一个来源；点当前来源收起，点其他来源关闭前一个并展开该项。来源折叠不执行定位；agent、工作区、Session 各自定位自己的真实 ID。
- 菜单栏永远只是面板开关，零/一/多候选一致。鼠标打开不预选；键盘打开选择首个有效目标。上下键仅移动选择，来源上的 Enter 只切换折叠，左右键收起或展开来源；子项左键返回父层，定位项上的 Enter 才提交。Tab 保持原生控件焦点。Escape 关闭但不撤销已提交动作。
- 全局呼出使用 KeyboardShortcuts 的命名 Recorder，在 Settings 中配置，默认 unset；key-up 开关面板，不申请全局监听权限。面板内的组合键继续交给原生菜单和控件。
- 打开期间固定成员与顺序，已有状态与可用性实时更新。删除 Update list 控件，重新打开重建名单。离线/退出立即阻止定位；菜单栏与需关注数量仍来自实时状态。空快照有新目标时提示重新打开，不声称没有需关注项。
- 定位中显示 Opening；失败保留目标、原因与 Retry。失败目标不在新名单时保留独立恢复入口，不计入需关注数量。新请求覆盖旧请求的界面结果，旧成功不能关面板或写历史。
- 看列表、悬停、选择不发送 focus/seen。实际 Herdr focus 可能将整个目标 tab 标为 seen，公共定位还可能影响同 Session 的多个 shell client；失败不保证零副作用。done 提示消失不是用户已处理的证明。

来源：`UI/Roster/RosterSections.swift`、`UI/Roster/RosterNesting.swift`、`UI/Roster/RosterPieces.swift`。

`NavigationBrowser.swift` 管浏览快照和按身份选择，`StatusItemController.swift` 管打开/关闭与键盘事件。`UI/AgentListView.swift` 接入高度动画；`UI/NavigationPanel.swift` 管固定顶栏和滚动列表；`UI/Roster` 保留 Sources 的来源、Session、Space/worktree 层级。

- 行首固定 `rowIcon` 槽位与标题之间用 `rowContentGap`；标题与可选副标、尾部读数槽位之间用 `lg`。正文上下内缩 `rowVertical`，顶层标题用 `sectionHeaderVertical`；左右均为 `md`。
- 行背景用 `row` 连续圆角，列表整体裁切负责首末边界；可用项的fill优先级 **selection → hover → clear**。不可用定位项不显示交互wash，也不显示hover操作暗示；Unavailable和原因仍保留。键盘检查轮廓独立绘制，冻结访问期间的选择身份不因失效改变，浏览器既有选择策略不变。离线来源标题仍可浏览，不禁用。
- current、来源展开和键盘选择含义不同，但共用selection强度；current＋hover不叠加、不位移。按下反馈与原生键盘focus交给plain Button样式，不额外叠加按下透明度或抢占Tab；列表键盘检查继续使用1pt轮廓。
- 悬停状态住在**行**里，不在列表里：鼠标扫过时只重绘进出那几行。
- 面板重新打开时清掉遗留的悬停（`panelIsOpen` 环境值，行为保持现状）。
- 缩进靠内容内缩，高亮仍按行自身盒子铺满 —— 缩进行不会得到一段空白高亮。
- **空态**（`RosterEmptyState`）是居中的图标 + 一句话，两行之间 `xs`。它不占一行的位置，也不缩进：空的是"这一组没有东西"，不是"有一行空的行"。
- **错误行**也走同一套：左侧 `RowSymbol`（橙色 `exclamationmark.triangle.fill`）、文字 `rowTrailing`、尾部用 `RosterActionPill`（裸着、悬停才出 `rowHover` 胶囊）。不用带边框的系统按钮——那是另一种语言。

- **尾部只有一列。** 摘要、计数、焦点箭头、chevron 全部收在同一个右缘（没有 chevron 的行用 `chevron` 槽位预留）。谁在自己的 trailing 里自己写 `Spacer`，谁就贴左——那样两种行的右边界会错开十几点。

### 行首图标

只有一种组件：`RowSymbol`。分组时钟、本机、SSH、worktree/agent 状态、错误提示和 Settings 标签都复用它。

- 列表14pt Regular、导航14pt Medium；列表仍放在 `Size.rowIcon`（22pt）透明槽位内，导航仍用14pt槽。离线提示也复用列表字重，不再独立画一枚粗图标；保留标题列和原有缩进。
- 只画 glyph，不画底板；来源使用 `textSecondary`，状态和告警保留语义色，不把电脑、网络改成状态圆点。以明确的 SF Symbol 名称生成模板图像，避免按钮环境隐式切成填充版；显式状态名中的 `.fill` 保留。
- 参考 Tinycast 的 `SymbolImage` Regular 字重和 `HeaderMenuSymbol` 14pt Medium 模板图像；不把 Settings 专用彩色 tile 搬进名单。14pt 是 Herdling 紧凑名单的字号，单色保留可读的状态轮廓；实现独立，不复制参考项目的 AGPL 代码。
- 空态插图、菜单栏品牌图标和原生菜单图标保留各自用途与规格。

验证：列表轮廓与14pt Regular参考图像匹配，导航字重与14pt Medium匹配；按钮的填充 variant 不会把 idle 轮廓改成实心。159项回归通过。实际玻璃面板检查了 Activity、全部来源折叠／本机展开、来源与导航悬停；折叠138pt、展开1197pt，源展开偏好已恢复。亮色真实玻璃、高对比度和 VoiceOver 未验证，测试截图不代替这些验收。


### 分组 header

- 一行可点击的 header：`RowSymbol` + 标题 + 尾部活动摘要 + `DisclosureChevron`。
- 字体 `sectionHeader`，标题色 `textPrimary`；摘要 `rowTrailing`，`textSecondary`。
- 填充：悬停 `rowHover`；**展开中保持 `selection`**，指针离开也保持 —— 分组一直标着"打开"。
- 顶层 header 与正文之间隔 `sectionBodyGap`；section 之间隔 `sectionSpacing`。树内部标题与子项之间用 `rowGap`，兄弟组之间用 `groupGap`。没有分隔线、没有底板。
- 折叠动画走 `AccordionMotion`，高度由实测内容高度驱动（`AccordionBody` 保持现状）。

### 嵌套层级

来源 → session → space → worktree → agent 是数据的固有深度，用 token 表达：

- session header：`sectionHeader`，`textSecondary`；
- 空间（多分支）：安静 caption + `textSecondary`，预留透明图标槽，文字与同级单 worktree 空间标题对齐；其下 worktree 再缩进一级；
- 空间（只有主 worktree）：**用普通的 header 行**（`GroupHeaderRow`，`isExpanded: nil`，无 chevron、无 selection 填充）。Herdr 给每个 workspace 一个叫 `Main` 的 worktree，没有分支的空间会得到一排一模一样的 `Main`；那一行没有信息，但**不能只是删掉**——删掉组就没有头了。它与 worktree 行同一档：同样的状态字形、同样 `.body.weight(.medium)`、同样的尾部读数列，**点击行为也同一档**（在 Ghostty 打开这个 workspace），外观与行为都不分叉。
  - 粗体标题的含义是「直接领 agent」；多分支的空间用安静 caption，因为它领的是 worktree 行。
  - 判定问结构（`RosterSpace.isOnlyItsPrimaryWorktree`），不是显示名，所以 herdr 改名叫不出错。
- worktree：`rowTitle.weight(.medium)`，缩进 `indent`；
- agent：`rowTitle`，在 worktree 基础上再缩进一级 `indent`，尾部是悬停才出现的焦点箭头。

每个**可见**层级只加一次 `indent`，所以列是 0 / 12 / 24 等距递进。session 标题显示时，其正文缩进一级。省略 Main 就少一级，因此不同深度的 agent 不必绝对对齐。加载与错误行继承所在层级的缩进；Activity 不引入目录缩进。

---

## 状态呈现

- 徽章/图标用状态语义色（`StatusPalette` 的 blocked 与 `controlAccentColor` 的 working）。
- 纯文字状态（`done` / `ready` / `unknown`）走 `textSecondary`，不染色：注意力应该只被 blocked 与 working 抓住。
- 分组摘要写数量 + 状态词，数字和状态词都用 `textSecondary`。

---

## 边缘渐隐

来源：`DesignSystem/PanelChrome.swift`。

列表仍有未显示内容时，用 `LinearGradient` mask 淡出底边：

- 底部渐隐带为 `scrollFadeHeight`（24pt）；没有操作条，不能继续保留旧的 76pt 渐隐预算。
- 有 **alpha floor 0.25**：滚到底时最深也只到 25%，行仍留一层影子；列表静止贴边时（下溢出为 0）完全不遮。
- 只在内容确实可滚动时加 mask。
- mask 不改布局或测量高度。
- 不引入 `scrollEdgeEffectStyle`：在透明面板里它画出一块有硬边的矩形。

不用 tinycast 的 `edgeDissolve`；带长由 Herdling 的列表视口决定。

### 细滚动条

名单滚动条遵循 Tinycast 的细条外观，不复用其 AGPL 实现：滚动时 thumb 为 6pt，悬停或拖动时为 10pt，轨道为淡色胶囊。绘制距视口边缘 3pt，thumb 按内容比例变化，最短 28pt；内容未溢出时不显示。

使用 AppKit 的 overlay `NSScroller`，只替换绘制；保留原生拖动、轨道点击、滚轮、自动淡出和辅助功能。覆盖系统 scroller 样式变化仅限名单，不修改系统偏好或 Settings。视口不保留 legacy gutter；名单行的尾部内容额外留 8pt 净空，让箭头与读数处于原生点击区之外，标题列、整行高亮与视口宽度不变。短名单同样保留这份净空，展开时尾列不跳动。

不改变名单固有高度、键盘 `scrollTo`、24pt 底部渐隐或定位动作。自动淡出时序沿用 AppKit，不另建计时器。

---

## Settings 窗口

来源：`SettingsWindowController.swift`、`SettingsView.swift`。

Settings 是**自己的 `NSWindow`**，不是面板里的一个子页面。

- 尺寸 `settingsWidth 560`，高度由内容决定；有真实红绿灯与系统 titlebar 带；`titlebarAppearsTransparent = false`，让 AppKit 自己画那条带；`isMovableByWindowBackground = false`。
- 内容是一个 `Form` + `.formStyle(.grouped)`：卡片、行内缩、hairline 都是系统画的，读起来和"系统设置"一致。
- **单栏，无侧边栏。** tinycast 用 `NavigationSplitView` 是因为它有一打以上 pane；Herdling 只有四组。等到 pane 超过五个再加，别提前加。
- 一行的 label 是 `SettingsLabel`：可选 `RowSymbol` + 标题 + 副标题。外面包 stock 控件（`Toggle` / `Picker` / `LabeledContent`），不要手搓带内边距的 `HStack`。
- 尾部要放**自定义**控件（如快捷键录制器）时不要用 `LabeledContent`：它会把值包进一个可选中文本框，吞掉点击。只读值（权限状态那种）用 `LabeledContent` 就对了。
- 一个被关掉的东西要读起来就是关的：开关关着的行，图标取 `textTertiary` 色；要禁用整行时用 `.disabled(...)` 加 `.opacity(0.45)`——裸 `.disabled` 会让标题留在全强度上。
- 标题/副标题的用词省着用：副标题只在标题漏掉一个后果或限制时出现，不复述标题。
- 关闭设置窗口回到面板：面板不因此打开或关闭。

`⌘,` 打开设置（应用菜单已绑定）；面板内的 `Esc` 只负责关面板。

---

## 给改 UI 的 agent

- **从渲染截图下手，不猜数值。** 改完在浅色桌面壁纸上截图：透明与圆角裁切的 bug 只在亮壁纸上现形。
- **间距和位置要有断言，不能靠眼睛。** `swift test --filter RosterRenderTests` 会用真实 AppKit 布局把面板、层级、Settings 渲染成 PNG，输出到每次新建的 `/tmp/herdling-render-<UUID>`，日志给出路径；不覆盖旧证据。`PanelLayoutTests` 验证完整面板高度、行高与展开留白，`PanelChromeTests` 验证文字列和轮廓。截图看感觉，断言看回归。
  - 离屏渲染要用 `NSHostingView` + `NSWindow`，**不要用 `ImageRenderer`**：它不跑 `onPreferenceChange`，所有测量出来的高度都是 0，手风琴会渲染成空的。
- **不要加没被要求的行为。** 重做外观就是重做外观。
- **新取值进 `Theme`**，视图里不留 magic number。
- **共享语法保持共享。** 行内缩、fill 优先级与分组 header 样式只写一份，分叉是 bug 不是特性。
- **字面量会被测试拦住。** `DesignTokenTests` 扫 `Sources/Herdling`：颜色、字号、内边距、frame、opacity、动画时长里任何裸字面量都算失败，只有 `Theme.swift`（token 本身）和 `HerdrBrand.swift`（512pt 品牌图标， artwork 不是界面）豁免。新值先进 `Theme` 再用。
- **用真实工具链构建验证。** 编不过 Swift 6 严格模式的设计改动不算做完。
