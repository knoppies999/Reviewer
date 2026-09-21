# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/knoppies999/Reviewer/releases/tag/v0.1.0
