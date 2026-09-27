# 原会话自动续跑：修复开发指导与验收规范

- 文档状态：实现与验收记录（v0.2.0）。
- 实现范围：P1–P3 已完成；P4 桌面/IDE app-server 复用因现有进程没有可验证的通用连接端点，未纳入本次版本。
- 基线：仓库提交 `7ea1855`；2026-09-27 本机问题调查。
- 读者：Windows / PowerShell 开发者及验收人员。
- 目标环境：Windows、Windows PowerShell 5.1、WinForms。
- 需求解释：“原本的绘画”按“原本的会话”理解。保留原 thread ID 和历史；允许更换执行进程，不允许偷偷建立新对话。
- 版本交付：代码、测试、README、变更日志与 v0.2.0 发布包均按本文方案更新。真实用户会话未被本次验收启动或改写。

## 1. 结论与方案选择

采用“原会话复用优先，受控移交兜底”的方案：

1. 已验证能连接持有该会话的原 app-server 时，在原服务内对同一 thread ID 提交下一轮。
2. 原服务不可连接时，先让原持有者有序退出或释放该会话，再使用明确的原 ID 执行 `codex exec resume`。
3. 未能证明占用已解除时，进入“等待释放原会话”；按退避策略检查，不创建新会话、不覆盖会话 ID、不删除锁。
4. 首次完成接管后，后续轮次由调度器串行管理，避免重复打开竞争写入者。

推荐首个可交付版本先完成第 2 条与完整错误处理，原服务复用作为能力探测通过后启用的路径。理由：本机 CLI 的按 ID 恢复能力已核实，但尚未验证桌面端/扩展私有服务是否暴露可连接控制端点。不能把“CLI 有 proxy 命令”当作“任意现有服务都能接入”。

对用户的承诺是“在原对话历史内继续”。同一个进程不是必要条件；桌面窗口能否即时显示外部写入，需要单独验收。不得把后台续接成功宣传成桌面窗口必然实时刷新。

## 2. 本次故障证据与边界

本地队列记录的事件顺序：

| 事件 | 本机时间或结果 |
|---|---|
| 检测的额度恢复 | 2026-09-27 19:59:41 |
| 加两分钟缓冲 | 20:01:41 |
| 实际启动子进程 | 20:01:49 |
| 子进程退出 | 退出码 1 |
| stderr | thread-store conflict；already has an active writer |

据此可确认：定时器到点启动了 Codex，失败发生在恢复会话的写入占用检查阶段，而非未触发计时。约八秒延迟符合十秒轮询的现实现象。

尚不能确认：具体持有者是哪一个桌面端或 IDE 实例。本机同时存在多个 app-server，命令行不包含足以唯一关联目标会话的信息。不能依据进程名、工作目录或日志文件名推断唯一 owner。

额外源码问题必须随修复处理：

| 位置 | 问题 | 必须的修改 |
|---|---|---|
| Start-Item | 一律启动独立 exec resume，无占用协商 | 先解析执行路径与所有权，再启动 |
| Finish-Item | 只存“退出码 1”，隐藏真实失败 | 分类错误并提供摘要、详情与下一步 |
| Finish-Item | Latest-Reset 已返回对象，仍调用 r.AddMinutes | 统一结果契约，使用 r.ResetAt，并覆盖再次限额路径 |
| Finish-Item | 收到 thread.started 后直接覆盖 session | 校验 ID 完全一致，不一致中止 |
| Finish-Item | manual 模式把任意非零退出当限额 | 占用、认证、权限、配置、网络错误分别处理 |
| Is-LimitText | reset 等宽泛文字会误判限额 | 优先结构化错误，再做窄范围兼容匹配 |
| Begin-Monitor | 新对象在 Ensure-Props 前赋新属性 | 构造完整属性或先补齐，再赋值 |
| Latest-Reset | 全局扫最近八文件、选最大时间 | 隔离会话与限额窗口，不把周限额当五小时 |
| Update-DetectInfo / Tick | 状态说继续扫描，实际无新扫描 | 展示真实扫描时间、下一次扫描及停扫原因 |
| 启动恢复 | running 直接变 pending | 先核对进程及原会话轮次，避免重复执行 |
| 关闭与删除 | Kill 子进程；单删可能丢失进程管理 | 停止调度、停止本轮、删除记录分开设计 |
| Timer 异常 | 单项异常停止全局计时器 | 隔离任务异常，显示系统故障但保留其他任务检查 |

