---
name: pr-review
description: Multi-agent pull request review for Azure DevOps repositories, tuned for C#/.NET and TypeScript with basic coverage of other languages. Use this whenever the user wants a PR, branch, or diff reviewed before merge, asks for a code review of their changes, wants to know what is risky in a change set, or wants the review to run from a pipeline. It computes the change set with a script, reviews each changed file in a fresh subagent, runs an integration and verification pass, merges the results with a script and prints report.md. Works in Claude Code, VS Code Copilot and the Copilot CLI.
argument-hint: "[PR id or branch] [base branch]"
---

# PR review workflow

You are coordinating a review, not performing it. No single context should ever hold the whole PR: a script computes the change set, each file is read by a fresh subagent, one subagent looks at how the pieces fit and double-checks the serious findings, and a script merges the results into a report. Keep your own context for coordination.

**Where things live.** This folder (`.claude/skills/pr-review`, or `~/.claude/skills/pr-review` and `~/.copilot/skills/pr-review` for user-level installs) is the single source of truth and is read by Claude Code, VS Code Copilot and the Copilot CLI. The agent definitions in `.github/agents` (Copilot) and `.claude/agents` (Claude Code) are thin wrappers that pin tools and models. Everything a subagent needs is in the prompt you build from the templates here, so the review also works with a harness that only has a generic subagent tool.

**Unattended runs** (pipelines, scripts) do not follow this interactive workflow: they run [scripts/Invoke-PrReview.ps1](./scripts/Invoke-PrReview.ps1), which performs every step below with one CLI process per unit of work and no reliance on the model orchestrating anything.

## 0. Orient

1. **Find the skill root**: the directory containing this file. Pass absolute paths to subagents.
2. **Read [config.json](./config.json).** It holds the base branch candidates, skip patterns, parallelism, confidence threshold, gate, conventions and verify commands. Use its values; do not hardcode your own.
3. **Work out the mode.**
   - **Pipeline**: the `TF_BUILD` environment variable is set, or the prompt says "pipeline mode". Never ask questions; use the output directory and manifest given in the prompt; finish by producing the files. The pipeline posts the comment and applies the gate.
   - **Local**: a chat session. Use whatever PR id, branch or base the user gave. If the base is unknown and the config candidates do not resolve, ask once (interactive) or fall back to `origin/HEAD` (non-interactive).
4. **Work out the target.** A PR id means that PR's source branch against its target (if an Azure DevOps MCP server is available, fetch the PR to get both plus the title and description; otherwise ask for the branch). A branch name means that branch against the base. Nothing means the current `HEAD` against the base. Uncommitted changes are included only when the user asks (`-IncludeWorkingTree`).

## 1. Compute the change set (the script does this, not you)

If the prompt already names an existing `manifest.json`, use it and skip to step 2. Otherwise run [scripts/Get-PrDiff.ps1](./scripts/Get-PrDiff.ps1) with `pwsh` (or `powershell` on Windows if `pwsh` is missing):

```
pwsh -NoProfile -File "<skillRoot>/scripts/Get-PrDiff.ps1" -Base <base> [-Head <ref>] [-IncludeWorkingTree] [-OutputDir <dir>] [-PullRequestId <id>] [-Title "<title>"]
```

It resolves the base and merge base, writes one diff per changed file under `<out>/diffs/`, a `full.diff`, and `manifest.json`, then prints the manifest path. **Read only `manifest.json`.** Do not read the diffs or the changed files yourself; that is what the subagents are for.

If the script fails, fix the cause when it is environmental (wrong base name; base not fetched: run `git fetch origin <base>` and retry once) and otherwise stop and report the error verbatim. Do not fall back to reviewing raw `git diff` output in your own context.

The manifest gives you, per file: `path`, `oldPath`, `status`, `additions`, `deletions`, `binary`, `language`, `checklist`, `diffFile`, `newFileLines`, `large`, `reviewMode` (`review`, `skip`, `deleted`) and `skipReason`. It also carries `pr` (id, title, description, source/target branch, url), `commits`, `base`, `head`, `mergeBase`, `repoRoot`, `skillRoot`, `outputDir`, `fullDiff` and `config` (the values in effect).

## 2. Plan

- Files with `reviewMode: review` get a subagent each (`filesPerSubagent` in the config lets you batch tiny files; default 1).
- Order by risk so the important results land first if anything is cut short: production code before tests, larger diffs before smaller, `.cs`/`.ts` before config and docs.
- Group into waves of `maxParallelSubagents`.
- Write a PR summary once (2 to 4 lines from title, description and commit subjects). Every subagent prompt includes it.
- Create `<out>/file-results.jsonl` now (empty). You append each subagent's result to it as it arrives, so nothing is lost if this conversation gets compacted.

## 3. Per-file reviews (subagents)

Build each prompt from [references/prompt-file-review.md](./references/prompt-file-review.md): replace every `{{placeholder}}` from the manifest and config, and set `{{instructions}}` to the **full contents** of [references/file-reviewer.md](./references/file-reviewer.md). `{{checklists}}` is the general checklist path plus the language one when `checklist` is not `general`; `{{largeNote}}` is empty or `; LARGE diff: focus on the hunks and their surroundings`; `{{status}}` is the status, with `renamed from <oldPath>` for renames.

Spawn it with your harness's mechanism, passing the filled prompt verbatim:

- **Copilot (VS Code or CLI)**: the `pr-file-reviewer` custom agent through the `agent` / `runSubagent` tool.
- **Claude Code**: the `Agent` tool with `subagent_type: pr-file-reviewer`; if that agent is not available, `general-purpose` works because the prompt is self-contained.
- **Any other harness**: its generic subagent or task tool.

