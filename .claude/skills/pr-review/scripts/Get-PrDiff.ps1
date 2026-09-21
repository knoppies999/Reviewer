#Requires -Version 5.1
<#
.SYNOPSIS
    Computes the change set for a pull-request review: one diff per changed file, a full diff, and a manifest.

.DESCRIPTION
    Runs the same way on a developer machine and on an Azure DevOps agent, and never modifies the
    repository (the only network call is an optional `git fetch` of the base branch). It writes:

        <OutputDir>/manifest.json    what the pr-review agents work from
        <OutputDir>/full.diff        the whole change set, for the integration pass
        <OutputDir>/diffs/*.diff     one unified diff per changed file

    On an Azure DevOps pipeline the PR id, source and target branch come from the predefined
    variables, and the PR title and description are fetched with System.AccessToken when it is
    mapped into the environment as SYSTEM_ACCESSTOKEN.

.PARAMETER Base
    Base branch or ref (develop, origin/main, a SHA). When omitted: $env:SYSTEM_PULLREQUEST_TARGETBRANCH,
    then the first existing branch in config baseBranchCandidates, then origin/HEAD.
.PARAMETER Head
    Ref to review. Default: HEAD.
.PARAMETER IncludeWorkingTree
    Diff the working tree (staged, unstaged and untracked files) instead of the Head commit. Local use.
.PARAMETER OutputDir
    Default: $env:BUILD_ARTIFACTSTAGINGDIRECTORY/pr-review on a pipeline, otherwise <repo>/<config.reportDirName>.
.PARAMETER ConfigPath
    Default: ../config.json relative to this script.
.PARAMETER NoFetch
    Do not `git fetch` the base branch before resolving it.
.PARAMETER RepositoryPath
    Any path inside the repository. Default: the current directory.
.PARAMETER PullRequestId
    Optional PR id for local runs (on a pipeline it comes from the environment).
.PARAMETER Title
    Optional PR title override.
.PARAMETER Description
    Optional PR description override.
.EXAMPLE
    pwsh -NoProfile -File Get-PrDiff.ps1 -Base develop
.EXAMPLE
    pwsh -NoProfile -File Get-PrDiff.ps1 -IncludeWorkingTree -OutputDir C:\temp\review
.OUTPUTS
    The manifest path, as the last line of output.
#>
[CmdletBinding()]
param(
    [string]$Base,
    [string]$Head = 'HEAD',
    [switch]$IncludeWorkingTree,
    [string]$OutputDir,
    [string]$ConfigPath,
    [switch]$NoFetch,
    [string]$RepositoryPath,
    [string]$PullRequestId,
    [string]$Title,
    [string]$Description
)

$ErrorActionPreference = 'Stop'
$isPipeline = -not [string]::IsNullOrEmpty($env:TF_BUILD)
$script:RepoRoot = $null
$script:Config = $null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- helpers

function Write-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Git {
    # Runs git in the repository and returns ExitCode / Lines / Output. Throws on failure unless -AllowFailure.
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
    $gitArgs = @('-c', 'core.quotepath=false')
    if ($script:RepoRoot) { $gitArgs += @('-C', $script:RepoRoot) }
    $gitArgs += $Arguments
    $previousEap = $ErrorActionPreference
    $previousEncoding = [Console]::OutputEncoding
    try {
        # Windows PowerShell turns native stderr into terminating errors under 'Stop'; git writes progress there.
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $raw = & git @gitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $previousEncoding
        $ErrorActionPreference = $previousEap
    }
    $lines = @($raw | ForEach-Object { "$_" })
    $text = $lines -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with exit code $code`n$text"
    }
    return [pscustomobject]@{ ExitCode = $code; Lines = $lines; Output = $text }
}

function Get-ConfigValue {
    param([Parameter(Mandatory = $true)][string]$Name, $Default)
    if ($null -ne $script:Config -and $script:Config.PSObject.Properties[$Name]) { return $script:Config.$Name }
    return $Default
}

function ConvertTo-GlobRegex {
    # Minimal glob to regex: ** (any depth), * (within one path segment), ? (one character).
    # A pattern without a slash matches at any depth, like .gitignore.
    param([Parameter(Mandatory = $true)][string]$Glob)
    $g = $Glob.Replace('\', '/').TrimStart('/')
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('^')
    if ($g -notmatch '/') { [void]$sb.Append('(?:.*/)?') }
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*') {
            if (($i + 1) -lt $g.Length -and $g[$i + 1] -eq '*') {
                if (($i + 2) -lt $g.Length -and $g[$i + 2] -eq '/') { [void]$sb.Append('(?:.*/)?'); $i += 3; continue }
                [void]$sb.Append('.*'); $i += 2; continue
            }
            [void]$sb.Append('[^/]*'); $i++; continue
        }
        if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
        [void]$sb.Append([regex]::Escape([string]$c)); $i++
    }
    [void]$sb.Append('$')
    return $sb.ToString()
}

