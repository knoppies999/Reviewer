# Troubleshooting

Start with the output directory. A driver run leaves `prompts/`, `responses/` and `driver-run.json` behind, and they answer most questions faster than any log.

```powershell
Get-Content .pr-review/responses/file-001.txt   # what the assistant actually said
Get-Content .pr-review/prompts/file-001.md      # what it was actually asked
Get-Content .pr-review/driver-run.json | ConvertFrom-Json   # attempts, timings, outcomes
```

---

## Computing the change set

### `Could not resolve a base branch (tried: ...)`

The named branch does not exist locally or on `origin`.

- Pass it explicitly: `-Base develop`.
- On a pipeline, confirm `fetchDepth: 0` in the checkout step.
- Fetch it by hand: `git fetch origin develop`.
- Check `baseBranchCandidates` in `config.json` matches your trunk naming.

### `git merge-base failed`

A shallow clone has no common ancestor to diff against.

```bash
git fetch --unshallow
```

On a pipeline, set `fetchDepth: 0`. The template does this already; a hand-written pipeline may not.

### The review misses my latest changes

Commit mode reviews the head commit, not your working tree. The script warns when the working tree is dirty. To include uncommitted work:

```powershell
pwsh -File ... /Invoke-PrReview.ps1 -Harness claude -Base develop -IncludeWorkingTree
```

### Every file was skipped

Open `manifest.json` and read `skipReason` on each file. It names the exact pattern that matched. Usually a `skipPatterns` entry is broader than intended: `**/*.min.js` is fine, `**/*min*` is not.

### A file I care about was skipped

Same place, same field. Remove or narrow the pattern in `config.json`. Binary files are always skipped; there is nothing to review in them.

---

## Running the review

### `The harness command 'claude' is not on PATH`

```bash
npm install -g @anthropic-ai/claude-code   # or @github/copilot
```

Then open a new shell so `PATH` is refreshed. On a pipeline, confirm the install step ran and matches the `harness` parameter.

### Every per-file review fails, `no valid JSON result in the response`

Read `responses/file-001.txt`. In order of likelihood:

| What it says | Fix |
|---|---|
| `Not logged in` / `Please run /login` | Run `claude` or `copilot` once interactively and sign in. In CI, set `ANTHROPIC_API_KEY` or `COPILOT_GITHUB_TOKEN`. |
| A permission or approval prompt | The harness needs broader tool permissions. For Claude Code check `--allowedTools` and the `--add-dir` entries in the `harnesses` entry; for Copilot check that `--allow-all-tools` is present. |
| Rate limit or quota | Lower `-MaxParallel`, or wait. |
| Prose with no JSON at all | The model ignored the output contract. Try a stronger model with `-Model`. |

The driver exits with code 3 when every file failed, which is a strong hint that it is authentication rather than the code.

### One file fails while the rest succeed

Usually a timeout on a very large file. Raise `-TimeoutMinutes`, or add the file to `skipPatterns` if it is generated. The report lists it under coverage as failed, so the result is honest either way.

### The integration pass did not run

The report says so, and every blocking and should-fix finding is marked `unverified`. Check `responses/integration-*.txt`. The integration prompt is the largest one, so a small context window or a low `--max-turns` is a common cause.

### The agent reviews files itself instead of spawning subagents

Its subagent tool is not enabled, or the worker agents are not discoverable.

- VS Code: check that `agent` is in the `tools` list of `.github/agents/pr-review.agent.md`, and that the two worker agents are present in `.github/agents/`.
- Claude Code: check `.claude/agents/` exists on the branch.
- Either way, the driver does not need a subagent tool at all. Use it if the chat path is fighting you.

### The review is slow

Each file is one model call. Raise `-MaxParallel` if your account tolerates it, trim `skipPatterns`, or route per-file reviews to a faster model with `-Model`. The integration pass is one call and is not worth optimising.

---

## Findings quality

### Too many low-value findings

- Raise `minConfidence` to 0.7 or 0.75.
- Add `conventions` so the reviewer knows what your codebase already decided.
- Check that your formatter and linter are mentioned; reviewers are told not to duplicate what a tool already enforces, but only if they know one exists.

### Findings that are plainly wrong

Check whether the integration pass refuted them. Refuted findings are in the collapsed appendix at the bottom of the report, not in the body. If wrong findings are surviving verification, the integration pass may be running out of room: check `responses/integration-1.txt` for truncation.

### Findings about code the pull request did not touch

They should be `severity: question`, `category: pre-existing`. If they are arriving as blocking, the per-file instructions are being ignored, which usually means a weaker model. Raise the model for per-file reviews.

### The same problem is reported twice

The merge de-duplicates findings in the same file and category with overlapping line ranges. Two reports of one problem with different categories survive on purpose, because they may be genuinely different angles.

---

## Pipeline

### `Cannot post to the pull request; missing: Token`

`System.AccessToken` is not mapped into the step. The template does this; a hand-written step needs:

```yaml
env:
  SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

### 403 when posting the comment

The build identity lacks permission. *Project settings → Repositories → (repo) → Security →* `<Project> Build Service (<Org>)` → **Contribute to pull requests** → Allow.

### `Not a pull request build; nothing to post`

Expected on a manual or CI run. The comment step only does something when `System.PullRequest.PullRequestId` is set, which requires a branch policy build validation.

### The build passed but the report shows blocking findings

Check the gate mode. `gate: none` never fails, and `gate: security` only fails on security findings. Also check whether a queue-time `PR_REVIEW_GATE` variable overrode the template parameter.

### The build failed with no findings

The gate also fails on an incomplete review. The log lists which files were not reviewed and why. Either fix the cause, or set `failOnIncomplete: false` in `config.json` to accept partial reviews.

### `The review did not produce findings.json`

The review step failed before the merge ran. Download the `pr-review` artifact and read `responses/`. Exit code 2 from the gate means this specific case.

### Several comments stack up on one pull request

The summary comment carries a hidden marker and is updated in place. Stacked comments mean the marker is missing, which happens if someone edited the bot's comment. Delete the extras; the next run will adopt the remaining one.

---

## Scripts

### `Argument types do not match` from a script

PowerShell 7's dynamic binder, from a helper called with many different value types inside nested hashtable literals. The shipped scripts avoid it by using `[object]::ReferenceEquals` for null checks and precomputing values before building a hashtable. If you add code and hit this, do the same.

### Parse errors under Windows PowerShell 5.1 only

5.1 reads a BOM-less file as ANSI, so a non-ASCII character inside a double-quoted string breaks the parse. The scripts are deliberately ASCII-only, with typography from `[char]` codes. Check your edit:

```powershell
Select-String -Path .claude/skills/pr-review/scripts/*.ps1 -Pattern '[^\x00-\x7F]'
```

### Execution policy blocks the scripts

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File ...
```

The pipeline template is unaffected; Azure DevOps agents already run pwsh with a permissive policy.

---

## Still stuck

Collect this before opening an issue:

```powershell
pwsh -v; git --version; claude --version 2>$null; copilot --version 2>$null
Get-Content .pr-review/driver-run.json
Get-ChildItem .pr-review/responses | Select-Object Name, Length
```

Plus the first 20 lines of the failing response file. Redact anything from your source that you would not put in a public issue: the prompts contain your diffs.
