# Installation

Reviewer is a folder of Markdown and PowerShell. There is nothing to build and nothing to install into a runtime. You copy two directories into a repository, or into your user profile, and your AI assistant discovers them.

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| PowerShell 7 (`pwsh`) | The driver uses background jobs and `-Version 7.0` features | `pwsh -v` |
| Windows PowerShell 5.1 (optional) | The other four scripts run there too, for older Windows agents | `powershell -v` |
| Git 2.20+ | `git diff -M`, `merge-base`, `--output=` | `git --version` |
| An assistant | Runs the actual review | see below |

One of:

```bash
npm install -g @github/copilot           # GitHub Copilot CLI
npm install -g @anthropic-ai/claude-code # Claude Code
```

or the **GitHub Copilot Chat** extension in VS Code with agent mode enabled. VS Code needs no CLI.

Node 20 or newer is required by both CLIs.

## Option 1: install into a repository (recommended)

This is the normal case. The review configuration is versioned with the code it reviews, so a change to the checklist arrives with the pull request that needs it.

1. Clone or download this repository.
2. Copy these two directories into the target repository's root, merging with anything already there:

   ```
   .claude/          -> <target repo>/.claude/
   .github/agents/   -> <target repo>/.github/agents/
   ```

3. If you want the Azure DevOps pipeline, also copy `pipelines/pr-review.yml`.
4. Add the review output directory to the target repository's `.gitignore`:

   ```gitignore
   .pr-review/
   ```

5. Commit. The skill must be present on the branch under review for a pipeline run to find it.

On Windows, from the target repository root:

```powershell
$source = 'C:\path\to\Reviewer'
Copy-Item "$source\.claude" . -Recurse -Force
New-Item -ItemType Directory -Force .github | Out-Null
Copy-Item "$source\.github\agents" .github -Recurse -Force
Copy-Item "$source\pipelines\pr-review.yml" pipelines -Force   # optional
```

On macOS or Linux:

```bash
SOURCE=~/src/Reviewer
cp -r "$SOURCE/.claude" .
mkdir -p .github && cp -r "$SOURCE/.github/agents" .github/
mkdir -p pipelines && cp "$SOURCE/pipelines/pr-review.yml" pipelines/   # optional
```

Then tune [config.json](../.claude/skills/pr-review/config.json) for the repository: base branch names, skip patterns, build and test commands, and house conventions. See [configuration.md](configuration.md).

## Option 2: install for your user account

Every repository on your machine gets the review, without committing anything. Useful for repositories you do not control, and for trying it out.

| Assistant | Skill goes to | Agents go to |
|---|---|---|
| Claude Code | `~/.claude/skills/pr-review/` | `~/.claude/agents/` |
| GitHub Copilot | `~/.copilot/skills/pr-review/` | `~/.copilot/agents/` |

```powershell
# Windows, both assistants
$source = 'C:\path\to\Reviewer'
foreach ($home in "$env:USERPROFILE\.claude", "$env:USERPROFILE\.copilot") {
    New-Item -ItemType Directory -Force "$home\skills", "$home\agents" | Out-Null
    Copy-Item "$source\.claude\skills\pr-review" "$home\skills" -Recurse -Force
}
Copy-Item "$source\.claude\agents\*" "$env:USERPROFILE\.claude\agents" -Force
Copy-Item "$source\.github\agents\*" "$env:USERPROFILE\.copilot\agents" -Force
```

```bash
# macOS / Linux
SOURCE=~/src/Reviewer
mkdir -p ~/.claude/skills ~/.claude/agents ~/.copilot/skills ~/.copilot/agents
cp -r "$SOURCE/.claude/skills/pr-review" ~/.claude/skills/
cp -r "$SOURCE/.claude/skills/pr-review" ~/.copilot/skills/
cp "$SOURCE/.claude/agents/"* ~/.claude/agents/
cp "$SOURCE/.github/agents/"* ~/.copilot/agents/
```

A repository-level copy always wins over a user-level one, so you can install globally and still override per repository.

## Option 3: other assistants

Codex, Gemini CLI, Cursor, OpenCode and others read the vendor-neutral `.agents/skills/` directory. Point them at the same skill:

```bash
mkdir -p .agents/skills
ln -s ../../.claude/skills/pr-review .agents/skills/pr-review   # or copy it
```

They have no custom-agent format equivalent to the wrappers, so use the driver (`Invoke-PrReview.ps1`) with a new entry under `harnesses` in `config.json`. See [configuration.md](configuration.md#harnesses).

## Verify the installation

**The scripts parse and the change set computes.** From the repository root, on a branch with at least one commit ahead of your base:

```powershell
pwsh -NoProfile -File .claude/skills/pr-review/scripts/Get-PrDiff.ps1 -Base main
```

Expect a summary and a manifest path. The `.pr-review/` directory now holds `manifest.json`, `full.diff` and one diff per changed file. Nothing in your working tree was touched.

**The assistant can see the skill.**

```bash
copilot skill list          # Copilot CLI
```

In VS Code, type `/` in Copilot Chat and look for `pr-review`. In Claude Code, type `/pr-review` and it should autocomplete.

**The driver can reach your assistant.** This writes the prompts and prints the exact commands without calling anything:

```powershell
pwsh -File .claude/skills/pr-review/scripts/Invoke-PrReview.ps1 -Harness claude -Base main -DryRun
```

Then run it for real on a small branch. If every file comes back as failed, open `.pr-review/responses/file-001.txt`; it is almost always an authentication message.

## Upgrading

Replace `.claude/skills/pr-review/` and the agent wrappers with the new version, then re-apply your local changes to `config.json`. Keep your own `config.json` if you have tuned it: the shipped one is a starting point, not something the scripts depend on being pristine. [CHANGELOG.md](../CHANGELOG.md) lists what changed.

## Uninstalling

Delete `.claude/skills/pr-review/`, the two or three agent wrapper files, `pipelines/pr-review.yml` and the `.pr-review/` output directory. Nothing else was modified.
