# Provider 扩展 Playbook

- Status: **Active**（S9 Phase 1 WO-4）
- Date: 2026-09-04
- Depends on: Provider Normalization V1（S5）、[`Sigma.Ai.Provider*`](../../apps/sigma_ai/lib/sigma_ai/provider.ex)
- Related: [S9 Phase 1 plan](../contracts/s9-phase1-plan.md) WO-4、[ADR 0002 Extension SDK](../adr/0002-beam-extension-sdk.md)、[build-api-session-context](../contracts/build-api-session-context.md)

> 如何在 **Normalized Provider** 合约上接新模型端点，或贡献 first-class 适配器。  
> **默认路径：复用 `Sigma.Ai.Providers.OpenAI`（OpenAI-compatible chat completions）。**  
> **不要**向 Agent / LiveView 暴露未规范化的裸 SSE / 厂商事件元组。

---

## 1. 决策树（先配置，后适配器）

```text
新模型 / 网关
    │
    ├─ 暴露 OpenAI Chat Completions SSE？
    │     └─ YES → 只改 ~/.pi/agent/models.json + auth
    │              （api: openai-completions，baseUrl，model id，authType）
    │              使用现有 Sigma.Ai.Providers.OpenAI — 不要新模块
    │
    ├─ 暴露 Anthropic Messages SSE？
    │     └─ YES → api: anthropic-messages + Sigma.Ai.Providers.Anthropic
    │
    └─ 线协议与两者均不兼容，且差异已确认？
          └─ 才允许 1 个 first-class 薄适配器（见 §5）
             必须实现 stream_normalized / capabilities；
             强制 fake transport + 归一化事件测试
```

Phase 1 **禁止**同时新增多个厂商适配器；多数「新模型」应走 OpenAI-compat。

---

## 2. 合约入口（调用方只碰这些）

| 模块 | 职责 |
| --- | --- |
| `Sigma.Ai.Provider` | 唯一公共 seam：`stream/2`、`capabilities/2`、legacy → normalized 桥 |
| `Sigma.Ai.ProviderRequest` | 中性请求（`model` / `context` / `options` / session ids） |
| `Sigma.Ai.ProviderEvent` | 归一化生命周期事件 |
| `Sigma.Ai.ProviderError` | 闭合错误分类 + retry 元数据 |
| `Sigma.Ai.ProviderCapabilities` | tools / thinking / image / windows / options |
| `Sigma.Ai.ProviderUsage` / `ProviderStopReason` | usage 与 stop 归一化 |
| `Sigma.Ai.ProviderAuth` | bearer / x-api-key / custom header；空白密钥省略 header |

会话接线：`Sigma.Web.ProtocolSessionOptions` 按 `api_type` 选择模块，并把 `base_url` / `api_key` / `auth_type` / `auth_header_name` 注入 `options`。

**硬规则**

1. Agent turn loop **不得**对厂商做特判；只消费 `%ProviderEvent{}`。
2. 适配器内部可保留 legacy `stream/1` 元组，但对外入口必须是 `Provider.stream/2`（会走 `stream_normalized` 或 legacy 归一化）。
3. **禁止**新增「只实现裸 `stream/1`、且绕过 `Provider.stream/2`」的热路径。新代码优先实现 `stream_normalized/1`。
4. 畸形 / 截断 tool arguments **不得**变成可执行的 `tool_call.completed`。

---

## 3. OpenAI-compatible 配置面（首选）

现有 OpenAI 适配器已验证的配置：

| 选项 | 来源 | 说明 |
| --- | --- | --- |
| `base_url` | `models.json` → `baseUrl`，或 `OPENAI_BASE_URL` | 须含 `/v1` 前缀风格；请求发往 `{base_url}/chat/completions` |
| `api_key` | `auth.json` 解析后的 `resolved_key`，或 `OPENAI_API_KEY` / `OPENROUTER_API_KEY` | 空白则 **不发** Authorization（keyless 网关） |
| `auth_type` | `authType`：`bearer`（默认 openai）/ `x-api-key` / `custom_header` | 见 `ProviderAuth` |
| `auth_header_name` | `authHeaderName` | 仅 `custom_header` 时使用 |
| `model.id` | provider 下 `models[].id` | 原样写入 JSON body `model` |
| `cancellation_ref` | 运行时 options | 协作取消；见 §6 |
| `receive_timeout` | options | 默认 120s |

### 3.1 `~/.pi/agent/models.json` 示例（compat 网关）

```json
{
  "providers": {
    "openrouter": {
      "name": "OpenRouter",
      "api": "openai-completions",
      "baseUrl": "https://openrouter.ai/api/v1",
      "authType": "bearer",
      "credential_id": "openrouter",
      "models": [
        {
          "id": "anthropic/claude-sonnet-4",
          "name": "Claude Sonnet 4",
          "contextWindow": 200000,
          "maxTokens": 8192
        }
      ]
    },
    "local-vllm": {
      "name": "Local vLLM",
      "api": "openai-completions",
      "baseUrl": "http://127.0.0.1:8000/v1",
      "authType": "bearer",
      "credential_id": "local-vllm",
      "models": [{ "id": "my-model", "name": "My Model" }]
    },
    "keyless-gateway": {
      "name": "Keyless Gateway",
      "api": "openai-completions",
      "baseUrl": "http://gateway.local/v1",
      "authType": "bearer",
      "credential_id": "keyless-gateway",
      "models": [{ "id": "default", "name": "Default" }]
    }
  }
}
```

