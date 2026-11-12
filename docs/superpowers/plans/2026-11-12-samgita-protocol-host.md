# Samgita Protocol Host（会话面）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 Phoenix endpoint 上暴露 samgita_protocol 1.0 `/app-server`，协商 `sessions.v1` / `streaming.v1` / `cancellation.v1`，把请求翻译成 `PublicRuntime` 命令、把 Sigma 事件翻译成原生通知。

**Architecture:** 上游 `SamgitaProtocolWebSocket.Plug` 负责升级与每连接 `Server`；`Sigma.Web.SamgitaHost.Handler` 做纯翻译并调用 `PublicRuntime.execute/2`；每个 thread 一个 `ThreadStream` GenServer 订阅 Sigma 事件、按 turn 维护 `SamgitaProtocol.Replay` 并扇出给已挂接的连接 Socket。Sigma Agent 侧增加严格 turn 选项与 `deltaKind`，与 Codex `TurnSteerParams.expectedTurnId` / `TurnInterruptParams.turnId` / 分类型 item delta 对齐。

**Tech Stack:** Elixir umbrella、Phoenix 1.8 + Gaoxy adapter、hex `samgita_protocol ~> 0.4.0`、`samgita_protocol_websocket ~> 0.4.0`。

**Spec:** [docs/superpowers/specs/2026-11-12-samgita-protocol-host-design.md](../specs/2026-11-12-samgita-protocol-host-design.md)

## Global Constraints

- 原生 wire `schema_version: "1.0"`；只声明 `["sessions.v1", "streaming.v1", "cancellation.v1"]`；不声明 `approvals.v1`。
- 不另起监听端口或服务进程；只挂在 `Sigma.Web.Endpoint`。
- 认证复用 `SIGMA_PROTOCOL_TOKEN` / `:sigma_web, :protocol_token`（≥32 字节，`Plug.Crypto.secure_compare`）；未配置时一律 401。不为认证路径新增专项测试（仓库规则）。
- 所有 Sigma 调用经 `PublicRuntime.execute/2`；不直接 `GenServer.call` Agent。wire 上不出现 PID / OTP 名。
- `thread_id = Base.url_encode64(repo_abs_path, padding: false) <> "." <> session_id`；仓库必须已在 `RepoManager` 注册。
- 新 session id：`:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)`（与 `entry_encoder.ex:208` 一致）。
- Sigma Agent 新选项默认关闭，现有行为不变。
- 上游缺口走 `upstream-issue-routing`；能力组要求标注 `TODO(upstream): gsmlg-opt/Samgita#1`。
- 每个 task 收尾：`mix format --check-formatted`、`mix compile --warnings-as-errors`、该 task 的测试；提交只含该 task 文件（工作区 `mix.lock` 已有无关修改，Task 4 前先与用户确认是否一起提交）。

## Review Focus

1. **turn 中途加入的连接**（第二个客户端、或断线重连且未带 checkpoint）：期望先按序收到当前 turn 已保留的通知、再收实时通知，不被上游 Client 判 `replay_gap` 断开；保留窗口已丢开头时，从下一个 turn 开始接收，同样不断开。→ Task 6、Task 7 测试。
2. **畸形或已失效的 thread_id**（非 base64、缺 `.`、仓库已移除、session 不存在）：期望 `not_found`，不 crash 连接。→ Task 4、Task 7 测试。
3. **同一 `command_id` 重放**（客户端在响应丢失后重试 `turn/start`）：期望返回原结果、不开第二个 turn；参数不同 → `conflict`。→ Task 5、Task 7 测试。
4. **多连接同一 thread，一个断开**：另一个继续收通知；ThreadStream 不因单连接退出而停止。→ Task 6 测试。
5. **ThreadStream 不存在时的 `stream/resume`**（Sigma 重启后或已空闲回收）：期望 `replay_gap`，不是 `handler_error`。→ Task 7 测试。

---

### Task 1: Sigma Agent 严格 turn 选项

**Files:**
- Modify: `apps/sigma_agent/lib/sigma_agent.ex`（`admit_prompt/4` ≈2109-2141、`admission_mode/2` ≈2337-2345、`cancel/1` ≈301、`handle_call(:cancel, …)` ≈1027）
- Modify: `apps/sigma_agent/lib/sigma_agent/public_runtime.ex`（`admit_prompt/3` ≈676、`cancel_session/3` ≈714、`call_prompt/4`）
- Modify: `docs/contracts/protocol-v1.md`（命令 payload 小节）
- Test: `apps/sigma_agent/test/sigma_agent/public_runtime_test.exs`

