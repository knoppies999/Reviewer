Review the changed file or files below, from a pull request. The instructions are your complete brief; follow them exactly.

Everything you need is already in this prompt: the diffs, the current contents of the files and the checklists are all included. Do not re-open them. Spend your tool calls only on questions this prompt cannot answer, such as how a changed signature is called elsewhere.

## Context
PR: {{title}}
What the PR does: {{summary}}
Base: {{baseRef}} ({{baseSha7}})   Head: {{headRef}} ({{headSha7}})
Repository root: {{repoRoot}}
Skill root: {{skillRoot}}
Repository conventions: {{conventions}}
Report findings with confidence >= {{minConfidence}}.

{{fileSections}}

## Checklists
{{checklistBlock}}

## Instructions
{{instructions}}

## Output
Return exactly one ```json block and nothing else of substance.

- For a single file, use the **per-file result** schema (`file`, `summary`, `findings[]`, `notes`) described in {{skillRoot}}/references/report-format.md.
- For more than one file, use `{ "results": [ ... ] }`, holding one such object per file above, in the same order.

Use the exact path from each `File:` line as the `file` value. Cite line numbers of the **new** version of the file. An empty `findings` array is a valid answer. Do not write or modify any files.
