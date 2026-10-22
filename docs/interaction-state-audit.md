# 交互状态与导航控件间距

## 当前结论

问题不是“再淡一点”。同一块玻璃上，导航的 current 底色与列表的 hover 底色相同，导航却占满38pt高度；颜色、状态含义和控件体量脱节。图标与文字之间也不是视觉上的6pt。

下文保留改动前研究证据。用户已批准整套方案，原生实现与本机验证完成；来源仍允许全部收起。官方资料见 [macOS 控件状态研究](macos-control-states-research.md)。实现完成不代表用户已接受最终美观效果。

## 原生状态对照

证据：本机 `.build/interaction-state-evidence-BJLrTD/native-state-sheet.png`。12张实际应用截图，非 CSS 仿制。只切换 Activity / Sources、来源折叠及键盘选择；没有点击 agent、提交 focus/seen 或重试连接。

| 对象 | 常态 | hover | 持续状态 | 持续状态＋hover | 按下 / 键盘 |
| --- | --- | --- | --- | --- | --- |
| 顶栏选项 | 次级图标与文字 | 提亮，无底色 | 主文字＋0.05底色，满38pt | 底色不变 | 按住可见文字变暗；未单测原生Tab焦点 |
| 来源标题 | 主文字、来源色图标 | 0.05整行底色 | 展开时0.10整行底色＋向下箭头 | 不叠加底色 | Enter只折叠；不是定位 |
| 定位行 | 主标题、次级副标题 | 0.05整行底色 | 不把访问过视作选中 | 键盘选中优先 | 键盘选择0.10底色＋1pt轮廓 |

状态值来自 `Theme.Colors`，上表列深色；浅色 hover/selection 为0.045/0.09。导航是 selection 再乘0.5。快照变化会改变真实任务文字和数量，比较状态时不以它们做固定素材。

未实拍：不可用定位项的 hover、真实定位中的 Opening / Retry、定位行按住。这些不通过点击用户目标制造，需隔离 fixture 验证。代码的 `HoverRow.fill` 尚未以 available 排除 hover，不能仅凭 disabled 就断言其外观正确。

## 光学间距测量

取同一原生截图的白色墨迹，不把控件 frame 当墨迹。Retina比例2；中性亮像素阈值185，结果约有0.5pt采样误差。

| 选项 | frame | 可见左留白 | 图标→文字 | 可见右留白 | 图标与文字墨迹中心差 |
| --- | --- | --- | --- | --- | --- |
| Activity | 86.5×38pt | 14pt | 12pt | 9pt | −0.75pt |
| Sources | 90×38pt | 12.5pt | 11.5pt | 9pt | ＋0.5pt |

原始数据：同目录 `optical-spacing.json`。采样时22pt图标槽、11pt glyph、6pt布局gap叠加了槽内余白；图标看起来离左侧和文字都更远。这是旧版测量，现行图标为14pt Regular 列表／14pt Medium 导航，见 `docs/ui.md`。垂直差还随具体 symbol 改变，不应给所有图标硬加同一个 y offset。

## Tinycast 参考实际做法

