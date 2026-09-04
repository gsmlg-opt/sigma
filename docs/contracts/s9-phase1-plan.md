# S9 Phase 1 — Extension / Feature Expansion 执行计划

- Status: **Active**（S0–S8 已完成；本文件是 S9 第一阶段 work order）
- Date: 2026-09-04
- Depends on: [contract-stabilization-v2-execution-report.md](contract-stabilization-v2-execution-report.md)（Complete）
- Deferred source: [sigma-contract-stabilization-plan-for-codex-v2.md](sigma-contract-stabilization-plan-for-codex-v2.md) §S9
- Related: [../features/tools.md](../features/tools.md)、[../features/hooks/](../features/hooks/)、[protocol-v1.md](protocol-v1.md)

> 供 Codex / Cursor 直接拆 PR 执行。规划为主；Phase 1 仅允许小而可验收的实现切片。

---

## 1. 背景与边界

稳定化里程碑（S0–S8）已交付：session writer、journal ops、permissions、Tool Runtime V2、Provider Normalization V1、active-turn、Protocol V1 / headless、Context Rules V2。

S9 在稳定化计划中刻意延期，涵盖 extension SDK、更多 providers、扩展工具面、worktree pools、background / multi-client、Samgita / Synapsis / Backplane、Distributed BEAM。

**本阶段目标：** 在不破坏 S0–S8 合约的前提下，选出 **1–2 周内可合入** 的最高杠杆切片，建立可重复的 S9 交付节奏。

**本阶段非目标：** 一次铺开全部 S9 列表；不要用大功能 PR 重新打开稳定化边界。

---

## 2. 能力盘点（已有 vs S9 缺口）

### 2.1 已具备（S9 可依赖的底座）

| 能力 | 证据 | 对 S9 的含义 |
| --- | --- | --- |
| Tool Runtime V2 | `sigma_coding`：`ToolMetadata` / `ToolScheduler` / `ToolResult` / `PendingToolRegistry`；execution report S4 | 新工具必须走 metadata + 规范化结果；禁止旁路 dispatcher |
| First-party tool surface | `sigma_tools`：`Ask/Read/Write/Bash/Edit/Search/Find`；`Catalog` + `default_tools/0` | 扩展工具落在 `sigma_tools`，不塞进 `sigma_coding` |
| Session-scoped tool state | `Sigma.Tools.Store`（Agent 拥有的 ETS；hashline snapshots） | `todo` 等协调类工具可复用，无需新持久化原语 |
| Provider contract | `Sigma.Ai.Provider` + Anthropic / OpenAI adapters + normalized events | 新 provider 应实现同一合约，禁止 agent 内特判 |
| Protocol V1 + PublicRuntime | `sigma_protocol`；`Sigma.Agent.PublicRuntime`；stdio + WS `SessionChannel`；多订阅 `ProtocolSubscription` | Synapsis/Samgita **集成入口已存在**；缺产品侧 cookbook / 绑定层 |
| MCP via Backplane | `backplane_mcp_protocol` + `Sigma.Coding.MCP` | Backplane「MCP 客户端」已用；「更深 provider/MCP 产品集成」仍缺 |
| Hooks（command/http） | `sigma_coding/hooks/*`；hooks 文档明确 **不是** Elixir extension API | Extension SDK 与 hooks 正交，勿混为一谈 |
| Git worktree sessions | `NewSessionLive` 创建/选用 worktree；sidecar metadata；session context 注入 | 单会话 worktree **有**；agent pool / 多会话编排 **无** |
| Multi-subscriber streaming | disconnect 不取消 turn；reconnect snapshot（S7） | 「后台会话产品化」部分具备；缺显式 lifecycle / 运营语义 |

### 2.2 S9 列表缺口（代码 + 文档）

