# Recorded review

A real review of the self-test fixture, replayed by `Invoke-ReplayHarness.ps1` so the offline self-test exercises the full pipeline without calling a model.

| File | Contents |
|---|---|
| `file-results.jsonl` | One line per reviewed file: the JSON each per-file reviewer returned, 25 findings in total. |
| `integration-result.json` | The integration pass: 25 verifications, 6 new cross-file findings and the assessment. |

## Provenance

Recorded on 2026-09-21 by running the skill interactively in Claude Code. Each of the six changed files was reviewed by its own fresh `general-purpose` subagent from the prompt the driver generates, and one further subagent ran the integration pass. The model was Claude Opus 5.

The outputs are stored as returned, re-serialised to one compact line per file with non-ASCII characters escaped. There is one deliberate addition: the `duplicateOf` field did not exist when this run was recorded, and the integration pass stated its three duplicates in prose instead ("F16 is the same defect as F1, in the service layer", and likewise F17 of F3 and F20 of F4). Those three links were added as `duplicateOf` on F16, F17 and F20 so the recording matches the current schema. Nothing else was edited.

## What it shows

Against the answer key, this run found all twelve planted defects and all six additional ones, did not report the unreachable null dereference, and the integration pass corrected five of the per-file reviewers' claims with evidence it gathered itself. It confirmed 20 findings, left 5 unverified because they depend on files the fixture does not contain, and refuted none.
