#Requires -Version 5.1
<#
.SYNOPSIS
    Posts the review report to an Azure DevOps pull request as a comment thread, updating the
    previous review comment on re-runs, with optional inline threads for high-severity findings.

.DESCRIPTION
    On a pipeline every parameter defaults to the predefined variables; map System.AccessToken into
    the step as SYSTEM_ACCESSTOKEN and give the build service identity "Contribute to pull requests"
    on the repository. Locally, pass -Token with a PAT that has Code (read & write) scope.

    The summary comment carries a hidden marker so a re-run edits the existing comment instead of
    adding a new one. Inline threads carry a per-finding fingerprint so they are not duplicated.

.PARAMETER ReportPath
    Default: <output dir>/report.md.
.PARAMETER FindingsPath
    Default: <output dir>/findings.json. Used for the thread status and inline comments.
.PARAMETER OrganizationUrl
    e.g. https://dev.azure.com/contoso/  Default: $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI.
.PARAMETER Project
    Default: $env:SYSTEM_TEAMPROJECT.
.PARAMETER Repository
    Repository id or name. Default: $env:BUILD_REPOSITORY_ID.
.PARAMETER PullRequestId
    Default: $env:SYSTEM_PULLREQUEST_PULLREQUESTID.
.PARAMETER Token
    System.AccessToken (Bearer) or a PAT (Basic). Default: $env:SYSTEM_ACCESSTOKEN.
.PARAMETER InlineComments
    Also post one thread per finding whose severity is in -InlineSeverities. Default: config postInlineComments.
.PARAMETER InlineSeverities
    Default: config inlineCommentSeverities, else "blocking".
.PARAMETER NoUpdateExisting
    Always create a new summary thread instead of editing the previous one.
.PARAMETER NotifyOnMissing
    When report.md is missing, post a short "review did not complete" comment instead of doing nothing.
.PARAMETER MaxCommentLength
    Truncate the summary comment beyond this many characters (the artifact keeps the full report).
.EXAMPLE
    pwsh -NoProfile -File Publish-AdoPrComment.ps1 -InlineComments
.EXAMPLE
    pwsh -NoProfile -File Publish-AdoPrComment.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Shop -Repository shop-api -PullRequestId 123 -Token $pat -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ReportPath,
    [string]$FindingsPath,
    [string]$OrganizationUrl = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI,
    [string]$Project = $env:SYSTEM_TEAMPROJECT,
    [string]$Repository = $env:BUILD_REPOSITORY_ID,
    [string]$PullRequestId = $env:SYSTEM_PULLREQUEST_PULLREQUESTID,
    [string]$Token = $env:SYSTEM_ACCESSTOKEN,
    [switch]$InlineComments,
    [string[]]$InlineSeverities,
    [switch]$NoUpdateExisting,
    [switch]$NotifyOnMissing,
    [int]$MaxCommentLength = 60000,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$isPipeline = -not [string]::IsNullOrEmpty($env:TF_BUILD)
$summaryMarker = '<!-- pr-review:summary -->'
$utf8 = [System.Text.Encoding]::UTF8

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

function Get-Fingerprint {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha.ComputeHash($utf8.GetBytes($Text))
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    }
    finally { $sha.Dispose() }
}

# ---------------------------------------------------------------- inputs

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $skillRoot 'config.json' }
$config = $null
if (Test-Path -LiteralPath $ConfigPath) { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }

if ($env:PR_REVIEW_OUTPUT_DIR) { $outputDir = $env:PR_REVIEW_OUTPUT_DIR }
elseif ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { $outputDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'pr-review' }
else { $outputDir = Join-Path (Get-Location).Path ([string](Get-Prop $config 'reportDirName' '.pr-review')) }
if (-not $ReportPath) { $ReportPath = Join-Path $outputDir 'report.md' }
if (-not $FindingsPath) { $FindingsPath = Join-Path $outputDir 'findings.json' }

if (-not $PSBoundParameters.ContainsKey('InlineComments')) { $InlineComments = [bool](Get-Prop $config 'postInlineComments' $false) }
if (-not $InlineSeverities -or $InlineSeverities.Count -eq 0) { $InlineSeverities = @(Get-Prop $config 'inlineCommentSeverities' @('blocking')) }

