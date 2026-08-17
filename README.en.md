# session-resolver

Cross-client session identity & content resolver for AI coding CLIs — one bash script, two capabilities:

- **identify**: answer "which session am I in" from inside a session (returns a standard ID)
- **resolve**: read a session's metadata and message content by ID (returns JSON)

Supports **Claude Code / Codex / dsh (DeepSeek Harness) / ZCode** with a unified ID format and unified output structure — your script parses one format, regardless of which client produced the session.

## The Problem

In workflows that run multiple AI coding CLIs (Claude Code + Codex + …), each client manages its own sessions: different ID formats, different storage locations, different record schemas. When you automate —

- a script running inside a session wants to know "which session is this" (logging, locking, attribution)
- a tool wants to read a session's full content by ID (context restore, cross-session handoff, analysis)

— you end up writing a separate adapter for every client. session-resolver ships that adapter layer: one command for a standard ID, one command for uniformly structured session content.

**How it differs from "session history viewers"**: viewers are built for humans (UI / HTML / export). session-resolver is built for programs — JSON output, non-interactive, embeddable in scripts and AI toolchains. Viewers are the browser; this is the DNS.

## Install

No build, no install step — a single script:

```bash
git clone https://github.com/<user>/session-resolver.git
# or just the script:
curl -O https://raw.githubusercontent.com/<user>/session-resolver/main/session-resolver.sh && chmod +x session-resolver.sh
```

Dependencies: `bash` + `python3`; ZCode queries need `sqlite3` (bundled on macOS); dsh queries need `zstd` (`brew install zstd`). CLI messages are in Chinese (the project's primary audience is Chinese-speaking; contributions to localize messages are welcome).

Skill-system users (ZCode/OpenCode/Codex etc.): install `SKILL.md` alongside the script as the skill manifest.

## Quick Start

```bash
# 1. Inside any supported client session (e.g. ask the AI to run it):
./session-resolver.sh identify
# → claude-code:bc3e96c7-a925-4c2e-ac9a-ccf181a3a388

# 2. Session metadata by standard ID:
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
# 3. Message content (with optional paging):
./session-resolver.sh resolve content claude-code:bc3e96c7-... --limit 10 --offset 5
```

content returns a unified message sequence; each message carries `role` / `time_created` / `parts`:

```json
[
  {
    "role": "user",
    "time_created": 1781011620546,
    "parts": [
      { "type": "text", "text": "help me fix this" }
    ]
  },
  {
    "role": "assistant",
    "time_created": 1781011798037,
    "parts": [
      { "type": "reasoning", "text": "check the logs first..." },
      { "type": "text", "text": "the issue is in the config..." },
      { "type": "tool", "tool": "Bash", "call_id": "toolu_xxx",
        "status": "completed", "input": {"command": "cat config"}, "output": "..." }
    ]
  }
]
```

Part types are uniform across clients: `text` / `reasoning` / `tool` (call + result in one object: input/output) / `file`.

## The Three Shapes of identify

Clients expose session identity differently; field-tested into three shapes (ask "which shape" first when adapting a new client):

| Shape | Mechanism | Example |
|------|-----------|---------|
| **env injection** | client injects a session identifier into child processes | Codex (`CODEX_THREAD_ID`) |
| **process tree** | session ID appears in an ancestor's command line | ZCode (`sess_<uuid>`) |
| **storage back-query** | no injection, no process-tree trace — locate session storage by cwd, take newest mtime | dsh (workspace registry), Claude Code (projects dir) |

Why the back-query works: identify runs inside the live session, whose record file was just written — its mtime is almost certainly the newest.

## Data Sources (read-only)

| Client | Storage | Notes |
|--------|---------|-------|
| Claude Code | `~/.claude/projects/<cwd-encoded>/<sessionId>.jsonl` | one file per session; sessionId/cwd/slug redundant on every record; subagent sessions under `subagents/` (not parsed yet) |
| Codex | `~/.codex/sessions/<Y>/<M>/<D>/rollout-*.jsonl` (+ `archived_sessions/`) | flat JSONL; one session may span files; title derived |
| dsh | `~/.dsh/sessions/<cwd-encoded>--/<session-uuid>/session.jsonl.zstd` | zstd-compressed; workspace registry at `~/.dsh/storages/workspace.json` |
| ZCode | `~/.zcode/cli/db/db.sqlite` | sqlite, three tables (session/message/part) |

session-resolver is strictly read-only. Field-tested format details (type tables, duplicate shapes, derived fields) per client: [docs/adapters.md](docs/adapters.md).

## Contributing New Adapters

Adapters for other clients (Gemini CLI / Cursor / …) are welcome. The method is distilled into an 8-item fieldwork checklist (session ID source → storage shape → record-type table → duplicate shapes → system-prompt contamination → derived fields → message linkage → verification samples); implement identify + resolve per client. See [docs/adapters.md](docs/adapters.md).

## License

[MIT](LICENSE)
