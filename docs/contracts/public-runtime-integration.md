# PublicRuntime 集成笔记（Synapsis / Samgita）

- Status: **Active**（S9 Phase 1 WO-5）
- Date: 2026-09-04
- Updated: 2026-09-09（Session UI Observability V2）；2026-11-12（§8.1 samgita_protocol host）
- Depends on: [protocol-v1.md](protocol-v1.md)、`Sigma.Agent.PublicRuntime`、`Sigma.Protocol.Envelope`
- Related: [S9 Phase 1 plan](s9-phase1-plan.md) WO-5、[ADR 0002](../adr/0002-beam-extension-sdk.md)、[providers playbook](../features/providers.md)

> Synapsis / Samgita 如何用 **Protocol V1 + PublicRuntime** 驱动会话，而不 fork Sigma OTP 树、不内嵌对方产品代码。  
> 外部集成者只读本文即可写出最小 **prompt → stream → cancel** 客户端草图。

---

## 1. 边界（先读）

| 做 | 不做 |
| --- | --- |
| 经 `Sigma.Protocol.Envelope` 建命令，经 `Sigma.Agent.PublicRuntime.execute/2` 执行 | 直接 `GenServer.call` Agent / Runtime / SessionProcess |
| 用 `subscription.attach` 收 `{:sigma_protocol, subscription_id, envelope}` | 把 PID、`#PID<…>`、OTP 模块名、Registry 名塞进协议 payload |
| 信任上下文（`repo_path` / `sessions_dir` / `session_opts` / `subscriber`）只留在进程本地 | 在 wire 上暴露内部 OTP 名或进程标识 |
| 适配器（stdio / WebSocket / 自研）只转发信封 | 在运输层拥有 Agent 生命周期规则 |
| 本仓提供契约与适配器参考 | 在本仓实现 Synapsis/Samgita 产品代码；发布对方 Hex 包；多集群 |

权威信封语义见 [protocol-v1.md](protocol-v1.md)。扩展工具不得发明新 wire 命令（[ADR 0002](../adr/0002-beam-extension-sdk.md)）。

---

## 2. 推荐调用面

### 2.1 首选入口

| 层 | 模块 / 命令 | 用途 |
| --- | --- | --- |
| 命令边界 | `Sigma.Agent.PublicRuntime.execute/2` | 唯一稳定的直接 Elixir API |
| 信封 | `Sigma.Protocol.Envelope.command/4`、`events/0`、`commands/0`、`capabilities/0` | 版本化 command/event 与 capability；未知 type 拒绝且不造 atom |
| 编解码 | `Sigma.Protocol.Codec` | JSON Lines / WebSocket `data` 字段 |
| 订阅 | `subscription.attach` / `subscription.detach` | 经 PublicRuntime；勿自建 Agent `subscribe` 旁路（产品集成） |
| 会话生命周期（产品级） | `session.create` / `resume` / `status` | create/resume 由 PublicRuntime 确保 runtime 已起 |

### 2.2 Synapsis / Samgita 最小命令子集

完整集合见 `Sigma.Protocol.Envelope.commands/0`。产品集成 **优先** 下列子集：

| 命令 | 何时用 |
| --- | --- |
| `session.create` | 新会话（payload：`cwd` / `providerId` / `modelId` / `metadata`） |
| `session.resume` | 已有 JSONL，确保 Agent 在跑 |
| `session.status` | 重连后拿快照 + `runtime` / `turn` 相位 |
| `subscription.attach` | 原子建立 snapshot/cursor 边界；返回 `subscriptionId` |
| `subscription.detach` | 主动卸订阅（disconnect 时适配器也会卸） |
| `prompt.submit` | 主路径：提交用户输入，得 `prompt.admitted` |
| `prompt.steer` / `prompt.follow_up` | 运行中引导 / 排队 follow-up（可选） |
| `turn.cancel` | **显式**取消当前 turn |
| `permission.resolve` | 交互审批：`requestId` + `decision`（`allow` \| `deny`） |
| `model.select` | 切换模型（需上下文提供 `model_resolver`） |
| `session.retry` | 从持久化 turn checkpoint 创建 replacement branch；不是 Resend |

次要（需要时再开）：`session.switch` / `session.fork` / `session.dump` /
`session.export`、`mcp.elicitation.resolve`。

### 2.3 信任上下文（不进 wire）

`PublicRuntime.execute(command, context)` 的 `context` 由宿主注入，**永不序列化**：

