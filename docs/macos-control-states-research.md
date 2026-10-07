# macOS 控件状态与图文间距

范围：只查 Apple HIG、SwiftUI、AppKit、SF Symbols 官方资料。Herdling 为 420pt 菜单栏单玻璃面板；Activity / Sources 使用 12pt Regular 文字、11pt 裸图标、38pt 高度、4pt 选项间距。本文只研究，不实现状态 UI，不改变来源手风琴可全部收起的行为。

## 状态先分清

**官方原则与 API 定义**如下；具体颜色、透明度和圆角并无适用于所有 macOS 控件的统一状态表。

| 状态 | 含义与视觉依据 | 不能代替什么 |
| --- | --- | --- |
| default / resting | 无瞬态输入的常态；系统按钮样式提供交互状态与外观适配。[1] | 不是响应 Return 的 default / primary button，也不等于未选中 |
| hover | 指针进入控件范围；SwiftUI `onHover` 定义进入/离开，不规定填充颜色。HIG 的 macOS 按钮章节明确延迟显示 tooltip。[1][5] | 不是选中、按下或键盘焦点；“悬停必须有背景”未获证实 |
| selected / current | 持续选择或当前视图。HIG 分段控件区分 selection 与 momentary action；两种语义不应混在同一组。[3] | 不是鼠标按住，也不是当前键盘目标 |
| pressed | 正在按按钮，属于瞬态反馈；`isPressed` 定义明确。HIG 要求自定义按钮始终提供 press state。[1][5] | 松手后不能靠残留 pressed 外观表示 current |
| keyboard focus | 键盘交互目标。HIG 建议采用系统焦点效果；macOS 可用环或高亮，列表通常高亮整行。[2][6] | 焦点移动不必切换视图；有时与 selection 重合，但概念不同 |
| disabled | 控件不允许交互，`isEnabled` / `disabled` 定义如此。[7] | 不是未选中、弱化文字或来源 offline；offline 来源仍可能可展开或重试 |
| emphasized / inactive selection | AppKit 行选择可依 `isEmphasized` 使用不同选择颜色。[8] | 窗口/列表强调程度变化不代表选择已取消，也不等于 disabled |

可同时存在 `current + hover`、`current + focus`、`current + pressed`。应分别记录，再组合绘制；不能用一个 `active` 布尔值包办。此为基于上述定义的**设计建模建议**，不是 Apple 指定实现。

## 对 Herdling 的设计建议（非官方规范）

- 先定义两条一致语义：**current 表示正在看什么，hover / pressed 表示正在操作哪里**。导航与列表共享反馈强弱逻辑，不必复制同一种底板；列表整行高亮有官方依据，导航未被规定必须同样填充。
- 用户已拒绝当前激活背景，不能仅调低其透明度再称“原生”。可先比较不依赖背景的 current 表达，但必须在指针离开后仍能识别当前视图；仅令 `selected || hovered` 同色不足以保证两者可辨。
- 将未选中 hover、当前项 hover、按下、键盘焦点和不可用状态放在**同一完整面板**比较。避免 hover 一个选项时出现两个同等“当前项”；按下反馈需短暂且可见，focus 仍须可定位。
- 字号、字重、图标槽和标签位置在状态切换时保持稳定；用外观反馈，不靠变宽、变粗或位移制造状态。颜色之外的 current 辨识与浅/深色、高对比度也需实际验收。
- 保留 38pt / 4pt 作为本项目研究起点，不宣称 Apple 指定值；不新增玻璃层，不把 hover 外观改动与手风琴展开策略绑定。

## icon + text：量墨迹，不只量 frame

**官方依据**：SF Symbols 的字重对应 SF 字体字重；small / medium / large scale 相对 cap height 定义，可在同字号下调整强调程度。系统符号与文字自动对齐；自定义符号支持 negative side margins 以改善光学水平对齐。[4] SwiftUI `Label` 是官方图标加标题组件，但公开文档没有承诺固定图文间距。[9]

