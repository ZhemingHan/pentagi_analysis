# 第一部分正式测试总结报告

## 1. 测试背景

本报告对应 PentAGI 项目第一部分正式测试，测试对象为项目在 Provider 编辑页面中内置的单项 `Test` 功能。测试目标是验证该功能在 3 个 Qwen 3.5 系列模型配置下的实际可用性、稳定性与失败分布，并对每个测试项内部的子测试结果进行完整记录与统计。

本轮正式测试运行目录为：

- [20260424_021740](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740)

关键原始与聚合证据包括：

- [summary.json](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/05_aggregates/summary.json)
- [provider_stats.json](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/05_aggregates/provider_stats.json)
- [error_stats.json](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/05_aggregates/error_stats.json)
- [subtest_stats.json](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/05_aggregates/subtest_stats.json)
- [readable_report.md](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/06_reports/readable_report.md)
- [failure_analysis.md](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/06_reports/failure_analysis.md)
- [item_subtest_report.md](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/06_reports/item_subtest_report.md)
- [subtest_report.md](/home/jeremy_han/projects/pentagi_analysis/analysis/codex/phase1_provider_agent_tests/runs/20260424_021740/06_reports/subtest_report.md)

## 2. 测试范围与方法

本轮测试只覆盖 Provider 页面内每个 agent 行右侧的单项 `Test`，不包含页面底部的整组 `Test`。

执行方式不是浏览器点击，而是等价复现前端 GraphQL 行为：先读取当前 Provider 配置快照，再将每个 agent 当前配置原样提交给 `testAgent(type, agentType, agent)` 接口。这样可以确保测试结果与前端单项测试语义一致，同时保留完整的请求、响应与元数据记录。

### 2.1 测试对象

| Provider 名称 | Provider ID | 统一模型名 |
| --- | ---: | --- |
| `qwen-3.5-plus` | 2 | `qwen3.5-plus` |
| `qwen3.5-35b` | 3 | `qwen3.5-35b-a3b` |
| `qwen3.5-27b` | 4 | `qwen3.5-27b` |

### 2.2 测试矩阵

| 维度 | 数量 | 说明 |
| --- | ---: | --- |
| Provider 数量 | 3 | 三个 Qwen 3.5 系列 Provider |
| Agent 测试项数量 | 39 | 3 个 Provider × 13 个 Agent |
| 常规子测试数量 | 23 | 大多数 agent 测试项内部包含 23 个子测试 |
| JSON 专项子测试数量 | 1 | `simpleJson` 为单独 JSON 子测试 |

### 2.3 数据口径说明

| 指标 | 说明 |
| --- | --- |
| 测试项 | 指一次 `testAgent` 调用，对应一个 Provider 的一个 Agent |
| 子测试 | `testAgent.tests[]` 中的单个测试结果项 |
| 常规子测试总出现次数 36 | 因为 12 类常规 agent × 3 个 Provider = 36 次 |
| `Vulnerability Report Memory Test` 总出现次数 3 | 仅在 3 个 Provider 的 `simpleJson` 中各出现 1 次 |
| 平均内部 latency | 指 `tests[].latency` 的均值，不等于整个测试项端到端耗时 |

## 3. 总体结果

### 3.1 测试总览

| 指标 | 数值 |
| --- | ---: |
| 开始时间 | 2026-04-24 02:17:40 +08:00 |
| 结束时间 | 2026-04-24 03:02:27 +08:00 |
| 总测试项数 | 39 |
| 首次成功项数 | 35 |
| 重试后成功项数 | 0 |
| 最终失败项数 | 4 |
| 总调用次数 | 39 |
| 总耗时 | 1,311,097 ms |
| 平均单项耗时 | 33,617.87 ms |
| 平均等待时间 | 30.0 s |
| 总体通过率 | 89.74% |
| 总体失败率 | 10.26% |

### 3.2 总体判断

从整体结果看，PentAGI 内置单项 `Test` 功能在当前 3 个 Qwen 3.5 系列配置下可用性较高。39 个测试项中有 35 个成功，仅 4 个失败，说明系统测试链路、配置读取、GraphQL 调用和结果解析整体稳定。

失败项并未呈现随机散布，而是集中在少数特定能力点上，尤其是：

- 严格 JSON 输出
- 指定工具调用一致性

这说明当前问题主要是模型行为边界问题，而不是系统整体不可用。

## 4. Provider 维度结果

### 4.1 Provider 对比表

