#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE1_SCRIPT_DIR="${SCRIPT_DIR}"
python3 - <<'PY'
import json
import os
import re
import statistics
import subprocess
import sys
import time
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_DIR = Path(os.environ["PHASE1_SCRIPT_DIR"]).resolve()
REPO_ROOT = SCRIPT_DIR.parents[2]
CREDENTIALS_FILE = REPO_ROOT / "analysis/codex/pentagi_qwen_online_flow_test/credentials.env"
RUNS_DIR = SCRIPT_DIR / "runs"
RUN_ID = datetime.now().strftime("%Y%m%d_%H%M%S")
OUT_DIR = RUNS_DIR / RUN_ID

BASE_WAIT_SECONDS = 30
RATE_LIMIT_WAIT_SECONDS = 120
RATE_LIMIT_RETRIES = 1
TARGET_PROVIDERS = ["qwen-3.5-plus", "qwen3.5-35b", "qwen3.5-27b"]
AGENT_ORDER = [
    "adviser",
    "assistant",
    "coder",
    "enricher",
    "generator",
    "installer",
    "pentester",
    "primaryAgent",
    "refiner",
    "reflector",
    "searcher",
    "simple",
    "simpleJson",
]
AGENT_TYPE_ENUM = {
    "adviser": "adviser",
    "assistant": "assistant",
    "coder": "coder",
    "enricher": "enricher",
    "generator": "generator",
    "installer": "installer",
    "pentester": "pentester",
    "primaryAgent": "primary_agent",
    "refiner": "refiner",
    "reflector": "reflector",
    "searcher": "searcher",
    "simple": "simple",
    "simpleJson": "simple_json",
}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_credentials(path: Path) -> dict:
    if not path.exists():
        raise FileNotFoundError(f"credentials file not found: {path}")
    env = {}
    pattern = re.compile(r"^([A-Z0-9_]+)=(.*)$")
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = pattern.match(line)
        if not match:
            continue
        key, value = match.groups()
        value = value.strip()
        if (value.startswith("'") and value.endswith("'")) or (value.startswith('"') and value.endswith('"')):
            value = value[1:-1]
        env[key] = value
    return env


CREDS = read_credentials(CREDENTIALS_FILE)
PENTAGI_EMAIL = CREDS["PENTAGI_EMAIL"]
PENTAGI_PASSWORD = CREDS["PENTAGI_PASSWORD"]
PENTAGI_CONTAINER = CREDS.get("PENTAGI_CONTAINER", "pentagi")


def run(cmd, *, input_text=None, check=True):
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        capture_output=True,
        check=check,
        cwd=str(REPO_ROOT),
    )


def docker_exec(script: str, *, check=True):
    return run(["docker", "exec", PENTAGI_CONTAINER, "sh", "-c", script], check=check)


def docker_write_file(path_in_container: str, content: str):
    proc = run(["docker", "exec", "-i", PENTAGI_CONTAINER, "sh", "-c", f"cat > '{path_in_container}'"], input_text=content)
    return proc


def ensure_dir(path: Path):
    path.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_text(path: Path, text: str):
    path.write_text(text, encoding="utf-8")


def append_timeline(path: Path, event_type: str, **fields):
    event = {
        "timestamp": now_iso(),
        "event": event_type,
    }
    event.update(fields)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


def sanitize_graphql_response(stdout: str, stderr: str, returncode: int):
    payload = None
    parse_error = None
    if stdout.strip():
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as exc:
            parse_error = str(exc)
    return {
        "returncode": returncode,
        "stdout": stdout,
        "stderr": stderr,
        "json": payload,
        "json_parse_error": parse_error,
    }


def extract_transport_or_graphql_error(sanitized) -> str:
    payload = sanitized.get("json")
    if payload and payload.get("errors"):
        try:
            return "; ".join(err.get("message", "") for err in payload["errors"] if err.get("message")) or json.dumps(
                payload["errors"], ensure_ascii=False
            )
        except Exception:
            return json.dumps(payload["errors"], ensure_ascii=False)
    if sanitized.get("stderr"):
        return sanitized["stderr"].strip()
    if sanitized.get("json_parse_error"):
        return sanitized["json_parse_error"]
    return ""


RATE_LIMIT_PATTERNS = [
    r"\b429\b",
    r"rate limit",
    r"too many requests",
    r"\bquota\b",
    r"dashscope.*limit",
    r"qwen.*limit",
]


def is_rate_limit(text: str) -> bool:
    if not text:
        return False
    lowered = text.lower()
    return any(re.search(pattern, lowered) for pattern in RATE_LIMIT_PATTERNS)


def categorize_error(error_text: str, tests: list, graphql_success: bool) -> str:
    combined = " ".join(
        [error_text or ""] + [str(test.get("error") or "") for test in tests]
    ).lower()
    if is_rate_limit(combined):
        return "rate_limit"
    if "auth" in combined or "unauthorized" in combined or "forbidden" in combined:
        return "auth"
    if "model" in combined and ("not found" in combined or "does not exist" in combined):
        return "model_not_found"
    if "timeout" in combined or "timed out" in combined or "deadline exceeded" in combined:
        return "timeout"
    if "provider" in combined or "config" in combined or "configuration" in combined:
        return "provider_config"
    if not graphql_success:
        return "graphql_error"
    if not tests:
        return "empty_tests"
    results = [test.get("result") for test in tests]
    if any(result is False for result in results) and any(result is True for result in results):
        return "partial_failure"
    return "other"


def average(values):
    values = [v for v in values if isinstance(v, (int, float))]
    if not values:
        return None
    return round(sum(values) / len(values), 2)


def percent(numerator: int, denominator: int):
    if denominator == 0:
        return 0.0
    return round((numerator / denominator) * 100.0, 2)


