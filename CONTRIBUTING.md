# Contributing

Thanks for taking a look. This is a small repository: Markdown that tells models what to do, and PowerShell that does everything a model should not.

## Ground rules

**Scripts do facts, models do judgement.** Anything countable, parseable or deterministic belongs in a script. If you find yourself asking a model to compute a line number or apply a threshold, move it.

**The orchestrator never reads changed code.** The whole design rests on it. A change that lets the orchestrating agent read a diff "just to check" defeats the context isolation and will not be merged.

**Reviewers are read-only.** Per-file reviewers get read and search tools. The integration pass gets shell access only for configured verify commands. Nothing in a review writes to the repository under review.

**Every subagent prompt is self-contained.** Subagents see nothing of the conversation. If a change needs the subagent to know something, put it in the prompt template.

## Scripts

Five scripts in `.claude/skills/pr-review/scripts/`. They must keep working under **PowerShell 7** and, except for the driver, under **Windows PowerShell 5.1**.

**ASCII only.** Windows PowerShell 5.1 reads a BOM-less file as ANSI, so a UTF-8 em dash inside a double-quoted string breaks the parse. Typography comes from `[char]` codes:

```powershell
$dot = [string][char]0x00B7   # middle dot
```

Check before committing:

```powershell
Select-String -Path .claude/skills/pr-review/scripts/*.ps1 -Pattern '[^\x00-\x7F]'
```

**Null checks in helpers use `[object]::ReferenceEquals`.** PowerShell 7's comparison binder throws `Argument types do not match` when a polymorphic helper is called inside nested hashtable literals. Build hashtables by assigning precomputed values rather than calling helpers inline.

**Comment-based help on every script**, with `.SYNOPSIS`, `.DESCRIPTION`, a line per parameter, and at least one `.EXAMPLE`.

**Never modify the repository under review.** Scripts read git state and write only into the output directory.

Check that everything still parses:

```powershell
foreach ($s in Get-ChildItem .claude/skills/pr-review/scripts/*.ps1) {
    $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$e)
    "$($s.Name): $($e.Count) error(s)"
}
```

Run the same loop under `powershell` as well as `pwsh`.

## Instructions and checklists

The reviewer instructions in `references/file-reviewer.md` and `references/integration-reviewer.md` are the product. Write them for a capable colleague, not a rule engine.

**Explain why.** "Report findings with confidence at or above the threshold, because the report sorts by severity and confidence anyway" beats "ALWAYS respect minConfidence". Models follow reasons further than they follow capitals.

**Checklist items are questions, not commands.** Each one is a thing to consider that becomes a finding only when you can point at a line and name a consequence. Keep them specific enough to act on: "N+1 queries, queries inside loops, fetching whole tables to filter in memory" earns its place; "consider performance" does not.

**Language checklists only carry language-specific traps.** Everything general is in `checklist-general.md`, which every reviewer already receives.

To add a language: write `references/checklist-<name>.md`, map its extensions under `checklists` in `config.json`, and mention it in the docs.

## Data formats

[`references/report-format.md`](.claude/skills/pr-review/references/report-format.md) is the contract between the reviewers, the merge script, the gate and the comment script. A change there is a change to four things at once. Update the document and `Merge-ReviewResults.ps1` in the same commit, and bump `schemaVersion` if the shape changes.

## Testing

Run the self-test before opening a pull request:

```powershell
pwsh -File tests/Invoke-SelfTest.ps1
```

It builds the fixture repository, replays a recorded real review through the driver, merge and gate, and checks the result exactly, in about 15 seconds. CI runs it on Linux and Windows on every push, together with a parse check and an ASCII check of every script. [tests/README.md](tests/README.md) explains what it covers.

Depending on what you changed, also:

1. **Parse check** under both PowerShell editions, as above, for any script change.
2. **Driver dry run** for both harnesses after changing a command template, and read the printed command lines:

   ```powershell
   pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 -Harness claude -Base main -DryRun
   ```

3. **A live self-test** after changing a prompt, an instruction file or a checklist, with `-Harness claude` or `-Harness copilot`. The scorecard is the only way to tell whether a wording change helped, and it makes before and after comparable.
4. **A new recording** after changing the fixture, as described in [tests/README.md](tests/README.md#changing-the-fixture-or-the-recording).

## Commits and pull requests

Imperative subject line under 72 characters, with the area first:

```
driver: retry once when the response has no JSON block
checklist(csharp): add captive dependency and DbContext lifetime checks
docs: explain the incomplete verdict in the gate section
```

In the pull request description say what changed, why, and how you tested it. If you changed a prompt or a checklist, include a before and after of a real finding: that is the only way to tell whether a wording change helped.

## Scope

Welcome:

- More language checklists, especially Python, Go, Java and SQL.
- New `harnesses` entries for other assistants.
- A GitHub Actions workflow and a `gh`-based comment script.
- Sharper checklist items, backed by a false positive or a miss you actually hit.
- More self-test fixtures, for example a Python or SQL change set, each with its own answer key.

Probably not:

- Anything that lets the review write to the repository under review.
- Batching several files into one reviewer by default.
- Replacing the deterministic merge with a model.

Open an issue before a large change so we can agree on the shape.
