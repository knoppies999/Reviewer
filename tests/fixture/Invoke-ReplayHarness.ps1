#Requires -Version 7.0
<#
.SYNOPSIS
    A stand-in for an AI CLI that replays a recorded review instead of calling a model.

.DESCRIPTION
    Invoke-PrReview.ps1 calls a harness once per unit of review work, handing it a prompt file.
    This script answers the same way a model would, with a fenced json block, but takes the answer
    from a recording:

      - a per-file prompt (one or more "File: <path>" lines) gets those files' lines from
        file-results.jsonl, as a bare object for one file and as { "results": [...] } for a batch
      - the verification prompt ("## Findings to verify") gets the recording's verifications
      - the contracts prompt ("## Files in the change set", without findings to verify) gets the
        recording's findings, assessment and verifyCommands

    Replies are preceded by a line of prose on purpose, so the driver's JSON extraction is
    exercised the way a real model's chatty reply would exercise it.

    Used by tests/Invoke-SelfTest.ps1 to run the complete driver, merge and gate path
    deterministically and without credentials.

.PARAMETER PromptFile
    The prompt file the driver wrote.
.PARAMETER RecordingDir
    Directory holding file-results.jsonl and integration-result.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PromptFile,
    [Parameter(Mandatory = $true)][string]$RecordingDir
)

$ErrorActionPreference = 'Stop'
$prompt = [System.IO.File]::ReadAllText($PromptFile)
$fence = '```'

function Write-JsonReply {
    param([string]$Prose, [string]$Json)
    if ($Prose) { Write-Output $Prose }
    Write-Output ($fence + 'json')
    Write-Output $Json
    Write-Output $fence
}

$integrationPath = Join-Path $RecordingDir 'integration-result.json'

# The verification pass: only the verdicts.
if ($prompt -match '(?m)^## Findings to verify') {
    $recorded = Get-Content -LiteralPath $integrationPath -Raw | ConvertFrom-Json -Depth 30
    $reply = [ordered]@{}
    $reply.verifications = @($recorded.verifications)
    Write-JsonReply -Prose 'Here are the verdicts, replayed from the recording.' -Json ($reply | ConvertTo-Json -Depth 30)
    exit 0
}

# The contracts pass: the cross-file findings and the assessment.
if ($prompt -match '(?m)^## Files in the change set') {
    $recorded = Get-Content -LiteralPath $integrationPath -Raw | ConvertFrom-Json -Depth 30
    $reply = [ordered]@{}
    $reply.findings = @($recorded.findings)
    $reply.assessment = [string]$recorded.assessment
    $reply.verifyCommands = @($recorded.verifyCommands)
    Write-JsonReply -Prose 'Here is the contracts result, replayed from the recording.' -Json ($reply | ConvertTo-Json -Depth 30)
    exit 0
}

# A per-file prompt: one result per "File:" line, in the order the prompt lists them.
$paths = @([regex]::Matches($prompt, '(?m)^File:\s*(.+?)\s*$') | ForEach-Object { $_.Groups[1].Value })
if ($paths.Count -eq 0) {
    Write-Output 'Replay harness: the prompt has no "File:" line, no findings to verify and no change set.'
    exit 1
}

$recordedByPath = @{}
foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $RecordingDir 'file-results.jsonl'))) {
    if (-not $line.Trim()) { continue }
    $obj = $line | ConvertFrom-Json -Depth 30
    $recordedByPath[[string]$obj.file] = $obj
}

$results = @()
foreach ($path in $paths) {
    if (-not $recordedByPath.ContainsKey($path)) {
        Write-Output "Replay harness: no recorded result for $path."
        exit 1
    }
    $results += $recordedByPath[$path]
}

if ($results.Count -eq 1) {
    Write-JsonReply -Prose '' -Json ($results[0] | ConvertTo-Json -Depth 30)
}
else {
    $reply = [ordered]@{}
    $reply.results = @($results)
    Write-JsonReply -Prose "Reviewed $($results.Count) small files together." -Json ($reply | ConvertTo-Json -Depth 30)
}
exit 0
