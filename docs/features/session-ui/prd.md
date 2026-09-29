# Sigma Session UI & Observability V2 — PRD

- 版本：1.0
- 日期：2026-09-09
- 状态：V2 必需范围已实施并验证；可选 Inspector/预测（SUI-10）deferred。完成证据见 `implementation-report.md`。
- 项目：`gsmlg-opt/sigma`，不扩展到 Samgita、Synapsis 或 Backplane。
- 配套文档：`implement-plan.md`。
- 产品目标：将聊天页升级为可观察、可恢复、可安全重试和分叉的 Agent Session Console。

## 1. 依据与验证边界

本文基于用户提供的聊天页截图、上一轮 Sigma 仓库审查，以及 Agent Note 中的 `Sigma Protocol V1 and headless runtime` 记录。上一轮代码搜索命中了提交 `e59e49a298e66a7c571cec2e7878ae85b082f8b0`，文件读取使用的是当时的 `main`；不能保证所有读取来自同一提交。

本轮 GitHub 连接器返回访问限制，公开文件读取也未成功。因此，下面的“已观察实现”指前一轮证据，不是对当前 HEAD 的重新认证。本文未执行代码、测试或浏览器交互验证。实施者必须记录当前 HEAD，检查变更，复用已经实现的能力，不得照旧假设重复开发。

### 1.1 已观察实现与需要解决的问题

| 位置 | 已观察实现 | 对本需求的影响 |
| --- | --- | --- |
| `SessionLive` | 消息 footer 展示 input/output；存在 Retry、Fork 动作及 handler | 不是从零添加按钮；先核对实际可见性、slot 行为和动作语义。[S1] |
| `SessionLive.latest_context_token_count/1` | 对历史 assistant input usage 取最大值 | 不能代表压缩后的当前 context，必须移除这一统计口径。[S1] |
| `SessionLive.assign_context_token_count/2` | 使用旧值与新值的 `max` | UI 中 context 只能增大，无法正确反映压缩、分支切换等变化。[S1] |
| `retry_message` | replay 日志、找到旧 prompt、再次 submit | 更接近“在当前会话末尾重新发送”，不等于从原 turn 边界重新生成。[S1] |
| `SessionProcess` | 有 `compaction_count`、`last_compaction`；所见 init 未从历史恢复计数 | 不能直接把运行时计数当成跨重启累计统计。[S2] |
| `Sigma.Agent` | 所见自动压缩阈值为已知 context window 的 80%，未知时 fallback 到 80,000 | UI 必须读取 runtime 有效策略，不能另写一份阈值公式。[S3] |
| Session journal / operations | 已有 append-only 日志、compaction entry、fork 和 active-leaf 设计 | 在既有 journal/operation 边界上扩展，不引入第二套行为状态库。[S4][S5] |
| Protocol V1 / PublicRuntime | Agent Note 记录了闭合类型、受控命令边界、订阅与慢消费者处理 | 新 metrics 命令/事件必须审查协议兼容性，不能仅向旧类型集合塞字符串。[S6] |

### 1.2 本文明确修正上一轮建议的地方

第一，历史最大 input 不是当前 context。第二，存在 compaction 字段不代表持久化、恢复和 UI 展示已经完成。第三，本文默认显示的速度是**可观测 LLM 请求吞吐率**，包括该请求等待时间，但不包括请求之外的工具耗时；只有 token 范围与计时窗口能够对齐时，才另外显示纯生成速度。第四，Retry/Fork 不承诺回滚文件、Git 状态或外部副作用。

除本节标为已观察的内容外，后续需求、字段和任务均为新增设计，不代表现有实现。

## 2. 产品目标与范围

用户应能在一个页面回答：这一轮花了多少 token、模型有多快、时间花在哪里、整个 session 已消耗多少、何时开始、运行多久、当前 context 多大、距离压缩还有多少余量，以及失败后如何安全继续。

### 2.1 V2 必须交付

