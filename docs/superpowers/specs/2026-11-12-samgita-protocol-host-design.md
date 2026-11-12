# Sigma 作为 samgita_protocol host（子项目 1：会话面）

- Status: Draft
- Date: 2026-11-12
- 上游参考：`../Samgita/apps/samgita_protocol`（0.4.0，wire schema 1.0）、
  `../Samgita/apps/samgita_protocol_websocket`、`../Samgita/docs/redesign/protocol-phase-2.md`、
  `../Samgita/docs/redesign/integrations/sigma.md`、`../Synapsis/docs/design.md` §4/§6
- Sigma 侧：`Sigma.Agent.PublicRuntime`、`Sigma.Protocol.Envelope`、
  `Sigma.Web.SessionChannel`、`Sigma.Web.AgentSocket`、`Sigma.Web.ProtocolSessionOptions`

## 1. 意图

让 Sigma 能像 Codex 一样被接入：Codex 通过 app-server 被 Samgita / Synapsis 驱动，
Sigma 则通过 **samgita_protocol 原生 1.0** 暴露自己。整体分三个子项目：

1. **本文**：host 骨架 + `sessions.v1` / `streaming.v1` / `cancellation.v1`，
   让本机 Synapsis 能直接把一段任务交给 Sigma（Synapsis 设计 P7 正卡在“Sigma 实现
   samgita_protocol host”）。
2. 后续：`project_events.v1` + 持久化 inbox（Samgita 推事件给 Sigma）。
3. 后续：Samgita 管理 API 客户端（`POST /api/agent/connect`、claim/report 回调），
   即“远程连接 Samgita”。

子项目 2、3 各自单独出设计，不在本文范围。

## 2. 目标 / 非目标 / 反目标

**目标**

- Sigma 在现有 Phoenix endpoint 上暴露 `GET /app-server`（samgita_protocol WebSocket，
  Bearer 认证），协商 `sessions.v1`、`streaming.v1`、`cancellation.v1`。
- 协议请求全部翻译为 `PublicRuntime.execute/2` 命令；Sigma 事件翻译为原生通知。
- 用 `SamgitaProtocolWebSocket.Client` 走真实 loopback 完成
  initialize → thread/start → turn/start → 收 item 流 → turn/completed、
  turn/interrupt、断线后 stream/resume 的功能测试。

**非目标**

- `project_events.v1`、持久化 inbox、Samgita 管理 API（子项目 2/3）。
- `approvals.v1`：属于审批功能，按仓库规则不开发、不声明。Sigma 保持 YOLO 默认，
  `interactive_approvals` 不开。
- Unix socket 监听：`samgita_protocol_websocket` 只支持 TCP 监听/WS URL；本机 Synapsis 走
  `ws://127.0.0.1:4580/app-server` + token。若以后需要 socket，按 `upstream-issue-routing`
  向 Samgita 提需求，不在本地造传输。
- Synapsis / Samgita 仓库内的任何代码修改；Samgita 平台目前没有原生 `sessions.v1` 客户端，
  本文不负责补。
- 跨 Sigma 重启的 replay 与 `command_id` 幂等持久化（见 §5.5）。

**反目标（即使能跑也算失败）**

- 另起一个 Sigma 服务进程或独立监听端口（Samgita `AGENTS.md` 明确禁止）。
- 绕过 `PublicRuntime` 直接 `GenServer.call` Agent / SessionProcess。
- 在 wire 上暴露 PID、OTP 模块名、文件系统内部路径之外的进程标识。
- 声明未经测试的能力组；对不支持的操作做静默回退。
- 为绕过上游缺陷做本地 patch / 私有状态修改。

## 3. 约束

- 依赖：hex `{:samgita_protocol, "~> 0.4.0"}`、`{:samgita_protocol_websocket, "~> 0.4.0"}`，
  加到 `apps/sigma_web/mix.exs`。其传递依赖（`gaoxy_http ~> 0.15.1`、
  `gaoxy_websock_adapter`、`plug_crypto 2.2.1`、`http_web_socket ~> 1.0.0-rc.5`）
  与当前 `mix.lock` 已有版本兼容。注意工作区 `mix.lock` 已有未提交修改，实施时先确认再动。
