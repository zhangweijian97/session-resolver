---
name: session-resolver
description: >
  会话身份适配器——跨智能体框架的会话 ID 标准化与解析工具。
  提供三个核心能力：identify（在会话中获取自己的标准 ID）、resolve（按 ID 查询会话内容）、
  list（枚举近期会话）。当需要获取当前会话 ID、跨会话读取历史会话内容（元数据/消息正文）、
  或扫近期会话清单（定时回看/异步反思入口）时触发。
version: 0.5.0
tags: [session, identity, resolver, zcode, codex, dsh, claude-code]
---

# session-resolver

会话身份适配器——跨智能体框架的会话 ID 标准化与解析工具。

## 核心能力

| 能力 | 命令 | 用途 |
|------|------|------|
| **identify** | `identify` | 在会话中获取当前会话的标准 ID |
| **resolve meta** | `resolve meta <id>` | 查询会话元数据（标题/时间/目录/摘要） |
| **resolve content** | `resolve content <id>` | 查询会话消息正文（角色+正文片段序列） |
| **list** | `list [--since 3d] [--framework ...]` | 枚举近期会话（标准 ID + 时间 + 标题，倒序） |

## 标准格式

```
<框架标识>:<该框架原生 session-id>

ZCode 示例: zcode:sess_bd2e826f-0932-48ec-8a03-0e7869f3bab8
Codex 示例: codex:019fc5c5-bf07-7c91-b165-9aa3ef8b2861
dsh 示例:   dsh:session-b52d2aa0-f5c7-41d5-b14e-57b607ea9285
Claude Code 示例: claude-code:bc3e96c7-a925-4c2e-ac9a-ccf181a3a388
```

resolve 时脚本自动解析前缀路由到对应框架的查询逻辑。已适配 `zcode:` + `codex:` + `dsh:` + `claude-code:` 前缀。

## 使用方法

> **脚本路径**：skill 包内同级的 `session-resolver.sh`（harness 加载本 skill 时提供包目录，脚本就在 SKILL.md 旁边）。

### identify — 获取当前会话 ID

```bash
SR=<部署位>/session-resolver.sh   # skill 安装者：包内与 SKILL.md 同级；独立安装：clone 仓库根
bash "$SR" identify
# 输出: zcode:sess_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# 或（Codex 环境）: codex:019fc5c5-bf07-7c91-b165-9aa3ef8b2861
```

**调用时机**：需要记录当前会话身份到目标卡、成长痕迹、HANDOFF 等跨会话载体时。

**实现原理**（ZCode）：
1. 从进程树（`ps -o command`）提取 `sess_<uuid>` 模式
2. 框架检测（环境变量 `ZCODE_APP_VERSION` / `ZCODE_ENV`）
3. 组合为标准格式输出

**实现原理**（Codex）：
1. 框架检测：环境变量 `CODEX_THREAD_ID` 存在 → codex
2. 提取 session-id：`CODEX_THREAD_ID` 主路径；兜底进程树 `--session-id <uuid>` 模式 / 最新 rollout 文件名
3. 组合为标准格式输出

**实现原理**（dsh / DeepSeek Harness）：
1. 框架检测：进程树含 dsh 常驻 server（`@deepseek-ai/dsh` / `dsh web`）→ dsh（无环境变量注入）
2. 提取 session-id：`~/.dsh/storages/workspace.json`（workspace path → sessionIds 注册表）按 `$PWD` 匹配 → 候选中取 `session.jsonl.zstd` mtime 最新者；cwd 匹配不上时回退全部 session 中最新；无 workspace.json 时全局扫描最新
3. 组合为标准格式输出

**实现原理**（Claude Code）：
1. 框架检测：环境变量 `CLAUDECODE` 非空 → claude-code（Claude Code 注入此标记但不注入 sessionId）
2. 提取 session-id（存储层反查，与 dsh 同构）：正向编码 `$PWD` → `~/.claude/projects/<编码>/` 目录下 mtime 最新的 `<uuid>.jsonl` 文件名；编码目录不存在时回退全局顶层 jsonl mtime 最新（深度 2 天然排除 `subagents/`）
3. 组合为标准格式输出

框架检测顺序：显式框架环境变量（zcode / codex / claude-code）→ 进程树探测（sess_ → zcode；--session-id → codex；dsh server → dsh）。