| 键 | 含义 |
| --- | --- |
| `repo_path` / `sessions_dir` | 仓库与会话目录（亦可放 payload，但推荐上下文） |
| `session_opts` | `keyword` 或 `fun(snapshot) -> keyword`：须含 `provider`（atom）与 `model`（map） |
| `subscriber` | 收 `{:sigma_protocol, …}` 的 PID；默认 `self()` |
| `interactive_approvals` | `true` 时走交互 `permission.required` 路径 |
| `permission_resolver` / `question_resolver` | 非交互自定义解析（可选） |
| `model_resolver` | `model.select` 用 |
| `max_subscriber_queue` | 订阅背压（默认 256） |
| `allow_external_cwd` / `artifact_root` / `allow_artifact_replace` | 路径/产物能力开关 |

参考实现：`Sigma.Agent.Stdio`、`Sigma.Web.SessionChannel`（均只调 PublicRuntime）。

---

## 3. 完整 turn 草图（直接 Elixir）

```elixir
alias Sigma.Agent.PublicRuntime
alias Sigma.Protocol.Envelope

session_id = "synapsis-demo"
context = %{
  repo_path: repo_path,
  sessions_dir: sessions_dir,
  subscriber: self(),
  interactive_approvals: true,
  session_opts: fn _snapshot ->
    [provider: MyProvider, model: %{id: "demo"}, cwd: repo_path]
  end
}

{:ok, create} =
  Envelope.command("session.create", session_id, %{
    "cwd" => repo_path,
    "providerId" => "demo",
    "modelId" => "demo"
  })

{:ok, %Envelope{type: "session.snapshot"}} = PublicRuntime.execute(create, context)

{:ok, attach} =
  Envelope.command("subscription.attach", session_id, %{
    "requiredCapabilities" => [
      "metrics.v1",
      "subscription.cursor.v1",
      "subscription.resync.v1"
    ]
  })

{:ok,
 %Envelope{
   payload: %{
     "subscriptionId" => sub_id,
     "enabledCapabilities" => enabled,
     "watermark" => watermark
   }
 }} =
  PublicRuntime.execute(attach, context)

{:ok, prompt} =
  Envelope.command("prompt.submit", session_id, %{"content" => "Inspect the repository"})

{:ok, %Envelope{type: "prompt.admitted", turn_id: turn_id}} =
  PublicRuntime.execute(prompt, context)

# 流式事件：{:sigma_protocol, ^sub_id, %Envelope{}}
# 终端：turn.completed | turn.failed | turn.cancelled | session.error
# 仅应用 cursor > watermark 的后续事件；metrics.changed 仅在 metrics.v1 已启用时出现。

# 可选取消：
{:ok, cancel} = Envelope.command("turn.cancel", session_id)
PublicRuntime.execute(cancel, context)
```

事件顺序（典型）：`prompt.admitted` → `turn.started` → `message.*` / `tool.*` → 终端事件。列表见 `Envelope.events/0`。

---

## 4. 订阅、重连、断开

### 4.1 订阅语义

- `subscription.attach` 为 **一个** sink PID 建非阻塞 relay；事件形态：`{:sigma_protocol, subscription_id, envelope}`。
- attach 响应本身是原子 snapshot 边界；新 relay 返回 `cursor == watermark == 0`，随后事件 cursor 严格递增。
- `requiredCapabilities` 会校验、去重并回显为 `enabledCapabilities`；不支持项返回 `unsupported_capabilities`。
- `metrics.changed` 是 `metrics.v1` opt-in。省略该 capability 的旧 V1 客户端不会收到新增闭合事件类型，metrics fact 也不占其 cursor。
- **订阅者断开只卸 relay，不取消活跃 turn**（S7；stdio EOF / Channel `terminate` 同理）。
- 慢订阅者可能丢 **中间** 事件；有序 **终端** 事件（`turn.completed` / `failed` / `cancelled` / `session.error`）会保留。
- 多客户端可并存；某一客户端掉线不影响其他订阅者与 Agent。
- sink overflow 或 metrics revision gap 会先发 `session.error` / `resync_required`；收到后不得继续累加旧 projection。

### 4.2 重连配方

1. `session.resume`（若进程已死）或确认 runtime 仍在。
2. 用所需 `requiredCapabilities` 执行 `subscription.attach`，把返回 snapshot 作为初始 projection，并保存 `subscriptionId` / `watermark`。
3. 只应用 cursor 大于 watermark 的后续事件；重复 metrics revision 不重复累计。
4. 遇到 cursor 缺口或 `resync_required`，暂停 delta，执行带该 `subscriptionId` 的 `session.status`；用返回 snapshot 整体替换 projection，再从新 watermark 之后继续。
5. 需要完整历史时用 `session.dump` / `session.export`（路径须在仓库或 `artifact_root` 内）。

