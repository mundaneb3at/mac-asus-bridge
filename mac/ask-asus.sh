#!/bin/bash

# Ask a fresh Claude session on the ASUS and print only its answer body.

set -o pipefail

timeout=300
keep=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) [ "$#" -ge 2 ] || { printf '%s\n' 'ask-asus: --timeout needs a value' >&2; exit 3; }; timeout=$2; shift 2 ;;
    --keep) keep=1; shift ;;
    *) printf '%s\n' 'ask-asus: unknown argument' >&2; exit 3 ;;
  esac
done
case "$timeout" in ''|*[!0-9]*) printf '%s\n' 'ask-asus: timeout must be a positive integer' >&2; exit 3 ;; esac
[ "$timeout" -gt 0 ] || { printf '%s\n' 'ask-asus: timeout must be a positive integer' >&2; exit 3; }

# Edit these three for your own machines before running.
target='<win-user>@<asus-tailscale-ip>'
runner='C:/Users/<win-user>/mac-bridge/windows/Answer-Ask.ps1'
stamp=$(date -u +%Y%m%dT%H%M%SZ)
token="${stamp}-$$"
remote_q="C:/Users/<win-user>/AppData/Local/Temp/ask-asus-${token}.question"
remote_a="C:/Users/<win-user>/AppData/Local/Temp/ask-asus-${token}.answer"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ask-asus.XXXXXX") || exit 3
question="$tmp_dir/question"
answer="$tmp_dir/answer"
verdict="$tmp_dir/verdict"
answer_wire="$tmp_dir/answer.wire"
remote_created=0

cleanup() {
  if [ "$keep" -eq 0 ]; then
    if [ "$remote_created" -eq 1 ]; then
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "powershell.exe -NoProfile -Command Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath '$remote_q','$remote_a'" >/dev/null 2>&1 || true
    fi
    rm -f "$question" "$answer" "$answer_wire" "$verdict" "$tmp_dir/ssh.err"
    rmdir "$tmp_dir" 2>/dev/null || true
  else
    printf 'ask-asus: kept local files at %s\n' "$tmp_dir" >&2
    printf 'ask-asus: kept remote files at %s and %s\n' "$remote_q" "$remote_a" >&2
  fi
}
trap cleanup EXIT
trap 'exit 3' HUP INT TERM

cat >"$question" || { printf '%s\n' 'ask-asus: could not read stdin' >&2; exit 3; }
python3 - "$question" <<'PY'
import re, sys
p = sys.argv[1]
data = open(p, "rb").read()
open(p, "wb").write(re.sub(br"sk-ant-[A-Za-z0-9_.-]*", b"[REDACTED]", data))
PY
[ "$?" -eq 0 ] || { printf '%s\n' 'ask-asus: could not filter question' >&2; exit 3; }

base64 <"$question" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
  "powershell.exe -NoProfile -Command \"[System.IO.File]::WriteAllBytes('$remote_q',[System.Convert]::FromBase64String([Console]::In.ReadToEnd()))\"" \
  >/dev/null || {
  printf '%s\n' 'ask-asus: question transport failed' >&2; exit 3;
}
remote_created=1

ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -QuestionFile $remote_q -AnswerFile $remote_a -TimeoutSec $timeout" >"$verdict" 2>"$tmp_dir/ssh.err" &
ssh_pid=$!
started=$(date +%s)
timed_out=0
while kill -0 "$ssh_pid" 2>/dev/null; do
  now=$(date +%s)
  if [ $((now - started)) -ge $((timeout + 15)) ]; then
    timed_out=1
    kill -TERM "$ssh_pid" 2>/dev/null || true
    break
  fi
  sleep 1
done
wait "$ssh_pid"
ssh_status=$?
[ "$timed_out" -eq 0 ] || { printf '%s\n' 'ask-asus: timed out' >&2; exit 4; }
case "$ssh_status" in
  0) ;;
  4) printf '%s\n' 'ask-asus: Windows Claude timed out' >&2; exit 4 ;;
  5) printf '%s\n' 'ask-asus: Windows Claude failed' >&2; exit 5 ;;
  *) printf '%s\n' 'ask-asus: SSH transport failed' >&2; exit 3 ;;
esac

ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
  "powershell.exe -NoProfile -Command \"[Console]::Out.WriteLine('ASK_ASUS_BASE64_V1');[Console]::Out.Write([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes('$remote_a')))\"" \
  >"$answer_wire" || {
  printf '%s\n' 'ask-asus: answer transport failed' >&2; exit 3;
}
python3 - "$answer_wire" "$answer" <<'PY'
import base64, binascii, sys

wire_path, answer_path = sys.argv[1:]
marker = b"ASK_ASUS_BASE64_V1"
lines = open(wire_path, "rb").read().splitlines()
indices = [i for i, line in enumerate(lines) if line == marker]
if not indices:
    sys.exit(1)
encoded = b"".join(lines[indices[-1] + 1:])
try:
    answer = base64.b64decode(encoded, validate=True)
except (ValueError, binascii.Error):
    sys.exit(1)
open(answer_path, "wb").write(answer)
PY
[ "$?" -eq 0 ] || { printf '%s\n' 'ask-asus: answer transport failed' >&2; exit 3; }
python3 - "$answer" <<'PY'
import re, sys
p = sys.argv[1]
data = open(p, "rb").read()
open(p, "wb").write(re.sub(br"sk-ant-[A-Za-z0-9_.-]*", b"[REDACTED]", data))
PY
[ "$?" -eq 0 ] || { printf '%s\n' 'ask-asus: could not filter answer' >&2; exit 3; }

outbox="$HOME/School/asus/outbox"
mkdir -p "$outbox" || { printf '%s\n' 'ask-asus: could not create archive directory' >&2; exit 3; }
archive="$outbox/${stamp}-ask-asus.md"
{
  printf '# ask-asus exchange\n\n## Question\n\n'; cat "$question"
  printf '\n\n## Answer\n\n'; cat "$answer"; printf '\n'
} >"$archive" || { printf '%s\n' 'ask-asus: could not archive exchange' >&2; exit 3; }
cat "$answer"
exit 0