对应 `auth.json`（keyless 可省略或放空 key；空白密钥不会发出畸形 `Bearer ` header）：

```json
{
  "openrouter": { "type": "api_key", "key": "sk-or-...", "name": "OpenRouter" },
  "local-vllm": { "type": "api_key", "key": "unused-or-real", "name": "vLLM" },
  "keyless-gateway": { "type": "api_key", "key": "", "name": "Keyless" }
}
```

`settings.json` 里用 `defaultProvider` / `defaultModel` 选中上述 id。Settings UI（`/settings/providers`）写回同一 pi 文件格式。

**映射：** `api: "openai-completions"` → 运行时 `api_type: "openai"` → `Sigma.Ai.Providers.OpenAI`。

---

## 4. 实现 `stream_normalized`（新适配器时）

Behaviour（`Sigma.Ai.Provider`）：

```elixir
@callback stream(params :: map()) :: Enumerable.t()
@callback stream_normalized(request :: ProviderRequest.t()) :: Enumerable.t()
@callback capabilities(model :: map()) :: ProviderCapabilities.t()

@optional_callbacks stream_normalized: 1, capabilities: 1
```

### 4.1 推荐形状（对齐现有 Anthropic / OpenAI）

```elixir
defmodule Sigma.Ai.Providers.Example do
  @behaviour Sigma.Ai.Provider

  alias Sigma.Ai.{ProviderCapabilities, ProviderEvent, ProviderRequest}

  @impl true
  def stream_normalized(%ProviderRequest{} = request) do
    # 解析厂商 SSE → 直接产出 %ProviderEvent{}，或
    # 产出 legacy 元组并由 Provider.stream/2 归一化（现有适配器做法）：
    stream(ProviderRequest.to_legacy(request))
  end

  @impl true
  def capabilities(model) do
    %ProviderCapabilities{
      tools: true,
      thinking: false,
      image_input: false,
      context_window: model[:context_window] || model["contextWindow"],
      max_output_tokens: model[:max_tokens] || model["maxTokens"],
      supported_options: [:max_tokens]
    }
  end

  @impl true
  def stream(params) do
    # 仅在适配器内部：HTTP + SSE 解析 → legacy 元组或 ProviderEvent
    # 协作取消：匹配 options[:cancellation_ref] → {:provider_error, ProviderError.from_reason(:cancelled)}
    ...
  end
end
```

### 4.2 归一化事件生命周期（必须覆盖）

| `%ProviderEvent{type:}` | 含义 |
| --- | --- |
| `:response_started` | 流开始 |
| `:content_text_delta` | 文本增量（`index` + `delta`） |
| `:content_thinking_delta` | 思考增量（若 capabilities.thinking） |
| `:tool_call_started` | 工具调用开始 |
| `:tool_call_arguments_delta` | 参数 JSON 增量（**不可执行**） |
| `:tool_call_completed` | 完整 `{id, name, arguments}` map |
| `:usage_updated` | `%ProviderUsage{}`（不发明缺失字段） |
| `:response_completed` | 终端；`stop_reason` 经 `ProviderStopReason.normalize/1` |
| `:response_failed` | 终端；`error: %ProviderError{}` |

`Provider.stream/2` 的 bridge：**恰好一个**终端事件（completed 或 failed）；无终端 EOF 会合成 `malformed_stream`；终端后 hang/raise 被抑制。

Legacy 元组映射见 `Provider.normalize_legacy_event/1`（`:start`、`:text_delta`、`:toolcall_*`、`:done`、`:provider_error` …）。

### 4.3 Capabilities

- 只声明真实支持的能力；未知 window / max tokens 用 `nil`，不要编造。
- `supported_options` 仅列适配器实际读取的 option atoms（如 `:max_tokens`、`:thinking_budget`）。
- 未实现 `capabilities/1` 时，`Provider.capabilities/2` 提供保守默认（anthropic 推断 thinking）。

### 4.4 错误分类

用 `ProviderError.from_http/2`、`from_reason/1`、`malformed/1`、`from_exception/1`。闭合 kind：

```text
:authentication | :rate_limit | :invalid_request | :context_limit
:timeout | :transport_unavailable | :server_error
:malformed_stream | :cancelled
```

- `rate_limit` / `timeout` / `server_error` / 部分 transport → `retryable: true`
- HTTP 429 可带 `retry_after_ms`
- 消息长度有界（8 KiB）

### 4.5 Cancellation