def failed_test_entries(tests: list) -> list:
    return [test for test in tests if test.get("result") is False]


def passed_test_entries(tests: list) -> list:
    return [test for test in tests if test.get("result") is True]


def compact_test_entry(test: dict) -> dict:
    return {
        "name": test.get("name"),
        "type": test.get("type"),
        "result": test.get("result"),
        "reasoning": test.get("reasoning"),
        "streaming": test.get("streaming"),
        "latency": test.get("latency"),
        "error": test.get("error"),
    }


def determine_outcome_shape(tests: list, graphql_success: bool) -> str:
    if not graphql_success:
        return "transport_or_graphql_failure"
    if not tests:
        return "empty_tests"
    passed_count = len(passed_test_entries(tests))
    failed_count = len(failed_test_entries(tests))
    if failed_count == 0 and passed_count > 0:
        return "all_passed"
    if failed_count > 0 and passed_count > 0:
        return "partial_failed"
    if failed_count > 0 and passed_count == 0:
        return "all_failed"
    return "unknown"


def build_error_summary(error_text: str, tests: list) -> str:
    failed = failed_test_entries(tests)
    if failed:
        pieces = []
        for test in failed[:3]:
            detail = test.get("error") or "failed without explicit error"
            pieces.append(f"{test.get('name')}: {detail}")
        if len(failed) > 3:
            pieces.append(f"... and {len(failed) - 3} more failed subtests")
        return "; ".join(pieces)
    clean_error = (error_text or "").strip()
    if clean_error:
        return clean_error[:300]
    return ""


def perform_login(run_root: Path, timeline_path: Path):
    login_request_path = run_root / "login_request.redacted.json"
    login_response_path = run_root / "login_response.json"
    container_login_payload = "/tmp/pentagi-phase1-login.json"

    write_json(
        login_request_path,
        {"mail": PENTAGI_EMAIL, "password": "*** redacted; see analysis/codex/pentagi_qwen_online_flow_test/credentials.env ***"},
    )

    login_payload = json.dumps({"mail": PENTAGI_EMAIL, "password": PENTAGI_PASSWORD}, ensure_ascii=False)
    docker_write_file(container_login_payload, login_payload + "\n")
    append_timeline(timeline_path, "login_started", container=PENTAGI_CONTAINER)
    started = time.monotonic()
    proc = docker_exec(
        "wget -qS -O /tmp/pentagi-phase1-login-body "
        "--no-check-certificate "
        '--header "Content-Type: application/json" '
        f"--post-file {container_login_payload} "
        "https://127.0.0.1:8443/api/v1/auth/login "
        "2>/tmp/pentagi-phase1-login-headers; "
        "status=$?; "
        'if [ -f /tmp/pentagi-phase1-login-body ]; then cat /tmp/pentagi-phase1-login-body; fi; '
        "exit $status",
        check=False,
    )
    elapsed = round((time.monotonic() - started) * 1000)

    header_proc = docker_exec("cat /tmp/pentagi-phase1-login-headers 2>/dev/null || true", check=False)
    headers = header_proc.stdout
    cookie_match = re.search(r"Set-Cookie:\s*(auth=[^;]+)", headers)
    cookie = cookie_match.group(1) if cookie_match else ""
    if cookie:
        docker_exec(f"printf '%s' '{cookie}' > /tmp/pentagi-phase1-auth-cookie")

    sanitized = {
        "returncode": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "headers_excerpt": headers,
        "duration_ms": elapsed,
        "cookie_found": bool(cookie),
    }
    write_json(login_response_path, sanitized)
    append_timeline(
        timeline_path,
        "login_finished",
        container=PENTAGI_CONTAINER,
        duration_ms=elapsed,
        success=proc.returncode == 0 and bool(cookie),
    )
    return proc.returncode == 0 and bool(cookie), sanitized


def graphql_request(payload: dict, *, timeline_path: Path = None, event_prefix: str = None):
    payload_text = json.dumps(payload, ensure_ascii=False)
    docker_write_file("/tmp/pentagi-phase1-graphql.json", payload_text + "\n")
    if timeline_path and event_prefix:
        append_timeline(timeline_path, f"{event_prefix}_started")
    started = time.monotonic()
    proc = docker_exec(
        """
cookie=$(cat /tmp/pentagi-phase1-auth-cookie)
wget -qS -O /tmp/pentagi-phase1-graphql-body \
  --no-check-certificate \
  --header "Cookie: $cookie" \
  --header "Content-Type: application/json" \
  --post-file /tmp/pentagi-phase1-graphql.json \
  https://127.0.0.1:8443/api/v1/graphql \
  2>/tmp/pentagi-phase1-graphql-headers
status=$?
if [ -f /tmp/pentagi-phase1-graphql-body ]; then cat /tmp/pentagi-phase1-graphql-body; fi
exit $status
""".strip(),
        check=False,
    )
    elapsed = round((time.monotonic() - started) * 1000)
    headers = docker_exec("cat /tmp/pentagi-phase1-graphql-headers 2>/dev/null || true", check=False).stdout
    sanitized = sanitize_graphql_response(proc.stdout, headers + ("\n" + proc.stderr if proc.stderr else ""), proc.returncode)
    sanitized["duration_ms"] = elapsed
    if timeline_path and event_prefix:
        append_timeline(
            timeline_path,
            f"{event_prefix}_finished",
            duration_ms=elapsed,
            returncode=proc.returncode,
            has_json=bool(sanitized.get("json")),
        )
    return sanitized


