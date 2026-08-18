#!/usr/bin/env bash
# session-resolver.sh — 会话身份适配器（identify + resolve）
# 跨智能体框架的会话 ID 标准化与解析工具
# 已适配: ZCode + Codex + dsh(DeepSeek Harness) + Claude Code

set -euo pipefail

# ─── 常量 ────────────────────────────────────────────

readonly VERSION="0.5.0"
readonly ZCODE_DB="${HOME}/.zcode/cli/db/db.sqlite"
readonly CODEX_ROOT="${CODEX_HOME:-${HOME}/.codex}"
readonly CODEX_SESSIONS="${CODEX_ROOT}/sessions"
readonly CODEX_ARCHIVED="${CODEX_ROOT}/archived_sessions"
readonly DSH_ROOT="${DSH_HOME:-${HOME}/.dsh}"
readonly DSH_SESSIONS="${DSH_ROOT}/sessions"
readonly DSH_WORKSPACE_JSON="${DSH_ROOT}/storages/workspace.json"
readonly CLAUDE_ROOT="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
readonly CLAUDE_PROJECTS="${CLAUDE_ROOT}/projects"

# ─── 工具函数 ────────────────────────────────────────

die() {
  echo "❌ $*" >&2
  exit 1
}

# 检查 sqlite3 是否可用
check_sqlite3() {
  command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 未安装"
}

# 检查 zstd 是否可用（dsh 会话文件为 zstd 压缩 JSONL）
check_zstd() {
  command -v zstd >/dev/null 2>&1 || die "zstd 未安装（dsh 会话解析需要，brew install zstd）"
}

# 检查 ZCode 数据库是否存在
check_db() {
  [[ -f "$ZCODE_DB" ]] || die "ZCode 数据库不存在: $ZCODE_DB"
}

# 去掉标准 ID 的框架前缀，返回纯 session-id
# 输入: zcode:sess_xxx → 输出: sess_xxx
# 输入: sess_xxx        → 输出: sess_xxx
strip_prefix() {
  local id="$1"
  # 如果含冒号，取冒号后部分
  if [[ "$id" == *:* ]]; then
    echo "${id#*:}"
  else
    echo "$id"
  fi
}

# 从标准 ID 提取框架前缀
# 输入: zcode:sess_xxx → 输出: zcode
# 输入: sess_xxx        → 输出: (空)
get_framework_prefix() {
  local id="$1"
  if [[ "$id" == *:* ]]; then
    echo "${id%%:*}"
  else
    echo ""
  fi
}

# ─── identify ────────────────────────────────────────

