# PentAGI Phase 1 Provider Agent Tests

This directory stores the first formal test phase for PentAGI's built-in provider test feature.

Phase 1 scope:

- Test only the built-in per-agent `Test` action exposed on the provider edit page.
- Use API-equivalent GraphQL `testAgent` calls instead of browser clicking.
- Cover exactly these 3 configured qwen providers:
  - `qwen-max`
  - `qwen3.5-35b`
  - `qwen3.5-27b`
- Keep all provider parameters unchanged by reading the current provider snapshot and replaying the same agent config.
- Run tests serially with a base `30s` delay between items.
- If a qwen API rate-limit pattern is detected, wait longer and retry only that one item once.

Outputs are written under `runs/<timestamp>/` and include:

- preflight checks
- provider snapshot
- test matrix
- execution timeline
- raw request/response/meta for every agent test
- structured aggregate JSON files
- readable markdown reports

Sensitive credentials are reused from:

- `../pentagi_qwen_online_flow_test/credentials.env`

Run from repository root:

```bash
bash analysis/codex/phase1_provider_agent_tests/run_phase1_agent_tests.sh
```
