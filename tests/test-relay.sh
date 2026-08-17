#!/bin/bash

# Offline regression tests for the Mac-side relay. No SSH or network is used.

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
relay="$script_dir/../mac/relay-send.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/mac-relay-test.XXXXXX") || exit 1
failures=0

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/agents.json" <<'JSON'
[
  {"pid":101,"cwd":"/tmp/a","kind":"interactive","startedAt":"2026-08-14T08:00:00Z","sessionId":"old-id","name":"old-session"},
  {"pid":202,"cwd":"/tmp/b","kind":"batch","startedAt":"2026-08-14T12:00:00Z","sessionId":"batch-id","name":"newer-batch"},
  {"pid":303,"cwd":"/tmp/c","kind":"interactive","startedAt":"2026-08-14T10:00:00Z","sessionId":"new-id","name":"newest-interactive"}
]
JSON

cat >"$tmp_dir/bin/claude" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "agents" ] && [ "${2:-}" = "--json" ]; then
  cat "$FAKE_AGENTS_FIXTURE"
  exit 0
fi
cat >"$FAKE_CAPTURE"
if [ "${FAKE_EMIT_SECRET:-0}" = "1" ]; then
  printf '%s\n' 'sender stdout sk-ant-oat01-EXAMPLE'
  printf '%s\n' 'sender stderr sk-ant-oat01-EXAMPLE' >&2
else
  printf '%s\n' 'message sent'
fi
exit 0
STUB
chmod +x "$tmp_dir/bin/claude"

export PATH="$tmp_dir/bin:$PATH"
export FAKE_AGENTS_FIXTURE="$tmp_dir/agents.json"
export FAKE_CAPTURE="$tmp_dir/captured-prompt"

printf '%s' 'hello' | "$relay" >"$tmp_dir/newest-result"
if python3 - "$tmp_dir/newest-result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result["ok"] is True
assert result["target"] == "newest-interactive"
assert result["sessionId"] == "new-id"
PY
then
  pass 'newest interactive session is selected when --name is absent'
else
  fail 'newest interactive session is selected when --name is absent'
fi

printf '%s' 'hello' | "$relay" --name does-not-exist >"$tmp_dir/missing-result"
missing_status=$?
if [ "$missing_status" -eq 3 ]; then
  pass 'unknown explicit --name exits 3'
else
  fail 'unknown explicit --name exits 3'
fi

cat >"$tmp_dir/expected-message" <<'MESSAGE'
Does ? survive * with 'single quotes' and "double quotes"?
This second line must also survive byte-identical.
MESSAGE
"$relay" <"$tmp_dir/expected-message" >"$tmp_dir/roundtrip-result"
if python3 - "$tmp_dir/captured-prompt" "$tmp_dir/expected-message" <<'PY'
import re, sys
prompt = open(sys.argv[1], "rb").read()
expected = open(sys.argv[2], "rb").read()
match = re.search(br"ASUS_RELAY_MESSAGE_BYTES: ([0-9]+)\nASUS_RELAY_MESSAGE_BEGIN\n", prompt)
assert match is not None
size = int(match.group(1))
actual = prompt[match.end():match.end() + size]
assert actual == expected
PY
then
  pass 'metacharacters, quotes, and newline survive byte-identical'
else
  fail 'metacharacters, quotes, and newline survive byte-identical'
fi

export FAKE_EMIT_SECRET=1
printf '%s' 'filter test' | "$relay" >"$tmp_dir/secret-result"
if ! grep -q 'sk-ant-oat01-EXAMPLE' "$tmp_dir/secret-result" && grep -q '\[REDACTED\]' "$tmp_dir/secret-result"; then
  pass 'secret-shaped strings are filtered from relayed output'
else
  fail 'secret-shaped strings are filtered from relayed output'
fi
unset FAKE_EMIT_SECRET

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %s assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'PASS: all relay tests passed\n'
exit 0