# 检测当前所在框架（环境变量优先，进程树探测兜底）
detect_framework() {
  # 显式框架环境变量
  if [[ -n "${ZCODE_APP_VERSION:-}" || -n "${ZCODE_ENV:-}" ]]; then
    echo "zcode"
    return
  fi
  if [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    echo "codex"
    return
  fi
  if [[ -n "${CLAUDECODE:-}" ]]; then
    echo "claude-code"
    return
  fi

  # 进程树探测（$$ 向上找祖先进程）
  local pid=$$ cmds=""
  for _ in $(seq 1 10); do
    cmds+="$(ps -o command -p "$pid" 2>/dev/null | tail -1)$(printf '\n')" || true
    local ppid
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || true
    [[ -z "$ppid" || "$ppid" == "0" || "$ppid" == "1" ]] && break
    pid="$ppid"
  done
  if [[ "$cmds" =~ sess_[a-f0-9-]+ ]]; then
    echo "zcode"
    return
  fi
  if printf '%s' "$cmds" | grep -qE -- '--session-id[ =][ ]*[a-f0-9-]+'; then
    echo "codex"
    return
  fi
  # dsh web 常驻 server（npm exec @deepseek-ai/dsh web / node .../bin/dsh web）
  if printf '%s' "$cmds" | grep -qE '(@deepseek-ai/dsh|[/.]dsh web)'; then
    echo "dsh"
    return
  fi
  echo ""
}

# dsh 实现：workspace.json（cwd→sessionIds 注册表）主路径 + 会话目录 mtime 最新兜底
# dsh 是 web 常驻 server，进程树不含 session-id，靠存储层反查
identify_dsh() {
  [[ -d "$DSH_SESSIONS" ]] || die "dsh 会话目录不存在: $DSH_SESSIONS"

  local session_id=""
  if [[ -f "$DSH_WORKSPACE_JSON" ]]; then
    session_id=$(python3 - "$DSH_WORKSPACE_JSON" "$DSH_SESSIONS" "$PWD" <<'PY' || true
import json, os, sys

ws_json, root, pwd = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(ws_json) as f:
        doc = json.load(f)
except Exception:
    sys.exit(0)

def mtime_of(sid):
    # session 目录形如 <root>/<cwd编码>--/<sid>/session.jsonl.zstd
    for base in os.listdir(root):
        p = os.path.join(root, base, sid)
        if os.path.isdir(p):
            f = os.path.join(p, "session.jsonl.zstd")
            return os.path.getmtime(f) if os.path.isfile(f) else -1
    return -1

# 主路径：cwd 精确匹配 workspace；其次 cwd 在某 workspace 之下（agent 可能 cd 到子目录）
workspaces = doc.get("tables", {}).get("workspaces", {})
cands = []
for ws in workspaces.values():
    path = (ws.get("path") or "").rstrip("/")
    if path and (pwd == path or pwd.startswith(path + "/")):
        cands.extend(ws.get("sessionIds", []))
if not cands:
    # 兜底1：workspace 匹配不上（agent 在 workspace 外跑命令）→ 全部 session 中 mtime 最新
    cands = [sid for ws in workspaces.values() for sid in ws.get("sessionIds", [])]
cands = [(mtime_of(sid), sid) for sid in set(cands)]
cands = [x for x in cands if x[0] >= 0]
if not cands:
    sys.exit(0)
# identify 在活跃会话中调用，当前会话 JSONL 刚被写入 → mtime 最新者即当前会话
print(max(cands)[1])
PY
)
  fi

  # 兜底2：无 workspace.json → 全局扫描 mtime 最新的 session 目录
  if [[ -z "$session_id" ]]; then
    session_id=$(python3 - "$DSH_SESSIONS" <<'PY' || true
import os, sys
root = sys.argv[1]
best, best_m = None, -1
try:
    for base in os.listdir(root):
        wsd = os.path.join(root, base)
        if not os.path.isdir(wsd):
            continue
        for sid in os.listdir(wsd):
            f = os.path.join(wsd, sid, "session.jsonl.zstd")
            if os.path.isfile(f):
                m = os.path.getmtime(f)
                if m > best_m:
                    best, best_m = sid, m
except Exception:
    pass
if best:
    print(best)
PY
)
  fi

  [[ -n "$session_id" ]] || die "无法识别当前 dsh 会话 ID（workspace.json 无匹配且会话目录为空？）"
  echo "$session_id"
}

# Claude Code 实现：正向编码 cwd → projects/<编码>/ mtime 最新反查 + 全局兜底
# Claude Code 注入 CLAUDECODE=1 但不注入 sessionId（进程树也不含），走存储层反查（与 dsh 同构）
identify_claude() {
  [[ -d "$CLAUDE_PROJECTS" ]] || die "Claude Code 会话目录不存在: $CLAUDE_PROJECTS"

  local session_id
  session_id=$(python3 - "$CLAUDE_PROJECTS" "$PWD" <<'PY' || true
import os, sys

root, pwd = sys.argv[1], sys.argv[2]

def encode(path):
    # 目录编码：'/' → '-'、非 ASCII 字符 → '-'（1 字符 → 1 个 '-'）、空格 → '-'，ASCII 保留
    out = []
    for ch in path:
        if ord(ch) < 128 and ch not in ('/', ' '):
            out.append(ch)
        else:
            out.append('-')
    return ''.join(out)

def latest_jsonl(dirpath):
    best, best_m = None, -1
    try:
        for name in os.listdir(dirpath):
            p = os.path.join(dirpath, name)
            if os.path.isfile(p) and name.endswith('.jsonl'):
                m = os.path.getmtime(p)
                if m > best_m:
                    best, best_m = name[:-len('.jsonl')], m
    except Exception:
        pass
    return best

# 主路径：正向编码 cwd → 目录下 mtime 最新（identify 在活跃会话中调用，当前会话刚被写入）
sid = latest_jsonl(os.path.join(root, encode(pwd)))
if not sid:
    # 兜底：编码目录不存在（编码规则漂移/agent 在 workspace 外）→ 全局顶层 jsonl mtime 最新
    # （仅扫 projects/<dir>/*.jsonl，天然排除 <sid>/subagents/ 深层文件）
    best, best_m = None, -1
    for d in os.listdir(root):
        dp = os.path.join(root, d)
        if not os.path.isdir(dp):
            continue
        cand = latest_jsonl(dp)
        if cand:
            p = os.path.join(dp, cand + '.jsonl')
            m = os.path.getmtime(p)
            if m > best_m:
                best, best_m = cand, m
    sid = best
if sid:
    print(sid)
PY
)
  [[ -n "$session_id" ]] || die "无法识别当前 Claude Code 会话 ID（projects 下无会话文件？）"
  echo "$session_id"
}

# 在会话中获取当前会话的标准 ID
# ZCode 实现：从进程树提取 sess_<uuid> + 环境变量检测框架
# Codex 实现：CODEX_THREAD_ID 主路径 + 进程树/rollout 文件名兜底
# dsh 实现：进程树检测框架 + workspace.json/mtime 反查 session
identify() {
  local session_id=""
  local framework
  framework=$(detect_framework)

  case "$framework" in
    codex)
      # 主路径：环境变量注入
      session_id="${CODEX_THREAD_ID:-}"
      # 兜底1：进程树 --session-id <uuid> 模式
      if [[ -z "$session_id" ]]; then
        session_id=$(ps -eo command 2>/dev/null \
          | grep -oE -- '--session-id[ =][ ]*[a-f0-9-]{10,}' | head -1 \
          | grep -oE '[a-f0-9-]{10,}' || true)
      fi
      # 兜底2：最新 rollout 文件名中的 uuid
      if [[ -z "$session_id" ]]; then
        session_id=$(find "$CODEX_SESSIONS" "$CODEX_ARCHIVED" \
          -name 'rollout-*.jsonl' -type f -print0 2>/dev/null \
          | xargs -0 ls -t 2>/dev/null | head -1 \
          | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' || true)
      fi
      if [[ -z "$session_id" ]]; then
        die "无法识别当前 Codex 会话 ID（CODEX_THREAD_ID 未注入且进程树无 session-id）"
      fi
      echo "codex:${session_id}"
      ;;

    dsh)
      session_id=$(identify_dsh)
      echo "dsh:${session_id}"
      ;;

    claude-code)
      session_id=$(identify_claude)
      echo "claude-code:${session_id}"
      ;;

    zcode)
      # 方法1：从当前进程命令行提取
      # $$ 是当前 shell 的 PID，向上查找含 sess_ 的进程
      local pid=$$
      for _ in $(seq 1 10); do
        local cmd
        cmd=$(ps -o command -p "$pid" 2>/dev/null | tail -1) || true
        if [[ "$cmd" =~ sess_[a-f0-9-]+ ]]; then
          session_id="${BASH_REMATCH[0]}"
          break
        fi
        # 向上找父进程
        local ppid
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || true
        [[ -z "$ppid" || "$ppid" == "0" || "$ppid" == "1" ]] && break
        pid="$ppid"
      done

      # 方法2：环境变量（ZCode 会注入）
      if [[ -z "$session_id" ]]; then
        local env_session
        env_session="${ZCODE_SESSION_ID:-${SESSION_ID:-}}"
        if [[ "$env_session" =~ sess_[a-f0-9-]+ ]]; then
          session_id="${BASH_REMATCH[0]}"
        fi
      fi

      # 方法3：PPID 链路扫描（兜底，扫描更广的进程树）
      if [[ -z "$session_id" ]]; then
        local all_cmds
        all_cmds=$(ps -eo command 2>/dev/null | grep -oE 'sess_[a-f0-9-]+' | head -1) || true
        if [[ -n "$all_cmds" ]]; then
          session_id="$all_cmds"
        fi
      fi

      if [[ -z "$session_id" ]]; then
        die "无法识别当前会话 ID（不在 ZCode 会话环境中？）"
      fi
      echo "zcode:${session_id}"
      ;;

    *)
      die "无法识别当前会话 ID（不在已适配框架 ZCode/Codex/dsh/Claude Code 会话环境中？）"
      ;;
  esac
}

