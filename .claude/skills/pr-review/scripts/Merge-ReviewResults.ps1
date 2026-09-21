#Requires -Version 5.1
<#
.SYNOPSIS
    Merges the per-file results and the integration result of a review into findings.json and report.md.

.DESCRIPTION
    Reads manifest.json, file-results.jsonl and (optionally) integration-result.json from the review
    output directory, applies the merge rules documented in references/report-format.md (confidence
    threshold, verifications, de-duplication, verdict, coverage) and writes findings.json and report.md.
    Deterministic: no model involved. Used by both the interactive skill and Invoke-PrReview.ps1.

    The source is deliberately ASCII-only (typography comes from [char] codes) so that Windows
    PowerShell 5.1, which reads BOM-less scripts as ANSI, parses it identically to PowerShell 7.

.PARAMETER OutputDir
    Review output directory. Default: $env:PR_REVIEW_OUTPUT_DIR, then $env:BUILD_ARTIFACTSTAGINGDIRECTORY/pr-review, then ./.pr-review.
.PARAMETER ManifestPath
    Default: <OutputDir>/manifest.json.
.PARAMETER ResultsPath
    Default: <OutputDir>/file-results.jsonl.
.PARAMETER IntegrationPath
    Default: <OutputDir>/integration-result.json (optional input).
.PARAMETER ConfigPath
    Default: ../config.json relative to this script.
.PARAMETER PrintReport
    Also write the rendered report to the console.
.EXAMPLE
    pwsh -NoProfile -File Merge-ReviewResults.ps1 -OutputDir .pr-review -PrintReport
#>
[CmdletBinding()]
param(
    [string]$OutputDir,
    [string]$ManifestPath,
    [string]$ResultsPath,
    [string]$IntegrationPath,
    [string]$ConfigPath,
    [switch]$PrintReport
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$dot = [string][char]0x00B7      # middle dot separator
$dash = [string][char]0x2014     # em dash
$larr = [string][char]0x2190     # left arrow

function Get-Prop {
    # Safe property/key lookup with a default. Null checks use ReferenceEquals instead of -eq/-ne so they
    # never go through PowerShell's polymorphic comparison binder.
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

function Get-Text {
    # String property with a default, trimmed.
    param($Object, [string]$Name, [string]$Default = '')
    $v = Get-Prop -Object $Object -Name $Name -Default $null
    if ([object]::ReferenceEquals($v, $null)) { return $Default }
    return ([string]$v).Trim()
}

function Write-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ---------------------------------------------------------------- inputs

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $skillRoot 'config.json' }
$config = $null
if (Test-Path -LiteralPath $ConfigPath) { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }

if (-not $OutputDir) {
    if ($env:PR_REVIEW_OUTPUT_DIR) { $OutputDir = $env:PR_REVIEW_OUTPUT_DIR }
    elseif ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $OutputDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'pr-review' }
    else { $OutputDir = Join-Path (Get-Location).Path (Get-Text $config 'reportDirName' '.pr-review') }
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not $ManifestPath) { $ManifestPath = Join-Path $OutputDir 'manifest.json' }
if (-not $ResultsPath) { $ResultsPath = Join-Path $OutputDir 'file-results.jsonl' }
if (-not $IntegrationPath) { $IntegrationPath = Join-Path $OutputDir 'integration-result.json' }
if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Manifest not found at $ManifestPath. Run Get-PrDiff.ps1 first." }

$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$manifestConfig = Get-Prop $manifest 'config' $null
$minConfidenceRaw = Get-Prop $manifestConfig 'minConfidence' $null
if ([object]::ReferenceEquals($minConfidenceRaw, $null)) { $minConfidenceRaw = Get-Prop $config 'minConfidence' 0.6 }
$minConfidence = [double]$minConfidenceRaw

