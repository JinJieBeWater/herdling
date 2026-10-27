# UI & Design System

Herdling 的界面规范。面板几何与交互以原生 `NSMenu` 为参照；图标与文字角色参考 [Tinycast](https://tinycast.dev/)（`abue-ammar/tinycast`，AGPL-3.0）。本文档只描述**Herdling 自己的**取值与结构，同名 token 的数值独立。

改任何 view body、`Theme` 取值或面板外观前先读本文。`Sources/Herdling/DesignSystem/Theme.swift` 是 token 的唯一来源。

---

## 平台分档

- **macOS 15 是地板**：滚动边缘渐隐使用 `onScrollGeometryChange`（15+）。
- **macOS 26 是视觉层级的分档**：面板玻璃由 `NSGlassEffectView` 提供（26+），与系统右键菜单同为 Liquid Glass；以下退回 `.menu` 材质。面板照常工作，只是少一层折射。

## 一眼看过去

Herdling 是一个**只展示列表的菜单栏下拉面板**：无边框面板，以原生 `NSMenu` 的系统玻璃为基底，使用20%的系统窗口背景色作中性 tint，降低繁忙背景对长名单的染色；不压 scrim、不叠灰底。普通文字使用 SwiftUI 层级样式，随玻璃取 vibrancy；悬停与键盘选择使用系统选中背景色与清晰的选中文字色。内容溢出时底边渐隐。刷新、设置和退出放在状态项右键菜单，不设独立底栏。

暗色是基准，亮色是同一套几何配反转的墨。

五条承重规则，按优先级：

1. **只有原生玻璃承载表面。** 不用实底、不叠 scrim；中性 tint 作用于玻璃自身，随系统浅暗外观变化，不保证与原生菜单像素相同。`NSVisualEffectView(.menu)` 只是 26 以下的回落，不等于 26+ 原生菜单的质感。
2. **普通墨色用层级样式，高亮文字不牺牲可读性。** 普通文字用 `.primary`／`.secondary`／`.tertiary`，高亮行通过 `backgroundProminence = .increased` 转成白字；次级文字此时使用 `selectedMenuItemTextColor`，不再继续降低透明度。状态字形在普通行保留语义色，在高亮上转白。
3. **只有一层玻璃。** 面板是 NSGlassEffectView，视图中不叠第二层 `glassEffect`。
4. **边缘渐隐。** 内容超过窗口时淡出底边；滚到底时恢复实色。
5. **交互高亮按命令菜单统一。** 名单可用行的悬停、键盘选择、顶栏悬停和行内命令均使用 `selectedContentBackgroundColor` 及白字，不把原始 `accentColor` 直接铺成大色块。当前视图只用文字和图标明暗区分，展开来源只用箭头与展开内容表达，不常驻铺底；右键检查保留短暂中性底色。不可用项不显示强调色。高亮不提交定位。

---

## 不可动的不变量

- **颜色只从 `Theme.Colors` 取。** 普通面板墨色用 `AnyShapeStyle` 保留层级样式，不先转成固定 alpha 的 `Color`；选中背景与选中次级文字使用各自的系统颜色角色。本机对照中，`Color.primary.opacity(…)` 和 `NSColor` label／system fill 未取得同样的普通文字 vibrancy；不能拿它们替代普通文字 token。中性状态底色单独用自适应白色填充。`ramp(dark:light:)` 只留给 AppKit 自绘的滚动条和需要不透明 alpha 的遮罩、template 图像。视图里不写 `Color.white.opacity(…)`、`.gray`、`NSColor.windowBackgroundColor`；玻璃 tint 的系统颜色也由 Theme 提供。
- **不叠玻璃。** 分组不是玻璃板，面板是唯一的玻璃表面。折叠/展开靠箭头方向、内容与间距表达。
- **不用固定字号。** 只有系统文字样式，`Theme.Typography` 里具名。写死 11.5pt 是回归。
- **测量出来的高度属于窗口，不属于 view。** 列表通过 `PanelContentHeightKey` 发布包含内缩的完整高度，`PanelHeightBridge` 驱动窗口；不再叠加固定操作条高度。
- **一行只有两级信息。** 标题 `textPrimary` + 尾部读数 `textSecondary`，读数里不再有第二种颜色：数字和状态词同色。一行里出现三种灰，读起来就是"这几个字为什么不一样"。
- **header 的尾部只放一个读数。** 分支名是标题的**副标**（紧跟标题、`lg` 间距），不是读数：它曾和计数一起塞在尾部簇里，同色同字号、只隔 10pt，于是两者被读成一句话（`docs/assessment-consulting 2 idle`），而标题与这堆东西之间空出 160pt。现在是 tinycast 的行文法：`字形 ─ 标题 ─ 副标 ─…─ 尾部读数`。
- **身份优先于元数据。** 来源和工作区先保标题，分支名先压缩；尾部最多显示优先级最高的两种状态（blocked → done → working → idle → unknown），完整计数保留在 help 和辅助功能中。不靠加宽面板或加高行容纳元数据。
- **前导图标按 Tinycast 的角色区分字重。** 分组、来源、状态、错误和 Settings 共用 `RowSymbol`：22pt 透明槽位中的 14pt Regular 单色 glyph；导航使用 14pt Medium 和独立14pt槽。来源用中性色，状态和告警保留语义色。没有底板、描边或独立圆角。
- **状态色是语义，不是装饰。** `StatusPalette` 已按亮/暗 + 高对比度四路自适应，普通行保留它；强调色高亮时字形改用白色，符号与辅助功能仍表达真实状态。
- **可访问性与 Reduce Motion 一直保留。** 每个折叠动画都走 `AccordionMotion.animation(reduceMotion:)`，每个图标 `accessibilityHidden`，每行有 `accessibilityLabel`/`Hint`。
- **交互不变。** 重做外观不改行为：折叠状态持久化、悬停清理、错误行的 retry/dismiss、点击焦点行为都保持原样，除非任务本身就是改它。
- **来源展开偏好归 store。** `expanded.source` 由 `SessionStore` 通过注入的 `defaults` 读写。快速入口不折叠；不再使用 `expanded.recent`。用 `@AppStorage` 会绕过 store，污染用户偏好与测试。
- **原生滚动条是 overlay 的。** `AppDelegate` 启动时把 `AppleShowScrollBars` 设成 `WhenScrolling`，避免 legacy 滚动条在透明面板右侧占据固定 gutter。

---

## Tokens

`Theme` 是唯一事实源。有 token 就不要写 magic number。

### Spacing

`xxs 2` · `xs 4` · `sm 6` · `md 8` · `lg 10` · `xl 12`

行内容左右内缩 `rowHorizontal`；列表水平内缩 `panelInset`。

行内、行间、组间各有预算，不能用增大行内 padding 代替高亮之间的分隔：

| token | 用途 |
| --- | --- |
| `rowHorizontal 6` | 高亮到行内容的左右内缩，与附加菜单行同一预算 |
| `rowVertical 5` | 正文上下内缩，22pt 槽位形成 32pt 行框；空间 caption 也占这一行高 |
| `sectionHeaderVertical 8` | 来源顶层标题上下内缩，保持 38pt |
| `rowGap 2` | 同组正文行、树内标题与第一行子项之间；正文中心节奏为 34pt |
| `sectionBodyGap 4` | 顶层标题与展开正文之间；放在折叠体内，收起时一起消失 |
| `navigationHeaderGap 4` | 固定视图顶栏与列表之间；不靠行内 padding 隔开两块背景 |
| `panelInset 6` | 顶栏与名单共用的左右背景边界 |
| `panelBottomInset 6` | 与侧边共用同一外壳留白 |
| `navigationVisualInset 5` | 38pt点击区与居中28pt表面的单侧余量 |
| `navigationTopInset 1` | 顶部点击区留白；加上5pt表面余量后，可见底块到外壳为6pt |
| `navigationContentInset 10` / `navigationContentGap 10` | 补偿14pt导航槽与22pt名单槽的半宽差；导航组首项与名单的图标中心在23pt，未缩进标题从40pt开始 |
| `groupGap 8` | 相邻来源子组、session、空间和 worktree 组之间 |
| `sectionSpacing 4` | 顶层 section 之间；展开前后均为 4pt，组内间距不变，不加尾部 padding |
| `rowContentGap 6` | 前导图标槽与标题之间；标题副标和尾部槽位仍用 `lg` |
| `indent 12` | 每个可见树层级的内容内缩；来源顶层标题是 section 容器，不额外消耗一层 |

正文的字号保持系统 `.body`，不是按 iOS 的 17pt 推算行高。当前 macOS 默认 body 实测 13pt；字体与行框高度是两件事。

快速入口的两行身份使用 `quickRowHeight 40`，顶部视图切换使用 `navigationHeaderHeight 38`；不是给全部目录行增加行高。


### 静默 agent

Activity和Sources的agent行右键先选中检查目标，再打开同一紧凑命令菜单；不提交定位。只保留`Open`和用勾选表达本机偏好的`Mute`两行，不重复目标标题、不设分隔线或快捷键帽；目标身份保留在窗口的辅助功能标题中。按来源＋Session＋pane保存，不推断父子关系。静默项不增加铃铛、角标、策略文字或操作列，而以更轻的标题与状态色表达。菜单作为独立原生玻璃子面板，固定锚在被右键行的右下侧，右缘对齐该行、间隔4pt；同一行内不同点击位置不改变菜单位置，不再贴主面板底部。下方空间不足时向上展开，并夹在屏幕可见区域内。行移动时重读锚点，行已不可见时收起菜单；不撑大名单。辅助功能的Actions使用同一行锚点。不引入Tinycast的底栏或动作搜索。

菜单内方向键切换动作，Return／Space执行，Escape只收菜单并归还名单焦点。当前动作按原生菜单以强调色底、选中菜单文字色高亮，字形与标题同色。右键检查只在菜单显示期间使用轻底色，关闭后消退。键盘操作显示强调色高亮，仍绑定精确身份。点击菜单外的名单先收菜单，消费这次点击，不穿透定位，并结束鼠标检查强调；点击应用外仍收起整个面板。正常点击、滚动、键盘浏览和原有快捷键不变。

Activity保持同一列表，没有折叠区或新页签。普通项全部在前，静默项全部在后；两组内部按blocked、done、working、idle、unknown及状态时间排列。静默idle不占普通idle最近三项名额。切换静默偏好立即重排当前成员，选择仍绑定原身份；可追加本次已知但尚未进入Activity的静默身份，不招入浏览期间的新到达者。取消静默立即恢复普通优先级；本次成员保留，下次打开恢复普通idle限制。普通状态刷新不挪行。Sources保留原来源、Session及工作区层级与顺序。

静默标题保留正常字号与字重，使用普通标题80%的墨色；working保留蓝色与真实字形，墨色约65%，副标题维持次级色。blocked字形用中性色，不重复强调完成／blocked。不整行加透明度、不改变行高、前导槽或标题锚点，帮助及辅助功能保留`Muted`与真实状态。Opening、Unavailable及定位失败反馈不弱化。鼠标静默后当前视口不追滚到下移目标；键盘操作继续显示精确选择并跟随重排。点击与定位保持原协议；标记动作本身不提交定位，也不修改Herdr的seen。

菜单栏及来源／Session／工作组汇总保留静默项的working等常态数量，排除它们的blocked／done关注数量。来源连接故障照常显示。偏好保存在注入的UserDefaults，沿用原存储键与身份，不重置已有标记；临时掉线保留标记，已确认在线快照中消失的pane或删除的来源移除对应标记。

### Radius

#### 全UI的角色规则

主面板与附加操作菜单共用12pt外圆角、6pt内容留白和6pt高亮圆角。顶栏、来源与普通行遵循同一套菜单轮廓，不再保留26pt大外框、13pt留白及独立的8／10pt控件标度。32／38／40pt行高与28pt导航表面保留，避免把双行身份或目录内容硬压成普通菜单行。短行内动作和原生系统控件保留各自形状；裸图标没有底板。

本机macOS27的无显示布局探针读到原生`NSMenu`内建`NSGlassEffectView.cornerRadius = 12`，上下padding为5pt。主名单留白取6pt是长列表适配，不声称原生四边均为6pt：它让4pt滚动条、1pt外边距与1pt内容间隙同时成立。产品不依赖测量所用的私有菜单布局接口。

名单高亮沿统一容器边界裁切一次，不再叠独立键盘描边。先把底色画成交集再叠容器遮罩会重复抗锯齿，让边缘变淡。边界测量留在设计系统，不向来源、会话、worktree、agent逐层传递首末标记；不改变行高、命中区或滚动布局。

设置窗的副标题和说明使用系统secondary色，原生Form不在玻璃上，不套名单的墨色token。菜单栏标记保留独立的小尺寸与template渲染，不跟面板一起放大。

`panel 12` · `panelContent (6, 6)`（两轴均为 `panel − panelInset`）· `row 6` · `navigationControl 6`

按相邻轮廓分配圆角，不让所有元素使用同一个半径：

| 元素 | 规则 |
| --- | --- |
| 面板 | 12pt；玻璃根层裁剪与 SwiftUI 都用连续曲线 |
| 贴顶首行高亮 | 可见表面距外壳6pt；命中区的5pt余量不计入可见底块 |
| 贴底末行高亮 | 距外壳6pt，内边界两轴均使用6pt连续曲线；不单独扩底部padding |
| 普通行与内部相邻角 | 6pt，与菜单高亮统一，不做成胶囊 |
| 顶栏选项 | 28pt视觉表面居于38pt点击区中央；上、左可见留白6pt，四角均6pt，不单独放大Activity左上角 |
| 前导图标 | 透明槽位，不绘制底板，因此没有图标底板圆角 |
| 行内操作 | 高20pt，使用同一6pt圆角；用紧凑尺寸而非胶囊区分动作与内容行 |
| Agent附加操作菜单 | 独立玻璃子面板，208×68pt、12pt连续角；两行各28pt、6pt普通角，13pt Regular字形居于18pt透明槽位，与标题同色；当前动作用强调色高亮，不做大按钮。锚在目标行右下侧、间隔4pt，靠屏幕下缘时翻到行上方；菜单内侧6pt，与主面板共用外框标度 |
| Settings 分组与系统控件 | 由原生 `Form`、Picker、Toggle 绘制，不覆盖系统圆角 |

列表内容边界使用 `RoundedRectangle(cornerSize: CGSize(width: 6, height: 6), style: .continuous)`；各行自身也画6pt圆角。顶部切换行与名单各自负责左右6pt内缩，不额外内收导航按钮组。38pt点击区顶部留1pt，加上5pt表面余量形成6pt可见留白；底部6pt，完整高度计入1+6pt。验收比较真实底色到外壳的直边和转角距离，不以列对齐或圆角中心相同代替。离线提示与名单尾部内容区共享距右侧12pt的右边界；读数仍保留各自的箭头或chevron槽位。名单滚动视口保持420pt全宽，行背景宽408pt，边界遮罩在右侧边距开放滚动条绘制空间。首末边界跟随真实内容，计入完整测量高度，不沿树逐层传递位置标记。

圆角矩形统一 `.continuous`；首末行只沿真正相交的容器边缘转弯，不把四角一起放大。普通行填充由整体遮罩裁切一次。整体遮罩保留文字与滚动条边界。独立圆形／胶囊控件保留各自形状。

### Size

`panelWidth 420` · `panelMinHeight 100` · `panelTopMargin 0` · `panelBottomMargin 16` · `panelScreenFraction 0.85` · `rowIcon 22` · `rowMinHeight 32` · `actionPill 20` · `progressIndicator 12` · `chevron 20` · `scrollFadeHeight 24` · `menuBarGlyphWidth 11` · `menuBarGlyphHeight 13` · `settingsWidth 560` · `settingsHeight 560` · `settingsMinHeight 420`

`rowIcon` 是行首图标的**固定槽位**。比槽位小的glyph居中放进槽位，而不是把槽位缩到自身大小，展开/折叠时标题列不会左右跳。导航保留独立 `navigationIcon 14`，通过10pt水平内缩与10pt图文间距补偿槽位差，不复制名单22pt槽；导航与未缩进名单的图标中心、标题起点对齐。`navigationControlHeight 28`只决定表面，`navigationHeaderHeight 38`仍决定点击区与测量高度。

尾部chevron透明槽为20pt，字形仍是10pt，不把箭头放大。它与前导22pt槽接近，同时让箭头墨迹避开原生overlay滚动条较宽的命中区；没有chevron的同类行也保留同一读数列，不为滚动条挪背景或加单侧列表留白。

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

SF Symbol 的显式字号，也是 token：`leading 14 regular` · `navigation 14 medium` · `chevron 10 semibold` · `actionSymbol 9 semibold` · `focusArrow 10` · `emptyState 15 medium` · `menuBar 11 medium` · `menuBarDigit 11 semibold monospaced`

菜单栏那三个是菜单栏自己的尺度（画进 image，不是画在面板里），所以自带数字，不借行的。

### Colors — 层级样式

| token | 样式 | 实测 alpha（暗／亮，离屏） | 用在哪 |
| --- | --- | --- | --- |
| `glassTint` | 系统 `windowBackgroundColor` | 0.20 | 主面板与操作菜单的原生玻璃自身；不增加内容层 |
| `unavailableSelection` | 白色 | 0.10／0.50 | 不可用的键盘目标，保留位置但不承诺可操作 |
| `inspection` | 白色 | 0.06／0.32 | 附加操作菜单打开期间的目标检查底色 |
| `textPrimary` | `.primary` | 0.85 | 行标题、正文 |
| `mutedTitle` | `.primary.opacity(0.8)` | 0.68 | 静默 agent 标题，轻于标题、重于次要字 |
| `textSecondary` | 普通 `.secondary`，高亮 `selectedMenuItemTextColor` | 普通0.55／0.50，高亮1.0 | 次要标签、状态词、无语义色的状态字形、折叠箭头；高亮仍清楚 |
| `textTertiary` | `.tertiary` | 0.25 | 占位、不可用文字 |
| `warning` | 亮色深橙／暗色杏橙 | 不透明语义色 | 面板离线与错误字形；离线文字仍用原生primary，不复用Settings装饰橙 |
| `highlight` / `highlightInk` | `selectedContentBackgroundColor`／`selectedMenuItemTextColor` | — | 名单悬停与键盘选择、顶栏悬停、行内命令、附加操作菜单 |
| `opaqueInk` | ramp 1.0 | 1.0 | 遮罩与菜单栏 template 图像，只看 alpha |
| `scrollThumb*` | ramp 0.30／0.42／0.50 | — | AppKit 自绘滚动条，不在 SwiftUI vibrancy 内 |
| `fadeFloor` | — | — | 底部渐隐最深只到 0.25：行留影子，不消失 |

**色相**（`Theme.Hue`）按色相命名而不是按角色：`blue` · `purple` · `orange` · `green`，留给Settings等非玻璃装饰角色。面板警示字形使用独立`Colors.warning`：亮色`#994A00`、暗色`#FFAB4D`；离线小字使用原生`textPrimary`，不以另一种固定橙色替代材质感知墨色。普通／静默／不可用层级保留原生vibrancy，高亮次级文字改用不透明选中文字色。blocked四路不变；working 使用独立四路语义蓝，普通浅色为深蓝、暗色为亮蓝，不再直接复用交互强调色。警示色在白／深灰参照上的对比通过，不等于任意真实玻璃背景都通过；状态同时由文字与字形表达，不叠scrim。来源不再用蓝／紫区分，本机和SSH靠符号、文字及辅助功能表达，均使用`textSecondary`。**本地/SSH的符号判断只在`SourceInfo.rosterSymbol`里写一次**。

`StatusPalette`（`AgentStatusPresentation.swift`）不在 `Theme` 里，它是状态的语义色，自带四路自适应。

**名单只在交互时铺底。** 强调色高亮 → 右键检查 `inspection` → 透明；展开本身不铺底。最后一次真实鼠标移动或键盘操作接管唯一高亮，Enter 对应当前目标；静止指针下的滚动、布局和刷新不抢走键盘选择。高亮和选择都不提交定位。

### Duration

`expand 0.18`

折叠动画用 `.smooth(duration: expand)`；悬停填充不带动画（tinycast 的行悬停是即时切换）。

---

## 面板结构

来源：`StatusItemController.swift`、`UI/AgentListView.swift`。

- **窗口**：无边框 `NSPanel`，`isOpaque = false`、`backgroundColor = .clear`、`.popUpMenu` level、`hasShadow`、`animationBehavior = .none`。位置贴着菜单栏 item 下沿，左右被屏幕可见区域夹住（`StatusItemController.panelOrigin` 已实现，不改）。
- **表面配方**，顺序固定：
  1. macOS 26+：`panelGlass(wrapping:cornerRadius:)` 生成 `NSGlassEffectView(style: .regular)`，设置 `Theme.Colors.glassTint`，作为窗口 contentView；tint 通过动态 NSColor 在当前 appearance 下解析系统窗口背景色，再取20% alpha，避免固定首次浅／暗外观；主面板与附加操作菜单共用，各传自己的圆角；
  2. 内容直接放在玻璃上，不盖 scrim；
  3. 最后 `.clipShape(RoundedRectangle(panel, .continuous))`。
  26 以下回落到 `NSVisualEffectView(material: .menu)`。验收在真实桌面上与原生右键菜单并排比较；VM 或离屏截图只证明透出背景，不证明玻璃质感一致。
- **玻璃始终保持激活外观。** Liquid Glass 只在激活外观下折射背景，非 key 窗口会变平。原生 `NSPopupMenuWindow` 并非 key 却始终折射，靠的是 `_hasActiveAppearanceIgnoringKeyFocus`；`MenuBarPanel` 同样覆写，主面板在附加操作菜单取得 key 时也不变平。只改外观，不伪造键盘焦点。
- **玻璃根层也裁圆角。** `NSGlassEffectView.cornerRadius` 与 SwiftUI 的 `clipShape` 不足以约束激活状态下的全部玻璃绘制；玻璃根 `CALayer` 用同一个 `Theme.Radius.panel`、与 SwiftUI 一致的 `.continuous` 曲线，并启用 `masksToBounds`。保留键盘焦点和窗口阴影。
- **名单背景左右6pt，末行底部6pt。** 首末边界跟随面板内轮廓，内部相邻角同为6pt；顶栏点击区顶部1pt加上表面余量后，可见留白为6pt。不留操作条或safe-area占位。
- **菜单操作独立于列表。** 右键或 Control-click 状态项打开原生菜单：Refresh、Settings、分隔线、Quit Herdling。刷新期间禁用 Refresh，并防止重复启动。Settings 的 `⌘,` 和退出的 `⌘Q` 继续通过应用菜单提供。

---

## 行、选中、悬停

### 查看与定位

行为与验收范围见 [Agent 查看与定位设计](agent-navigation-design.md)。HTML 原型不代替原生验收。

- 顶栏用 **Activity / Sources** 互斥视图切换，两个选项之间保留xs（4pt），按钮背景与名单共享6pt左边界。Activity用波形表示状态动态，Sources用服务器表示本机和SSH来源；14pt Medium裸字形使用独立14pt槽，后接10pt布局间距和10pt水平内缩，没有图标盘。图标中心与未缩进名单同在23pt，文字从40pt开始。当前选项使用主色文字和图标，其余使用次级色；两项静止时均透明，悬停时按命令菜单显示强调色底、白字和白色图标。28pt视觉表面居于38pt点击区中央，上、左外壳留白均6pt，四角均6pt。没有整条底板、共用轨道、下划线、常驻边框或第二层玻璃；当前视图不使用常驻底色。每次打开进入Activity：在线blocked → done → working → 最近三个idle；各等级按Herdr的状态更新时间由新到旧，同时间保留来源快照顺序。整个列表平铺，不显示分组标题或额外数量；idle不依赖成功定位记录。
- 顶栏选项使用系统 callout Regular（macOS 默认12pt），两项及选中前后的字号、字重相同；选中靠底色与文字明暗区分。列表标题仍为 body，分组标题仍为 subheadline Medium。
- 顶栏离线提示显示橙色网络图标和 `1 offline` 这类短文案，help/辅助功能提供来源名称与状态；覆盖部分 Session 不可用的来源。文案不挤进12pt数字槽。快速列表不再放整行离线警告。右侧不显示重复的 working、ready，左侧状态图标与完整辅助功能状态保留；Needs input、Completed、Opening、不可用状态与 Retry 保留。
- **顶部与未缩进名单共享背景、图标和文字锚点。** 短导航保留14pt槽、10pt内缩和10pt图文间距；名单保留22pt槽、6pt内缩和6pt图文间距，以不同的角色预算对齐图标中心和标题起点。整条顶栏保持透明。空摘要不参与尾部布局，Retry与状态数量的右缘保持一致。
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

- 行首固定 `rowIcon` 槽位与标题之间用 `rowContentGap`；标题与可选副标、尾部读数槽位之间用 `lg`。正文上下内缩 `rowVertical`，顶层标题用 `sectionHeaderVertical`；左右均为 `rowHorizontal`。
- 行背景用 `row` 连续圆角，列表整体裁切负责首末边界；可用项的fill优先级 **highlight → inspection → clear**。不可用定位项不显示强调色，也不显示hover操作暗示；Unavailable和原因仍保留。键盘停在不可用项时用中性unavailableSelection底保持可见，冻结访问期间的选择身份不因失效改变，浏览器既有选择策略不变。离线来源标题仍可浏览，不禁用。
- current靠文字与图标明暗，来源展开靠箭头；键盘选择与悬停用强调色。不同状态不叠底、不位移。按下反馈与原生键盘focus交给plain Button样式，不额外叠加按下透明度或抢占Tab。
- 行内悬停反馈留在行里；名单高亮由浏览器按精确身份统一，真实鼠标移动才交接，不用布局触发的进入事件冒充输入。
- 面板重新打开时清掉遗留的悬停（`panelIsOpen` 环境值，行为保持现状）。
- 缩进靠内容内缩，高亮仍按行自身盒子铺满 —— 缩进行不会得到一段空白高亮。
- **空态**（`RosterEmptyState`）是居中的图标 + 一句话，两行之间 `xs`。它不占一行的位置，也不缩进：空的是"这一组没有东西"，不是"有一行空的行"。
- **错误行**也走同一套：左侧`RowSymbol`（warning色`exclamationmark.triangle.fill`）、文字`rowTrailing`、尾部用`RosterActionPill`（裸着，悬停才出强调色6pt圆角；所在行已高亮时不再叠底色）。不用带边框的系统按钮。

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
- 填充：悬停和键盘选中时用强调色，指针离开后透明；展开状态只由箭头和内容表达。
- 展开箭头普通态用次级墨色，高亮态转白；不另加底板或徽标。
- 顶层 header 与正文之间隔 `sectionBodyGap`；section 之间隔 `sectionSpacing`。树内部标题与子项之间用 `rowGap`，兄弟组之间用 `groupGap`。没有分隔线、没有底板。
- 折叠动画走 `AccordionMotion`，高度由实测内容高度驱动（`AccordionBody` 保持现状）。

### 嵌套层级

来源 → session → space → worktree → agent 是数据的固有深度，用 token 表达：

- session header：`sectionHeader`，`textSecondary`；
- 空间（多分支）：安静 caption + `textSecondary`，预留透明图标槽，文字与同级单 worktree 空间标题对齐；其下 worktree 再缩进一级；
- 空间（只有主 worktree）：**用普通的 header 行**（`GroupHeaderRow`，`isExpanded: nil`，无 chevron、无常驻填充）。Herdr 给每个 workspace 一个叫 `Main` 的 worktree，没有分支的空间会得到一排一模一样的 `Main`；那一行没有信息，但**不能只是删掉**——删掉组就没有头了。它与 worktree 行同一档：同样的状态字形、同样 `.body.weight(.medium)`、同样的尾部读数列，**点击行为也同一档**（在所选终端打开这个 workspace），外观与行为都不分叉。
  - 粗体标题的含义是「直接领 agent」；多分支的空间用安静 caption，因为它领的是 worktree 行。
  - 判定问结构（`RosterSpace.isOnlyItsPrimaryWorktree`），不是显示名，所以 herdr 改名叫不出错。
- worktree：`rowTitle.weight(.medium)`，缩进 `indent`；
- agent：`rowTitle`，在 worktree 基础上再缩进一级 `indent`，尾部是悬停才出现的焦点箭头。

每个**可见**层级只加一次 `indent`，所以列是 0 / 12 / 24 等距递进。session 标题显示时，其正文缩进一级。省略 Main 就少一级，因此不同深度的 agent 不必绝对对齐。加载与错误行继承所在层级的缩进；Activity 不引入目录缩进。

---

## 状态呈现

- 徽章/图标用 `StatusPalette` 的 blocked / working 四路语义色；working 不与选中背景共用原始强调色。
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

名单滚动条使用独立实现的4pt细条。普通状态隐藏；滚动、悬停和拖动时宽度都为4pt，只改变深浅，不画整条背景轨道。thumb按内容比例变化，最短28pt；上下8pt留白避开面板外圆角；内容未溢出时不显示。

使用AppKit的overlay `NSScroller`，只替换绘制；保留原生拖动、轨道点击、滚轮、自动淡出和辅助功能。覆盖系统scroller样式变化仅限名单，不修改系统偏好或Settings。滚动视口横跨420pt面板，名单内容与固定顶栏各保留左右6pt边距；细条画在x415–419，距面板右边缘1pt，与行背景右边x414留1pt间隙。宽于细条的原生命中区可以延伸进空白内边距，不能覆盖箭头或读数。

行高亮四态保持408pt完整宽度，左右边界对称，文字不随滚动条显隐移动。不保留固定单边槽或额外文字净空。内容边界两轴均6pt，底部留白6pt；右侧滚动条另获透明绘制空间，不增加玻璃层或可见面板背景。

保留行高和固有高度测量、键盘 `scrollTo`、24pt 底部渐隐与定位动作。当前自动淡出时序沿用 AppKit，不另建计时器。

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
- **间距和位置要有断言，不能靠眼睛。** `swift test --filter RosterRenderTests` 会用真实 AppKit 布局把面板、层级、Settings 渲染成 PNG，输出到每次新建的 `/tmp/herdling-render-<UUID>`，日志给出路径；不覆盖旧证据。`PanelLayoutTests` 验证完整面板高度、行高与展开留白，`PanelChromeTests` 验证文字列和轮廓；渲染窗口放在屏幕外，避免真实指针触发悬停。截图看感觉，断言看回归。
  - 离屏渲染要用 `NSHostingView` + `NSWindow`，**不要用 `ImageRenderer`**：它不跑 `onPreferenceChange`，所有测量出来的高度都是 0，手风琴会渲染成空的。
- **不要加没被要求的行为。** 重做外观就是重做外观。
- **新取值进 `Theme`**，视图里不留 magic number。
- **共享语法保持共享。** 行内缩、fill 优先级与分组 header 样式只写一份，分叉是 bug 不是特性。
- **字面量会被测试拦住。** `DesignTokenTests` 扫 `Sources/Herdling`：颜色、字号、内边距、frame、opacity、动画时长里任何裸字面量都算失败，只有 `Theme.swift`（token 本身）和 `HerdrBrand.swift`（512pt 品牌图标， artwork 不是界面）豁免。新值先进 `Theme` 再用。
- **用真实工具链构建验证。** 编不过 Swift 6 严格模式的设计改动不算做完。
