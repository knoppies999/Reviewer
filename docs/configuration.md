# Configuration

Everything tunable lives in [`.claude/skills/pr-review/config.json`](../.claude/skills/pr-review/config.json). The scripts and the agents both read it, so one edit changes every way of running the review.

## Change set

| Key | Default | Meaning |
|---|---|---|
| `baseBranchCandidates` | `["develop","main","master"]` | Tried in order when no base is given. First one that resolves wins. On a pipeline the pull request target branch takes precedence. |
| `reportDirName` | `".pr-review"` | Output directory under the repository root for local runs. On a pipeline the artifact staging directory is used instead. |
| `skipPatterns` | lock files, generated code, binaries, build output | Globs that are never sent to a reviewer. `**` matches any depth, `*` stays within a path segment, and a pattern without a slash matches at any depth like `.gitignore`. |
| `maxDiffLinesPerFile` | 1500 | Above this the file is marked `large`. It is still reviewed; the reviewer is told to focus on the hunks and their surroundings. |
| `reviewDeletedFiles` | `false` | Give deleted files their own subagent. Usually unnecessary: the integration pass checks for leftover references. |

Add to `skipPatterns` whenever a review wastes calls on noise. Check `skipReason` in `manifest.json` to see which pattern matched a file.

## Review behaviour

| Key | Default | Meaning |
|---|---|---|
| `maxParallelSubagents` | 4 | Subagents per wave in chat, and the driver's default parallelism. Raise it if your account tolerates the concurrency. |
| `filesPerSubagent` | 1 | Files per per-file subagent. Leave at 1. Batching trades away the context isolation that makes this work. |
| `minConfidence` | 0.6 | Findings below this are dropped by the merge. Raise to 0.75 for a quieter review, lower to 0.5 to see more speculation. |
| `conventions` | `[]` | Short house rules handed to every reviewer. |
| `verifyCommands` | `[]` | Build, type-check or test commands the integration pass runs. |

`conventions` is the highest-leverage setting in the file. It is the difference between a generic review and one that knows your codebase:

```json
"conventions": [
  "All public API endpoints require an authorization policy, never role checks in the handler",
  "Money is always decimal in C# and minor units as integers in TypeScript",
  "Every repository method takes a CancellationToken and passes it through",
  "No new usage of the legacy Sync* helpers in src/Legacy"
]
```

`verifyCommands` turns the integration pass from opinion into evidence. A failing command becomes a finding with the output excerpt:

```json
"verifyCommands": ["dotnet build --no-restore", "npx tsc --noEmit"]
```

Keep them fast and side-effect free. Never put anything there that writes to a shared database, publishes a package or pushes to a remote.

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
    "--output-format", "text", "--max-turns", "60"
  ],
  "modelArgs": ["--model", "{{model}}"],
  "ciArgs": ["--bare"],
  "integrationArgs": [],
  "fileReviewTools": "Read,Grep,Glob",
  "integrationTools": "Read,Grep,Glob,Bash(git *),Bash(pwsh *)",
  "env": {}
}
```

| Field | Meaning |
|---|---|
| `command` | The executable. Must be on `PATH`. |
| `args` | Arguments for every call. |
| `modelArgs` | Appended only when `-Model` is given. |
| `ciArgs` | Appended in CI (`TF_BUILD`, `CI=true`, or `-CI`). |
| `integrationArgs` | Appended only to the integration pass. |
| `fileReviewTools` | Fills `{{allowedTools}}` for per-file calls. Read-only on purpose. |
| `integrationTools` | Fills `{{allowedTools}}` for the integration pass. The driver appends one entry per verify command verb. |
| `env` | Environment variables set for the run, if not already set. Restored afterwards. |

Placeholders available anywhere in `args`: `{{prompt}}`, `{{promptFile}}`, `{{repoRoot}}`, `{{outputDir}}`, `{{skillRoot}}`, `{{model}}`, `{{allowedTools}}`.

### Adding another assistant

Add an entry and run with `-Harness <name>`. The prompt handed to the CLI is one sentence pointing at a prompt file on disk, so the assistant only needs to read a file and reply with JSON. For example, Codex:

```json
"codex": {
  "command": "codex",
  "args": ["exec", "{{prompt}}", "--sandbox", "read-only", "--json"],
  "modelArgs": ["-m", "{{model}}"],
  "ciArgs": [],
  "integrationArgs": ["--sandbox", "workspace-write"],
  "env": {}
}
```

Check it with `-DryRun` first, which prints the exact command line without calling anything.

## Where to change what

| To change | Edit |
|---|---|
| What reviewers look for | `references/file-reviewer.md`, `references/integration-reviewer.md`, the checklists |
| Severity and confidence meaning | `references/severity-guide.md` |
| The shape of a subagent prompt | `references/prompt-file-review.md`, `references/prompt-integration.md` |
| Report layout and JSON schema | `references/report-format.md` and `Merge-ReviewResults.ps1` together |
| Models and tool limits in chat | `.github/agents/*.agent.md` (Copilot), `.claude/agents/*.md` (Claude Code) |
| Models and tool limits for the driver | the `harnesses` entry |
| Pipeline behaviour | `pipelines/pr-review.yml` |

In VS Code a subagent cannot use a model from a higher cost tier than the orchestrator's, so if you pin the integration reviewer to a strong model, pin the orchestrator at least as high.
