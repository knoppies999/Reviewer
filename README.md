# Reviewer

A multi-agent pull request reviewer that runs inside your AI coding assistant and in your CI pipeline.

Most AI code review is one model reading one big diff. Quality falls off a cliff as the change set grows, because everything competes for the same context window. Reviewer does what a careful human team does instead:

1. a **script** computes the change set, so the file list, line counts and diffs are exact and cost nothing,
2. **every changed file is reviewed in its own fresh subagent**, so no file dilutes another's context,
3. **one integration pass** reads the whole diff for cross-file problems and **confirms or refutes** every serious finding from step 2,
4. a **script** merges the results deterministically into a report and a machine-readable findings file.

The orchestrating agent never reads changed code itself. It reads a manifest, delegates, and collects. That is what keeps the review sharp on a 60-file pull request.

It runs in **VS Code Copilot Chat**, the **GitHub Copilot CLI** and **Claude Code**, and unattended in an **Azure DevOps** pipeline, where it posts the report to the pull request, publishes it as a build artifact, and can fail the build on blocking findings.

Checklists are tuned for **C# / .NET** and **TypeScript / JavaScript**, with a general checklist covering everything else.

---

## Quick start

Copy two folders into the repository you want reviewed, then ask for a review.

```bash
git clone https://github.com/knoppies999/Reviewer.git
```

Copy `Reviewer/.claude/` and `Reviewer/.github/agents/` into your repository root, commit them, and add `.pr-review/` to that repository's `.gitignore`. Then, in VS Code Copilot Chat or Claude Code:

```
/pr-review review the current branch against develop
```

The report is printed in chat and written to `.pr-review/report.md` and `.pr-review/findings.json`.

To run the same review with no chat session at all, from any shell:

```bash
pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 -Harness claude -Base develop
```

Full details in [docs/installation.md](docs/installation.md) and [docs/usage.md](docs/usage.md).

---

## What you get

A report that leads with a verdict and separates what must be fixed from what merely could be:

```markdown
# PR review: Add retries to payment capture

**Verdict:** Request changes · **Base:** `develop` ← **Head:** `feature/payment-retries` · 7 files reviewed, 2 skipped, 1 deleted

The PR adds retries to payment capture and returns the cancelled order from CancelOrder.
The retry is unsafe without idempotency, and the API contract change is not mirrored in the front end.

## Blocking (1)

### F1 · `src/Orders/OrderService.cs:88-94` · bug · confidence 0.85 · confirmed
**Retry loop can charge the card twice on timeout**

A timeout after the provider accepted the charge is retried without an idempotency key,
so a slow provider double-charges. The catch at line 90 treats TaskCanceledException
like a transport failure.

_Verification (confirmed): ChargeAsync has no idempotency parameter and the provider SDK
documents timeouts as ambiguous._

**Suggestion:** Pass the order id as the idempotency key to _payments.ChargeAsync.
```

Alongside it, `findings.json` carries the same data with severity, category, confidence, verification status and coverage, which the build gate and the pull request comment script both read.

---

## How it works

| Step | Who | What |
|---|---|---|
| 1 | `Get-PrDiff.ps1` | Resolves base and merge base, writes one diff per file, `full.diff` and `manifest.json`. Never modifies the repository. |
| 2 | orchestrator | Reads only the manifest. Orders files by risk, builds one self-contained prompt per file. |
| 3 | per-file subagents | One fresh context per file: reads the diff and the whole file, applies the general and language checklists, returns JSON findings with severity and confidence. |
| 4 | integration subagent | Reads the whole diff for contract, wiring, test and completeness problems, runs any configured build or test commands, and confirms or refutes every blocking and should-fix finding. |
| 5 | `Merge-ReviewResults.ps1` | Applies the confidence threshold and the verifications, de-duplicates, decides the verdict, writes `findings.json` and `report.md`. |
| 6 | pipeline only | Posts the report to the pull request, publishes the artifact, applies the gate. |

Two ways to drive steps 2 to 4. In a chat session the assistant's own agent spawns the subagents. Unattended, `Invoke-PrReview.ps1` launches the assistant's CLI once per file and once for the integration pass, with a parallel limit, retries and timeouts. The driver does not depend on a model orchestrating anything, which is why it is the recommended path for pipelines.

