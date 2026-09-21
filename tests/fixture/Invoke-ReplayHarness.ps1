#Requires -Version 7.0
<#
.SYNOPSIS
    A stand-in for an AI CLI that replays a recorded review instead of calling a model.

.DESCRIPTION
    Invoke-PrReview.ps1 calls a harness once per changed file and once for the integration
    pass, handing it a prompt file. This script answers the same way a model would, with a
    fenced json block, but takes the answer from a recording:

      - a per-file prompt ("File: <path>") gets that file's line from file-results.jsonl
      - the integration prompt ("## Findings to verify") gets integration-result.json

    The integration reply is preceded by a line of prose on purpose, so the driver's JSON
    extraction is exercised the way a real model's chatty reply would exercise it.

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

if ($prompt -match '(?m)^## Findings to verify') {
    $json = [System.IO.File]::ReadAllText((Join-Path $RecordingDir 'integration-result.json')).Trim()
    Write-Output "Here is the integration result, replayed from the recording."
    Write-Output ($fence + 'json')
    Write-Output $json
    Write-Output $fence
    exit 0
}

$match = [regex]::Match($prompt, '(?m)^File:\s*(.+?)\s*$')
if (-not $match.Success) {
    Write-Output 'Replay harness: the prompt has no "File:" line and no findings to verify.'
    exit 1
}
$path = $match.Groups[1].Value

foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $RecordingDir 'file-results.jsonl'))) {
    if (-not $line.Trim()) { continue }
    $recorded = $line | ConvertFrom-Json
    if ([string]$recorded.file -eq $path) {
        Write-Output ($fence + 'json')
        Write-Output $line
        Write-Output $fence
        exit 0
    }
}

Write-Output "Replay harness: no recorded result for $path."
exit 1
