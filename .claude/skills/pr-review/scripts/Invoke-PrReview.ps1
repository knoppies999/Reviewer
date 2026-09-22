#Requires -Version 7.0
<#
.SYNOPSIS
    Runs the whole pull-request review unattended with a headless AI CLI, then merges the results.
    Works with any harness defined under "harnesses" in config.json (GitHub Copilot CLI and Claude
    Code are provided).

.DESCRIPTION
    Steps: compute the change set (Get-PrDiff.ps1, unless -ManifestPath is given) -> write one
    self-contained prompt per unit of review work -> run the harness CLI for each with a parallel
    limit, retries and a timeout, collecting the JSON results into file-results.jsonl -> run the
    verification pass -> Merge-ReviewResults.ps1 writes findings.json and report.md. Prompts and raw
    responses are kept under <out>/prompts and <out>/responses for debugging.

    Three things keep the wall clock down on a large pull request.

      Self-contained prompts. Each prompt already holds the diff, the current contents of the files
      and the checklists, so a review is one tool call and an answer instead of five or six
      sequential round trips. Turn it off per part with inlineDiff, inlineFileContent and
      inlineChecklists in config.json.

      Batching. Files with tiny diffs share one call, up to filesPerSubagent files and
      batchDiffLineBudget changed lines. Anything above smallFileDiffLines still gets a call of its
      own. Set batchSmallFiles to false for strictly one file per call.

      A concurrent contracts pass. The half of the old integration pass that looks at contracts and
      wiring needs only the diff, so it starts with the first file review instead of after the last
      one. Only the verification pass, which needs the findings, waits. Set concurrentContractsPass
      to false to run it after the files instead.

    Results are cached under <repoRoot>/.pr-review-cache, keyed by the exact prompt, so re-running a
    review after changing two files only pays for those two. -NoCache turns that off.

    This is the path for pipelines and scripts. The interactive skill (SKILL.md) covers chat sessions.

.PARAMETER Harness
    Name of a harness in config.json ("copilot" or "claude" out of the box).
.PARAMETER Base, Head, IncludeWorkingTree, RepositoryPath, OutputDir
    Passed to Get-PrDiff.ps1 when no -ManifestPath is given.
.PARAMETER ManifestPath
    Use an existing manifest (skips Get-PrDiff.ps1). The pipeline template passes this.
.PARAMETER Model
    Model id for the harness (filled into its modelArgs). Empty = the harness default.
.PARAMETER FileReviewModel
    Model for the per-file reviews only. Falls back to config fileReviewModel, then -Model.
.PARAMETER IntegrationModel
    Model for the contracts and verification passes. Falls back to config integrationModel, then -Model.
.PARAMETER MaxParallel
    Parallel harness calls. Default: config maxParallelSubagents.
.PARAMETER TimeoutMinutes
    Per-call timeout for file reviews (the contracts and verification passes get twice this).
.PARAMETER MaxRetries
    Retries per call after a failed or unparsable response. Default 1.
.PARAMETER ExtraArgs
    Extra arguments appended to every harness call.
.PARAMETER NoCache
    Ignore the cache and write nothing to it.
.PARAMETER CI
    Treat as unattended CI run (also inferred from TF_BUILD / CI=true): appends the harness's ciArgs.
.PARAMETER SkipIntegration
    Skip the contracts and verification passes (findings stay unverified).
.PARAMETER DryRun
    Write the prompts and print the commands that would run, without calling the harness.
.EXAMPLE
    pwsh -File Invoke-PrReview.ps1 -Harness claude -Base develop
.EXAMPLE
    pwsh -File Invoke-PrReview.ps1 -Harness copilot -ManifestPath out/manifest.json -CI -Model claude-sonnet-5
.EXAMPLE
    pwsh -File Invoke-PrReview.ps1 -Harness claude -Base main -FileReviewModel claude-sonnet-5 -IntegrationModel claude-opus-5
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
    [string]$FileReviewModel,
    [string]$IntegrationModel,
    [int]$MaxParallel = 0,
    [int]$TimeoutMinutes = 20,
    [int]$MaxRetries = 1,
    [string[]]$ExtraArgs,
    [string]$ConfigPath,
    [switch]$NoCache,
    [switch]$CI,
    [switch]$SkipIntegration,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$isCI = $CI -or (-not [string]::IsNullOrEmpty($env:TF_BUILD)) -or ($env:CI -eq 'true')
$startedAt = Get-Date
# Bumped when a change to the prompts or this script would invalidate cached responses.
$promptSchemaVersion = 2

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
    if (-not [object]::ReferenceEquals($v, $null)) { return $v }
    return $Default
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
function Get-Fence {
    # A fence at least one backtick longer than the longest run inside the text, so content that is
    # itself Markdown cannot close the block early.
    param([string]$Text)
    $longest = 2
    foreach ($m in [regex]::Matches([string]$Text, '`+')) { if ($m.Value.Length -gt $longest) { $longest = $m.Value.Length } }
    return ([string][char]0x60) * ($longest + 1)
}
function Get-TextHash {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes([string]$Text))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

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
if ($MaxParallel -le 0) { $MaxParallel = [int](Get-Prop $config 'maxParallelSubagents' 8) }
if ($MaxParallel -le 0) { $MaxParallel = 1 }
if (-not $FileReviewModel) { $FileReviewModel = [string](Get-Prop $config 'fileReviewModel' '') }
if (-not $FileReviewModel) { $FileReviewModel = $Model }
if (-not $IntegrationModel) { $IntegrationModel = [string](Get-Prop $config 'integrationModel' '') }
if (-not $IntegrationModel) { $IntegrationModel = $Model }

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

