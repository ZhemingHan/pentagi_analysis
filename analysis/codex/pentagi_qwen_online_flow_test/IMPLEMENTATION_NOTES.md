# PentAGI API 测试实现思路

## 目标

用脚本代替前端操作，对正在运行的 PentAGI 服务做最小可复现测试：

- 登录系统。
- 查询 Provider。
- 使用指定 Provider 新建 Flow。
- 保存每一次请求和响应。
- 轮询 Flow、Task、Subtask 和日志。
- 主动结束测试 Flow，避免持续占用资源。
- 生成适合人工阅读的 Markdown 报告。

## 为什么通过 Docker 容器内访问

宿主环境直接访问 `https://localhost:8443` 时出现连接失败，但 `docker ps` 显示 `pentagi` 容器内部服务正在运行，且端口映射在宿主网络上。为了绕开当前执行环境与宿主端口映射之间的网络差异，脚本选择：

```bash
docker exec pentagi sh -c 'wget ... https://127.0.0.1:8443/api/v1/...'
```

这样请求发生在 `pentagi` 容器内部，`127.0.0.1:8443` 指向容器内的 PentAGI 后端进程，稳定可达。

## 认证问题如何解决

最初尝试默认密码 `admin` 登录失败，后续使用用户提供的新密码登录成功。容器内 BusyBox `wget` 不支持 `--save-cookies`，因此脚本改为：

- 使用 `wget -qS` 把响应头写入 `/tmp/pentagi-login-headers`。
- 用 `sed` 从 `Set-Cookie` 响应头里提取 `auth=...`。
- 将 Cookie 存入容器内 `/tmp/pentagi-auth-cookie`。
- 同时把本次会话 Cookie 保存到运行目录的 `auth.cookie`，方便复现与排查。

## GraphQL 调用方式

脚本将 GraphQL 请求 JSON 写入容器内临时文件：

```bash
/tmp/pentagi_graphql_payload.json
```

然后用已提取的 Cookie 调用：

```bash
https://127.0.0.1:8443/api/v1/graphql
```

当前测试使用的核心 mutation 是：

```graphql
mutation CreateFlow($modelProvider:String!, $input:String!) {
  createFlow(modelProvider:$modelProvider, input:$input) {
    id
    title
    status
    provider { name type }
    createdAt
    updatedAt
  }
}
```

## 状态轮询与结果保存

`createFlow` 返回后，系统仍会异步生成 Task、Subtask 和日志。因此脚本会进行多轮查询并保存：

- Flow 状态。
- Task 列表。
- Subtask 列表。
- MessageLog。
- AgentLog。
- TerminalLog。
- SearchLog。

轮询结果以完整 JSON 保存为 `04_poll_*.json`，同时用 `04_poll_summary.txt` 保存便于快速查看的状态摘要。

## 如何避免无意义测试记录

最初版本脚本会在 Docker 权限检查前创建运行目录，导致一次没有实际意义的失败目录。现在脚本先执行：

```bash
docker exec pentagi sh -c true
```

只有 Docker 可访问时才创建新的 `runs/<timestamp>/` 目录，避免产生空目录或无效记录。

## 收尾策略

测试完成后脚本会调用：

```graphql
mutation FinishFlow($flowId:ID!) {
  finishFlow(flowId:$flowId)
}
```

这样可以把测试 Flow 收尾，避免它继续运行、继续调用模型或占用后台执行资源。

## 报告文件

每次正式运行会生成两类 Markdown：

- `summary.md`：机器生成的运行索引和基本元数据。
- `readable_report.md`：从最终 JSON 中提取 Flow、Task、日志和模型输出，形成便于人工阅读的报告。

顶层 `README.md` 说明目录结构和运行方式，本文件说明实现思路和问题解决过程。