[docs/architecture.md](docs/architecture.md) explains the design, the data formats and why each decision was made.

---

## Repository layout

```
.claude/
├── skills/pr-review/               the skill: single source of truth
│   ├── SKILL.md                    interactive workflow for chat sessions
│   ├── config.json                 all knobs, plus per-harness CLI command templates
│   ├── references/
│   │   ├── file-reviewer.md        what a per-file reviewer does
│   │   ├── integration-reviewer.md what the integration pass does
│   │   ├── prompt-*.md             prompt templates with {{placeholders}}
│   │   ├── checklist-general.md    all languages, plus the Integration section
│   │   ├── checklist-csharp.md
│   │   ├── checklist-typescript.md
│   │   ├── severity-guide.md       blocking / should-fix / nit / question, and confidence
│   │   └── report-format.md        result schemas, id rule, merge rules, report template
│   └── scripts/
│       ├── Get-PrDiff.ps1          change set -> diffs/, full.diff, manifest.json
│       ├── Invoke-PrReview.ps1     driver: runs a headless CLI per file, then merges
│       ├── Merge-ReviewResults.ps1 results -> findings.json + report.md
│       ├── Test-ReviewGate.ps1     pass/fail from findings.json
│       └── Publish-AdoPrComment.ps1 post or update the Azure DevOps PR comment
└── agents/                         Claude Code subagent wrappers
.github/agents/                     GitHub Copilot custom agent wrappers
pipelines/pr-review.yml             Azure DevOps step template
docs/                               installation, usage, configuration, architecture
```

**Why the skill lives in `.claude/skills/`:** Claude Code, VS Code Copilot and the Copilot CLI all read that folder, so one copy serves every target. The agent files are thin wrappers that pin tools and models; the reviewer instructions live in the skill and are pasted into every subagent prompt. A harness with only a generic subagent tool therefore works too. Codex, Gemini CLI and Cursor read `.agents/skills/`; a one-line `SKILL.md` there pointing at this folder is enough to add them.

---

## Documentation

| Document | Covers |
|---|---|
| [docs/installation.md](docs/installation.md) | Per-repository and per-machine installation, prerequisites, verifying the install |
| [docs/usage.md](docs/usage.md) | VS Code Copilot Chat, Claude Code, the Copilot CLI, and the unattended driver |
| [docs/configuration.md](docs/configuration.md) | Every key in `config.json`, including harness command templates |
| [docs/azure-pipelines.md](docs/azure-pipelines.md) | Pipeline setup, credentials, permissions, template parameters, the gate |
| [docs/architecture.md](docs/architecture.md) | How the pieces fit, data formats, extension points, design rationale |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptoms, causes and fixes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Conventions for changing the skill, the scripts or the checklists |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

---

## Requirements

- **PowerShell 7** (`pwsh`) for the driver. The other four scripts also run on Windows PowerShell 5.1.
- **Git** 2.20 or newer, with full history available (`fetchDepth: 0` on a pipeline).
- One assistant: **GitHub Copilot** (VS Code Chat, or `npm i -g @github/copilot`) or **Claude Code** (`npm i -g @anthropic-ai/claude-code`).
- For the pipeline: an Azure DevOps project, a credential for the assistant, and *Contribute to pull requests* for the build identity.

---

## Status

Verified locally: all five scripts parse and run under PowerShell 7 and Windows PowerShell 5.1; the change-set script against a scratch repository in commit, working-tree and pipeline-environment modes; the driver end to end against a stand-in harness covering parallelism, retries, JSON extraction, the integration pass, merge and report; merge edge cases including malformed results, failed files and a missing integration pass; the gate in every mode including the incomplete-review path; and the pull request comment script against a mock of the Azure DevOps threads API.

Not yet exercised against a live service: a real Copilot subscription, a logged-in Claude Code CLI, or an Azure DevOps organisation. A driver run was launched against the Claude Code CLI on the author's machine and correctly reported `incomplete` because that CLI was not signed in. Expect to tune models, tool permissions and prompt wording on the first real runs.

## License

[MIT](LICENSE).