**取消 turn 只能**发 `turn.cancel`；不要把 disconnect 当成 cancel。

---

## 5. Metrics snapshot 与 privacy

`session.snapshot.metrics` 是 journal 可重建的 durable projection；
`runtimeSnapshot.metrics` 在其上增加当前 in-flight request 等瞬时状态。不要把
`runtimeSnapshot.metrics.activeRequest` 写回 durable totals，也不要把顶层 metrics
缺少 active request 解释为 idle。

`metrics.changed` 的 request fact 仅允许身份、provider/model、purpose/status、
revision、标准化 usage/timing、语义 provenance 与 retry relation。凭证、认证
header、raw provider payload 和任意 adapter metadata 均不得进入 wire 或 metrics
journal。request/turn summaries 有界，不能替代完整 journal dump。

## 6. Retry / Resend / Fork

| 操作 | 语义 |
| --- | --- |
| `session.retry` | 从所选 user message 对应 turn 前的持久化 checkpoint 创建 replacement branch 和新 turn |
| Resend | 将旧文本作为新的 `prompt.submit` 追加到当前 active leaf；没有独立 wire command |
| `session.fork` | 创建独立 session，复制所选 lineage/context；child own usage 为零，来源 usage 记为 inherited |

Retry/Fork 使用 `operationId`（省略时取 command envelope ID）实现幂等，并可带
`expectedSourceRevision` / `expectedSourceLeaf` 做 stale-client 检查。busy、revision
冲突、缺失附件或不可用 replacement model 都显式失败，不退化成普通 submit。

三种操作均不回滚工作目录中的文件、Git 或外部副作用；Fork 默认仍共享工作目录。

## 7. Permission / `approval_required`

| 模式 | 行为 |
| --- | --- |
| 默认 allow-all | 无 resolver 也可执行工具（除非规则显式 `ask` / deny） |
| `interactive_approvals: true` | 先 `subscription.attach`，再 prompt；收到 `permission.required`，用 `permission.resolve`（`requestId` + `allow`\|`deny`） |
| 显式 `ask` 且无 resolver / 非 interactive | 工具不执行；流上出现带 `error.code == "approval_required"` 的 `session.error` |

要点：

- `permission.resolve` 的 `requestId` 必须匹配当前请求；错误 id → `not_found`，工具不跑。
- 默认允许策略 **不会** 因无 resolver 变成全局 gated；仅显式 `ask` 触发 `approval_required`。
- MCP 表单另走 `mcp.elicitation.resolve`（`accept` / `decline` / `cancel`）。

---

## 8. 运输适配器（可选）

| 适配器 | 入口 | 说明 |
| --- | --- | --- |
| 直接 Elixir | `PublicRuntime.execute/2` | Synapsis 同节点 OTP 首选 |
| JSON Lines | `Sigma.Agent.Stdio.run/3` | 每行一条编码命令；EOF 不断 turn |
| WebSocket | `/agent/websocket` → `session:<id>` | `repository` + `token`（`SIGMA_PROTOCOL_TOKEN` ≥32B）；`command` / `event` 通道 |
| samgita_protocol 1.0 | `GET /app-server` | 原生 thread/turn/item 协议，见 §8.1 |

远程客户端：编码信封进运输层，逻辑仍等价于 PublicRuntime。同 BEAM 节点优先直接 Elixir，避免多余编解码。

### 8.1 samgita_protocol host（`/app-server`）

Sigma 在现有 Phoenix endpoint 上以 samgita_protocol 1.0 暴露会话面，供 Synapsis / Samgita
像驱动 Codex app-server 一样驱动 Sigma。设计见
[samgita-protocol-host-design](../superpowers/specs/2026-11-12-samgita-protocol-host-design.md)。
实现：`Sigma.Web.SamgitaHost.{EndpointPlug, Handler, ThreadStream, Translate, Commands, ThreadId}`；
所有请求仍只经 `PublicRuntime.execute/2`。

**端点与认证**：`ws://127.0.0.1:4580/app-server`（路径精确匹配、query 为空），
`Authorization: Bearer <SIGMA_PROTOCOL_TOKEN>`（与 `/agent` 同一 token，≥32B；未配置即 401）。
在 endpoint 层于 `Plug.Static` / Router 之前挂载，不另起监听。