def build_snapshot_and_preflight(run_root: Path, timeline_path: Path):
    query = {
        "query": (
            "query settingsProviders { "
            "settingsProviders { "
            "userDefined { "
            "id name type "
            "agents { "
            "simple { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "simpleJson { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "primaryAgent { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "assistant { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "generator { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "refiner { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "adviser { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "reflector { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "searcher { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "enricher { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "coder { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "installer { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "pentester { model maxTokens temperature topK topP minLength maxLength repetitionPenalty frequencyPenalty presencePenalty reasoning { effort maxTokens } price { input output cacheRead cacheWrite } } "
            "} } } }"
        )
    }
    sanitized = graphql_request(query, timeline_path=timeline_path, event_prefix="settings_snapshot_fetch")
    write_json(run_root / "01_settings_providers_snapshot.json", sanitized)

    snapshot = sanitized.get("json") or {}
    providers = (((snapshot.get("data") or {}).get("settingsProviders") or {}).get("userDefined")) or []
    provider_map = {provider["name"]: provider for provider in providers}
    checks = []
    ok = sanitized["returncode"] == 0 and bool(snapshot.get("data"))
    for provider_name in TARGET_PROVIDERS:
        provider = provider_map.get(provider_name)
        exists = provider is not None
        has_all_agents = exists and all(agent in provider.get("agents", {}) for agent in AGENT_ORDER)
        missing_models = []
        if exists:
            for agent in AGENT_ORDER:
                model = (((provider.get("agents") or {}).get(agent) or {}).get("model"))
                if not model:
                    missing_models.append(agent)
        checks.append(
            {
                "provider_name": provider_name,
                "exists": exists,
                "provider_id": provider.get("id") if provider else None,
                "provider_type": provider.get("type") if provider else None,
                "has_all_agents": has_all_agents,
                "missing_models": missing_models,
            }
        )
        ok = ok and exists and has_all_agents and not missing_models

    preflight = {
        "timestamp": now_iso(),
        "login_cookie_present": True,
        "snapshot_query_success": sanitized["returncode"] == 0 and bool(snapshot.get("data")),
        "target_providers": TARGET_PROVIDERS,
        "checks": checks,
        "ok": ok,
    }
    write_json(run_root / "00_preflight.json", preflight)
    append_timeline(timeline_path, "settings_snapshot_saved", ok=ok, provider_count=len(providers))
    return ok, provider_map, preflight


def build_test_matrix(provider_map: dict):
    matrix = []
    sequence_no = 1
    for provider_name in TARGET_PROVIDERS:
        provider = provider_map[provider_name]
        for agent_key in AGENT_ORDER:
            agent_cfg = deepcopy(provider["agents"][agent_key])
            matrix.append(
                {
                    "sequence_no": sequence_no,
                    "provider_name": provider_name,
                    "provider_id": provider["id"],
                    "provider_type": provider["type"],
                    "agent_key": agent_key,
                    "agent_type_enum": AGENT_TYPE_ENUM[agent_key],
                    "model": agent_cfg["model"],
                    "agent": agent_cfg,
                    "base_wait_seconds": BASE_WAIT_SECONDS,
                    "rate_limit_wait_seconds": RATE_LIMIT_WAIT_SECONDS,
                    "max_retries_on_rate_limit": RATE_LIMIT_RETRIES,
                }
            )
            sequence_no += 1
    return matrix


def classify_attempt_result(sanitized):
    payload = sanitized.get("json") or {}
    graphql_success = sanitized["returncode"] == 0 and not payload.get("errors")
    tests = (((payload.get("data") or {}).get("testAgent") or {}).get("tests")) or []
    all_tests_passed = bool(tests) and all(test.get("result") is True for test in tests)
    error_text = extract_transport_or_graphql_error(sanitized)
    error_category = categorize_error(error_text, tests, graphql_success)
    return {
        "graphql_success": graphql_success,
        "tests": tests,
        "tests_count": len(tests),
        "all_tests_passed": all_tests_passed,
        "outcome_shape": determine_outcome_shape(tests, graphql_success),
        "error_text": error_text,
        "error_category": error_category,
        "rate_limit": error_category == "rate_limit",
    }


def sleep_with_timeline(seconds: int, timeline_path: Path, reason: str, context: dict):
    append_timeline(timeline_path, "wait_started", wait_seconds=seconds, reason=reason, **context)
    time.sleep(seconds)
    append_timeline(timeline_path, "wait_finished", wait_seconds=seconds, reason=reason, **context)


def execute_single_test(item: dict, run_root: Path, timeline_path: Path):
    test_dir = run_root / "04_raw_tests" / f"{item['sequence_no']:02d}_{item['provider_name']}_{item['agent_key']}"
    ensure_dir(test_dir)

    request_payload = {
        "query": (
            "mutation testAgent($type: ProviderType!, $agentType: AgentConfigType!, $agent: AgentConfigInput!) { "
            "testAgent(type: $type, agentType: $agentType, agent: $agent) { "
            "tests { name type result reasoning streaming latency error } "
            "} }"
        ),
        "variables": {
            "type": item["provider_type"],
            "agentType": item["agent_type_enum"],
            "agent": deepcopy(item["agent"]),
        },
    }

    write_json(
        test_dir / "request.json",
        {
            "sequence_no": item["sequence_no"],
            "provider_name": item["provider_name"],
            "provider_id": item["provider_id"],
            "provider_type": item["provider_type"],
            "agent_key": item["agent_key"],
            "agent_type_enum": item["agent_type_enum"],
            "model": item["model"],
            "graphql_payload": request_payload,
        },
    )

    attempts = []
    extra_wait_seconds = 0
    retry_reason = None
    final_status = "failed"
    append_timeline(
        timeline_path,
        "test_started",
        sequence_no=item["sequence_no"],
        provider_name=item["provider_name"],
        agent_key=item["agent_key"],
        model=item["model"],
    )

    attempt_no = 1
    while True:
        started_at = now_iso()
        started_monotonic = time.monotonic()
        sanitized = graphql_request(request_payload)
        ended_at = now_iso()
        duration_ms = round((time.monotonic() - started_monotonic) * 1000)
        classified = classify_attempt_result(sanitized)

        attempt_record = {
            "attempt_no": attempt_no,
            "started_at": started_at,
            "ended_at": ended_at,
            "duration_ms": duration_ms,
            "sanitized_response": sanitized,
            "graphql_success": classified["graphql_success"],
            "tests_count": classified["tests_count"],
            "all_tests_passed": classified["all_tests_passed"],
            "outcome_shape": classified["outcome_shape"],
            "error_category": classified["error_category"],
            "error_text": classified["error_text"],
            "rate_limit": classified["rate_limit"],
            "tests": classified["tests"],
        }
        attempts.append(attempt_record)

        if classified["all_tests_passed"]:
            final_status = "passed_after_retry" if attempt_no > 1 else "passed"
            break

        if classified["rate_limit"] and attempt_no <= RATE_LIMIT_RETRIES:
            retry_reason = "rate_limit"
            append_timeline(
                timeline_path,
                "rate_limit_detected",
                sequence_no=item["sequence_no"],
                provider_name=item["provider_name"],
                agent_key=item["agent_key"],
                attempt_no=attempt_no,
                error_excerpt=classified["error_text"][:300],
            )
            extra_wait_seconds += RATE_LIMIT_WAIT_SECONDS
            sleep_with_timeline(
                RATE_LIMIT_WAIT_SECONDS,
                timeline_path,
                "rate_limit_backoff",
                {
                    "sequence_no": item["sequence_no"],
                    "provider_name": item["provider_name"],
                    "agent_key": item["agent_key"],
                    "attempt_no": attempt_no,
                },
            )
            append_timeline(
                timeline_path,
                "retry_started",
                sequence_no=item["sequence_no"],
                provider_name=item["provider_name"],
                agent_key=item["agent_key"],
                next_attempt_no=attempt_no + 1,
                retry_reason=retry_reason,
            )
            attempt_no += 1
            continue

        final_status = "failed_after_retry" if attempt_no > 1 else "failed"
        break

    final_attempt = attempts[-1]
    append_timeline(
        timeline_path,
        "test_finished",
        sequence_no=item["sequence_no"],
        provider_name=item["provider_name"],
        agent_key=item["agent_key"],
        model=item["model"],
        attempt_count=len(attempts),
        final_status=final_status,
        error_category=final_attempt["error_category"],
        duration_ms=final_attempt["duration_ms"],
    )

    response_payload = {
        "sequence_no": item["sequence_no"],
        "provider_name": item["provider_name"],
        "agent_key": item["agent_key"],
        "attempts": attempts,
    }
    write_json(test_dir / "response.json", response_payload)

    meta = {
        "sequence_no": item["sequence_no"],
        "provider_name": item["provider_name"],
        "provider_id": item["provider_id"],
        "provider_type": item["provider_type"],
        "agent_key": item["agent_key"],
        "agent_type_enum": item["agent_type_enum"],
        "model": item["model"],
        "started_at": attempts[0]["started_at"],
        "ended_at": final_attempt["ended_at"],
        "duration_ms": sum(attempt["duration_ms"] for attempt in attempts),
        "base_wait_seconds": BASE_WAIT_SECONDS,
        "extra_wait_seconds": extra_wait_seconds,
        "attempt_count": len(attempts),
        "retry_reason": retry_reason,
        "graphql_success": final_attempt["graphql_success"],
        "tests_count": final_attempt["tests_count"],
        "all_tests_passed": final_attempt["all_tests_passed"],
        "outcome_shape": final_attempt["outcome_shape"],
        "final_status": final_status,
        "error_category": final_attempt["error_category"],
        "error_summary": build_error_summary(final_attempt["error_text"], final_attempt["tests"]),
        "raw_error_excerpt": (final_attempt["error_text"] or "")[:1000],
        "passed_test_count": len(passed_test_entries(final_attempt["tests"])),
        "failed_test_count": len(failed_test_entries(final_attempt["tests"])),
        "passed_tests": [compact_test_entry(test) for test in passed_test_entries(final_attempt["tests"])],
        "failed_tests": failed_test_entries(final_attempt["tests"]),
        "tests": final_attempt["tests"],
    }
    write_json(test_dir / "meta.json", meta)
    return meta


def aggregate_results(run_root: Path, preflight: dict, matrix: list, item_results: list, started_at: str, ended_at: str):
    agg_dir = run_root / "05_aggregates"
    reports_dir = run_root / "06_reports"
    ensure_dir(agg_dir)
    ensure_dir(reports_dir)

    total_provider_count = len(TARGET_PROVIDERS)
    total_agent_items = len(matrix)
    total_calls = sum(item["attempt_count"] for item in item_results)
    first_pass_successes = sum(1 for item in item_results if item["final_status"] == "passed")
    retry_successes = sum(1 for item in item_results if item["final_status"] == "passed_after_retry")
    final_failures = sum(1 for item in item_results if item["final_status"] in {"failed", "failed_after_retry"})
    rate_limit_count = sum(1 for item in item_results if item["error_category"] == "rate_limit" or item["retry_reason"] == "rate_limit")
    non_rate_limit_failures = sum(
        1 for item in item_results if item["final_status"] in {"failed", "failed_after_retry"} and item["error_category"] != "rate_limit"
    )
    total_duration_ms = sum(item["duration_ms"] for item in item_results)
    average_item_duration_ms = average([item["duration_ms"] for item in item_results])
    average_wait_seconds = average([item["base_wait_seconds"] + item["extra_wait_seconds"] for item in item_results])

    summary = {
        "run_id": RUN_ID,
        "started_at": started_at,
        "ended_at": ended_at,
        "provider_count": total_provider_count,
        "agent_item_count": total_agent_items,
        "total_call_count": total_calls,
        "first_pass_success_count": first_pass_successes,
        "retry_success_count": retry_successes,
        "final_failure_count": final_failures,
        "rate_limit_count": rate_limit_count,
        "non_rate_limit_failure_count": non_rate_limit_failures,
        "total_duration_ms": total_duration_ms,
        "average_item_duration_ms": average_item_duration_ms,
        "average_wait_seconds": average_wait_seconds,
        "pass_rate_percent": percent(first_pass_successes + retry_successes, total_agent_items),
        "failure_rate_percent": percent(final_failures, total_agent_items),
    }
    write_json(agg_dir / "summary.json", summary)

    provider_stats = {}
    for provider_name in TARGET_PROVIDERS:
        subset = [item for item in item_results if item["provider_name"] == provider_name]
        failures = [item for item in subset if item["final_status"] in {"failed", "failed_after_retry"}]
        failure_counter = Counter(item["agent_key"] for item in failures)
        slowest = max(subset, key=lambda item: item["duration_ms"]) if subset else None
        latencies = []
        for item in subset:
            for test in item["tests"]:
                if isinstance(test.get("latency"), (int, float)):
                    latencies.append(test["latency"])
        provider_stats[provider_name] = {
            "total_items": len(subset),
            "success_count": sum(1 for item in subset if item["final_status"] in {"passed", "passed_after_retry"}),
            "failure_count": len(failures),
            "rate_limit_count": sum(1 for item in subset if item["retry_reason"] == "rate_limit" or item["error_category"] == "rate_limit"),
            "average_latency_ms": average(latencies),
            "slowest_item": {
                "sequence_no": slowest["sequence_no"],
                "agent_key": slowest["agent_key"],
                "model": slowest["model"],
                "duration_ms": slowest["duration_ms"],
                "final_status": slowest["final_status"],
            }
            if slowest
            else None,
            "most_failed_agent": [
                {"agent_key": key, "failure_count": value}
                for key, value in failure_counter.most_common()
            ][:3],
        }
    write_json(agg_dir / "provider_stats.json", provider_stats)

    agent_stats = {}
    for agent_key in AGENT_ORDER:
        subset = [item for item in item_results if item["agent_key"] == agent_key]
        latencies = []
        error_counts = Counter()
        providers_passed = []
        providers_failed = []
        for item in subset:
            for test in item["tests"]:
                if isinstance(test.get("latency"), (int, float)):
                    latencies.append(test["latency"])
            error_counts[item["error_category"]] += 1
            if item["final_status"] in {"passed", "passed_after_retry"}:
                providers_passed.append(item["provider_name"])
            else:
                providers_failed.append(item["provider_name"])
        agent_stats[agent_key] = {
            "providers_passed": providers_passed,
            "providers_failed": providers_failed,
            "success_count": len(providers_passed),
            "failure_count": len(providers_failed),
            "error_category_counts": dict(error_counts),
            "average_latency_ms": average(latencies),
            "latency_distribution": {
                "min": min(latencies) if latencies else None,
                "max": max(latencies) if latencies else None,
                "mean": average(latencies),
            },
        }
    write_json(agg_dir / "agent_stats.json", agent_stats)

    item_stats = []
    for item in item_results:
        item_stats.append(
            {
                "sequence_no": item["sequence_no"],
                "provider_name": item["provider_name"],
                "agent_key": item["agent_key"],
                "model": item["model"],
                "final_status": item["final_status"],
                "error_category": item["error_category"],
                "outcome_shape": item["outcome_shape"],
                "tests_count": item["tests_count"],
                "passed_test_count": item.get("passed_test_count", 0),
                "failed_test_count": item.get("failed_test_count", 0),
                "passed_tests": item.get("passed_tests", []),
                "failed_tests": item.get("failed_tests", []),
            }
        )
    write_json(agg_dir / "item_stats.json", item_stats)

    subtest_index = defaultdict(
        lambda: {
            "type": None,
            "total_runs": 0,
            "pass_count": 0,
            "fail_count": 0,
            "reasoning_true_count": 0,
            "streaming_true_count": 0,
            "latencies": [],
            "providers": defaultdict(lambda: {"pass_count": 0, "fail_count": 0}),
            "agents": defaultdict(lambda: {"pass_count": 0, "fail_count": 0}),
            "occurrences": [],
        }
    )
    for item in item_results:
        for test in item["tests"]:
            name = test.get("name") or "<unknown>"
            bucket = subtest_index[name]
            bucket["type"] = test.get("type")
            bucket["total_runs"] += 1
            if test.get("result") is True:
                bucket["pass_count"] += 1
                bucket["providers"][item["provider_name"]]["pass_count"] += 1
                bucket["agents"][item["agent_key"]]["pass_count"] += 1
            else:
                bucket["fail_count"] += 1
                bucket["providers"][item["provider_name"]]["fail_count"] += 1
                bucket["agents"][item["agent_key"]]["fail_count"] += 1
            if test.get("reasoning") is True:
                bucket["reasoning_true_count"] += 1
            if test.get("streaming") is True:
                bucket["streaming_true_count"] += 1
            if isinstance(test.get("latency"), (int, float)):
                bucket["latencies"].append(test["latency"])
            bucket["occurrences"].append(
                {
                    "sequence_no": item["sequence_no"],
                    "provider_name": item["provider_name"],
                    "agent_key": item["agent_key"],
                    "model": item["model"],
                    "result": test.get("result"),
                    "latency": test.get("latency"),
                    "error": test.get("error"),
                    "reasoning": test.get("reasoning"),
                    "streaming": test.get("streaming"),
                }
            )

    subtest_stats = {}
    for subtest_name, bucket in sorted(subtest_index.items()):
        subtest_stats[subtest_name] = {
            "type": bucket["type"],
            "total_runs": bucket["total_runs"],
            "pass_count": bucket["pass_count"],
            "fail_count": bucket["fail_count"],
            "pass_rate_percent": percent(bucket["pass_count"], bucket["total_runs"]),
            "reasoning_true_count": bucket["reasoning_true_count"],
            "streaming_true_count": bucket["streaming_true_count"],
            "average_latency_ms": average(bucket["latencies"]),
            "providers": {provider: stats for provider, stats in sorted(bucket["providers"].items())},
            "agents": {agent: stats for agent, stats in sorted(bucket["agents"].items())},
            "occurrences": bucket["occurrences"],
        }
    write_json(agg_dir / "subtest_stats.json", subtest_stats)

    error_stats = {
        "counts": dict(Counter(item["error_category"] for item in item_results)),
        "items": [
            {
                "sequence_no": item["sequence_no"],
                "provider_name": item["provider_name"],
                "agent_key": item["agent_key"],
                "model": item["model"],
                "final_status": item["final_status"],
                "error_category": item["error_category"],
                "outcome_shape": item["outcome_shape"],
                "tests_count": item["tests_count"],
                "passed_test_count": item.get("passed_test_count", 0),
                "failed_test_count": item.get("failed_test_count", 0),
                "error_summary": item["error_summary"],
                "failed_tests": item.get("failed_tests", []),
            }
            for item in item_results
            if item["error_category"] not in {"other"} or item["final_status"] in {"failed", "failed_after_retry"}
        ],
    }
    write_json(agg_dir / "error_stats.json", error_stats)

    retry_items = [item for item in item_results if item["attempt_count"] > 1]
    retry_stats = {
        "retry_count": len(retry_items),
        "items": [
            {
                "sequence_no": item["sequence_no"],
                "provider_name": item["provider_name"],
                "agent_key": item["agent_key"],
                "model": item["model"],
                "retry_reason": item["retry_reason"],
                "final_status": item["final_status"],
                "extra_wait_seconds": item["extra_wait_seconds"],
                "attempt_count": item["attempt_count"],
            }
            for item in retry_items
        ],
        "successful_retries": sum(1 for item in retry_items if item["final_status"] == "passed_after_retry"),
        "failed_retries": sum(1 for item in retry_items if item["final_status"] == "failed_after_retry"),
        "total_extra_wait_seconds": sum(item["extra_wait_seconds"] for item in retry_items),
    }
    write_json(agg_dir / "retry_stats.json", retry_stats)

    readable_lines = [
        "# 第一部分 Provider 内置 Test 功能测试报告",
        "",
        "## 测试背景",
        "",
        "本轮测试验证 PentAGI Provider 编辑页中每个 agent 行右侧的内置 `Test` 功能是否可用。",
        "测试方式为 API 等价调用 `testAgent`，不修改任何参数，直接复用当前 provider 配置快照。",
        "",
        "## 测试对象与矩阵",
        "",
        f"- Provider 数量：`{total_provider_count}`",
        f"- Agent 测试项数量：`{total_agent_items}`",
        f"- 调用顺序固定为：`{' -> '.join(TARGET_PROVIDERS)}`",
        f"- 每个 provider 的 agent 顺序固定为：`{' / '.join(AGENT_ORDER)}`",
        "",
        "## 执行规则",
        "",
        f"- 基础间隔：`{BASE_WAIT_SECONDS}s`",
        f"- 限流重试等待：`{RATE_LIMIT_WAIT_SECONDS}s`",
        f"- 限流重试次数：`{RATE_LIMIT_RETRIES}`",
        "- 非限流失败不重试，直接记录并继续后续测试。",
        "",
        "## 总体结果",
        "",
        f"- 首次成功：`{first_pass_successes}`",
        f"- 重试后成功：`{retry_successes}`",
        f"- 最终失败：`{final_failures}`",
        f"- 总调用次数：`{total_calls}`",
        f"- 通过率：`{summary['pass_rate_percent']}%`",
        f"- 失败率：`{summary['failure_rate_percent']}%`",
        f"- 限流次数：`{rate_limit_count}`",
        f"- 总耗时：`{total_duration_ms}ms`",
        "",
        "## 分 Provider 结果",
        "",
    ]
    for provider_name in TARGET_PROVIDERS:
        stat = provider_stats[provider_name]
        readable_lines.extend(
            [
                f"### {provider_name}",
                "",
                f"- 总项数：`{stat['total_items']}`",
                f"- 成功数：`{stat['success_count']}`",
                f"- 失败数：`{stat['failure_count']}`",
                f"- 限流次数：`{stat['rate_limit_count']}`",
                f"- 平均内部 latency（tests[].latency 均值）：`{stat['average_latency_ms']}`",
            ]
        )
        if stat["slowest_item"]:
            readable_lines.append(
                f"- 最慢项：`{stat['slowest_item']['agent_key']}` / `{stat['slowest_item']['model']}` / `{stat['slowest_item']['duration_ms']}ms`"
            )
        readable_lines.append("")

    readable_lines.extend(["## 分 Agent 结果", ""])
    for agent_key in AGENT_ORDER:
        stat = agent_stats[agent_key]
        readable_lines.extend(
            [
                f"### {agent_key}",
                "",
                f"- 通过 provider：`{', '.join(stat['providers_passed']) if stat['providers_passed'] else '-'}`",
                f"- 失败 provider：`{', '.join(stat['providers_failed']) if stat['providers_failed'] else '-'}`",
                f"- 平均内部 latency（tests[].latency 均值）：`{stat['average_latency_ms']}`",
                f"- 错误分布：`{json.dumps(stat['error_category_counts'], ensure_ascii=False)}`",
                "",
            ]
        )

    failures = [item for item in item_results if item["final_status"] in {"failed", "failed_after_retry"}]
    readable_lines.extend(["## 失败项清单", ""])
    if failures:
        for item in failures:
            readable_lines.append(
                f"- `{item['provider_name']}` / `{item['agent_key']}` / `{item['model']}` -> `{item['final_status']}` / `{item['error_category']}` / `{item['outcome_shape']}` / 失败 `{item.get('failed_test_count', 0)}` 个子测试（共 `{item['tests_count']}` 个）"
            )
            if item.get("failed_tests"):
                for failed_test in item["failed_tests"]:
                    readable_lines.append(
                        f"  - 子测试：`{failed_test.get('name', '?')}` / 类型：`{failed_test.get('type', '?')}` / latency：`{failed_test.get('latency')}` / 错误：`{failed_test.get('error') or '无明确错误信息'}`"
                    )
            else:
                readable_lines.append(f"  - 错误摘要：`{item['error_summary'] or '无明确错误摘要'}`")
    else:
        readable_lines.append("- 本轮无最终失败项。")

    readable_lines.extend(
        [
            "",
            "## 限流情况分析",
            "",
            f"- 触发限流的测试项数：`{len(retry_items)}`",
            f"- 重试后恢复的项数：`{retry_stats['successful_retries']}`",
            f"- 重试后仍失败的项数：`{retry_stats['failed_retries']}`",
            "",
            "## 关键观察",
            "",
            "- 本报告只覆盖 Provider 页面内置的 per-agent Test 能力，不覆盖底部整组 Test。",
            "- `testAgent` 不携带 `providerId`，区分 provider 的依据是快照中原样读取并提交的 agent config。",
            "- 除总览统计外，本轮还产出了 item 和 subtest 两个维度的明细统计。",
            "- 后续综合报告可以直接消费本轮 `05_aggregates` 下的统计 JSON。",
            "",
            "## 后续建议",
            "",
            "- 若通过率足够高，可进入下一阶段功能实测。",
            "- 若限流比例偏高，应在后续测试阶段采用更大的 provider 级间隔。",
        ]
    )
    write_text(reports_dir / "readable_report.md", "\n".join(readable_lines) + "\n")

    item_lines = [
        "# 第一部分 Item 子测试明细报告",
        "",
        "每一节对应一个 provider/agent 测试项，列出该项内全部子测试的通过/失败情况。",
        "",
    ]
    for item in item_results:
        item_lines.extend(
            [
                f"## {item['sequence_no']:02d} / {item['provider_name']} / {item['agent_key']}",
                "",
                f"- 模型：`{item['model']}`",
                f"- 最终状态：`{item['final_status']}`",
                f"- 结果形态：`{item['outcome_shape']}`",
                f"- 子测试通过/失败：`{item.get('passed_test_count', 0)}/{item.get('failed_test_count', 0)}`（总数 `{item['tests_count']}`）",
                "",
                "通过的子测试：",
            ]
        )
        if item.get("passed_tests"):
            for passed_test in item["passed_tests"]:
                item_lines.append(
                    f"- `{passed_test.get('name', '?')}` / `{passed_test.get('type', '?')}` / latency=`{passed_test.get('latency')}` / reasoning=`{passed_test.get('reasoning')}` / streaming=`{passed_test.get('streaming')}`"
                )
        else:
            item_lines.append("- 无")
        item_lines.append("")
        item_lines.append("失败的子测试：")
        if item.get("failed_tests"):
            for failed_test in item["failed_tests"]:
                item_lines.append(
                    f"- `{failed_test.get('name', '?')}` / `{failed_test.get('type', '?')}` / latency=`{failed_test.get('latency')}` / error=`{failed_test.get('error') or '无明确错误信息'}`"
                )
        else:
            item_lines.append("- 无")
        item_lines.append("")
    write_text(reports_dir / "item_subtest_report.md", "\n".join(item_lines) + "\n")

    subtest_lines = [
        "# 第一部分 Subtest 维度统计报告",
        "",
        "每一节对应一个子测试名称，统计它在全部 provider/agent 项中的通过与失败情况。",
        "",
    ]
    for subtest_name, stat in subtest_stats.items():
        subtest_lines.extend(
            [
                f"## {subtest_name}",
                "",
                f"- 类型：`{stat['type']}`",
                f"- 总出现次数：`{stat['total_runs']}`",
                f"- 通过次数：`{stat['pass_count']}`",
                f"- 失败次数：`{stat['fail_count']}`",
                f"- 通过率：`{stat['pass_rate_percent']}%`",
                f"- 平均 latency：`{stat['average_latency_ms']}`",
                "",
                "按 provider：",
            ]
        )
        for provider_name, provider_stat in stat["providers"].items():
            subtest_lines.append(
                f"- `{provider_name}` -> pass=`{provider_stat['pass_count']}` fail=`{provider_stat['fail_count']}`"
            )
        subtest_lines.append("")
        subtest_lines.append("失败发生位置：")
        failures_for_subtest = [occ for occ in stat["occurrences"] if occ["result"] is False]
        if failures_for_subtest:
            for occ in failures_for_subtest:
                subtest_lines.append(
                    f"- `{occ['provider_name']}` / `{occ['agent_key']}` / latency=`{occ['latency']}` / error=`{occ['error'] or '无明确错误信息'}`"
                )
        else:
            subtest_lines.append("- 无")
        subtest_lines.append("")
    write_text(reports_dir / "subtest_report.md", "\n".join(subtest_lines) + "\n")

    failure_lines = [
        "# 第一部分失败项分析",
        "",
    ]
    if failures:
        for item in failures:
            failure_lines.extend(
                [
                    f"## {item['provider_name']} / {item['agent_key']}",
                    "",
                    f"- 模型：`{item['model']}`",
                    f"- 失败时间：`{item['ended_at']}`",
                    f"- 失败形态：`{item['outcome_shape']}`",
                    f"- 子测试通过/失败：`{item.get('passed_test_count', 0)}/{item.get('failed_test_count', 0)}`（总数 `{item['tests_count']}`）",
                    f"- 首次错误：`{item['error_summary']}`",
                    f"- 失败子测试数：`{item.get('failed_test_count', 0)}`",
                    f"- 是否重试：`{'是' if item['attempt_count'] > 1 else '否'}`",
                    f"- 重试结果：`{item['final_status']}`",
                    f"- 最终归因：`{item['error_category']}`",
                    f"- 是否疑似环境/模型/配额问题：`{'配额/限流' if item['error_category'] == 'rate_limit' else '需人工判断'}`",
                    "",
                ]
            )
            if item.get("failed_tests"):
                failure_lines.append("失败子测试明细：")
                for failed_test in item["failed_tests"]:
                    failure_lines.append(
                        f"- `{failed_test.get('name', '?')}` / `{failed_test.get('type', '?')}` / latency=`{failed_test.get('latency')}` / error=`{failed_test.get('error') or '无明确错误信息'}`"
                    )
                failure_lines.append("")
    else:
        failure_lines.append("本轮无最终失败项。")
    write_text(reports_dir / "failure_analysis.md", "\n".join(failure_lines) + "\n")

    executive_lines = [
        "# 第一部分执行摘要",
        "",
        f"- 本轮测试覆盖 3 个 qwen provider 的 39 个内置 per-agent Test 项。",
        f"- 通过率：`{summary['pass_rate_percent']}%`，失败率：`{summary['failure_rate_percent']}%`。",
        f"- 首次成功：`{first_pass_successes}`，重试后成功：`{retry_successes}`，最终失败：`{final_failures}`。",
        f"- 主要失败原因分布：`{json.dumps(error_stats['counts'], ensure_ascii=False)}`。",
        f"- {'建议进入下一阶段功能实测。' if final_failures == 0 else '建议先审阅失败项，再决定是否进入下一阶段功能实测。'}",
        "",
        "关键产物：",
        "- `05_aggregates/summary.json`",
        "- `05_aggregates/provider_stats.json`",
        "- `05_aggregates/agent_stats.json`",
        "- `05_aggregates/item_stats.json`",
        "- `05_aggregates/subtest_stats.json`",
        "- `05_aggregates/error_stats.json`",
        "- `05_aggregates/retry_stats.json`",
        "- `06_reports/readable_report.md`",
        "- `06_reports/item_subtest_report.md`",
        "- `06_reports/subtest_report.md`",
        "- `06_reports/failure_analysis.md`",
    ]
    write_text(reports_dir / "executive_summary.md", "\n".join(executive_lines) + "\n")


def write_preflight_failure_summary(run_root: Path, preflight: dict):
    reports_dir = run_root / "06_reports"
    ensure_dir(reports_dir)
    lines = [
        "# 第一部分执行摘要",
        "",
        "- 本轮未进入正式测试。",
        f"- 预检查结果：`{'通过' if preflight.get('ok') else '失败'}`",
        "",
        "失败检查项：",
    ]
    for item in preflight.get("checks", []):
        if not (item["exists"] and item["has_all_agents"] and not item["missing_models"]):
            lines.append(
                f"- `{item['provider_name']}`: exists={item['exists']} has_all_agents={item['has_all_agents']} missing_models={item['missing_models']}"
            )
    write_text(reports_dir / "executive_summary.md", "\n".join(lines) + "\n")


def main():
    try:
        docker_exec("true")
    except subprocess.CalledProcessError as exc:
        print(exc.stderr or exc.stdout, file=sys.stderr)
        raise

    ensure_dir(OUT_DIR)
    ensure_dir(OUT_DIR / "04_raw_tests")
    timeline_path = OUT_DIR / "03_execution_timeline.ndjson"
    started_at = now_iso()

    login_ok, login_info = perform_login(OUT_DIR, timeline_path)
    if not login_ok:
        preflight = {
            "timestamp": now_iso(),
            "ok": False,
            "reason": "login_failed",
            "login": login_info,
        }
        write_json(OUT_DIR / "00_preflight.json", preflight)
        write_preflight_failure_summary(OUT_DIR, preflight)
        append_timeline(timeline_path, "run_finished", ok=False, reason="login_failed")
        print(str(OUT_DIR))
        return

    preflight_ok, provider_map, preflight = build_snapshot_and_preflight(OUT_DIR, timeline_path)
    if not preflight_ok:
        write_preflight_failure_summary(OUT_DIR, preflight)
        append_timeline(timeline_path, "run_finished", ok=False, reason="preflight_failed")
        print(str(OUT_DIR))
        return

    matrix = build_test_matrix(provider_map)
    write_json(OUT_DIR / "02_test_matrix.json", matrix)

    results = []
    for index, item in enumerate(matrix):
        result = execute_single_test(item, OUT_DIR, timeline_path)
        results.append(result)
        if index < len(matrix) - 1:
            sleep_with_timeline(
                BASE_WAIT_SECONDS,
                timeline_path,
                "base_spacing",
                {
                    "sequence_no": item["sequence_no"],
                    "provider_name": item["provider_name"],
                    "agent_key": item["agent_key"],
                },
            )

    ended_at = now_iso()
    aggregate_results(OUT_DIR, preflight, matrix, results, started_at, ended_at)
    append_timeline(timeline_path, "run_finished", ok=True, total_items=len(results))
    print(str(OUT_DIR))


if __name__ == "__main__":
    main()
PY