| S9 项 | 当前状态 | 缺口摘要 |
| --- | --- | --- |
| BEAM-native Extension SDK | **无**独立 behaviour / 注册表 / 加载器。仅有 `Sigma.Coding.Tool`、hooks command/http | 需 ADR + 分阶段 SDK（tools / commands / providers / context / events / render） |
| 更多 providers | 仅 `Providers.Anthropic`、`Providers.OpenAI` | 缺 first-class 适配器与验证矩阵；OpenAI-compat 网关可部分覆盖但未产品化文档 |
| `job` / `todo` / `task` / LSP / AST / `web_search` / `github` | `todo` **implemented**（Store-backed）；其余 Catalog 仍为 `status: :planned` | `job`/`task`/LSP/AST/`web_search`/`github` 未实现；`eval` 在 PRD 出现但 catalog 未列 |
| Worktree agent pools | 单会话 worktree UI | 无 pool supervisor、无跨 worktree 调度 |
| Background sessions / multi-client | Protocol 多客户端订阅已有 | 无「后台会话」产品契约、无客户端仲裁策略文档化 |
| Samgita / Synapsis 集成 | `PublicRuntime` 可作为直接 Elixir API | 无官方集成包 / 示例 / 契约测试指向外部产品 |
| Backplane 更深集成 | MCP protocol 依赖已在用 | 非 MCP 的 Backplane provider 面未接 |
| Distributed BEAM | 单节点 umbrella | 无 cluster / remote session 设计 |

### 2.3 文档状态注意

| 文档 | 现状 | Phase 1 动作 |
| --- | --- | --- |
| `docs/features/tools.md` | 初版 `sigma_tools` PRD；实现已落地，缺醒目 Status | 标注 **Initial surface shipped** |
| `docs/features/hooks/*` | 设计/实现计划；与 Extension SDK 显式划界 | 保持；Phase 1 不扩 hooks→plugin |
| `docs/archive/oh-my-pi-learning-roadmap-prd.md` | Archived；合约阶段已完成 | 仅交叉引用，不复活为 active roadmap |

---

## 3. 优先级建议（P0 / P1 / P2）

排序原则：**依赖已满足** → **用户可感知价值** → **风险/面积可控** → **不重新打开 S0–S8 合约**。

### P0 — 立刻做（Phase 1 候选核）

| ID | 项 | 理由 |
| --- | --- | --- |
| P0-A | S9 执行节奏与文档 Status 对齐 | 低成本；避免后续 agent 重复盘点或误把 S9 当稳定化未完成 |
| P0-B | `todo` 工具（session-scoped） | 高用户价值；可复用 `Sigma.Tools.Store`；无外部网络；符合 Tool Runtime V2；不依赖 subagent |
| P0-C | Extension SDK **ADR + 最小注册缝**（设计优先） | 解锁后续全部扩展路径；但 **完整 SDK 过大**，Phase 1 只定边界与可选 thin façade |
| P0-D | Provider 扩展 **playbook**（+ 可选 1 个薄适配器） | S5 已就绪；多数「新模型」可先走 OpenAI-compat；避免同时开多个 first-class 适配器 |

### P1 — 下一波（Phase 2，约 2–4 周）

| ID | 项 | 依赖 | 理由 |
| --- | --- | --- | --- |
| P1-A | `job`（bash 异步 / list / poll / cancel） | Tool Runtime V2；bash 输出截断策略 | 长任务刚需；比 LSP 简单，但有进程生命周期风险 |
| P1-B | `web_search`（可配置 provider） | credentials / settings | 研究向价值高；需密钥与失败闭合 |
| P1-C | Extension SDK MVP：tool + context source 注册 | P0-C ADR | 允许外部 OTP app 注册，不含热加载/远程代码 |
| P1-D | Synapsis / Samgita **集成 cookbook + 契约测试夹具** | PublicRuntime / Protocol V1 | 产品集成，不 fork 其运行时 |
| P1-E | Background session 产品语义 | ProtocolSubscription | 明确「无 UI 附着时的会话生命周期」与取消策略 |

### P2 — 有意延后

| ID | 项 | 延后理由 |
| --- | --- | --- |
| P2-A | `task` / subagents | 需要 agent 嵌套、权限、journal 归属；面积大 |
| P2-B | LSP / `ast_grep` / `ast_edit` | 外部进程、语言生态、结果规范化成本高 |
| P2-C | `github` 工具 | OAuth/token、API 面、权限策略 |
| P2-D | Worktree agent pools | 多会话编排 + 资源隔离；先稳单会话 |
| P2-E | Backplane 非 MCP 深度集成 | 需产品边界澄清 |
| P2-F | Distributed BEAM | 运维与一致性远超 Phase 1；单节点先吃满 |

---

## 4. Phase 1 Work Orders（1–2 周）

**总目标：** 交付「可扩展的工具面第一步 + 扩展边界写清 + provider 扩展路径可用」，并保持 green CI。

