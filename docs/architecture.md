# Architecture

## The problem

A pull request review done by one model in one context degrades as the change set grows. File four gets less attention than file one, the middle of a large diff is skimmed, and by the end the model is summarising rather than reviewing. Raising the context window does not fix it; attention is the scarce resource, not tokens.

The other failure is the opposite of skimming. A model reviewing a single file in isolation invents problems, because it cannot see the caller that already guards the null, or the switch that already handles the new case. Findings that a human reviewer would dismiss in five seconds reach the pull request and erode trust in the whole thing.

## The shape of the solution

Four moves, each aimed at one of those failures.

**Compute the facts with a script.** Which files changed, how many lines, what the diff is, which are generated: a script answers all of that exactly, for free, with no hallucination. The orchestrating agent never runs `git diff` into its own context.

**One fresh subagent per file.** Each reviewer sees one diff, one file, and the checklists. No other file competes for its attention, and nothing from file one is still in context when file twenty is read. This is what fixes skimming. Files whose diffs are tiny share a subagent, because a twenty-line config change does not need a context to itself; the thresholds for that are deliberately mean.

**A contracts pass and a verification pass.** The contracts pass reads the whole diff and looks for the problems only a whole-PR view can see: a changed signature nobody updated, a C# DTO not mirrored in the TypeScript client, a migration missing for a model change. The verification pass is handed every blocking and should-fix finding, from the file reviews and the contracts pass alike, and confirms or refutes each one with evidence. That second one is what fixes invention.

**Merge with a script.** Applying the confidence threshold, the verifications, de-duplication and the verdict is arithmetic, not judgement. A script does it the same way every time, and the gate and the comment script can rely on the output.

## The pipeline of a review

```
Get-PrDiff.ps1
    manifest.json, full.diff, diffs/*.diff
        |
        v
  orchestrator  (chat agent, or Invoke-PrReview.ps1)
        |
        +--> pr-file-reviewer x N            one per changed file, in parallel waves
        |        -> file-results.jsonl       (files with tiny diffs share one)
        |
        +--> pr-integration-reviewer         contracts pass: the whole diff, no findings yet
        |        (starts with the first      -> findings, assessment, verify command results
        |         file review, not after
        |         the last one)
        |
        +--> pr-integration-reviewer         verification pass: every blocking and
                 (after both of the above)   should-fix finding from both
                 -> integration-result.json
        |
        v
Merge-ReviewResults.ps1
    findings.json, report.md
        |
        +--> Publish-AdoPrComment.ps1
        +--> Test-ReviewGate.ps1
```

Every arrow is a file on disk. That is deliberate. A review that crashes halfway leaves `file-results.jsonl` behind, and the merge still produces a report from what did finish, with the rest listed as failed under coverage.

The two whole-PR passes used to be one, running after the last file review. Splitting them is what takes the longest single call off the critical path: contracts needs only the diff, so it runs while the files are being reviewed, and only verification has to wait for findings.

## Components

### Get-PrDiff.ps1

Resolves the base branch (explicit argument, then the pull request target from pipeline variables, then the configured candidates, then `origin/HEAD`), finds the merge base, and writes one unified diff per changed file plus `full.diff` and `manifest.json`.

It fetches the base branch when a remote exists, and otherwise works entirely offline. It never writes to the index or the working tree, and it sets `GIT_TERMINAL_PROMPT=0` so it can never hang waiting for credentials.

`manifest.json` carries per file: path, old path, status, additions, deletions, whether it is binary, the checklist to use, the diff path, the current line count, whether it is large, the review mode (`review`, `skip`, `deleted`) and the skip reason. Plus pull request metadata, the commit subjects, the base and head SHAs and the effective configuration.

Untracked files are handled by synthesising a diff, because `git diff` does not see them and `-IncludeWorkingTree` would otherwise silently miss a whole new file.

### The reviewers

The instructions live in `references/file-reviewer.md`, `references/contracts-reviewer.md` and `references/verification-reviewer.md`, not in the agent files. The prompt templates in `references/prompt-*.md` have a `{{instructions}}` placeholder that is filled with the whole file.