function Resolve-CommitRef {
    # Tries origin/<name>, then <name> as a local branch, then <name> as any ref or SHA.
    param([Parameter(Mandatory = $true)][string]$Name)
    $short = $Name -replace '^refs/heads/', '' -replace '^refs/remotes/', ''
    $remoteName = $short -replace '^origin/', ''
    foreach ($candidate in @("refs/remotes/origin/$remoteName", "refs/heads/$short", $Name)) {
        $r = Invoke-Git -Arguments @('rev-parse', '--verify', '--quiet', "$candidate^{commit}") -AllowFailure
        if ($r.ExitCode -eq 0 -and $r.Output.Trim()) {
            return [pscustomobject]@{ Ref = $candidate; Sha = $r.Output.Trim() }
        }
    }
    return $null
}

function Test-BinaryFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] 8000
            $read = $stream.Read($buffer, 0, $buffer.Length)
            for ($j = 0; $j -lt $read; $j++) { if ($buffer[$j] -eq 0) { return $true } }
            return $false
        }
        finally { $stream.Dispose() }
    }
    catch { return $false }
}

function Get-SafeFileName {
    param([Parameter(Mandatory = $true)][string]$Path)
    $name = $Path -replace '[\\/:*?"<>|\s]', '_'
    if ($name.Length -gt 120) { $name = $name.Substring($name.Length - 120) }
    return $name
}

function Get-ChecklistName {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ext = [System.IO.Path]::GetExtension($Path).TrimStart('.').ToLowerInvariant()
    $map = Get-ConfigValue -Name 'checklists' -Default $null
    if ($null -ne $map) {
        if ($ext -and $map.PSObject.Properties[$ext]) { return [string]$map.$ext }
        if ($map.PSObject.Properties['*']) { return [string]$map.'*' }
    }
    return 'general'
}

# ---------------------------------------------------------------- locate everything

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$skillRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) { $ConfigPath = Join-Path $skillRoot 'config.json' }
if (Test-Path -LiteralPath $ConfigPath) {
    $script:Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}
else {
    Write-Warning "Config not found at $ConfigPath; using built-in defaults."
}

if (-not $RepositoryPath) { $RepositoryPath = (Get-Location).Path }
$top = Invoke-Git -Arguments @('-C', $RepositoryPath, 'rev-parse', '--show-toplevel')
$script:RepoRoot = [System.IO.Path]::GetFullPath($top.Output.Trim())

if (-not $OutputDir) {
    if ($isPipeline -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
        $OutputDir = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'pr-review'
    }
    else {
        $OutputDir = Join-Path $script:RepoRoot ([string](Get-ConfigValue -Name 'reportDirName' -Default '.pr-review'))
    }
}
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
$diffDir = Join-Path $OutputDir 'diffs'
New-Item -ItemType Directory -Force -Path $diffDir | Out-Null
Get-ChildItem -LiteralPath $diffDir -Filter '*.diff' -File | Remove-Item -Force
# Remove outputs of a previous run so a stale report can never be mistaken for this one.
foreach ($stale in @('manifest.json', 'full.diff', 'file-results.jsonl', 'findings.json', 'report.md')) {
    $stalePath = Join-Path $OutputDir $stale
    if (Test-Path -LiteralPath $stalePath) { Remove-Item -LiteralPath $stalePath -Force }
}

$previousGitPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = '0'   # never hang on a credential prompt
try {

    # ------------------------------------------------------------ head

    $status = Invoke-Git -Arguments @('status', '--porcelain', '--untracked-files=normal') -AllowFailure
    $dirty = ($status.ExitCode -eq 0) -and (($status.Lines -join '').Trim().Length -gt 0)

    if ($IncludeWorkingTree) {
        $headSha = (Invoke-Git -Arguments @('rev-parse', 'HEAD')).Output.Trim()
        $headLabel = 'working tree'
        $headRefForName = 'HEAD'
    }
    else {
        $headSha = (Invoke-Git -Arguments @('rev-parse', '--verify', "$Head^{commit}")).Output.Trim()
        $headLabel = $Head
        $headRefForName = $Head
        if ($dirty -and -not $isPipeline) {
            Write-Warning 'The working tree has uncommitted changes; they are NOT part of this review. Use -IncludeWorkingTree to include them.'
        }
    }

    $headBranch = (Invoke-Git -Arguments @('rev-parse', '--abbrev-ref', $headRefForName) -AllowFailure).Output.Trim()
    if (-not $headBranch -or $headBranch -eq 'HEAD') {
        foreach ($envName in @('SYSTEM_PULLREQUEST_SOURCEBRANCH', 'BUILD_SOURCEBRANCH')) {
            $value = [Environment]::GetEnvironmentVariable($envName)
            if ($value) { $headBranch = $value -replace '^refs/heads/', ''; break }
        }
        if (-not $headBranch -or $headBranch -eq 'HEAD') { $headBranch = $headSha.Substring(0, 7) }
    }

    # ------------------------------------------------------------ base

    $baseCandidates = @()
    if ($Base) { $baseCandidates += $Base }
    elseif ($env:SYSTEM_PULLREQUEST_TARGETBRANCH) { $baseCandidates += $env:SYSTEM_PULLREQUEST_TARGETBRANCH }
    else { $baseCandidates += @(Get-ConfigValue -Name 'baseBranchCandidates' -Default @('develop', 'main', 'master')) }

    $hasOrigin = ((Invoke-Git -Arguments @('remote') -AllowFailure).Lines -contains 'origin')
    $resolvedBase = $null
    $tried = @()
    foreach ($candidate in $baseCandidates) {
        $short = $candidate -replace '^refs/heads/', '' -replace '^refs/remotes/origin/', '' -replace '^origin/', ''
        $looksLikeSha = ($short -match '^[0-9a-fA-F]{7,40}$')
        if ($hasOrigin -and -not $NoFetch -and -not $looksLikeSha) {
            $fetch = Invoke-Git -Arguments @('fetch', '--no-tags', '--quiet', 'origin', "+refs/heads/${short}:refs/remotes/origin/${short}") -AllowFailure
            if ($fetch.ExitCode -ne 0) { Write-Verbose "git fetch of '$short' failed (continuing with local refs): $($fetch.Output)" }
        }
        $tried += $candidate
        $resolvedBase = Resolve-CommitRef -Name $candidate
        if ($resolvedBase) { break }
    }
    if (-not $resolvedBase -and -not $Base) {
        $tried += 'origin/HEAD'
        $resolvedBase = Resolve-CommitRef -Name 'origin/HEAD'
    }
    if (-not $resolvedBase) {
        throw "Could not resolve a base branch (tried: $($tried -join ', ')). Pass -Base <branch>, or on a pipeline make sure the checkout uses fetchDepth: 0 so the target branch is available."
    }
    $baseName = $resolvedBase.Ref -replace '^refs/remotes/origin/', '' -replace '^refs/heads/', ''

    $mergeBaseResult = Invoke-Git -Arguments @('merge-base', $resolvedBase.Sha, $headSha) -AllowFailure
    if ($mergeBaseResult.ExitCode -ne 0 -or -not $mergeBaseResult.Output.Trim()) {
        throw "git merge-base failed for $($resolvedBase.Ref) and $headLabel. On a shallow clone use fetchDepth: 0 (Azure Pipelines) or run 'git fetch --unshallow'.`n$($mergeBaseResult.Output)"
    }
    $mergeBase = $mergeBaseResult.Output.Trim()

    $diffRange = @($mergeBase)
    if (-not $IncludeWorkingTree) { $diffRange += $headSha }

    # ------------------------------------------------------------ changed files

    $nameStatus = Invoke-Git -Arguments (@('diff', '--name-status', '-M', '--no-color') + $diffRange)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($line in $nameStatus.Lines) {
        if (-not $line.Trim()) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $statusChar = $parts[0].Substring(0, 1)
        switch ($statusChar) {
            'R' { $entries.Add([pscustomobject]@{ Path = $parts[2]; OldPath = $parts[1]; Status = 'renamed'; Untracked = $false }) }
            'C' { $entries.Add([pscustomobject]@{ Path = $parts[2]; OldPath = $parts[1]; Status = 'added'; Untracked = $false }) }
            'A' { $entries.Add([pscustomobject]@{ Path = $parts[1]; OldPath = $null; Status = 'added'; Untracked = $false }) }
            'D' { $entries.Add([pscustomobject]@{ Path = $parts[1]; OldPath = $null; Status = 'deleted'; Untracked = $false }) }
            'T' { $entries.Add([pscustomobject]@{ Path = $parts[1]; OldPath = $null; Status = 'type-changed'; Untracked = $false }) }
            default { $entries.Add([pscustomobject]@{ Path = $parts[1]; OldPath = $null; Status = 'modified'; Untracked = $false }) }
        }
    }
    if ($IncludeWorkingTree) {
        $untracked = Invoke-Git -Arguments @('ls-files', '--others', '--exclude-standard') -AllowFailure
        foreach ($u in $untracked.Lines) {
            if ($u.Trim()) { $entries.Add([pscustomobject]@{ Path = $u; OldPath = $null; Status = 'added'; Untracked = $true }) }
        }
    }

    $skipRules = @()
    foreach ($pattern in @(Get-ConfigValue -Name 'skipPatterns' -Default @())) {
        $skipRules += [pscustomobject]@{ Pattern = [string]$pattern; Regex = New-Object System.Text.RegularExpressions.Regex((ConvertTo-GlobRegex -Glob ([string]$pattern)), 'IgnoreCase') }
    }
    $maxDiffLines = [int](Get-ConfigValue -Name 'maxDiffLinesPerFile' -Default 1500)
    $reviewDeleted = [bool](Get-ConfigValue -Name 'reviewDeletedFiles' -Default $false)
    $outputDirRelative = $OutputDir.Replace('\', '/')

    $files = New-Object System.Collections.Generic.List[object]
    $untrackedDiffs = New-Object System.Collections.Generic.List[string]
    $index = 0
    foreach ($entry in $entries) {
        $index++
        $relPath = $entry.Path.Replace('\', '/')
        $oldPath = $null
        if ($entry.OldPath) { $oldPath = $entry.OldPath.Replace('\', '/') }
        $additions = 0
        $deletions = 0
        $binary = $false
        $diffFile = Join-Path $diffDir ('{0:000}-{1}.diff' -f $index, (Get-SafeFileName -Path $relPath))

        if ($entry.Untracked) {
            $full = Join-Path $script:RepoRoot $relPath
            $binary = Test-BinaryFile -Path $full
            if ($binary) {
                $text = "diff --git a/$relPath b/$relPath`nnew file mode 100644`nBinary files /dev/null and b/$relPath differ`n"
            }
            else {
                $content = [System.IO.File]::ReadAllText($full)
                $lines = @($content -split "`r?`n")
                if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines = @($lines | Select-Object -First ($lines.Count - 1)) }
                $additions = $lines.Count
                $body = ($lines | ForEach-Object { "+$_" }) -join "`n"
                $text = "diff --git a/$relPath b/$relPath`nnew file mode 100644`n--- /dev/null`n+++ b/$relPath`n@@ -0,0 +1,$additions @@`n$body`n"
            }
            Write-Utf8File -Path $diffFile -Content $text
            $untrackedDiffs.Add($text)
        }
        else {
            $pathArgs = @('--', $relPath)
            if ($oldPath) { $pathArgs += $oldPath }
            $num = Invoke-Git -Arguments (@('diff', '--numstat', '-M', '--no-color') + $diffRange + $pathArgs) -AllowFailure
            $numLine = $num.Lines | Where-Object { $_ -match "`t" } | Select-Object -First 1
            if ($numLine) {
                $np = $numLine -split "`t"
                if ($np[0] -eq '-' -or $np[1] -eq '-') { $binary = $true }
                else { $additions = [int]$np[0]; $deletions = [int]$np[1] }
            }
            $diffOut = Invoke-Git -Arguments (@('diff', '-M', '--no-color', "--output=$diffFile") + $diffRange + $pathArgs) -AllowFailure
            if ($diffOut.ExitCode -ne 0) { Write-Warning "git diff failed for $relPath : $($diffOut.Output)" }
        }

        $newFileLines = 0
        if ($entry.Status -ne 'deleted' -and -not $binary) {
            if ($IncludeWorkingTree) {
                $full = Join-Path $script:RepoRoot $relPath
                if (Test-Path -LiteralPath $full) { $newFileLines = @([System.IO.File]::ReadAllLines($full)).Count }
            }
            else {
                $show = Invoke-Git -Arguments @('show', "${headSha}:${relPath}") -AllowFailure
                if ($show.ExitCode -eq 0) { $newFileLines = $show.Lines.Count }
            }
        }

        $skipReason = $null
        foreach ($rule in $skipRules) {
            if ($rule.Regex.IsMatch($relPath)) { $skipReason = "matches skip pattern $($rule.Pattern)"; break }
        }
        if (-not $skipReason -and $relPath.StartsWith($outputDirRelative.Substring([Math]::Min($outputDirRelative.Length, $script:RepoRoot.Length + 1)), [System.StringComparison]::OrdinalIgnoreCase) -and $OutputDir.StartsWith($script:RepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $skipReason = 'review output directory'
        }
        if (-not $skipReason -and $binary) { $skipReason = 'binary file' }

        $reviewMode = 'review'
        if ($skipReason) { $reviewMode = 'skip' }
        elseif ($entry.Status -eq 'deleted') {
            if (-not $reviewDeleted) { $reviewMode = 'deleted'; $skipReason = 'deleted file (the integration pass checks for remaining references)' }
        }
        elseif (($additions + $deletions) -eq 0) {
            $reviewMode = 'skip'
            if ($entry.Status -eq 'renamed') { $skipReason = 'renamed without content changes (the integration pass checks references)' }
            else { $skipReason = 'no textual change (mode change only)' }
        }

        $checklist = Get-ChecklistName -Path $relPath
        $files.Add([ordered]@{
                path         = $relPath
                oldPath      = $oldPath
                status       = $entry.Status
                additions    = $additions
                deletions    = $deletions
                binary       = $binary
                extension    = [System.IO.Path]::GetExtension($relPath).TrimStart('.').ToLowerInvariant()
                language     = $checklist
                checklist    = $checklist
                diffFile     = $diffFile
                newFileLines = $newFileLines
                large        = (($additions + $deletions) -gt $maxDiffLines)
                reviewMode   = $reviewMode
                skipReason   = $skipReason
            })
    }

    # ------------------------------------------------------------ full diff, commits, PR metadata

    $fullDiff = Join-Path $OutputDir 'full.diff'
    $fd = Invoke-Git -Arguments (@('diff', '-M', '--no-color', "--output=$fullDiff") + $diffRange) -AllowFailure
    if ($fd.ExitCode -ne 0) { Write-Warning "full diff failed: $($fd.Output)" }
    if (-not (Test-Path -LiteralPath $fullDiff)) { Write-Utf8File -Path $fullDiff -Content '' }
    if ($untrackedDiffs.Count -gt 0) {
        [System.IO.File]::AppendAllText($fullDiff, ($untrackedDiffs -join ''), $utf8NoBom)
    }

    $logRange = "$mergeBase..$headSha"
    $log = Invoke-Git -Arguments @('log', '--no-color', '--no-merges', '-n', '50', '--format=%h%x1f%an%x1f%s', $logRange) -AllowFailure
    $commits = @()
    foreach ($l in $log.Lines) {
        if (-not $l) { continue }
        $p = $l -split [string][char]0x1f
        if ($p.Count -ge 3) { $commits += [ordered]@{ sha = $p[0]; author = $p[1]; subject = $p[2] } }
    }

    $pr = [ordered]@{
        id           = $null
        title        = $null
        description  = $null
        author       = $null
        repository   = $null
        sourceBranch = $headBranch
        targetBranch = $baseName
        url          = $null
    }
    if ($PullRequestId) { $pr.id = $PullRequestId } elseif ($env:SYSTEM_PULLREQUEST_PULLREQUESTID) { $pr.id = $env:SYSTEM_PULLREQUEST_PULLREQUESTID }
    if ($env:BUILD_REPOSITORY_NAME) { $pr.repository = $env:BUILD_REPOSITORY_NAME } else { $pr.repository = Split-Path -Leaf $script:RepoRoot }
    if ($env:SYSTEM_PULLREQUEST_SOURCEBRANCH) { $pr.sourceBranch = $env:SYSTEM_PULLREQUEST_SOURCEBRANCH -replace '^refs/heads/', '' }

    $collection = $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI
    $project = $env:SYSTEM_TEAMPROJECT
    $repoId = $env:BUILD_REPOSITORY_ID
    if ($pr.id -and $collection -and $project -and $env:BUILD_REPOSITORY_NAME) {
        $pr.url = "$($collection.TrimEnd('/'))/$([uri]::EscapeDataString($project))/_git/$([uri]::EscapeDataString($env:BUILD_REPOSITORY_NAME))/pullrequest/$($pr.id)"
    }
    if ($pr.id -and $collection -and $project -and $repoId -and $env:SYSTEM_ACCESSTOKEN) {
        try {
            $uri = "$($collection.TrimEnd('/'))/$([uri]::EscapeDataString($project))/_apis/git/repositories/$repoId/pullRequests/$($pr.id)?api-version=7.1"
            $resp = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" }
            if ($resp.title) { $pr.title = [string]$resp.title }
            if ($resp.description) { $pr.description = [string]$resp.description }
            if ($resp.createdBy -and $resp.createdBy.displayName) { $pr.author = [string]$resp.createdBy.displayName }
        }
        catch {
            Write-Warning "Could not fetch pull request metadata from Azure DevOps: $($_.Exception.Message)"
        }
    }
    if ($Title) { $pr.title = $Title }
    if ($Description) { $pr.description = $Description }
    if (-not $pr.title) {
        if ($commits.Count -gt 0) { $pr.title = $commits[0].subject } else { $pr.title = "$headBranch vs $baseName" }
    }

    # ------------------------------------------------------------ manifest

    $toReview = @($files | Where-Object { $_.reviewMode -eq 'review' }).Count
    $skipped = @($files | Where-Object { $_.reviewMode -eq 'skip' }).Count
    $deleted = @($files | Where-Object { $_.reviewMode -eq 'deleted' }).Count
    $sumAdd = 0; $sumDel = 0
    foreach ($f in $files) { $sumAdd += $f.additions; $sumDel += $f.deletions }

    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToUniversalTime().ToString('o')
        mode          = $(if ($isPipeline) { 'pipeline' } else { 'local' })
        repoRoot      = $script:RepoRoot
        skillRoot     = $skillRoot
        outputDir     = $OutputDir
        fullDiff      = $fullDiff
        base          = [ordered]@{ ref = $resolvedBase.Ref; name = $baseName; sha = $resolvedBase.Sha }
        head          = [ordered]@{ ref = $headLabel; name = $headBranch; sha = $headSha; includesWorkingTree = [bool]$IncludeWorkingTree }
        mergeBase     = $mergeBase
        pr            = $pr
        commits       = @($commits)
        files         = @($files.ToArray())
        summary       = [ordered]@{
            filesChanged  = $files.Count
            filesToReview = $toReview
            filesSkipped  = $skipped
            filesDeleted  = $deleted
            additions     = $sumAdd
            deletions     = $sumDel
        }
        config        = [ordered]@{
            maxParallelSubagents = [int](Get-ConfigValue -Name 'maxParallelSubagents' -Default 4)
            filesPerSubagent     = [int](Get-ConfigValue -Name 'filesPerSubagent' -Default 1)
            minConfidence        = [double](Get-ConfigValue -Name 'minConfidence' -Default 0.6)
            conventions          = @(Get-ConfigValue -Name 'conventions' -Default @())
            verifyCommands       = @(Get-ConfigValue -Name 'verifyCommands' -Default @())
            gate                 = [string](Get-ConfigValue -Name 'gate' -Default 'blocking')
        }
    }
    $manifestPath = Join-Path $OutputDir 'manifest.json'
    Write-Utf8File -Path $manifestPath -Content ($manifest | ConvertTo-Json -Depth 8)

    Write-Host ''
    Write-Host 'PR review change set'
    Write-Host "  Base:       $($resolvedBase.Ref) ($($resolvedBase.Sha.Substring(0, 7)))"
    Write-Host "  Head:       $headLabel ($($headSha.Substring(0, 7)))"
    Write-Host "  Merge base: $($mergeBase.Substring(0, 7))"
    Write-Host "  Files:      $($files.Count) changed, $toReview to review, $skipped skipped, $deleted deleted (+$sumAdd / -$sumDel)"
    Write-Host "  Manifest:   $manifestPath"
    if ($isPipeline) {
        Write-Host "##vso[task.setvariable variable=PrReviewManifest]$manifestPath"
        Write-Host "##vso[task.setvariable variable=PrReviewOutputDir]$OutputDir"
    }
    Write-Output $manifestPath
}
finally {
    if ($null -eq $previousGitPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $previousGitPrompt }
}
