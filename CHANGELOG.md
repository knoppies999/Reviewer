# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-09-22

Cuts the wall clock of a review, especially a large one, without changing what any reviewer sees. The self-test asserts that: it reviews the fixture with the new defaults, again with batching off, and again from the cache, and requires all three to produce the same findings.

None of this has been timed against a live model. The replay harness answers instantly, so what is measured here is structural: how many calls a review makes, how many model round trips each call needs, and what sits on the critical path.

### Changed

- **Prompts are self-contained.** The driver writes the unified diff, the current file with line numbers, and the checklists into each prompt file. A per-file reviewer used to open its prompt, the diff, two checklists and the source file before it could think, and for a CLI process each of those is a model round trip that re-sends everything before it. It now answers on its first turn, which is why the new `fileArgs` for Claude Code caps a file review at ten turns. Turn any of it off with `inlineDiff`, `inlineFileContent` and `inlineChecklists`. This applies only to the driver: a chat orchestrator keeps the paths, because reading a file to paste it into a prompt would pull the pull request through the one context that has to stay empty.
- **Files with tiny diffs share a call.** `filesPerSubagent` was in the config and the manifest but the driver ignored it, so a forty-file pull request was always forty processes. It now packs files into a call while they stay under `smallFileDiffLines` (25) changed lines, `batchMaxFileLines` (250) total lines, `filesPerSubagent` (4) files and `batchDiffLineBudget` (150) changed lines between them. Anything above those still gets a reviewer to itself. A batched call answers with `{ "results": [ … ] }`, which the driver splits back into one `file-results.jsonl` line per file, so nothing downstream changes. Set `batchSmallFiles` to false for the strict one-file-per-subagent rule.
- **The whole-PR pass is split in two.** Contracts and wiring need only the diff, so that half now starts with the first file review instead of after the last one; only verification, which needs the findings, waits. On a large pull request this takes the longest single call off the critical path. `references/integration-reviewer.md` and `references/prompt-integration.md` are replaced by `contracts-reviewer.md`, `verification-reviewer.md`, `prompt-contracts.md` and `prompt-verify.md`. The driver combines both results into the same `integration-result.json`, so the merge, the gate and the comment script are untouched.
- **`maxParallelSubagents` is 8**, was 4.
- The finding id rule now covers the contracts findings explicitly, and the driver applies it when building the verification prompt. That lets a `duplicateOf` point from a file finding to a contracts finding and still mean the same thing to the merge, which matters more now that the two passes run independently and can see one changed signature from both sides.
- A config file passed with `-ConfigPath` now wins over the manifest's snapshot for the driver's own execution knobs. The manifest still wins for what describes the change set, such as `minConfidence` and `conventions`.

### Added

- **A response cache** under `.pr-review-cache` in the repository, keyed on a hash of the exact prompt plus the harness, the model and a schema version. Re-running a review after fixing two files out of thirty calls the model twice. `-NoCache` ignores it; `cacheResults`, `cacheDirName` and `cacheMaxAgeDays` configure it. A pipeline agent starts empty, so this is a local convenience. It holds whole reviews of your code, so it is in `.gitignore` and `skipPatterns`.
- **Model tiering.** `-FileReviewModel` and `-IntegrationModel`, with `fileReviewModel` and `integrationModel` in the config and matching pipeline parameters, so the bounded per-file work can run on a faster model while the cross-file passes keep the strong one. Both default to `-Model`, so nothing changes until you set them.
- **Per-harness tool and argument keys** for the new shape: `fileArgs`, `contractsTools` and `verifyTools`. `contractsTools` and `verifyTools` fall back to the older `integrationTools` when only that is present.
- `driver-run.json` now records the parallelism, the calls made against the files reviewed, how many were batched, how many file contents were inlined, the cache hits, and the seconds each whole-PR pass took. It is the first place to look when a review was slower than expected.
- Twelve self-test checks for all of the above, including the two that would catch a speed change turning into a quality change: batching off must produce an identical merged result, and a warm cache must too.

### Fixed

- Wrapping the driver's file list in `@()` tripped PowerShell 7's `PSToObjectArrayBinder` with "Argument types do not match", the third time this project has hit that binder. Generic lists are now converted with `ToArray()`.

## [0.2.0] - 2026-09-21

### Added