$missing = @()
if (-not $OrganizationUrl) { $missing += 'OrganizationUrl (SYSTEM_TEAMFOUNDATIONCOLLECTIONURI)' }
if (-not $Project) { $missing += 'Project (SYSTEM_TEAMPROJECT)' }
if (-not $Repository) { $missing += 'Repository (BUILD_REPOSITORY_ID)' }
if (-not $PullRequestId) { $missing += 'PullRequestId (SYSTEM_PULLREQUEST_PULLREQUESTID)' }
if (-not $Token) { $missing += 'Token (SYSTEM_ACCESSTOKEN; map it with env: SYSTEM_ACCESSTOKEN: $(System.AccessToken))' }
if ($missing.Count -gt 0) {
    if (-not $PullRequestId -and $isPipeline -and $env:BUILD_REASON -ne 'PullRequest') {
        Write-Host "Not a pull request build (Build.Reason=$($env:BUILD_REASON)); nothing to post."
        exit 0
    }
    Write-Issue -Type 'error' -Message "Cannot post to the pull request; missing: $($missing -join ', ')"
    exit 1
}

# System.AccessToken is a JWT (Bearer); a PAT is used with Basic auth.
$isJwt = $Token -match '^ey[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.'
$authHeader = if ($isJwt) { "Bearer $Token" } else { 'Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$Token")) }
$headers = @{ Authorization = $authHeader; 'Content-Type' = 'application/json'; Accept = 'application/json' }
$prBase = "$($OrganizationUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Project))/_apis/git/repositories/$([uri]::EscapeDataString($Repository))/pullRequests/$PullRequestId"

function Invoke-Ado {
    param([string]$Method, [string]$Uri, $Body)
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body ($utf8.GetBytes($json))
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        $detail = ''
        try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = " $($_.ErrorDetails.Message)" } } catch { }
        throw "Azure DevOps API $Method $Uri failed: $($_.Exception.Message)$detail"
    }
}

# ---------------------------------------------------------------- content

$findings = $null
if (Test-Path -LiteralPath $FindingsPath) { $findings = Get-Content -LiteralPath $FindingsPath -Raw | ConvertFrom-Json }
$verdict = [string](Get-Prop $findings 'verdict' '')

$buildLink = ''
if ($env:BUILD_BUILDID) {
    $buildLink = " $([char]0x00B7) [build $($env:BUILD_BUILDNUMBER)]($($OrganizationUrl.TrimEnd('/'))/$([uri]::EscapeDataString($Project))/_build/results?buildId=$($env:BUILD_BUILDID))"
}
$footer = "`n`n---`n_Posted by the pr-review pipeline$buildLink $([char]0x00B7) $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC_"

if (Test-Path -LiteralPath $ReportPath) {
    $report = Get-Content -LiteralPath $ReportPath -Raw
    $content = "$summaryMarker`n$report"
    $limit = $MaxCommentLength - $footer.Length - 200
    if ($content.Length -gt $limit) {
        $content = $content.Substring(0, $limit) + "`n`n_$([char]0x2026) report truncated; the full report.md is in the **pr-review** build artifact._"
    }
    $content += $footer
    # An open (active) thread when changes are requested or the review is incomplete; otherwise resolved so it does not nag.
    $reviewIncomplete = [bool](Get-Prop $findings 'incomplete' $false)
    $threadStatus = if ($verdict -eq 'request-changes' -or $verdict -eq 'incomplete' -or $reviewIncomplete -or -not $verdict) { 1 } else { 4 }
}
elseif ($NotifyOnMissing) {
    $content = "$summaryMarker`n### PR review did not complete`nThe automated review produced no report. Check the review step in the build log.$footer"
    $threadStatus = 1
}
else {
    Write-Issue -Type 'warning' -Message "No report at $ReportPath; nothing to post."
    exit 0
}

# ---------------------------------------------------------------- summary thread

$threads = Invoke-Ado -Method Get -Uri "$prBase/threads?api-version=7.1"
$existingThreads = @(Get-Prop $threads 'value' @())
$existing = $null
if (-not $NoUpdateExisting) {
    $existing = $existingThreads | Where-Object {
        -not (Get-Prop $_ 'isDeleted' $false) -and
        @(Get-Prop $_ 'comments' @()).Count -gt 0 -and
        ([string](Get-Prop (@(Get-Prop $_ 'comments' @()))[0] 'content' '')).Contains($summaryMarker)
    } | Select-Object -First 1
}