1. 每条 assistant 消息与完整 turn 的关联统计：input、output、LLM 吞吐率、耗时、状态和可发现的操作入口。
2. Session 右栏：累计 usage、平均 LLM 吞吐率、开始时间与相对时间、当前运行状态。
3. Context 面板：当前估计或最近实测、有效阈值、剩余 token、成功压缩次数及最后压缩信息。
4. 分支感知的 Retry 和明确边界的 Fork；操作幂等、原历史保留、工作目录副作用提示。
5. 刷新、断线重连、进程重启、压缩和分叉后仍正确的统计；缺失数据明确显示未知。
6. 适合桌面与窄屏的布局、键盘操作、稳定滚动、错误与取消状态。

### 2.2 后续增强，不阻塞基础版本

估算距离压缩的轮数、完整 Session Inspector、详细 request/compaction 历史、复杂分支树、更多分组分析。基础 turn 汇总和最后一次压缩详情属于必需功能，不应以 Inspector 尚未完成为由延迟。

### 2.3 不在本次范围

不重写 agent 执行引擎，不新增模型网关或计费平台，不实现文件系统事务回滚，不自动创建工作树，不增加不受限自动重试，不替换 DuskMoon 组件体系，不重做其他项目的 UI。

Token usage 不是订阅配额百分比，也不是可验证账单金额。UI 不得从 token 数推算 Pro 配额或货币费用。

## 3. 信息模型与统计范围

### 3.1 实体

| 实体 | 定义 |
| --- | --- |
| Session | 一个持久化逻辑会话；展示标题、存储路径和计量归属标识必须区分。 |
| Turn | 一次被接受的用户请求，到 completed / failed / cancelled / interrupted 的完整执行，包含多个 LLM 请求和工具调用。 |
| Request | 一次可观察到的实际 provider 请求；可见的 transport retry 必须生成独立 request 身份。 |
| Message | 展示和上下文中的消息；不保证与 turn 或 request 一一对应。 |
| Tool call | 一次带独立身份、状态与时间信息的工具执行。 |
| Compaction | 一次压缩尝试；只有成功提交上下文变更的 attempt 才计入成功次数。 |
| Lineage | 当前分支祖先关系及 fork 来源；决定当前 context，不决定 session 已发生的总消耗。 |

每次执行必须有稳定的 `turn_id`、`request_id`，并能关联 message、tool 和 compaction。标识不得依赖会变的 UI 标题或文件名。具体复用现有 ID 还是增加稳定 session UID，由 SUI-00 核对现有 rename/header 契约后冻结。

### 3.2 三种不能混淆的统计

**Session own usage**：本 session 实际发起、可计量的请求总和，包括旧 retry 分支、失败/取消时已知 usage、压缩和其他辅助 LLM 请求。切换分支或压缩不能让已发生消耗消失。

**Active-lineage usage**：当前选中路径的历史消耗，仅作为详情筛选，不能替代默认 session own usage。

**Inherited usage**：fork 带来的祖先请求记录。新 session 可以继承 context 和历史，但其 own usage 从零开始。继承请求保留来源身份，不重新计费或重复聚合。

请求类型至少区分 `turn`、`compaction`、`auxiliary`。只有经实际 instrumentation 观察到的请求才能计量；网关内部隐藏重试等不可见消耗必须说明不在覆盖范围内。

## 4. Token 与时间口径

### 4.1 Usage 归一化

| 字段 | 契约 |
| --- | --- |
| `input_tokens_total` | 该次请求完整 input，已包含能够归一化的缓存部分。 |
| `output_tokens_total` | 该次请求完整 output；是否包含 reasoning 由 adapter 的已验证映射确定。 |
| `cache_read_tokens` / `cache_write_tokens` | input 的细分；不能再加到已包含它们的 input total 上。 |
| `reasoning_tokens` | 当 provider 语义支持时作为 output 子集；不能重复相加。 |
| `visible_output_tokens` | 仅在能够可靠取得时提供，不由字符数或流事件个数冒充。 |
| `usage_status` | `reported`、`derived`、`estimated`、`unknown`；细分字段可以分别具有不同状态。 |
| `usage_revision` | 同一 request 的更新版本，支持最终 usage 覆盖中间估计。 |

Adapter 必须声明并测试 provider 原始计数是否包含缓存/reasoning。不得假设所有 provider 都采用同一结构，或在未知情况下强行补零。

