# Azure DevOps pipeline

The review runs as a pull request validation build. It posts the report as a pull request comment, publishes it as a build artifact, and fails the build when the gate says so.

## One-time setup

### 1. A credential for the assistant

**GitHub Copilot.** A user with a Copilot seat creates a GitHub fine-grained personal access token with the **Copilot Requests** permission. The organisation policy must allow the Copilot CLI. Store it as a secret pipeline variable named `COPILOT_GITHUB_TOKEN`.

**Claude Code.** An Anthropic Console API key, stored as `ANTHROPIC_API_KEY`.

Either way, put it in a variable group so several pipelines can share it:

*Pipelines → Library → + Variable group →* name it `ai-review`, add the variable, click the padlock to mark it secret, and allow the pipelines that need it.

Reviews consume that account's usage. A 20-file pull request is roughly 20 model calls: one per file, fewer when small files are batched, plus one contracts pass and one verification pass.

### 2. Permission to comment

The build identity needs to write to pull requests.

*Project settings → Repositories → (your repo) → Security →* find **`<Project> Build Service (<Organisation>)`** → set **Contribute to pull requests** to **Allow**.

Without this the review still runs and still publishes the artifact; only the comment fails, with a 403 in the log.

### 3. The files on the branch

`.claude/skills/pr-review/` must exist on the branch being reviewed, because the pipeline runs the scripts from the checkout. Merge the installation commit into your trunk before relying on it.

## The pipeline

Create `azure-pipelines-review.yml` at the repository root:

```yaml
trigger: none          # only ever runs for pull requests

pr:
  branches:
    include: [develop, main]

pool:
  vmImage: ubuntu-latest   # windows-latest also works; pwsh is on both

variables:
- group: ai-review         # COPILOT_GITHUB_TOKEN and/or ANTHROPIC_API_KEY

steps:
- template: pipelines/pr-review.yml
  parameters:
    harness: copilot       # copilot | claude
    gate: blocking         # blocking | security | none
```

Then register it: *Pipelines → New pipeline →* point at the file, save without running.

### Wire it to a branch policy

A pull request build only runs if a branch policy asks for it.

*Repos → Branches →* hover your target branch → **⋯ → Branch policies → Build validation → +**

| Setting | Value |
|---|---|
| Build pipeline | the pipeline you just created |
| Trigger | Automatic |
| Policy requirement | **Optional** to start with, **Required** once you trust it |
| Build expiration | Immediately when the branch is updated |
| Display name | AI review |

Start with Optional. You get the comment on every pull request without blocking anyone while you tune the checklists and the confidence threshold.

## Template parameters