if ($existing) {
    $threadId = $existing.id
    $commentId = (@($existing.comments))[0].id
    if ($PSCmdlet.ShouldProcess("PR $PullRequestId thread $threadId", 'Update review summary comment')) {
        Invoke-Ado -Method Patch -Uri "$prBase/threads/$threadId/comments/$commentId`?api-version=7.1" -Body @{ content = $content } | Out-Null
        Invoke-Ado -Method Patch -Uri "$prBase/threads/$threadId`?api-version=7.1" -Body @{ status = $threadStatus } | Out-Null
        Write-Host "Updated review comment (thread $threadId) on PR $PullRequestId."
    }
}
else {
    if ($PSCmdlet.ShouldProcess("PR $PullRequestId", 'Create review summary comment')) {
        $created = Invoke-Ado -Method Post -Uri "$prBase/threads?api-version=7.1" -Body @{
            comments = @(@{ parentCommentId = 0; content = $content; commentType = 1 })
            status   = $threadStatus
        }
        Write-Host "Posted review comment (thread $($created.id)) on PR $PullRequestId."
    }
}

# ---------------------------------------------------------------- inline threads

if ($InlineComments -and $null -ne $findings) {
    $allContent = @()
    foreach ($t in $existingThreads) {
        foreach ($c in @(Get-Prop $t 'comments' @())) { $allContent += [string](Get-Prop $c 'content' '') }
    }
    $posted = 0
    foreach ($f in @(Get-Prop $findings 'findings' @())) {
        $severity = [string](Get-Prop $f 'severity' '')
        $file = [string](Get-Prop $f 'file' '')
        $line = Get-Prop $f 'line' $null
        if ($InlineSeverities -notcontains $severity) { continue }
        if ((Get-Prop $f 'verification' 'not-checked') -eq 'refuted') { continue }
        if (-not $file -or $null -eq $line) { continue }

        $title = [string](Get-Prop $f 'title' '')
        $fingerprint = Get-Fingerprint -Text "$file|$line|$title"
        $marker = "<!-- pr-review:finding:$fingerprint -->"
        if (@($allContent | Where-Object { $_.Contains($marker) }).Count -gt 0) { continue }

        $endLine = Get-Prop $f 'endLine' $line
        $suggestion = [string](Get-Prop $f 'suggestion' '')
        $body = "$marker`n**$severity $([char]0x00B7) $(Get-Prop $f 'category' '-') $([char]0x00B7) confidence $(Get-Prop $f 'confidence' '-') $([char]0x00B7) $(Get-Prop $f 'verification' 'not-checked')**`n`n**$title**`n`n$(Get-Prop $f 'detail' '')"
        if ($suggestion) { $body += "`n`n**Suggestion:** $suggestion" }
        $dups = @(Get-Prop $f 'duplicates' @())
        if ($dups.Count -gt 0) {
            $refs = @($dups | ForEach-Object { "$(Get-Prop $_ 'id' '?') at ``$(Get-Prop $_ 'file' '?'):$(Get-Prop $_ 'line' '?')``" })
            $body += "`n`nAlso reported as $($refs -join ', ')."
        }

        $thread = @{
            comments      = @(@{ parentCommentId = 0; content = $body; commentType = 1 })
            status        = 1
            threadContext = @{
                filePath       = '/' + $file.TrimStart('/')
                rightFileStart = @{ line = [int]$line; offset = 1 }
                rightFileEnd   = @{ line = [int]$endLine; offset = 1 }
            }
        }
        if ($PSCmdlet.ShouldProcess("PR $PullRequestId $file`:$line", 'Create inline finding comment')) {
            try {
                Invoke-Ado -Method Post -Uri "$prBase/threads?api-version=7.1" -Body $thread | Out-Null
                $posted++
            }
            catch {
                Write-Issue -Type 'warning' -Message "Could not post inline comment for $file`:$line - $($_.Exception.Message)"
            }
        }
    }
    Write-Host "Posted $posted inline finding comment(s)."
}

exit 0