上述是代码审查发现，不表示每一项都已在用户环境复现。

## 3. 不可违反的约束

- `originalThreadId` 创建监控记录后不可变；当前 `session` 只能迁移为它的兼容字段。
- 禁止自动使用 `thread/start`、`thread/fork`、`--last`、空 ID、新会话回退、临时不持久化模式。
- 新进程必须使用与原会话一致的 Codex home、用户身份及可兼容的二进制。
- 不因可执行文件修改时间较新就自动换版本。记录路径、版本、文件哈希；升级须重新验收。
- 不改变用户模型、推理配置和权限策略以“让它能跑”。桌面动态配置不一定等同于 CLI 配置，必须核对。
- 到恢复时间仅表示允许尝试，不能视为额度已被服务端确认恢复。
- 同一会话最多一个调度动作处于提交中；同一轮续跑不得因重复 Tick 重复发送。
- 不直接编辑 Codex 的数据库、锁、WAL、会话正文或 session_index 来制造“释放”。
- 工作目录不存在时阻止启动，不退回调度器自身目录执行。
- 会话 ID 不变能证明对话身份保留，不能保证模型记忆逐字不变；可能存在正常的上下文压缩。
- 本文的实现建议和超时默认值属于本项目设计，不是 Codex 产品保证。

## 4. 占用处理设计

### 4.1 建立可验证的所有权信息

记录 owner 类型：`schedulerOwned`、`sharedServer`、`externalUnknown`。

进程身份由 PID、启动时间、可执行路径、Codex home 共同验证。PID 可复用，单独保存 PID 不够。进程树仅为辅助证据，不能证明该服务只运行目标会话。

共享服务需要保存经验证的控制端点来源及服务实例身份。命令行中没有端点时，不猜端口、不把新启动的 app-server 当成原服务、不截取其他进程的 stdin。

本机调查发现：
- PATH 解析到 VS Code 扩展内的 codex.exe，版本 `0.155.0-alpha.16.3`。
- CLI 帮助提供 `app-server proxy --sock`。
- 多个现有 app-server 命令行使用默认或明确的 stdio 传输。
- 以上只证明工具能力存在，尚未证明这些现有实例能由调度器重新连接。

### 4.2 路径 A：原服务内继续

前置条件：控制端点合法可访问、身份匹配、接口版本支持、目标 thread 确实属于该服务。

流程：
1. 按本机协议完成 initialize / initialized。
2. 使用支持的读取接口查询 thread 和当前 turn；处理分页，不能仅查第一页。
3. 原轮次仍在运行时只观察，不叠加续跑消息。
4. 轮次已经因限额停止且恢复时间到达时，向同一 thread 提交一次自定义 prompt。
5. 保存返回 turn ID，持续读取事件，区分“请求已受理”“真正开始”“等待审批”“完成”“失败”。
6. 原客户端仍是订阅者时保留它；不为消除占用而主动终止原服务。

本机生成的 schema 已核实：
- ThreadResumeParams 必填 threadId。
- ThreadReadParams 支持 threadId、includeTurns。
- ThreadLoadedListParams 支持 cursor、limit。
- TurnStartParams 必填 threadId、input；存在 clientUserMessageId 字段。
- ThreadUnsubscribeResponse 返回 status。

请求示意（必须用当前二进制生成的 schema 验证后实现）：

~~~json
{"id":30,"method":"turn/start","params":{"threadId":"<originalThreadId>","input":[{"type":"text","text":"<该任务保存的续跑指令>"}]}}
~~~

字段 `clientUserMessageId` 的存在不能证明服务器保证幂等。未经测试，不得因超时重发 turn/start。

### 4.3 路径 B：先释放，再恢复原 ID

这是首版必须交付的可靠路径。