| Provider | 总项数 | 成功数 | 失败数 | 通过率 | 平均内部 latency(ms) | 最慢测试项 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `qwen-3.5-plus` | 13 | 12 | 1 | 92.31% | 6607.47 | `adviser` / `qwen3.5-plus` / 64015 ms |
| `qwen3.5-35b` | 13 | 11 | 2 | 84.62% | 3385.53 | `searcher` / `qwen3.5-35b-a3b` / 34457 ms |
| `qwen3.5-27b` | 13 | 12 | 1 | 92.31% | 4208.14 | `reflector` / `qwen3.5-27b` / 42225 ms |

### 4.2 Provider 分析

`qwen-3.5-plus` 与 `qwen3.5-27b` 在测试项通过率上并列第一，均达到 92.31%。其中 `qwen-3.5-plus` 的优势在于工具调用型关键子测试表现更稳定，而其唯一失败点发生在 `simpleJson` 的 JSON 严格输出。`qwen3.5-35b` 整体略弱，通过率为 84.62%，失败集中出现在带工具调用约束的测试项中。

## 5. 失败项汇总

### 5.1 失败项总表

| 序号 | Provider | Agent | 模型 | 失败形态 | 通过/失败子测试 | 失败子测试 | 失败原因摘要 |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| 13 | `qwen-3.5-plus` | `simpleJson` | `qwen3.5-plus` | `all_failed` | `0/1` | `Vulnerability Report Memory Test` | `invalid JSON response: unexpected end of JSON input` |
| 15 | `qwen3.5-35b` | `assistant` | `qwen3.5-35b-a3b` | `partial_failed` | `22/1` | `Penetration Testing Memory with Tool Call` | `expected function 'generate_report' not found in tool calls` |
| 21 | `qwen3.5-35b` | `primaryAgent` | `qwen3.5-35b-a3b` | `partial_failed` | `22/1` | `Penetration Testing Memory with Tool Call` | `expected function 'generate_report' not found in tool calls` |
| 27 | `qwen3.5-27b` | `adviser` | `qwen3.5-27b` | `partial_failed` | `22/1` | `Penetration Testing Memory with Tool Call` | `expected function 'generate_report' not found in tool calls` |

### 5.2 失败类型判断

本轮 4 个失败项可分为两类：

| 失败类别 | 项数 | 说明 |
| --- | ---: | --- |
| 严格 JSON 输出失败 | 1 | 仅出现在 `qwen-3.5-plus / simpleJson` |
| 指定工具调用一致性失败 | 3 | 都指向 `Penetration Testing Memory with Tool Call` |

## 6. Agent 维度简表

下表仅列出本轮存在失败的 agent 类型，帮助快速定位风险点。

| Agent | 通过 Provider | 失败 Provider | 失败原因类型 |
| --- | --- | --- | --- |
| `adviser` | `qwen-3.5-plus`, `qwen3.5-35b` | `qwen3.5-27b` | 工具调用一致性 |
| `assistant` | `qwen-3.5-plus`, `qwen3.5-27b` | `qwen3.5-35b` | 工具调用一致性 |
| `primaryAgent` | `qwen-3.5-plus`, `qwen3.5-27b` | `qwen3.5-35b` | 工具调用一致性 |
| `simpleJson` | `qwen3.5-35b`, `qwen3.5-27b` | `qwen-3.5-plus` | JSON 输出格式 |

## 7. 子测试成功率总表

下表按子测试名称汇总本轮全部子测试的通过情况。该表是本轮最重要的数据表之一，反映了“真正失败发生在哪一类能力”。

| 子测试名称 | 类型 | 总出现次数 | 通过次数 | 失败次数 | 成功率 | 平均内部 latency(ms) |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Ask Advice Function | tool | 36 | 36 | 0 | 100.00% | 1740.56 |
| Basic Context Memory Test | completion | 36 | 36 | 0 | 100.00% | 3684.50 |
| Basic Echo Function | tool | 36 | 36 | 0 | 100.00% | 1352.94 |
| Basic Echo Function Streaming | tool | 36 | 36 | 0 | 100.00% | 1321.67 |
| Count from 1 to 3 Streaming | completion | 36 | 36 | 0 | 100.00% | 3123.61 |
| Count from 1 to 5 | completion | 36 | 36 | 0 | 100.00% | 4155.36 |
| Cybersecurity Workflow Memory Test | completion | 36 | 36 | 0 | 100.00% | 1908.28 |
| Function Argument Memory Test | completion | 36 | 36 | 0 | 100.00% | 1502.72 |
| Function Response Memory Test | completion | 36 | 36 | 0 | 100.00% | 4318.28 |
| JSON Response Function | tool | 36 | 36 | 0 | 100.00% | 1655.94 |
| Math Calculation | completion | 36 | 36 | 0 | 100.00% | 1986.11 |
| Penetration Testing Framework | completion | 36 | 36 | 0 | 100.00% | 8828.61 |
| Penetration Testing Memory with Tool Call | tool | 36 | 33 | 3 | 91.67% | 2785.11 |
| Penetration Testing Methodology | completion | 36 | 36 | 0 | 100.00% | 10091.22 |
| Penetration Testing Tool Selection | tool | 36 | 36 | 0 | 100.00% | 2044.53 |
| SQL Injection Attack Type | completion | 36 | 36 | 0 | 100.00% | 6816.42 |
| Search Query Function | tool | 36 | 36 | 0 | 100.00% | 1329.03 |
| Search Query Function Streaming | tool | 36 | 36 | 0 | 100.00% | 1227.53 |
| Simple Math | completion | 36 | 36 | 0 | 100.00% | 2640.44 |
| Simple Math Streaming | completion | 36 | 36 | 0 | 100.00% | 2592.81 |
| Text Transform Uppercase | completion | 36 | 36 | 0 | 100.00% | 2925.22 |
| Vulnerability Assessment Tools | completion | 36 | 36 | 0 | 100.00% | 33742.36 |
| Vulnerability Report Memory Test | json | 3 | 2 | 1 | 66.67% | 12143.33 |
| Web Application Security Scanner | completion | 36 | 36 | 0 | 100.00% | 6484.72 |