**Interfaces:**
- Produces（Protocol V1 payload，全部可选）：
  - `prompt.submit` 的 `"admission" => "reject_if_busy"`：若现有逻辑会走排队分支 → `{:error, {:prompt_rejected, :turn_active}}`，不排队。
  - `prompt.steer` 的 `"expectedTurnId" => id`：无运行 turn，或 `turn_state.turn_id != id` → `{:error, {:prompt_rejected, :turn_mismatch}}`，不新开 turn、不入队。
  - `turn.cancel` 的 `"expectedTurnId" => id`：有运行 turn 且 id 不符 → `{:error, :turn_mismatch}`；其余与现有一致（`cancelling` / `already_cancelling` / `already_cancelled` / `{:error, :no_active_turn}`）。
- Produces（Elixir）：`Sigma.Agent.cancel(pid, opts \\ [])`，`opts` 接受 `expected_turn_id: String.t()`；`Sigma.Agent.prompt/3`、`steer/3` 的 opts 接受 `admission: :reject_if_busy`、`expected_turn_id: String.t()`。

- [ ] **Step 1: 写失败测试**（在 public_runtime_test 中复用该文件现有阻塞 provider 的 setup）
  - `test "prompt.submit with admission reject_if_busy rejects while a turn runs"`：turn A 阻塞中提交 → `{:error, {:prompt_rejected, :turn_active}}`；释放后 A 完成且没有 follow-up turn 运行。
  - `test "prompt.submit without admission still queues a follow-up"`：断言现有 `"status" => "queued_as_follow_up"`。
  - `test "prompt.steer with mismatched expectedTurnId is rejected"`：A 运行中，`expectedTurnId: "other"` → `{:error, {:prompt_rejected, :turn_mismatch}}`。
  - `test "prompt.steer with expectedTurnId and no active turn does not start a turn"`：→ `:turn_mismatch`，`session.status` 的 turn phase 不变。
  - `test "prompt.steer with matching expectedTurnId steers"`：→ `"status" => "queued_as_steering"`、`"turnId" == A`。
  - `test "turn.cancel with mismatched expectedTurnId leaves the turn running"`：→ `{:error, :turn_mismatch}`；之后用正确 id 取消得到 `"status" => "cancelling"`。
- [ ] **Step 2: 运行确认失败** — `mix test apps/sigma_agent/test/sigma_agent/public_runtime_test.exs`，预期新增 6 个中 5 个失败（“without admission” 应已通过）。
- [ ] **Step 3: 实现**
  - `admit_prompt/4`：在 `start_turn` 分支，若 `opts[:expected_turn_id]` 非 nil → 拒绝 `:turn_mismatch`；在排队分支，`opts[:admission] == :reject_if_busy` → 拒绝 `:turn_active`；`mode == :steering` 且 `expected_turn_id` 非 nil 且 ≠ `state.turn_state.turn_id` → 拒绝 `:turn_mismatch`。拒绝路径与现有 `:session_busy` 分支一致：`release_resources` + `emit({:prompt_rejected, reason})`。
  - `admission_mode(:auto, opts)` 对 `:reject_if_busy` 落到 `:follow_up`（实际不会执行到排队）。
  - `handle_call({:cancel, opts}, …)`：`expected_turn_id` 存在且有运行 turn 且不符 → `{:error, :turn_mismatch}`，否则沿用 `:cancel` 的现有逻辑（`cancel/1` 委托 `cancel(pid, [])`）。
  - `PublicRuntime`：从 payload 读 `"admission"`（仅接受 `"reject_if_busy"`，其他值 → `{:error, :invalid_admission}`）与 `"expectedTurnId"`（非空字符串），并入 `prompt_opts` / `cancel` opts；`expectedTurnId` 存在时 `cancel_session/3` 不走 `cancel_detached_children`。
- [ ] **Step 4: 运行确认通过** — 同一命令，全部 PASS；再跑 `mix test apps/sigma_agent` 确认无回归。
- [ ] **Step 5: 文档** — `protocol-v1.md` 记录三个可选字段及其拒绝原因。
- [ ] **Step 6: 提交** — `feat(agent): add strict turn admission and expected turn checks`

