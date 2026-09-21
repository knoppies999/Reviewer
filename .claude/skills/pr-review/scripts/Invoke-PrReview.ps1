#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the whole pull-request review unattended with a headless AI CLI: one process per changed file,
    one for the integration pass, then a deterministic merge. Works with any harness defined under
    "harnesses" in config.json (GitHub Copilot CLI and Claude Code are provided).

.DESCRIPTION
    Steps: compute the change set (Get-PrDiff.ps1, unless -ManifestPath is given) -> write one prompt file
    per reviewable file from references/prompt-file-review.md -> run the harness CLI for each with a
    parallel limit, retries and a timeout, collecting the JSON results into file-results.jsonl -> build
    the integration prompt from references/prompt-integration.md and run it once -> Merge-ReviewResults.ps1
    writes findings.json and report.md. Prompts and raw responses are kept under <out>/prompts and
    <out>/responses for debugging.

    This is the path for pipelines and scripts. The interactive skill (SKILL.md) covers chat sessions.

.PARAMETER Harness
    Name of a harness in config.json ("copilot" or "claude" out of the box).
.PARAMETER Base, Head, IncludeWorkingTree, RepositoryPath, OutputDir
    Passed to Get-PrDiff.ps1 when no -ManifestPath is given.
.PARAMETER ManifestPath
    Use an existing manifest (skips Get-PrDiff.ps1). The pipeline template passes this.
.PARAMETER Model
    Model id for the harness (filled into its modelArgs). Empty = the harness default.
.PARAMETER MaxParallel
    Parallel per-file reviews. Default: config maxParallelSubagents.
.PARAMETER TimeoutMinutes
    Per-call timeout for file reviews (the integration pass gets twice this).
.PARAMETER MaxRetries
    Retries per call after a failed or unparsable response. Default 1.
.PARAMETER ExtraArgs
    Extra arguments appended to every harness call.
.PARAMETER CI
    Treat as unattended CI run (also inferred from TF_BUILD / CI=true): appends the harness's ciArgs.
.PARAMETER SkipIntegration
    Skip the integration pass (findings stay unverified).
.PARAMETER DryRun
    Write the prompts and print the commands that would run, without calling the harness.
.EXAMPLE
    pwsh -File Invoke-PrReview.ps1 -Harness claude -Base develop
.EXAMPLE
    pwsh -File Invoke-PrReview.ps1 -Harness copilot -ManifestPath out/manifest.json -CI -Model claude-sonnet-5
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Harness,
    [string]$Base,
    [string]$Head = 'HEAD',
    [switch]$IncludeWorkingTree,
    [string]$RepositoryPath,
    [string]$OutputDir,
    [string]$ManifestPath,
    [string]$Model,
    [int]$MaxParallel = 0,
    [int]$TimeoutMinutes = 20,
    [int]$MaxRetries = 1,
    [string[]]$ExtraArgs,
    [string]$ConfigPath,
    [switch]$CI,
    [switch]$SkipIntegration,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$isCI = $CI -or (-not [string]::IsNullOrEmpty($env:TF_BUILD)) -or ($env:CI -eq 'true')
$startedAt = Get-Date