默认总量为完整 input 与完整 output 的和；任一部分缺失时，展示“已知用量 / 部分数据”，不能把已知部分伪装成完整总量。详情展示已覆盖请求数，例如“已取得 18/20 次请求的完整 usage”。

同一 request 的最终 usage 需要按身份替换旧版本，不能将 start、delta、message_end、request_end 分别累加。Assistant 消息统计与 turn 汇总是两种视图，不是两笔消耗。

### 4.2 时间字段

持久化 UTC wall-clock 时间用于 started、finished、排序和相对时间；同进程内使用 monotonic clock 计算时长，持久化计算结果。不得跨进程重启相减旧 monotonic 时间值，也不能将其转换成 Unix 时间。

- `session.created_at`：会话创建时间。
- `session.started_at`：第一次被接受的用户 turn 时间；不能用 LiveView mount 时间。
- `turn.wall_ms`：该 turn 从开始执行到终止的墙钟耗时；排队时间单独记录。
- `request.elapsed_ms`：provider 调用开始到完成、失败或取消的耗时。
- `request.first_output_ms`：首个有实际内容的 text/thinking/tool-argument 事件延迟；排除 keepalive 和空头部。
- `request.ttft_ms`：首个可见文本 delta 延迟；tool-only 请求可以没有此值。
- `tool.elapsed_ms`：工具自身执行耗时。

UI 默认时间名必须与实际字段一致。“首输出”不应伪装成“首文本”。只有首文本延迟才标为 TTFT。

### 4.3 速度

默认 `LLM tok/s = output_tokens_total / request.elapsed_seconds`，这是包含请求等待时间的**请求吞吐率**，不是硬件 decode benchmark。它排除请求之间的工具执行、用户审批和排队时间。

Turn / session 平均吞吐率采用匹配请求集合的 `Σ output_tokens_total / Σ request.elapsed_seconds`，不能简单平均各条 tok/s。集合仅包含 token 与有效结束时长均已知的请求，coverage 随指标返回。失败或取消请求有完整的观测计数和时长时可以纳入，不能悄悄删除其消耗。

“纯生成 tok/s”仅作为可选详情：要求 numerator 与生成时间窗口一致，尤其不能把包括首文本之前 reasoning 的总 output，除以首文本之后的时间。缺少这些条件时不显示该指标。

流式过程中可能拿不到 token 数。此时显示运行耗时和“usage 待返回”，不能将 delta 数当 token。零输出、零/负计时窗口和极短窗口必须有显式边界处理，不出现 Infinity 或 NaN。

不同模型的 token 定义可能不同，跨模型总平均应标记“混合模型”；详情按 provider/model 分组。并行请求的累积时长不是 session 实际经过时间。

### 4.4 相对时间与活跃时间

显示“开始于 13:30 · 18 分钟前”，hover/详情显示带时区的完整日期。历史数据没有真实 started_at 时显示“创建于…”或“开始时间未知”，不可伪造。

Session age 与 active time 分开。Active time 来自执行区间的并集，不包括闲置；工具并发时，工具累计耗时与 turn 墙钟时间分开命名，不做错误的互斥百分比分解。前端本地刷新相对时间，不能每秒遍历日志或重渲染整个会话。

## 5. 页面与消息交互

### 5.1 布局职责

**顶部**负责会话标题、模型选择、运行状态和收起侧栏。不要让长 session ID 成为主标题，也不要在顶部和右栏重复整套配置卡片。

**左栏**负责 workspace 与 session 导航。条目显示可读标题、运行/失败/等待状态和最后活动；ID 作为可复制的次级信息。完整分支树不属于基础版本。

**中间**负责对话和执行结果。Assistant 正文保持阅读宽度，长代码块局部横向滚动；执行细节默认折叠，但最终回答不能被折叠的工具输出淹没。

**右栏**负责 observability，按 Runtime、Usage、Timing、Context/Compaction 排序。工作目录等静态元数据进入可展开区域，避免多处重复。