### Task 2: `message.delta` 增加 `deltaKind`

**Files:**
- Modify: `apps/sigma_agent/lib/sigma_agent/protocol_event_mapper.ex:98, 600-604`
- Modify: `docs/contracts/protocol-v1.md`
- Test: `apps/sigma_agent/test/sigma_agent/protocol_event_mapper_test.exs`

**Interfaces:**
- Produces：`message.delta` payload 为 `%{"messageId", "delta", "deltaKind"}`，其中 `deltaKind ∈ ["text", "thinking", "toolcall"]`；裸字符串 delta 为 `"text"`；无法识别的 delta 不带 `deltaKind`（保持 `"delta" => ""`）。

- [ ] **Step 1: 写失败测试** `test "message.delta carries deltaKind per provider delta"`：分别喂 `{:text_delta, 0, "a", msg}`、`{:thinking_delta, 0, "b", msg}`、`{:toolcall_delta, 0, "c", msg}`，断言 `deltaKind` 依次为 `"text"` / `"thinking"` / `"toolcall"`，`delta` 不变。
- [ ] **Step 2: 运行确认失败** — `mix test apps/sigma_agent/test/sigma_agent/protocol_event_mapper_test.exs`
- [ ] **Step 3: 实现** — 把 `public_delta/1` 改为返回 `{kind, text}` 或新增 `delta_kind/1`，在 98 行 payload 加入。
- [ ] **Step 4: 运行通过**，并跑 `mix test apps/sigma_web/test/sigma_web/session_channel_test.exs` 确认现有消费者不受影响。
- [ ] **Step 5: 文档 + 提交** — `feat(protocol): tag message.delta with deltaKind`

### Task 3: 抽出共享的协议 context 与 token 校验

纯重构，无行为变化，供 host 复用。

**Files:**
- Create: `apps/sigma_web/lib/sigma_web/protocol_context.ex`
- Create: `apps/sigma_web/lib/sigma_web/protocol_token.ex`
- Modify: `apps/sigma_web/lib/sigma_web/session_channel.ex:63-161`、`apps/sigma_web/lib/sigma_web/agent_socket.ex:31-44`

**Interfaces:**
- Produces：
  - `Sigma.Web.ProtocolToken.verify(token :: term()) :: :ok | :error`：搬移 `AgentSocket.authenticate/1` 原样逻辑。
  - `Sigma.Web.ProtocolContext.build(%{workdir: String.t(), sessions_dir: String.t(), session_id: String.t(), subscriber: pid()}, opts :: keyword()) :: map()`：返回现有 `execute_command/2` 中的 context 映射（含 skill store 与 `SkillInvocationService.callbacks/1` 合并），`opts[:interactive_approvals]` 默认 `true`（Channel 现状），`opts[:initial_metadata]` 透传给 session_opts 构造。
  - `Sigma.Web.ProtocolContext.prepare(command :: Envelope.t(), workdir :: String.t()) :: {:ok, Envelope.t()} | {:error, term()}`：搬移 `prepare_command/2`。
- [ ] **Step 1: 搬移实现**，`SessionChannel` / `AgentSocket` 改为调用新模块。
- [ ] **Step 2: 回归** — `mix test apps/sigma_web/test/sigma_web/session_channel_test.exs` 全部 PASS（不新增测试）。
- [ ] **Step 3: 提交** — `refactor(web): share protocol context and token verification`

### Task 4: 依赖与 `ThreadId`