function Get-Prop {
    # Safe property/key lookup with a default. Null checks use ReferenceEquals instead of -eq/-ne so they
    # never go through PowerShell's polymorphic comparison binder, which was observed to throw
    # "Argument types do not match" (PSToObjectArrayBinder) once one site had seen many value types.
    param($Object, [string]$Name, $Default = $null)
    if ([object]::ReferenceEquals($Object, $null)) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $v = $Object[$Name]
            if (-not [object]::ReferenceEquals($v, $null)) { return $v }
        }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ([object]::ReferenceEquals($p, $null)) { return $Default }
    $v = $p.Value
    if ([object]::ReferenceEquals($v, $null)) { return $Default }
    return $v
}
function Write-Utf8File { param([string]$Path, [AllowEmptyString()][string]$Content) [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom) }
function Expand-Template {
    param([string]$Template, [hashtable]$Values)
    foreach ($k in $Values.Keys) { $Template = $Template.Replace('{{' + $k + '}}', [string]$Values[$k]) }
    return $Template
}
function Get-JsonBlock {
    # Extracts the first ```json block (or the whole text, or the outermost {...}) and parses it.
    param([string]$Text)
    if (-not $Text) { return $null }
    $candidates = @()
    $m = [regex]::Match($Text, '```json\s*([\s\S]*?)```')
    if ($m.Success) { $candidates += $m.Groups[1].Value }
    $m2 = [regex]::Match($Text, '```\s*([\s\S]*?)```')
    if ($m2.Success) { $candidates += $m2.Groups[1].Value }
    $candidates += $Text
    $i = $Text.IndexOf('{'); $j = $Text.LastIndexOf('}')
    if ($i -ge 0 -and $j -gt $i) { $candidates += $Text.Substring($i, $j - $i + 1) }
    foreach ($c in $candidates) {
        try { $obj = $c.Trim() | ConvertFrom-Json -Depth 30; if ($obj -is [System.Management.Automation.PSCustomObject]) { return $obj } } catch { }
    }
    return $null
}
function Test-IsTestPath { param([string]$Path) return ($Path -match '(?i)(^|/)(tests?|specs?|__tests__|__mocks__)(/|$)|(?i)\.(tests?|specs?)\.[^/]+$|\.Tests?(\.|/)') }
function Get-Sha7 { param([string]$Sha) if ($Sha -and $Sha.Length -ge 7) { return $Sha.Substring(0, 7) } return $Sha }

# ---------------------------------------------------------------- config and harness

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $skillRoot 'config.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found at $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json -Depth 20
$harnesses = Get-Prop $config 'harnesses' $null
if ($null -eq $harnesses -or -not $harnesses.PSObject.Properties[$Harness]) {
    $names = if ($harnesses) { ($harnesses.PSObject.Properties.Name -join ', ') } else { 'none' }
    throw "Harness '$Harness' is not defined under 'harnesses' in $ConfigPath (defined: $names)."
}
$hdef = $harnesses.$Harness
$command = [string](Get-Prop $hdef 'command' '')
if (-not $command) { throw "Harness '$Harness' has no 'command'." }
if (-not $DryRun -and -not (Get-Command $command -ErrorAction SilentlyContinue)) {
    throw "The harness command '$command' is not on PATH. Install it first (see README.md)."
}
if ($MaxParallel -le 0) { $MaxParallel = [int](Get-Prop $config 'maxParallelSubagents' 4) }
if ($MaxParallel -le 0) { $MaxParallel = 1 }

# ---------------------------------------------------------------- change set

if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath)) {
    Write-Host "Using existing manifest $ManifestPath"
}
else {
    if ($ManifestPath) { Write-Warning "Manifest $ManifestPath not found; computing the change set." }
    $getDiff = Join-Path $scriptDir 'Get-PrDiff.ps1'
    $p = @{ ConfigPath = $ConfigPath }
    if ($Base) { $p.Base = $Base }
    if ($Head -and $Head -ne 'HEAD') { $p.Head = $Head }
    if ($IncludeWorkingTree) { $p.IncludeWorkingTree = $true }
    if ($OutputDir) { $p.OutputDir = $OutputDir }
    if ($RepositoryPath) { $p.RepositoryPath = $RepositoryPath }
    $lines = @(& $getDiff @p)
    $ManifestPath = [string]($lines | Select-Object -Last 1)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Get-PrDiff.ps1 did not produce a manifest (last output: $ManifestPath)" }
}
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 20
$out = [string]$manifest.outputDir
$repoRoot = [string]$manifest.repoRoot
$mconfig = Get-Prop $manifest 'config' $null
$promptDir = Join-Path $out 'prompts'
$respDir = Join-Path $out 'responses'
foreach ($d in @($promptDir, $respDir)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Get-ChildItem -LiteralPath $d -File | Remove-Item -Force
}
$resultsPath = Join-Path $out 'file-results.jsonl'
$integrationPath = Join-Path $out 'integration-result.json'
foreach ($stale in @($resultsPath, $integrationPath, (Join-Path $out 'findings.json'), (Join-Path $out 'report.md'))) {
    if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force }
}
Write-Utf8File -Path $resultsPath -Content ''

# ---------------------------------------------------------------- prompts

$fileTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-file-review.md') -Raw
$integrationTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-integration.md') -Raw
$fileInstructions = Get-Content -LiteralPath (Join-Path $skillRoot 'references/file-reviewer.md') -Raw
$integrationInstructions = Get-Content -LiteralPath (Join-Path $skillRoot 'references/integration-reviewer.md') -Raw