Run a wave's subagents in parallel when the environment allows it, otherwise one after another. Never skip a file because it is slow, and never review it yourself instead.

When a result comes back: check that it is a single JSON object with `file` and `findings`, set `file` to the manifest path if the reviewer changed it, and append it as one line to `file-results.jsonl`. If a subagent returns no JSON, errors out, or reviewed the wrong file, retry once with the same prompt; if it fails again, append `{ "file": "<path>", "error": "<what happened>" }` and move on. Do not paraphrase findings; keep them as returned.

## 4. Integration and verification (one subagent)

After all waves, assign ids to the per-file findings with the fixed rule from [references/report-format.md](./references/report-format.md): walk the manifest files in order, and each file's findings in order, numbering `F1`, `F2`, … Collect every finding with severity `blocking` or `should-fix` as `{ id, file, line, severity, category, title, detail }`.

Build the prompt from [references/prompt-integration.md](./references/prompt-integration.md) with `{{instructions}}` set to the full contents of [references/integration-reviewer.md](./references/integration-reviewer.md), `{{fileList}}` as one line per manifest file (status, +/-, and whether it was reviewed, skipped with reason, deleted, or failed), `{{summaries}}` and `{{notes}}` from the results, `{{findingsToVerify}}` as the JSON array, and `{{verifyCommands}}` from the config (or `none`). Spawn the **`pr-integration-reviewer`** agent the same way as above (Claude Code: `subagent_type: pr-integration-reviewer`).

Save the returned JSON object verbatim to `<out>/integration-result.json`. If the pass fails twice, do not create the file; the merge marks everything unverified and says so.

## 5. Merge (the script does this, not you)

Run [scripts/Merge-ReviewResults.ps1](./scripts/Merge-ReviewResults.ps1):

```
pwsh -NoProfile -File "<skillRoot>/scripts/Merge-ReviewResults.ps1" -OutputDir "<out>"
```

It applies the confidence threshold and the verifications, merges duplicates, decides the verdict, and writes `findings.json` and `report.md`. If it reports a problem, fix the input (usually a malformed line in `file-results.jsonl`) and run it again. Do not hand-write `findings.json` or `report.md` while the script can run.

## 6. Deliver

- **Local**: print `report.md` verbatim in the chat, then the two file paths. Mention [scripts/Publish-AdoPrComment.ps1](./scripts/Publish-AdoPrComment.ps1) only if the user asks about posting to the PR.
- **Pipeline**: your final message is the verdict line, the counts, and the two file paths. The pipeline posts the comment, publishes the artifact and applies the gate with [scripts/Test-ReviewGate.ps1](./scripts/Test-ReviewGate.ps1).

## Failure handling

| Situation | Do |
|---|---|
| No changed files, or every file skipped | Run the merge anyway (it writes an `approve` report listing skipped files) and stop. |
| More files than fit in one session | Keep going in waves; `file-results.jsonl` is your checkpoint. Never sample a subset. |
| A subagent asks a question | Answer it from the manifest and PR summary in a retry prompt. Never forward it to the user in pipeline mode. |
| The subagent tool is unavailable | Stop and tell the user the subagent tool must be enabled. Do not review inline. Suggest the driver script for unattended runs. |
| Verify command fails | It is a finding from the integration pass, with the output excerpt. Do not try to fix the build. |

## Configuration

All knobs live in [config.json](./config.json):

| Key | Meaning | Default |
|---|---|---|
| `baseBranchCandidates` | Base branches tried in order when none is given | `develop`, `main`, `master` |
| `reportDirName` | Output directory under the repo root for local runs | `.pr-review` |
| `maxParallelSubagents` | Subagents per wave (and the driver's parallelism) | 4 |
| `filesPerSubagent` | Files per per-file subagent (1 = one file each) | 1 |
| `maxDiffLinesPerFile` | Above this the file is marked `large` (still reviewed) | 1500 |
| `minConfidence` | Findings below this are dropped by the merge | 0.6 |
| `reviewDeletedFiles` | Give deleted files their own subagent | false |
| `gate` | Pipeline gate: `blocking`, `security` or `none` | `blocking` |
| `failOnMissingReport` | Gate fails when no `findings.json` was produced | true |
| `failOnIncomplete` | Gate fails when any reviewable file could not be reviewed | true |
| `postInlineComments` / `inlineCommentSeverities` | Also post per-finding inline PR threads | false / `blocking` |
| `verifyCommands` | Commands the integration pass runs (build, type-check, tests) | none |
| `conventions` | Repo conventions passed to every reviewer | none |
| `skipPatterns` | Globs never reviewed (lock files, generated code, binaries) | see file |
| `checklists` | File extension to checklist mapping; `*` is the fallback | cs/ts/… |
| `harnesses` | Command templates the driver uses per harness (`copilot`, `claude`) | see file |

## Adjusting the review

- Per-file review behaviour: [references/file-reviewer.md](./references/file-reviewer.md). Models and tool limits per harness: `.github/agents/pr-file-reviewer.agent.md`, `.claude/agents/pr-file-reviewer.md`, and the `harnesses` entries.
- Integration and verification pass: [references/integration-reviewer.md](./references/integration-reviewer.md) and the matching agent wrappers.
- Prompt shape: `references/prompt-file-review.md` and `references/prompt-integration.md`.
- Language checklists: `references/checklist-*.md`. Add a language by adding a file and mapping its extensions in `config.json`.
- Severity, categories and confidence: [references/severity-guide.md](./references/severity-guide.md).