**Files:**
- Modify: `apps/sigma_web/mix.exs`（加入 `{:samgita_protocol, "~> 0.4.0"}`、`{:samgita_protocol_websocket, "~> 0.4.0"}`）、`mix.lock`
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/thread_id.ex`
- Test: `apps/sigma_web/test/sigma_web/samgita_host/thread_id_test.exs`

**Interfaces:**
- Produces：
  - `Sigma.Web.SamgitaHost.ThreadId.encode(repo_path :: String.t(), session_id :: String.t()) :: String.t()`
  - `ThreadId.decode(thread_id :: term()) :: {:ok, %{repo_path: String.t(), sessions_dir: String.t(), session_id: String.t()}} | {:error, :not_found}`：在第一个 `.` 处切分；base64 失败、空段、仓库未注册 → `{:error, :not_found}`；`repo_path` 为 `Path.expand(repo["path"])`，`sessions_dir` 为 `ConfigManager.ensure_sessions_dir/1`。
  - `ThreadId.repository(path :: term()) :: {:ok, String.t()} | {:error, :invalid_params}`：`thread/start` 的 `metadata.repository` 校验。

- [ ] **Step 1: 确认 `mix.lock` 现有修改的归属**（问用户），然后 `mix deps.get`；确认 lock 中 `gaoxy_http`、`gaoxy_websock_adapter`、`http_web_socket`、`plug_crypto` 版本未被降级。
- [ ] **Step 2: 写失败测试**（RepoManager 注册临时仓库，参照 `session_channel_test.exs:68-117` 的 setup）：
  - `"encode/decode round-trips a registered repository"`
  - `"session ids containing dots survive decode"`（`"a.b"` → `session_id == "a.b"`）
  - `"decode rejects malformed ids"`：`"nodot"`、`"!!!.x"`、`".x"`、`"abc."`、`123` 均为 `{:error, :not_found}`
  - `"decode rejects unregistered repositories"`
  - `"repository/1 accepts only registered absolute paths"`
- [ ] **Step 3: 运行确认失败 → 实现 → 运行通过** — `mix test apps/sigma_web/test/sigma_web/samgita_host/thread_id_test.exs`
- [ ] **Step 4: 提交** — `feat(web): add samgita_protocol deps and thread id codec`

### Task 5: `Translate` 与 `Commands`

**Files:**
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/translate.ex`
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/commands.ex`
- Modify: `apps/sigma_web/lib/sigma_web/application.ex`（在 Endpoint 之前启动 `Commands`）
- Test: `apps/sigma_web/test/sigma_web/samgita_host/translate_test.exs`、`.../commands_test.exs`

**Interfaces:**
- Produces（纯函数）：
  - `Translate.notification(event :: Sigma.Protocol.Envelope.t(), thread_id :: String.t()) :: {:ok, map()} | :skip`。返回完整原生 notification map `%{"schema_version" => "1.0", "type" => "notification", "correlation_id" => event.turn_id, "method" => m, "params" => p}`，不含 `stream_id` / `cursor`。映射：
    - `turn.started` → `turn/started`
    - `turn.completed` / `turn.failed` / `turn.cancelled` → `turn/completed`，status 分别为 `completed` / `failed` / `interrupted`
    - `message.started` / `message.completed` → `item/started` / `item/completed`，`item_id = payload["message"]["id"]`，`item = %{"type" => "message", "role" => …, "content" => …}`
    - `message.delta` 且 `deltaKind == "text"` → `item/delta`（`item_id = messageId`）；其他 kind → `:skip`
    - `tool.started` → `item/started`，`item_id = toolCallId`，`item = %{"type" => "tool", "name" => …, "arguments" => …}`；`tool.completed` → `item/completed`，`item = %{"type" => "tool", "name", "content", "is_error"}`；`tool.update` → `:skip`
    - 其他事件、或缺 `turn_id` → `:skip`
  - `Translate.thread_started(thread_id) :: map()`：非回放 `thread/started` 通知，`correlation_id = thread_id`。
  - `Translate.error(reason :: term()) :: SamgitaProtocol.Error.t()`：`:not_found` / `:session_not_found` → `not_found`；`{:prompt_rejected, :turn_active}` / `{:prompt_rejected, :turn_mismatch}` / `:turn_mismatch` → `conflict`；`:model_unavailable` / `:invalid_admission` / `:invalid_params` → `invalid_params`；其余 → `handler_error`。`details` 永不包含输入内容。
- Produces（进程）：`Sigma.Web.SamgitaHost.Commands`，命名 GenServer，有界 1024 条（FIFO 淘汰）：
  - `reserve(command_id :: String.t(), fingerprint :: term()) :: :new | {:done, result} | :conflict`：同 id 不同 fingerprint → `:conflict`；同 id 执行中 → `:conflict`
  - `complete(command_id, result) :: :ok`；`release(command_id) :: :ok`（执行出错时释放，允许重试）
  - fingerprint = `{method, params}`。

- [ ] **Step 1: 写失败测试** — 每条映射一个断言（含 `deltaKind: "thinking"` → `:skip`、`tool.update` → `:skip`、无 `turn_id` → `:skip`）；返回的每个 notification 用 `SamgitaProtocol.Schema.validate/1` 补上 `stream_id`/`cursor` 后校验通过；`Translate.error/1` 各分支；Commands 的 `:new` → `complete` → `{:done, r}`、不同 fingerprint 返回 `:conflict`、执行中重入返回 `:conflict`、`release` 后再 `reserve` 为 `:new`、超过 1024 条后最旧条目被淘汰。
- [ ] **Step 2: 运行确认失败 → 实现 → 运行通过**
- [ ] **Step 3: 提交** — `feat(web): translate Sigma events to samgita_protocol notifications`

### Task 6: `ThreadStream`

**Files:**
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/thread_stream.ex`
- Modify: `apps/sigma_web/lib/sigma_web/application.ex`（`Registry` name `Sigma.Web.SamgitaHost.Registry`、`DynamicSupervisor` name `Sigma.Web.SamgitaHost.ThreadStreams`）
- Test: `apps/sigma_web/test/sigma_web/samgita_host/thread_stream_test.exs`