This is the decision that makes the thing portable. A subagent prompt is completely self-contained: context, file paths, instructions, output contract. It does not matter whether the harness has a rich custom-agent format, a generic task tool, or nothing but a CLI that reads a prompt file. The agent wrappers in `.claude/agents/` and `.github/agents/` only pin tools and models, and a harness with neither still gets an identical review.

### Invoke-PrReview.ps1

The unattended orchestrator. It writes one prompt file per unit of work, then launches the assistant's CLI as a background job for each, with a parallel limit, a timeout and a retry.

The prompt on the command line is one sentence: read this file and carry out the instructions. The real brief is in the file. That keeps command lines short enough for Windows, keeps quoting problems away, and leaves every prompt on disk for inspection afterwards.

**The prompt file holds everything the reviewer needs.** The diff, the current file with line numbers, and the checklists are all pasted in, because for a CLI process every file it opens is a full model round trip that resends the whole conversation first. A file review used to open five things before it could think. Now it answers from the first turn, which is why the per-file turn cap in `fileArgs` can be as low as ten. The blocks are built with a fence longer than any backtick run inside the content, so a Markdown file being reviewed cannot close its own code block. This only applies to the driver: a chat orchestrator leaves the paths alone, since reading a file in order to paste it would put the whole pull request in the one context that has to stay empty.

Answers are cached under `.pr-review-cache` in the repository, keyed on a hash of the exact prompt plus the harness, the model and a schema version. Re-running a review after fixing two files out of thirty calls the model twice. A changed file changes its prompt, which changes the key, so nothing stale can survive; bump `$promptSchemaVersion` when a change to the prompts should invalidate everything.

Responses are parsed by `Get-JsonBlock`, which tries a fenced `json` block, any fenced block, the whole response, and finally the outermost braces. Models add prose around JSON no matter how firmly you ask them not to, and failing a review over a politeness sentence would be absurd. A batched call answers with `{ "results": [ ... ] }`, which the driver splits back into one `file-results.jsonl` line per file, so everything downstream still sees one result per file.

### Merge-ReviewResults.ps1

Reads the manifest, `file-results.jsonl` and `integration-result.json`, and applies the rules in `references/report-format.md`: apply verifications, append integration findings, drop below the confidence threshold, move refuted findings to an appendix, fold duplicates, decide the verdict, build coverage.

Duplicates are folded in two passes. First, the verification pass declares them with `duplicateOf`, because only a whole-PR view can tell that a finding in a controller and a finding in the service it calls are one defect. Then a conservative safety net folds findings in the same file and category whose lines overlap **and** whose titles are similar. Title similarity is required because two different defects often share a line: an early version folded on overlap alone and silently lost a real finding. A folded finding keeps every location under `duplicates`, so the report can say "Also reported as" and nothing is discarded.

Finding ids follow a fixed rule so that the verification pass and the merge agree without coordinating: walk the manifest files in order, and each file's findings in order, numbering `F1`, `F2`, and so on; the contracts findings continue the sequence. The orchestrator applies the same rule when it builds the verification prompt, which is what lets a `duplicateOf` point from a file finding to a contracts finding and still mean the same thing to the merge.

The verdict is `request-changes` if any counted blocking finding remains, `approve-with-comments` if any should-fix remains, otherwise `approve`. If nothing could be reviewed at all the verdict is `incomplete`, and `incomplete: true` is set whenever any reviewable file failed. A broken review must never look like an approval.

### Test-ReviewGate.ps1 and Publish-AdoPrComment.ps1

Both read `findings.json` only. Neither knows anything about models. The gate writes Azure DevOps logging commands when `TF_BUILD` is set and plain text otherwise, so it is readable locally. The comment script uses a hidden marker to update its previous comment and per-finding fingerprints to avoid duplicate inline threads.

## Data formats

Defined once in [`references/report-format.md`](../.claude/skills/pr-review/references/report-format.md), which is the contract between the reviewers, the merge, the gate and the comment script. Change it there and change the merge script in the same commit.