**由调度器自己持有的进程：**
- 前一子进程已退出：收齐输出、保存结果、Dispose，然后才允许下一进程。
- 进程仍运行：不重复启动；若明确需要停止，按已验证的终止流程停止本轮并等待退出。
- 只有已验证为本调度器独占的工作进程才允许超时后强制结束；记录原因和未完成轮次，不结束共享 app-server。

**外部桌面端 / IDE 持有：**
- 有可用的会话释放接口：由原连接执行释放，并等待可核验的卸载结果。
- 无可用控制接口：提示用户在原宿主中有序退出目标会话的持有者。关闭标签、停止生成或最小化窗口都不能自动视为已释放。
- 共享宿主有其他会话时，不整进程结束；保持等待释放，并给出具体诊断。
- 若用户选择退出整个宿主，应在产品内明确显示影响范围；不能把一次接管授权扩大成任意杀进程许可。

**释放判断：**
- unsubscribe 成功只证明当前连接退订，不证明其他连接退订或立即卸载。
- 官方当前文档描述无订阅、无活动后存在卸载宽限期；本机版本行为仍需验证。
- 不能用固定 sleep 两秒替代释放验证。
- 受控进程确实退出、或确认目标服务已经卸载，才进入获取会话阶段。
- 最终恢复成功事件作为获取成功证据；若再次返回 active writer，退回 waiting_owner，不当作不可恢复错误。

执行命令模板：

~~~powershell
# 模板；不要在诊断阶段对用户真实会话执行。
# WorkingDirectory、Codex home、配置身份应由 ProcessStartInfo 明确设置。
& $VerifiedCodexPath exec resume --json $OriginalThreadId -
# prompt 通过重定向 stdin 写入并关闭 stdin。
~~~

保留标准参数转义函数；PowerShell 5.1 的 ProcessStartInfo 没有可依赖的现代 ArgumentList。prompt 用 UTF-8 stdin 传入，避免中文、多行、引号和反斜杠组合出错。

新进程读取旧历史，仍属原会话。不得使用“复制历史建立一个新会话”代替恢复。

### 4.4 能力不足时的产品行为

如果原会话长期由不可控制的共享宿主持有，当前公开能力不能保证无交互接管。此时展示“等待原会话释放”，提供经过验证的操作指引，并保留队列。

无人值守的前提是：接管前已经释放原持有者，或配置了已通过验证的共享服务路径。首版不能承诺对任意正在打开的桌面会话强制无缝接管。

## 5. 状态机、重试和崩溃恢复

~~~mermaid
stateDiagram-v2
    [*] --> monitoring
    monitoring --> waiting_limit: 目标任务确因限额中断
    waiting_limit --> acquiring: 恢复时间与缓冲到达
    acquiring --> waiting_owner: 原写入者仍占用
    waiting_owner --> acquiring: 释放已验证或退避检查到期
    acquiring --> running: 原ID匹配且本轮已开始
    running --> waiting_limit: 再次限额
    running --> needs_attention: 审批或认证等阻塞
    running --> done: 本轮成功
    acquiring --> needs_attention: ID或配置不匹配
    running --> reconciling: 连接断开或结果未知
    reconciling --> running: 找到已提交轮次
    reconciling --> needs_attention: 无法判定是否提交成功
~~~

补充状态：paused、cancelled。与状态分开存储 errorKind、retryAt 和 resumeTargetState，不用一个 error 字符串承担全部含义。

错误分类优先级：会话 ID 不匹配 > active writer 冲突 > 会话不存在/配置/身份错误 > 额度限制 > 网络暂态 > 其他退出错误。manual 模式同样分类。

建议默认退避：
- 已确认无请求被接受的占用失败：15、30、60 秒，之后每 60 秒；十分钟仍占用时突出显示阻塞原因。
- 已确认提交前失败的网络错误：30、60、120 秒，最多五次后需处理。
- 请求可能已接受但响应丢失：进入 reconciling，禁止盲目重发。
- 再次限额：采用匹配本账户/窗口的最新 reset，过期记录不能再次启动；没有可信时间则监控，不能自动猜再等五小时。
- 假如无法读取 owner 状态，每次 exec 重试都可能真正执行任务。只有未决提交已排除、到了允许恢复时间时才能尝试，不可把它当纯只读探测。

