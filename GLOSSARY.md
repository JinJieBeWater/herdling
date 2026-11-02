# Herdling

Herdling 同时展示旧版 Herdr 与 Herdr Core 中回报的 agent 状态，并帮助用户定位到对应的终端位置。

## 对象

**Agent**：运行在终端中的编码助手。同名不代表同一个 agent；普通终端不因列入目录就成为 agent。

**来源（Source）**：Sources 中按设备浏览工作目录的入口。一个设备可以同时提供旧版 Herdr Session 和 Core 终端；同名不代表同一对象。

**运行时（Runtime）**：管理终端与状态的系统；本项目分别指旧版 Herdr 和 Herdr Core。两者可同时提供目标，各自维护身份与连接。

**Session**：旧版 Herdr 中独立的会话，包含工作区和 pane。Core 终端不属于这一会话模型。

**工作区（Workspace）**：旧版 Herdr 中可独立定位的工作区域。界面的 Space/worktree 层级组织这些工作区；分组名称不等于定位身份。

**Core 终端（Core terminal）**：由某个 Herdr Core 管理的终端，可以运行 shell、普通程序或 agent。它的身份由所属 Core 与原生终端标识共同确定。

**Core machine**：Core 管理的远程设备及连接。它与 Herdling 为旧版 Herdr 选择的 SSH 来源分别管理。

**终端地址（Terminal address）**：从某个 Core 入口到终端的当前访问路线。地址可以随连接变化；相同短地址不代表同一终端。

## 状态与定位

**待关注（Attention）**：运行时回报需要用户关注的 agent 集合，包括 blocked、done 和 Core 的 error。它是浏览分类，不是待办任务、未读消息或处理记录。

**最近空闲（Recent idle）**：当前由运行时回报为 `idle`、且状态更新时间较近的 agent。不要求用户访问过，也不表示刚完成任务。

**完成提示（done）**：当前的待查看完成提醒。Core 使用 Herdr App 根据 seen 推导的状态，不直接将原始 done 当作待关注提示；它不证明业务任务已完成。

**seen**：旧版 Herdr 或原生 Herdr App 维护的关注标记，不是 Core 原始状态的一部分。Herdling 同步 App 的已查看状态，不独立维护该标记；seen 不证明用户理解或处理了任务。

**未报告（Unreported）**：终端没有回报 agent 状态。它仍可出现在 Sources，但不因此成为 Activity 中的 idle agent。

**终端结束（Finished）**：Core 终端进程已结束。它描述进程生命周期，不代表 agent 的 done 提示。

**最近定位（Recent jumps）**：Herdling 近期报告定位动作成功的目标。它记录导航历史，不证明用户读过或处理过其中的内容。

**定位目标**：旧版 Herdr 中确定的工作区或 pane，或确定 Core 所属的终端。仅激活终端应用，没有定位到指定对象，不算完整定位。