固定参考提交：[46beb10](https://github.com/abue-ammar/tinycast/tree/46beb10a7d23d9dcfa1e977f1144c99e47804c44)。

- [`BarButton.swift`](https://github.com/abue-ammar/tinycast/blob/46beb10a7d23d9dcfa1e977f1144c99e47804c44/Tinycast/DesignSystem/BarButton.swift)：bar控件使用独立的紧凑表面；HeaderMenuSymbol按symbolSize设槽，不用列表22pt槽。selected优先于hover，不叠加。
- [`Theme.swift`](https://github.com/abue-ammar/tinycast/blob/46beb10a7d23d9dcfa1e977f1144c99e47804c44/Tinycast/DesignSystem/Theme.swift)：barButtonHeight28、barControl圆角8、menuSymbolSize14、sm6/md8；selected/hover使用与Herdling列表相同的0.10/0.05层级。bar文字为callout Medium，不等于Herdling已定的12pt Regular。

这是项目参考，不是 Apple 指定尺寸；也不把其菜单按钮行为改成我们的视图切换。本文引用做法，不复制其 AGPL 源码。

## 已批准方案

推荐先比较**紧凑视觉表面、原有点击范围**，而不是再改整块38pt背景的透明度：

- 顶栏与命中范围仍38pt，视觉表面28pt居中；普通行维持32/38/40pt角色尺寸。表面不再挤住外层玻璃轮廓，导航圆角候选8pt，行圆角仍10pt。
- 导航用14pt左右的独立symbol槽，保留6pt布局gap和8pt左右内缩；实际墨迹重新量。12pt Regular不变，图标与文本基线按symbol/font匹配，不全局偏移。
- current复用selection，不让current等于另一类控件的hover。未选中导航hover仍仅提亮，保留已确认“不出现第二个填色按钮”；列表hover仍是临时wash。
- current＋hover不叠加、不放大；pressed只提供短暂反馈，不改变current。键盘focus独立可辨，不能因为hover而丢失。
- disabled定位项抑制交互wash，保留状态和理由；offline来源标题仍可浏览，不误做disabled。此项需fixture反例验证后才能实施。

一致指状态语义、优先级与视觉强弱一致，不是所有控件都套同尺寸底板。方案仅供对照，未宣布美观验收；点击范围/视觉表面拆分需真实玻璃和键盘验证。

## 原生实施与验证

- 当时导航表面28pt、点击区38pt，14pt图标槽和8pt圆角；实际两个选项宽78.5/82pt、间隔4pt。真实AppKit输入测试点击视觉表面之外的上下5pt区域，仍只切换视图，不提交定位。字号与字重未变。第一轮外壳修正只给按钮组前导加5pt、改13pt圆角，使上、左留白一致，但留下顶栏与名单背景边缘5pt、文字起点3pt、图标中心1pt的偏差。用户随后确认三者全部对齐：顶栏与名单共同使用13pt水平边界，导航保留14pt槽，用12pt水平内缩与10pt间距校准内容列。统一横向列时曾未经确认改变底边，随后恢复8pt留白、18pt纵向曲率。用户之后明确要求背景到外壳留白统一，并确认整圈13pt：底边改13pt、内侧两轴曲率均13pt；同时保留闭合键盘轮廓，比较直边和转角的真实可见距离。玻璃和系统阴影不变；现行规范见 `ui.md`。
- 同一亮墨迹阈值与2×比例重新量得：Activity左/图文/右留白为10/8/9pt，Sources为8.5/7.5/9pt，约0.5pt采样误差。图文空隙较此前各缩4pt；并非把6pt布局间距宣称为6pt光学空隙。垂直墨迹中心差仍为−0.75/+0.5pt，未硬加统一偏移。
- 实拍current、inactive hover、current＋hover、native pressed、来源收起/展开及各自hover、普通行hover和键盘检查。current复用selection；inactive导航hover没有第二块底色；按住plain按钮变暗；键盘检查有独立轮廓。实际来源标题展开后再次收起，恢复空偏好，没有重置偏好。
- 独立原生fixture显示：可用项hover有wash，禁用项没有wash和hover操作暗示；离线来源仍可hover/浏览，展开状态优先于hover。指针精确位置、active状态和动作计数均记录，dummy动作0，无后端或真实目标。冻结访问中目标失效的测试还验证键盘轮廓与选择身份保留。
- Tab交还原生按钮系统并清除列表选择；当前系统设置下未见稳定可辨的按钮focus环，不宣称已覆盖其所有外观。没有强制开启系统键盘导航，也没有增加抢占Tab的自定义focus。

证据：`.build/compact-navigation-evidence-DlJpBX/` 中的 `compact-native-state-sheet.png`、`compact-optical-spacing.json`、`fixture-precise-*.png`。147 tests / 10 suites串行通过，release与本地包签名、diff检查通过；只更新repo-local包。

锁屏期间前台为loginwindow，activate返回false、hover截图不变；这些记录排除。解锁后的fixture使用精确指针和active门禁，常态与hover能分开才纳入证据。早期偏离目标的指针采样同样排除，不用降级采样判断产品。

未运行：旧macOS、VoiceOver、系统Reduce Motion/增强对比/亮色真实玻璃组合、真实SSH/用户终端定位、配置后的全局快捷键操作。Opening/Unavailable/Retry保留由隔离渲染测试覆盖，不通过点击用户目标制造。

## 2026-10-08：控件圆角不等于外壳留白

用户指出Sources的13pt四角接近胶囊，与来源标题的方圆矩形不一致。导航普通角恢复8pt；只有Activity贴外壳的左上角适配13pt内轮廓。名单普通角10pt、真实末行沿容器转弯、整圈13pt留白均保持。独立参考轮廓先观察到两项渲染测试失败，再实现通过；不改变图标、文字锚点、命中范围或定位协议。

本轮167 tests / 12 suites通过。原生亮／暗Activity、收起／展开Sources和Settings共八组有效截图；展开fixture按稳定后的内容高度349pt取景。运行包另核对实际Sources＋来源标题、正确首末行悬停和13pt底边。证据位于`.build/rounded-control-language-e7xIrO/`；只切换视图和移动指针，没有点击真实目标。旧系统、辅助功能显示组合、配置后的快捷键及真实SSH／Ghostty定位未在本轮重测。
