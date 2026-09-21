# Self-test

An end-to-end test of the whole review: it builds a small C# and TypeScript repository with planted defects, reviews it with the real scripts, and checks the result against an answer key.

```bash
pwsh -File tests/Invoke-SelfTest.ps1
```

That is the offline run. It needs PowerShell 7 and Git, no credentials, and finishes in about 15 seconds. It runs on every push through [.github/workflows/selftest.yml](../.github/workflows/selftest.yml), on Linux and Windows.

## What it does

1. **Builds the fixture.** [fixture/New-SampleRepo.ps1](fixture/New-SampleRepo.ps1) creates a git repository with a `main` branch and a `feature/refunds` branch. The feature adds a refund endpoint to a small shop and, with it, twelve planted defects across six C# and TypeScript files, plus a lock file and a generated migration that should be skipped.
2. **Computes the change set** with `Get-PrDiff.ps1` and checks that exactly the right six files are reviewed and the right two are skipped.
3. **Runs the review** with `Invoke-PrReview.ps1`. Offline, the harness is [fixture/Invoke-ReplayHarness.ps1](fixture/Invoke-ReplayHarness.ps1), which answers each prompt from a recorded real review in [fixture/recorded](fixture/recorded). So the driver, the JSON extraction, the finding ids, the integration prompt, the merge and the report are all the real code; only the model is replaced.
4. **Checks the merged result exactly**: verdict, counts, which duplicates were folded, that no finding was lost, and two regression cases described below.
5. **Scores the findings** against [fixture/answer-key.json](fixture/answer-key.json) with [Measure-Review.ps1](Measure-Review.ps1).
6. **Checks the gate** in `blocking`, `security` and `none` mode.
7. **Repeats the merge and gate under Windows PowerShell 5.1** when it is available, and checks the result is identical.

The working directory is deleted when every check passes and kept when one fails, with its path printed, so you can open `review/report.md`, `review/prompts/` and `review/responses/`.

## The two regression cases

Both come from the first real test run of this project, and both are checked explicitly.

- **Over-merging.** Two different defects on the same line with the same category, a dictionary lookup that throws on unknown keys and a culture-sensitive `ToLower()`, were once folded into one finding, and the second one's detail and suggestion were lost. The test checks that both survive as separate findings.
- **Under-merging.** The same defect reported from a controller and from the service it calls stayed as two findings, inflating the blocking count. The test checks that the three such pairs are folded, keeping both locations.

Run against the merge script from before the fix, the self-test fails 11 of its 31 checks, and the scorer independently reports the lost culture finding as a miss.

## Live run

To measure a real model on the same fixture:

```bash
pwsh -File tests/Invoke-SelfTest.ps1 -Harness claude
pwsh -File tests/Invoke-SelfTest.ps1 -Harness copilot -Model claude-sonnet-5 -KeepWorkDir
```

This calls the model once per file and once for the integration pass, so it costs usage and takes 15 to 20 minutes. Exact counts are not checked, because a model never produces the same findings twice. It passes when:

- recall on the twelve planted defects is at least `-MinRecall`, 0.8 by default,
- nothing on the must-not-report list was reported,
- the expected files were reviewed and skipped,
- the `blocking` gate fails, as it must on a change with these defects.

The harness CLI must be signed in first; see [docs/usage.md](../docs/usage.md#the-driver-unattended).

## Scoring any review

`Measure-Review.ps1` scores any `findings.json` produced for this fixture, including one from a chat session:

```bash
pwsh -File tests/Measure-Review.ps1 -FindingsPath path/to/findings.json
```

It prints a scorecard like this and exits 0 on a pass:

```
Planted defects       12 of 12 found, recall 1.00 (minimum 0.80)
  D1   found    F7   blocking   Raw SQL built by string interpolation into FromSqlRaw
  D2   found    F14  blocking   Charge retried with no idempotency key, so a customer can be charged twice
  ...
Additional defects    6 of 6 found
Must not be reported  0 violation(s)
Files                 6 of 6 expected reviewed, 2 of 2 expected skipped
Result                PASS
```

## The answer key

[fixture/answer-key.json](fixture/answer-key.json) has four parts.

| Part | Contents |
|---|---|
| `planted` | The twelve defects built into the fixture on purpose. These decide recall. |
| `additional` | Six real defects that come with the planted ones, found by the first real run. Reported, not required. |
| `mustNotReport` | A null dereference that looks real in isolation but is unreachable because both callers return `NotFound` first. A review that reports it fails. |
| `expectedReviewed`, `expectedSkipped` | Which files the change set must send to reviewers and which it must skip. |

A key location matches a finding when the file is the same, the line ranges overlap within `lineTolerance`, and the finding's title or detail contains one of the keywords. Each finding, with the duplicates folded into it, can satisfy only one defect, so merging two different defects together costs a miss.

Keep the answer key outside the generated repository. The fixture builder never writes it into the repo, so a reviewer cannot read the answers.

## Changing the fixture or the recording

The recording in [fixture/recorded](fixture/recorded) is tied to the fixture's exact contents, because findings carry line numbers. If you change `New-SampleRepo.ps1`, record a new run:

1. Run a live self-test with `-KeepWorkDir`.
2. Copy `review/file-results.jsonl` and `review/integration-result.json` from its working directory into `fixture/recorded/`.
3. Update the exact expectations in the offline block of `Invoke-SelfTest.ps1` (counts, duplicates, the regression ids) from the new run, and check the answer key still matches.

See [fixture/recorded/README.md](fixture/recorded/README.md) for where the current recording came from.
