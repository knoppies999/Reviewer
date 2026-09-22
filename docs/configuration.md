# Configuration

Everything tunable lives in [`.claude/skills/pr-review/config.json`](../.claude/skills/pr-review/config.json). The scripts and the agents both read it, so one edit changes every way of running the review.

## Change set

| Key | Default | Meaning |
|---|---|---|
| `baseBranchCandidates` | `["develop","main","master"]` | Tried in order when no base is given. First one that resolves wins. On a pipeline the pull request target branch takes precedence. |
| `reportDirName` | `".pr-review"` | Output directory under the repository root for local runs. On a pipeline the artifact staging directory is used instead. |
| `skipPatterns` | lock files, generated code, binaries, build output | Globs that are never sent to a reviewer. `**` matches any depth, `*` stays within a path segment, and a pattern without a slash matches at any depth like `.gitignore`. |
| `maxDiffLinesPerFile` | 1500 | Above this the file is marked `large`. It is still reviewed; the reviewer is told to focus on the hunks and their surroundings. |
| `reviewDeletedFiles` | `false` | Give deleted files their own subagent. Usually unnecessary: the contracts pass checks for leftover references. |

Add to `skipPatterns` whenever a review wastes calls on noise. Check `skipReason` in `manifest.json` to see which pattern matched a file.

## Review behaviour

| Key | Default | Meaning |
|---|---|---|
| `maxParallelSubagents` | 8 | Subagents per wave in chat, and the driver's default parallelism. Raise it if your account tolerates the concurrency; lower it if you see rate limiting, which costs more in retries than the parallelism wins. |
| `minConfidence` | 0.6 | Findings below this are dropped by the merge. Raise to 0.75 for a quieter review, lower to 0.5 to see more speculation. |
| `conventions` | `[]` | Short house rules handed to every reviewer. |
| `verifyCommands` | `[]` | Build, type-check or test commands the contracts pass runs. |

`conventions` is the highest-leverage setting in the file. It is the difference between a generic review and one that knows your codebase:

```json
"conventions": [
  "All public API endpoints require an authorization policy, never role checks in the handler",
  "Money is always decimal in C# and minor units as integers in TypeScript",
  "Every repository method takes a CancellationToken and passes it through",
  "No new usage of the legacy Sync* helpers in src/Legacy"
]
```

`verifyCommands` turns the contracts pass from opinion into evidence. A failing command becomes a finding with the output excerpt:

```json
"verifyCommands": ["dotnet build --no-restore", "npx tsc --noEmit"]
```

Keep them fast and side-effect free. Never put anything there that writes to a shared database, publishes a package or pushes to a remote.

## Speed

A review's wall clock is the number of calls on the critical path multiplied by how long each one takes. These settings attack both. The defaults are the fast ones; every entry here is something to turn *down* if you would rather have the old behaviour.

| Key | Default | Meaning |
|---|---|---|
| `inlineDiff` | `true` | Put the unified diff in the prompt instead of its path. |
| `inlineFileContent` | `true` | Put the current file, with line numbers, in the prompt. |
| `inlineFileContentMaxLines` | 1200 | Longest file to inline. Above it the reviewer is told to read the file itself. |
| `inlineChecklists` | `true` | Put the checklists in the prompt instead of their paths. |
| `batchSmallFiles` | `true` | Let files with tiny diffs share one subagent. |
| `smallFileDiffLines` | 25 | A file may be batched only at or below this many changed lines. |
| `batchMaxFileLines` | 250 | …and only when the whole file is this short. A small change in a large file still gets its own reviewer. |
| `filesPerSubagent` | 4 | Most files in one batched subagent. |
| `batchDiffLineBudget` | 150 | Most changed lines in one batched subagent. |
| `concurrentContractsPass` | `true` | Run the contracts pass alongside the per-file reviews instead of after them. |
| `cacheResults` | `true` | Reuse the answer to an identical prompt from a previous run. |
| `cacheDirName` | `".pr-review-cache"` | Where that cache lives, under the repository root. Add it to `.gitignore`. |
| `cacheMaxAgeDays` | 30 | Cache entries older than this are deleted at the start of a run. |
| `fileReviewModel` | `""` | Model for the per-file reviews, overriding `-Model`. |
| `integrationModel` | `""` | Model for the contracts and verification passes, overriding `-Model`. |

**Inlining** is the one with no trade-off. A CLI reviewer used to open its prompt, the diff, two checklists and the source file before it could think, and each of those is a full model round trip that resends everything before it. All of that text is on disk already, so the driver pastes it in and the reviewer answers from the first turn. This only applies to the driver: in a chat session the orchestrator leaves the paths alone, because reading a file to paste it into a prompt would pull the whole pull request through the one context this design keeps empty.

**Batching** is the one that does trade something. Two small files in one context is not the same as two contexts, so the thresholds are deliberately mean: a file qualifies only when both its diff and the file around it are small. Anything that looks like real work gets a reviewer to itself. Set `batchSmallFiles` to `false` for the strict one-file-per-subagent rule.

**The concurrent contracts pass** splits the old whole-PR pass in two. Contracts and wiring need only the diff, so that half starts with the first file review rather than after the last one; only verification, which needs the findings, waits. On a large pull request this takes the longest single call off the critical path entirely.

**The cache** is keyed on the exact prompt, so it invalidates itself when a file, the instructions or the model change. It earns its keep when you re-run a review after fixing two files out of thirty. A pipeline agent starts with an empty cache, so this is a local convenience; pass `-NoCache` to ignore it.