使用现有 DuskMoon 组件和语义主题 token。大面积高饱和导航背景不是本次必需结构，优先改为中性 surface，品牌色用于选择、进度和关键动作。禁止为这个页面引入第二套 UI 框架。[S7]

### 5.2 Message footer 与 Turn summary

2026-09-29 经用户确认的展示调整：每个可识别 turn 默认只显示一条紧凑摘要（状态、整轮墙钟耗时、input、output）；多个请求或有工具时增加请求/工具数量。请求级 input/output、LLM 请求吞吐率、请求耗时、缓存、reasoning、TTFT、模型、request 状态与数据质量保留在默认折叠的请求明细。旧记录不能关联 turn 时保留请求范围说明。不得把最后一条回答的 usage 当成整轮消耗。

失败、取消和 tool-only turn 也必须有摘要展示位置。终态与迟到 usage correction 更新对应摘要，不重置整段会话或把请求完成当成整轮完成。具体范围与验收以 `../../superpowers/specs/2026-09-29-session-ui-information-design.md` 为准。

用户消息显示提交时间和相应操作，不显示虚构的 output/生成速度；输入 token 估计若存在，必须与 provider 实际消耗明确区分。

Copy、Retry、Fork、More 对键盘和触屏可访问；不能只靠 hover 才能发现。运行中的操作禁用时必须说明原因。一次请求只有工具输出或发生错误时，也必须能够找到对应的 turn 状态和统计。

### 5.3 Composer 与运行状态

Composer 默认紧凑、随内容增长，设置合理高度上限，不长期占据大量空白。按键行为和 placeholder/help 文字必须来自同一设置；不能同时显示互相矛盾的 Enter 与 Cmd/Ctrl+Enter 发送说明。

保留提交失败时的正文和附件。提供明确的 Stop，并展示 `cancelling`，只有 runtime 确认终止后才切换为可重试。展示 queued、waiting_provider、running_tools、waiting_approval、compacting、failed 等真实状态；不以单一 spinner 掩盖一切。

用户向上阅读时不抢滚动位置；新内容使用“跳到最新”提示。摘要统计更新不能重置输入焦点、选中文本或展开状态。

## 6. Session 右栏需求

| 分组 | 必需显示 |
| --- | --- |
| Runtime | 当前状态、正在执行的阶段、当前模型；故障或等待原因。 |
| Usage | Own input、own output、已知总量、usage coverage；压缩/辅助用量可展开。 |
| Timing | started_at + relative time、session age；当前请求耗时、平均 LLM tok/s。 |
| Context | 当前估计/最近实测、窗口上限及来源、有效压缩阈值、剩余 token。 |
| Compaction | 本 session 成功压缩次数、最后成功时间、before/after 信息及数据来源。 |
| Metadata | 工作目录、fork 来源、继承统计、按需查看的 MCP 状态。 |

平均吞吐率和 usage 的 scope 必须可解释。新 fork 显示 own usage = 0、继承来源及 context，而不是继承父会话账单。当前分支继承的 compaction 可以另列，不能冒充本 session 新完成的次数。

## 7. Context 与 Compaction

### 7.1 ContextSnapshot 必须区分两种事实

`last_request_input_tokens` 是某次请求实际发送的 input；`next_request_estimated_input_tokens` 是按当前 active leaf、模型、系统指令、工具 schema、skills、附件和保留消息组装的下一请求估计。两者不能使用同一字段名称。

Snapshot 必须携带 active-leaf/context revision、模型、测量来源、生成时间及 stale 标记。待发送 composer 草稿若纳入预览，应单独标为 draft preview，不混进已提交会话状态。

Provider usage 到达后校正对应请求的观测值。压缩、分支切换、工具/系统上下文变化、模型切换后要重建或失效旧估计。模型切换会改变后续预算，不改写已结束请求的模型和 usage。

### 7.2 阈值与余量

有效阈值由 runtime 的同一个 compaction policy 计算并返回，UI 只呈现。保留现有 80%/80k 行为是否仍正确，由 SUI-00 核对；本 PRD 不授权前端自行改变策略，也不假设已有 configured threshold。[S3]