# ─── resolve: meta ──────────────────────────────────

# 按框架前缀路由
resolve_meta() {
  local raw_id="$1"
  local session_id
  session_id=$(strip_prefix "$raw_id")

  local framework
  framework=$(get_framework_prefix "$raw_id")
  case "$framework" in
    claude-code) resolve_meta_claude "$session_id" ;;
    codex) resolve_meta_codex "$session_id" ;;
    dsh) resolve_meta_dsh "$session_id" ;;
    zcode|"") resolve_meta_zcode "$session_id" ;;
    *) die "框架 '$framework' 未适配（已适配: zcode, codex, dsh, claude-code）" ;;
  esac
}

# ZCode 实现：查询 sqlite session 表
# 返回 JSON: { id, title, time_created, directory, summary_* }
resolve_meta_zcode() {
  local session_id="$1"

  check_sqlite3
  check_db

  # 查询 session 表
  local result
  result=$(sqlite3 "$ZCODE_DB" -json -separator $'\t' \
    "SELECT
       id,
       title,
       time_created,
       directory,
       path,
       summary_files,
       summary_additions,
       summary_deletions,
       time_updated
     FROM session
     WHERE id = '${session_id}'
     LIMIT 1;") || die "查询失败: ${session_id}"

  if [[ -z "$result" || "$result" == "[]" ]]; then
    die "会话不存在: ${session_id}"
  fi

  # sqlite3 -json 已返回 JSON 数组，取第一个元素
  echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if not data:
    print('{}')
else:
    row = data[0]
    print(json.dumps({
        'id': row['id'],
        'title': row['title'],
        'time_created': row['time_created'],
        'directory': row['directory'],
        'path': row.get('path') or '',
        'summary_files': row.get('summary_files') or 0,
        'summary_additions': row.get('summary_additions') or 0,
        'summary_deletions': row.get('summary_deletions') or 0,
        'time_updated': row['time_updated']
    }, ensure_ascii=False, indent=2))
"
}

# Codex 实现：解析 rollout JSONL 的 session_meta 记录
# 返回 JSON: { id, title(派生), time_created, directory, path, message_count, time_updated, originator, cli_version, source, model_provider }
resolve_meta_codex() {
  local session_id="$1"
  local paths
  paths=$(find_codex_rollouts "$session_id")

  python3 - "$session_id" "$paths" <<'PY'
import json, sys
from datetime import datetime

paths = [line for line in sys.argv[2].splitlines() if line.strip()]
sid = sys.argv[1]

def ts_ms(iso):
    if not iso:
        return None
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

meta = None
first_user = ""
msg_count = 0
timestamps = []

for path in paths:
    with open(path) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            t = rec.get("type")
            p = rec.get("payload") or {}
            if t == "session_meta":
                if meta is None or (p.get("timestamp", "") or "") < (meta.get("timestamp", "") or ""):
                    meta = p
                if p.get("timestamp"):
                    timestamps.append(p["timestamp"])
            elif t == "event_msg" and p.get("type") == "user_message":
                # user_message 是用户输入的干净文本（response_item role=user 常混入系统指令块）
                if not first_user and str(p.get("message", "")).strip():
                    first_user = str(p["message"]).strip().replace("\n", " ")[:80]
            elif t == "response_item" and p.get("type") == "message" and p.get("role") in ("user", "assistant"):
                msg_count += 1
            if rec.get("timestamp"):
                timestamps.append(rec["timestamp"])

if meta is None:
    sys.stderr.write(f"Codex 会话无 session_meta 记录: {sid}\n")
    sys.exit(1)

ts_sorted = sorted([ts_ms(t) for t in timestamps if ts_ms(t)])
print(json.dumps({
    "id": sid,
    "title": first_user or sid,
    "time_created": ts_ms(meta.get("timestamp")) or (ts_sorted[0] if ts_sorted else None),
    "directory": meta.get("cwd", ""),
    "path": paths[0],
    "message_count": msg_count,
    "time_updated": ts_sorted[-1] if ts_sorted else None,
    "originator": meta.get("originator", ""),
    "cli_version": meta.get("cli_version", ""),
    "source": meta.get("source", ""),
    "model_provider": meta.get("model_provider", ""),
}, ensure_ascii=False, indent=2))
PY
}

# 定位 Codex 会话的 rollout 文件（活跃位 + 归档位）
find_codex_rollouts() {
  local session_id="$1"
  local found
  found=$(find "$CODEX_SESSIONS" "$CODEX_ARCHIVED" \
    -name "rollout-*-${session_id}.jsonl" -type f 2>/dev/null | sort)
  if [[ -z "$found" ]]; then
    die "Codex 会话不存在: ${session_id}"
  fi
  echo "$found"
}

# 定位 dsh 会话目录（~/.dsh/sessions/<cwd编码>--/<session-uuid>/）
find_dsh_session() {
  local session_id="$1"
  # 兼容裸 uuid：无 session- 前缀时补上（原生 id 形态为 session-<uuid>）
  if [[ "$session_id" != session-* ]]; then
    session_id="session-${session_id}"
  fi
  local found
  found=$(find "$DSH_SESSIONS" -mindepth 2 -maxdepth 2 -type d -name "$session_id" 2>/dev/null | head -1)
  if [[ -z "$found" ]]; then
    die "dsh 会话不存在: ${session_id}"
  fi
  echo "$found"
}

# dsh 实现：解析 session.jsonl.zstd（zstd 压缩 JSONL）
# 返回 JSON: { id, title(session/title 显式记录), time_created, time_updated, directory, path, model, provider, message_count }
# 关键差异：session 记录的 id/createdAt/cwd 是顶层字段（不在 data 内）；title 有显式记录无需派生
resolve_meta_dsh() {
  local session_id="$1"
  local sess_dir
  sess_dir=$(find_dsh_session "$session_id")

  check_zstd

  python3 - "$session_id" "$sess_dir" <<'PY'
import json, os, subprocess, sys

sid, sess_dir = sys.argv[1], sys.argv[2]
zf = os.path.join(sess_dir, "session.jsonl.zstd")
proc = subprocess.Popen(["zstd", "-dc", zf], stdout=subprocess.PIPE, text=True)

meta = None
title = ""
model = ""
provider = ""
msg_count = 0
last_time = None
first_user = ""

for line in proc.stdout:
    try:
        rec = json.loads(line)
    except Exception:
        continue
    t = rec.get("type")
    d = rec.get("data") or {}
    if t == "session" and meta is None:
        meta = rec  # id/createdAt/cwd 在顶层
    elif t == "session/title":
        title = d.get("title") or title
    elif t == "request/context":
        if not model:
            model = d.get("model", "")
            provider = d.get("provider", "")
    elif t == "user/message":
        msg_count += 1
        if not first_user:
            for c in (d.get("content") or []):
                if c.get("type") == "text" and str(c.get("text", "")).strip():
                    first_user = str(c["text"]).strip().replace("\n", " ")[:80]
                    break
    elif t == "assistant/message":
        msg_count += 1
    if rec.get("time"):
        last_time = max(last_time or 0, rec["time"])

if meta is None:
    sys.stderr.write(f"dsh 会话无 session 记录: {sid}\n")
    sys.exit(1)

print(json.dumps({
    "id": meta.get("id", sid),
    "title": title or first_user or sid,
    "time_created": meta.get("createdAt"),
    "time_updated": last_time,
    "directory": meta.get("cwd", ""),
    "path": os.path.join(sess_dir, "session.jsonl.zstd"),
    "model": model,
    "provider": provider,
    "message_count": msg_count,
}, ensure_ascii=False, indent=2))
PY
}

# 定位 Claude Code 主会话文件（projects/<cwd编码>/<sessionId>.jsonl；深度 2 排除 subagents/）
find_claude_session() {
  local session_id="$1"
  local found
  found=$(find "$CLAUDE_PROJECTS" -mindepth 2 -maxdepth 2 -name "${session_id}.jsonl" -type f 2>/dev/null | head -1)
  if [[ -z "$found" ]]; then
    die "Claude Code 会话不存在: ${session_id}"
  fi
  echo "$found"
}

# Claude Code 实现：解析 projects/<dir>/<sessionId>.jsonl
# 无独立 session_meta 记录——sessionId/cwd/version/gitBranch/slug 冗余在每条记录，从首条对话记录取
# 返回 JSON: { id, title(首条用户消息派生，slug 兜底), time_created, time_updated, directory, path, message_count, cli_version, git_branch, slug }
resolve_meta_claude() {
  local session_id="$1"
  local path
  path=$(find_claude_session "$session_id")

  python3 - "$session_id" "$path" <<'PY'
import json, sys
from datetime import datetime

sid, path = sys.argv[1], sys.argv[2]

def ts_ms(iso):
    if not iso:
        return None
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

first = None
last_ts = None
slug = ""
first_user = ""
msg_count = 0

with open(path) as fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except Exception:
            continue
        t = rec.get("type")
        if t not in ("user", "assistant"):
            continue
        if first is None:
            first = rec
        if not slug and rec.get("slug"):
            slug = rec["slug"]
        if rec.get("timestamp"):
            last_ts = rec["timestamp"]
        msg_count += 1
        if t == "user" and not first_user:
            m = rec.get("message") or {}
            c = m.get("content")
            if isinstance(c, str) and c.strip():
                first_user = c.strip().replace("\n", " ")[:80]
            elif isinstance(c, list):
                for p in c:
                    if isinstance(p, dict) and p.get("type") == "text" and str(p.get("text", "")).strip():
                        first_user = str(p["text"]).strip().replace("\n", " ")[:80]
                        break

if first is None:
    sys.stderr.write(f"Claude Code 会话无对话记录: {sid}\n")
    sys.exit(1)

print(json.dumps({
    "id": sid,
    "title": first_user or slug or sid,
    "time_created": ts_ms(first.get("timestamp")),
    "time_updated": ts_ms(last_ts),
    "directory": first.get("cwd", ""),
    "path": path,
    "message_count": msg_count,
    "cli_version": first.get("version", ""),
    "git_branch": first.get("gitBranch", ""),
    "slug": slug,
}, ensure_ascii=False, indent=2))
PY
}

# ─── resolve: content ───────────────────────────────

# 按框架前缀路由
resolve_content() {
  local raw_id="$1"
  shift

  # 可选参数
  local limit=""
  local offset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  local session_id
  session_id=$(strip_prefix "$raw_id")

  local framework
  framework=$(get_framework_prefix "$raw_id")
  case "$framework" in
    claude-code) resolve_content_claude "$session_id" --limit "$limit" --offset "$offset" ;;
    codex) resolve_content_codex "$session_id" --limit "$limit" --offset "$offset" ;;
    dsh) resolve_content_dsh "$session_id" --limit "$limit" --offset "$offset" ;;
    zcode|"") resolve_content_zcode "$session_id" --limit "$limit" --offset "$offset" ;;
    *) die "框架 '$framework' 未适配（已适配: zcode, codex, dsh, claude-code）" ;;
  esac
}

