# PentAGI qwen-online Flow Test

这个目录用于保存 Codex 侧对 PentAGI 的可复现测试记录。测试目标是：不通过前端，直接在运行中的 `pentagi` Docker 容器内调用后端 API，新建一个使用 `qwen-online` 的 Flow，并保存每一步请求、响应、轮询状态和最终报告。

## 当前测试内容

- 登录 PentAGI 后端。
- 查询可用 Provider。
- 使用 `qwen-online` 新建 Flow。
- 提问：`介绍一下你能干什么？`
- 轮询 Flow、Task、Subtask、MessageLog、AgentLog、TerminalLog、SearchLog。
- 调用 `finishFlow` 主动收尾，避免测试任务持续运行。
- 生成适合人工阅读的 `readable_report.md`。

## 文件说明

- `credentials.env`：保存用户提供的 PentAGI 登录凭据和默认测试参数，敏感文件。
- `run_flow_test.sh`：完整测试脚本。
- `IMPLEMENTATION_NOTES.md`：整体实现思路、遇到的问题和解决方式。
- `runs/<timestamp>/`：每次正式测试运行的完整产物目录。

每个 `runs/<timestamp>/` 目录中重点查看：

- `summary.md`：运行索引和基础元数据。
- `readable_report.md`：适合人工阅读的测试报告。
- `analysis_summary.md`：如有，是人工补充的分析摘要。
- `06_final_status.json`：最终完整状态和日志。
- `04_poll_summary.txt`：轮询过程摘要。

## 运行方式

从仓库根目录执行：

```bash
bash analysis/codex/pentagi_qwen_online_flow_test/run_flow_test.sh
```

如果当前用户没有 Docker socket 权限，需要以具备 Docker 权限的方式运行。

## 注意事项

- `credentials.env` 和各运行目录下的 `auth.cookie` 不应提交或外发。
- 脚本会真实创建 Flow，并在最后调用 `finishFlow` 收尾。
- 脚本已加入 Docker 预检，避免在 Docker 不可访问时生成无意义运行目录。