崩溃恢复：
1. 全局命名 Mutex 防止两个调度器同时写同一 queue.json；进程内用任务提交标记防 Timer 重入。
2. 启动时先加载状态到 reconciling，不直接把 running 改 pending。
3. 核对工作进程身份和已提交 turn；若不能确认上一轮是否提交成功，等待处理。
4. 保存调度意图、启动事件、输出事件及退出结果。原子替换状态文件；保留上个有效版本。
5. 非幂等服务下不能承诺跨崩溃“恰好一次”。状态不确定时暂停自动提交，比重复执行更符合原任务语义。

## 6. 数据结构与模块修改

队列版本升至 3。沿用现有字段，并补充：

| 字段 | 含义 |
|---|---|
| originalThreadId | 固定的原会话身份 |
| executionMode | managedResume / existingServer |
| codexPath、codexVersion、codexHome | 经验证的运行环境；不存 token |
| ownerKind、ownerPid、ownerStartedAt | 所有权证据；允许未知 |
| attemptId、turnId、submissionState | 提交关联及不确定状态恢复 |
| errorKind、lastError、lastExitCode | 分类与可读摘要 |
| retryAt、retryCount、resumeTargetState | 重试策略 |
| detectedResetAt、detectedAt、detectedSource | 原始恢复依据 |
| lastScanAt、nextScanAt、scanStatus | 实际扫描运行情况 |
| promptSnapshot | 本次尝试冻结的自定义指令 |
| updatedAt | UTC ISO 8601 时间 |

version=2 迁移：session 转 originalThreadId；旧 running 转 reconciling；已存 active writer 错误转 waiting_owner，保留原始日志；字段全部初始化后再赋值。错误记录不自动新建重复监控项。

建议只做必要拆分：
- `CodexQueueCN.ps1`：UI、事件绑定、启动入口。
- `QueueCore.ps1`：状态转换、重试、持久化、限额匹配。
- `CodexRunner.ps1`：进程、流、身份校验；共享服务适配器等能力验证后再加。
- `tests/`：隔离状态机与假的子进程协议测试。

禁止测试通过 Invoke-Expression 执行生产脚本头部；它会覆盖测试 DataDir 并产生生产目录副作用。改为 dot-source 无启动副作用的函数模块，显式传入测试 statePath、sessionRoot、时钟和进程启动器。

Start-Item 改造：
- 前置验证原 ID、目录、运行环境和提交状态。
- attemptId、promptSnapshot 落盘后开始提交。
- 实时读取 stdout/stderr，不能只在进程结束后解析身份事件。
- 第一个 thread.started / 恢复响应必须与 originalThreadId 相同；不匹配时停止本调度器新建的进程、报告 identity_mismatch。
- 这只是事后保护；真正预防新会话还须强制使用 resume 参数、拒绝空 ID，并验证所支持 CLI 的语义。
- 同时持续排空两条流，避免阻塞；生产日志逐行写入 runs 下，UI 只保存有限摘要。
- finally 清理进程和读流句柄；错误不能停止全局调度器。

Finish-Item 改造：
- 使用结构化事件和退出码共同判断状态。
- 占用进入 waiting_owner；审批进入 needs_attention；再次限额进入 waiting_limit。
- 保留 finished、原始退出码、分类依据，lastError 不只写数字。
- done 表示本轮成功结束，不宣称整个业务目标必然完成。

## 7. 限额检测和时间反馈

完整修复还要处理“读到了时间但并非当前任务限额”的问题：

1. 只因目标任务实际限额错误而进入等待额度，普通 rate_limits 遥测不是“任务已被中断”的证据。
2. 优先目标会话最新事件；账户级数据必须匹配 Codex home/身份及 provider，无法关联时标记未知，不能套用其他会话时间。
3. 选择五小时窗口 `window_minutes=300`；周窗口单独表示。若两个窗口均阻塞，等待到所有阻塞窗口满足恢复条件，不拿周窗口冒充五小时。
4. 按事件时间选最新记录，不能在旧日志中选最大 reset；文件修改时间仅用于缩小搜索范围。
5. 新版文件名不一定以 UUID 结尾；通过受支持的会话元数据或会话 API 校验身份，不能只靠旧正则。
6. 定义统一检测结果：status、resetAtUtc、observedAtUtc、source、windowMinutes、scannedCount、error。
7. 缓存命中也验证是否过期；用户“立即检测”可跳过缓存。扫描失败与未发现记录分别展示。
8. 自动模式未知时间不显示手动时间框里预填的“当前时间+五小时”；应显示未知或真实检测时间。
9. 内部统一 DateTimeOffset / UTC，界面显示本地完整日期、时分秒和时区；睡眠唤醒后比较时间，不补发错过的每个 Tick。
10. 十秒调度、六十秒日志缓存分别告知；没有扫描就不能刷新 lastScanAt。