# ZCode 实现：查询 sqlite message + part 表
# 返回 JSON 数组: [{ role, time_created, parts: [...] }]
resolve_content_zcode() {
  local session_id="$1"
  shift

  local limit="" offset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  check_sqlite3
  check_db

  # 构建 limit/offset SQL 片段
  local limit_sql=""
  if [[ -n "$limit" ]]; then
    limit_sql="LIMIT ${limit}"
    if [[ -n "$offset" ]]; then
      limit_sql="LIMIT ${limit} OFFSET ${offset}"
    fi
  fi

  # 查询 message + part，按时间排序
  # message.data 含 role（JSON），part.data 含 type + 正文（JSON）
  local query
  query="
    SELECT
      m.id as msg_id,
      m.time_created as msg_time,
      json_extract(m.data, '$.role') as role,
      p.id as part_id,
      p.data as part_data
    FROM message m
    LEFT JOIN part p ON p.message_id = m.id
    WHERE m.session_id = '${session_id}'
    ORDER BY m.time_created ASC, p.id ASC
    ${limit_sql};
  "

  local raw
  raw=$(sqlite3 "$ZCODE_DB" -json "$query") || die "查询失败: ${session_id}"

  if [[ -z "$raw" || "$raw" == "[]" ]]; then
    echo "[]"
    return
  fi

  # 用 python3 聚合成消息序列（每条消息含 parts 数组）
  echo "$raw" | python3 -c "
import json, sys

rows = json.load(sys.stdin)

messages = []
current_msg = None

for row in rows:
    msg_id = row['msg_id']
    # 新消息
    if current_msg is None or current_msg['_id'] != msg_id:
        if current_msg is not None:
            del current_msg['_id']
            messages.append(current_msg)
        current_msg = {
            '_id': msg_id,
            'role': row['role'] or 'unknown',
            'time_created': row['msg_time'],
            'parts': []
        }

    part_data_raw = row.get('part_data')
    if not part_data_raw:
        continue

    try:
        part = json.loads(part_data_raw)
    except (json.JSONDecodeError, TypeError):
        continue

    ptype = part.get('type', '')

    if ptype == 'text':
        current_msg['parts'].append({
            'type': 'text',
            'text': part.get('text', '')
        })
    elif ptype == 'tool':
        state = part.get('state', {})
        current_msg['parts'].append({
            'type': 'tool',
            'tool': part.get('tool', ''),
            'status': state.get('status', ''),
            'input': state.get('input'),
            'output': state.get('output')
        })
    elif ptype == 'reasoning':
        current_msg['parts'].append({
            'type': 'reasoning',
            'text': part.get('text', '')
        })
    elif ptype == 'file':
        current_msg['parts'].append({
            'type': 'file',
            'filename': part.get('filename', ''),
            'url': part.get('url', '')
        })
    elif ptype in ('step-start', 'step-finish'):
        # 步骤标记，跳过（无正文内容）
        pass
    else:
        # 未知类型，保留原始数据供调试
        current_msg['parts'].append({
            'type': ptype,
            'raw': part
        })

# 别忘了最后一条
if current_msg is not None:
    del current_msg['_id']
    messages.append(current_msg)

print(json.dumps(messages, ensure_ascii=False, indent=2))
"
}