# ---------------------------------------------------------------- settings that shape the prompts

# Two precedences. What describes the change set was decided when the manifest was written, so the
# manifest wins. What decides how this script does its work is this script's own config, so the file
# passed with -ConfigPath wins; the manifest is only the fallback for an older config without the key.
function Get-Setting { param([string]$Name, $Default) return (Get-Prop $mconfig $Name (Get-Prop $config $Name $Default)) }
function Get-DriverSetting { param([string]$Name, $Default) return (Get-Prop $config $Name (Get-Prop $mconfig $Name $Default)) }
$inlineDiff = [bool](Get-DriverSetting 'inlineDiff' $true)
$inlineContent = [bool](Get-DriverSetting 'inlineFileContent' $true)
$inlineContentMax = [int](Get-DriverSetting 'inlineFileContentMaxLines' 1200)
$inlineChecklists = [bool](Get-DriverSetting 'inlineChecklists' $true)
$batchSmall = [bool](Get-DriverSetting 'batchSmallFiles' $true)
$smallFileLines = [int](Get-DriverSetting 'smallFileDiffLines' 25)
$batchMaxFileLines = [int](Get-DriverSetting 'batchMaxFileLines' 250)
$filesPerUnit = [int](Get-DriverSetting 'filesPerSubagent' 4)
$batchLineBudget = [int](Get-DriverSetting 'batchDiffLineBudget' 150)
$concurrentContracts = [bool](Get-DriverSetting 'concurrentContractsPass' $true)
$useCache = (-not $NoCache) -and [bool](Get-DriverSetting 'cacheResults' $true)
$cacheDirName = [string](Get-DriverSetting 'cacheDirName' '.pr-review-cache')
$cacheMaxAgeDays = [int](Get-DriverSetting 'cacheMaxAgeDays' 30)
if ($filesPerUnit -lt 1) { $filesPerUnit = 1 }
if ($filesPerUnit -eq 1) { $batchSmall = $false }

$cacheDir = ''
if ($useCache) {
    $cacheDir = Join-Path $repoRoot $cacheDirName
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $cutoff = (Get-Date).AddDays( - [math]::Abs($cacheMaxAgeDays))
        Get-ChildItem -LiteralPath $cacheDir -File -Filter '*.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { Write-Warning "Cache directory $cacheDir is not usable ($($_.Exception.Message)); continuing without the cache."; $useCache = $false }
}

# ---------------------------------------------------------------- reading the new version of a file

$headSha = [string]$manifest.head.sha
$headIncludesWorkingTree = [bool](Get-Prop $manifest.head 'includesWorkingTree' $false)
$headIsCheckedOut = $headIncludesWorkingTree
if (-not $headIsCheckedOut) {
    try {
        $current = (& git -C $repoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
        $headIsCheckedOut = ([string]$current).Trim() -eq $headSha
    }
    catch { $headIsCheckedOut = $false }
}
function Get-NewFileText {
    # The new version of a changed file: from the working tree when it is the head we are reviewing,
    # otherwise from git. Returns $null when it cannot be had cheaply.
    param([string]$Path)
    if ($headIsCheckedOut) {
        $full = Join-Path $repoRoot $Path
        if (Test-Path -LiteralPath $full) {
            try { return [System.IO.File]::ReadAllText($full) } catch { return $null }
        }
    }
    try {
        $lines = @(& git -C $repoRoot show "$($headSha):$Path" 2>$null)
        if ($LASTEXITCODE -eq 0) { return ($lines -join "`n") }
    }
    catch { }
    return $null
}
function Format-NumberedText {
    param([string]$Text)
    $lines = @([regex]::Split([string]$Text, "`r?`n"))
    $sb = [System.Text.StringBuilder]::new()
    for ($k = 0; $k -lt $lines.Count; $k++) { [void]$sb.AppendLine(('{0,5}  {1}' -f ($k + 1), $lines[$k])) }
    return $sb.ToString().TrimEnd()
}

# ---------------------------------------------------------------- templates and checklists

$fileTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-file-review.md') -Raw
$sectionTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-file-section.md') -Raw
$contractsTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-contracts.md') -Raw
$verifyTemplate = Get-Content -LiteralPath (Join-Path $skillRoot 'references/prompt-verify.md') -Raw
$fileInstructions = Get-Content -LiteralPath (Join-Path $skillRoot 'references/file-reviewer.md') -Raw
$contractsInstructions = Get-Content -LiteralPath (Join-Path $skillRoot 'references/contracts-reviewer.md') -Raw
$verifyInstructions = Get-Content -LiteralPath (Join-Path $skillRoot 'references/verification-reviewer.md') -Raw

$checklistCache = @{}
function Get-ChecklistText {
    param([string]$Name)
    if ($checklistCache.ContainsKey($Name)) { return $checklistCache[$Name] }
    $path = Join-Path $skillRoot "references/checklist-$Name.md"
    $text = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw } else { '' }
    $checklistCache[$Name] = $text
    return $text
}
function Get-ChecklistBlock {
    # The checklists for a unit, inlined once each, or their paths when inlining is off.
    param([string[]]$Names)
    $ordered = @('general') + @($Names | Where-Object { $_ -and $_ -ne 'general' } | Sort-Object -Unique)
    if (-not $inlineChecklists) {
        return "Load these from disk before you start:`n" + (($ordered | ForEach-Object { "- $skillRoot/references/checklist-$_.md" }) -join "`n")
    }
    $parts = @()
    foreach ($name in $ordered) {
        $text = Get-ChecklistText -Name $name
        if (-not $text) { continue }
        $parts += "### checklist-$name.md`n$text"
    }
    return ($parts -join "`n")
}

