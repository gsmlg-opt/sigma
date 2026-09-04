# PublicRuntime 集成笔记（Synapsis / Samgita）

- Status: **Active**（S9 Phase 1 WO-5）
- Date: 2026-09-04
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
| 信封 | `Sigma.Protocol.Envelope.command/4`、`events/0`、`commands/0` | 版本化 command/event；未知 type 拒绝且不造 atom |
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
| `subscription.attach` | 开始收流；返回 `subscriptionId` |
| `subscription.detach` | 主动卸订阅（disconnect 时适配器也会卸） |
| `prompt.submit` | 主路径：提交用户输入，得 `prompt.admitted` |
| `prompt.steer` / `prompt.follow_up` | 运行中引导 / 排队 follow-up（可选） |
| `turn.cancel` | **显式**取消当前 turn |
| `permission.resolve` | 交互审批：`requestId` + `decision`（`allow` \| `deny`） |
| `model.select` | 切换模型（需上下文提供 `model_resolver`） |

次要（需要时再开）：`session.switch` / `fork` / `dump` / `export`、`mcp.elicitation.resolve`。

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

{:ok, attach} = Envelope.command("subscription.attach", session_id)
{:ok, %Envelope{payload: %{"subscriptionId" => sub_id}}} =
  PublicRuntime.execute(attach, context)

{:ok, prompt} =
  Envelope.command("prompt.submit", session_id, %{"content" => "Inspect the repository"})

{:ok, %Envelope{type: "prompt.admitted", turn_id: turn_id}} =
  PublicRuntime.execute(prompt, context)

# 流式事件：{:sigma_protocol, ^sub_id, %Envelope{}}
# 终端：turn.completed | turn.failed | turn.cancelled | session.error

# 可选取消：
{:ok, cancel} = Envelope.command("turn.cancel", session_id)
PublicRuntime.execute(cancel, context)
```

事件顺序（典型）：`prompt.admitted` → `turn.started` → `message.*` / `tool.*` → 终端事件。列表见 `Envelope.events/0`。

---

## 4. 订阅、重连、断开

### 4.1 订阅语义

- `subscription.attach` 为 **一个** sink PID 建非阻塞 relay；事件形态：`{:sigma_protocol, subscription_id, envelope}`。
- **订阅者断开只卸 relay，不取消活跃 turn**（S7；stdio EOF / Channel `terminate` 同理）。
- 慢订阅者可能丢 **中间** 事件；有序 **终端** 事件（`turn.completed` / `failed` / `cancelled` / `session.error`）会保留。
- 多客户端可并存；某一客户端掉线不影响其他订阅者与 Agent。

### 4.2 重连配方

1. `session.resume`（若进程已死）或确认 runtime 仍在。
2. `session.status` → `session.snapshot`（含有界消息、`messageCount` / `messagesTruncated`、`runtime`、`turn`）。
3. `subscription.attach` 继续收后续事件。
4. 需要完整历史时用 `session.dump` / `session.export`（路径须在仓库或 `artifact_root` 内）。

**取消 turn 只能**发 `turn.cancel`；不要把 disconnect 当成 cancel。

---

## 5. Permission / `approval_required`

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

## 6. 运输适配器（可选）

| 适配器 | 入口 | 说明 |
| --- | --- | --- |
| 直接 Elixir | `PublicRuntime.execute/2` | Synapsis 同节点 OTP 首选 |
| JSON Lines | `Sigma.Agent.Stdio.run/3` | 每行一条编码命令；EOF 不断 turn |
| WebSocket | `/agent/websocket` → `session:<id>` | `repository` + `token`（`SIGMA_PROTOCOL_TOKEN` ≥32B）；`command` / `event` 通道 |

远程客户端：编码信封进运输层，逻辑仍等价于 PublicRuntime。同 BEAM 节点优先直接 Elixir，避免多余编解码。

---

## 7. 公开状态形状（无 PID）

`session.status` / 快照中的公开字段示例：

```json
{
  "runtime": { "status": "running", "messageCount": 3, "eventCount": 12 },
  "turn": {
    "phase": "streaming_provider",
    "turnId": "…",
    "steeringQueueCount": 0,
    "followUpQueueCount": 0
  }
}
```

`phase` 等为字符串；**禁止**依赖内部 atom、进程名或 `#Reference<…>`。错误经 `Sigma.Protocol.Error`（如 `approval_required`），不含 exception struct。

---

## 8. 给 Synapsis / Samgita 的集成建议

1. **薄适配层**：对方仓库只包一层「Envelope ↔ PublicRuntime ↔ 订阅 mailbox」，不要复制 Agent turn loop。
2. **同节点**：依赖 `sigma_agent` + `sigma_protocol`（及会话/工具所需 app），用直接 API。
3. **跨进程**：stdio 或已启用的 Agent WebSocket；token 与仓库注册仍由 Sigma 宿主管。
4. **审批**：UI 产品设 `interactive_approvals: true`；无人值守自动化保持 allow-all，或自带 `permission_resolver`。
5. **契约测试**：Phase 2（计划 P1-D）再加外部夹具；Phase 1 以本笔记 + `public_runtime_test.exs` 行为为准。
6. **禁止**：`Runtime.lookup` 拿 PID 当公共 API、监督对方树、在 Sigma 内嵌 Samgita/Synapsis 产品模块。

---

## 9. 验收对照（WO-5）

- [x] 命令子集、订阅/重连、审批、`approval_required`、disconnect≠cancel、边界写清  
- [x] 外部集成者可据此写 prompt→stream→cancel 草图  
- [x] 无 Synapsis/Samgita 产品实现、无 Hex 包、无多集群设计  

Phase 2 预告：PublicRuntime 外部契约测试夹具 + 更深产品 cookbook（见 [s9-phase1-plan.md](s9-phase1-plan.md) §8）。
