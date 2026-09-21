#Requires -Version 7.0
<#
.SYNOPSIS
    Scores a review's findings.json against an answer key and prints a scorecard.

.DESCRIPTION
    Matches every expected defect in the answer key to a finding in findings.json. A location
    in the key matches a finding when:

      - the file is the same,
      - the line ranges overlap, allowing lineTolerance lines either side,
      - the finding's title or detail contains one of the location's keywords (case-insensitive).

    A finding carries the duplicates the merge folded into it, and any of those locations can
    match too. Each finding can satisfy at most one defect, assigned most-constrained first, so
    two different defects merged into one finding score as one hit and one miss.

    The run passes when recall on the planted defects is at least -MinRecall, nothing on the
    must-not-report list was reported, and the expected files were reviewed and skipped.

    Works on any findings.json the review produced for the self-test fixture, whether from the
    recorded run, a live run of the driver, or a chat session.

.PARAMETER FindingsPath
    The findings.json to score.
.PARAMETER AnswerKeyPath
    Default: fixture/answer-key.json next to this script.
.PARAMETER MinRecall
    Minimum share of planted defects that must be found. Default 0.8.
.PARAMETER PassThru
    Return the result object instead of setting the exit code.
.EXAMPLE
    pwsh -File tests/Measure-Review.ps1 -FindingsPath .pr-review/findings.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FindingsPath,
    [string]$AnswerKeyPath = (Join-Path $PSScriptRoot 'fixture/answer-key.json'),
    [double]$MinRecall = 0.8,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$severityRank = @{ 'blocking' = 0; 'should-fix' = 1; 'nit' = 2; 'question' = 3 }

$doc = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json -Depth 30
$key = Get-Content -LiteralPath $AnswerKeyPath -Raw | ConvertFrom-Json -Depth 30
$tolerance = [int]$key.lineTolerance

function Get-Norm { param([string]$Path) return ($Path -replace '\\', '/').Trim().ToLowerInvariant() }

# ---------------------------------------------------------------- flatten findings into items

$items = New-Object System.Collections.Generic.List[object]
foreach ($f in @($doc.findings)) {
    $locations = New-Object System.Collections.Generic.List[object]
    $line = if ($null -ne $f.line) { [int]$f.line } else { $null }
    $end = if ($null -ne $f.endLine) { [int]$f.endLine } else { $line }
    $locations.Add([pscustomobject]@{ File = (Get-Norm $f.file); Line = $line; End = $end; Title = [string]$f.title; Text = ([string]$f.title + ' ' + [string]$f.detail) })
    foreach ($d in @($f.duplicates)) {
        if ($null -eq $d) { continue }
        $dl = if ($null -ne $d.line) { [int]$d.line } else { $null }
        $de = if ($null -ne $d.endLine) { [int]$d.endLine } else { $dl }
        $locations.Add([pscustomobject]@{ File = (Get-Norm $d.file); Line = $dl; End = $de; Title = [string]$d.title; Text = [string]$d.title })
    }
    $items.Add([pscustomobject]@{ Id = [string]$f.id; Severity = [string]$f.severity; Confidence = [double]$f.confidence; Title = [string]$f.title; Locations = $locations; UsedBy = $null })
}

function Test-Overlap {
    param($Location, [int]$From, [int]$To, [int]$Tolerance)
    if ($null -eq $Location.Line) { return $false }
    return ([Math]::Max([int]$Location.Line, $From - $Tolerance) -le [Math]::Min([int]$Location.End, $To + $Tolerance))
}