**总非目标：** 见 §5。

### WO-1 — 文档与索引（本 PR）

| | |
| --- | --- |
| **目标** | 建立 S9 Phase 1 权威 work order；索引可发现；`tools.md` Status 反映已落地 |
| **非目标** | 改运行时行为 |
| **Apps** | 无（仅 `docs/`） |
| **验收** | `docs/README.md` 链到本文件；`tools.md` 有 Status；本文件结构可供后续 PR 引用 |
| **PR** | `docs: add S9 phase-1 execution plan`（本提交） |

### WO-2 — `todo` 工具 MVP ✅

| | |
| --- | --- |
| **目标** | 实现 oh-my-pi 风格 session-scoped todo：创建/更新/列表/完成/清除；写入 `Sigma.Tools.Store`；晋升 Catalog `:implemented`；加入 `default_tools/0` |
| **非目标** | 跨 session 持久化到 JSONL；UI 专用面板；与 `task`/subagent 联动；磁盘 sidecar |
| **Apps** | `sigma_tools`（主）；必要时 `sigma_agent` 仅确认 `tool_state` 注入已存在；`sigma_web` 不强制新 UI |
| **建议元数据** | `effect: :write`（或协调类等价）、`concurrency: :sequential`、可中断 |
| **验收** | |
| | 1. `Sigma.Tools.Todo` 实现 `Sigma.Coding.Tool` callbacks |
| | 2. Catalog 中 `todo` 为 `:implemented`；`default_tools()` 包含它 |
| | 3. 单元测试：增删改查、非法 id、空列表、与 Store 同寿命 |
| | 4. 计划中工具仍不暴露；`mix test` 相关 app 绿 |
| **PR 拆分** | 单 PR：`feat(tools): add session-scoped todo tool` |
| **Status** | **Done** — `Sigma.Tools.Todo` + Store `get/put_todo_state`；schema `add\|update\|complete\|remove\|list\|clear` |

**Schema 建议（可微调，保持窄）：**

```text
action: add | update | complete | remove | list | clear
id?: string
content?: string
status?: pending | in_progress | completed
```

### WO-3 — Extension SDK ADR（设计）+ 可选 thin 注册 façade

| | |
| --- | --- |
| **目标** | 写下 `docs/adr/0002-beam-extension-sdk.md`（或下一序号）：扩展点清单、与 hooks 边界、加载模型（编译期/应用启动注册，**禁止**运行时任意代码加载）、错误与权限、与 Protocol/Tool Runtime 关系 |
| **可选代码（若仍很小）** | `Sigma.Extension` 或 `Sigma.Coding.ExtensionRegistry`：仅 `register_tool/1` + `list_tools/0` 内存表；默认仍走 `Sigma.Tools.default_tools/0` |
| **非目标** | 热插拔、远程下载扩展、JS/TS 插件兼容层、render hints 完整实现、commands/providers/context 全套回调 |
| **Apps** | 文档：`docs/adr/`；可选代码：`sigma_coding` 或新建极薄模块（优先不新建 umbrella app） |
| **验收** | ADR Accepted；明确 Phase 2 MVP 范围；若有 registry，有单元测试且默认路径行为不变 |
| **PR 拆分** | PR-A：`docs(adr): define BEAM extension SDK boundary`；PR-B（可选）：`feat(coding): add extension tool registry façade` |

### WO-4 — Provider 扩展路径

| | |
| --- | --- |
| **目标** | 写清「如何在 Normalized Provider 合约上增加适配器 / 使用 OpenAI-compat 网关」；验证现有 OpenAI adapter 对常见 compat 端点的配置面（base URL、auth header、model id） |
| **可选实现** | **至多一个** first-class 薄适配器（仅当与 OpenAI-compat 差异已确认且测试可假 provider 覆盖）；否则只做文档 + settings 示例 |
| **非目标** | 同时新增多个厂商；改 agent turn loop；改 LiveView 选型 UX 大改 |
| **Apps** | `sigma_ai`（若写适配器）；文档可放 `docs/features/providers.md` 或 ADR 附录 |
| **验收** | 贡献者按文档能接 compat 端点；若有新适配器：归一化事件测试 + fake transport 绿 |
| **PR 拆分** | PR-A：`docs: provider extension playbook`；PR-B（可选）：`feat(ai): add <provider> adapter` |