# ---------------------------------------------------------------- shared prompt values

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
$minConfidence = [double](Get-Setting 'minConfidence' 0.6)
$verifyCommands = @(Get-Prop $mconfig 'verifyCommands' @(Get-Prop $config 'verifyCommands' @()))

$common = @{
    title = $title; summary = $prSummary
    baseRef = [string]$manifest.base.name; baseSha7 = Get-Sha7 ([string]$manifest.base.sha)
    headRef = [string]$manifest.head.name; headSha7 = Get-Sha7 $headSha
    repoRoot = $repoRoot; skillRoot = $skillRoot; manifestPath = $ManifestPath; fullDiff = [string]$manifest.fullDiff
    minConfidence = $minConfidence; conventions = $conventionText
}

# ---------------------------------------------------------------- units of review work

$reviewFiles = @(@(Get-Prop $manifest 'files' @()) | Where-Object { [string](Get-Prop $_ 'reviewMode' '') -eq 'review' })
# Production before tests, then largest diff first: the long calls start first, which shortens the
# last wave, and the results that matter most land first if a run is cut short.
$ordered = @($reviewFiles | Sort-Object -Property @{ Expression = { if (Test-IsTestPath ([string]$_.path)) { 1 } else { 0 } } }, @{ Expression = { -([int]$_.additions + [int]$_.deletions) } })

$units = New-Object System.Collections.Generic.List[object]
function New-Unit { $u = [pscustomobject]@{ Files = (New-Object System.Collections.Generic.List[object]); DiffLines = 0 }; return $u }
$batch = $null
foreach ($f in $ordered) {
    $changed = [int]$f.additions + [int]$f.deletions
    $whole = [int](Get-Prop $f 'newFileLines' 0)
    # A file shares a context only when both its change and the file around it are small. A ten-line
    # change inside a nine-hundred-line file still needs a reviewer's whole attention.
    $isSmall = $batchSmall -and (-not [bool](Get-Prop $f 'large' $false)) -and ($changed -le $smallFileLines) -and ($whole -le $batchMaxFileLines)
    if (-not $isSmall) {
        $u = New-Unit; $u.Files.Add($f); $u.DiffLines = $changed
        $units.Add($u)
        continue
    }
    if ($null -ne $batch -and (($batch.Files.Count -ge $filesPerUnit) -or (($batch.DiffLines + $changed) -gt $batchLineBudget))) { $batch = $null }
    if ($null -eq $batch) { $batch = New-Unit; $units.Add($batch) }
    $batch.Files.Add($f)
    $batch.DiffLines += $changed
}

# ---------------------------------------------------------------- per-unit prompts

