[CmdletBinding(DefaultParameterSetName = 'Message')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Message', Position = 0)]
    [string]$Message,

    [Parameter(Mandatory = $true, ParameterSetName = 'File')]
    [string]$File,

    [string]$Name,
    [switch]$WaitReply,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSec = 180
)

# Edit these three for your own machines before running.
$SshTarget = '<mac-user>@<mac-tailscale-ip>'
$RelayPath = '/Users/<mac-user>/School/asus/mac-bridge/mac/relay-send.sh'
$OutboxPath = '/Users/<mac-user>/School/asus/outbox'
$SecretPattern = 'sk-ant-[A-Za-z0-9_.-]*'

function Scrub-RelayText([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, $SecretPattern, '[REDACTED]')
}

function Stop-Relay([string]$Text, [int]$Code) {
    [Console]::Error.WriteLine((Scrub-RelayText $Text))
    exit $Code
}

function Invoke-SshText([string]$RemoteCommand, [string]$InputText, [int]$LimitSec) {
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = 'ssh.exe'
    $start.Arguments = "-o BatchMode=yes -o ConnectTimeout=10 $SshTarget $RemoteCommand"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
    } catch {
        return [pscustomobject]@{ ExitCode = 127; Stdout = ''; Stderr = $_.Exception.Message }
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
    try {
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Close()
    } catch {
        # SSH may close stdin early; its exit code and stderr carry the verdict.
    }

    if (-not $process.WaitForExit($LimitSec * 1000)) {
        try { $process.Kill() } catch { }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = 124
            Stdout = $stdoutTask.Result
            Stderr = ($stderrTask.Result + "`nSSH timed out")
        }
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

if ($Name -and $Name -notmatch '^[A-Za-z0-9._-]+$') {
    Stop-Relay '-Name may contain only letters, digits, dot, underscore, and hyphen.' 2
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
    try {
        $resolvedFile = (Resolve-Path -LiteralPath $File -ErrorAction Stop).Path
        $body = [System.IO.File]::ReadAllText($resolvedFile)
    } catch {
        Stop-Relay ("Could not read -File: " + $_.Exception.Message) 2
    }
} else {
    $body = $Message
}

$baseline = New-Object 'System.Collections.Generic.HashSet[string]'
$listCommand = "/bin/mkdir -p $OutboxPath; /usr/bin/find $OutboxPath -type f -print"
if ($WaitReply) {
    $before = Invoke-SshText $listCommand '' 20
    if ($before.ExitCode -ne 0) {
        Stop-Relay ("Could not record the outbox before sending: " + $before.Stderr) 2
    }
    foreach ($path in ($before.Stdout -split "\r?\n")) {
        if ($path) { [void]$baseline.Add($path) }
    }
}

$remoteCommand = "/bin/bash $RelayPath --timeout $TimeoutSec"
if ($Name) { $remoteCommand += " --name $Name" }
$sent = Invoke-SshText $remoteCommand $body ($TimeoutSec + 30)
$cleanOut = Scrub-RelayText $sent.Stdout
$cleanErr = Scrub-RelayText $sent.Stderr

$verdictLine = $null
$verdict = $null
foreach ($line in ($cleanOut -split "\r?\n")) {
    if (-not $line) { continue }
    try {
        $candidate = $line | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $candidate.PSObject.Properties['ok'] -and
            $null -ne $candidate.PSObject.Properties['sessionId']) {
            $verdictLine = $line
            $verdict = $candidate
        }
    } catch { }
}

if ($null -eq $verdictLine) {
    Stop-Relay ("Relay returned no JSON verdict. stdout: $cleanOut stderr: $cleanErr") 2
}
[Console]::Out.WriteLine($verdictLine)
if ($sent.ExitCode -ne 0) {
    if ($cleanErr) { [Console]::Error.WriteLine($cleanErr.Trim()) }
    exit $sent.ExitCode
}
if (-not $verdict.ok) { Stop-Relay 'Relay returned ok:false with a zero process exit code.' 2 }
if (-not $WaitReply) { exit 0 }

$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
while ([DateTime]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 1
    $after = Invoke-SshText $listCommand '' 20
    if ($after.ExitCode -ne 0) { continue }
    $newFile = $null
    foreach ($path in ($after.Stdout -split "\r?\n")) {
        if ($path -and -not $baseline.Contains($path)) {
            $newFile = $path
            break
        }
    }
    if ($null -eq $newFile) { continue }
    if ($newFile -notmatch ('^' + [regex]::Escape($OutboxPath) + '/[A-Za-z0-9._/-]+$')) {
        Stop-Relay 'A new outbox file had an unsafe path; refusing to put it in a remote command.' 2
    }
    $reply = Invoke-SshText ("/bin/cat " + $newFile) '' 20
    if ($reply.ExitCode -ne 0) { continue }
    [Console]::Out.Write((Scrub-RelayText $reply.Stdout))
    exit 0
}

Stop-Relay "sent but no reply within $TimeoutSec s" 4