## 8. 关键子测试专题分析

### 8.1 Penetration Testing Memory with Tool Call

这是本轮最关键的风险子测试。

| 指标 | 数值 |
| --- | ---: |
| 总出现次数 | 36 |
| 通过次数 | 33 |
| 失败次数 | 3 |
| 成功率 | 91.67% |
| 平均内部 latency | 2785.11 ms |

按 Provider 分布如下：

| Provider | 通过次数 | 失败次数 |
| --- | ---: | ---: |
| `qwen-3.5-plus` | 12 | 0 |
| `qwen3.5-35b` | 10 | 2 |
| `qwen3.5-27b` | 11 | 1 |

按 Agent 分布如下：

| Agent | 通过次数 | 失败次数 |
| --- | ---: | ---: |
| `adviser` | 2 | 1 |
| `assistant` | 2 | 1 |
| `primaryAgent` | 2 | 1 |
| 其他 agent | 27 | 0 |

这说明当前工具调用一致性问题不是随机扩散的，而是集中出现在少数 agent 角色上，特别是 `assistant`、`primaryAgent` 与 `adviser`。

### 8.2 Vulnerability Report Memory Test

这是本轮第二个需要重点关注的子测试。

| 指标 | 数值 |
| --- | ---: |
| 总出现次数 | 3 |
| 通过次数 | 2 |
| 失败次数 | 1 |
| 成功率 | 66.67% |
| 平均内部 latency | 12143.33 ms |

按 Provider 分布如下：

| Provider | 通过次数 | 失败次数 |
| --- | ---: | ---: |
| `qwen-3.5-plus` | 0 | 1 |
| `qwen3.5-35b` | 1 | 0 |
| `qwen3.5-27b` | 1 | 0 |

该子测试仅出现在 `simpleJson` 中，因此它本质上是结构化 JSON 输出稳定性的代表性指标。本轮显示 `qwen-3.5-plus` 在该点上弱于另外两个模型。

## 9. 正式结论

### 9.1 结论摘要

| 结论项 | 结论 |
| --- | --- |
| 系统内置单项 `Test` 功能是否可用 | 可用，整体通过率 89.74% |
| 最稳定的 Provider | `qwen-3.5-plus` 与 `qwen3.5-27b` 并列 |
| 相对较弱的 Provider | `qwen3.5-35b` |
| 主要风险点 | 工具调用一致性、JSON 严格输出 |
| 是否具备进入第二部分测试基础 | 具备 |

### 9.2 正式判断

PentAGI 第一部分测试表明，项目内置 Provider 单项 `Test` 功能在当前环境下总体稳定，能够完成大部分 agent 级验证。39 个测试项中有 35 个通过，仅 4 个失败，说明项目测试链路、配置读取与结果落盘机制均工作正常。

本轮问题并未表现为系统普遍不可用，而是集中在少数明确的能力边界上：

- `qwen-3.5-plus` 在严格 JSON 输出上存在风险
- `qwen3.5-35b` 与 `qwen3.5-27b` 在特定工具调用一致性测试上存在风险

因此，第一部分测试结果支持进入第二部分功能实测。但在后续阶段，应持续重点观察两类问题：

- 严格结构化输出是否稳定
- 指定工具调用是否严格满足预期

## 10. 附：本报告定位

本文件是第一部分正式总结稿，适合作为后续综合报告中的“第一部分正式版”直接引用。原始运行证据与完整机器可读结果均保留在本轮运行目录中，可用于后续复核与二次分析。