$items = New-Object System.Collections.Generic.List[object]
$inlinedContentFiles = 0
$i = 0
foreach ($unit in $units) {
    $i++
    # ToArray(), not @(): wrapping a generic List in an array subexpression can trip PowerShell 7's
    # PSToObjectArrayBinder with "Argument types do not match".
    $unitFiles = $unit.Files.ToArray()
    $sections = @()
    $checklistNames = @()
    $contentBudget = [math]::Max($inlineContentMax, 1500)
    $n = 0
    foreach ($f in $unitFiles) {
        $n++
        $path = [string]$f.path
        $status = [string]$f.status
        if ($status -eq 'renamed' -and $f.oldPath) { $status = "renamed from $($f.oldPath)" }
        $checklistName = [string](Get-Prop $f 'checklist' 'general')
        $checklistNames += $checklistName
        # The fence info string is the file's extension. The manifest's "language" is a copy of the
        # checklist name, so it would label a plain text or Markdown file "general".
        $language = [System.IO.Path]::GetExtension($path).TrimStart('.').ToLowerInvariant()
        if ($language -notmatch '^[a-z0-9]{1,12}$') { $language = '' }
        $diffFile = [string]$f.diffFile

        $diffBlock = "The unified diff is at $diffFile. Read it first."
        if ($inlineDiff -and (Test-Path -LiteralPath $diffFile)) {
            $diffText = ([System.IO.File]::ReadAllText($diffFile)).TrimEnd()
            $fence = Get-Fence -Text $diffText
            $diffBlock = "$fence" + "diff`n$diffText`n$fence"
        }

        $newLines = [int](Get-Prop $f 'newFileLines' 0)
        $contextBlock = "Not included here. Read $path from the repository root, at least the changed regions and the declarations they depend on."
        if ($inlineContent -and $newLines -gt 0 -and $newLines -le $inlineContentMax -and $newLines -le $contentBudget) {
            $text = Get-NewFileText -Path $path
            if ($null -ne $text) {
                $numbered = Format-NumberedText -Text $text
                $fence = Get-Fence -Text $numbered
                $contextBlock = "The whole file after the change, with line numbers:`n`n$fence$language`n$numbered`n$fence"
                $contentBudget -= $newLines
                $inlinedContentFiles++
            }
        }
        elseif ($inlineContent -and $newLines -gt $inlineContentMax) {
            $contextBlock = "Too large to include ($newLines lines). Read $path from the repository root: the changed regions with generous margins, and the declarations they depend on."
        }

        # Built by assignment: a call or a subexpression inside a hashtable literal can trip
        # PowerShell 7's PSToObjectArrayBinder with "Argument types do not match".
        $sv = @{}
        $sv.index = $n
        $sv.fileCount = $unitFiles.Count
        $sv.path = $path
        $sv.status = $status
        $sv.additions = $f.additions
        $sv.deletions = $f.deletions
        $sv.newFileLines = $newLines
        $sv.largeNote = if ($f.large) { '; LARGE diff: focus on the hunks and their surroundings' } else { '' }
        $sv.checklistName = $checklistName
        $sv.diffBlock = $diffBlock
        $sv.contextBlock = $contextBlock
        $sections += (Expand-Template -Template $sectionTemplate -Values $sv)
    }

    $values = $common.Clone()
    $values.fileSections = ($sections -join "`n")
    $values.checklistBlock = Get-ChecklistBlock -Names $checklistNames
    $values.instructions = $fileInstructions
    $promptFile = Join-Path $promptDir ('file-{0:000}.md' -f $i)
    Write-Utf8File -Path $promptFile -Content (Expand-Template -Template $fileTemplate -Values $values)
    $items.Add([pscustomobject]@{
            Index = $i; Paths = @($unitFiles | ForEach-Object { [string]$_.path }); PromptFile = $promptFile
            ResponseFile = Join-Path $respDir ('file-{0:000}.txt' -f $i)
            Attempt = 0; Job = $null; Started = $null; Done = $false; Findings = 0; Seconds = 0.0; Cached = $false
        })
}

$batched = @($items | Where-Object { $_.Paths.Count -gt 1 })
$label = "$($items.Count) call(s) for $($reviewFiles.Count) file(s)"
if ($batched.Count -gt 0) { $label += ", $($batched.Count) of them batched" }
Write-Host "Harness: $Harness ($command)  $label  parallel: $MaxParallel  timeout: $TimeoutMinutes min  output: $out"

# ---------------------------------------------------------------- harness invocation

