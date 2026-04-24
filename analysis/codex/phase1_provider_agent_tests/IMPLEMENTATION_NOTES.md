# Phase 1 Implementation Notes

## Why use API-equivalent calls instead of UI automation

The frontend provider edit page does not send a browser-only action. Each per-agent `Test` button calls the GraphQL mutation:

```graphql
mutation testAgent($type: ProviderType!, $agentType: AgentConfigType!, $agent: AgentConfigInput!) {
  testAgent(type: $type, agentType: $agentType, agent: $agent) {
    tests {
      name
      type
      result
      reasoning
      streaming
      latency
      error
    }
  }
}
```

So the most faithful non-UI test is to:

1. log in,
2. query `settingsProviders`,
3. load the selected provider's current `agents` config,
4. send `testAgent` with the exact same config the UI would submit.

This avoids flaky browser automation while preserving frontend-equivalent behavior.

## Important backend behavior

The backend `testAgent` mutation does not accept `providerId` or provider name. It only takes:

- `type`
- `agentType`
- `agent`

That means the distinction between `qwen-max`, `qwen3.5-35b`, and `qwen3.5-27b` comes entirely from the agent config that is loaded from `settingsProviders.userDefined` and replayed unchanged.

## Phase 1 execution model

- Providers are tested in a fixed order:
  - `qwen-max`
  - `qwen3.5-35b`
  - `qwen3.5-27b`
- Agent order is fixed and matches the agreed matrix:
  - `adviser`
  - `assistant`
  - `coder`
  - `enricher`
  - `generator`
  - `installer`
  - `pentester`
  - `primaryAgent`
  - `refiner`
  - `reflector`
  - `searcher`
  - `simple`
  - `simpleJson`

## Rate-limit handling

Any failure matching one of these patterns is treated as a qwen API rate-limit issue:

- `429`
- `rate limit`
- `too many requests`
- `quota`
- qwen/dashscope-specific rate limit wording

Handling:

- save the first failure
- wait an extra `120s`
- retry only that one item once
- continue the rest of the matrix regardless of pass/fail

Other failures are recorded without retry.

## Reporting goals

The run artifacts are designed so that later reporting can be built from facts rather than narrative memory:

- raw per-item evidence under `04_raw_tests/`
- machine-readable timeline in `03_execution_timeline.ndjson`
- aggregate JSON under `05_aggregates/`
- readable markdown reports under `06_reports/`

The final comprehensive report can later consume:

- `summary.json`
- `provider_stats.json`
- `agent_stats.json`
- `error_stats.json`
- `retry_stats.json`
- `readable_report.md`
- `failure_analysis.md`
- `executive_summary.md`
