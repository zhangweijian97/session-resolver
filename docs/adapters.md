# 各客户端数据源实测真相与适配勘察清单

> 本文是四个已适配客户端的实测勘察记录（数据源形态、记录类型全表、坑），以及适配新客户端的 8 条勘察清单。目标读者：想深入使用 resolve 输出的开发者、想贡献新 adapter 的贡献者。
>
> 所有结论来自真实会话数据的实测（非官方文档推断），客户端版本以实测时点为准——格式可能随客户端升级漂移，发现问题欢迎提 issue。

## Claude Code

**存储**：`~/.claude/projects/<cwd编码>/<sessionId>.jsonl`（每会话一文件，文件名=sessionId）；subagent 会话独立存于 `<sessionId>/subagents/<agent-id>.jsonl`（本工具暂不解析）。

**目录编码**：cwd 的 `/` → `-`、非 ASCII 字符 → `-`（1 字符 → 1 个 `-`）、空格 → `-`，ASCII 保留。

**记录类型全表**（87 文件实测）：

| type | 内容 | 消费 |
|------|------|------|
| `user` / `assistant` | 对话主体，`message` 为 Anthropic API 形态（`{role, content}`，content 为 str 或 parts 数组） | meta + content |
| `progress` / `file-history-snapshot` / `queue-operation` / `last-prompt` / `system/api_error` | 进度/快照/队列/标记/错误事件 | 跳过 |

**message.content part 类型**：`text`、`thinking`（推理，`thinking` 字段）、`tool_use`（`name`+`input`+`id`）、`tool_result`（`tool_use_id` 关联，出现在 user 消息里，content 为 str 或 list）、`server_tool_use`/`server_tool_result`（服务端工具，同构）。

**坑与要点**：

- sessionId/cwd/timestamp/version/gitBranch/slug **冗余在每条记录**，无独立 meta 记录——meta 从首条对话记录取。
- 无环境变量 session-id 注入（有 `CLAUDECODE=1` 框架标记）→ identify 走存储层反查。
- 无显式 title；有 `slug`（客户端生成的会话短语标识）。title 派生：首条用户文本消息截断，slug 兜底。
- 首条 user 消息可能是命令包装文本（`<local-command-caveat>` 等纯文本直存）——按纯数据层不过滤，调用方自行识别。
- tool 关联按 `tool_use_id`（`tool_use.id` ↔ `tool_result.tool_use_id`）。
- 环境变量 `CLAUDE_CONFIG_DIR` 可覆盖数据根目录。

## Codex

**存储**：`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<时间戳>-<thread-id>.jsonl`（活跃）+ `~/.codex/archived_sessions/`（归档，平铺同命名）。

**记录类型**（每行一个 JSON）：`session_meta`（会话元数据：session_id/cwd/timestamp/originator/cli_version 等）、`response_item`（`message` / `function_call` / `function_call_output`）、`event_msg`（事件）、`world_state` / `turn_context`（环境快照，跳过）。

**坑与要点**：

- **用户消息双形态**：`response_item`(role=user) + `event_msg`(type=user_message) 并存——解析取 response_item，跳过 event_msg 去重。
- `developer` role 承载系统指令（AGENTS.md 等巨大文本），content 输出默认过滤。
- 会话 ID = thread-id（UUID），环境变量 `CODEX_THREAD_ID` 注入（桌面/CLI 均可用）——identify 主路径。
- 同一会话可跨多个 rollout 文件（续接），按文件名时间序合并解析。
- title 无显式字段——派生：首条用户消息截断。
- tool 关联按 `call_id`（`function_call.call_id` ↔ `function_call_output.call_id`）。
- 环境变量 `CODEX_HOME` 可覆盖数据根目录。

## dsh（DeepSeek Harness）

**存储**：`~/.dsh/sessions/<cwd编码>--/<session-uuid>/session.jsonl.zstd`（zstd 压缩 JSONL，每会话一目录）；workspace 注册表 `~/.dsh/storages/workspace.json`（path → sessionIds 映射，identify 主路径）。