# Codex 实现：解析 rollout JSONL 的 response_item 序列
# 返回 JSON 数组: [{ role, time_created, parts: [...] }]
# 去重：event_msg user_message 跳过（response_item role=user 已承载）
# 过滤：developer role（系统指令）、step 标记
resolve_content_codex() {
  local session_id="$1"
  shift

  local limit="" offset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  local paths
  paths=$(find_codex_rollouts "$session_id")

  python3 - "$session_id" "$limit" "$offset" "$paths" <<'PY'
import json, sys
from datetime import datetime

paths = [line for line in sys.argv[4].splitlines() if line.strip()]
sid, limit_s, offset_s = sys.argv[1], sys.argv[2], sys.argv[3]
limit = int(limit_s) if limit_s else None
offset = int(offset_s) if offset_s else 0

def ts_ms(iso):
    if not iso:
        return None
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

messages = []
tool_parts = {}       # call_id -> tool part
last_assistant = None # 最近的 assistant 消息（工具调用挂载点）

def close_and_append(msg):
    messages.append(msg)

for path in paths:
    with open(path) as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            if rec.get("type") != "response_item":
                continue
            p = rec.get("payload") or {}
            ptype = p.get("type")
            ts = ts_ms(rec.get("timestamp"))

            if ptype == "message":
                role = p.get("role")
                if role == "developer":
                    continue  # 系统指令，非对话内容
                parts = []
                for c in (p.get("content") or []):
                    ct = c.get("type")
                    if ct in ("input_text", "output_text"):
                        parts.append({"type": "text", "text": c.get("text", "")})
                    elif ct == "reasoning_text":
                        parts.append({
                            "type": "reasoning",
                            "text": c.get("text") or c.get("summary") or "",
                        })
                    elif ct == "file":
                        parts.append({
                            "type": "file",
                            "filename": c.get("filename", ""),
                            "url": c.get("url", ""),
                        })
                    elif ct in ("step-start", "step-finish"):
                        pass
                    else:
                        parts.append({"type": ct, "raw": c})
                msg = {"role": role, "time_created": ts, "parts": parts}
                close_and_append(msg)
                last_assistant = msg if role == "assistant" else None

            elif ptype == "function_call":
                part = {
                    "type": "tool",
                    "tool": p.get("name", ""),
                    "call_id": p.get("call_id", ""),
                    "status": "pending",
                    "input": None,
                    "output": None,
                }
                try:
                    part["input"] = json.loads(p.get("arguments") or "{}")
                except Exception:
                    part["input"] = p.get("arguments")
                tool_parts[p.get("call_id", "")] = part
                if last_assistant is not None:
                    last_assistant["parts"].append(part)
                else:
                    # 无 assistant 消息可挂载时，独立成一条伪 assistant 消息
                    synth = {"role": "assistant", "time_created": ts, "parts": [part]}
                    close_and_append(synth)
                    last_assistant = synth

            elif ptype == "function_call_output":
                part = tool_parts.get(p.get("call_id", ""))
                if part is not None:
                    part["status"] = "completed"
                    part["output"] = p.get("output")

if offset > 0:
    messages = messages[offset:]
if limit is not None:
    messages = messages[:limit]

print(json.dumps(messages, ensure_ascii=False, indent=2))
PY
}

