# 共享 Provider、模型配置与服务引用设计

**状态：** 按 2026-10-19 用户补充修订的文字设计，用户 LGTM 已批准，进入实施。

**代码基线：** Sigma `main @ 898ce173950d555da9e31a73c2dba3ef6917385e`。

**用户已明确：** provider 独立；模型配置选择 provider，管理可用模型；默认 context 指新会话的默认上下文预算，可在会话内调整；会话只允许选择模型配置中的模型；MCP 可选择 provider 并覆盖 URL；Skills 可选择 Backplane provider 使用其远程技能。

## 1. 资源边界与实施范围

Provider 成为共享连接资源，负责地址、服务类型和凭据引用。Models、MCP、Skills 各自管理自己的配置，通过 provider ID 使用连接；provider 不再承担“当前模型”或“默认模型”的职责。

| 设置入口 | 职责 |
| --- | --- |
| `/settings/providers` | 独立管理连接、地址、服务类型、认证及凭据引用 |
| `/settings/models` | 选择 provider，发现/手动加入模型，编辑模型默认上下文预算，设置全局默认模型 |
| `/settings/mcp` | 选择 provider 的 MCP 服务，或继续独立配置；允许覆盖 MCP URL |
| `/settings/skills` | 本地技能管理，以及选择 Backplane provider 配置远程来源、浏览并使用远程技能 |

会话模型选择器只消费 Models 管理的条目。连接可暂时不提供模型；MCP-only 或 Skills-only 连接不要求有默认模型。

这次工作分为三个有依赖的交付阶段：共享 Provider + Models + 会话模型修复；MCP provider 引用；Skills provider 引用。三个阶段共同构成本次范围。

不重写 MCP transport、Skill Protocol 客户端、技能缓存、agent 执行器或 journal。复用现有机制，不增加后台全量发现、自动启用全部模型或新的推理协议。

## 2. 当前源码事实

### 2.1 模型列表混乱的具体入口

- 设置页只有单个 `model` 输入；实际会话选项来自 `models.json.providers[id].models`。
- `ConfigManager.get_config` 会接受不在集合内的 `settings.defaultModel`；`provider_models/1` 在保存时把该当前模型重新补入集合。
- `SessionLive.ensure_model_option/3` 把不在配置集合中的当前运行模型加回下拉。
- `SessionLive.select_model` 没有验证 model membership，并通过更新 provider 的当前模型将伪造/过期 ID 补入配置，随后还会修改全局默认 provider。
- 会话恢复时，缺失原模型会静默回退全局默认；协议启动路径也缺少同等的 membership 检查。
- NewSession 只在加载时生成模型选项，创建提交时需要重新读取配置，覆盖另一页刚移除模型的情况。

主要源码：`apps/sigma_session/lib/sigma_session/config_manager.ex:29,436`；`apps/sigma_web/lib/sigma_web/live/session_live.ex:1636,2763,4359`；`apps/sigma_web/lib/sigma_web/live/new_session_live.ex:405,600`；`apps/sigma_web/lib/sigma_web/protocol_session_options.ex:46`。

### 2.2 上下文预算

模型 `contextWindow` 是能力上限，会话 metadata 的 `context_limit` 是会话预算。现有有效窗口已使用二者较小值。当前预算 parser 却只接受五个固定值，默认 256000；128000、131072 等值会被拒绝。协议启动还没有接入与 Web 相同的预算解析。

### 2.3 已有远程服务基础

- MCP 已支持 HTTP、独立 URL、认证头和 credential 引用；`ConfigManager.mcp_servers_for/1` 在运行前解析凭据，适合增加 provider 引用解析。
- `settings.json.skillSources` 已支持 Backplane 来源，`RemoteAdapter -> RemoteSource -> Backplane.SkillProtocol` 已有目录、准备、校验、缓存和精确离线复用。当前 UI 主要只读显示来源，缺少 provider 选择和配置入口。
- 当前安装的 `backplane_skill_protocol 1.10.16` 使用 `/skill-protocol/v1/catalog`、`/resolve`、`/artifact`；endpoint 只接受 HTTP origin，协议路径由客户端追加。不能把旧 `/skills` API 接进去。
- Backplane MCP 地址为 `<service origin>/mcp`。LLM 的 `/v1` 地址、MCP 完整地址及 Skills 的 service origin 是不同配置语义，不能互相猜测替换。

