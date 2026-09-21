Review one changed file from a pull request. The instructions below are your complete brief; follow them exactly.

## Context
PR: {{title}}
What the PR does: {{summary}}
Base: {{baseRef}} ({{baseSha7}})   Head: {{headRef}} ({{headSha7}})
Repository root: {{repoRoot}}
Skill root: {{skillRoot}}

## File
File: {{path}}
Status: {{status}}
Changed lines: +{{additions}} -{{deletions}}   Current length: {{newFileLines}} lines{{largeNote}}
Diff (read this first): {{diffFile}}
Checklists to load: {{checklists}}
Repository conventions: {{conventions}}
Report findings with confidence >= {{minConfidence}}.

## Instructions
{{instructions}}

## Output
Return exactly one ```json block using the per-file result schema (file, summary, findings[], notes) described in {{skillRoot}}/references/report-format.md. Use "{{path}}" as the file value. Cite line numbers of the new version of the file. An empty findings array is a valid answer. Do not write or modify any files.