已知当前估计与有效阈值时：`tokens_remaining = max(0, threshold - estimated_input)`。只有最近实测时，明确显示“基于上次请求”；估计失效或阈值未知时显示未知。

阈值达到或超过时，显示“已到阈值，等待安全检查点”，不能保证精确倒计时。Model window 未知时显示不定量状态，不能把 80k fallback 伪装成模型容量，也不能画 0% 的假空条。

必须区分自动压缩阈值与请求能否容纳 input/output 的硬预算。Runtime 需在发送前检查已知窗口和输出预留；UI 的进度条不能取代 overflow 防护。检查阶段与压缩能执行的安全边界都由 runtime 返回。

### 7.3 压缩事件与历史

Compaction 记录至少包含 ID、trigger（auto/manual）、started/committed/failed 状态、关联 source leaf、保留边界、summary entry、before/after token 数及各自来源、完成时间、关联 request IDs。

成功次数从已提交 journal 记录重建，不依赖某个进程从零开始的内存计数。压缩失败不增加成功次数；已经发生的 LLM usage 仍计入 session。累计消耗不会因 context 变小而减少。

最后一次压缩详情至少显示时间、before/after、摘要入口；旧记录缺少这些字段时显示“历史记录未采集”，不能逆推不存在的测量值。压缩不能删除原始审计历史。

提供手动 Compact 的入口时，只能调用受控 runtime operation，在空闲安全边界执行；若当前 runtime 尚无安全手动能力，需先补齐操作边界，不能直接修改 UI messages。

### 7.4 可选的轮数预测

不得显示“还有 X 分钟自动压缩”这种假确定性。后续可在同一 context epoch、同一有效策略下，利用足够多的已结束 turn 增长样本显示“约 3–5 轮”。

样本不足、刚压缩、模型/工具上下文变化、异常大工具结果或增长无效时隐藏预测。预测只供展示，不驱动实际压缩，不影响 admission 决策。

## 8. Retry、Resend 与 Fork

### 8.1 动作契约

| 动作 | 行为 | 原历史 | 自动执行 |
| --- | --- | --- | --- |
| Retry turn | 从被选 turn 的原始用户输入边界创建替代执行分支；生成新的 turn_id，并记录 retry_of_turn_id | 保留 | 明确确认后执行一次 |
| Resend as new turn | 把旧输入追加到当前 active leaf，作为新任务 | 保留 | 用户选择后执行一次 |
| Fork here | 从明确、安全、已持久化的边界创建新 session，保留来源关系 | 源 session 不变 | 默认不运行模型 |

现有“找到旧 prompt 再 submit”的行为只能标为 Resend；在真正的 Retry 完成之前，禁止给该行为使用会误导用户的 Retry 文案。[S1]

### 8.2 Retry 的精确边界

Retry 默认针对完整 turn，而不是随意重放其中一个 LLM/tool request。输入使用已保存的原始用户内容和附件引用，不将当前上下文后的旧 prompt 再次追加；不静默重新展开已经执行过的 skill 文本。

新执行以原用户输入对应的 checkpoint 为基础，不包含原回答及其后续对话。旧分支继续可查看，原执行和新执行的消耗均保留在 session own usage。

默认使用原 provider/model，若不可用则要求显式选择替代；权限遵循当前安全策略，不能复活过期授权。文件、外部服务和工具环境可能变化，因此 Retry 不是确定性回放。

已有数据无法重建原始输入、附件或安全边界时，拒绝假装重放成功，解释缺失原因，并提供显式 Resend/Fork 的可用选项。

### 8.3 Fork 的精确边界

基础交互以“完成的 turn 之后”为默认 fork 点。Fork popover 显示源 session、turn/消息边界、目标标题、模型、工作目录及是否切换到新 session。

不能在未配对的 tool-call/tool-result 中间创建可运行上下文。点击中间 message 时，需要用户选择有效边界；不得悄悄把边界移动到别处。压缩之前的历史边界须由 journal ancestry 正确重建，否则明确拒绝。

Fork 保留来源 session、来源 entry/leaf、operation ID 和创建时间。新 session own usage 为零；继承记录保留 origin/request 身份，不能重复统计。

### 8.4 副作用、忙状态与并发

