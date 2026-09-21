#Requires -Version 7.0
<#
.SYNOPSIS
    End-to-end self-test: builds a sample repository with planted defects, reviews it, and checks the result.

.DESCRIPTION
    Two modes, both running the same scripts a real review runs.

    Offline (default, no -Harness). Deterministic, needs no credentials, takes seconds:
      1. Builds the fixture repository with fixture/New-SampleRepo.ps1.
      2. Computes the change set with Get-PrDiff.ps1 and checks which files are reviewed and skipped.
      3. Runs Invoke-PrReview.ps1 with a replay harness that answers every prompt from a recorded
         real review (fixture/recorded), so the driver, JSON extraction, id assignment,
         integration prompt, merge and report are all exercised.
      4. Checks the merged result exactly: verdict, counts, and that duplicates are folded but
         distinct defects on one line are not.
      5. Scores the findings against fixture/answer-key.json with Measure-Review.ps1.
      6. Checks the gate in all three modes, and under Windows PowerShell 5.1 when available.

    Live (-Harness claude|copilot). Calls a real model, costs usage, takes 15 to 20 minutes:
      Steps 1, 2, 5 and 6 as above, with step 3 using the real harness. Exact counts are not
      checked because a model does not produce the same findings twice; the scorecard's recall
      threshold, the must-not-report list and the gate are what decide pass or fail.

    Exit code 0 when every check passed, 1 otherwise. The working directory is deleted on
    success and kept on failure so the outputs can be inspected.

.PARAMETER Harness
    A harness from config.json for a live run. Omit for the offline run.
.PARAMETER Model
    Model id for a live run.
.PARAMETER MaxParallel
    Parallel per-file reviews. Default 4.
.PARAMETER MinRecall
    Minimum recall on planted defects for a live run. Default 0.8. The offline run requires 1.0.
.PARAMETER SkillRoot
    Skill to test. Default: .claude/skills/pr-review in this repository.
.PARAMETER WorkDir
    Where to build the fixture and write the review. Default: a new directory under the temp folder.
.PARAMETER KeepWorkDir
    Keep the working directory even when every check passed.
.EXAMPLE
    pwsh -File tests/Invoke-SelfTest.ps1
.EXAMPLE
    pwsh -File tests/Invoke-SelfTest.ps1 -Harness claude -KeepWorkDir
#>
[CmdletBinding()]
param(
    [string]$Harness,
    [string]$Model,
    [int]$MaxParallel = 4,
    [double]$MinRecall = 0.8,
    [string]$SkillRoot,
    [string]$WorkDir,
    [switch]$KeepWorkDir
)

