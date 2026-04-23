#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDENTIALS_FILE="${SCRIPT_DIR}/credentials.env"
RUNS_DIR="${SCRIPT_DIR}/runs"
RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${RUNS_DIR}/${RUN_ID}"

if [[ ! -f "${CREDENTIALS_FILE}" ]]; then
  echo "credentials file not found: ${CREDENTIALS_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CREDENTIALS_FILE}"

: "${PENTAGI_EMAIL:?missing PENTAGI_EMAIL}"
: "${PENTAGI_PASSWORD:?missing PENTAGI_PASSWORD}"
: "${PENTAGI_CONTAINER:=pentagi}"
: "${PENTAGI_PROVIDER:=qwen-online}"
: "${PENTAGI_QUESTION:=介绍一下你能干什么？}"

run_in_container() {
  docker exec "${PENTAGI_CONTAINER}" sh -c "$1"
}

# Avoid creating meaningless run directories when Docker is unavailable.
run_in_container "true" >/dev/null

mkdir -p "${OUT_DIR}"

COOKIE_FILE="${OUT_DIR}/auth.cookie"
SUMMARY_FILE="${OUT_DIR}/summary.md"
META_FILE="${OUT_DIR}/metadata.env"
READABLE_REPORT_FILE="${OUT_DIR}/readable_report.md"

cat > "${META_FILE}" <<META
RUN_ID='${RUN_ID}'
PENTAGI_CONTAINER='${PENTAGI_CONTAINER}'
PENTAGI_PROVIDER='${PENTAGI_PROVIDER}'
PENTAGI_QUESTION='${PENTAGI_QUESTION}'
STARTED_AT='$(date -Is)'
META

chmod 600 "${COOKIE_FILE}" 2>/dev/null || true

write_container_file() {
  local container_path="$1"
  docker exec -i "${PENTAGI_CONTAINER}" sh -c "cat > '${container_path}'"
}

graphql_request() {
  local payload_file="$1"
  local output_file="$2"
  write_container_file /tmp/pentagi_graphql_payload.json < "${payload_file}"
  run_in_container "cookie=\$(cat /tmp/pentagi-auth-cookie); wget -qO- --no-check-certificate --header \"Cookie: \$cookie\" --header 'Content-Type: application/json' --post-file /tmp/pentagi_graphql_payload.json https://127.0.0.1:8443/api/v1/graphql" > "${output_file}"
}

extract_json_field() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

cur = data
for part in expr.split("."):
    if part.endswith("]"):
        name, idx = part[:-1].split("[")
        if name:
            cur = cur[name]
        cur = cur[int(idx)]
    else:
        cur = cur[part]
print(cur)
PY
}

cat > "${OUT_DIR}/01_login_request.redacted.json" <<JSON
{"mail":"${PENTAGI_EMAIL}","password":"*** redacted; stored in credentials.env ***"}
JSON

run_in_container "wget -qS -O /tmp/pentagi-login-body --no-check-certificate --header 'Content-Type: application/json' --post-data '{\"mail\":\"${PENTAGI_EMAIL}\",\"password\":\"${PENTAGI_PASSWORD}\"}' https://127.0.0.1:8443/api/v1/auth/login 2>/tmp/pentagi-login-headers && sed -n 's/^  Set-Cookie: \\(auth=[^;]*\\).*/\\1/p' /tmp/pentagi-login-headers > /tmp/pentagi-auth-cookie && chmod 600 /tmp/pentagi-auth-cookie && cat /tmp/pentagi-login-body" > "${OUT_DIR}/01_login_response.json"

run_in_container "cat /tmp/pentagi-auth-cookie" > "${COOKIE_FILE}"
chmod 600 "${COOKIE_FILE}"

run_in_container "cookie=\$(cat /tmp/pentagi-auth-cookie); wget -qO- --no-check-certificate --header \"Cookie: \$cookie\" https://127.0.0.1:8443/api/v1/providers/" > "${OUT_DIR}/02_providers_response.json"

cat > "${OUT_DIR}/03_create_flow_request.json" <<JSON
{
  "query": "mutation CreateFlow(\$modelProvider:String!, \$input:String!){ createFlow(modelProvider:\$modelProvider, input:\$input){ id title status provider { name type } createdAt updatedAt } }",
  "variables": {
    "modelProvider": "${PENTAGI_PROVIDER}",
    "input": "${PENTAGI_QUESTION}"
  }
}
JSON

graphql_request "${OUT_DIR}/03_create_flow_request.json" "${OUT_DIR}/03_create_flow_response.json"

FLOW_ID="$(extract_json_field "${OUT_DIR}/03_create_flow_response.json" "data.createFlow.id")"
echo "FLOW_ID='${FLOW_ID}'" >> "${META_FILE}"

cat > "${OUT_DIR}/04_flow_status_request.json" <<JSON
{
  "query": "query FlowStatus(\$flowId:ID!){ flow(flowId:\$flowId){ id title status provider { name type } createdAt updatedAt } tasks(flowId:\$flowId){ id title status input result subtasks { id title status description result } } messageLogs(flowId:\$flowId){ id type message thinking result resultFormat taskId subtaskId createdAt } agentLogs(flowId:\$flowId){ id initiator executor task result taskId subtaskId createdAt } terminalLogs(flowId:\$flowId){ id type text terminal taskId subtaskId createdAt } searchLogs(flowId:\$flowId){ id initiator executor engine query result taskId subtaskId createdAt } }",
  "variables": {
    "flowId": ${FLOW_ID}
  }
}
JSON

for i in 1 2 3 4 5 6 7 8 9 10; do
  graphql_request "${OUT_DIR}/04_flow_status_request.json" "${OUT_DIR}/04_poll_${i}.json"
  python3 - "$OUT_DIR/04_poll_${i}.json" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