界面必须明确提示：**Retry/Fork 只改变对话历史，不回滚已执行的文件修改、命令、Git 操作或外部请求。共享工作目录时，新旧会话仍操作同一组文件。**

运行、审批、压缩或 cancellation 尚未确认结束时，不允许越过 runtime 的 busy guard。浏览器禁用按钮不是安全边界。

变更操作携带幂等 operation ID 及期望 source revision/leaf。双击、断线后重发、多标签页竞争不得产生两个执行或两个 fork。Revision 冲突必须要求刷新选择，不能在新的 active leaf 上执行旧操作。

## 9. 数据与实现架构约束

### 9.1 单一事实来源

持久化的 request/turn/compaction 事实进入现有 journal writer 的一致性边界。Session metrics 由这些事实纯 fold 得到；LiveView、debug log buffer 和浏览器计时器都不是累计统计的事实来源。

统计不能只遍历 `snapshot.messages`：该视图可能只包含当前有效上下文，不能覆盖已压缩消息、非当前分支、失败请求和维护请求。[S4]

Metrics operational records 不得变成发给模型的消息，也不能意外推进 conversation active leaf。新增记录形式、版本策略和旧 reader 行为必须在契约任务中冻结。

### 9.2 建议职责划分

| 层 | 职责 |
| --- | --- |
| `sigma_protocol` | 无 I/O 的共享 DTO、闭合事件/命令 schema；名字在 SUI-00 冻结。 |
| `sigma_ai` | Provider usage 归一化、请求边界与时间事实，不维护 session 总账。 |
| `sigma_coding` / 现有 dispatcher 边界 | 带相关 ID 的工具 begin/end/error 事实。 |
| `sigma_session` | Journal 兼容性、持久化事实、纯 metrics reducer 与 replay。 |
| `sigma_agent` | 运行阶段、当前 context/policy、受控操作、live projection 与一致性 snapshot。 |
| `sigma_web` | 展示、格式化、交互、局部更新；不重复计算业务累计或阈值。 |

纯 reducer 可命名为 `Sigma.Session.Metrics`，runtime 持有 live projection；这是建议命名，不是已存在模块。不得因为沿用某个建议名字而引入 umbrella 依赖环。

### 9.3 Snapshot、更新与协议

客户端先建立订阅与 snapshot watermark 边界，再应用其后的更新。消息包含可去重的事件身份/序号；缺口、溢出或 revision 不连续时触发 resync，而不是继续显示不可靠总量。

Live delta 可以降频；已持久化的最终结果不能丢失。请求最终 usage 的补报或修正按 request ID 更新，不改变已终止 turn 的运行状态。

复用 PublicRuntime、既有 socket/channel/stdio 适配层。可增加逻辑上的 metrics snapshot 查询和 metrics changed 事件，但正式命名与 protocol version/capability 兼容方式必须先确认旧客户端的闭合类型行为。[S6]

不持久化每一个文本 token 事件。至少持久化必要的 start/terminal/correction 事实；高频展示增量保持可丢弃、可从 snapshot 恢复。

## 10. 兼容性、性能与隐私

旧日志必须可打开。缺失 timing、usage、完整 turn identity 或 compaction 详情时，标记 legacy/partial/unknown；不要通过阅读页面偷偷改写历史。语义无法可靠恢复时，应降低功能而不是猜测。

用户刷新页面或 agent 重启后，已完成统计保持一致；未终止 request 标为 interrupted/unknown，不假设仍在计费，也不能把停机时间计成模型生成时间。

初次构建可以顺序扫描 journal，后续按事件增量更新。禁止每个 token、每秒时钟或每次 render 全量 replay。大型对话应分页/窗口化显示，摘要缓存只能是可重建派生数据。

验证 viewport 至少覆盖 390、1024、1440 像素宽度，light/dark 两类主题。窄屏把右栏变为 drawer；不丢失统计与操作。关键按钮有可访问名称、焦点可见、可键盘触发；状态不能只靠颜色表达。

不得把 provider key、认证头或未脱敏的原始网络 payload 发送到浏览器 metrics。Inspector/export 遵循当前 session 访问边界，只包含已授权的内容和经过选择的诊断字段。

