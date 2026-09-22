Verification pass over the findings of a pull request review. The instructions below are your complete brief; follow them exactly.

## Context
PR: {{title}}
What the PR does: {{summary}}
Base: {{baseRef}} ({{baseSha7}})   Head: {{headRef}} ({{headSha7}})
Repository root: {{repoRoot}}
Skill root: {{skillRoot}}
Manifest: {{manifestPath}}
Full diff: {{fullDiff}}

## Files in the change set (status, +/-, outcome)
{{fileList}}

## Per-file summaries
{{summaries}}

## Cross-file notes from the file reviewers
{{notes}}

## What the contracts pass concluded
{{assessment}}

## Findings to verify (JSON array; each has id, file, line, severity, category, title, detail, source)
{{findingsToVerify}}

## Instructions
{{instructions}}

## Output
Return exactly one ```json block using the **verification result** schema (`verifications[]`) described in {{skillRoot}}/references/report-format.md. Include one verification entry for every id listed above, and set `duplicateOf` on an entry when it describes the same defect as another listed id. Do not write or modify any files.