| File | Written by | Read by |
|---|---|---|
| `manifest.json` | `Get-PrDiff.ps1` | orchestrator, driver, merge, whole-PR reviewers |
| `diffs/*.diff` | `Get-PrDiff.ps1` | per-file reviewers, or the driver when it inlines them |
| `full.diff` | `Get-PrDiff.ps1` | contracts and verification reviewers |
| `file-results.jsonl` | orchestrator or driver | merge, and the driver when building the verification prompt |
| `integration-result.json` | orchestrator or driver | merge |
| `.pr-review-cache/*.txt` | driver | driver, on a later run of the same review |
| `findings.json` | merge | gate, comment script, humans with scripts |
| `report.md` | merge | humans |

## Design decisions worth knowing

**The skill lives in `.claude/skills/`, not `.github/skills/`.** Claude Code, VS Code Copilot and the Copilot CLI all read `.claude/skills/`; only Copilot reads `.github/skills/`. One folder, three assistants.

**The orchestrator never reads changed code.** It is stated three times across the skill and the agent file, because it is the rule a helpful model most wants to break. The moment it reads one file "just to check", the design is gone.

**Confidence and severity are independent.** A serious problem you are only fairly sure of is blocking at confidence 0.6, not a nit at 0.9. Collapsing them into one number loses the distinction between "this matters" and "I am sure".

**Refuted findings are kept, not deleted.** They go into a collapsed appendix with the reason. That is how you audit whether the verification pass is refuting things it should not.

**The merge would rather show a duplicate than lose a defect.** A missed merge costs the reader a few seconds; an over-merge hides a problem entirely. So cross-file duplicates are only folded when the verification pass declares them, and the same-file safety net needs both overlapping lines and similar titles.

**Speed is bought from round trips and scheduling, not from reading less.** Every reviewer still sees the whole diff and the whole file; what changed is that it no longer spends five model turns fetching them, that trivial files share a call, and that the contracts pass runs while the files are being reviewed instead of after. The self-test asserts that turning batching off produces the same merged result, because a speed change that quietly changes findings is a correctness bug.

**The scripts are ASCII-only.** Windows PowerShell 5.1 reads a BOM-less file as ANSI, so a UTF-8 em dash inside a double-quoted string becomes three bytes that break the parse. Typography in the report comes from `[char]` codes. This is enforced in `.editorconfig` and worth preserving.

**Null checks in helpers use `[object]::ReferenceEquals`.** PowerShell 7's comparison binder was observed throwing `Argument types do not match` from a helper that had been called with many different value types, inside nested hashtable literals. Static reference comparison sidesteps the dynamic binder entirely. It happened a second time with `@()` inside a hashtable literal, so every script builds hashtables by assigning precomputed values.

## Extending it

| To add | Do |
|---|---|
| A language checklist | Write `references/checklist-<name>.md`, map extensions under `checklists` in `config.json` |
| Another assistant | Add an entry under `harnesses`; verify with `-DryRun` |
| A new finding category | Add it to `severity-guide.md` and the vocabulary table in `report-format.md` |
| A different report layout | Change the template in `report-format.md` and the rendering in `Merge-ReviewResults.ps1` together |
| GitHub instead of Azure DevOps | Keep everything, replace `Publish-AdoPrComment.ps1` with `gh pr comment` |
| A custom gate rule | `Test-ReviewGate.ps1` reads only `findings.json`; a new mode is a few lines |

## What it is not

It does not replace human review. It is good at the mechanical half: the fourth file, the caller in another project, the missing migration, the test that was edited to pass. It has no opinion about whether the feature is a good idea, and it cannot tell you that the approach is wrong.

It does not fix code. Every reviewer is read-only by design, and only the contracts pass gets shell access, for the verify commands you configure.

It is not deterministic. Two runs on the same diff will not produce identical findings. The verification pass and the confidence threshold narrow the variance, but a finding that appears in one run and not the next is expected behaviour, not a bug.
