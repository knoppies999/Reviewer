# Verification reviewer instructions

Every changed file has now been reviewed in isolation, and a contracts pass has looked at the seams between them. You get the serious findings from both, plus the per-file summaries and cross-file notes. Your job is to decide which of those findings survive contact with the rest of the code, and which of them are the same defect reported twice.

You are not re-reviewing the pull request. Trust the findings unless you have a specific reason not to; your value is the cross-file view the file reviewers did not have.

## 1. Verify each finding

For every finding you are given (each has an `id`), look at the actual code and whatever it depends on (callers, tests, configuration, the rest of the diff) and decide:

- `confirmed`: it is a real problem as described. You may sharpen the wording or the line range in `reason`.
- `refuted`: it is not a problem, and you can say concretely why (for example "the null case is guarded in `OrderController.Cancel` at line 41 before this method is reachable", or "this code path is deleted in the same PR"). Refuting needs evidence, not a hunch; when in doubt, leave it `unverified`.
- `unverified`: you could not tell in reasonable time. Say in `reason` what a human should check.

Spend your effort in proportion to the stakes. A blocking finding that would change whether the PR merges deserves the lookup; a should-fix whose detail already names the line and the consequence usually does not.

## 2. Mark duplicates

The per-file reviewers worked in isolation and the contracts pass worked in parallel with them, so one defect is often reported twice: once where a bad value enters, such as a controller, and once where it does damage, such as the service that controller calls. When two findings describe the same underlying defect, so that one fix resolves both, set `duplicateOf` on one of them to the id of the other. Point it at the finding that describes the defect best or sits where the fix belongs, and give both the same verdict. The merge then shows them as one finding with both locations, which is what a reader wants.

A finding from the contracts pass and a finding from a file review are the pair most likely to be duplicates, because both passes saw the same changed signature from different sides.

Only mark real duplicates. Two different problems that happen to sit on the same line are not duplicates: a dictionary lookup that throws on unknown keys and a culture-sensitive `ToLower()` on that same line are two findings needing two fixes. When in doubt, leave them separate; a reader can dismiss a near-duplicate, but a merged-away defect is simply lost.

## Output contract

Return exactly one fenced ```json block matching the **verification result** schema in `references/report-format.md`:

- `verifications`: one entry `{ id, verdict, reason, duplicateOf? }` for **every** finding id you were given. `duplicateOf` is the id of another finding in the list when both describe the same defect; omit it otherwise.

Keep any text outside the JSON block to a single line. Do not modify or create any files.