function Get-CliArgs {
    param([string]$PromptFile, [string]$Kind)
    $prompt = "Read the file `"$PromptFile`" and carry out the instructions in it exactly. Everything you need is in that file. Reply with the single JSON block it asks for and nothing else."
    $tools = [string](Get-Prop $hdef 'fileReviewTools' '')
    $kindModel = $FileReviewModel
    if ($Kind -ne 'file') {
        $kindModel = $IntegrationModel
        $fallback = [string](Get-Prop $hdef 'integrationTools' '')
        if ($Kind -eq 'contracts') {
            $tools = [string](Get-Prop $hdef 'contractsTools' $fallback)
            foreach ($vc in $verifyCommands) {
                $verb = ([string]$vc).Trim().Split(' ')[0]
                if ($verb) { $tools += ",Bash($verb *)" }
            }
        }
        else { $tools = [string](Get-Prop $hdef 'verifyTools' $fallback) }
    }
    $values = @{ prompt = $prompt; promptFile = $PromptFile; repoRoot = $repoRoot; outputDir = $out; skillRoot = $skillRoot; model = $kindModel; allowedTools = $tools.Trim(',') }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($a in @(Get-Prop $hdef 'args' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) }
    if ($kindModel) { foreach ($a in @(Get-Prop $hdef 'modelArgs' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) } }
    if ($isCI) { foreach ($a in @(Get-Prop $hdef 'ciArgs' @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) } }
    $kindArgsName = if ($Kind -eq 'file') { 'fileArgs' } else { 'integrationArgs' }
    foreach ($a in @(Get-Prop $hdef $kindArgsName @())) { $list.Add((Expand-Template -Template ([string]$a) -Values $values)) }
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
    Write-Host "  contracts:    $(Format-Command (Get-CliArgs -PromptFile (Join-Path $promptDir 'contracts.md') -Kind 'contracts'))"
    Write-Host "  verification: $(Format-Command (Get-CliArgs -PromptFile (Join-Path $promptDir 'verify.md') -Kind 'verify'))"
    Write-Host "  prompts in:   $promptDir"
    exit 0
}

# cache: keyed by the exact prompt plus everything that changes how it is answered
function Get-CacheFile {
    param([string]$PromptFile, [string]$Kind)
    if (-not $useCache) { return '' }
    $key = @(
        "v$promptSchemaVersion", $Harness, $command, $Kind
        $(if ($Kind -eq 'file') { $FileReviewModel } else { $IntegrationModel })
        (@($ExtraArgs) -join ' ')
        [System.IO.File]::ReadAllText($PromptFile)
    ) -join "`n--`n"
    return (Join-Path $cacheDir ((Get-TextHash -Text $key) + '.txt'))
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

# ---------------------------------------------------------------- the review

$contractsResult = $null
$contractsSeconds = 0.0
$contractsCached = $false
$runContracts = (-not $SkipIntegration) -and ($items.Count -gt 0)
$cacheHits = 0

# The contracts prompt needs only the change set, so it is built and started before the file reviews.
$contractsPrompt = Join-Path $promptDir 'contracts.md'
if ($runContracts) {
    $planned = @()
    foreach ($mf in @(Get-Prop $manifest 'files' @())) {
        $mode = [string](Get-Prop $mf 'reviewMode' '')
        $outcome = switch ($mode) {
            'review' { 'reviewed in a separate pass' }
            'skip' { "skipped: $([string](Get-Prop $mf 'skipReason' ''))" }
            'deleted' { 'deleted' }
            default { $mode }
        }
        $planned += "- $([string]$mf.path)  [$([string]$mf.status), +$($mf.additions)/-$($mf.deletions)]  $outcome"
    }
    $cv = $common.Clone()
    $cv.fileList = ($planned -join "`n")
    $cv.verifyCommands = if ($verifyCommands.Count) { ($verifyCommands | ForEach-Object { "- $_" }) -join "`n" } else { 'none' }
    $cv.instructions = $contractsInstructions
    Write-Utf8File -Path $contractsPrompt -Content (Expand-Template -Template $contractsTemplate -Values $cv)
}

function Read-CachedResponse {
    param([string]$PromptFile, [string]$Kind, [string]$ResponseFile)
    $cacheFile = Get-CacheFile -PromptFile $PromptFile -Kind $Kind
    if (-not $cacheFile -or -not (Test-Path -LiteralPath $cacheFile)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($cacheFile)
        Write-Utf8File -Path $ResponseFile -Content $text
        return $text
    }
    catch { return $null }
}
function Write-CachedResponse {
    param([string]$PromptFile, [string]$Kind, [string]$Text)
    $cacheFile = Get-CacheFile -PromptFile $PromptFile -Kind $Kind
    if (-not $cacheFile) { return }
    try { Write-Utf8File -Path $cacheFile -Content $Text } catch { }
}