- 0.4.0 是实验版；上游缺陷或缺失能力走 `upstream-issue-routing`（Samgita 属 `gsmlg-opt`），
  确认的阻塞即停，不做本地绕过。
- `SamgitaProtocolWebSocket.Plug` 只接受 `request_path == "/app-server"` 且 query 为空，
  必须在 endpoint 层、`Plug.Parsers` / Router 之前挂载（或用等价方式确保路径精确匹配）。
- 认证：复用现有 `SIGMA_PROTOCOL_TOKEN`（`Sigma.Web.AgentSocket` 同源配置，≥32 字节），
  未配置时 `/app-server` 一律 401（等同禁用）。这是复用已有机制，不新增安全/权限功能；
  按仓库规则不为认证路径新增专项测试，功能测试只是携带合法 token。
- 仓库规则：Sigma 是 Web 产品，无独立 CLI；host 只是另一个运输适配器。

## 4. 架构

```text
Synapsis ──WS /app-server──▶ SamgitaProtocolWebSocket.Socket (每连接进程)
                               │ SamgitaProtocol.Server.receive/2
                               ▼
                         Sigma.Web.SamgitaHost.Handler  (纯翻译 + 调用)
                               │ Envelope.command → PublicRuntime.execute/2
                               ▼
                         Sigma.Agent / Session (现有)
                               │ {:sigma_protocol, sub_id, envelope}
                               ▼
                         Sigma.Web.SamgitaHost.ThreadStream (每 thread 一个，host 持有)
                           - 订阅 PublicRuntime（subscription.attach）
                           - Sigma 事件 → 原生通知（纯函数 Translate）
                           - 追加到 SamgitaProtocol.Replay（有界，stream_id = thread_id）
                           - 扇出给已挂接的 Socket：send(pid, {:protocol_notification, msg})
```

模块（放在 `sigma_web`，与 `AgentSocket` / `SessionChannel` 同层；我的决定）：

| 模块 | 职责 |
| --- | --- |
| `Sigma.Web.SamgitaHost.Handler` | 实现 `SamgitaProtocol.Handler`；`capabilities/0` 返回三组；`methods/0` 精确等于三组请求方法；`handle_request/4` 只做参数→Envelope 翻译与结果映射 |
| `Sigma.Web.SamgitaHost.Translate` | 纯函数：Sigma Envelope 事件 → 原生通知 map；Sigma 错误 → `SamgitaProtocol.Error` |
| `Sigma.Web.SamgitaHost.ThreadStream` | 每 thread 的 GenServer，`DynamicSupervisor` + `Registry` 管理；持有 Replay log 与挂接连接集合（监控 Socket pid） |
| `Sigma.Web.SamgitaHost.Commands` | 每 thread 有界的 `command_id → {params_hash, result}` 表（放在 ThreadStream 状态里即可） |

Socket 的 `handler_state` 用 principal 函数构造，在 Socket 进程内执行，因此 `self()` 即
Socket pid，Handler 用它向 ThreadStream 挂接。Socket 进程退出由 ThreadStream 的 monitor
清理；ThreadStream 在 Sigma 会话 runtime 结束且无挂接连接时退出。

## 5. 协议映射

### 5.1 能力与初始化

`connection/initialize` 由 `SamgitaProtocol.Server` 内建处理。Handler 声明
`["sessions.v1", "streaming.v1", "cancellation.v1"]`。

### 5.2 请求