function Test-ItemMatchesDefect {
    param($Item, $Defect)
    foreach ($spec in @($Defect.anyOf)) {
        $file = Get-Norm $spec.file
        foreach ($loc in $Item.Locations) {
            if ($loc.File -ne $file) { continue }
            if (-not (Test-Overlap -Location $loc -From ([int]$spec.lines[0]) -To ([int]$spec.lines[1]) -Tolerance $tolerance)) { continue }
            foreach ($kw in @($spec.keywords)) {
                if ($loc.Text.IndexOf([string]$kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
        }
    }
    return $false
}

# ---------------------------------------------------------------- assign items to defects

function Resolve-Defects {
    param([object[]]$Defects, [string]$Group)
    $candidates = @{}
    foreach ($d in $Defects) { $candidates[$d.id] = @($items | Where-Object { -not $_.UsedBy -and (Test-ItemMatchesDefect -Item $_ -Defect $d) }) }
    $matchCount = @{}
    foreach ($it in $items) { $matchCount[$it.Id] = @($Defects | Where-Object { $candidates[$_.id] -contains $it }).Count }
    $results = @{}
    # Most constrained first: a defect with a single candidate claims it before a defect with several.
    foreach ($d in @($Defects | Sort-Object -Property @{ Expression = { $candidates[$_.id].Count } }, @{ Expression = { $_.id } })) {
        $choice = @($candidates[$d.id] | Where-Object { -not $_.UsedBy } |
            Sort-Object -Property @{ Expression = { $matchCount[$_.Id] } }, @{ Expression = { $severityRank[$_.Severity] } }, @{ Expression = { $_.Confidence }; Descending = $true }) |
            Select-Object -First 1
        $candidateCount = $candidates[$d.id].Count
        $defectId = [string]$d.id
        $defectTitle = [string]$d.title
        if ($choice) {
            $choice.UsedBy = $defectId
            $sevOk = $severityRank[$choice.Severity] -le $severityRank[[string]$d.minSeverity]
            $findingId = $choice.Id
            $findingSeverity = $choice.Severity
            $results[$defectId] = [pscustomobject]@{ Group = $Group; Id = $defectId; Title = $defectTitle; Found = $true; Finding = $findingId; Severity = $findingSeverity; SeverityOk = $sevOk; Candidates = $candidateCount }
        }
        else {
            $results[$defectId] = [pscustomobject]@{ Group = $Group; Id = $defectId; Title = $defectTitle; Found = $false; Finding = ''; Severity = ''; SeverityOk = $false; Candidates = $candidateCount }
        }
    }
    return @($Defects | ForEach-Object { $results[$_.id] })
}

$planted = Resolve-Defects -Defects @($key.planted) -Group 'planted'
$additional = Resolve-Defects -Defects @($key.additional) -Group 'additional'

# ---------------------------------------------------------------- must-not-report, coverage

$violations = New-Object System.Collections.Generic.List[object]
foreach ($n in @($key.mustNotReport)) {
    $file = Get-Norm $n.file
    foreach ($it in $items) {
        foreach ($loc in $it.Locations) {
            if ($loc.File -ne $file) { continue }
            if (-not (Test-Overlap -Location $loc -From ([int]$n.lines[0]) -To ([int]$n.lines[1]) -Tolerance 0)) { continue }
            foreach ($kw in @($n.titleKeywords)) {
                if ($loc.Title.IndexOf([string]$kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $violations.Add([pscustomobject]@{ Id = $n.id; Title = $n.title; Finding = $it.Id; FindingTitle = $loc.Title })
                }
            }
        }
    }
}

$reviewedActual = @(@($doc.coverage.reviewed) | ForEach-Object { Get-Norm $_ })
$skippedActual = @(@($doc.coverage.skipped) | ForEach-Object { Get-Norm $_.file })
$missingReviewed = @(@($key.expectedReviewed) | Where-Object { $reviewedActual -notcontains (Get-Norm $_) })
$missingSkipped = @(@($key.expectedSkipped) | Where-Object { $skippedActual -notcontains (Get-Norm $_) })

$foundPlanted = @($planted | Where-Object { $_.Found }).Count
$recall = if ($planted.Count -gt 0) { [math]::Round($foundPlanted / $planted.Count, 3) } else { 0 }
$passed = ($recall -ge $MinRecall) -and ($violations.Count -eq 0) -and ($missingReviewed.Count -eq 0) -and ($missingSkipped.Count -eq 0)

# ---------------------------------------------------------------- scorecard

function Write-Row {
    param($R)
    $status = if (-not $R.Found) { 'MISSED' } elseif (-not $R.SeverityOk) { 'low-sev' } else { 'found' }
    $where = if ($R.Found) { "{0,-4} {1,-10}" -f $R.Finding, $R.Severity } else { '{0,-15}' -f '-' }
    Write-Host ("  {0,-4} {1,-8} {2} {3}" -f $R.Id, $status, $where, $R.Title)
}

Write-Host ''
Write-Host ("Planted defects       {0} of {1} found, recall {2:0.00} (minimum {3:0.00})" -f $foundPlanted, $planted.Count, $recall, $MinRecall)
foreach ($r in $planted) { Write-Row $r }
Write-Host ("Additional defects    {0} of {1} found" -f @($additional | Where-Object { $_.Found }).Count, $additional.Count)
foreach ($r in $additional) { Write-Row $r }
Write-Host ("Must not be reported  {0} violation(s)" -f $violations.Count)
foreach ($v in $violations) { Write-Host "  $($v.Id) reported as $($v.Finding): $($v.FindingTitle)" }
Write-Host ("Files                 {0} of {1} expected reviewed, {2} of {3} expected skipped" -f ($key.expectedReviewed.Count - $missingReviewed.Count), $key.expectedReviewed.Count, ($key.expectedSkipped.Count - $missingSkipped.Count), $key.expectedSkipped.Count)
foreach ($m in $missingReviewed) { Write-Host "  not reviewed: $m" }
foreach ($m in $missingSkipped) { Write-Host "  not skipped:  $m" }
Write-Host ("Result                {0}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }))

# Built by assignment, never with @() or pipelines inside a hashtable literal: PowerShell 7's
# PSToObjectArrayBinder throws "Argument types do not match" on that pattern.
$foundAdditional = @($additional | Where-Object { $_.Found }).Count
$totalPlanted = $planted.Count
$violationList = $violations.ToArray()
$result = [pscustomobject]@{}
$result | Add-Member -NotePropertyName Passed -NotePropertyValue $passed
$result | Add-Member -NotePropertyName Recall -NotePropertyValue $recall
$result | Add-Member -NotePropertyName FoundPlanted -NotePropertyValue $foundPlanted
$result | Add-Member -NotePropertyName TotalPlanted -NotePropertyValue $totalPlanted
$result | Add-Member -NotePropertyName FoundAdditional -NotePropertyValue $foundAdditional
$result | Add-Member -NotePropertyName Planted -NotePropertyValue $planted
$result | Add-Member -NotePropertyName Additional -NotePropertyValue $additional
$result | Add-Member -NotePropertyName Violations -NotePropertyValue $violationList
$result | Add-Member -NotePropertyName MissingReviewed -NotePropertyValue $missingReviewed
$result | Add-Member -NotePropertyName MissingSkipped -NotePropertyValue $missingSkipped
if ($PassThru) { return $result }
exit $(if ($passed) { 0 } else { 1 })
