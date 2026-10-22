# Legacy Tools Retirement Implementation Plan

> **For agentic workers:** Execute the independent file groups in parallel, then integrate and review the complete diff. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 退役全部 Sigma 旧内置工具，保留聊天、MCP、原生协作及现有宿主能力，为下一阶段 Codex 接入建立空内置目录基线。

**Architecture:** 删除工具实现与默认注册；共享 MCP 调度、权限、hooks 和 Session 资源保持原有责任。工具专项测试删除，通用运行时覆盖改用测试内夹具，不新增生产工具。

**Tech Stack:** Elixir umbrella、Phoenix LiveView、Backplane Agent Runtime 1.10.28、现有 MCP/skills/JSONL。

## Task 1: 冻结验收与测试夹具

**Files:** `apps/sigma_agent/test/sigma_agent/{backplane_tool_catalog,backplane_engine,backplane_public_runtime,backplane_child_io,subagent_host}_test.exs`；`apps/sigma_coding/test/sigma_coding/{integration,tool_runtime}_test.exs`；`apps/sigma_web/test/sigma_web/live/subagent_status_test.exs`；新增必要的退役回归测试。

- [x] 验证当前 scoped baseline；记录真实命令和结果。
- [x] 为 Web/协议默认目录不再暴露旧工具、空目录聊天及旧工具拒绝建立失败断言。
- [x] 将通用执行、enum 准入、权限、取消、隔离测试中的旧工具依赖改为测试内的最小工具；保留原有断言。

## Task 2: 删除旧工具实现

**Files:** 删除 `apps/sigma_tools/`、`apps/sigma_coding/lib/sigma_coding/tools/`、对应 `apps/sigma_coding/test/sigma_coding/tools/`；修改 Coding application 和旧注册/元数据专项测试。

- [x] 删除上述 tracked 文件；保留用户本地构建产物，仅清理本 worktree 新生成的旧应用缓存。
- [x] 删除未被会话使用的 `ExtensionRegistry` 和监督项，保留 MCP 仍使用的共享执行层。
- [x] 清除旧内置名称专用的元数据逻辑；通用工具仍通过显式 metadata 和保守默认值获得安全属性。

## Task 3: 更新运行时入口和宿主边界

**Files:** `apps/sigma_agent/lib/sigma_agent/backplane/child_io.ex`、`apps/sigma_agent/lib/sigma_agent/session_context.ex`；`apps/sigma_web/lib/sigma_web/{protocol_session_options,live/session_live,live/settings_live,live/project_skills_live,controllers/skills_controller}.ex`；`apps/sigma_web/mix.exs`。

- [x] 两个生产入口使用空内置目录，不再调用已删除的 `Sigma.Tools.default_tools/0`。
- [x] 删除 child 的旧 QuestionTool 包装，保留通用交互宿主回调与 MCP 调度。
- [x] 保留原生协作目录及 writerless/disabled 的空目录语义。
- [x] 移除技能上下文对 `read`/`activate_skill` 的要求，继续支持显式技能展开及只读资源。
- [x] 技能 API 禁用模型激活广告，设置页面显示当前手动调用能力；保留原模型调用策略配置。

## Task 4: 文档、脚本和验证

**Files:** `README.md`、`AGENTS.md`、文档索引、`docs/features/tools.md`、`docs/contracts/{skills-v1,build-api-session-context}.md`、`docs/adr/0002-beam-extension-sdk.md`、相关历史计划的状态说明、`scripts/verify-skills-local-smoke.exs`。

- [x] 更新当前架构描述与旧 SDK 退役状态，保留历史设计原文与来源。
- [x] 技能 smoke 改验保留的手动调用/资源路径。
- [x] 运行 `mix compile --warnings-as-errors`、修改文件的 `mix format --check-formatted`。
- [x] 串行运行受影响 Coding、Agent、Web/协议、Session skills/history 测试；不修改范围外失败。
- [x] 审查所有删除和引用；检查旧模块没有通过测试夹具混入生产目录。

所有 Mix/Devenv 命令由协调者串行执行；并行 worker 不运行构建、不提交、不改 `deps/`。初始退役实施阶段不提交、推送、发布或重启服务；后续 Git 交付遵循用户单独的合并请求。

## 验证记录（2026-10-23）