**Interfaces:**
- Consumes：`ThreadId.decode/1`、`Translate.notification/2`、`ProtocolContext.build/2`、`PublicRuntime.execute/2`（`subscription.attach` 以自身为 subscriber）。
- Produces：
  - `ThreadStream.ensure(thread_id) :: {:ok, pid} | {:error, :not_found}`：经 Registry 查找或启动；启动时执行 `subscription.attach`。
  - `ThreadStream.attach(thread_id, socket_pid) :: {:ok, %{active_stream: nil | %{"stream_id" => String.t(), "cursor" => non_neg_integer()}}}`：监控 socket；**在同一次 call 内**，若当前 turn 的 Replay 仍含 cursor 1，则按序把已保留事件 `send(socket_pid, {:protocol_notification, msg})`，之后实时扇出；若已丢失 cursor 1，则当前 turn 不向该连接发送，从下一个 turn 起发送（我的决定，取代设计稿中“客户端先 `stream/resume(…, 0)`”）。
  - `ThreadStream.resume(thread_id, stream_id, cursor) :: {:ok, [map()]} | {:error, SamgitaProtocol.Error.t()}`：ThreadStream 不存在、或 stream 未知 → `replay_gap`；否则 `Replay.since/2`。
  - 状态：每个 turn 一个 `Replay`，`stream_id = turn_id`，`limit: 4096`；保留最近 8 个 turn 的 log。
  - 生命周期：零连接挂接且无运行 turn 时，300_000 ms 后退出（`subscription.detach`）。
- [ ] **Step 1: 写失败测试**（用 `ChannelProvider` / `BlockingChannelProvider` 同款 mock provider 与 setup）：
  - `"a turn is delivered in cursor order to an attached socket"`：用测试进程当 socket，收到 `turn/started`（cursor 1）… `turn/completed`，cursor 连续，`stream_id == turn_id`。
  - `"a late attach receives the retained backlog before live events"`：阻塞的 turn 中途 attach，先收到 cursor 1..n，再收到 n+1。
  - `"two sockets both receive; one exiting does not stop the stream"`
  - `"resume returns replay_gap for unknown streams"`
- [ ] **Step 2: 运行确认失败 → 实现 → 运行通过**
- [ ] **Step 3: 提交** — `feat(web): add per-thread samgita stream with bounded replay`

### Task 7: Handler、endpoint 挂载与 loopback 集成测试