**能力组**：`sessions.v1`、`streaming.v1`、`cancellation.v1`（不声明 `approvals.v1`，Sigma 保持 YOLO 默认）。
客户端可只协商其中一部分：host 按连接协商到的组过滤通知（samgita_protocol 0.4.1 起 handler 可见协商组，
见 [gsmlg-opt/Samgita#1](https://github.com/gsmlg-opt/Samgita/issues/1)）。未协商 `streaming.v1` 的连接
收不到 `item/*`，`turn/started` / `turn/completed` 不带 `stream_id` / `cursor`（无回放；`active_stream` 为
`null`），连接保持可用。

**thread_id**：`<base64url-无填充(已注册仓库绝对路径)>.<session_id>`，与路由 `:repository` 同一编码；
UI / Protocol V1 创建的会话可直接拼出。解析失败、仓库未注册、会话 journal 不存在 → `not_found`。

| 请求 | Sigma 命令 | 结果 |
| --- | --- | --- |
| `thread/start`（`metadata.repository` 必填，`title?`） | `session.create`（`cwd` = 仓库；其余 metadata + `title` 写入会话 metadata；`metadata.provider_id` / `model_id` 覆盖默认模型） | `thread_id`、`thread`；session id 为 32 位小写 hex；随后发非回放通知 `thread/started`；本连接开始跟随该 thread。未注册仓库 → `invalid_params` |
| `thread/read` | `session.status`（`history.limit: 50`，host 字节预算 512 KiB） | `thread` = `{turn, runtime, message_count, active_stream, messages, messages_truncated}`；`active_stream` 只对本连接跟随的 thread 给出，否则 `null`；`messages` 为最近 50 条对话消息 `{id, role: user\|assistant, text, tools?, truncated?}`（`text` 为文本块拼接，单条 ≤ 8 KiB；`tools` 为工具调用名；不含 thinking、图片与工具结果），更早消息被省略时 `messages_truncated: true`；`thread/start` 返回 `messages: []` |
| `thread/resume` | `session.resume` + `session.status`（同上 history） | 同上（含 `messages`）；确保 ThreadStream 并跟随（推送活跃 turn 的 backlog） |
| `turn/start` | `prompt.submit`，`admission: "reject_if_busy"`，input 文本以 `\n\n` 连接；执行前重新跟随本连接已跟随的 thread | `turn_id`、`status: "running"`；已有运行 turn → `conflict`（`turn_active`）；会话未运行 → `conflict`（`session_not_running`，先 `thread/resume`） |
| `turn/steer` | `prompt.steer`，`expectedTurnId`；同样先重新跟随 | 同上；turn 不符或无运行 turn → `conflict`（`turn_mismatch`） |
| `turn/interrupt` | `turn.cancel`，`expectedTurnId` | `cancelling` / `already_cancelling` → `requested`；同一 turn `already_cancelled` → `interrupted`；`no_active_turn` 或其他 turn 已取消 → `already_finished`；`turn_mismatch` → `conflict` |
| `stream/resume` | 无（读本连接跟随 thread 的 Replay） | `{stream_id, cursor, events}`（≤128 条/页）；未知或已丢弃的流 → `replay_gap` |
| `request/cancel` | 无 | Server 按连接串行处理，被引用请求必已结束：本连接最近 128 个已完成请求 id → `already_finished`，否则 `not_found` |

| Sigma 事件 | 原生通知（`stream_id` = turn_id，cursor 从 1 起） |
| --- | --- |
| `turn.started` | `turn/started` |
| `turn.completed` / `turn.failed` / `turn.cancelled` | `turn/completed`，`status` = `completed` / `failed` / `interrupted` |
| `message.started` / `message.completed` | `item/started` / `item/completed`（`item.type = "message"`） |
| `message.delta`（仅 `deltaKind: "text"`） | `item/delta` |
| `tool.started` / `tool.completed` | `item/started` / `item/completed`（`item.type = "tool"`） |

用户消息的 item 早于 `turn/started` 发出，因此 turn 流的 cursor 1 通常是用户 item。

**conflict 原因**：`conflict` 一律带 `details.reason`，取值固定：`turn_active`、`turn_mismatch`、
`session_busy`、`session_not_running`、`command_id_conflict`。

**重新跟随**：会话 Agent 退出时 ThreadStream 停止；`turn/start` / `turn/steer` 执行前会对本连接已跟随的
thread 重新挂接，因此会话在别处重启后新 turn 照常下发。按 `command_id` 重放的 `thread/start` /
`thread/resume` 也让当前连接跟随该 thread（`thread/start` 重放会再发一次 `thread/started`）。

**晚加入与重连**：连接经 `thread/start` / `thread/resume` 跟随 thread 时，host 在挂接调用内先推送活跃
turn 的保留 backlog（cursor 1 起），再推实时通知；`active_stream` 给出 backlog 末尾 cursor。若该 turn
的 cursor 1 已不在保留窗内，本连接跳过该 turn，从下一个 turn 开始接收。订阅事件丢失（`resync_required`
或订阅 cursor 不连续）会毒化受影响 turn：停止扇出、丢弃其 log（`stream/resume` → `replay_gap`），客户端改用
`thread/read` 快照。

**幂等与限制**：
- 所有变更请求先按 `command_id` 进入全局有界内存表（1024 条，FIFO 淘汰）：同 id 同参数 → 返回原结果，
  不重复执行；同 id 不同参数或仍在执行 → `conflict`。只有确定失败（Sigma 命令执行前失败，或
  `PublicRuntime.execute/2` 返回错误）才释放 id 以便重试；执行中/后的 raise 或 exit、命令已生效后的
  失败（如 `session.create` 成功但无法跟随流）结果不确定，id 保持占用，同 id 重试得 `conflict`，
  客户端应以 `thread/read` 核对后换新 `command_id`。这一保留只在 1024 条窗口内成立：条目被淘汰后同 id
  会作为新命令执行。
- Replay 只在内存：每 turn ≤4096 条，每 thread 保留最近 8 个 turn。Sigma 重启后 `command_id` 表与流历史
  丢失，`stream/resume` 得 `replay_gap`；恢复不变量不变（不重放 Provider 调用或工具效果）。
- ThreadStream 在会话 Agent 退出时停止；无挂接连接且无运行 turn 时空闲超时退出。连接断开不取消 turn。

---

## 9. 公开状态形状（无 PID）

`session.status` / 快照中的公开字段示例：

```json
{
  "protocolVersion": 1,
  "capabilities": ["metrics.v1", "subscription.cursor.v1", "subscription.resync.v1"],
  "watermark": 12,
  "runtime": { "status": "running", "messageCount": 3, "eventCount": 12 },
  "turn": {
    "phase": "streaming_provider",
    "turnId": "…",
    "currentRequestId": "request-id",
    "steeringQueueCount": 0,
    "followUpQueueCount": 0
  },
  "metrics": { "schemaVersion": 1, "available": true },
  "runtimeSnapshot": {
    "watermark": 12,
    "metrics": { "activeRequest": { "requestId": "request-id", "status": "running" } }
  }
}
```

`phase` 等为字符串；**禁止**依赖内部 atom、进程名或 `#Reference<…>`。错误经 `Sigma.Protocol.Error`（如 `approval_required`），不含 exception struct。

---

## 10. Legacy client 与 downgrade

- 旧 Protocol V1 closed-enum client 省略 `metrics.v1`，仍只接收旧事件类型。
- 非 `1` 的 envelope version 和未知 type 会显式拒绝，不能靠忽略字段完成跨版本降级。
- 当前 journal reader 将 metrics operational records 排除在 model context 和 active leaf 之外，并对旧日志缺失字段给出 partial/unknown。
- 这不构成“任意旧 binary 可写新 journal”的保证。binary downgrade 前停止 writer 并备份 JSONL；未验证的旧版本不要对新 journal 原地写入。

## 11. 给 Synapsis / Samgita 的集成建议

1. **薄适配层**：对方仓库只包一层「Envelope ↔ PublicRuntime ↔ 订阅 mailbox」，不要复制 Agent turn loop。
2. **同节点**：依赖 `sigma_agent` + `sigma_protocol`（及会话/工具所需 app），用直接 API。
3. **跨进程**：stdio 或已启用的 Agent WebSocket；token 与仓库注册仍由 Sigma 宿主管。
4. **审批**：UI 产品设 `interactive_approvals: true`；无人值守自动化保持 allow-all，或自带 `permission_resolver`。
5. **契约测试**：以 `sigma_protocol` codec/metrics tests、`public_runtime_test.exs`、`protocol_event_mapper_test.exs` 和 metrics privacy tests 为当前行为证据。
6. **禁止**：`Runtime.lookup` 拿 PID 当公共 API、监督对方树、在 Sigma 内嵌 Samgita/Synapsis 产品模块。

---

## 12. 验收对照（WO-5）

- [x] 命令子集、订阅/重连、审批、`approval_required`、disconnect≠cancel、边界写清  
- [x] 外部集成者可据此写 prompt→stream→cancel 草图  
- [x] 无 Synapsis/Samgita 产品实现、无 Hex 包、无多集群设计  

Session UI metrics、恢复和操作契约见
[session-ui/contract.md](../features/session-ui/contract.md)；S9 原始阶段边界仍见
[s9-phase1-plan.md](s9-phase1-plan.md) §8。
