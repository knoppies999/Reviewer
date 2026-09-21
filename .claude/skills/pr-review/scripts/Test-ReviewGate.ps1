#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the review gate to findings.json and fails (non-zero exit) when it is not met.

.DESCRIPTION
    Gate modes:
      blocking  fail when any counted finding has severity "blocking"
      security  fail only when a counted "blocking" finding has category "security"
      none      never fail; print the summary only
    A finding is counted when its verification is not "refuted". Findings verified as "unverified"
    count too unless -IgnoreUnverified is given.

    Mode resolution: -Gate, then $env:PR_REVIEW_GATE, then config.json "gate", then "blocking".
    Exit codes: 0 pass, 1 gate failed, 2 no findings file (unless allowed).

.PARAMETER FindingsPath
    Default: <output dir>/findings.json where the output dir is $env:PR_REVIEW_OUTPUT_DIR,
    then $env:BUILD_ARTIFACTSTAGINGDIRECTORY/pr-review, then ./.pr-review.
.PARAMETER Gate
    blocking | security | none.
.PARAMETER ConfigPath
    Default: ../config.json relative to this script.
.PARAMETER IgnoreUnverified
    Do not count blocking findings the integration pass could not verify.
.PARAMETER AllowMissingReport
    Exit 0 when findings.json does not exist (overrides config failOnMissingReport).
.EXAMPLE
    pwsh -NoProfile -File Test-ReviewGate.ps1 -Gate security
#>
[CmdletBinding()]
param(
    [string]$FindingsPath,
    [ValidateSet('', 'blocking', 'security', 'none')][string]$Gate = '',
    [string]$ConfigPath,
    [switch]$IgnoreUnverified,
    [switch]$AllowMissingReport
)

$ErrorActionPreference = 'Stop'
$isPipeline = -not [string]::IsNullOrEmpty($env:TF_BUILD)

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

function Write-Issue {
    param([ValidateSet('error', 'warning')][string]$Type, [string]$Message)
    if ($isPipeline) { Write-Host "##vso[task.logissue type=$Type]$Message" }
    elseif ($Type -eq 'error') { Write-Host "ERROR: $Message" -ForegroundColor Red }
    else { Write-Warning $Message }
}

function Stop-WithFailure {
    param([string]$Message, [int]$Code = 1)
    Write-Issue -Type 'error' -Message $Message
    if ($isPipeline) { Write-Host "##vso[task.complete result=Failed;]$Message" }
    exit $Code
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $skillRoot 'config.json' }
$config = $null
if (Test-Path -LiteralPath $ConfigPath) { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }

if (-not $Gate) {
    if ($env:PR_REVIEW_GATE) { $Gate = $env:PR_REVIEW_GATE } else { $Gate = [string](Get-Prop $config 'gate' 'blocking') }
}
$Gate = $Gate.Trim().ToLowerInvariant()
if ($Gate -notin @('blocking', 'security', 'none')) { Stop-WithFailure "Unknown gate '$Gate'. Use blocking, security or none." 2 }

if (-not $FindingsPath) {
    if ($env:PR_REVIEW_OUTPUT_DIR) { $dir = $env:PR_REVIEW_OUTPUT_DIR }
    elseif ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $dir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'pr-review' }
    else { $dir = Join-Path (Get-Location).Path ([string](Get-Prop $config 'reportDirName' '.pr-review')) }
    $FindingsPath = Join-Path $dir 'findings.json'
}

if (-not (Test-Path -LiteralPath $FindingsPath)) {
    $failOnMissing = (-not $AllowMissingReport) -and [bool](Get-Prop $config 'failOnMissingReport' $true)
    if ($Gate -eq 'none' -or -not $failOnMissing) {
        Write-Issue -Type 'warning' -Message "No findings file at $FindingsPath; nothing to gate."
        exit 0
    }
    Stop-WithFailure "The review did not produce $FindingsPath. The review step failed or wrote somewhere else; check its log. (Set failOnMissingReport=false in config.json or pass -AllowMissingReport to make this a warning.)" 2
}

$findings = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json
$all = @(Get-Prop $findings 'findings' @())
$verdict = [string](Get-Prop $findings 'verdict' 'unknown')

$counted = @($all | Where-Object {
        (Get-Prop $_ 'severity' '') -eq 'blocking' -and
        (Get-Prop $_ 'verification' 'not-checked') -ne 'refuted' -and
        (-not $IgnoreUnverified -or (Get-Prop $_ 'verification' 'not-checked') -ne 'unverified')
    })
switch ($Gate) {
    'none' { $failing = @() }
    'security' { $failing = @($counted | Where-Object { (Get-Prop $_ 'category' '') -eq 'security' }) }
    default { $failing = $counted }
}

$bySeverity = @{}
foreach ($f in $all) {
    $s = [string](Get-Prop $f 'severity' 'unknown')
    if ($bySeverity.ContainsKey($s)) { $bySeverity[$s]++ } else { $bySeverity[$s] = 1 }
}
$summaryParts = @()
foreach ($s in @('blocking', 'should-fix', 'nit', 'question')) { if ($bySeverity.ContainsKey($s)) { $summaryParts += "$($bySeverity[$s]) $s" } }
if ($summaryParts.Count -eq 0) { $summaryParts = @('no findings') }

Write-Host ''
Write-Host "PR review gate: $Gate"
Write-Host "  Verdict:  $verdict"
Write-Host "  Findings: $($summaryParts -join ', ')"
if ($isPipeline) { Write-Host "##vso[task.setvariable variable=PrReviewVerdict]$verdict" }

# A review that could not review some or all files must not pass silently.
$incomplete = ([bool](Get-Prop $findings 'incomplete' $false)) -or ($verdict -eq 'incomplete')
$failedFiles = @(Get-Prop (Get-Prop $findings 'coverage' $null) 'failed' @())
$failOnIncomplete = [bool](Get-Prop $config 'failOnIncomplete' $true)
$incompleteBlocks = $incomplete -and $failOnIncomplete -and ($Gate -ne 'none')

if ($failing.Count -gt 0) {
    Write-Host "  Gate hits: $($failing.Count)"
    foreach ($f in $failing) {
        $loc = "$(Get-Prop $f 'file' '?'):$(Get-Prop $f 'line' '?')"
        $msg = "[$(Get-Prop $f 'id' '-')] $loc $(Get-Prop $f 'title' '') ($(Get-Prop $f 'category' '-'), confidence $(Get-Prop $f 'confidence' '-'), $(Get-Prop $f 'verification' 'not-checked'))"
        Write-Issue -Type 'error' -Message $msg
    }
}
if ($incomplete) {
    Write-Host "  Not reviewed: $($failedFiles.Count) file(s)"
    $issueType = if ($incompleteBlocks) { 'error' } else { 'warning' }
    foreach ($ff in $failedFiles) { Write-Issue -Type $issueType -Message "Not reviewed: $(Get-Prop $ff 'file' '?') ($(Get-Prop $ff 'error' '-'))" }
}
if ($failing.Count -gt 0 -or $incompleteBlocks) {
    $reasons = @()
    if ($failing.Count -gt 0) { $reasons += "$($failing.Count) blocking finding(s)" }
    if ($incompleteBlocks) { $reasons += "the review is incomplete ($($failedFiles.Count) file(s) not reviewed; set failOnIncomplete=false in config.json to allow this)" }
    Stop-WithFailure "PR review gate '$Gate' failed: $($reasons -join ' and '). See the review comment on the PR or the pr-review artifact." 1
}

Write-Host "  Result:   pass"
exit 0