**Files:**
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/handler.ex`
- Create: `apps/sigma_web/lib/sigma_web/samgita_host/endpoint_plug.ex`
- Modify: `apps/sigma_web/lib/sigma_web/endpoint.ex`（在 `socket "/agent"` 之后、`Plug.Static` 之前加入 `plug Sigma.Web.SamgitaHost.EndpointPlug`）
- Modify: `docs/contracts/public-runtime-integration.md`（新增 samgita_protocol 小节：端点、三个能力组、请求/通知映射、thread_id 格式、客户端必须同时提供三组的要求附 Samgita#1、内存幂等与 replay 限制）
- Test: `apps/sigma_web/test/sigma_web/samgita_host/handler_test.exs`、`.../loopback_test.exs`

**Interfaces:**
- Consumes：Task 1-6 的全部 Produces。
- Produces：
  - `Handler.capabilities/0` 返回 `["sessions.v1", "streaming.v1", "cancellation.v1"]`；`methods/0` 返回 `SamgitaProtocol.Capabilities.methods(capabilities())`；handler state 为 `%{principal: term(), socket: pid()}`（在 `handler_state` fn 中以 `self()` 取得 socket）。
  - `handle_request/4` 各方法：
    - `thread/start`：`ThreadId.repository(metadata["repository"])`，生成 session id，`session.create`（payload `metadata` = 其余 metadata，加上 `"title"`），然后 `ThreadStream.ensure` + `attach`，`send(self(), {:protocol_notification, Translate.thread_started(id)})`
    - `thread/read`：`session.status`；`thread/resume`：`session.resume` + `ensure` + `attach`。两者的 `thread` 都包含 `"turn"`（status payload）与 `"active_stream"`
    - `turn/start`：`prompt.submit`，带 `"admission" => "reject_if_busy"`，input 文本以 `"\n\n"` 连接
    - `turn/steer`：`prompt.steer`，带 `"expectedTurnId"`
    - `turn/interrupt`：`turn.cancel`，带 `"expectedTurnId"`；`cancelling` / `already_cancelling` → `requested`，`already_cancelled`（同一 turn）→ `interrupted`，`:no_active_turn` 或其他 turn 的 `already_cancelled` → `already_finished`，`:turn_mismatch` → `conflict`
    - `stream/resume`：`ThreadStream.resume/3`，返回 `%{"stream_id", "cursor", "events"}`（cursor = 最后一条的 cursor，空页为请求的 cursor）
    - `request/cancel`：已在本连接完成的请求 id → `already_finished`，否则 `not_found`（handler state 中保留最近 128 个已完成请求 id，取自 context `"id"`）
  - 所有变更请求先过 `Commands.reserve(context["command_id"], {method, params})`。
  - `EndpointPlug.call/2`：`request_path == "/app-server"` 时委托给 `SamgitaProtocolWebSocket.Plug.call(conn, authenticate: &auth/1, handler: Handler, handler_state: &%{principal: &1, socket: self()})`，`auth/1` 为 `ProtocolToken.verify/1` 成功时返回 `{:ok, :sigma_protocol_token}`；其他路径原样返回 conn。在 Handler 的 capabilities 处加注 `# TODO(upstream): gsmlg-opt/Samgita#1`。
- [ ] **Step 1: 写失败测试**
  - handler_test：`"methods match advertised groups"`（`SamgitaProtocol.Server.new(Handler, state)` 返回 `{:ok, _}`）。
  - loopback_test：仿照 `endpoint_http_test.exs:23-61` 启动一个只挂 `EndpointPlug` 的测试 endpoint（`port: 0`、`server: true`），mock provider setup 仿照 session_channel_test；用 `SamgitaProtocolWebSocket.Client.connect("ws://127.0.0.1:#{port}/app-server", token: token, capabilities: […三组])`：
    - `"initialize negotiates the three groups"`
    - `"thread/start, turn/start stream items and complete"`：收到 `thread/started`、`turn/started`、`item/started`、≥1 `item/delta`、`item/completed`、`turn/completed status completed`
    - `"turn/start while busy is a conflict"`、`"turn/steer with stale turn_id is a conflict"`
    - `"turn/interrupt reports requested then the turn completes interrupted"`
    - `"replaying a command_id returns the original turn without a second turn"`；`"reusing a command_id with different params conflicts"`
    - `"a second client joining mid-turn receives backlog then live events"`（Review Focus 1）
    - `"unknown or malformed thread ids are not_found"`（Review Focus 2）
    - `"stream/resume for an unknown stream is replay_gap"`（Review Focus 5）
    - `"thread/read works for a session created through Protocol V1 / UI"`（用 `ThreadId.encode` 拼出 id）
- [ ] **Step 2: 运行确认失败 → 实现 → 运行通过** — `mix test apps/sigma_web/test/sigma_web/samgita_host`
- [ ] **Step 3: 全量检查** — `mix format --check-formatted`、`mix compile --warnings-as-errors`、`mix test`
- [ ] **Step 4: 在 dev server 上手动核验**（若 4580 正在运行且设置了 token）：用一个 mix run 脚本里的 `SamgitaProtocolWebSocket.Client` 连接 `ws://127.0.0.1:4580/app-server`，完成 initialize + thread/start + 一个 turn；记录结果，或注明未核验。
- [ ] **Step 5: 文档 + 提交** — `feat(web): expose samgita_protocol host at /app-server`