# per-file results: last line per file wins
$resultsByFile = @{}
$malformedLines = 0
if (Test-Path -LiteralPath $ResultsPath) {
    $lineNo = 0
    foreach ($line in [System.IO.File]::ReadAllLines($ResultsPath)) {
        $lineNo++
        if (-not $line.Trim()) { continue }
        $obj = $null
        try { $obj = $line | ConvertFrom-Json } catch { $malformedLines++; Write-Warning "file-results.jsonl line $lineNo is not valid JSON and was skipped."; continue }
        $f = Get-Text $obj 'file' ''
        if (-not $f) { $malformedLines++; Write-Warning "file-results.jsonl line $lineNo has no 'file' and was skipped."; continue }
        $resultsByFile[$f.Replace('\', '/')] = $obj
    }
}
else {
    Write-Warning "No per-file results at $ResultsPath; every reviewable file will be reported as failed."
}

$integration = $null
$integrationRan = $false
if (Test-Path -LiteralPath $IntegrationPath) {
    try { $integration = Get-Content -LiteralPath $IntegrationPath -Raw | ConvertFrom-Json; $integrationRan = $true }
    catch { Write-Warning "integration-result.json is not valid JSON; treating the integration pass as not run." }
}

# ---------------------------------------------------------------- normalise findings

function ConvertTo-Finding {
    param($Raw, [string]$File, [string]$Source)
    $sev = (Get-Text $Raw 'severity' 'question').ToLowerInvariant()
    if ($sev -notin @('blocking', 'should-fix', 'nit', 'question')) { $sev = 'question' }
    $cat = (Get-Text $Raw 'category' 'maintainability').ToLowerInvariant()
    if (-not $cat) { $cat = 'maintainability' }
    $lineInt = $null
    $rawLine = Get-Prop $Raw 'line' $null
    if (-not [object]::ReferenceEquals($rawLine, $null)) { try { $lineInt = [int]$rawLine } catch { $lineInt = $null } }
    $endInt = $lineInt
    $rawEnd = Get-Prop $Raw 'endLine' $null
    if (-not [object]::ReferenceEquals($rawEnd, $null)) { try { $endInt = [int]$rawEnd } catch { $endInt = $lineInt } }
    if (-not [object]::ReferenceEquals($lineInt, $null) -and -not [object]::ReferenceEquals($endInt, $null) -and $endInt -lt $lineInt) { $endInt = $lineInt }
    $conf = 0.5
    $rawConf = Get-Prop $Raw 'confidence' $null
    if (-not [object]::ReferenceEquals($rawConf, $null)) { try { $conf = [double]$rawConf } catch { $conf = 0.5 } }
    if ($conf -gt 1) { $conf = 1 }
    if ($conf -lt 0) { $conf = 0 }
    $detail = Get-Text $Raw 'detail' ''
    $title = Get-Text $Raw 'title' ''
    if (-not $title) { $title = if ($detail.Length -gt 80) { $detail.Substring(0, 77) + '...' } else { $detail } }
    if (-not $title) { $title = '(untitled finding)' }
    $file = (Get-Text $Raw 'file' $File).Replace('\', '/')
    if (-not $file) { $file = if ($File) { $File } else { '(unknown file)' } }
    $suggestion = Get-Text $Raw 'suggestion' ''
    $fnd = [ordered]@{}
    $fnd.id = $null
    $fnd.file = $file
    $fnd.line = $lineInt
    $fnd.endLine = $endInt
    $fnd.severity = $sev
    $fnd.category = $cat
    $fnd.title = $title
    $fnd.detail = $detail
    $fnd.suggestion = $suggestion
    $fnd.confidence = [math]::Round($conf, 2)
    $fnd.source = $Source
    $fnd.verification = 'not-checked'
    $fnd.verificationReason = ''
    $fnd.duplicates = New-Object System.Collections.Generic.List[object]
    return $fnd
}

$all = New-Object System.Collections.Generic.List[object]
$reviewed = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
$deleted = New-Object System.Collections.Generic.List[string]
$notes = New-Object System.Collections.Generic.List[object]
$summaries = New-Object System.Collections.Generic.List[object]
$manifestFiles = @(Get-Prop $manifest 'files' @())
$manifestPaths = @{}
$n = 0
foreach ($mf in $manifestFiles) {
    $path = (Get-Text $mf 'path' '').Replace('\', '/')
    $manifestPaths[$path] = $true
    $mode = Get-Text $mf 'reviewMode' 'review'
    if ($mode -eq 'skip') {
        $entry = [ordered]@{}; $entry.file = $path; $entry.reason = Get-Text $mf 'skipReason' ''
        $skipped.Add($entry); continue
    }
    if ($mode -eq 'deleted') { $deleted.Add($path); continue }
    if (-not $resultsByFile.ContainsKey($path)) {
        $entry = [ordered]@{}; $entry.file = $path; $entry.error = 'no result was returned for this file'
        $failed.Add($entry); continue
    }
    $r = $resultsByFile[$path]
    $err = Get-Text $r 'error' ''
    if ($err) {
        $entry = [ordered]@{}; $entry.file = $path; $entry.error = $err
        $failed.Add($entry); continue
    }
    $reviewed.Add($path)
    $s = Get-Text $r 'summary' ''
    if ($s) { $entry = [ordered]@{}; $entry.file = $path; $entry.summary = $s; $summaries.Add($entry) }
    $nt = Get-Text $r 'notes' ''
    if ($nt) { $entry = [ordered]@{}; $entry.file = $path; $entry.note = $nt; $notes.Add($entry) }
    foreach ($raw in @(Get-Prop $r 'findings' @())) {
        if ([object]::ReferenceEquals($raw, $null)) { continue }
        $n++
        $fnd = ConvertTo-Finding -Raw $raw -File $path -Source 'file-review'
        $fnd.id = "F$n"
        $all.Add($fnd)
    }
}
foreach ($extra in $resultsByFile.Keys) {
    if (-not $manifestPaths.ContainsKey($extra)) { Write-Warning "file-results.jsonl contains a result for '$extra', which is not in the manifest; ignored." }
}

# verifications, including duplicates the integration pass declared with duplicateOf
$verdicts = @{}
$duplicateOf = @{}
if ($integrationRan) {
    foreach ($v in @(Get-Prop $integration 'verifications' @())) {
        $id = Get-Text $v 'id' ''
        if ($id) { $verdicts[$id] = $v }
    }
}
foreach ($fnd in $all) {
    if ($fnd.severity -in @('blocking', 'should-fix')) {
        if ($verdicts.ContainsKey($fnd.id)) {
            $vd = (Get-Text $verdicts[$fnd.id] 'verdict' 'unverified').ToLowerInvariant()
            if ($vd -notin @('confirmed', 'refuted', 'unverified')) { $vd = 'unverified' }
            $fnd.verification = $vd
            $fnd.verificationReason = Get-Text $verdicts[$fnd.id] 'reason' ''
            $target = Get-Text $verdicts[$fnd.id] 'duplicateOf' ''
            if ($target -and $target -ne $fnd.id) { $duplicateOf[$fnd.id] = $target }
        }
        else {
            $fnd.verification = 'unverified'
            $fnd.verificationReason = if ($integrationRan) { 'not addressed by the integration pass' } else { 'the integration pass did not run' }
        }
    }
}

# integration findings continue the id sequence
if ($integrationRan) {
    foreach ($raw in @(Get-Prop $integration 'findings' @())) {
        if ([object]::ReferenceEquals($raw, $null)) { continue }
        $n++
        $fnd = ConvertTo-Finding -Raw $raw -File '' -Source 'integration'
        $fnd.id = "F$n"
        $all.Add($fnd)
    }
}

# confidence threshold, refuted split, de-duplication
$droppedLowConfidence = 0
$refuted = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]
foreach ($fnd in $all) {
    if ($fnd.confidence -lt $minConfidence) { $droppedLowConfidence++; continue }
    if ($fnd.verification -eq 'refuted') { $refuted.Add($fnd); continue }
    $candidates.Add($fnd)
}
$severityRank = @{ 'blocking' = 0; 'should-fix' = 1; 'nit' = 2; 'question' = 3 }
$verificationRank = @{ 'confirmed' = 0; 'unverified' = 1; 'not-checked' = 2 }
$titleSimilarityThreshold = 0.5
$stopWords = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($w in @('the', 'and', 'for', 'are', 'its', 'this', 'that', 'with', 'without', 'not', 'can', 'may', 'from', 'into',
        'than', 'then', 'when', 'which', 'any', 'all', 'every', 'never', 'only', 'also', 'does', 'has', 'have', 'was',
        'were', 'will', 'would', 'could', 'should', 'but', 'via', 'per', 'out', 'one', 'two', 'new')) { [void]$stopWords.Add($w) }

function Get-TitleTokens {
    # Lower-cased words of 3+ letters, stop words removed, common suffixes stripped.
    param([string]$Text)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($raw in ($Text.ToLowerInvariant() -split '[^a-z0-9]+')) {
        if ($raw.Length -lt 3 -or $stopWords.Contains($raw)) { continue }
        $word = $raw
        foreach ($suffix in @('ations', 'ation', 'ings', 'ing', 'ions', 'ion', 'ed', 'es', 's')) {
            if ($word.EndsWith($suffix) -and ($word.Length - $suffix.Length) -ge 4) { $word = $word.Substring(0, $word.Length - $suffix.Length); break }
        }
        [void]$set.Add($word)
    }
    return , $set
}

function Get-TitleSimilarity {
    # Jaccard similarity of the two titles' token sets, 0 to 1.
    param([string]$A, [string]$B)
    $ta = Get-TitleTokens -Text $A
    $tb = Get-TitleTokens -Text $B
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
    $inter = 0
    foreach ($t in $ta) { if ($tb.Contains($t)) { $inter++ } }
    return ([double]$inter / [double]($ta.Count + $tb.Count - $inter))
}

function Resolve-DuplicateRoot {
    # Follows duplicateOf links to the finding that should absorb $Id. $null when $Id stands alone.
    param([string]$Id)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $current = $Id
    while ($duplicateOf.ContainsKey($current) -and $byId.ContainsKey($duplicateOf[$current])) {
        if (-not $seen.Add($current)) { return $null }
        $current = $duplicateOf[$current]
    }
    if ($current -eq $Id) { return $null }
    return $current
}

function Add-Duplicate {
    # Folds $Dup into $Root, keeping a reference to it and the stronger severity, confidence and verification.
    param($Root, $Dup)
    $entry = [ordered]@{}
    $entry.id = $Dup.id
    $entry.file = $Dup.file
    $entry.line = $Dup.line
    $entry.endLine = $Dup.endLine
    $entry.severity = $Dup.severity
    $entry.title = $Dup.title
    $entry.source = $Dup.source
    $Root.duplicates.Add($entry)
    foreach ($inner in $Dup.duplicates) { $Root.duplicates.Add($inner) }
    if ($severityRank[$Dup.severity] -lt $severityRank[$Root.severity]) { $Root.severity = $Dup.severity }
    if ($Dup.confidence -gt $Root.confidence) { $Root.confidence = $Dup.confidence }
    if ($verificationRank.ContainsKey($Dup.verification) -and $verificationRank.ContainsKey($Root.verification)) {
        if ($verificationRank[$Dup.verification] -lt $verificationRank[$Root.verification]) {
            $Root.verification = $Dup.verification
            $Root.verificationReason = $Dup.verificationReason
        }
    }
}

$mergedDuplicates = 0
$byId = @{}
foreach ($fnd in $candidates) { $byId[$fnd.id] = $fnd }

# Pass 1: duplicates the integration pass declared. This is the only way findings from
# different files are merged, because only a whole-PR view can tell they are one defect.
$foldedIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($fnd in $candidates) {
    if (-not $duplicateOf.ContainsKey($fnd.id)) { continue }
    $rootId = Resolve-DuplicateRoot -Id $fnd.id
    if (-not $rootId) { continue }
    Add-Duplicate -Root $byId[$rootId] -Dup $fnd
    [void]$foldedIds.Add($fnd.id)
    $mergedDuplicates++
}

# Pass 2: a conservative safety net for undeclared duplicates. Same file, same category,
# overlapping lines AND similar titles. Two different defects on one line stay separate;
# a missed merge only shows a duplicate, an over-merge would hide a defect.
$kept = New-Object System.Collections.Generic.List[object]
$remaining = @($candidates | Where-Object { -not $foldedIds.Contains($_.id) })
foreach ($fnd in @($remaining | Sort-Object -Property @{ Expression = { $severityRank[$_.severity] } }, @{ Expression = { $_.confidence }; Descending = $true })) {
    $dup = $null
    foreach ($k in $kept) {
        if ($k.file -ne $fnd.file -or $k.category -ne $fnd.category) { continue }
        if ([object]::ReferenceEquals($k.line, $null) -or [object]::ReferenceEquals($fnd.line, $null)) { continue }
        $startMax = [Math]::Max([int]$k.line, [int]$fnd.line)
        $endMin = [Math]::Min([int]$k.endLine, [int]$fnd.endLine)
        if ($startMax -gt $endMin) { continue }
        if ((Get-TitleSimilarity -A $k.title -B $fnd.title) -lt $titleSimilarityThreshold) { continue }
        $dup = $k
        break
    }
    if (-not [object]::ReferenceEquals($dup, $null)) {
        Add-Duplicate -Root $dup -Dup $fnd
        $mergedDuplicates++
        continue
    }
    $kept.Add($fnd)
}
$final = @($kept | Sort-Object -Property @{ Expression = { $severityRank[$_.severity] } }, @{ Expression = { $_.confidence }; Descending = $true }, @{ Expression = { [int]($_.id -replace '^F', '') } })

# verdict, counts
$counts = [ordered]@{}
$counts.blocking = 0
$counts['should-fix'] = 0
$counts.nit = 0
$counts.question = 0
$counts.refuted = $refuted.Count
foreach ($fnd in $final) { $counts[$fnd.severity] = [int]$counts[$fnd.severity] + 1 }
$verdict = 'approve'
if ($counts.blocking -gt 0) { $verdict = 'request-changes' } elseif ($counts['should-fix'] -gt 0) { $verdict = 'approve-with-comments' }
# A review in which nothing could be reviewed must never look like an approval.
$incomplete = ($failed.Count -gt 0)
if ($reviewed.Count -eq 0 -and $failed.Count -gt 0) { $verdict = 'incomplete' }

$summaryParts = @()
foreach ($sev in @('blocking', 'should-fix', 'nit', 'question')) {
    if ($counts[$sev] -gt 0) { $summaryParts += "$($counts[$sev]) $sev" }
}
$summaryText = if ($summaryParts.Count -gt 0) { "$($summaryParts -join ', ') across $($reviewed.Count) reviewed file(s)." } else { "No findings across $($reviewed.Count) reviewed file(s)." }
if ($failed.Count -gt 0) { $summaryText += " $($failed.Count) file(s) could not be reviewed." }

$assessment = ''
if ($integrationRan) { $assessment = Get-Text $integration 'assessment' '' }
if (-not $assessment -and -not $integrationRan) { $assessment = 'The integration pass did not run, so cross-file effects were not checked and high-severity findings are unverified.' }

$pr = Get-Prop $manifest 'pr' $null
$base = Get-Prop $manifest 'base' $null
$head = Get-Prop $manifest 'head' $null
$verifyCommands = @()
if ($integrationRan) { $verifyCommands = @(Get-Prop $integration 'verifyCommands' @()) }

$prId = Get-Prop $pr 'id' $null
$prTitle = Get-Text $pr 'title' ''
$prUrl = Get-Text $pr 'url' ''
$prRepository = Get-Text $pr 'repository' ''
$baseName = Get-Text $base 'name' ''
$baseSha = Get-Text $base 'sha' ''
$headName = Get-Text $head 'name' ''
$headSha = Get-Text $head 'sha' ''

$target = [ordered]@{}
$target.pullRequestId = $prId
$target.title = $prTitle
$target.url = $(if ($prUrl) { $prUrl } else { $null })
$target.repository = $prRepository
$target.base = $baseName
$target.baseSha = $baseSha
$target.head = $headName
$target.headSha = $headSha

$coverage = [ordered]@{}
$coverage.reviewed = @($reviewed.ToArray())
$coverage.skipped = @($skipped.ToArray())
$coverage.deleted = @($deleted.ToArray())
$coverage.failed = @($failed.ToArray())

$findingsDoc = [ordered]@{}
$findingsDoc.schemaVersion = 1
$findingsDoc.generatedAt = (Get-Date).ToUniversalTime().ToString('o')
$findingsDoc.target = $target
$findingsDoc.verdict = $verdict
$findingsDoc.incomplete = $incomplete
$findingsDoc.summary = $summaryText
$findingsDoc.assessment = $assessment
$findingsDoc.counts = $counts
$findingsDoc.findings = @($final)
$findingsDoc.refuted = @($refuted.ToArray())
$findingsDoc.coverage = $coverage
$findingsDoc.notes = @($notes.ToArray())
$findingsDoc.verifyCommands = @($verifyCommands)
$findingsDoc.integrationPassRan = $integrationRan
$findingsDoc.droppedLowConfidence = $droppedLowConfidence
$findingsDoc.mergedDuplicates = $mergedDuplicates
$findingsDoc.malformedResultLines = $malformedLines

$findingsPath = Join-Path $OutputDir 'findings.json'
Write-Utf8File -Path $findingsPath -Content ($findingsDoc | ConvertTo-Json -Depth 12)

# ---------------------------------------------------------------- report

function Format-Location {
    param($Finding)
    if ([object]::ReferenceEquals($Finding.line, $null)) { return ('`' + $Finding.file + '`') }
    if (-not [object]::ReferenceEquals($Finding.endLine, $null) -and $Finding.endLine -ne $Finding.line) { return ('`' + $Finding.file + ':' + $Finding.line + '-' + $Finding.endLine + '`') }
    return ('`' + $Finding.file + ':' + $Finding.line + '`')
}
function Format-Verification {
    param($Finding)
    if ($Finding.source -eq 'integration') { return 'integration pass' }
    return $Finding.verification
}
function Format-OneLine {
    param([string]$Text)
    return (($Text -replace '\s+', ' ')).Trim()
}
function Format-Code {
    param([string]$Text)
    return ('`' + $Text + '`')
}

$verdictText = 'Approve'
if ($verdict -eq 'request-changes') { $verdictText = 'Request changes' }
elseif ($verdict -eq 'approve-with-comments') { $verdictText = 'Approve with comments' }
elseif ($verdict -eq 'incomplete') { $verdictText = 'Incomplete (the review could not run)' }
elseif ($incomplete) { $verdictText += ' (partial: some files could not be reviewed)' }
$sb = New-Object System.Text.StringBuilder
$title = $prTitle
if (-not $title) { $title = "$headName vs $baseName" }
[void]$sb.AppendLine("# PR review: $title")
[void]$sb.AppendLine()
$filesLine = "$($reviewed.Count) files reviewed, $($skipped.Count) skipped, $($deleted.Count) deleted"
if ($failed.Count -gt 0) { $filesLine += ", $($failed.Count) failed" }
[void]$sb.AppendLine("**Verdict:** $verdictText $dot **Base:** $(Format-Code $baseName) $larr **Head:** $(Format-Code $headName) $dot $filesLine")
if ($prUrl) { [void]$sb.AppendLine(); [void]$sb.AppendLine("PR ${prId}: $prUrl") }
if ($assessment) { [void]$sb.AppendLine(); [void]$sb.AppendLine($assessment) }

function Add-Section {
    param([string]$Heading, [string]$Severity, [bool]$Always, [bool]$AsBullets)
    $items = @($final | Where-Object { $_.severity -eq $Severity })
    if ($items.Count -eq 0 -and -not $Always) { return }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("## $Heading ($($items.Count))")
    if ($items.Count -eq 0) { [void]$sb.AppendLine(); [void]$sb.AppendLine('None.'); return }
    foreach ($f in $items) {
        $alsoReported = ''
        if ($f.duplicates.Count -gt 0) {
            $refs = @($f.duplicates | ForEach-Object { "$($_.id) at $(Format-Location $_)" })
            $alsoReported = "Also reported as $($refs -join ', ')."
        }
        if ($AsBullets) {
            $line = "- $(Format-Location $f) $dot $($f.title)."
            if ($f.detail -and $f.detail -ne $f.title) { $line += " $(Format-OneLine $f.detail)" }
            if ($alsoReported) { $line += " $alsoReported" }
            [void]$sb.AppendLine($line)
        }
        else {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("### $($f.id) $dot $(Format-Location $f) $dot $($f.category) $dot confidence $($f.confidence) $dot $(Format-Verification $f)")
            [void]$sb.AppendLine("**$($f.title)**")
            if ($f.detail) { [void]$sb.AppendLine(); [void]$sb.AppendLine($f.detail) }
            if ($f.verificationReason -and $f.verification -ne 'not-checked') { [void]$sb.AppendLine(); [void]$sb.AppendLine("_Verification ($($f.verification)): $($f.verificationReason)_") }
            if ($f.suggestion) { [void]$sb.AppendLine(); [void]$sb.AppendLine("**Suggestion:** $($f.suggestion)") }
            if ($alsoReported) { [void]$sb.AppendLine(); [void]$sb.AppendLine("_$($alsoReported)_") }
        }
    }
}
Add-Section -Heading 'Blocking' -Severity 'blocking' -Always $true -AsBullets $false
Add-Section -Heading 'Should fix' -Severity 'should-fix' -Always $false -AsBullets $false
Add-Section -Heading 'Nits' -Severity 'nit' -Always $false -AsBullets $true
Add-Section -Heading 'Questions' -Severity 'question' -Always $false -AsBullets $true

$integrationLines = @()
foreach ($vc in $verifyCommands) {
    $integrationLines += "- Verify command $(Format-Code (Get-Text $vc 'command' '')) exited $(Get-Text $vc 'exitCode' '?'): $(Format-OneLine (Get-Text $vc 'summary' ''))"
}
foreach ($nt in $notes) { $integrationLines += "- $(Format-Code $nt.file): $(Format-OneLine $nt.note)" }
if (-not $integrationRan) { $integrationLines += '- The integration pass did not run; cross-file effects were not checked.' }
if ($integrationLines.Count -gt 0) {
    [void]$sb.AppendLine(); [void]$sb.AppendLine('## Integration notes')
    foreach ($l in $integrationLines) { [void]$sb.AppendLine($l) }
}

[void]$sb.AppendLine(); [void]$sb.AppendLine('## Coverage')
$covBits = @()
$covBits += '**Reviewed:** ' + $(if ($reviewed.Count) { (($reviewed | ForEach-Object { Format-Code $_ }) -join ', ') } else { 'none' })
if ($skipped.Count) { $covBits += '**Skipped:** ' + (($skipped | ForEach-Object { "$(Format-Code $_.file) ($($_.reason))" }) -join ', ') }
if ($deleted.Count) { $covBits += '**Deleted:** ' + (($deleted | ForEach-Object { Format-Code $_ }) -join ', ') }
$covBits += '**Failed:** ' + $(if ($failed.Count) { (($failed | ForEach-Object { "$(Format-Code $_.file) ($($_.error))" }) -join ', ') } else { 'none' })
[void]$sb.AppendLine(($covBits -join " $dot "))
if ($droppedLowConfidence -gt 0 -or $mergedDuplicates -gt 0) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("_$droppedLowConfidence finding(s) below confidence $minConfidence dropped; $mergedDuplicates duplicate(s) merged._")
}

if ($refuted.Count -gt 0) {
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("<details><summary>Refuted during verification ($($refuted.Count))</summary>")
    [void]$sb.AppendLine()
    foreach ($f in $refuted) { [void]$sb.AppendLine("- $(Format-Location $f) $dot $($f.title) $dash $(Format-OneLine $f.verificationReason)") }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('</details>')
}

[void]$sb.AppendLine()
[void]$sb.AppendLine('_Generated by the pr-review skill: one subagent per changed file plus an integration and verification pass. Findings marked "unverified" need a human look._')

$reportPath = Join-Path $OutputDir 'report.md'
$report = $sb.ToString().Replace("`r`n", "`n")
Write-Utf8File -Path $reportPath -Content $report

Write-Host "Merged $($reviewed.Count) reviewed file(s): $summaryText Verdict: $verdict"
Write-Host "  $findingsPath"
Write-Host "  $reportPath"
if ($PrintReport) { Write-Host ''; Write-Host $report }