主要源码：`apps/sigma_session/lib/sigma_session/config_manager.ex:345,525,621`；`apps/sigma_session/lib/sigma_session/skills/{remote_adapter,remote_source}.ex`；`apps/sigma_coding/lib/sigma_coding/mcp.ex:313`；已安装 Skill Protocol 的 `client.ex:85,103,137,314,488`；Backplane checkout 的 `apps/backplane_api/lib/backplane/api/router.ex`。

## 3. 方案选择与兼容存储

| 方案 | 收益 | 代价 |
| --- | --- | --- |
| 领域 API/UI 独立，保留 pi 文件布局作为存储适配 | 可以共享 provider 引用；不引入双写或破坏现有用户配置 | 必须明确模型集合只能由 Models 操作修改，推荐 |
| 新增 providers.json 并迁移全部连接 | 物理文件也完全拆开 | 需要迁移版本、pi 导入/导出和兼容策略，当前收益有限 |
| MCP/Skills 复制 provider 地址与密钥 | 表单接线容易 | 连接修改后多份配置失去一致性，不采用 |

推荐第一种：**独立的是资源和配置入口；继续保留 pi 兼容的磁盘布局，不维护两份权威数据。**

- 共享连接仍持久化在 `models.json.providers[id]` 的连接字段；补充明确的服务类型及 Backplane `serviceOrigin`。已有 `api` / `baseUrl` 保留其 LLM 语义。
- 模型条目仍由 `providers[id].models[]` 存储，但通过独立 Models API 读写；领域内身份是 `(provider_id, model_id)`。物理嵌套不再意味着 provider 表单可以隐式新增模型。
- descriptor 新增 `defaultContextLimit`，与既有 `contextWindow` / `maxTokens` 分开；保留未知元数据。
- `settings.defaultProvider/defaultModel` 只保存全局默认模型 pair。不再用集合排序或 provider 当前模型表达独立配置状态。
- MCP 配置增加 `providerId` 和可选 `urlOverride`；没有 provider 引用时沿用原有独立配置。
- `skillSources` 增加 `providerId`；已有独立 `baseUrl/credentialId/accessContextId` 来源仍可读取。
- provider-backed 配置只保存引用和明确覆盖项，不复制实际密钥或派生地址。读取当前 provider 后，再构造具体客户端需要的配置。
- 旧字符串/对象模型继续兼容。首次读取不写盘；过期 defaultModel 或历史记录不迁移成新的模型条目。

## 4. Provider 独立配置

- 列表显示名称、类型和已配置服务；详情编辑连接及凭据引用，不出现模型列表、当前模型或激活 provider 按钮。
- Backplane 类型明确填写 service origin，例如 `https://backplane.example`；LLM endpoint 保留独立配置。表单显示由服务约定得到的 MCP 地址和 Skills 协议预览。
- 已有只有 LLM Base URL 的 provider 不猜测其 service origin。用户补全 Backplane 类型/origin 后才能供 MCP/Skills 选择。
- 能力依据明确的类型/端点配置，不根据显示名称恰好叫 backplane 判断，也不把配置完成显示为远端健康检查成功。
- 各配置入口引用已保存连接；任何资源都不能因为 provider 没有模型而无法使用 MCP/Skills。
- 删除被 Models/MCP/Skills 引用的 provider 时显示引用并拒绝直接删除，用户先处理引用。外部编辑产生悬空引用时标记不可用，不自动绑定另一个 provider。

## 5. Models 配置与上下文预算

### 5.1 模型管理 UI

- 新增独立 Models 导航与页面，以 provider 筛选、模型列表及模型详情呈现。新增条目必须先选择 provider。
- 选择 provider 后可以发现候选或手动添加 ID/显示名。发现列表支持搜索、多选及已加入标记；仅“添加所选”会写入模型配置。
- 每个已加入模型可编辑显示名与默认上下文预算；详情同时显示已知模型窗口上限，明确区分两个字段。
- 默认预算为正整数 token 数，可输入 128000、131072 等自定义值；留空表示新会话沿用系统默认。显示名留空时使用 ID。
- 模型列表提供设置全局默认和移除操作。移除全局默认模型时说明将清除默认选择，确认后清除，不自动换另一个模型。
- provider 内按完整 model ID 去重，保留大小写与内部字符，清理输入首尾空白；不同 provider 的相同 ID 是不同模型。
- 没有模型的 provider 显示“尚未配置模型”；发现失败不修改已有模型，仍可手动添加。