**记录类型**（单会话实测 28 种 type，多数跳过）：`session`（元数据，id/createdAt/cwd 在**顶层字段**非 data 内）、`session/title`（显式标题）、`user/message`、`assistant/message`（content 内嵌 text/reasoning/tool-call）、`tool/result`、`request/context`（model/provider）为消费主体；流式 chunk（assistant/chunk 等）、agent/inbox/spliced、tool/call、step/turn 标记、command/approval/permission 等全部跳过（与完整形态重复或非对话内容）。

**坑与要点**：

- dsh 是 **web 常驻 server**（`npm exec @deepseek-ai/dsh web`），会话中命令的祖先进程是 server 进程，进程树不含 session-id，无环境变量注入 → identify 走存储层反查（注册表按 cwd 匹配 + mtime 最新，三级兜底）。
- 目录名编码：cwd 逐字符编码（`/` → `-`、非 ASCII → `~XXXX` 大写十六进制 Unicode 码点、首尾各补 `-`）——identify 不逆向编码，走注册表。
- title 有显式记录（`session/title`），无需派生。
- runtime context 快照以 `user/message` 形态混入（文本以 "Current runtime context." 开头）——无干净判别字段，按纯数据层不过滤。
- 解压依赖 `zstd` 命令（macOS 非自带）。
- 会话 ID 原生形态 `session-<uuid>`；本工具兼容裸 uuid（自动补前缀）。
- 环境变量 `DSH_HOME` 可覆盖数据根目录。

## ZCode

**存储**：`~/.zcode/cli/db/db.sqlite` 三表——`session`（会话元数据）、`message`（消息级元数据，role 在 `data` JSON 字符串内）、`part`（正文片段，`data` JSON 字符串含 type + 正文）。

**坑与要点**：

- `role` 需 `json_extract(message.data, '$.role')` 提取，不在独立字段。
- part 的工具调用与返回是**同一个 part**（统一 `type: "tool"`，`state.input` + `state.output`），不拆分。
- identify 从进程树提取 `sess_<uuid>`（环境变量 `ZCODE_APP_VERSION`/`ZCODE_ENV` 检测框架）。
- artifacts 目录（`~/.zcode/cli/artifacts/sess_<id>/`）只是文件变更快照，对话正文在 sqlite 的 part 表。

## 适配新客户端：8 条勘察清单

适配新客户端 adapter 前，按此清单勘察数据源，不重走试错。目标是回答"数据在哪、怎么读、有哪些坑"：

1. **会话 ID 来源**：环境变量 / 进程树 / 文件名，哪个最可靠？有无注入变量（如 `CODEX_THREAD_ID`）？——三形态（注入/进程树/反查）先判型。
2. **数据源形态**：中心库（sqlite）还是文件（JSONL/JSON）？活跃位 + 归档位各在哪？有无根目录覆盖环境变量？
3. **记录类型全表**：遍历实际文件统计所有 type，别只看文档假设（dsh 实测 28 种，多数可跳过）。
4. **重复形态**：同一语义是否多记录形态并存（Codex 用户消息双形态）？选主形态，其余跳过。
5. **系统指令混入**：developer/system 角色或首条 user 消息是否携带系统指令？title 等派生字段要选干净数据源。
6. **字段派生**：无显式字段时（title/summary），从哪些记录可派生？派生规则写进 adapter。
7. **消息关联**：工具调用与返回如何关联（call_id / tool_use_id）？挂载到哪条消息？
8. **验证样本**：至少测活跃会话 + 归档会话各一，确认新旧格式兼容。

实现侧：identify 一个函数（框架检测 + ID 提取）+ resolve meta/content 各一个函数（记录 → 统一 parts 映射）+ list 枚举一段（会话发现 + mtime + 标题来源），注册到路由 case 即可。list 的标题来源与 meta 的 title 派生规则同源，勘察一次两处复用。
