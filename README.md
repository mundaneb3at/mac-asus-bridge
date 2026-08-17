# mac-asus-bridge

A small cross-machine execution relay between two independently-running
[Claude Code](https://claude.com/claude-code) sessions on different machines —
in the original setup, a Mac and a Windows PC ("the ASUS").

## The idea

Two Claude Code sessions on different machines and OSes sometimes need to hand
work to each other, but neither one wants to run as a permanent daemon or keep
a live connection open just in case. This bridge treats "ask the other
machine" as a single reliable function call instead of an ad-hoc SSH
one-liner, with a real exit-code contract instead of "did it seem to work."

The two directions are asymmetric on purpose, because the underlying Claude
Code platforms are asymmetric (see [Platform asymmetry](#platform-asymmetry)):

- **Mac to a fresh Windows session (`ask-asus`):** starts a brand-new,
  hook-free Windows `claude -p`, waits for its one-shot answer, and returns
  that answer to the Mac. It does not target a live Windows chat — Windows
  Claude builds at the time this was built had no way to message an existing
  session.
- **Windows to an already-running Mac session (`Send-MacRelay`):** messages a
  live Claude Code Desktop session on the Mac through its `SendMessage` tool,
  and optionally waits for a reply file the Mac session writes back.

Either leg lets an agent on one machine delegate a sub-question to an agent on
a totally different machine, and get a real success/failure signal back
instead of guessing from silence.

## Exit-code contract

`ask-asus.sh` (Mac to Windows) returns one of:

| Code | Meaning |
|---|---|
| `0` | Answered — the answer body is on stdout |
| `3` | Transport/setup failure (SSH, argument, or filesystem error) |
| `4` | Timeout |
| `5` | Windows Claude ran but failed |

`Send-MacRelay.ps1` (Windows to Mac) exits `0` on a confirmed send (and, with
`-WaitReply`, a returned answer), `2` on a relay/transport failure, and `4` if
`-WaitReply` timed out with no reply file.

## One-line usage in each direction

Windows to a live Mac Desktop session, from this folder:

```powershell
.\windows\Send-MacRelay.ps1 -Message "Check the task and write your reply to the outbox." -WaitReply
```

Mac Desktop session replying back to the waiting Windows command:

```bash
mkdir -p ~/School/asus/outbox
printf '%s\n' 'Reply text' > ~/School/asus/outbox/reply-$(date +%s).txt
```

Mac to a fresh Windows Claude session:

```bash
printf '%s\n' 'Inspect the Windows workspace and answer this question.' | bash mac/ask-asus.sh
```

`ask-asus.sh` accepts `--timeout <seconds>` (default `300`) and `--keep`. It
prints only the answer body to stdout and archives the question and answer at
`~/School/asus/outbox/<utc-timestamp>-ask-asus.md`.

For a multiline or quote-heavy Windows-to-Mac message, use `-File .\prompt.txt`.
The PowerShell wrapper sends UTF-8 bytes through SSH stdin; the message is
never placed in the remote command line.

## Two failure modes that look like something they are not

**`exit 3` from `ask-asus.sh`, run *inside* a Claude Code session's own
sandbox, is NOT a transport fault.** A Claude Code session's network allowlist
can block outbound SSH entirely — the OS returns `Operation not permitted`,
which surfaces as the exact same `exit 3, question transport failed` a
genuinely broken key or a dead host would produce. It reads like a broken
key, a broken PowerShell runner, or a dead remote machine. It is none of
those. **Rerun outside the sandbox and it succeeds.** Check this before
debugging anything on the Windows side — making it work inside the sandbox
permanently means allowlisting that host, which is a deliberate choice, not a
bug fix.

**SSH from a Bash tool does not work; SSH from a PowerShell tool does.** Git
Bash ships its own `ssh` binary, which cannot reach the Windows `ssh-agent`
service holding the decrypted key. Any Bash-side SSH from Windows to the Mac
has to call the Windows OpenSSH binary explicitly, e.g.:

```bash
/c/Windows/System32/OpenSSH/ssh.exe -o BatchMode=yes <mac-user>@<mac-tailscale-ip> "..."
```

This silently broke a monitor on its first arming — it reported "could not
reach the Mac" while the identical command through a PowerShell tool worked
fine. Whichever `ssh` happens to be first on `PATH` is not a safe assumption.

## Setup

This was built for one specific pair of machines and still has the real
values as placeholders — it is a personal tool, not a packaged installer.
Before using it, edit the placeholder values in these four files:

| File | Placeholders to edit |
|---|---|
| `mac/ask-asus.sh` | `target`, `runner` (Windows SSH target + path to `Answer-Ask.ps1`) |
| `windows/Send-MacRelay.ps1` | `$SshTarget`, `$RelayPath`, `$OutboxPath` (Mac SSH target + paths) |
| `windows/Answer-Ask.ps1` | `$ClaudePath`, `$WorkspacePath` (or set `ASK_ASUS_CLAUDE` / `ASK_ASUS_WORKSPACE` env vars instead) |
| `mac/relay-send.sh` | none — resolves the live Claude session via `claude agents --json`, no hardcoded values |

Both directions assume:

- Key-based, non-interactive SSH already works between the two machines.
- `claude` (or `~/.local/bin/claude`) is on the Mac's `PATH` for non-interactive
  shells — the OAuth token needs to be exported from a file the shell actually
  sources for non-interactive sessions (e.g. `~/.zshenv`, not `~/.zshrc`).
- The Mac session only ever writes inside its own designated write root —
  `relay-send.sh` and `Send-MacRelay.ps1` don't enforce that on their own; it
  is enforced by whatever sandboxing the Mac Claude session itself runs
  under.

### Platform asymmetry

Claude Code peer discovery and messaging (`ListAgents` / `SendMessage`) were
platform-gated at the time this was built, not version-gated: available on
macOS builds, absent on Windows builds of the same version. That is why the
Windows-to-Mac leg messages a *live* Mac session directly, while the
Mac-to-Windows leg has to spin up a *fresh* one-shot session and collect its
answer through a file instead.

## What this does NOT do

- Run a daemon, or keep a permanent Claude CLI peer alive.
- Hardcode or remember a specific session name on the Mac side — it always
  resolves the newest running session (or `--name`) at call time.
- Confirm delivery merely because `SendMessage` reported success.
- Auto-pick up work on the Mac side — the Desktop session has to act on the
  message itself.
- Create a reply automatically. A reply requires the Mac session to write a
  new file to its outbox; `-WaitReply` only watches for that file to appear.
- Deliver into a live Windows chat session (see platform asymmetry above).
- Run Windows session hooks, including any workspace auto-commit hook — the
  fresh `claude -p` invocation loads no inherited settings and gets an
  explicit empty hook configuration.

## Tests

Offline, no SSH or network required:

```bash
bash tests/test-relay.sh      # Mac-side relay-send.sh, pure bash + python3
bash tests/test-ask-asus.sh   # Windows return leg, needs a PowerShell host
```

`test-relay.sh` stubs the `claude` CLI directly and is fully portable — CI
runs it for real on both Ubuntu and macOS.

`test-ask-asus.sh` exercises the *real* `Answer-Ask.ps1` runner against a
compiled C# console-app stub (`tests/claude-stub.cs`) standing in for
`claude.exe`. It picks `powershell.exe` (Windows) or `pwsh` (installed
elsewhere) if either is present, and prints `SKIP` and exits `0` if neither
is. Measured on GitHub's `ubuntu-latest` and `macos-latest` runners: `pwsh`
*is* preinstalled, but its `Add-Type -OutputType ConsoleApplication` cannot
produce a native executable outside Windows, so the compile step fails and
this test genuinely SKIPs there — it isn't a CI shortcut, it's what actually
happens. The return leg it covers only runs on a live Windows box in
practice, so run it there directly.

## Size

8 files, ~37 KB total — 4 shipped scripts (`ask-asus.sh`, `relay-send.sh`,
`Send-MacRelay.ps1`, `Answer-Ask.ps1`, ~20 KB combined), 2 test scripts plus
one C# test stub (~11 KB combined), and this README.