- **End-to-end self-test** in `tests/`. `New-SampleRepo.ps1` builds a C# and TypeScript repository with twelve planted defects; a replay harness answers the driver from a recorded real review, so the real driver, merge and gate all run; `Measure-Review.ps1` scores any review of the fixture against `answer-key.json`. Offline it takes about 15 seconds and needs no credentials; with `-Harness` it measures a live model. It includes explicit regression checks for both merge bugs below, and fails 11 of its 31 checks against the merge from 0.1.0.
- **GitHub Actions workflow** running the self-test on Linux and Windows on every push and pull request, with a parse check and an ASCII check of every script. On Windows the merge and gate are repeated under Windows PowerShell 5.1.

### Fixed

- **Over-merging.** Two different defects on the same line and category were folded into one finding, and the second one's detail and suggestion were lost. The same-file safety net now also requires similar titles before folding, and a folded finding is kept under `duplicates` instead of being reduced to a mention.
- **Under-merging.** The same defect reported from two files, typically a controller and the service it calls, stayed as two findings and inflated the blocking count. The integration pass now declares duplicates with `duplicateOf`, and the merge folds them into one finding that keeps both locations. The report and the inline pull request comments show "Also reported as".
### Changed

- Findings in `findings.json` carry a `duplicates` array, and verifications in `integration-result.json` accept `duplicateOf`. Both are additive, so `schemaVersion` stays 1.
- A folded group takes the most severe severity, the highest confidence and the strongest verification among its members.
- The driver builds its reference file paths with forward slashes, like the other scripts. PowerShell accepts either separator on every platform, so this changes nothing at runtime; the Linux CI run confirms the driver works there.

## [0.1.0] - 2026-09-21

First public release.

### Added

- **The skill** at `.claude/skills/pr-review/`, read natively by Claude Code, VS Code Copilot and the Copilot CLI. Holds the interactive workflow, the configuration, the reviewer instructions, the prompt templates and the checklists.
- **`Get-PrDiff.ps1`** computes the change set: resolves the base branch and merge base, writes one diff per changed file, `full.diff` and `manifest.json`. Handles renames, deletions, binary files, untracked files and working-tree mode, and never modifies the repository.
- **`Invoke-PrReview.ps1`**, a harness-agnostic driver that runs the whole review unattended by launching an assistant CLI once per file and once for the integration pass, with a parallel limit, retries, timeouts and a `-DryRun` mode.
- **`Merge-ReviewResults.ps1`** turns the raw results into `findings.json` and `report.md` deterministically: confidence threshold, verification, de-duplication, verdict and coverage.
- **`Test-ReviewGate.ps1`** decides pass or fail from `findings.json` in `blocking`, `security` or `none` mode, and fails an incomplete review unless `failOnIncomplete` is turned off.
- **`Publish-AdoPrComment.ps1`** posts the report to an Azure DevOps pull request, updating its previous comment in place and optionally opening one inline thread per blocking finding.
- **Agent wrappers** for GitHub Copilot in `.github/agents/` and for Claude Code in `.claude/agents/`, pinning tools and models only. The reviewer instructions live in the skill and are pasted into every subagent prompt, so a harness with only a generic subagent tool works too.
- **Checklists** for C# / .NET and TypeScript / JavaScript, plus a general checklist covering correctness, error handling, security, concurrency, performance, data, tests, configuration and integration.
- **Severity guide** defining `blocking`, `should-fix`, `nit` and `question`, with confidence kept independent of severity.
- **Azure DevOps step template** at `pipelines/pr-review.yml` with `harness` (`copilot` or `claude`), `runner` (`driver` or `agent`), `gate`, `model`, `maxParallel`, `inlineComments` and more.
- **Documentation** covering installation, usage, configuration, the pipeline, the architecture and troubleshooting.

### Notes

- Verified locally: all five scripts parse and run under PowerShell 7 and Windows PowerShell 5.1; the change-set script against a scratch repository in commit, working-tree and pipeline-environment modes; the driver end to end against a stand-in harness; merge edge cases including malformed results, failed files and a missing integration pass; the gate in every mode including the incomplete path; and the comment script against a mock of the Azure DevOps threads API.
- Not yet exercised against a live service: a Copilot subscription, a signed-in Claude Code CLI, or an Azure DevOps organisation.
- The scripts are deliberately ASCII-only, because Windows PowerShell 5.1 reads a BOM-less file as ANSI and a stray non-ASCII character changes how it parses.

[0.3.0]: https://github.com/knoppies999/Reviewer/compare/7c178ba...main
[0.2.0]: https://github.com/knoppies999/Reviewer/compare/d0d20f6...7c178ba
[0.1.0]: https://github.com/knoppies999/Reviewer/commit/d0d20f6
