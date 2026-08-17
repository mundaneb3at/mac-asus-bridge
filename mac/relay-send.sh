#!/bin/bash

# Send one stdin message through a short-lived Claude CLI peer on the Mac.

name=""
timeout=120

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      [ "$#" -ge 2 ] || { printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"--name requires a value"}'; exit 2; }
      name=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"--timeout requires a value"}'; exit 2; }
      timeout=$2
      shift 2
      ;;
    *)
      printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"unknown argument"}'
      exit 2
      ;;
  esac
done

case "$timeout" in
  ''|*[!0-9]*) printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"timeout must be a positive integer"}'; exit 2 ;;
esac
[ "$timeout" -gt 0 ] || { printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"timeout must be a positive integer"}'; exit 2; }

if command -v claude >/dev/null 2>&1; then
  claude_bin=$(command -v claude)
elif [ -x "$HOME/.local/bin/claude" ]; then
  claude_bin="$HOME/.local/bin/claude"
else
  printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"claude executable not found"}'
  exit 2
fi

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/asus-relay.XXXXXX" 2>/dev/null) || {
  printf '%s\n' '{"ok":false,"target":"","sessionId":"","detail":"could not create temporary directory"}'
  exit 2
}

cleanup() {
  exec 2>&-
  for file in message agents.json agents.err target session detail prompt send.out send.err cat.err internal.err timed-out; do
    [ ! -e "$tmp_dir/$file" ] || rm -f "$tmp_dir/$file"
  done
  rmdir "$tmp_dir" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
exec 2>"$tmp_dir/internal.err"

if ! cat >"$tmp_dir/message" 2>"$tmp_dir/cat.err"; then
  printf '%s\n' 'could not read the message from stdin' >"$tmp_dir/detail"
  emit_pending_input_error=1
fi

emit_result() {
  python3 - "$1" "$2" "$3" "$tmp_dir/detail" "$tmp_dir/internal.err" <<'PY'
import json, re, sys
ok = sys.argv[1] == "true"
try:
    detail = open(sys.argv[4], "r", encoding="utf-8", errors="replace").read().strip()
except OSError:
    detail = "relay failed without a diagnostic"
try:
    internal = open(sys.argv[5], "r", encoding="utf-8", errors="replace").read().strip()
    if internal:
        detail = (detail + "\n" + internal).strip()
except OSError:
    pass
secret = re.compile(r"sk-ant-[A-Za-z0-9_.-]*")
clean = lambda value: secret.sub("[REDACTED]", value)
if len(detail) > 4000:
    detail = detail[-4000:]
print(json.dumps({"ok": ok, "target": clean(sys.argv[2]),
                  "sessionId": clean(sys.argv[3]), "detail": clean(detail)},
                 separators=(",", ":")))
PY
}

if [ "${emit_pending_input_error:-0}" -eq 1 ]; then
  emit_result false "" ""
  exit 2
fi

if ! "$claude_bin" agents --json >"$tmp_dir/agents.json" 2>"$tmp_dir/agents.err"; then
  printf '%s\n' 'could not list Claude agents' >"$tmp_dir/detail"
  cat "$tmp_dir/agents.err" >>"$tmp_dir/detail"
  emit_result false "" ""
  exit 2
fi

python3 - "$tmp_dir/agents.json" "$name" "$tmp_dir/target" "$tmp_dir/session" "$tmp_dir/detail" <<'PY'
import json, sys
source, wanted, target_file, session_file, detail_file = sys.argv[1:]
try:
    agents = json.load(open(source, "r", encoding="utf-8"))
    if not isinstance(agents, list):
        raise ValueError("agent response was not an array")
except Exception:
    open(detail_file, "w").write("claude agents --json returned invalid JSON")
    sys.exit(2)

def newest(items):
    return max(items, key=lambda a: (str(a.get("startedAt", "")), int(a.get("pid", 0) or 0)))

if wanted:
    choices = [a for a in agents if str(a.get("name", "")) == wanted]
    if not choices:
        open(detail_file, "w").write("no Claude agent matched the requested name")
        sys.exit(3)
    chosen = newest(choices)
else:
    choices = [a for a in agents if a.get("kind") == "interactive"]
    if not choices:
        open(detail_file, "w").write("no interactive Claude agent is running")
        sys.exit(3)
    chosen = newest(choices)

target = str(chosen.get("name", ""))
session = str(chosen.get("sessionId", ""))
if not target or not session:
    open(detail_file, "w").write("resolved agent is missing its name or sessionId")
    sys.exit(3)
open(target_file, "w").write(target)
open(session_file, "w").write(session)
PY
select_status=$?

if [ "$select_status" -ne 0 ]; then
  emit_result false "" ""
  [ "$select_status" -eq 3 ] && exit 3
  exit 2
fi

target=$(cat "$tmp_dir/target")
session=$(cat "$tmp_dir/session")
cat >"$tmp_dir/detail" <<EOF
resolved target $target ($session)
EOF

python3 - "$tmp_dir/target" "$tmp_dir/session" "$tmp_dir/message" "$tmp_dir/prompt" <<'PY'
import json, sys
target = open(sys.argv[1], "r").read()
session = open(sys.argv[2], "r").read()
body = open(sys.argv[3], "rb").read()
header = (
    "Use SendMessage exactly once to deliver the byte-counted message below.\n"
    "Recipient name: %s\nRecipient sessionId: %s\n"
    "Preserve the message body exactly; do not answer it yourself.\n"
    "ASUS_RELAY_MESSAGE_BYTES: %d\nASUS_RELAY_MESSAGE_BEGIN\n"
) % (json.dumps(target), json.dumps(session), len(body))
with open(sys.argv[4], "wb") as output:
    output.write(header.encode("utf-8"))
    output.write(body)
    output.write(b"\nASUS_RELAY_MESSAGE_END\n")
PY

cat "$tmp_dir/prompt" 2>"$tmp_dir/cat.err" | "$claude_bin" -p --output-format text --allowedTools ListAgents,SendMessage >"$tmp_dir/send.out" 2>"$tmp_dir/send.err" &
send_pid=$!
started_at=$(date +%s)
while kill -0 "$send_pid" 2>/dev/null; do
  now=$(date +%s)
  if [ $((now - started_at)) -ge "$timeout" ]; then
    : >"$tmp_dir/timed-out"
    kill -TERM "$send_pid" 2>/dev/null || true
    sleep 2
    kill -KILL "$send_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$send_pid"
send_status=$?

cat "$tmp_dir/send.out" "$tmp_dir/send.err" "$tmp_dir/cat.err" >>"$tmp_dir/detail"
if [ -e "$tmp_dir/timed-out" ]; then
  printf '\nsend timed out after %s seconds\n' "$timeout" >>"$tmp_dir/detail"
  emit_result false "$target" "$session"
  exit 124
fi
if [ "$send_status" -ne 0 ]; then
  printf '\nclaude send exited with status %s\n' "$send_status" >>"$tmp_dir/detail"
  emit_result false "$target" "$session"
  exit "$send_status"
fi

emit_result true "$target" "$session"
exit 0