# dsh 实现：解析 session.jsonl.zstd 的完整形态记录
# 返回 JSON 数组: [{ role, time_created, parts: [...] }]
# 主形态：user/message + assistant/message（含内嵌 tool-call）
# 跳过：chunk 流式记录（与完整形态重复）、agent/inbox/spliced（与 user/message 重复）、
#       tool/call（与 assistant/message 内嵌 tool-call 重复）、step/turn 标记、配置类记录
resolve_content_dsh() {
  local session_id="$1"
  shift

  local limit="" offset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  local sess_dir
  sess_dir=$(find_dsh_session "$session_id")

  check_zstd

  python3 - "$session_id" "$limit" "$offset" "$sess_dir" <<'PY'
import json, os, subprocess, sys

sid, limit_s, offset_s, sess_dir = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
limit = int(limit_s) if limit_s else None
offset = int(offset_s) if offset_s else 0
zf = os.path.join(sess_dir, "session.jsonl.zstd")
proc = subprocess.Popen(["zstd", "-dc", zf], stdout=subprocess.PIPE, text=True)

messages = []
tool_parts = {}  # call_id -> tool part（跨消息挂载 tool/result）

for line in proc.stdout:
    try:
        rec = json.loads(line)
    except Exception:
        continue
    t = rec.get("type")
    d = rec.get("data") or {}
    ts = rec.get("time")

    if t == "user/message":
        parts = []
        for c in (d.get("content") or []):
            if c.get("type") == "text":
                parts.append({"type": "text", "text": c.get("text", "")})
        messages.append({"role": "user", "time_created": ts, "parts": parts})

    elif t == "assistant/message":
        m = d.get("message") or {}
        parts = []
        for c in (m.get("content") or []):
            ct = c.get("type")
            if ct == "text":
                parts.append({"type": "text", "text": c.get("text", "")})
            elif ct == "reasoning":
                parts.append({"type": "reasoning", "text": c.get("text", "")})
            elif ct == "tool-call":
                part = {
                    "type": "tool",
                    "tool": c.get("name", ""),
                    "call_id": c.get("id", ""),
                    "status": "pending",
                    "input": None,
                    "output": None,
                }
                try:
                    part["input"] = json.loads(c.get("arguments") or "{}")
                except Exception:
                    part["input"] = c.get("arguments")
                parts.append(part)
                tool_parts[c.get("id", "")] = part
            elif ct == "file":
                parts.append({"type": "file", "filename": c.get("filename", ""), "url": c.get("url", "")})
        messages.append({"role": "assistant", "time_created": ts, "parts": parts})

    elif t == "tool/result":
        msg = d.get("message") or {}
        cid = (msg.get("source") or {}).get("callId", "")
        texts = []
        for c in (msg.get("content") or []):
            if c.get("type") == "tool-result":
                for cc in (c.get("content") or []):
                    if cc.get("type") == "text":
                        texts.append(cc.get("text", ""))
        out = "\n".join(texts)
        part = tool_parts.get(cid)
        if part is not None:
            part["status"] = "completed"
            part["output"] = out
        else:
            # 未见对应 call 的孤儿 result：独立成一条伪 assistant 消息，不丢数据
            messages.append({"role": "assistant", "time_created": ts, "parts": [{
                "type": "tool", "tool": "", "call_id": cid,
                "status": "completed", "input": None, "output": out,
            }]})

if offset > 0:
    messages = messages[offset:]
if limit is not None:
    messages = messages[:limit]

print(json.dumps(messages, ensure_ascii=False, indent=2))
PY
}

# Claude Code 实现：解析 jsonl 的 user/assistant 记录（Anthropic API 形态：message.content 为 str | parts 数组）
# tool 关联：tool_use(id) ↔ tool_result(tool_use_id)，跨消息回填到对应 tool part
# 跳过：progress/file-history-snapshot/queue-operation/last-prompt/system 等非对话 type；
#       纯 tool_result 的 user 消息回填后无残余 part → 不产出空消息
# server_tool_use / server_tool_result 与本地 tool 同构处理
resolve_content_claude() {
  local session_id="$1"
  shift

  local limit="" offset=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  local path
  path=$(find_claude_session "$session_id")

  python3 - "$session_id" "$limit" "$offset" "$path" <<'PY'
import json, sys
from datetime import datetime

sid, limit_s, offset_s, path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
limit = int(limit_s) if limit_s else None
offset = int(offset_s) if offset_s else 0

def ts_ms(iso):
    if not iso:
        return None
    try:
        return int(datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp() * 1000)
    except Exception:
        return None

messages = []
tool_parts = {}  # tool_use_id -> tool part（跨消息回填 tool_result）

with open(path) as fh:
    for line in fh:
        try:
            rec = json.loads(line)
        except Exception:
            continue
        t = rec.get("type")
        if t not in ("user", "assistant"):
            continue
        m = rec.get("message") or {}
        ts = ts_ms(rec.get("timestamp"))
        content = m.get("content")

        parts = []
        if isinstance(content, str):
            parts.append({"type": "text", "text": content})
        elif isinstance(content, list):
            for p in content:
                if not isinstance(p, dict):
                    continue
                pt = p.get("type")
                if pt == "text":
                    parts.append({"type": "text", "text": p.get("text", "")})
                elif pt == "thinking":
                    parts.append({"type": "reasoning", "text": p.get("thinking", "") or p.get("text", "")})
                elif pt in ("tool_use", "server_tool_use"):
                    part = {
                        "type": "tool",
                        "tool": p.get("name", ""),
                        "call_id": p.get("id", ""),
                        "status": "pending",
                        "input": p.get("input"),
                        "output": None,
                    }
                    parts.append(part)
                    tool_parts[p.get("id", "")] = part
                elif pt in ("tool_result", "server_tool_result"):
                    cid = p.get("tool_use_id", "")
                    out = p.get("content")
                    if isinstance(out, list):
                        texts = [c.get("text", "") for c in out if isinstance(c, dict) and c.get("type") == "text"]
                        out = "\n".join(texts)
                    target = tool_parts.get(cid)
                    if target is not None:
                        target["status"] = "completed"
                        target["output"] = out
                    # tool_result 不生成新 part（结果属于对应 tool_use，回填或丢弃）
                else:
                    parts.append({"type": pt, "raw": p})
        if parts:
            messages.append({"role": t, "time_created": ts, "parts": parts})

if offset > 0:
    messages = messages[offset:]
if limit is not None:
    messages = messages[:limit]

print(json.dumps(messages, ensure_ascii=False, indent=2))
PY
}