### resolve meta — 查询会话元数据

```bash
bash "$SR" resolve meta zcode:sess_xxx
# Codex: bash "$SR" resolve meta codex:019fc5c5-bf07-7c91-b165-9aa3ef8b2861
```

返回 JSON：

```json
{
  "id": "sess_xxx",
  "title": "目标实现",
  "time_created": 1783769777904,
  "directory": "/Users/.../研发项目",
  "path": "",
  "summary_files": 3,
  "summary_additions": 150,
  "summary_deletions": 20,
  "time_updated": 1783770000000
}
```

**调用时机**：目标卡上记录了多个 session-id，先扫元数据判断哪段值得深入。

**Codex meta 字段**：`id` / `title`（派生：首条用户消息截断）/ `time_created` / `directory`（cwd）/ `path` / `message_count` / `time_updated` / `originator` / `cli_version` / `source` / `model_provider`。

**dsh meta 字段**：`id` / `title`（显式：`session/title` 记录，无需派生）/ `time_created` / `time_updated` / `directory`（cwd）/ `path` / `model` / `provider` / `message_count`。

**Claude Code meta 字段**：`id` / `title`（派生：首条用户文本消息截断，slug 兜底）/ `time_created` / `time_updated` / `directory`（cwd）/ `path` / `message_count` / `cli_version` / `git_branch` / `slug`。

### resolve content — 查询会话消息正文

```bash
bash "$SR" resolve content zcode:sess_xxx
# 可选分段：
bash "$SR" resolve content zcode:sess_xxx --limit 10 --offset 5
```

返回 JSON 数组，每条消息含角色和正文片段：

```json
[
  {
    "role": "user",
    "time_created": 1783769777906,
    "parts": [
      {"type": "text", "text": "目标实现"}
    ]
  },
  {
    "role": "assistant",
    "time_created": 1783769780000,
    "parts": [
      {"type": "text", "text": "..."},
      {"type": "reasoning", "text": "..."},
      {"type": "tool", "tool": "Bash", "status": "completed", "input": {...}, "output": "..."}
    ]
  }
]
```

**part 类型说明**：

| type | 内容 | 说明 |
|------|------|------|
| `text` | 文本正文 | 用户输入或 AI 回复的文本 |
| `tool` | 工具调用+返回 | 统一类型，含 `tool`（工具名）+ `state.input`（调用参数）+ `state.output`（返回结果） |
| `reasoning` | 模型推理过程 | AI 的思考链 |
| `file` | 文件引用 | 用户上传的文件（filename + url） |
| `step-start`/`step-finish` | 步骤标记 | 已过滤，不返回 |

**Codex 数据形态**：`output_text`/`input_text` → `text`；`reasoning_text` → `reasoning`；`function_call` → `tool`（input 为 JSON 解析后的参数）；`function_call_output` 按 call_id 补全 tool 的 status/output。用户消息在 rollout 中双形态存在（response_item + event_msg user_message），解析取 response_item，event_msg 跳过；developer role（系统指令）过滤。

**dsh 数据形态**：主形态记录 `user/message` + `assistant/message`（后者 content 内嵌 text / reasoning / tool-call）；`tool/result` 按 callId 补全 tool 的 status/output。跳过流式 chunk 记录（assistant/chunk、reasoning-chunks 等，与完整形态重复）、`agent/inbox/spliced`（与 user/message 重复）、`tool/call`（与内嵌 tool-call 重复）、step/turn 标记。注意：dsh 的 runtime context 快照以 user/message 形态混入（文本以 "Current runtime context." 开头），非真实用户输入——按纯数据层原则不过滤，调用方提炼时自行识别。

**Claude Code 数据形态**：`user`/`assistant` 记录的 `message.content` 为 Anthropic API 形态（str 或 parts 数组）：`text` → `text`；`thinking` → `reasoning`；`tool_use`/`server_tool_use` → `tool`（pending）；`tool_result`/`server_tool_result` 按 `tool_use_id` 跨消息回填对应 tool part 的 status/output（不生成新 part）。跳过 `progress`/`file-history-snapshot`/`queue-operation`/`last-prompt`/`system` 等非对话 type；纯 tool_result 的 user 消息回填后无残余 part，不产出空消息。命令包装文本（`<local-command-caveat>` 等）按纯数据层不过滤。