| 原生请求 | Sigma 命令 | 结果 |
| --- | --- | --- |
| `thread/start`（`title?`, `metadata.repository`） | `session.create`（仓库见 §7；provider/model 走 `ProtocolSessionOptions.prepare_create/1` 默认值，`metadata.provider_id` / `metadata.model_id` 可覆盖） | `thread_id` = Sigma session id，`thread` = 精简快照；随后发 `thread/started` |
| `thread/read`（`thread_id`） | `session.status` | `thread_id` + `thread`（有界快照：状态、turn 相位、最近消息投影） |
| `thread/resume`（`thread_id`） | `session.resume` | 同上；确保 ThreadStream 存在并挂接本连接 |
| `turn/start`（`thread_id`, `input`） | `prompt.submit`（input 文本按顺序以 `\n\n` 连接） | `thread_id`, `turn_id`, `status: "running"`（来自 `prompt.admitted`） |
| `turn/steer`（`thread_id`, `turn_id`, `input`） | `prompt.steer`；`turn_id` 与当前运行 turn 不符 → `conflict` | 同上 |
| `turn/interrupt`（`thread_id`, `turn_id`） | `turn.cancel` | `status`：已发出取消 → `requested`；已停止 → `interrupted`；turn 已结束 → `already_finished` |
| `stream/resume`（`stream_id`, `cursor`） | 不进 PublicRuntime；读 ThreadStream 的 Replay | `Replay.since/2` 结果；超出保留 → `replay_gap` |
| `request/cancel`（`request_id`） | 无 Sigma 命令 | Server 按连接串行处理请求，到达时被引用请求必已结束：已知 id → `already_finished`，未知 → `not_found` |

`prompt.admitted` 已携带 `turnId`，`turn/start` 直接使用。

**现状差异**（builder check 核实）：`prompt.submit` 在已有运行 turn 时会排队为 follow-up 并成功
（`sigma_agent.ex:2128-2141`）；`prompt.steer` 无运行 turn 时会新开 turn（`:2122-2127`）；
`prompt.steer` 与 `turn.cancel` 都不接受 turn id（`public_runtime.ex:264-279, 714-728`）。
按 §7，Sigma Agent 增加严格选项后表中 `conflict` 语义成立。

### 5.3 通知

**流按 turn 划分（我的决定）**：每个 turn 一个 stream，`stream_id` = turn_id，cursor 从 1 开始；
`turn/started` 起、`turn/completed` 止均为该流的可回放通知。`thread/started` 为非回放通知。
原因：上游 Client 对 `cursor > seen + 1` 直接判 `replay_gap` 并断开
（`samgita_protocol/lib/samgita_protocol/client.ex:429-430`），thread 级单流在第一个 turn 内
就会越过保留窗，晚加入的连接再也无法接收。

- Replay 保留上限按 turn 设为较大值（`Replay.new/2` 允许 ≤10_000；具体值实施时定），
  分页仍是 128 条。
- `thread/read` / `thread/resume` 的 `thread` 快照携带 `active_stream: {stream_id, cursor}`
  （无运行 turn 时为 null）。晚加入或重连的客户端先 `stream/resume(stream_id, 0)` 追上，
  再接收实时通知；超出保留则得到 `replay_gap`，改用快照。

| Sigma 事件 | 原生通知 |
| --- | --- |
| `turn.started` | `turn/started` |
| `turn.completed` / `turn.failed` / `turn.cancelled` | `turn/completed`，`status` = completed / failed / interrupted |
| `message.started` / `message.delta` / `message.completed` | `item/started` / `item/delta` / `item/completed`，`item.type = "message"`，`item_id` = Sigma message id；只转发正文文本 delta（见下） |
| `tool.started` / `tool.completed` | `item/started` / `item/completed`，`item.type = "tool"`，含工具名与有界结果预览；`tool.update` 不转发（无字符串 delta） |

**delta 分类（我的决定）**：`Sigma.Agent.ProtocolEventMapper` 目前把正文、thinking、工具参数
delta 合并进同一 `message.delta` 字符串（`protocol_event_mapper.ex:600-603`）。在 Sigma 侧为
`message.delta` payload **增量添加** `deltaKind`（`text` / `thinking` / `toolcall`），现有
Protocol V1 客户端忽略未知字段即可；host 只把 `text` 转为 `item/delta`。

**能力组要求（我的决定，上游缺口）**：Handler 看不到协商结果，而 WS Socket 会以 1008 关闭发送
未协商组通知的连接（`samgita_protocol_websocket/.../socket.ex:70-79`）。因此本 host 要求客户端
同时提供三组；只提供 `sessions.v1` 的客户端会在首个 `item/*` 时被断开。按
`upstream-issue-routing` 向 Samgita 提 issue（让 Handler context 可见协商组），分类为 `needed`；
文档化的客户端要求就是临时约定，不在本地绕过，issue 解决后移除该要求。
| 其他（metrics、subagents、questions、hosted 等） | 不转发 |