## 11. 验收标准

| ID | 必须通过的场景 |
| --- | --- |
| AC-01 | 一轮有多个 LLM/tool 步骤时，消息、request 和 turn 汇总对应正确，无重复记账。 |
| AC-02 | Provider 明确报告 input total 40k（包含 30k cache）、output total 1k（包含 400 reasoning）时，完整总量为 41k。 |
| AC-03 | 两请求分别输出 10/1000 tokens、耗时 0.1/20 秒，平均吞吐率约 50.25 tok/s，而不是 75。 |
| AC-04 | 添加请求之外的 30 秒工具耗时，只增加 turn/tool 时间，不改变已完成 LLM 请求吞吐率。 |
| AC-05 | Context 从 100k 压缩到 25k 后 UI 正确下降，session 已发生 usage 保留并计入压缩开销。 |
| AC-06 | 刷新与 runtime 重启后，usage 和成功 compaction 次数一致；legacy 缺失字段显示未知。 |
| AC-07 | Fork 新 session own usage 为零，继承 context/来源可见；父 session 总量不变。 |
| AC-08 | Retry 旧 turn 不包含该 turn 原回答及后续内容，原分支保留，新执行恰好一次。 |
| AC-09 | Retry/Fork 不回滚实际文件；界面提示共享工作目录和副作用。 |
| AC-10 | 双击、多标签页、重复事件、迟到 usage correction 不重复执行或累计。 |
| AC-11 | 错误、取消、tool-only、usage 缺失、进程中断均可展示，不出现 NaN、伪造 0 或无限 running。 |
| AC-12 | Model window 未知时不显示假容量；切模型/分支/压缩后旧 context 估计失效。 |
| AC-13 | 订阅缺口或慢消费者丢失增量后通过 snapshot 恢复；刷新中进行的 turn 状态正确。 |
| AC-14 | 390/1024/1440 宽度、light/dark、键盘操作、长代码、输入保留与滚动不抢占通过浏览器验证。 |
| AC-15 | 至少 10,000 条 journal 记录的 fixture 验证增量行为；稳定更新不扫描整个日志，不重复持久化 token delta。 |
| AC-16 | 压缩失败不增加成功次数，但其已知模型消耗保留；手动压缩遵守 safe boundary。 |
| AC-17 | Metrics operational records 不进入模型上下文、不破坏 active leaf；旧协议客户端保持明确兼容或显式版本拒绝。 |

V2 的必需功能以这些验收为完成标准，不以“页面上出现了数字和按钮”为完成标准。

## 12. 源码与记录索引

[S1] 前一轮读取：`apps/sigma_web/lib/sigma_web/live/session_live.ex`，尤其 `retry_message`、`latest_context_token_count`、`assign_context_token_count`、message footer/actions、右栏 render。

[S2] 前一轮读取：`apps/sigma_agent/lib/sigma_agent/session_process.ex`，`defstruct`、`init`、`handle_call(:status)`、`apply_event({:compact, ...})`。

[S3] 前一轮搜索：`apps/sigma_agent/lib/sigma_agent.ex`，`@default_compact_threshold`、`@compact_context_ratio`、`maybe_compact`。

[S4] 前一轮读取/搜索：`apps/sigma_session/lib/sigma_session/log.ex`、`writer.ex`、`entry_encoder.ex`、`operations.ex`。

[S5] 前一轮搜索：`docs/contracts/session-journal-and-operations-v2-prd.md`、`docs/adr/0001-session-journal-and-operations-v2.md`。实施时需读取全文，搜索摘要不构成完整契约验证。

[S6] 本轮 Agent Note 读取：`Sigma Protocol V1 and headless runtime`，note ID `0d766b60-3888-438a-81e6-5ca1b070b32d`，revision 1。其测试通过描述是历史笔记记录，不是本次独立执行的结果。它指向 `docs/protocol-v1.md`，实施时需核对该文档和实际代码。

[S7] 本轮可读取的公开仓库 README 页面：应用边界、开发命令、DuskMoon 约束。网页可能有缓存，不作为当前 HEAD 证明。