$pr = Get-Prop $manifest 'pr' $null
$title = [string](Get-Prop $pr 'title' '')
$summaryParts = @()
$desc = [string](Get-Prop $pr 'description' '')
if ($desc) { $desc = ($desc -replace '\s+', ' ').Trim(); if ($desc.Length -gt 600) { $desc = $desc.Substring(0, 600) + [string][char]0x2026 }; $summaryParts += $desc }
$subjects = @(@(Get-Prop $manifest 'commits' @()) | Select-Object -First 15 | ForEach-Object { "- $([string](Get-Prop $_ 'subject' ''))" })
if ($subjects.Count -gt 0) { $summaryParts += ("Commits:`n" + ($subjects -join "`n")) }
$prSummary = if ($summaryParts.Count -gt 0) { $summaryParts -join "`n" } else { "No description available; title: $title" }
$conventions = @(Get-Prop $mconfig 'conventions' @(Get-Prop $config 'conventions' @()))
$conventionText = if ($conventions.Count -gt 0) { $conventions -join '; ' } else { 'none specified' }
$minConfidence = [double](Get-Prop $mconfig 'minConfidence' (Get-Prop $config 'minConfidence' 0.6))
$verifyCommands = @(Get-Prop $mconfig 'verifyCommands' @(Get-Prop $config 'verifyCommands' @()))

$common = @{
    title = $title; summary = $prSummary
    baseRef = [string]$manifest.base.name; baseSha7 = Get-Sha7 ([string]$manifest.base.sha)
    headRef = [string]$manifest.head.name; headSha7 = Get-Sha7 ([string]$manifest.head.sha)
    repoRoot = $repoRoot; skillRoot = $skillRoot; manifestPath = $ManifestPath; fullDiff = [string]$manifest.fullDiff
    minConfidence = $minConfidence; conventions = $conventionText
}

$reviewFiles = @(@(Get-Prop $manifest 'files' @()) | Where-Object { [string](Get-Prop $_ 'reviewMode' '') -eq 'review' })
$ordered = @($reviewFiles | Sort-Object -Property @{ Expression = { if (Test-IsTestPath ([string]$_.path)) { 1 } else { 0 } } }, @{ Expression = { -([int]$_.additions + [int]$_.deletions) } })
$items = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($f in $ordered) {
    $i++
    $status = [string]$f.status
    if ($status -eq 'renamed' -and $f.oldPath) { $status = "renamed from $($f.oldPath)" }
    $checklists = "$skillRoot/references/checklist-general.md"
    if ([string]$f.checklist -and [string]$f.checklist -ne 'general') { $checklists += " and $skillRoot/references/checklist-$($f.checklist).md" }
    $values = $common.Clone()
    $values.path = [string]$f.path; $values.status = $status
    $values.additions = $f.additions; $values.deletions = $f.deletions; $values.newFileLines = $f.newFileLines
    $values.largeNote = if ($f.large) { '; LARGE diff: focus on the hunks and their surroundings' } else { '' }
    $values.diffFile = [string]$f.diffFile; $values.checklists = $checklists
    $values.instructions = $fileInstructions
    $promptFile = Join-Path $promptDir ('file-{0:000}.md' -f $i)
    Write-Utf8File -Path $promptFile -Content (Expand-Template -Template $fileTemplate -Values $values)
    $items.Add([pscustomobject]@{
            Index = $i; Path = [string]$f.path; PromptFile = $promptFile
            ResponseFile = Join-Path $respDir ('file-{0:000}.txt' -f $i)
            Attempt = 0; Job = $null; Started = $null; Done = $false; Findings = 0; Seconds = 0.0
        })
}
Write-Host "Harness: $Harness ($command)  files to review: $($items.Count)  parallel: $MaxParallel  timeout: $TimeoutMinutes min  output: $out"

# ---------------------------------------------------------------- harness invocation

