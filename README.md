# session-resolver

跨 AI 编程客户端的会话身份与内容解析工具——一个 bash 脚本，两个能力：

- **identify**：在会话内部回答"我是哪个会话"（返回标准 ID）
- **resolve**：按 ID 读取会话的元数据与消息正文（返回 JSON）

支持 **Claude Code / Codex / dsh（DeepSeek Harness）/ ZCode** 四种客户端，统一 ID 格式、统一输出结构——你的脚本只写一份解析逻辑，不随框架分叉。

## 解决什么问题

同时用多个 AI 编程客户端（Claude Code + Codex + …）的工作流里，"会话"是每个客户端各自管理的：ID 格式不同、存储位置不同、记录格式不同。当你在做自动化——

- 会话里跑的脚本想知道"当前是哪个会话"（打日志、加锁、埋点）
- 工具想按 ID 读回某次会话的完整内容（上下文恢复、跨会话传递、分析）

——每个客户端都要单独适配一遍。session-resolver 把这层适配做完了：`identify` 一个命令拿标准 ID，`resolve` 一个命令拿统一结构的会话内容。

**与"会话历史查看器"类工具的差别**：查看器是给人看的（UI/HTML/导出），session-resolver 是给程序用的——输出 JSON、无交互、可嵌入脚本和 AI 工具链。查看器是浏览器，这个是 DNS。

## 安装

无构建、无依赖安装，单脚本即用：

```bash
git clone https://github.com/zhangweijian97/session-resolver.git
# 或只取脚本：
curl -O https://raw.githubusercontent.com/zhangweijian97/session-resolver/main/session-resolver.sh && chmod +x session-resolver.sh
```

依赖：`bash` + `python3`；查询 ZCode 会话需 `sqlite3`（macOS 自带）；查询 dsh 会话需 `zstd`（`brew install zstd`）。

AI 客户端技能体系用户：仓库内的 `SKILL.md` 可作为技能描述文件与脚本同目录安装（ZCode/OpenCode/Codex 等技能目录均可用）。

## 快速开始

```bash
# 1. 在任一已适配客户端的会话中（如让 AI 帮你跑）：
./session-resolver.sh identify
# → claude-code:bc3e96c7-a925-4c2e-ac9a-ccf181a3a388

# 2. 按标准 ID 查会话元数据：
./session-resolver.sh resolve meta claude-code:bc3e96c7-a925-4c2e-ac9a-ccf181a3a388
```

```json
{
  "id": "bc3e96c7-a925-4c2e-ac9a-ccf181a3a388",
  "title": "openclaw update │ ◇ Updating OpenClaw...",
  "time_created": 1781011620546,
  "time_updated": 1781011798037,
  "directory": "/Users/you/project",
  "message_count": 12,
  "cli_version": "2.1.90",
  "git_branch": "main",
  "slug": "harmonic-meandering-cerf"
}
```

```bash
# 3. 读消息正文（支持分段）：
./session-resolver.sh resolve content claude-code:bc3e96c7-... --limit 10 --offset 5
```

content 返回统一的消息序列，每条消息含 `role` / `time_created` / `parts`（正文片段数组）：

```json
[
  {
    "role": "user",
    "time_created": 1781011620546,
    "parts": [
      { "type": "text", "text": "帮我修复这个问题" }
    ]
  },
  {
    "role": "assistant",
    "time_created": 1781011798037,
    "parts": [
      { "type": "reasoning", "text": "先看日志……" },
      { "type": "text", "text": "问题在配置文件……" },
      { "type": "tool", "tool": "Bash", "call_id": "toolu_xxx",
        "status": "completed", "input": {"command": "cat config"}, "output": "..." }
    ]
  }
]
```

part 类型在所有框架间统一：`text`（正文）/ `reasoning`（模型推理）/ `tool`（工具调用+返回，同一对象内含 input/output）/ `file`。

## identify 的三种形态

每个客户端暴露会话身份的方式不同，实测归纳为三形态（适配新客户端时先问"是哪种"）：

| 形态 | 机制 | 实例 |
|------|------|------|
| **环境变量注入** | 客户端给子进程注入会话标识 | Codex（`CODEX_THREAD_ID`） |
| **进程树提取** | 会话 ID 出现在祖先进程命令行里 | ZCode（`sess_<uuid>`） |
| **存储层反查** | 无注入、进程树也没有——按 cwd 定位会话存储，取 mtime 最新 | dsh（workspace 注册表）、Claude Code（projects 目录） |

存储层反查的可靠性判据：identify 在活跃会话中调用，当前会话的记录文件刚被写入，mtime 几乎必然最新。

## 各客户端数据源（只读）

| 客户端 | 存储 | 说明 |
|--------|------|------|
| Claude Code | `~/.claude/projects/<cwd编码>/<sessionId>.jsonl` | 每会话一文件；sessionId/cwd/slug 冗余在每条记录；subagent 会话在 `subagents/` 子目录（暂不解析） |
| Codex | `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl`（+ `archived_sessions/`） | 平铺 JSONL；同一会话可跨文件续接；title 需派生 |
| dsh | `~/.dsh/sessions/<cwd编码>--/<session-uuid>/session.jsonl.zstd` | zstd 压缩；workspace 注册表在 `~/.dsh/storages/workspace.json` |
| ZCode | `~/.zcode/cli/db/db.sqlite` | sqlite 三表（session/message/part） |

session-resolver 只读不写，不改动任何客户端数据。各框架记录格式的实测细节（类型全表、重复形态、字段派生）见 [docs/adapters.md](docs/adapters.md)。

## 贡献新客户端适配

欢迎为其他客户端（Claude Code Desktop / Gemini CLI / Cursor …）贡献 adapter。适配方法已沉淀为一份 8 条勘察清单（会话 ID 来源 → 数据源形态 → 记录类型全表 → 重复形态 → 系统指令混入 → 字段派生 → 消息关联 → 验证样本），按清单勘察后实现 identify + resolve 两个函数即可，见 [docs/adapters.md](docs/adapters.md)。

## License

[MIT](LICENSE)
