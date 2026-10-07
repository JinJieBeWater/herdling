# Herdling

Herdling 展示 agent 状态，并帮助用户定位到对应的终端位置。

## 对象

**Agent**：运行在特定 pane 中的编码助手。同名不代表同一个 agent；一个 agent 可以经历多轮运行。

**来源（Source）**：运行 Herdr 的本机或 SSH 主机。不同来源可以有同名 Session 和工作区。

**Session**：一个来源内独立的 Herdr 会话，包含工作区和 pane。

**工作区（Workspace）**：Herdr 中可独立定位的工作区域。界面的 Space/worktree 层级组织这些工作区；分组名称不等于定位身份。

## 状态与定位

**待关注（Attention）**：当前由 Herdr 回报为 `blocked` 或 `done` 的 agent 集合。它是浏览分类，不是待办任务、未读消息或处理记录。

**最近空闲（Recent idle）**：当前由 Herdr 回报为 `idle`、且状态更新时间较近的 agent。不要求用户访问过，也不表示刚完成任务。

**完成提示（done）**：Herdr 当前回报的完成提醒。不表示用户已阅读、问题已解决或业务任务已完成。

**seen**：Herdr 维护的关注标记。它不是用户理解或处理结果的证明，也不是 Herdling 独立维护的已读记录。

**最近定位（Recent jumps）**：Herdling 近期报告定位动作成功的 pane 目标。它记录导航历史，不证明用户读过或处理过其中的内容。

**定位目标**：一个确定来源和 Session 内的工作区或 pane。仅激活终端应用，没有定位到指定对象，不算完整定位。