# ─── list：近期会话枚举 ──────────────────────────────

# 枚举近期会话（标准 ID + 最后活动时间 + 标题），跨框架合并按时间倒序
# 各框架存储知识复用 resolve 的勘察结论（见设计文档「list（枚举）」段）
list_sessions() {
  local since="" frameworks=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) since="$2"; shift 2 ;;
      --framework) frameworks="$2"; shift 2 ;;
      *) die "未知参数: $1" ;;
    esac
  done

  # framework 值域校验（逗号分隔多值）
  if [[ -n "$frameworks" ]]; then
    local fw
    for fw in ${frameworks//,/ }; do
      case "$fw" in
        zcode|codex|dsh|claude-code) ;;
        *) die "未知框架: '$fw'（可用: zcode, codex, dsh, claude-code）" ;;
      esac
    done
  fi

  python3 - "$since" "$frameworks" <<'PY'
import json, os, re, shutil, sqlite3, subprocess, sys, time

since_raw, fw_raw = sys.argv[1], sys.argv[2]
home = os.path.expanduser("~")

# --since 解析: 3d / 12h / 30m / 1d12h → epoch 秒下限; 空 = 全量
since_s = 0.0
if since_raw:
    if not re.fullmatch(r"(?:\d+[dhm])+", since_raw):
        sys.stderr.write(f"无效 --since 格式: {since_raw}（示例: 3d, 12h, 30m, 1d12h）\n")
        sys.exit(1)
    total = sum(int(n) * u for n, u in (
        (n, {"d": 86400, "h": 3600, "m": 60}[unit])
        for n, unit in re.findall(r"(\d+)([dhm])", since_raw)
    ))
    since_s = time.time() - total

frameworks = [f.strip() for f in fw_raw.split(",") if f.strip()] \
    or ["zcode", "codex", "dsh", "claude-code"]

rows = []  # (mtime_epoch, standard_id, title)

def clean_title(s):
    return " ".join(str(s).split())[:80]

# --- zcode: session 表 SQL 过滤（time_updated 毫秒）---
if "zcode" in frameworks:
    db = os.path.join(home, ".zcode/cli/db/db.sqlite")
    if not os.path.isfile(db):
        sys.stderr.write(f"警告: zcode 数据库不存在，跳过（{db}）\n")
    else:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            for sid, title, tu in con.execute(
                "SELECT id, title, time_updated FROM session WHERE time_updated > ?",
                (int(since_s * 1000),),
            ):
                rows.append((tu / 1000, f"zcode:{sid}", clean_title(title or "")))
            con.close()
        except Exception as e:
            sys.stderr.write(f"警告: zcode 枚举失败: {e}\n")

# --- codex: rollout 文件扫描，同 thread 多文件去重（mtime 取最新，标题读最早文件）---
if "codex" in frameworks:
    codex_root = os.environ.get("CODEX_HOME", os.path.join(home, ".codex"))
    roots = [os.path.join(codex_root, "sessions"), os.path.join(codex_root, "archived_sessions")]
    uuid_re = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    if not any(os.path.isdir(r) for r in roots):
        sys.stderr.write(f"警告: codex 会话目录不存在，跳过（{codex_root}）\n")
    else:
        threads = {}  # thread-id -> [max_mtime, earliest_path]
        for root in roots:
            for dirpath, _dirnames, filenames in os.walk(root):
                for name in filenames:
                    if not (name.startswith("rollout-") and name.endswith(".jsonl")):
                        continue
                    m = uuid_re.search(name)
                    if not m:
                        continue
                    p = os.path.join(dirpath, name)
                    mt = os.path.getmtime(p)
                    cur = threads.get(m.group(0))
                    if cur is None:
                        threads[m.group(0)] = [mt, p]
                    else:
                        cur[0] = max(cur[0], mt)
                        if name < os.path.basename(cur[1]):
                            cur[1] = p  # 文件名含时间戳，最早文件承载 session_meta + 首条用户消息

        def codex_title(path):
            try:
                with open(path) as fh:
                    for i, line in enumerate(fh):
                        if i >= 200:
                            break
                        try:
                            rec = json.loads(line)
                        except Exception:
                            continue
                        p = rec.get("payload") or {}
                        if rec.get("type") == "event_msg" and p.get("type") == "user_message":
                            msg = str(p.get("message") or "").strip()
                            if msg:
                                return clean_title(msg)
            except Exception:
                pass
            return ""

        for sid, (mt, earliest) in threads.items():
            if since_s and mt < since_s:
                continue
            rows.append((mt, f"codex:{sid}", codex_title(earliest)))

# --- dsh: 会话目录扫描（sid=目录名），zstd 解压流取显式 title ---
if "dsh" in frameworks:
    dsh_root = os.environ.get("DSH_HOME", os.path.join(home, ".dsh"))
    sess_root = os.path.join(dsh_root, "sessions")
    if not os.path.isdir(sess_root):
        sys.stderr.write(f"警告: dsh 会话目录不存在，跳过（{dsh_root}）\n")
    elif not shutil.which("zstd"):
        sys.stderr.write("警告: zstd 未安装，dsh 枚举跳过（brew install zstd）\n")
    else:
        def dsh_title(zf):
            title, first_user = "", ""
            try:
                proc = subprocess.Popen(["zstd", "-dc", zf], stdout=subprocess.PIPE, text=True)
                for line in proc.stdout:
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    t = rec.get("type")
                    d = rec.get("data") or {}
                    if t == "session/title":
                        title = d.get("title") or title
                    elif t == "user/message" and not first_user:
                        for c in (d.get("content") or []):
                            if c.get("type") == "text" and str(c.get("text", "")).strip():
                                first_user = str(c["text"]).strip()
                                break
                proc.wait()
            except Exception:
                pass
            return clean_title(title or first_user)

        for ws in os.listdir(sess_root):
            wsd = os.path.join(sess_root, ws)
            if not os.path.isdir(wsd):
                continue
            for sid in os.listdir(wsd):
                zf = os.path.join(wsd, sid, "session.jsonl.zstd")
                if not os.path.isfile(zf):
                    continue
                mt = os.path.getmtime(zf)
                if since_s and mt < since_s:
                    continue
                rows.append((mt, f"dsh:{sid}", dsh_title(zf)))

