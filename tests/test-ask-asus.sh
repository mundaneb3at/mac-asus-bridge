#!/bin/bash

# Offline return-leg tests. No SSH or network is used.
#
# This exercises the Windows-side answer runner (Answer-Ask.ps1) for real, via
# a PowerShell host. On the ASUS itself that's Git Bash + Windows PowerShell
# (cygpath converts POSIX paths for it). On a plain Linux/macOS runner there is
# no cygpath and no powershell.exe, only pwsh (PowerShell 7, which understands
# POSIX paths natively) if it's installed. This shim picks whichever is present
# instead of assuming Windows.

set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ask="$script_dir/../mac/ask-asus.sh"
runner="$script_dir/../windows/Answer-Ask.ps1"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ask-asus-test.XXXXXX") || exit 1
failures=0

cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

if command -v powershell.exe >/dev/null 2>&1; then
  PS_EXE=powershell.exe
elif command -v pwsh >/dev/null 2>&1; then
  PS_EXE=pwsh
else
  printf 'SKIP: no PowerShell host found (need powershell.exe or pwsh)\n'
  exit 0
fi
export PS_EXE
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

mkdir -p "$tmp_dir/bin" "$tmp_dir/home"
stub_src_win=$(winpath "$script_dir/claude-stub.cs")
stub_exe_win=$(winpath "$tmp_dir/claude-stub.exe")
"$PS_EXE" -NoProfile -Command "Add-Type -Path '$stub_src_win' -OutputAssembly '$stub_exe_win' -OutputType ConsoleApplication" || {
  printf 'SKIP: %s could not compile the console-app stub on this platform\n' "$PS_EXE"
  exit 0
}
[ -e "$tmp_dir/claude-stub.exe" ] || {
  printf 'SKIP: %s produced no executable on this platform\n' "$PS_EXE"
  exit 0
}

cat >"$tmp_dir/bin/ssh" <<'STUB'
#!/bin/bash
case "$*" in
  *Remove-Item*) rm -f "$FAKE_REMOTE_Q" "$FAKE_REMOTE_A"; exit 0 ;;
esac
answer_transfer=0
case "$*" in
  *ASK_ASUS_BASE64_V1*) answer_transfer=1 ;;
esac
if [ "$answer_transfer" -eq 1 ]; then
  printf '%s\n' 'Workspace path schema loaded: MAIN_ROOT = contaminated-banner' | tee "$FAKE_ANSWER_WIRE_CAPTURE"
else
  printf '%s\n' 'Workspace path schema loaded: MAIN_ROOT = contaminated-banner'
fi
if [ "${FAKE_MODE:-success}" = "ssh_failure" ]; then exit 255; fi
if [ "${FAKE_MODE:-success}" = "transport" ]; then exit 255; fi
case "$*" in
  *WriteAllBytes*)
    "$PS_EXE" -NoProfile -Command \
      "[System.IO.File]::WriteAllBytes('$FAKE_REMOTE_Q_WIN',[System.Convert]::FromBase64String([Console]::In.ReadToEnd()))"
    status=$?
    [ "$status" -eq 0 ] || exit "$status"
    cp "$FAKE_REMOTE_Q" "$FAKE_CAPTURE_QUESTION"
    ;;
  *ASK_ASUS_BASE64_V1*)
    "$PS_EXE" -NoProfile -Command \
      "[Console]::Out.WriteLine('ASK_ASUS_BASE64_V1');[Console]::Out.Write([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes('$FAKE_REMOTE_A_WIN')))" \
      | tee -a "$FAKE_ANSWER_WIRE_CAPTURE"
    exit "${PIPESTATUS[0]}"
    ;;
  *)
    "$PS_EXE" -NoProfile -ExecutionPolicy Bypass -File "$FAKE_RUNNER_WIN" \
      -QuestionFile "$FAKE_REMOTE_Q_WIN" -AnswerFile "$FAKE_REMOTE_A_WIN" -TimeoutSec 10
    ;;
esac
STUB
chmod +x "$tmp_dir/bin/ssh"

export PATH="$tmp_dir/bin:$PATH"
export HOME="$tmp_dir/home"
export FAKE_REMOTE_Q="$tmp_dir/remote.question"
export FAKE_REMOTE_A="$tmp_dir/remote.answer"
export FAKE_CAPTURE_QUESTION="$tmp_dir/captured.question"
export FAKE_ANSWER_WIRE_CAPTURE="$tmp_dir/answer.wire.capture"
export FAKE_CLAUDE_INPUT="$tmp_dir/claude.input"
export FAKE_SETTINGS_CAPTURE="$tmp_dir/settings.json"
export FAKE_ARGS_CAPTURE="$tmp_dir/claude.args"
export FAKE_RUNNER_WIN=$(winpath "$runner")
export FAKE_REMOTE_Q_WIN=$(winpath "$FAKE_REMOTE_Q")
export FAKE_REMOTE_A_WIN=$(winpath "$FAKE_REMOTE_A")
export ASK_ASUS_CLAUDE="$stub_exe_win"
export ASK_ASUS_WORKSPACE=$(winpath "$script_dir/..")

python3 - "$tmp_dir/expected.question" <<'PY'
import sys