`item` 对象只放有界显示投影；完整历史仍以 Sigma 的 JSONL 为准。

### 5.4 错误映射

Sigma `{:error, reason}` → `SamgitaProtocol.Error`：会话不存在 → `not_found`；
已有运行 turn / turn 不匹配 → `conflict`（前提见 §7 第 2 项）；模型不可用等配置问题 → `invalid_params`；
其余 → `handler_error`（`message` 不插值输入或密钥）。

### 5.5 幂等与持久性（我的决定）

- 状态变更请求的 `command_id` 在 ThreadStream 内做有界内存去重：同 id 同参数 → 返回原结果；
  同 id 不同参数 → `conflict`。`thread/start` 尚无 thread，用 host 级有界表。
- Replay log 在内存、有界（保留条数待实现时取默认值并写入测试）。Sigma 重启后 stream 历史丢失，
  `stream/resume` 返回 `replay_gap`，客户端应改用 `thread/read` 拿快照——与恢复不变量一致
  （不重放 Provider 调用或工具效果，不伪造结果）。
- 断线：正在跑的 turn 不因连接断开而取消（与 stdio / Channel 适配器一致）。

## 6. 验证

- `Translate` 纯函数单测：每类事件/错误映射。
- Handler 合约：`methods/0` 与三组请求方法完全相等。
- `sigma_agent`：严格提交与期望 turn id 的回归测试（含默认行为不变），`message.delta` 的 `deltaKind`。
- thread_id 编解码往返；未注册仓库与畸形 thread_id。
- 真实 loopback 集成测试（`sigma_web` test，使用已有测试 provider 配置
  `:test_provider_config`）：用 `SamgitaProtocolWebSocket.Client` 连测试 endpoint，覆盖
  initialize 协商、thread/start/read/resume、turn/start → item 流 → turn/completed、
  turn/steer、turn/interrupt、断线重连后 stream/resume 续接与 `replay_gap`、重复/冲突
  `command_id`、request/cancel。
- `mix compile --warnings-as-errors`、`mix format --check-formatted`、相关 `mix test`。
- 文档：在 `docs/contracts/public-runtime-integration.md` 增加 samgita_protocol 一节，说明端点、
  能力组、映射与限制。

## 7. 已定（用户决策，2026-11-12）

- **thread_id 编码仓库**：所有 PublicRuntime 命令都需要 `repo_path` / `sessions_dir`
  （`public_runtime.ex:1214-1233`），后续请求只带 `thread_id`。
  - `thread/start` 必须带 `metadata.repository`：已在 Sigma 注册的仓库绝对路径；未注册 →
    `invalid_params`（与 `/agent/websocket` 一样只接受已注册仓库）。
  - `thread_id` = `<base64url-无填充(仓库绝对路径)>.<session_id>`，与路由 `:repository` 参数同一编码。
    解析失败或仓库未注册 → `not_found`。无额外状态，重启后照常解析；UI 创建的已有会话可直接拼出
    thread_id 访问。
  - `thread/start` 的 `title` / 其余 `metadata` 写入 `session.create` 的 `metadata`。
- **turn 严格语义（范围扩到 `sigma_agent`）**：在 Sigma Agent 侧增加可选参数，默认行为不变，
  只有 host 使用：
  - 提交时“忙则拒绝”：已有运行 turn → 原子拒绝（host 映射为 `conflict`），不排队为 follow-up。
  - steer / cancel 接受期望 turn id，在 Agent 进程内原子比较：不符或无运行 turn → 拒绝
    （steer → `conflict`；interrupt 对已结束 turn → `already_finished`，对不符 turn → `conflict`）。
  - 通过 `Envelope` payload 的可选字段（如 `expectedTurnId`、`admission: "reject_if_busy"`）经
    `PublicRuntime` 传入，字段名由实施者定；Protocol V1 文档同步说明。

另：`SamgitaProtocolWebSocket.Plug` 对其他路径返回 404 并 halt（`plug.ex:31`），endpoint 需
按路径包一层再委托，不能直接 `plug`。

## 8. 留给实施者

模块内部结构、Registry 命名、Replay 保留上限、快照字段的具体裁剪、测试组织。