### 5.2 发现请求

HTTP discovery 放在 `Sigma.Ai` 的小型无状态模块中，使用现有 Req 与认证 helper。OpenAI Responses/Chat Completions 使用已配置 LLM Base URL 的 `/models`；Anthropic 沿用其基址约定请求 `/v1/models`，带版本头并处理分页。

请求有有限超时及重复游标保护。合法空列表、无搜索结果、不支持发现、认证失败、网络失败和响应无效分开反馈。候选只包含明确且有效的 ID/名称/已有模型元数据，不从名称猜测窗口、默认预算或能力。

候选、搜索和勾选只保存在 LiveView。请求绑定 provider ID 和保存的连接版本；切换、修改连接、删除或重试后不应用旧结果。加入时从最新配置合并，避免覆盖随后变更；重复发现不覆盖用户已有元数据。

### 5.3 默认预算规则

用户已确认默认 context 是新会话预算，不是模型窗口上限：

1. 新会话使用显式会话预算，否则取所选模型 `defaultContextLimit`，再否则使用当前系统默认 256000。
2. 创建时将解析后的预算写入会话 `meta.context_limit`，之后修改模型默认值不改变该会话。
3. 既有会话的有效持久化预算优先；缺少预算的 legacy 会话继续使用原有 256000，避免模型默认值改动意外改变历史会话。
4. 会话内允许调整预算；切换模型保留会话预算，有效窗口继续按预算与已知模型上限的较小值计算。
5. Web 和 headless/protocol 新会话入口消费同一预算 resolver。parser 接受任意严格正整数，拒绝 0、负数、浮点和带尾缀字符串；保留既有五档快捷值并支持当前自定义值。

## 6. 会话模型选择器修复

模型配置是唯一权威集合，统一提供配置模型列表、按 pair 查找和选择解析，供设置、新会话、SessionLive、协议启动共用。

- 删除 `ensure_model_option` 对未配置当前模型的补回；历史记录只用于显示原选择，不增加下拉候选。
- 不允许通过 `provider.model`、`settings.defaultModel`、session metadata、journal 或浏览器提交把模型补入配置。
- 会话切换事件按最新配置验证 provider/model pair，失败无 config/journal/runtime 副作用。选择成功只修改本会话 journal 与运行模型，不顺带修改全局默认模型。
- 创建提交在创建 worktree/session 文件之前重新验证模型；不能信任页面加载时的选项快照。空集合提供 Models 设置入口。
- 模型配置变更后已打开页面更新候选；即使页面尚未更新，服务器也拒绝过期选择。
- 已移除的当前模型在选择器之外标记为不可用，不能作为可选项重新出现，不静默改为全局默认。
- 设置变更不主动中断已经运行的一轮；当前模型被移除后，下一次提交提示先选择仍在配置中的模型，不能继续通过旧选择发起请求。显式保存但已移除的历史模型在恢复时明确报不可用，并提供恢复原配置的 Models 入口。
- 本次不新增 agent 启动前另选模型并改写 journal 的恢复子系统。保留现有 journal 所有权和先持久化再切换的顺序。

## 7. MCP 选择 Provider

- HTTP MCP 表单增加“独立配置 / 已保存 Provider”的来源选择。
- 选择 Backplane 后显示继承的 `<service origin>/mcp` 和 credential 名称；默认只需选 provider，不重复填写 URL/key。
- “覆盖 URL”是 MCP 配置自己的可选字段；启用后输入完整地址，仅覆盖该 MCP server，不修改 provider 或 Models/Skills。
- 优先级为 MCP URL override > provider MCP endpoint。认证仍按 provider 的凭据引用与该服务的适配方式解析。
- 独立 HTTP 和 stdio 配置保持可用。provider 引用失效时明确拒绝，不悄悄切回复制的旧 URL 或其他 provider。
- `mcp_servers_for/1` 完成 provider/credential 解析后，继续交给现有 MCP 客户端。repository/session 仍通过原 server ID 选择 MCP。
- 修改 provider 影响随后解析/建立的连接；本次不自动中断正在执行的 MCP 调用或新增热重连框架。