**Model tiering** is off by default. Per-file review is the bounded, checklist-driven part and the place a smaller model costs you least; the contracts and verification passes are where cross-file reasoning happens. Splitting them is worth trying before you lower anything else:

```json
"fileReviewModel": "claude-sonnet-5",
"integrationModel": "claude-opus-5"
```

## Gate and reporting

| Key | Default | Meaning |
|---|---|---|
| `gate` | `"blocking"` | `blocking` fails on any counted blocking finding. `security` fails only on blocking findings with category `security`. `none` never fails. |
| `failOnMissingReport` | `true` | The gate fails when no `findings.json` was produced at all. |
| `failOnIncomplete` | `true` | The gate fails when any reviewable file could not be reviewed, so a broken review never looks like a pass. |
| `postInlineComments` | `false` | Also post one inline pull request thread per finding. |
| `inlineCommentSeverities` | `["blocking"]` | Which severities get an inline thread. |

A queue-time pipeline variable `PR_REVIEW_GATE` overrides `gate` without editing the file, which is useful for a one-off merge.

## Checklists

```json
"checklists": {
  "cs": "csharp", "razor": "csharp",
  "ts": "typescript", "tsx": "typescript",
  "*": "general"
}
```

Maps a file extension to a file in `references/checklist-<name>.md`. The `*` entry is the fallback. Add a language by writing `references/checklist-python.md` and adding `"py": "python"`.

Every reviewer also gets `checklist-general.md`, so a language checklist only needs the traps specific to that language.

## Harnesses

The `harnesses` object is what makes the driver work with any assistant. Each entry is a command template:

```json
"claude": {
  "command": "claude",
  "args": [
    "-p", "{{prompt}}", "--permission-mode", "dontAsk",
    "--allowedTools", "{{allowedTools}}",
    "--add-dir", "{{outputDir}}", "--add-dir", "{{skillRoot}}",
    "--output-format", "text"
  ],
  "modelArgs": ["--model", "{{model}}"],
  "ciArgs": ["--bare"],
  "fileArgs": ["--max-turns", "10"],
  "integrationArgs": ["--max-turns", "60"],
  "fileReviewTools": "Read,Grep,Glob",
  "contractsTools": "Read,Grep,Glob,Bash(git *),Bash(pwsh *)",
  "verifyTools": "Read,Grep,Glob",
  "env": {}
}
```

| Field | Meaning |
|---|---|
| `command` | The executable. Must be on `PATH`. |
| `args` | Arguments for every call. |
| `modelArgs` | Appended when a model is in effect for that call (`-Model`, `-FileReviewModel` or `-IntegrationModel`). |
| `ciArgs` | Appended in CI (`TF_BUILD`, `CI=true`, or `-CI`). |
| `fileArgs` | Appended only to per-file calls. The turn cap is low on purpose: the prompt already holds the diff, the file and the checklists, so a review that needs ten turns has gone exploring. |
| `integrationArgs` | Appended to the contracts and verification passes. |
| `fileReviewTools` | Fills `{{allowedTools}}` for per-file calls. Read-only on purpose. |
| `contractsTools` | Fills `{{allowedTools}}` for the contracts pass. The driver appends one entry per verify command verb. |
| `verifyTools` | Fills `{{allowedTools}}` for the verification pass. Read-only: it checks findings, it does not run builds. |
| `env` | Environment variables set for the run, if not already set. Restored afterwards. |

`contractsTools` and `verifyTools` both fall back to `integrationTools` when only that older key is present.

Placeholders available anywhere in `args`: `{{prompt}}`, `{{promptFile}}`, `{{repoRoot}}`, `{{outputDir}}`, `{{skillRoot}}`, `{{model}}`, `{{allowedTools}}`.

### Adding another assistant

Add an entry and run with `-Harness <name>`. The prompt handed to the CLI is one sentence pointing at a prompt file on disk, so the assistant only needs to read a file and reply with JSON. For example, Codex:

```json
"codex": {
  "command": "codex",
  "args": ["exec", "{{prompt}}", "--sandbox", "read-only", "--json"],
  "modelArgs": ["-m", "{{model}}"],
  "ciArgs": [],
  "fileArgs": [],
  "integrationArgs": ["--sandbox", "workspace-write"],
  "env": {}
}
```

Check it with `-DryRun` first, which prints the exact command line without calling anything.

## Where to change what

| To change | Edit |
|---|---|
| What reviewers look for | `references/file-reviewer.md`, `references/contracts-reviewer.md`, `references/verification-reviewer.md`, the checklists |
| Severity and confidence meaning | `references/severity-guide.md` |
| The shape of a subagent prompt | `references/prompt-file-review.md`, `references/prompt-file-section.md`, `references/prompt-contracts.md`, `references/prompt-verify.md` |
| Report layout and JSON schema | `references/report-format.md` and `Merge-ReviewResults.ps1` together |
| Models and tool limits in chat | `.github/agents/*.agent.md` (Copilot), `.claude/agents/*.md` (Claude Code) |
| Models and tool limits for the driver | the `harnesses` entry |
| Pipeline behaviour | `pipelines/pr-review.yml` |

In VS Code a subagent cannot use a model from a higher cost tier than the orchestrator's, so if you pin the `pr-integration-reviewer` to a strong model, pin the orchestrator at least as high.