flow = data.get("data", {}).get("flow", {})
tasks = data.get("data", {}).get("tasks", [])
logs = data.get("data", {}).get("messageLogs", [])
print(f"flow={flow.get('status')} tasks={[t.get('status') for t in tasks]} message_logs={len(logs)}")
PY
  sleep 10
done > "${OUT_DIR}/04_poll_summary.txt"

cat > "${OUT_DIR}/05_finish_flow_request.json" <<JSON
{
  "query": "mutation FinishFlow(\$flowId:ID!){ finishFlow(flowId:\$flowId) }",
  "variables": {
    "flowId": ${FLOW_ID}
  }
}
JSON

graphql_request "${OUT_DIR}/05_finish_flow_request.json" "${OUT_DIR}/05_finish_flow_response.json"
sleep 3
graphql_request "${OUT_DIR}/04_flow_status_request.json" "${OUT_DIR}/06_final_status.json"

python3 - "${OUT_DIR}" "${READABLE_REPORT_FILE}" <<'PY'
import json
import pathlib
import sys

out_dir = pathlib.Path(sys.argv[1])
report_path = pathlib.Path(sys.argv[2])

def load_json(name):
    with (out_dir / name).open("r", encoding="utf-8") as f:
        return json.load(f)

create = load_json("03_create_flow_response.json")["data"]["createFlow"]
final = load_json("06_final_status.json")["data"]
flow = final["flow"]
tasks = final.get("tasks", [])
message_logs = final.get("messageLogs", [])
agent_logs = final.get("agentLogs", [])
terminal_logs = final.get("terminalLogs", [])
search_logs = final.get("searchLogs", [])

latest_report = ""
for log in reversed(message_logs):
    if log.get("type") in {"report", "done", "output"} and (log.get("result") or log.get("message")):
        latest_report = log.get("result") or log.get("message")
        break

lines = [
    "# PentAGI qwen-online Flow 测试报告",
    "",
    "## 测试结论",
    "",
    f"- 新建 Flow 成功，Flow ID：`{flow.get('id')}`。",
    f"- 使用 Provider：`{flow.get('provider', {}).get('name')}` / `{flow.get('provider', {}).get('type')}`。",
    f"- Flow 标题：`{flow.get('title')}`。",
    f"- Flow 最终状态：`{flow.get('status')}`。",
    f"- `createFlow` 初始返回状态：`{create.get('status')}`。",
    f"- Task 数量：`{len(tasks)}`。",
    f"- MessageLog 数量：`{len(message_logs)}`。",
    f"- AgentLog 数量：`{len(agent_logs)}`。",
    f"- TerminalLog 数量：`{len(terminal_logs)}`。",
    f"- SearchLog 数量：`{len(search_logs)}`。",
    "",
    "## 任务与子任务",
    "",
]

for task in tasks:
    lines.extend([
        f"- Task `{task.get('id')}`：{task.get('title')}，状态 `{task.get('status')}`。",
        f"- 用户输入：{task.get('input')}",
    ])
    subtasks = task.get("subtasks") or []
    if subtasks:
        lines.append("")
        lines.append("### 子任务列表")
        lines.append("")
        for subtask in subtasks:
            result = subtask.get("result") or ""
            result_note = "有结果" if result else "无结果"
            lines.append(
                f"- Subtask `{subtask.get('id')}`：{subtask.get('title')}，状态 `{subtask.get('status')}`，{result_note}。"
            )
    lines.append("")

lines.extend([
    "## 模型可读输出摘录",
    "",
])

if latest_report:
    lines.append(latest_report)
else:
    lines.append("本次轮询窗口内未捕获到 report/done/output 类型的最终文本。")

lines.extend([
    "",
    "## 原始文件索引",
    "",
    "- `01_login_request.redacted.json`：脱敏登录请求。",
    "- `01_login_response.json`：登录响应。",
    "- `02_providers_response.json`：Provider 列表。",
    "- `03_create_flow_request.json`：新建 Flow 请求。",
    "- `03_create_flow_response.json`：新建 Flow 响应。",
    "- `04_poll_*.json`：轮询过程中的状态和日志快照。",
    "- `04_poll_summary.txt`：轮询摘要。",
    "- `05_finish_flow_request.json`：结束 Flow 请求。",
    "- `05_finish_flow_response.json`：结束 Flow 响应。",
    "- `06_final_status.json`：最终状态和日志。",
    "- `auth.cookie`：本次会话 Cookie，敏感文件。",
    "- `metadata.env`：运行元数据。",
])

report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

cat > "${SUMMARY_FILE}" <<MD
# PentAGI qwen-online Flow Test

- Run ID: ${RUN_ID}
- Flow ID: ${FLOW_ID}
- Provider: ${PENTAGI_PROVIDER}
- Question: ${PENTAGI_QUESTION}
- Started at: $(grep STARTED_AT "${META_FILE}" | cut -d= -f2-)
- Finished at: $(date -Is)

## Files

- 01_login_request.redacted.json
- 01_login_response.json
- 02_providers_response.json
- 03_create_flow_request.json
- 03_create_flow_response.json
- 04_poll_*.json
- 04_poll_summary.txt
- 05_finish_flow_request.json
- 05_finish_flow_response.json
- 06_final_status.json
- readable_report.md
- auth.cookie
- metadata.env

## Notes

The login password is stored in ${CREDENTIALS_FILE}. The raw session cookie for this run is stored in ${COOKIE_FILE}.
Readable results are summarized in ${READABLE_REPORT_FILE}.
MD

echo "${OUT_DIR}"