try {
    # ------------------------------------------------------------ contracts pass, alongside the files
    $contractsJob = $null
    $contractsStarted = $null
    $contractsAttempt = 0
    $contractsResponse = Join-Path $respDir 'contracts-1.txt'
    $contractsConcurrent = $runContracts -and $concurrentContracts -and ($MaxParallel -ge 2)
    if ($runContracts) {
        $cached = Read-CachedResponse -PromptFile $contractsPrompt -Kind 'contracts' -ResponseFile $contractsResponse
        if ($null -ne $cached) {
            $parsed = Get-JsonBlock -Text $cached
            if ($null -ne $parsed) {
                $contractsResult = $parsed; $contractsCached = $true; $cacheHits++
                Write-Host ("[{0:HH:mm:ss}] cached  contracts pass" -f (Get-Date))
            }
        }
    }
    if ($contractsConcurrent -and $null -eq $contractsResult) {
        $contractsAttempt = 1
        $contractsStarted = Get-Date
        $contractsJob = Invoke-Reviewer -PromptFile $contractsPrompt -Kind 'contracts' -ResponseFile $contractsResponse
        Write-Host ("[{0:HH:mm:ss}] start   contracts pass (alongside the file reviews)" -f (Get-Date))
    }

    # ------------------------------------------------------------ per-file reviews
    $pending = [System.Collections.Generic.Queue[object]]::new()
    foreach ($it in $items) { $pending.Enqueue($it) }
    $running = [System.Collections.Generic.List[object]]::new()
    $failedItems = 0
    $failedPaths = New-Object System.Collections.Generic.List[string]

    function Save-UnitResult {
        # Splits one unit's answer into one per-file line of file-results.jsonl. Accepts a bare
        # per-file object (one file) or { results: [...] } (a batch), in either case keyed by path.
        param($Parsed, $Item)
        $objects = @()
        $results = Get-Prop $Parsed 'results' $null
        if ($null -ne $results) { $objects = @($results) }
        elseif ($null -ne $Parsed.PSObject.Properties['findings']) { $objects = @($Parsed) }
        if ($objects.Count -eq 0) { return $null }

        $byPath = @{}
        foreach ($o in $objects) {
            if ([object]::ReferenceEquals($o, $null)) { continue }
            $p = ([string](Get-Prop $o 'file' '')).Replace('\', '/')
            if ($p -and ($Item.Paths -contains $p)) { $byPath[$p] = $o }
        }
        # A reviewer that answered in order but mislabelled the paths is still usable.
        if ($byPath.Count -eq 0 -and $objects.Count -eq $Item.Paths.Count) {
            for ($k = 0; $k -lt $objects.Count; $k++) { $byPath[$Item.Paths[$k]] = $objects[$k] }
        }
        if ($byPath.Count -eq 0) { return $null }

        $total = 0
        $missing = @()
        foreach ($p in $Item.Paths) {
            if (-not $byPath.ContainsKey($p)) { $missing += $p; continue }
            $o = $byPath[$p]
            $o | Add-Member -Force -NotePropertyName 'file' -NotePropertyValue $p
            $total += @(Get-Prop $o 'findings' @()).Count
            [System.IO.File]::AppendAllText($resultsPath, (($o | ConvertTo-Json -Depth 30 -Compress) + "`n"), $utf8NoBom)
        }
        $outcome = @{}
        $outcome.Findings = $total
        $outcome.Missing = $missing
        return $outcome
    }

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        $slots = $MaxParallel
        if ($null -ne $contractsJob -and $contractsJob.State -eq 'Running') { $slots = $MaxParallel - 1 }
        while ($pending.Count -gt 0 -and $running.Count -lt $slots) {
            $it = $pending.Dequeue()
            $it.Attempt++
            $it.Started = Get-Date
            $label = if ($it.Paths.Count -eq 1) { $it.Paths[0] } else { "$($it.Paths.Count) small files" }
            if ($it.Attempt -eq 1) {
                $cached = Read-CachedResponse -PromptFile $it.PromptFile -Kind 'file' -ResponseFile $it.ResponseFile
                if ($null -ne $cached) {
                    $parsed = Get-JsonBlock -Text $cached
                    $saved = if ($null -ne $parsed) { Save-UnitResult -Parsed $parsed -Item $it } else { $null }
                    if ($null -ne $saved -and @($saved.Missing).Count -eq 0) {
                        $it.Done = $true; $it.Cached = $true; $it.Findings = $saved.Findings; $it.Seconds = 0.0
                        $cacheHits++
                        Write-Host ("[{0:HH:mm:ss}] cached  {1}: {2} finding(s)" -f (Get-Date), $label, $saved.Findings)
                        continue
                    }
                }
            }
            $it.Job = Invoke-Reviewer -PromptFile $it.PromptFile -Kind 'file' -ResponseFile $it.ResponseFile
            $running.Add($it)
            Write-Host ("[{0:HH:mm:ss}] start   {1} (attempt {2})" -f (Get-Date), $label, $it.Attempt)
        }
        if ($pending.Count -eq 0 -and $running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 400
        foreach ($it in @($running)) {
            $state = [string]$it.Job.State
            $elapsed = ((Get-Date) - $it.Started).TotalMinutes
            $timedOut = ($elapsed -gt $TimeoutMinutes) -and ($state -eq 'Running')
            if ($state -notin @('Completed', 'Failed', 'Stopped') -and -not $timedOut) { continue }
            $running.Remove($it) | Out-Null
            $r = Complete-Job -Job $it.Job -TimedOut $timedOut
            $it.Seconds = [math]::Round(((Get-Date) - $it.Started).TotalSeconds, 1)
            $label = if ($it.Paths.Count -eq 1) { $it.Paths[0] } else { "$($it.Paths.Count) small files" }
            $parsed = if ($r.TimedOut) { $null } else { Get-JsonBlock -Text $r.Output }
            $saved = if ($null -ne $parsed) { Save-UnitResult -Parsed $parsed -Item $it } else { $null }
            if ($null -ne $saved -and @($saved.Missing).Count -eq 0) {
                $it.Done = $true; $it.Findings = $saved.Findings
                Write-CachedResponse -PromptFile $it.PromptFile -Kind 'file' -Text $r.Output
                Write-Host ("[{0:HH:mm:ss}] done    {1}: {2} finding(s) in {3}s" -f (Get-Date), $label, $saved.Findings, $it.Seconds)
            }
            else {
                $why = if ($r.TimedOut) { "timed out after $TimeoutMinutes min" }
                elseif ($r.ExitCode -ne 0) { "exit code $($r.ExitCode)" }
                elseif ($null -ne $saved) { "no result for $(@($saved.Missing) -join ', ')" }
                else { 'no valid JSON result in the response' }
                if ($it.Attempt -le $MaxRetries) {
                    Write-Warning "${label}: $why; retrying."
                    $pending.Enqueue($it)
                }
                else {
                    foreach ($p in $it.Paths) {
                        $failedItems++
                        $failedPaths.Add($p)
                        $errLine = [ordered]@{ file = $p; error = "$why after $($it.Attempt) attempt(s); see $($it.ResponseFile)" }
                        [System.IO.File]::AppendAllText($resultsPath, (($errLine | ConvertTo-Json -Compress) + "`n"), $utf8NoBom)
                    }
                    Write-Warning "${label}: giving up ($why)."
                }
            }
        }
    }

    # ------------------------------------------------------------ finish the contracts pass
    if ($runContracts) {
        while ($null -eq $contractsResult -and $contractsAttempt -le $MaxRetries) {
            if ($null -eq $contractsJob) {
                $contractsAttempt++
                $contractsStarted = Get-Date
                $contractsResponse = Join-Path $respDir "contracts-$contractsAttempt.txt"
                $contractsJob = Invoke-Reviewer -PromptFile $contractsPrompt -Kind 'contracts' -ResponseFile $contractsResponse
                Write-Host ("[{0:HH:mm:ss}] start   contracts pass (attempt {1})" -f (Get-Date), $contractsAttempt)
            }
            $limit = $TimeoutMinutes * 2
            while ($contractsJob.State -eq 'Running' -and ((Get-Date) - $contractsStarted).TotalMinutes -lt $limit) { Start-Sleep -Milliseconds 400 }
            $r = Complete-Job -Job $contractsJob -TimedOut ($contractsJob.State -eq 'Running')
            $contractsJob = $null
            $contractsSeconds = [math]::Round(((Get-Date) - $contractsStarted).TotalSeconds, 1)
            $parsed = if ($r.TimedOut) { $null } else { Get-JsonBlock -Text $r.Output }
            if ($null -ne $parsed -and (($null -ne $parsed.PSObject.Properties['findings']) -or ($null -ne $parsed.PSObject.Properties['assessment']))) {
                $contractsResult = $parsed
                Write-CachedResponse -PromptFile $contractsPrompt -Kind 'contracts' -Text $r.Output
                Write-Host ("[{0:HH:mm:ss}] done    contracts pass in {1}s" -f (Get-Date), $contractsSeconds)
            }
            else {
                $why = if ($r.TimedOut) { "timed out after $($TimeoutMinutes * 2) min" } elseif ($r.ExitCode -ne 0) { "exit code $($r.ExitCode)" } else { 'no valid JSON result in the response' }
                Write-Warning "contracts pass: $why (see $contractsResponse)."
            }
        }
        if ($null -eq $contractsResult) { Write-Warning 'The contracts pass did not complete; cross-file problems were not checked.' }
    }
    elseif ($SkipIntegration) { Write-Host 'Contracts and verification passes skipped (-SkipIntegration).' }
    elseif ($items.Count -eq 0) { Write-Host 'No reviewable files; contracts and verification passes skipped.' }

    # ------------------------------------------------------------ verification pass
    $verifications = @()
    $verifyRan = $false
    $verifySeconds = 0.0
    if ($runContracts) {
        # Same id rule as Merge-ReviewResults.ps1: manifest file order, then finding order, with the
        # contracts findings continuing the sequence. Computing the ids here lets the verification
        # pass point duplicateOf at a contracts finding and have the merge agree.
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
                            if ([object]::ReferenceEquals($raw, $null)) { continue }
                            $n++
                            $sev = ([string](Get-Prop $raw 'severity' '')).ToLowerInvariant()
                            if ($sev -in @('blocking', 'should-fix')) {
                                $toVerify += [ordered]@{ id = "F$n"; file = $path; line = (Get-Prop $raw 'line' $null); severity = $sev; category = [string](Get-Prop $raw 'category' ''); title = [string](Get-Prop $raw 'title' ''); detail = [string](Get-Prop $raw 'detail' ''); source = 'file-review' }
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
        foreach ($raw in @(Get-Prop $contractsResult 'findings' @())) {
            if ([object]::ReferenceEquals($raw, $null)) { continue }
            $n++
            $sev = ([string](Get-Prop $raw 'severity' '')).ToLowerInvariant()
            if ($sev -in @('blocking', 'should-fix')) {
                $toVerify += [ordered]@{ id = "F$n"; file = [string](Get-Prop $raw 'file' ''); line = (Get-Prop $raw 'line' $null); severity = $sev; category = [string](Get-Prop $raw 'category' ''); title = [string](Get-Prop $raw 'title' ''); detail = [string](Get-Prop $raw 'detail' ''); source = 'contracts' }
            }
        }

        if ($toVerify.Count -eq 0) {
            Write-Host 'Nothing to verify: no blocking or should-fix findings.'
            $verifyRan = $true
        }
        else {
            $vv = $common.Clone()
            $vv.fileList = ($fileList -join "`n")
            $vv.summaries = if ($summaries.Count) { $summaries -join "`n" } else { '(none)' }
            $vv.notes = if ($notes.Count) { $notes -join "`n" } else { '(none)' }
            $vv.assessment = [string](Get-Prop $contractsResult 'assessment' '(the contracts pass did not report an assessment)')
            $vv.findingsToVerify = ($toVerify | ConvertTo-Json -Depth 5 -AsArray)
            $vv.instructions = $verifyInstructions
            $verifyPrompt = Join-Path $promptDir 'verify.md'
            Write-Utf8File -Path $verifyPrompt -Content (Expand-Template -Template $verifyTemplate -Values $vv)

            $attempt = 0
            while (-not $verifyRan -and $attempt -le $MaxRetries) {
                $attempt++
                $respFile = Join-Path $respDir "verify-$attempt.txt"
                $started = Get-Date
                $text = $null
                if ($attempt -eq 1) {
                    $text = Read-CachedResponse -PromptFile $verifyPrompt -Kind 'verify' -ResponseFile $respFile
                    if ($null -ne $text) { $cacheHits++; Write-Host ("[{0:HH:mm:ss}] cached  verification pass" -f (Get-Date)) }
                }
                if ($null -eq $text) {
                    Write-Host ("[{0:HH:mm:ss}] start   verification pass (attempt {1}, {2} finding(s))" -f (Get-Date), $attempt, $toVerify.Count)
                    $job = Invoke-Reviewer -PromptFile $verifyPrompt -Kind 'verify' -ResponseFile $respFile
                    $limit = $TimeoutMinutes * 2
                    while ($job.State -eq 'Running' -and ((Get-Date) - $started).TotalMinutes -lt $limit) { Start-Sleep -Milliseconds 400 }
                    $r = Complete-Job -Job $job -TimedOut ($job.State -eq 'Running')
                    $text = if ($r.TimedOut) { $null } else { $r.Output }
                    $failure = if ($r.TimedOut) { "timed out after $($TimeoutMinutes * 2) min" } elseif ($r.ExitCode -ne 0) { "exit code $($r.ExitCode)" } else { 'no valid JSON result in the response' }
                }
                else { $failure = 'the cached response could not be parsed' }
                $verifySeconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
                $parsed = if ($null -ne $text) { Get-JsonBlock -Text $text } else { $null }
                if ($null -ne $parsed -and $null -ne $parsed.PSObject.Properties['verifications']) {
                    $verifications = @(Get-Prop $parsed 'verifications' @())
                    $verifyRan = $true
                    Write-CachedResponse -PromptFile $verifyPrompt -Kind 'verify' -Text $text
                    Write-Host ("[{0:HH:mm:ss}] done    verification pass in {1}s" -f (Get-Date), $verifySeconds)
                }
                else { Write-Warning "verification pass: $failure (see $respFile)." }
            }
            if (-not $verifyRan) { Write-Warning 'The verification pass did not complete; findings will be reported as unverified.' }
        }
    }

    # ------------------------------------------------------------ one integration result for the merge
    if ($null -ne $contractsResult -or $verifications.Count -gt 0) {
        $combined = [ordered]@{}
        $combined.verifications = @($verifications)
        $combined.findings = @(Get-Prop $contractsResult 'findings' @())
        $combined.assessment = [string](Get-Prop $contractsResult 'assessment' '')
        $combined.verifyCommands = @(Get-Prop $contractsResult 'verifyCommands' @())
        Write-Utf8File -Path $integrationPath -Content ($combined | ConvertTo-Json -Depth 30)
    }
}
finally {
    foreach ($k in $envBackup.Keys) { [Environment]::SetEnvironmentVariable($k, $envBackup[$k]) }
    Get-Job | Where-Object { $_.State -eq 'Running' } | Stop-Job -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------ merge
$unitLog = New-Object System.Collections.Generic.List[object]
foreach ($it in $items) {
    $entry = [ordered]@{}
    $entry.files = $it.Paths
    $entry.attempts = $it.Attempt
    $entry.ok = $it.Done
    $entry.cached = $it.Cached
    $entry.findings = $it.Findings
    $entry.seconds = $it.Seconds
    $unitLog.Add($entry)
}
$runLog = [ordered]@{
    harness = $Harness; command = $command
    model = $Model; fileReviewModel = $FileReviewModel; integrationModel = $IntegrationModel
    ci = $isCI
    startedAt = $startedAt.ToUniversalTime().ToString('o'); durationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
    parallel = $MaxParallel
    calls = $items.Count; filesReviewed = $reviewFiles.Count; batchedCalls = $batched.Count
    inlinedFileContents = $inlinedContentFiles; cacheHits = $cacheHits
    units = $unitLog
    contractsPassRan = ($null -ne $contractsResult); contractsSeconds = $contractsSeconds; contractsCached = $contractsCached
    verificationPassRan = $verifyRan; verificationSeconds = $verifySeconds
}
Write-Utf8File -Path (Join-Path $out 'driver-run.json') -Content ($runLog | ConvertTo-Json -Depth 6)

$allFailed = ($reviewFiles.Count -gt 0 -and $failedItems -ge $reviewFiles.Count)
if ($allFailed) { Write-Warning 'Every per-file review failed; check the responses folder and the harness authentication.' }
& (Join-Path $scriptDir 'Merge-ReviewResults.ps1') -OutputDir $out -ConfigPath $ConfigPath -PrintReport:(-not $isCI)
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { exit 2 }
if ($allFailed) { exit 3 }
exit 0
