# Sigma 文档索引

本目录按用途分类。优先阅读 **contracts/** 与 **adr/**；实施过程中的旧计划在 **archive/**。

## 导航

| 目录 | 用途 |
| --- | --- |
| [adr/](adr/) | 已接受的架构决策记录 |
| [contracts/](contracts/) | 当前有效的协议、合约、PRD 与稳定化报告 |
| [features/](features/) | 功能域设计与实现计划（hooks、tools） |
| [agents/](agents/) | Agent/技能协作约定（领域、issue、triage） |
| [archive/](archive/) | 已完成或被取代的历史计划与规格 |

## 权威合约（contracts/）

| 文档 | 说明 |
| --- | --- |
| [protocol-v1.md](contracts/protocol-v1.md) | Protocol V1：命令/事件信封与适配器边界 |
| [context-rules-v2.md](contracts/context-rules-v2.md) | Context Rules V2：AGENTS/CLAUDE 装配与指令 |
| [build-api-session-context.md](contracts/build-api-session-context.md) | 会话上下文如何组装并送入 provider |
| [session-journal-and-operations-v2-prd.md](contracts/session-journal-and-operations-v2-prd.md) | Session journal / 会话操作 V2 PRD |
| [contract-stabilization-v2-execution-report.md](contracts/contract-stabilization-v2-execution-report.md) | 合约稳定化 V2 **完成报告** |
| [sigma-contract-stabilization-plan-for-codex-v2.md](contracts/sigma-contract-stabilization-plan-for-codex-v2.md) | 稳定化执行计划（**Historical / Complete**，保留作对照） |

对应 ADR：[adr/0001-session-journal-and-operations-v2.md](adr/0001-session-journal-and-operations-v2.md)

## 功能文档（features/）

| 文档 | 说明 |
| --- | --- |
| [hooks/](features/hooks/) | Hook 系统设计、PRD、实现与生命周期计划 |
| [tools.md](features/tools.md) | `sigma_tools` / oh-my-pi 风格工具面 PRD |

## Agent 协作（agents/）

| 文档 | 说明 |
| --- | --- |
| [domain.md](agents/domain.md) | 领域文档与 ADR 阅读约定 |
| [issue-tracker.md](agents/issue-tracker.md) | GitHub Issues 操作约定 |
| [triage-labels.md](agents/triage-labels.md) | Triage 标签映射 |

## 归档（archive/）

见 [archive/README.md](archive/README.md)。含早期 port 说明、oh-my-pi 学习路线图父 PRD，以及已落地的 superpowers plans/specs。

## 仓库根目录说明

- 根目录 **无** 现行 `PLAN.md`。早期 port 工作曾要求把决策写入根 `PLAN.md`；该文件若重新出现，应视为 historical，并以本索引与 `contracts/` 为准。
- 产品概览与运行说明见根 [README.md](../README.md)。
- Agent 仓库约定见根 [AGENTS.md](../AGENTS.md)。
