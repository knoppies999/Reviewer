Contracts and wiring pass over a whole pull request. The instructions below are your complete brief; follow them exactly.

The per-file reviews are running while you work, so you will not be given their findings. Look at the seams between the files, not inside them.

## Context
PR: {{title}}
What the PR does: {{summary}}
Base: {{baseRef}} ({{baseSha7}})   Head: {{headRef}} ({{headSha7}})
Repository root: {{repoRoot}}
Skill root: {{skillRoot}}
Manifest: {{manifestPath}}
Full diff: {{fullDiff}}
Repository conventions: {{conventions}}
Report findings with confidence >= {{minConfidence}}.

## Files in the change set (status, +/-, how the review treats them)
{{fileList}}

## Verify commands to run exactly as written
{{verifyCommands}}

## Instructions
{{instructions}}

The integration checklist is the "Integration" section of {{skillRoot}}/references/checklist-general.md.

## Output
Return exactly one ```json block using the **contracts result** schema (`findings[]`, `assessment`, `verifyCommands[]`) described in {{skillRoot}}/references/report-format.md. Do not write or modify any files.