**调用时机**：需要读取历史会话内容做上下文恢复、跨会话知识传递、或 subagent 提炼。

### list — 枚举近期会话

```bash
bash "$SR" list --since 3d                     # 全部框架，近 3 天
bash "$SR" list --since 12h --framework zcode  # 单框架，近 12 小时
bash "$SR" list --framework zcode,dsh          # 多框架（逗号分隔）
```

输出一行一条（制表符分隔），跨框架合并按最后活动时间倒序：

```
zcode:sess_xxx	2026-08-18 10:38	实施 session-resolver list 命令
dsh:session-yyy	2026-08-17 22:33	验证dsh会话解析器适配
```

- `--since`：`3d` / `12h` / `30m`，可组合（`1d12h`）；不传 = 全量
- `--framework`：`zcode|codex|dsh|claude-code` 逗号分隔多值；不传 = 全部框架合并
- 时间语义：zcode 用 session 表 `time_updated`，其余框架用会话文件 mtime
- 单框架容错：某框架数据根不存在（未安装该框架）或 dsh 的 zstd 缺失 → stderr 警告后跳过，不阻断其他框架

**调用时机**：定时扫描近期会话回看（收集卡补录）、异步反思找"最近发生了什么"的入口——先 list 拿清单，再对值得深入的会话 resolve meta/content。

## 数据源

**ZCode**：`~/.zcode/cli/db/db.sqlite`（session / message / part 三表）

- `session` 表：会话元数据
- `message` 表：消息级元数据（`data` JSON 字段含 `role`）
- `part` 表：消息正文片段（`data` JSON 字段含 `type` + 正文）

**只读查询**——session-resolver 不写入数据库，数据库的归档由 ZCode 框架负责。

**Codex**：`~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<时间戳>-<thread-id>.jsonl`（活跃）+ `~/.codex/archived_sessions/`（归档，平铺同命名）

- rollout 为 JSONL，记录类型：`session_meta`（会话元数据）、`response_item`（消息/工具调用/工具返回）、`event_msg`（事件，user_message 与 response_item 重复，跳过）
- 会话 ID = thread-id（环境变量 `CODEX_THREAD_ID`），同一会话可跨多个 rollout 文件（续接，按文件名排序合并）
- `CODEX_HOME` 环境变量可覆盖数据根目录（默认 `~/.codex`）

**dsh**：`~/.dsh/sessions/<cwd编码>--/<session-uuid>/session.jsonl.zstd`（zstd 压缩 JSONL，每会话一目录）

- 会话注册表：`~/.dsh/storages/workspace.json`（workspace path → sessionIds 映射，identify 主路径）
- 首行 `session` 记录含 id/createdAt/cwd（顶层字段，不在 data 内）；title 为显式 `session/title` 记录
- 解压依赖 `zstd` 命令（brew install zstd）
- `DSH_HOME` 环境变量可覆盖数据根目录（默认 `~/.dsh`）

**Claude Code**：`~/.claude/projects/<cwd编码>/<sessionId>.jsonl`（每会话一文件，文件名=sessionId）

- 目录编码：`/` → `-`、非 ASCII 字符 → `-`（1 字符 → 1 个 `-`）、空格 → `-`，ASCII 保留
- sessionId/cwd/version/gitBranch/slug 冗余在每条记录（无独立 meta 记录）；subagent 会话存于 `<sessionId>/subagents/` 子目录，MVP 不解析
- 无 title 显式记录，title 派生（首条用户消息截断，slug 兜底）
- `CLAUDE_CONFIG_DIR` 环境变量可覆盖数据根目录（默认 `~/.claude`）

**只读查询**——session-resolver 不写入任何框架数据源，归档由各框架负责。

## 定位与边界

- **纯数据层**：不启动 session，只被 session 调用。resolve 返回素材，提炼是调用方职责
- **框架解耦**：接口用 `<框架>:<id>` 标准格式，不过早设计跨框架架构
- **只读工具**：不产生持久化数据，无运行时数据退役问题

## 脚本路径

脚本与 SKILL.md 同级，位于 skill 包内：

- skill 安装者：`<skill 安装目录>/session-resolver/session-resolver.sh`
- 独立安装（不开 skill 体系）：clone 仓库后位于仓库根 `session-resolver.sh`

脚本随 skill 包一起分发，不独立部署。
