Whole-PR integration and verification pass. The instructions below are your complete brief; follow them exactly.

## Context
PR: {{title}}
What the PR does: {{summary}}
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

## Findings to verify (JSON array; each has id, file, line, severity, category, title, detail)
{{findingsToVerify}}

## Verify commands to run exactly as written
{{verifyCommands}}

## Instructions
{{instructions}}

The integration checklist is the "Integration" section of {{skillRoot}}/references/checklist-general.md.

## Output
Return exactly one ```json block using the integration result schema (verifications[], findings[], assessment, verifyCommands[]) described in {{skillRoot}}/references/report-format.md. Include one verification entry for every id listed above, and set duplicateOf on an entry when it describes the same defect as another listed id. Do not write or modify any files.