$ErrorActionPreference = 'Stop'
$started = Get-Date
$live = [bool]$Harness
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SkillRoot) { $SkillRoot = Join-Path $repoRoot '.claude/skills/pr-review' }
$SkillRoot = [System.IO.Path]::GetFullPath($SkillRoot)
$scripts = Join-Path $SkillRoot 'scripts'
$fixtureDir = Join-Path $PSScriptRoot 'fixture'
$recordingDir = Join-Path $fixtureDir 'recorded'
$answerKey = Join-Path $fixtureDir 'answer-key.json'
$pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not $WorkDir) { $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ('reviewer-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)
$sampleRepo = Join-Path $WorkDir 'sample-repo'
$out = Join-Path $WorkDir 'review'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$checks = New-Object System.Collections.Generic.List[object]
function Assert-Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $checks.Add([pscustomobject]@{ Name = $Name; Passed = $Condition; Detail = $Detail })
    $mark = if ($Condition) { 'pass' } else { 'FAIL' }
    $suffix = if ($Detail) { " ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $mark, $Name, $suffix)
}
function Write-Step { param([string]$Text) Write-Host ''; Write-Host "== $Text" }
function Invoke-Script {
    # Runs a script in a child pwsh, the way a pipeline would, and returns its output and exit code.
    param([string]$Path, [string[]]$Arguments, [string]$Shell = $pwsh)
    $output = & $Shell -NoProfile -File $Path @Arguments 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $lines = @($output)
    # Assigned first: @() inside a hashtable literal trips PowerShell 7's PSToObjectArrayBinder.
    return [pscustomobject]@{ ExitCode = $code; Output = $lines }
}

$mode = if ($live) { "live, harness '$Harness'" } else { 'offline, replaying the recorded review' }
Write-Host "Reviewer self-test ($mode)"
Write-Host "  skill:   $SkillRoot"
Write-Host "  workdir: $WorkDir"

try {
    # ------------------------------------------------------------ 1. fixture
    Write-Step 'Build the fixture repository'
    $r = Invoke-Script -Path (Join-Path $fixtureDir 'New-SampleRepo.ps1') -Arguments @('-Path', $sampleRepo)
    Assert-Check 'fixture repository built' ($r.ExitCode -eq 0) ($r.Output | Select-Object -Last 1)
    if ($r.ExitCode -ne 0) { throw "Fixture build failed:`n$($r.Output -join "`n")" }

    # ------------------------------------------------------------ 2. change set
    Write-Step 'Compute the change set'
    $r = Invoke-Script -Path (Join-Path $scripts 'Get-PrDiff.ps1') -Arguments @('-Base', 'main', '-RepositoryPath', $sampleRepo, '-OutputDir', $out, '-NoFetch')
    Assert-Check 'Get-PrDiff.ps1 exit code 0' ($r.ExitCode -eq 0)
    if ($r.ExitCode -ne 0) { throw "Get-PrDiff.ps1 failed:`n$($r.Output -join "`n")" }
    $manifestPath = Join-Path $out 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
    $key = Get-Content -LiteralPath $answerKey -Raw | ConvertFrom-Json -Depth 20
    $toReview = @($manifest.files | Where-Object { $_.reviewMode -eq 'review' } | ForEach-Object { $_.path } | Sort-Object)
    $skipped = @($manifest.files | Where-Object { $_.reviewMode -eq 'skip' } | ForEach-Object { $_.path } | Sort-Object)
    Assert-Check 'files to review match the answer key' ((($toReview -join '|') -eq ((@($key.expectedReviewed) | Sort-Object) -join '|'))) "$($toReview.Count) file(s)"
    Assert-Check 'skipped files match the answer key' ((($skipped -join '|') -eq ((@($key.expectedSkipped) | Sort-Object) -join '|'))) "$($skipped.Count) file(s)"
    Assert-Check 'skips are explained by a skip pattern' (@($manifest.files | Where-Object { $_.reviewMode -eq 'skip' -and $_.skipReason -notlike 'matches skip pattern*' }).Count -eq 0)
    Assert-Check 'pull request title comes from the head commit' ($manifest.pr.title -eq 'Add refunds') $manifest.pr.title

    # ------------------------------------------------------------ 3. review
    $driver = Join-Path $scripts 'Invoke-PrReview.ps1'
    $driverArgs = @('-ManifestPath', $manifestPath, '-MaxParallel', "$MaxParallel", '-CI')
    if ($live) {
        Write-Step "Run the review with '$Harness' (this calls a real model)"
        $driverArgs = @('-Harness', $Harness) + $driverArgs
        if ($Model) { $driverArgs += @('-Model', $Model) }
    }
    else {
        Write-Step 'Run the review with the replay harness'
        $config = Get-Content -LiteralPath (Join-Path $SkillRoot 'config.json') -Raw | ConvertFrom-Json -Depth 20
        $replayArgs = [string[]]@('-NoProfile', '-File', (Join-Path $fixtureDir 'Invoke-ReplayHarness.ps1'), '-PromptFile', '{{promptFile}}', '-RecordingDir', $recordingDir)
        $empty = [string[]]@()
        $replay = [pscustomobject]@{ command = $pwsh; args = $replayArgs; modelArgs = $empty; ciArgs = $empty; integrationArgs = $empty; env = [pscustomobject]@{} }
        $config.harnesses | Add-Member -Force -NotePropertyName 'replay' -NotePropertyValue $replay
        $configPath = Join-Path $WorkDir 'config-replay.json'
        [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
        $driverArgs = @('-Harness', 'replay', '-ConfigPath', $configPath) + $driverArgs
    }
    $reviewStarted = Get-Date
    $r = Invoke-Script -Path $driver -Arguments $driverArgs
    $seconds = [math]::Round(((Get-Date) - $reviewStarted).TotalSeconds, 1)
    Assert-Check 'Invoke-PrReview.ps1 exit code 0' ($r.ExitCode -eq 0) "$seconds s"
    if ($r.ExitCode -ne 0) { Write-Host ($r.Output -join "`n") }

    $findingsPath = Join-Path $out 'findings.json'
    $reportPath = Join-Path $out 'report.md'
    Assert-Check 'findings.json and report.md written' ((Test-Path -LiteralPath $findingsPath) -and (Test-Path -LiteralPath $reportPath))
    if (-not (Test-Path -LiteralPath $findingsPath)) { throw 'The review produced no findings.json.' }
    $doc = Get-Content -LiteralPath $findingsPath -Raw | ConvertFrom-Json -Depth 30
    $report = Get-Content -LiteralPath $reportPath -Raw

    # ------------------------------------------------------------ 4. merged result
    Write-Step 'Check the merged result'
    Assert-Check 'every reviewable file was reviewed' (@($doc.coverage.failed).Count -eq 0) "$(@($doc.coverage.reviewed).Count) reviewed, $(@($doc.coverage.failed).Count) failed"
    Assert-Check 'the integration pass ran' ([bool]$doc.integrationPassRan)
    Assert-Check 'verdict is request-changes' ($doc.verdict -eq 'request-changes') $doc.verdict

    $keptIds = @($doc.findings | ForEach-Object { $_.id })
    $byId = @{}
    foreach ($f in $doc.findings) { $byId[$f.id] = $f }
    function Get-DuplicateIds { param([string]$Id) if ($byId.ContainsKey($Id)) { return @($byId[$Id].duplicates | ForEach-Object { $_.id }) } return @() }

    if (-not $live) {
        # Exact expectations for the recorded run (fixture/recorded). If the recording is replaced,
        # update these numbers from the new run and re-check the two regression cases by hand.
        $c = $doc.counts
        Assert-Check 'counts: 13 blocking, 13 should-fix, 0 nit, 2 question, 0 refuted' (($c.blocking -eq 13) -and ($c.'should-fix' -eq 13) -and ($c.nit -eq 0) -and ($c.question -eq 2) -and ($c.refuted -eq 0)) "$($c.blocking)/$($c.'should-fix')/$($c.nit)/$($c.question)/$($c.refuted)"
        Assert-Check 'three duplicates merged' ($doc.mergedDuplicates -eq 3) "$($doc.mergedDuplicates)"

        # Regression: two different defects on one line were once folded into one finding.
        Assert-Check 'over-merge fixed: F6 (KeyNotFound) and F9 (culture-sensitive ToLower) stay separate' (($keptIds -contains 'F6') -and ($keptIds -contains 'F9'))
        # Regression: the same defect reported from two files once stayed as two findings.
        Assert-Check 'under-merge fixed: F16 folded into F1' ((Get-DuplicateIds 'F1') -contains 'F16')
        Assert-Check 'under-merge fixed: F17 folded into F3' ((Get-DuplicateIds 'F3') -contains 'F17')
        Assert-Check 'under-merge fixed: F20 folded into F4' ((Get-DuplicateIds 'F4') -contains 'F20')
        Assert-Check 'folded findings are not also listed on their own' (@('F16', 'F17', 'F20' | Where-Object { $keptIds -contains $_ }).Count -eq 0)
        Assert-Check 'a folded group keeps the higher confidence (F4 takes 0.8 from F20)' ([double]$byId['F4'].confidence -eq 0.8) "$($byId['F4'].confidence)"

        # Conservation: every finding the reviewers returned is accounted for somewhere.
        $accounted = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($f in $doc.findings) { [void]$accounted.Add($f.id); foreach ($d in @($f.duplicates)) { if ($d) { [void]$accounted.Add($d.id) } } }
        foreach ($f in @($doc.refuted)) { [void]$accounted.Add($f.id) }
        $missing = @(1..31 | ForEach-Object { "F$_" } | Where-Object { -not $accounted.Contains($_) })
        Assert-Check 'no finding lost: F1 to F31 all kept, folded or refuted' (($missing.Count -eq 0) -and ($doc.droppedLowConfidence -eq 0)) $(if ($missing) { "missing $($missing -join ', ')" } else { '' })
        Assert-Check 'report names the folded duplicates' ($report.Contains('Also reported as F16 at'))
    }

    # ------------------------------------------------------------ 5. score
    Write-Step 'Score against the answer key'
    $threshold = if ($live) { $MinRecall } else { 1.0 }
    $score = & (Join-Path $PSScriptRoot 'Measure-Review.ps1') -FindingsPath $findingsPath -AnswerKeyPath $answerKey -MinRecall $threshold -PassThru
    Write-Host ''
    Assert-Check "recall on planted defects at least $threshold" ($score.Recall -ge $threshold) "$($score.FoundPlanted) of $($score.TotalPlanted)"
    Assert-Check 'nothing on the must-not-report list was reported' (@($score.Violations).Count -eq 0)
    Assert-Check 'expected files reviewed and skipped' ((@($score.MissingReviewed).Count -eq 0) -and (@($score.MissingSkipped).Count -eq 0))
    if (-not $live) { Assert-Check 'all additional real defects found' ($score.FoundAdditional -eq @($key.additional).Count) "$($score.FoundAdditional) of $(@($key.additional).Count)" }

    # ------------------------------------------------------------ 6. gate
    Write-Step 'Check the gate'
    $gate = Join-Path $scripts 'Test-ReviewGate.ps1'
    $g = Invoke-Script -Path $gate -Arguments @('-FindingsPath', $findingsPath, '-Gate', 'blocking')
    Assert-Check 'gate blocking fails (exit 1)' ($g.ExitCode -eq 1) "exit $($g.ExitCode)"
    $g = Invoke-Script -Path $gate -Arguments @('-FindingsPath', $findingsPath, '-Gate', 'none')
    Assert-Check 'gate none passes (exit 0)' ($g.ExitCode -eq 0) "exit $($g.ExitCode)"
    if (-not $live) {
        $g = Invoke-Script -Path $gate -Arguments @('-FindingsPath', $findingsPath, '-Gate', 'security')
        Assert-Check 'gate security fails on the unverified ownership finding (exit 1)' ($g.ExitCode -eq 1) "exit $($g.ExitCode)"
    }

    # ------------------------------------------------------------ 7. Windows PowerShell 5.1
    $winPs = if ($IsWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source } else { $null }
    if ($winPs) {
        Write-Step 'Repeat the merge and gate under Windows PowerShell 5.1'
        $out51 = Join-Path $WorkDir 'review-ps51'
        New-Item -ItemType Directory -Force -Path $out51 | Out-Null
        foreach ($name in 'manifest.json', 'file-results.jsonl', 'integration-result.json') {
            $source = Join-Path $out $name
            if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $out51 }
        }
        $m = Invoke-Script -Path (Join-Path $scripts 'Merge-ReviewResults.ps1') -Arguments @('-OutputDir', $out51) -Shell $winPs
        Assert-Check 'merge runs under 5.1' ($m.ExitCode -eq 0) "exit $($m.ExitCode)"
        $doc51 = Get-Content -LiteralPath (Join-Path $out51 'findings.json') -Raw | ConvertFrom-Json -Depth 30
        $same = ($doc51.verdict -eq $doc.verdict) -and ((@($doc51.findings | ForEach-Object { $_.id }) -join ',') -eq ($keptIds -join ',')) -and ($doc51.mergedDuplicates -eq $doc.mergedDuplicates)
        Assert-Check 'merge under 5.1 gives the same result as PowerShell 7' $same
        $g = Invoke-Script -Path $gate -Arguments @('-FindingsPath', (Join-Path $out51 'findings.json'), '-Gate', 'blocking') -Shell $winPs
        Assert-Check 'gate under 5.1 fails (exit 1)' ($g.ExitCode -eq 1) "exit $($g.ExitCode)"
    }
}
catch {
    Assert-Check 'self-test completed without an error' $false $_.Exception.Message
}

# ---------------------------------------------------------------- summary
$failed = @($checks | Where-Object { -not $_.Passed })
$elapsed = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
Write-Host ''
if ($failed.Count -eq 0) {
    Write-Host "Self-test passed: $($checks.Count) checks in $elapsed s."
    if ($KeepWorkDir) { Write-Host "Outputs kept in $WorkDir" } else { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}
Write-Host "Self-test FAILED: $($failed.Count) of $($checks.Count) checks failed in $elapsed s."
foreach ($f in $failed) { Write-Host "  - $($f.Name)$(if ($f.Detail) { " ($($f.Detail))" })" }
Write-Host "Outputs kept for inspection in $WorkDir"
exit 1