### WO-5 — PublicRuntime 集成笔记（轻量）

| | |
| --- | --- |
| **目标** | 在本文件或短文 `docs/contracts/public-runtime-integration.md` 列出 Synapsis/Samgita 应调用的命令子集、订阅语义、审批 `approval_required`、禁止直接碰 GenServer |
| **非目标** | 发布 Hex 包、实现对方仓库代码、多集群 |
| **验收** | 外部集成者只读该文档即可写出最小 prompt→stream→cancel 客户端草图 |
| **PR** | 可与 WO-3 合并，或独立小 PR |

### Phase 1 建议时间盒

```text
Week 1:  WO-1 (done) → WO-2 todo → WO-3 ADR
Week 2:  WO-4 playbook (+ optional thin provider) → WO-5 notes → buffer / bugfix
```

并行约束：勿同时改 `session_process.ex` / `session_live.ex` 做无关重构；新工具优先自包含在 `sigma_tools`。

---

## 5. Phase 1 明确不要做

- LSP / AST grep / AST edit / `github` / `eval` / browser
- `task` subagents、advisor、memory consolidation、DAP
- Worktree **agent pools**、跨会话编排
- Distributed BEAM / multi-node session
- Samgita / Synapsis **产品内嵌**或反向依赖其 OTP 树
- Backplane 超出当前 MCP 客户端的大规模接入
- 完整 Extension SDK（热加载、多扩展点一次做完）
- 用数据库替换 JSONL；改 DuskMoon 组件体系
- 把 hooks 改造成 Elixir plugin 框架（hooks 文档 N1 已排除）
- 「顺手」扩大 Tool Runtime / Provider / Protocol 合约（除非 bugfix 且有回归测试）

---

## 6. 依赖图（Phase 1 视窗）

```text
S0–S8 (done)
    │
    ▼
WO-1 docs ─────────────────────────────────────┐
    │                                            │
    ├──────────────► WO-2 todo ──────────────────┤
    │                                            │
    ├──────────────► WO-3 Extension ADR (± registry)
    │                      │                     │
    │                      ▼                     │
    │               (P1) Extension MVP           │
    │                                            │
    ├──────────────► WO-4 provider playbook (±1 adapter)
    │                                            │
    └──────────────► WO-5 PublicRuntime notes ───┘
                         │
                         ▼
              Phase 2: job, web_search, SDK MVP, integrations
```

---

## 7. 风险与缓解

| 风险 | 缓解 |
| --- | --- |
| Extension ADR 争论过久挤掉 todo | ADR 限 1–2 页；争议点列入 Open Questions，不阻塞 WO-2 |
| `todo` 被做成持久 journal 条目 | 明确 Store-only；会话结束即消失；文档写清 |
| Provider 适配器引入真实网络 flaky 测试 | 强制 fake transport / fixture SSE |
| Catalog 引用未实现模块原子 | 保持 `:planned` 不 `default_tools`；实现前不要 `Code.ensure_loaded` |
| 范围膨胀到 job/LSP | PR 模板引用本文件 §5；reviewer 拒绝越界 |

---

## 8. 后续 Phase 预告（非本阶段承诺）

1. **Phase 2：** `job` + `web_search` + Extension MVP（tool/context register）+ PublicRuntime 外部契约测试  
2. **Phase 3：** `task` 设计专项 或 LSP 二选一（先 ADR）  
3. **Phase 4+：** worktree pools、background session 产品化、分布式评估  

每完成一波更新本文件 Status 或拆出 `s9-phase2-plan.md`，并在 [contract-stabilization-v2-execution-report.md](contract-stabilization-v2-execution-report.md) 的 remaining work 处交叉链接。

---

## 9. Codex / Cursor 执行清单（可复制）

```text
[x] WO-2: implement Sigma.Tools.Todo + tests + catalog/default_tools
[ ] WO-3: ADR 0002 BEAM extension SDK boundary (+ optional registry)
[ ] WO-4: provider extension playbook (+ optional single adapter)
[ ] WO-5: PublicRuntime integration notes for Synapsis/Samgita
[ ] Do NOT start: LSP, AST, task, github, worktree pools, distributed BEAM
[ ] Keep: allow-all permission default; Tool Runtime V2 metadata; Protocol V1 envelopes
[ ] Verify: mix format --check-formatted && mix compile --warnings-as-errors && mix test
```