1. 请求 options 带 `cancellation_ref`（`make_ref()`）。
2. 适配器在 SSE receive 环中匹配 `{:cancel, ^ref}`，取消 HTTP（如 `Req.cancel_async_response/1`），产出 cancelled 错误事件。
3. `Provider.stream/2` bridge 向 producer 转发 cancel；消费者停拉时 kill producer。
4. **不要**因取消而 kill Agent GenServer。

参考测试：`apps/sigma_ai/test/sigma_ai/provider_contract_test.exs`（「cooperatively cancel their live transports」）。

---

## 5. 何时才写 first-class 薄适配器

仅当 **全部** 满足：

1. 线协议与 OpenAI chat completions **且** Anthropic messages 均不兼容（已用真实或录制流量确认）。
2. 差异无法用 base URL / auth header / model id / 网关改写消化。
3. 能用 **fake transport / 录制 SSE fixture** 做确定性测试（禁止 flaky 真网）。
4. 同一 PR **只**加这一个适配器；不改 agent turn loop / LiveView 选型大改。

接线清单（薄）：

1. `apps/sigma_ai/lib/sigma_ai/providers/<name>.ex` — behaviour 实现。
2. `ProtocolSessionOptions.provider_module/1` — 增加 `api_type` 分支。
3. `ConfigManager` — `api` 字符串 ↔ `api_type` 映射（若引入新 api 名）。
4. Settings UI 的 `api_type` 白名单（若需产品可选）。
5. 测试：归一化序列 + fake SSE + cancel + 错误分类（对齐 OpenAI/Anthropic 测试模式）。

Phase 1 默认 **不**新增适配器：OpenAI-compat 配置面已覆盖常见网关。

---

## 6. Fixture / 测试清单（贡献者验收）

对照 `provider_contract_test.exs` 与 `providers/openai_test.exs` / `anthropic_test.exs`：

| # | 场景 | 期望 |
| --- | --- | --- |
| 1 | Text-only completion | `response_started` → text deltas → `usage_updated?` → `response_completed`（`:stop`） |
| 2 | Thinking + text（若支持） | thinking deltas + text；capabilities.thinking == true |
| 3 | 单 / 多 tool call | started → arguments_delta → completed；arguments 为 map |
| 4 | 增量 JSON arguments | deltas 可展示；仅 completed 可执行 |
| 5 | Usage / cache | `ProviderUsage` 字段；缺失则 nil，不捏造 |
| 6 | Context-limit HTTP | `response_failed`，`kind: :context_limit` |
| 7 | Rate limit + Retry-After | `kind: :rate_limit`，`retryable`，可选 `retry_after_ms` |
| 8 | Transport timeout | `kind: :timeout`，retryable |
| 9 | Cooperative cancel | 终端 `kind: :cancelled`；HTTP 已取消 |
| 10 | Malformed / truncated tool args | **无** `tool_call_completed`；终端 `malformed_stream` |
| 11 | Empty stream / missing terminal | bridge 合成 `malformed_stream` |
| 12 | Image 序列化（若 image_input） | 请求 body 含预期 image block；用 capture server 断言 |
| 13 | Blank API key | **不**发送空 Bearer / 空 key header |
| 14 | Equivalent adapters | 同 fixture 语义下 Anthropic 与 OpenAI 归一化 shape 一致（契约测试模式） |

命令：

```bash
mix test apps/sigma_ai/test/sigma_ai/provider_contract_test.exs
mix test apps/sigma_ai/test/sigma_ai/providers/openai_test.exs
mix test apps/sigma_ai/test/sigma_ai/providers/anthropic_test.exs
mix test apps/sigma_ai/test/sigma_ai/provider_auth_test.exs
```

---

## 7. 非目标（本 playbook / Phase 1）

- 同时合并多个新厂商适配器
- 改 Agent turn loop、权限、Protocol 信封
- LiveView provider 选型 UX 大改
- 真网 e2e 作为唯一门禁
- 把 hooks 或 ExtensionRegistry 当成 provider 插件加载器（providers 仍是编译期 OTP 模块；见 ADR 0002）

---

## 8. 参考代码路径

| 路径 | 用途 |
| --- | --- |
| `apps/sigma_ai/lib/sigma_ai/provider.ex` | 公共 seam + legacy 归一化 + cancel bridge |
| `apps/sigma_ai/lib/sigma_ai/providers/openai.ex` | OpenAI-compat 参考实现 |
| `apps/sigma_ai/lib/sigma_ai/providers/anthropic.ex` | Anthropic Messages 参考实现 |
| `apps/sigma_ai/lib/sigma_ai/provider_auth.ex` | Auth header 策略 |
| `apps/sigma_web/lib/sigma_web/protocol_session_options.ex` | `api_type` → 模块 + options 注入 |
| `apps/sigma_session/lib/sigma_session/config_manager.ex` | `models.json` / `auth.json` 读写 |
| `apps/sigma_ai/test/sigma_ai/provider_contract_test.exs` | 归一化契约与 cancel |
| `docs/contracts/contract-stabilization-v2-execution-report.md` §S5 | S5 完成证据 |