| Parameter | Default | Meaning |
|---|---|---|
| `harness` | `copilot` | `copilot` or `claude`. Selects the CLI to install, the secret to map and the command template. |
| `runner` | `driver` | `driver` runs `Invoke-PrReview.ps1`, one CLI process per file. `agent` lets a single Copilot session orchestrate the whole skill. Prefer `driver`. |
| `gate` | `blocking` | See [the gate](#the-gate). |
| `model` | assistant default | Model id for every call. Copilot ids come from `copilot help config`; Claude Code takes `sonnet`, `opus` or a full id. |
| `fileReviewModel` | `model` | Model for the per-file reviews only. |
| `integrationModel` | `model` | Model for the contracts and verification passes only. |
| `maxParallel` | 8 | Concurrent harness calls. |
| `inlineComments` | `false` | Also post one inline thread per blocking finding. |
| `baseBranch` | pull request target | Override the base branch. |
| `cliVersion` | `latest` | npm version of `@github/copilot` or `@anthropic-ai/claude-code`. Pin it for reproducible builds. |
| `nodeVersion` | `22.x` | Node version installed for the CLI. |
| `timeoutMinutes` | 45 | Timeout on the review step. |
| `skillPath` | `.claude/skills/pr-review` | Where the skill lives in the repository. |
| `extraCliArgs` | | Appended to every assistant call. |

## What the template does

```
checkout (fetchDepth: 0, persistCredentials: true)
  -> install Node
  -> install the assistant CLI
  -> Get-PrDiff.ps1               computes the change set
  -> Invoke-PrReview.ps1          the review
  -> Publish-AdoPrComment.ps1     posts or updates the comment
  -> PublishPipelineArtifact      the pr-review artifact
  -> Test-ReviewGate.ps1          decides pass or fail
```

`fetchDepth: 0` is not optional. A shallow clone has no merge base, and the review has nothing to diff against.

The review step is marked `continueOnError`, and the comment, artifact and gate steps run on `succeededOrFailed()`. That ordering is deliberate: when the review breaks you still get the artifact and a comment saying so, and the gate is the single place that decides the build result.

## The gate

[`Test-ReviewGate.ps1`](../.claude/skills/pr-review/scripts/Test-ReviewGate.ps1) reads `findings.json` and exits non-zero when the build should fail.

| Mode | Fails on |
|---|---|
| `blocking` | Any finding with severity `blocking` whose verification is not `refuted`. |
| `security` | The same, narrowed to findings with category `security`. |
| `none` | Nothing. Advisory only. |

In `blocking` and `security` mode the gate **also** fails when the review is incomplete, meaning a file that should have been reviewed was not. Set `failOnIncomplete: false` in `config.json` if you would rather have a partial review pass.

Exit codes: `0` pass, `1` gate failed, `2` no findings file at all.

Override the mode at queue time without editing anything by defining a pipeline variable `PR_REVIEW_GATE` with value `blocking`, `security` or `none`.

Unverified blocking findings count by default, on the principle that an unchecked serious claim deserves a human look. Pass `-IgnoreUnverified` to the gate script if you disagree.

## The pull request comment

The summary comment carries a hidden marker, so a re-run after a new push **edits the existing comment** rather than adding another one. The thread is left **active** when changes are requested or the review is incomplete, and **resolved** otherwise, so a clean review does not sit there demanding attention.

With `inlineComments: true`, each blocking finding also gets a thread anchored to its file and line. Those carry a per-finding fingerprint, so a re-run does not duplicate a comment that is already there.

Comments longer than 60000 characters are truncated with a pointer to the artifact, which holds the full report.

## Recommended rollout

1. **Week one, `gate: none`, policy Optional.** Read the comments. Nothing blocks.
2. **Tune.** Add `conventions` for the rules your team actually cares about. Add `skipPatterns` for anything generated. Raise `minConfidence` if the reviews are noisy.
3. **Week two, `gate: security`.** Only genuine security findings block. Low false-positive rate, high value.
4. **When you trust it, `gate: blocking` and policy Required.** Keep `PR_REVIEW_GATE` in mind for the occasional override.

Treat it as a first reviewer that never gets tired, not as a replacement for a human one. It is good at the things humans skim: the fourth file in a pull request, the caller three directories away, the migration nobody re-read.

## Cost

One model call per changed file, plus one contracts pass and one verification pass. Files with trivial diffs share a call, so the real number is usually below the file count. `skipPatterns` is what keeps it honest: a repository with committed lock files and generated clients can otherwise double its call count on files nobody reads.

Each call is also cheaper than it looks. Because the prompt already contains the diff, the file and the checklists, a reviewer does not spend four or five turns opening them, and every one of those turns would have re-sent the whole conversation.

To cap spend, set `maxAiCredits` for Copilot, or route per-file reviews to a cheaper model with `fileReviewModel` while `integrationModel` keeps the cross-file passes strong.

## GitHub Actions

There is no Actions workflow in this repository, but nothing here is Azure-specific except `Publish-AdoPrComment.ps1`. The change set, driver, merge and gate scripts all work unchanged. Replace the comment step with `gh pr comment --body-file .pr-review/report.md` and keep the rest.