function Get-CliArgs {
    param([string]$PromptFile, [string]$Kind)
    $prompt = "Read the file `"$PromptFile`" and carry out the instructions in it exactly. Reply with the single JSON block it asks for and nothing else."
    $tools = [string](Get-Prop $hdef 'fileReviewTools' '')
    if ($Kind -eq 'integration') {
        $tools = [string](Get-Prop $hdef 'integrationTools' '')
        foreach ($vc in $verifyCommands) {
            $verb = ([string]$vc).Trim().Split(' ')[0]
            if ($verb) { $tools += ",Bash($verb *)" }
        }
    }
    $values = @{ prompt = $prompt; promptFile = $PromptFile; repoRoot = $repoRoot; outputDir = $out; skillRoot = $skillRoot; model = $Model; allowedTools = $tools.Trim(',') }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(Get-Prop $hdef 'args' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) }
    if ($Model) { foreach ($a in @(Get-Prop $hdef 'modelArgs' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) } }
    if ($isCI) { foreach ($a in @(Get-Prop $hdef 'ciArgs' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) } }
    if ($Kind -eq 'integration') { foreach ($a in @(Get-Prop $hdef 'integrationArgs' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) } }
    foreach ($a in @($ExtraArgs)) { if ($a) { $list.Add([string]$a) } }
    return $list.ToArray()
}

$jobScript = {
    param([string]$Command, [string[]]$Arguments, [string]$WorkDir, [string]$OutFile)
    Set-Location -LiteralPath $WorkDir
    $ErrorActionPreference = 'Continue'
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $output = & $Command @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $text = ($output -join "`n")
    [System.IO.File]::WriteAllText($OutFile, $text, [System.Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Format-Command {
    param([string[]]$Arguments)
    return (@($command) + @($Arguments | ForEach-Object { if ($_ -match '\s|"') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })) -join ' '
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'Dry run: prompts written, nothing executed.'
    if ($items.Count -gt 0) { Write-Host "  file review:  $(Format-Command (Get-CliArgs -PromptFile $items[0].PromptFile -Kind 'file'))" }
    Write-Host "  integration:  $(Format-Command (Get-CliArgs -PromptFile (Join-Path $promptDir 'integration.md') -Kind 'integration'))"
    Write-Host "  prompts in:   $promptDir"
    exit 0
}

# environment requested by the harness (restored afterwards)
$envBackup = @{}
foreach ($p in @((Get-Prop $hdef 'env' $null).PSObject.Properties)) {
    if ($null -eq $p) { continue }
    $envBackup[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name)
    if (-not [Environment]::GetEnvironmentVariable($p.Name)) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value) }
}

function Invoke-Reviewer {
    # Starts one harness call as a background job; returns the job.
    param([string]$PromptFile, [string]$Kind, [string]$ResponseFile)
    $cliArgs = Get-CliArgs -PromptFile $PromptFile -Kind $Kind
    return Start-Job -ScriptBlock $jobScript -ArgumentList @($command, $cliArgs, $repoRoot, $ResponseFile)
}

function Complete-Job {
    # Collects a finished/timed-out job. Returns @{ Output; ExitCode; TimedOut }.
    param($Job, [bool]$TimedOut)
    if ($TimedOut) {
        Stop-Job -Job $Job -ErrorAction SilentlyContinue
        $r = @{ Output = ''; ExitCode = -1; TimedOut = $true }
    }
    else {
        $res = @(Receive-Job -Job $Job -ErrorAction SilentlyContinue) | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] -and $null -ne $_.PSObject.Properties['ExitCode'] } | Select-Object -Last 1
        if ($res) { $r = @{ Output = [string]$res.Output; ExitCode = [int]$res.ExitCode; TimedOut = $false } }
        else { $r = @{ Output = ''; ExitCode = -1; TimedOut = $false } }
    }
    Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    return $r
}