payload = (
    b"Does ? survive * and $VAR with 'single quotes' and \"double quotes\"?\r\n"
    b"The previous break is CRLF; this break is a lone LF.\n"
    b"literal-tab:\tend; UTF-8: em\xe2\x80\x94dash\r\n"
    b"binary-ish:" + bytes([1, 2, 3, 4, 5, 0x7f, 0x80, 0x81, 0xfe, 0xff]) + b"\n"
)
open(sys.argv[1], "wb").write(payload)
PY
export FAKE_MODE=success
export FAKE_ANSWER='clean answer; secret sk-ant-oat01-EXAMPLE'
bash "$ask" --timeout 10 <"$tmp_dir/expected.question" >"$tmp_dir/success.out" 2>"$tmp_dir/success.err"
success_status=$?
if [ "$success_status" -eq 0 ] && cmp -s "$tmp_dir/expected.question" "$FAKE_CAPTURE_QUESTION" && cmp -s "$tmp_dir/expected.question" "$FAKE_CLAUDE_INPUT"; then
  pass 'metacharacters, quotes, dollar text, and newline arrive byte-identical'
else
  fail 'metacharacters, quotes, dollar text, and newline arrive byte-identical'
fi
if python3 - "$tmp_dir/expected.question" <<'PY' \
  && cmp -s "$tmp_dir/expected.question" "$FAKE_CAPTURE_QUESTION" \
  && cmp -s "$tmp_dir/expected.question" "$FAKE_CLAUDE_INPUT"
import sys

data = open(sys.argv[1], "rb").read()
required = [b"\r\n", b"lone LF.\n", b"\t", b"em\xe2\x80\x94dash", bytes([1, 2, 3, 4, 5, 0x7f, 0x80, 0x81, 0xfe, 0xff])]
sys.exit(0 if all(part in data for part in required) and b"\x00" not in data else 1)
PY
then
  pass 'CRLF, lone LF, tab, UTF-8, and binary-ish bytes survive transport byte-identical'
else
  fail 'CRLF, lone LF, tab, UTF-8, and binary-ish bytes survive transport byte-identical'
fi
if ! grep -q 'Workspace path schema loaded' "$tmp_dir/success.out"; then
  pass 'PowerShell profile banner is absent from the captured answer'
else
  fail 'PowerShell profile banner is absent from the captured answer'
fi
printf '%s' 'clean answer; secret [REDACTED]' >"$tmp_dir/expected.answer"
if python3 - "$FAKE_ANSWER_WIRE_CAPTURE" <<'PY' \
  && cmp -s "$tmp_dir/expected.answer" "$tmp_dir/success.out"
import sys

data = open(sys.argv[1], "rb").read()
banner = b"Workspace path schema loaded: MAIN_ROOT = contaminated-banner"
marker = b"ASK_ASUS_BASE64_V1"
sys.exit(0 if data.startswith(banner) and data.find(marker) > data.find(banner) else 1)
PY
then
  pass 'answer parsing ignores a remote-shell banner before the framed payload'
else
  fail 'answer parsing ignores a remote-shell banner before the framed payload'
fi
if grep -q '\[REDACTED\]' "$tmp_dir/success.out" && ! grep -q 'sk-ant-oat01-EXAMPLE' "$tmp_dir/success.out"; then
  pass 'secret-shaped strings are filtered from output'
else
  fail 'secret-shaped strings are filtered from output'
fi
archive_count=$(find "$HOME/School/asus/outbox" -name '*-ask-asus.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$archive_count" -eq 1 ] && grep -q '## Question' "$HOME"/School/asus/outbox/*-ask-asus.md; then
  pass 'successful exchange is archived'
else
  fail 'successful exchange is archived'
fi

export FAKE_MODE=transport
printf '%s' 'transport test' | bash "$ask" --timeout 10 >"$tmp_dir/transport.out" 2>"$tmp_dir/transport.err"
if [ "$?" -eq 3 ]; then pass 'transport failure exits 3'; else fail 'transport failure exits 3'; fi

export FAKE_MODE=claude_error
printf '%s' 'claude error test' | bash "$ask" --timeout 10 >"$tmp_dir/error.out" 2>"$tmp_dir/error.err"
error_status=$?
if [ "$error_status" -eq 5 ]; then pass 'Claude failure exits 5'; else fail 'Claude failure exits 5'; fi
after_error_count=$(find "$HOME/School/asus/outbox" -name '*-ask-asus.md' 2>/dev/null | wc -l | tr -d ' ')
if [ "$after_error_count" -eq "$archive_count" ]; then
  pass 'Claude failure does not write a success archive'
else
  fail 'Claude failure does not write a success archive'
fi

if grep -q '"hooks":{}' "$FAKE_SETTINGS_CAPTURE" && grep -q -- '--setting-sources' "$FAKE_ARGS_CAPTURE"; then
  pass 'Windows invocation suppresses inherited hooks'
else
  fail 'Windows invocation suppresses inherited hooks'
fi

if ! grep -Fq 'scp' "$ask"; then
  pass 'ask-asus transport contains no scp references'
else
  fail 'ask-asus transport contains no scp references'
fi

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'PASS: all ask-asus tests passed\n'
exit 0