# --- claude-code: projects 深度 2 扫描（天然排除 subagents/，sid=文件名）---
if "claude-code" in frameworks:
    cc_root = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(home, ".claude"))
    proj = os.path.join(cc_root, "projects")
    if not os.path.isdir(proj):
        sys.stderr.write(f"警告: claude-code 会话目录不存在，跳过（{proj}）\n")
    else:
        def claude_title(path):
            first_user, slug = "", ""
            try:
                with open(path) as fh:
                    for i, line in enumerate(fh):
                        if i >= 200:
                            break
                        try:
                            rec = json.loads(line)
                        except Exception:
                            continue
                        t = rec.get("type")
                        if t not in ("user", "assistant"):
                            continue
                        if not slug and rec.get("slug"):
                            slug = rec["slug"]
                        if t == "user" and not first_user:
                            m = rec.get("message") or {}
                            c = m.get("content")
                            if isinstance(c, str) and c.strip():
                                first_user = c.strip()
                            elif isinstance(c, list):
                                for part in c:
                                    if isinstance(part, dict) and part.get("type") == "text" \
                                            and str(part.get("text", "")).strip():
                                        first_user = str(part["text"]).strip()
                                        break
                        if first_user and slug:
                            break
            except Exception:
                pass
            return clean_title(first_user or slug)

        for d in os.listdir(proj):
            dp = os.path.join(proj, d)
            if not os.path.isdir(dp):
                continue
            for name in os.listdir(dp):
                p = os.path.join(dp, name)
                if not (os.path.isfile(p) and name.endswith(".jsonl")):
                    continue
                mt = os.path.getmtime(p)
                if since_s and mt < since_s:
                    continue
                rows.append((mt, f"claude-code:{name[:-len('.jsonl')]}", claude_title(p)))

rows.sort(key=lambda r: r[0], reverse=True)
for mt, sid, title in rows:
    print(f"{sid}\t{time.strftime('%Y-%m-%d %H:%M', time.localtime(mt))}\t{title}")
PY
}

# ─── 用法 ────────────────────────────────────────────

usage() {
  cat <<EOF
session-resolver v${VERSION} — 会话身份适配器

用法:
  session-resolver.sh identify
    在会话中获取当前会话的标准 ID（格式: <框架>:<session-id>）
    已适配框架: zcode（进程树 sess_ + 环境变量）、codex（CODEX_THREAD_ID）、
                dsh（进程树 + workspace.json/mtime 反查）、
                claude-code（CLAUDECODE 环境变量 + projects mtime 反查）

  session-resolver.sh resolve meta <标准ID>
    查询会话元数据（标题/时间/目录/摘要）

  session-resolver.sh resolve content <标准ID> [--limit N] [--offset N]
    查询会话消息正文（角色 + 正文片段序列）
    可选 --limit/--offset 分段查询

  session-resolver.sh list [--since 3d] [--framework zcode|codex|dsh|claude-code]
    枚举近期会话（标准 ID + 最后活动时间 + 标题），按时间倒序
    --since: 时间过滤（3d / 12h / 30m，可组合如 1d12h；不传 = 全量）
    --framework: 逗号分隔多值过滤；不传 = 全部框架合并
    输出: 一行一条 <标准ID>\t<本地时间 YYYY-MM-DD HH:MM>\t<标题截断80>

  session-resolver.sh --version
    显示版本号

  session-resolver.sh --help
    显示此帮助

标准 ID 格式:
  <框架标识>:<该框架原生 session-id>
  ZCode 示例: zcode:sess_bd2e826f-0932-48ec-8a03-0e7869f3bab8
  Codex 示例: codex:019fc5c5-bf07-7c91-b165-9aa3ef8b2861
  dsh 示例:   dsh:session-b52d2aa0-f5c7-41d5-b14e-57b607ea9285
  Claude Code 示例: claude-code:bc3e96c7-a925-4c2e-ac9a-ccf181a3a388

数据源:
  ZCode: ${ZCODE_DB}
  Codex: ${CODEX_SESSIONS}/<YYYY>/<MM>/<DD>/rollout-*.jsonl（+ ${CODEX_ARCHIVED}）
  dsh:   ${DSH_SESSIONS}/<cwd编码>--/<session-uuid>/session.jsonl.zstd（zstd 压缩 JSONL，需 zstd）
  Claude Code: ${CLAUDE_PROJECTS}/<cwd编码>/<sessionId>.jsonl（subagents 子目录 MVP 不解析）
  （只读查询，不写入数据库）
EOF
}

# ─── 主入口 ──────────────────────────────────────────

main() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    identify)
      identify
      ;;
    resolve)
      local subcmd="${1:-}"
      shift || true
      case "$subcmd" in
        meta)
          [[ $# -lt 1 ]] && die "用法: session-resolver.sh resolve meta <标准ID>"
          resolve_meta "$1"
          ;;
        content)
          [[ $# -lt 1 ]] && die "用法: session-resolver.sh resolve content <标准ID> [--limit N] [--offset N]"
          resolve_content "$@"
          ;;
        *)
          die "未知 resolve 子命令: '$subcmd'。可用: meta, content"
          ;;
      esac
      ;;
    list)
      list_sessions "$@"
      ;;
    --version|-v)
      echo "session-resolver v${VERSION}"
      ;;
    --help|-h|help|"")
      usage
      ;;
    *)
      die "未知命令: '$cmd'。可用: identify, resolve, list, --help"
      ;;
  esac
}

main "$@"