界面至少展示：
- 原会话 ID、续跑方式和是否已接管。
- “等待额度 / 等待释放 / 正在续跑 / 需要处理”的明确区别。
- 原始重置时间、缓冲、计划执行时间、实际启动时间。
- 错误摘要与“查看详情”按钮，详情含可复制的 stderr、退出码、尝试时间。
- 下一次扫描/重试时间，暂停原因。
- 版本及构建提交，帮助确认本地同步。

示例：“额度时间已到；原会话仍被其他 Codex 实例占用。保留原对话，下一次检查 20:03:00。”
不能显示“继续扫描”来掩盖错误终态。

## 8. 实施顺序与完成标准

| 阶段 | 交付物 | 放行条件 |
|---|---|---|
| P0 兼容性验证 | 固定二进制、schema、合成会话报告 | 原 ID 恢复成立；能复现占用冲突；确认释放方法 |
| P1 基础修复 | 错误分类、结果契约、字段初始化、ID保护 | 无 UI 的隔离测试通过 |
| P2 受控接管 | waiting_owner、退避、进程清理、崩溃恢复 | 原持有者退出后同 ID 成功继续且不重复提交 |
| P3 反馈与检测 | 真正的扫描反馈、窗口隔离、错误详情 | WinForms 实际交互验收通过 |
| P4 可选原服务复用 | 经验证端点与协议适配 | 同服务续跑、多会话隔离、审批、断线恢复通过 |
| P5 发布 | 文档、打包、部署、CI及验收记录 | 源码/部署/zip一致，端到端用例通过 |

P4 尚未通过，因此 v0.2.0 实现 P1–P3：明确冲突后按退避策略使用原 ID 重试；外部桌面/IDE 长期占有时显示等待，并需要在原宿主释放会话。不得宣称能自动关闭或强制接管任意桌面端。

本机生成 schema 的可复现命令：

~~~powershell
& $VerifiedCodexPath --version
& $VerifiedCodexPath exec resume --help
& $VerifiedCodexPath app-server proxy --help
& $VerifiedCodexPath app-server generate-json-schema --out $IsolatedSchemaDirectory
~~~

以上为帮助和类型生成，不提交模型任务。不要为了验证能力调用真实用户会话的 resume 或 turn/start。

## 9. 测试矩阵与端到端验收

所有自动测试使用独立临时目录和合成会话；不得写入用户的 queue.json、真实 session 日志或终止用户进程。

| 用例 | 验收结果 |
|---|---|
| 首次新增监控、旧记录迁移 | 不发生属性赋值异常；原ID保留 |
| 到点、跨午夜、睡眠唤醒 | 仅发起一次有效尝试，日期正确 |
| 缓存中 reset 已过期 | 不立即误启动 |
| 只有周窗口、只有他人会话数据 | 不当作目标五小时重置 |
| 目标未限额但存在遥测 | 不擅自续跑 |
| active writer、自动/手动两模式 | 均进入等待释放，不终止队列 |
| 原持有者正常退出 | 继续同一个 ID，历史可读取 |
| owner 共享多个会话 | 不结束共享进程，不干扰旁支 |
| owner 不可识别 | 明确阻塞，不按名称杀进程 |
| 收到不同 thread ID | 阻止继续并报告身份错误 |
| 再次限额 | 使用统一 reset 对象，无 AddMinutes 异常 |
| 中文多行 prompt、路径带空格 | 字节及参数传递正确 |
| stdout/stderr 大量输出 | 不死锁，UI持续响应 |
| 两个调度器、Timer 重入 | 单一提交者 |
| 提交成功但响应丢失 | 对账，不盲目补发 |
| 在提交前/后任意点崩溃 | 不把未知轮次直接改待执行 |
| 登录失效/权限审批/配置错误 | 明确需要处理，不伪装限额 |
| 关闭窗口或删除运行记录 | 有清晰进程归属，不遗留无管理任务 |
| 一项检查抛异常 | 其他任务仍被调度 |
| 桌面重新打开原对话 | 看见同 ID 新轮次；是否需刷新有记录 |