## 8. Skills 选择 Backplane Provider

- Skills 页 Remote sources 增加添加/编辑来源入口，选择 Backplane provider、来源名和 enabled/offline。
- provider 选择后读取 service origin 与 credential 引用，显示只读协议预览；不要求用户填写 `/skills` 或 `/skill-protocol/v1`。
- 当前 Skill Protocol client 只接受 HTTP origin；本次仅 MCP 支持任意完整 URL override，不扩展 Skills 的路径前缀能力。
- 远程来源保留稳定 source ID；修改显示名不改变技能引用或缓存身份。service origin、凭据或 access context 改变时使原访问绑定失效，需重新建立对应来源，不能离线复用另一个访问范围的内容。
- 用户显式浏览来源后异步请求现有 `Facade.remote_catalog`，提供搜索/分页与来源状态；不在设置页加载时批量请求所有远端。
- 远程技能继续通过当前明确的 `source_id:skill_id` 引用进入现有准备/调用链路；不把远程目录自动混成本地自动执行目录。
- 使用现有 RemoteSource 做版本/摘要校验、只读缓存和 exact offline 复用；本次不增加上传、发布或远程执行代理。
- Backplane Skills 使用现有客户端的 Bearer 认证；MCP 依服务使用其认证头，不同时发送相互冲突的 Bearer/x-api-key。共享凭据引用不复制密钥，401/403 保留具体服务的错误反馈。

## 9. 实施分解与验证

### 阶段一：共享 Provider、Models 和会话修复

- 独立连接/模型领域 API，保留 pi 存储适配；模型变更通知与最新 membership 验证。
- 连接和模型页 UI；发现与手动添加；模型默认预算；默认模型 pair。
- 修复保存补回、历史补回、伪造/过期选择、全局默认副作用和两种会话启动路径。
- 验证文件：`config_manager_test.exs`、新增 discovery 测试、`context_policy_test.exs`、`settings_live_test.exs`、`new_session_live_test.exs`、会话模型/预算相关 `session_live_test.exs`，以及 scoped `ProtocolSessionOptions` 测试。

### 阶段二：MCP Provider 引用

- 复用阶段一连接 resolver；配置来源选择、继承预览和 URL override；保持独立配置。
- 验证 provider 修改后解析到新值、override 优先、悬空引用拒绝、credential 不落盘及 HTTP/stdio 兼容。
- 测试集中在 ConfigManager/MCP settings；只在实际改动 transport 接缝时运行相应 MCP 用例。

### 阶段三：Skills Provider 引用

- 复用阶段一连接 resolver；来源 CRUD、显式目录浏览和既有调用接线。
- 验证 provider-backed 与 legacy 独立来源并存、source 身份稳定、origin/context 变化不复用旧 binding、无密钥 DOM、远程目录与本地目录隔离。
- 验证文件：`skills_remote_adapter_test.exs`、`skills_controller_test.exs`、Settings Skills 测试；修改 binding 接线时增加相应 source/cache 用例，复用已有完整性及离线回归。

阶段二、三依赖阶段一的 provider resolver，可并行实施。每个阶段独立验收，最终覆盖以下用户路径：

1. 只配置一个 Backplane provider，在 Models 发现/手动加入模型并设置默认预算；新会话预算正确且可调整。
2. 未加入候选不出现；移除模型后多个已打开会话不再将其列为候选；伪造切换不能把它补回。
3. 选择 Backplane MCP 无需重复填写连接；覆盖 URL 只影响该 MCP。
4. Skills 选择同一 Backplane provider 能浏览和使用远程技能；沿用版本校验与缓存。
5. provider 连接保存不修改模型集合，模型操作不重置 MCP/Skills，凭据不被复制到引用配置或 DOM。

只运行相关 scoped 测试与修改文件的格式检查；范围外失败记录并停止扩大修复。浏览器覆盖桌面/窄屏、亮色/暗色、键盘操作及 loading/error 状态，并核对实际加载的构建。

此前只读核对的 4580 页面为 `0.3.7-dev @ da119933`，落后于当前 checkout；不能用旧页面证明实施生效。实现验收使用隔离配置/服务，不改变用户真实 provider、MCP 或 Skills 配置。

用户于 2026-10-19 回复 LGTM，批准本设计。实施计划见 ../plans/2026-10-19-provider-model-management.md。
