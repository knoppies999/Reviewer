# Usage

Four ways to run a review. They all produce the same two files, `report.md` and `findings.json`, in the same output directory.

| Way | When | Orchestrated by |
|---|---|---|
| [VS Code Copilot Chat](#vs-code-copilot-chat) | You are already in the editor | the assistant |
| [Claude Code](#claude-code) | Terminal or desktop session | the assistant |
| [Copilot CLI](#github-copilot-cli) | Terminal session | the assistant |
| [The driver](#the-driver-unattended) | Pipelines, scripts, cron, large pull requests | `Invoke-PrReview.ps1` |

The first three are conversational: you can interrupt, ask follow-up questions and re-run one file. The driver is deterministic and unattended, and does not rely on a model to orchestrate anything. For a pipeline, use the driver.

---

## VS Code Copilot Chat

Requires the GitHub Copilot Chat extension with agent mode, and subagents enabled (the default in current releases).

1. Open Copilot Chat.
2. Either pick **pr-review** from the agent dropdown, or stay in the default agent and type `/pr-review`. Both work: the skill instructs whichever agent is running to delegate the same way.
3. Say what to review.

```
review the current branch against develop
review PR 1234
review feature/payment-retries against main, include my uncommitted changes
just review the C# files in this branch
```

With the Azure DevOps MCP server configured, a pull request number is enough: the agent fetches the title, description and branches. Without it, the agent asks which branch to use.

The first run asks permission to run `pwsh` and `git`. Approve them, or pre-approve in your settings:

```jsonc
// .vscode/settings.json
{
  "chat.tools.terminal.autoApprove": {
    "git status": true,
    "git diff": true,
    "git merge-base": true,
    "pwsh -NoProfile -File .claude/skills/pr-review/scripts/Get-PrDiff.ps1": true,
    "pwsh -NoProfile -File .claude/skills/pr-review/scripts/Merge-ReviewResults.ps1": true
  }
}
```

The report is printed in chat and written to `.pr-review/`.

---

## Claude Code

```
/pr-review review the current branch against develop
```

The skill runs in the main session and spawns the `pr-file-reviewer` and `pr-integration-reviewer` subagents from `.claude/agents/`. Because per-file reviews are the bulk of the cost, set `model:` in `.claude/agents/pr-file-reviewer.md` to route them to a cheaper model while the contracts and verification passes keep the strong one:

```yaml
---
name: pr-file-reviewer
model: haiku
---
```

---

## GitHub Copilot CLI

Interactive, from the repository root:

```bash
copilot
/agent                    # pick pr-review
/pr-review review the current branch against develop
```

Non-interactive, one session doing the whole review:

```bash
copilot --agent=pr-review \
  -p "/pr-review review the current branch against develop" \
  -s --no-ask-user --allow-all-tools \
  "--deny-tool=shell(git push)" "--deny-tool=shell(git commit)"
```

`--allow-all-tools` is required in `-p` mode. Deny rules still take precedence over it, which is how the review stays read-only. For anything unattended, prefer the driver below: it gives the same permissions per call and does not depend on the model to keep track of thirty files.

---

## The driver (unattended)

`Invoke-PrReview.ps1` runs the entire review by launching your assistant's CLI per unit of work: one call per changed file (tiny ones share a call), one for the contracts pass and one for the verification pass.

```powershell
# Claude Code, current branch against develop
pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 -Harness claude -Base develop

# Copilot CLI, twelve calls at a time, specific model
pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 `
  -Harness copilot -Base develop -MaxParallel 12 -Model claude-sonnet-5

# A fast model for the files, the strong one for the cross-file passes
pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 `
  -Harness claude -Base develop -FileReviewModel claude-sonnet-5 -IntegrationModel claude-opus-5
```

It prints a line per call as it starts and finishes, and writes `driver-run.json` next to the report with the timings, how many calls the batching saved and how many answers came from the cache. That file is the place to look when a review took longer than you expected.

### Options

| Option | Default | Meaning |
|---|---|---|
| `-Harness` | required | A key under `harnesses` in `config.json`: `copilot` or `claude` out of the box. |
| `-Base` | config candidates | Base branch or ref. Falls back to `develop`, `main`, `master`, then `origin/HEAD`. |
| `-Head` | `HEAD` | Ref to review. |
| `-IncludeWorkingTree` | off | Review uncommitted changes, including untracked files, instead of the head commit. |
| `-RepositoryPath` | current directory | Any path inside the repository. |
| `-OutputDir` | `.pr-review` | Where the review is written. |
| `-ManifestPath` | | Reuse an already computed change set and skip `Get-PrDiff.ps1`. |
| `-Model` | harness default | Model id passed to the CLI, for every call. |
| `-FileReviewModel` | `-Model` | Model for the per-file reviews only. |
| `-IntegrationModel` | `-Model` | Model for the contracts and verification passes only. |
| `-MaxParallel` | 8 | Concurrent calls. The contracts pass takes one of these slots while it runs. |
| `-TimeoutMinutes` | 20 | Per call. The contracts and verification passes get double. |
| `-MaxRetries` | 1 | Retries after a failed or unparsable response. |
| `-NoCache` | off | Ignore `.pr-review-cache` and write nothing to it. |
| `-SkipIntegration` | off | Skip the contracts and verification passes. Findings stay unverified. |
| `-ExtraArgs` | | Extra arguments appended to every CLI call. |
| `-CI` | auto | Adds the harness's CI arguments. Inferred from `TF_BUILD` or `CI=true`. |
| `-DryRun` | off | Write the prompts and print the exact commands. Calls nothing. |

### What it leaves behind

```
.pr-review/
├── manifest.json          the change set
├── full.diff              the whole diff, for the integration pass
├── diffs/*.diff           one per changed file
├── prompts/*.md           exactly what each subagent was asked
├── responses/*.txt        exactly what each one replied
├── file-results.jsonl     one parsed result per line
├── integration-result.json
├── driver-run.json        attempts, timings, token-free run log
├── findings.json          machine-readable result
└── report.md              human-readable result
```

`prompts/` and `responses/` are the first place to look when a review disappoints. They show precisely what the model saw and said.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | The review completed. Findings may still exist; use the gate to decide pass or fail. |
| 2 | The merge step failed. |
| 3 | Every per-file review failed. Usually authentication. |

A non-zero exit does not mean the code is bad, only that the run had a problem. Pass or fail is [`Test-ReviewGate.ps1`](../.claude/skills/pr-review/scripts/Test-ReviewGate.ps1), described in [azure-pipelines.md](azure-pipelines.md#the-gate).

---

## Reviewing something other than the current branch

```powershell
# A specific branch against a specific base
pwsh -File ... /Invoke-PrReview.ps1 -Harness claude -Base main -Head feature/x

# Work in progress, including untracked files
pwsh -File ... /Invoke-PrReview.ps1 -Harness claude -Base develop -IncludeWorkingTree

# A range you already know
pwsh -File ... /Get-PrDiff.ps1 -Base a1b2c3d -Head e4f5a6b
pwsh -File ... /Invoke-PrReview.ps1 -Harness claude -ManifestPath .pr-review/manifest.json
```

Uncommitted changes are **never** included unless you ask. A commit-mode run warns when the working tree is dirty so a stale review is never mistaken for a current one.

---

## Posting to an Azure DevOps pull request by hand

The pipeline does this for you. To do it from your machine, use a personal access token with *Code (read & write)*:

```powershell
pwsh -File .claude/skills/pr-review/scripts/Publish-AdoPrComment.ps1 `
  -OrganizationUrl https://dev.azure.com/<org> `
  -Project <project> -Repository <repo> -PullRequestId <id> `
  -Token <pat>
```

Add `-InlineComments` to also open one thread per blocking finding, anchored to its line. Add `-WhatIf` to see exactly what would be posted without posting it. Re-running edits the previous comment instead of stacking a new one, because the summary carries a hidden marker.

---

## Reading the report

**Verdict** is the headline. `Request changes` means at least one blocking finding survived verification. `Approve with comments` means only should-fix findings remain. `Incomplete` means nothing could be reviewed, which is a failure of the tooling, not a judgement about the code.

**Verification** on each finding is the most useful column. `confirmed` means the integration pass looked at the surrounding code and agreed. `refuted` findings are moved out of the report into a collapsed appendix with the reason. `unverified` means nobody could settle it and a human should look.

**Confidence** is the reviewer's own estimate that a competent reviewer with full context would agree. It is independent of severity: a blocking finding at 0.6 means "if I am right, this must not ship". Findings below `minConfidence` are dropped before the report is written.

**Also reported as** under a finding lists the same defect reported from another place, typically where a bad value enters and where it does damage. Look at both locations, but count it once. The counts and the gate already do.

**Coverage** lists every file as reviewed, skipped with a reason, deleted, or failed. If a file you care about is missing from the review, this is where it says why.

The vocabulary is defined in [severity-guide.md](../.claude/skills/pr-review/references/severity-guide.md).