try {
    # ------------------------------------------------------------ per-file reviews
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($it in $items) { $pending.Enqueue($it) }
    $running = [System.Collections.Generic.List[object]]::new()
    $failedItems = 0
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $MaxParallel) {
            $it = $pending.Dequeue()
            $it.Attempt++
            $it.Started = Get-Date
            $it.Job = Invoke-Reviewer -PromptFile $it.PromptFile -Kind 'file' -ResponseFile $it.ResponseFile
            $running.Add($it)
            Write-Host ("[{0:HH:mm:ss}] start   {1} (attempt {2})" -f (Get-Date), $it.Path, $it.Attempt)
        }
        Start-Sleep -Milliseconds 1500
        foreach ($it in @($running)) {
            $state = [string]$it.Job.State
            $elapsed = ((Get-Date) - $it.Started).TotalMinutes
            $timedOut = ($elapsed -gt $TimeoutMinutes) -and ($state -eq 'Running')
            if ($state -notin @('Completed', 'Failed', 'Stopped') -and -not $timedOut) { continue }
            $running.Remove($it) | Out-Null
            $r = Complete-Job -Job $it.Job -TimedOut $timedOut
            $it.Seconds = [math]::Round(((Get-Date) - $it.Started).TotalSeconds, 1)
            $parsed = if ($r.TimedOut) { $null } else { Get-JsonBlock -Text $r.Output }
            $valid = ($null -ne $parsed) -and ($null -ne $parsed.PSObject.Properties['findings'])
            if ($valid) {
                $parsed | Add-Member -Force -NotePropertyName 'file' -NotePropertyValue $it.Path
                $count = @($parsed.findings).Count
                [System.IO.File]::AppendAllText($resultsPath, (($parsed | ConvertTo-Json -Depth 30 -Compress) + "`n"), $utf8NoBom)
                $it.Done = $true; $it.Findings = $count
                Write-Host ("[{0:HH:mm:ss}] done    {1}: {2} finding(s) in {3}s" -f (Get-Date), $it.Path, $count, $it.Seconds)
            }
            else {
                $why = if ($r.TimedOut) { "timed out after $TimeoutMinutes min" } elseif ($r.ExitCode -ne 0) { "exit code $($r.ExitCode)" } else { 'no valid JSON result in the response' }
                if ($it.Attempt -le $MaxRetries) {
                    Write-Warning "$($it.Path): $why; retrying."
                    $pending.Enqueue($it)
                }
                else {
                    $failedItems++
                    $errLine = [ordered]@{ file = $it.Path; error = "$why after $($it.Attempt) attempt(s); see $($it.ResponseFile)" }
                    [System.IO.File]::AppendAllText($resultsPath, (($errLine | ConvertTo-Json -Compress) + "`n"), $utf8NoBom)
                    Write-Warning "$($it.Path): giving up ($why)."
                }
            }
        }
    }

    # ------------------------------------------------------------ integration pass
    $integrationRan = $false
    if ($SkipIntegration) { Write-Host 'Integration pass skipped (-SkipIntegration).' }
    elseif ($items.Count -eq 0) { Write-Host 'No reviewable files; integration pass skipped.' }
    else {
        # Same id rule as Merge-ReviewResults.ps1: manifest file order, then finding order.
        $resultsByFile = @{}
        foreach ($line in [System.IO.File]::ReadAllLines($resultsPath)) {
            if (-not $line.Trim()) { continue }
            try { $o = $line | ConvertFrom-Json -Depth 30; $resultsByFile[[string]$o.file] = $o } catch { }
        }
        $toVerify = @(); $summaries = @(); $notes = @(); $fileList = @(); $n = 0
        foreach ($mf in @(Get-Prop $manifest 'files' @())) {
            $path = [string]$mf.path
            $mode = [string](Get-Prop $mf 'reviewMode' '')
            $outcome = $mode
            if ($mode -eq 'review') {
                if ($resultsByFile.ContainsKey($path)) {
                    $res = $resultsByFile[$path]
                    if (Get-Prop $res 'error' $null) { $outcome = "review FAILED: $([string]$res.error)" }
                    else {
                        $outcome = "reviewed, $(@(Get-Prop $res 'findings' @()).Count) finding(s)"
                        $s = [string](Get-Prop $res 'summary' ''); if ($s) { $summaries += "- ${path}: $s" }
                        $nt = [string](Get-Prop $res 'notes' ''); if ($nt) { $notes += "- ${path}: $nt" }
                        foreach ($raw in @(Get-Prop $res 'findings' @())) {
                            if ($null -eq $raw) { continue }
                            $n++
                            $sev = ([string](Get-Prop $raw 'severity' '')).ToLowerInvariant()
                            if ($sev -in @('blocking', 'should-fix')) {
                                $toVerify += [ordered]@{ id = "F$n"; file = $path; line = (Get-Prop $raw 'line' $null); severity = $sev; category = [string](Get-Prop $raw 'category' ''); title = [string](Get-Prop $raw 'title' ''); detail = [string](Get-Prop $raw 'detail' '') }
                            }
                        }
                    }
                }
                else { $outcome = 'review FAILED: no result' }
            }
            elseif ($mode -eq 'skip') { $outcome = "skipped: $([string](Get-Prop $mf 'skipReason' ''))" }
            elseif ($mode -eq 'deleted') { $outcome = 'deleted' }
            $fileList += "- $path  [$([string]$mf.status), +$($mf.additions)/-$($mf.deletions)]  $outcome"
        }
        $values = $common.Clone()
        $values.fileList = ($fileList -join "`n")
        $values.summaries = if ($summaries.Count) { $summaries -join "`n" } else { '(none)' }
        $values.notes = if ($notes.Count) { $notes -join "`n" } else { '(none)' }
        $values.findingsToVerify = if ($toVerify.Count) { ($toVerify | ConvertTo-Json -Depth 5) } else { '[]' }
        $values.verifyCommands = if ($verifyCommands.Count) { ($verifyCommands | ForEach-Object { "- $_" }) -join "`n" } else { 'none' }
        $values.instructions = $integrationInstructions
        $integrationPrompt = Join-Path $promptDir 'integration.md'
        Write-Utf8File -Path $integrationPrompt -Content (Expand-Template -Template $integrationTemplate -Values $values)

        $attempt = 0
        while (-not $integrationRan -and $attempt -le $MaxRetries) {
            $attempt++
            $started = Get-Date
            Write-Host ("[{0:HH:mm:ss}] start   integration pass (attempt {1}, {2} finding(s) to verify)" -f (Get-Date), $attempt, $toVerify.Count)
            $respFile = Join-Path $respDir "integration-$attempt.txt"
            $job = Invoke-Reviewer -PromptFile $integrationPrompt -Kind 'integration' -ResponseFile $respFile
            $limit = $TimeoutMinutes * 2
            while ($job.State -eq 'Running' -and ((Get-Date) - $started).TotalMinutes -lt $limit) { Start-Sleep -Milliseconds 1500 }
            $r = Complete-Job -Job $job -TimedOut ($job.State -eq 'Running')
            $parsed = if ($r.TimedOut) { $null } else { Get-JsonBlock -Text $r.Output }
            $valid = ($null -ne $parsed) -and (($null -ne $parsed.PSObject.Properties['verifications']) -or ($null -ne $parsed.PSObject.Properties['findings']) -or ($null -ne $parsed.PSObject.Properties['assessment']))
            if ($valid) {
                Write-Utf8File -Path $integrationPath -Content ($parsed | ConvertTo-Json -Depth 30)
                $integrationRan = $true
                Write-Host ("[{0:HH:mm:ss}] done    integration pass in {1}s" -f (Get-Date), [math]::Round(((Get-Date) - $started).TotalSeconds, 1))
            }
            else {
                $why = if ($r.TimedOut) { "timed out after $limit min" } elseif ($r.ExitCode -ne 0) { "exit code $($r.ExitCode)" } else { 'no valid JSON result in the response' }
                Write-Warning "integration pass: $why (see $respFile)."
            }
        }
        if (-not $integrationRan) { Write-Warning 'The integration pass did not complete; findings will be reported as unverified.' }
    }
}
finally {
    foreach ($k in $envBackup.Keys) { [Environment]::SetEnvironmentVariable($k, $envBackup[$k]) }
    Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------ merge
$runLog = [ordered]@{
    harness = $Harness; command = $command; model = $Model; ci = $isCI
    startedAt = $startedAt.ToUniversalTime().ToString('o'); durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    files = @($items | ForEach-Object { [ordered]@{ path = $_.Path; attempts = $_.Attempt; ok = $_.Done; findings = $_.Findings; seconds = $_.Seconds } })
    integrationPassRan = $integrationRan
}
Write-Utf8File -Path (Join-Path $out 'driver-run.json') -Content ($runLog | ConvertTo-Json -Depth 6)

if ($items.Count -gt 0 -and $failedItems -eq $items.Count) {
    Write-Warning 'Every per-file review failed; check the responses folder and the harness authentication.'
}
& (Join-Path $scriptDir 'Merge-ReviewResults.ps1') -OutputDir $out -ConfigPath $ConfigPath -PrintReport:(-not $isCI)
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { exit 2 }
if ($items.Count -gt 0 -and $failedItems -eq $items.Count) { exit 3 }
exit 0
