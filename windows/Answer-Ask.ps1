[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$QuestionFile,
    [Parameter(Mandatory = $true)]
    [string]$AnswerFile,
    [ValidateRange(1, 3600)]
    [int]$TimeoutSec = 300
)

$SecretPattern = 'sk-ant-[A-Za-z0-9_.-]*'
# Edit these two for your own machine, or override via ASK_ASUS_CLAUDE / ASK_ASUS_WORKSPACE.
$ClaudePath = 'C:\Users\<win-user>\.local\bin\claude.exe'
$WorkspacePath = 'C:\Users\<win-user>\workspace'
if ($env:ASK_ASUS_CLAUDE) { $ClaudePath = $env:ASK_ASUS_CLAUDE }
if ($env:ASK_ASUS_WORKSPACE) { $WorkspacePath = $env:ASK_ASUS_WORKSPACE }

function Scrub([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, $SecretPattern, '[REDACTED]')
}

function Verdict([bool]$Ok, [string]$Status, [int]$Code, [string]$Detail) {
    $result = [ordered]@{
        ok = $Ok
        status = $Status
        exitCode = $Code
        detail = (Scrub $Detail)
    }
    [Console]::Out.WriteLine(($result | ConvertTo-Json -Compress))
    exit $Code
}

try {
    $questionPath = (Resolve-Path -LiteralPath $QuestionFile -ErrorAction Stop).Path
    $questionBytes = [System.IO.File]::ReadAllBytes($questionPath)
    $answerPath = [System.IO.Path]::GetFullPath($AnswerFile)
    $answerParent = [System.IO.Path]::GetDirectoryName($answerPath)
    if (-not [System.IO.Directory]::Exists($answerParent)) {
        throw "Answer directory does not exist: $answerParent"
    }
} catch {
    Verdict $false 'claude_error' 5 $_.Exception.Message
}

$settingsFile = [System.IO.Path]::GetTempFileName()
$utf8 = New-Object System.Text.UTF8Encoding($false)
try {
    # Load no inherited settings, then explicitly provide an empty hook configuration.
    $settings = '{"hooks":{}}'
    [System.IO.File]::WriteAllText($settingsFile, $settings, $utf8)

    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $ClaudePath
    $start.Arguments = "-p --output-format text --setting-sources `"`" --settings `"$settingsFile`""
    $start.WorkingDirectory = $WorkspacePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.BaseStream.Write($questionBytes, 0, $questionBytes.Length)
    $process.StandardInput.BaseStream.Close()

    if (-not $process.WaitForExit($TimeoutSec * 1000)) {
        try { $process.Kill() } catch { }
        $process.WaitForExit()
        Verdict $false 'timeout' 4 "Claude timed out after $TimeoutSec seconds."
    }

    $answer = Scrub $stdoutTask.Result
    $errorText = Scrub $stderrTask.Result
    if ($process.ExitCode -ne 0) {
        Verdict $false 'claude_error' 5 "Claude exited $($process.ExitCode): $errorText"
    }
    if ([string]::IsNullOrWhiteSpace($answer)) {
        Verdict $false 'claude_error' 5 'Claude returned an empty answer.'
    }
    [System.IO.File]::WriteAllText($answerPath, $answer, $utf8)
} catch {
    Verdict $false 'claude_error' 5 $_.Exception.Message
} finally {
    if ($settingsFile -and [System.IO.File]::Exists($settingsFile)) {
        [System.IO.File]::Delete($settingsFile)
    }
}

Verdict $true 'answered' 0 ''