**本项目观察**：当前导航复用 `RowSymbol` 的 22pt 固定槽位，后接 `rowContentGap = 6pt`。11pt 是图标字体大小，不是可见墨迹宽度。槽位右侧留白也会被看成图文间距，所以“设置了 6pt”不等于眼睛看到 6pt。

```text
可见图文空隙 ≈ 图标槽右侧余白 + 布局 gap + 文字左侧 bearing
```

**设计建议**：导航是短图文组合，列表槽位是跨行对齐工具，不必共用宽度。先用同字号、同字重并调 symbol scale 的组合做对照，另与现有 12pt Regular + 11pt 图标比较；固定裸图标规则不变。量每个实际 symbol 的墨迹边界、文字基线与组合重心，再比较较紧槽位或标准 `Label`。若需实验，可对比 4 / 6 / 8pt 布局 gap；这些是候选值，**不是 Apple 推荐值**。切勿仅因 frame 居中就认定 optical spacing 正确。

## 可引用官方段落

以下为原文摘录；网页需 JavaScript，已核对同路径 Apple DocC JSON（`https://developer.apple.com/tutorials/data/` + 页面路径 + `.json`），不是搜索摘要。

1. [HIG — Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons)：
   > “System buttons offer a range of styles that support customization while providing built-in interaction states, accessibility support, and appearance adaptation.”
   > “Always include a press state for a custom button.”
   > “In macOS and visionOS, the system displays a tooltip after people hover over a button for a moment.”
2. [HIG — Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)：
   > “In many cases, focusing an item also selects it. The exception is when automatic selection might cause a distracting context shift, like opening a new view.”
   > “Rely on system-provided focus effects.”
   > “In general, use a focus ring for a text or search field, but use a highlight in a list or collection.”
3. [HIG — Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls)：
   > “Don’t assign actions to segments in a control that otherwise represents selection state, and don’t show a selection state for segments in a control that otherwise performs actions.”
4. [HIG — SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)：
   > “Each symbol is also available in three scales: small, medium (the default), and large. The scales are defined relative to the cap height of the San Francisco system font.”
   > “Specifying a scale lets you adjust a symbol’s emphasis compared to adjacent text, without disrupting the weight matching with text that uses the same point size.”
5. SwiftUI [isPressed](https://developer.apple.com/documentation/swiftui/buttonstyleconfiguration/ispressed)：
   > “A Boolean that indicates whether the user is currently pressing the button.”
   SwiftUI [onHover(perform:)](https://developer.apple.com/documentation/swiftui/view/onhover(perform:))：
   > “Adds an action to perform when the user moves the pointer over or away from the view’s frame.”
6. SwiftUI [FocusState](https://developer.apple.com/documentation/swiftui/focusstate)：
   > “A property wrapper type that can read and write a value that SwiftUI updates as the placement of focus within the scene changes.”
7. SwiftUI [isEnabled](https://developer.apple.com/documentation/swiftui/environmentvalues/isenabled)：
   > “A Boolean value that indicates whether the view associated with this environment allows user interaction.”
   SwiftUI [disabled(_:)](https://developer.apple.com/documentation/swiftui/view/disabled(_:))：
   > “Adds a condition that controls whether users can interact with this view.”
8. AppKit [NSTableRowView.isEmphasized](https://developer.apple.com/documentation/appkit/nstablerowview/isemphasized)：
   > “Determines whether the row will draw with the alternate or secondary color (unless overridden).”
9. SwiftUI [Label](https://developer.apple.com/documentation/swiftui/label)：
   > “A standard label for user interface items, consisting of an icon with a title.”

## 未核实边界

未实测各 macOS 版本、原生按钮样式在这块玻璃上的精确 hover / pressed / disabled 像素效果；未核实 12pt / 11pt、38pt、4pt、22pt 槽位或某一透明度为 Apple 标准。未测当前两个图标的实际墨迹边界，故不能断言应缩几 pt。HIG 的 tvOS 五状态示例、visionOS 按钮外观及网页 CSS `:hover` / `:active` / `:focus` 均不作为 macOS 外观结论。