关键端到端步骤：
1. 在隔离测试环境创建测试会话 A，记录 UUID 和一条独特上下文标记。
2. 原宿主保持 A，复现第二写入者冲突；记录请求和退出日志。
3. 调度器进入 waiting_owner，UI 展示真实原因。
4. 通过验证过的流程释放 A；同时有另一测试会话 B，确认 B 不受影响。
5. 调度器只对 A 发送一次继续指令，保存新 turn ID/历史事件。
6. 验证返回会话 ID 等于 A、旧历史仍在、续跑用户消息仅一次、B 无变化。
7. 模拟再次限额和恢复，重复一次；最后在宿主打开 A 检查新旧轮次。
8. 真实模型调用单独记录已执行与否；schema、语法解析或 mock 通过不等于本用例通过。

本次在 Windows PowerShell 5.1 上通过了隔离队列迁移、WinForms 启动、假 Codex active-writer 冲突与释放后同 ID 续跑测试。测试证明 runner 在本地按约定处理结果，不证明所有 Codex 桌面版本都会自动释放线程；真实 Codex 服务端续接与桌面窗口刷新仍需单独验证。

## 10. 发布、迁移与回滚

- 开发提交按逻辑拆分：错误反馈、状态机/原ID保护、接管、限额检测、集成测试、发布包。
- 修改 PowerShell 保留 UTF-8 BOM、LF，兼容 5.1。
- CI 保留语法和 zip 校验，并增加隔离功能测试；zip 与源码目录双向核对文件集合及哈希。
- zip 继续使用现有平铺结构，不增加版本目录前缀。
- 部署目标：G:\software\Five-Hour-Limit-Get-Lost-v0.1.0。源码、部署与 zip 逐文件校验。
- 更新前暂停新增调度并保存队列备份；有运行轮次时不直接覆盖其状态。
- 文件同步不代表运行窗口已加载新版。空闲时重启调度器，核对构建标识；共享服务不随调度器升级被结束。
- 回滚前停止新提交、确认已运行轮次归属；恢复旧程序及对应队列备份。不能把旧 running 记录直接交给旧版自动重跑。
- 回滚不恢复旧 Codex 会话数据库覆盖新历史。不能为了回滚删掉已成功追加的轮次。

最终交付报告必须同时列出：代码提交、CI链接、三份文件一致性、真实端到端结果、原会话ID保持结果，以及任何仍需人工释放的场景。

## 11. 参考依据与未决验证项

源码依据：[CodexQueueCN.ps1](../Five-Hour-Limit-Get-Lost-v0.2.0/CodexQueueCN.ps1)，按函数名定位，上述基线有效。

官方依据：[Codex App Server](https://learn.chatgpt.com/docs/app-server)。其 thread/resume 用于继续既有 thread；turn/start 提交一轮输入；unsubscribe 仅移除当前连接订阅，不能据此认定跨进程占用已解除。

本机依据：上述版本的 exec resume / app-server proxy 帮助，以及本机生成的 JSON schema。schema 在临时目录生成用于核对，不应将含机器路径的临时文件作为发布依赖。

实施前必须闭环的未知项：
- 当前目标会话的确切持有者，以及它是否有可复用控制端点。
- 被支持版本的卸载/释放实际条件及延迟。
- 桌面/IDE配置如何传递到恢复进程，尤其模型、权限与工具可用性。
- 外部追加轮次能否在原桌面及时显示，还是需要重新打开。
- 当前协议的消息去重行为；未验证前使用“结果未知则对账/暂停”策略。

这些未知项不改变原 ID 必须保留的决策，只决定是启用原服务复用，还是使用受控释放后恢复。不得在开发报告中把未验证项标记为已解决。