- 实施前的 scoped baseline：ToolCatalog、PublicRuntime、Dispatcher 共 17 tests，0 failures。
- 退役回归先观察到 `opts[:tools] == []` 失败，旧入口当时仍返回九个内置工具；完成接线后通过。
- 最终同一次受影响范围运行（seed 467997）共 **924 tests，0 failures**：

| 范围 | 结果 |
| --- | --- |
| `apps/sigma_coding/test`，含 MCP、hooks、权限、调度和 native terminal helper | 234 tests，0 failures |
| `apps/sigma_agent/test`，含空目录、旧调用拒绝、原生协作、隔离、取消和持久化 | 362 tests，0 failures |
| Session skills、手动调用及相关历史/JSONL 范围（下列文件） | 211 tests，0 failures |
| Web/协议默认目录、聊天、审批、子代理及技能配置（下列文件） | 117 tests，0 failures |

执行的完整测试范围：

```sh
mix test \
  apps/sigma_coding/test \
  apps/sigma_agent/test \
  apps/sigma_web/test/sigma_web/protocol_session_options_test.exs \
  apps/sigma_web/test/sigma_web/skills_controller_test.exs \
  apps/sigma_web/test/sigma_web/live/session_live_test.exs \
  apps/sigma_web/test/sigma_web/live/subagent_status_test.exs \
  apps/sigma_web/test/sigma_web/live/project_skills_live_test.exs \
  apps/sigma_web/test/sigma_web/live/settings_live_test.exs \
  apps/sigma_session/test/sigma_session/skills_test.exs \
  apps/sigma_session/test/sigma_session/skills_remote_source_test.exs \
  apps/sigma_session/test/sigma_session/skills_remote_adapter_test.exs \
  apps/sigma_session/test/sigma_session/skills_protocol_test.exs \
  apps/sigma_session/test/sigma_session/skills_preparer_test.exs \
  apps/sigma_session/test/sigma_session/skills_facade_test.exs \
  apps/sigma_session/test/sigma_session/skill_invocation_store_test.exs \
  apps/sigma_session/test/sigma_session/slash_commands_test.exs \
  apps/sigma_session/test/sigma_session/log_test.exs \
  apps/sigma_session/test/sigma_session/journal_test.exs \
  apps/sigma_session/test/sigma_session/journal/index_test.exs \
  apps/sigma_session/test/sigma_session/entry_decoder_test.exs \
  apps/sigma_session/test/sigma_session/entry_encoder_test.exs \
  apps/sigma_session/test/sigma_session/session_files_test.exs \
  apps/sigma_session/test/sigma_session/subagent_journal_test.exs \
  apps/sigma_session/test/sigma_session/subagent_admission_journal_test.exs \
  apps/sigma_session/test/sigma_session/context_compaction_replay_test.exs \
  apps/sigma_session/test/sigma_session/writer_test.exs
```

其他检查均通过：

- `MIX_ENV=test mix compile --warnings-as-errors`。
- 不含测试夹具的 `mix compile --force --warnings-as-errors`。
- 29 个修改/新增 Elixir 文件的 `mix format --check-formatted`。
- `mix run --no-start scripts/verify-skills-local-smoke.exs` 输出 `skills local smoke: passed`，验证手动展开、资源 digest/释放及 invocation recovery。
- `git diff --check`；生产代码、配置、脚本、工作流与 Mix 文件中没有已退役模块或默认注册调用的有效引用。
- 两次独立交叉审查，修正技能页面可用性及 context contract 后无剩余可行动问题。

新 worktree 首次验证需按现有 CI 执行 `scripts/build-terminal-helper.sh debug`；旧应用缓存仅从本 worktree 的 `_build/test/lib/sigma_tools` 移出。开发编译前以 `mix npm.install --frozen`、`mix duskmoon.bundle` 生成所需资源；依赖清单及锁文件无变更。

退役验收在基线 `291ec117` 的 `codex/retire-legacy-tools` 工作区完成；验收时变更尚未提交、合并，原 main 保持干净，未切换现有 4580 服务。本记录只代表本地测试与构建，不代表已发布、部署或完成 Codex 工具兼容。

2026-10-23，用户随后调用 `cmd-worktree-merge`，授权将该已验证工作区提交、合入当前 main 并清理工作区和分支。

Agent Note（project=sigma）：`09fc1d22-6236-4265-867e-84c680c62320`，记录退役边界及实现来源，随合并交付同步代码状态。
