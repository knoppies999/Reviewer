# Result, findings and report formats

Every review produces the same files in the output directory (`.pr-review/` for local runs, the artifact staging directory on a pipeline), whether the interactive skill or the driver script ran it:

| File | Written by | Purpose |
|---|---|---|
| `manifest.json`, `full.diff`, `diffs/*.diff` | `Get-PrDiff.ps1` | The change set. |
| `file-results.jsonl` | orchestrator or driver | One per-file result per line, exactly as the reviewer returned it (plus `file`). A batched call is split into one line per file. |
| `integration-result.json` | orchestrator or driver | The contracts result and the verification result, combined into one object. Absent when neither pass ran. |
| `findings.json` | `Merge-ReviewResults.ps1` | Machine-readable source of truth; the gate and the PR comment script read it. |
| `report.md` | `Merge-ReviewResults.ps1` | Human-readable rendering of `findings.json`; printed in chat and posted to the PR. |

## Vocabulary

| Field | Values |
|---|---|
| `severity` | `blocking`, `should-fix`, `nit`, `question` |
| `category` | `bug`, `security`, `performance`, `concurrency`, `data`, `tests`, `maintainability`, `style`, `docs`, `integration`, `dependencies`, `pre-existing` |
| `verification` | `confirmed`, `refuted`, `unverified`, `not-checked` |
| `source` | `file-review`, `integration` |
| `verdict` | `approve`, `approve-with-comments`, `request-changes`, `incomplete` (nothing could be reviewed) |

`line` and `endLine` always refer to the **new** version of the file. `confidence` is 0 to 1. `title` is at most 80 characters and names the problem, not the fix. `detail` explains the trigger and the consequence. `suggestion` is concrete or omitted. Paths are relative to the repository root with forward slashes.

## Per-file result (returned by the file reviewer)

```json
{
  "file": "src/Orders/OrderService.cs",
  "summary": "Adds a retry around the payment call and changes CancelOrder to return the cancelled order.",
  "findings": [
    {
      "line": 88,
      "endLine": 94,
      "severity": "blocking",
      "category": "bug",
      "title": "Retry loop can charge the card twice on timeout",
      "detail": "A timeout after the provider accepted the charge is retried without an idempotency key, so a slow provider double-charges. The catch at line 90 treats TaskCanceledException like a transport failure.",
      "suggestion": "Pass the order id as the idempotency key to _payments.ChargeAsync and retry only when the provider reports the charge was not created.",
      "confidence": 0.85
    }
  ],
  "notes": "CancelOrder's return type changed from void to Order; callers are not visible from this file."
}
```

When a call covers several small files, the reviewer returns `{ "results": [ … ] }` holding one such object per file, in the order the prompt listed them; the orchestrator splits it back into one line per file. In `file-results.jsonl` each line is one per-file object. A reviewer that failed is recorded as `{ "file": "<path>", "error": "<what happened>" }`, one line per file in the failed call.

## Finding ids

Ids are assigned in a fixed order so that the verification pass and the merge script agree: walk the manifest's `files` in order, and for each file with `reviewMode: review` walk its result's `findings` in order, numbering `F1`, `F2`, … The contracts pass's findings continue the sequence afterwards, in the order it returned them. The orchestrator applies the same rule when it builds the verification prompt, so `duplicateOf` can point from a file finding to a contracts finding and the merge will agree about which id is which.

## Contracts result (returned by the contracts reviewer)

This pass runs alongside the per-file reviews, so it has no findings to verify and returns none of its own verdicts.

```json
{
  "findings": [
    {
      "file": "src/Web/ClientApp/src/api/orders.ts",
      "line": 12,
      "severity": "blocking",
      "category": "integration",
      "title": "cancelOrder() still expects an empty response",
      "detail": "The C# endpoint now returns the Order DTO, but the TypeScript client types the response as void and the caller in OrderPage.tsx never reads it, so the UI keeps showing the stale status.",
      "suggestion": "Change the return type to Promise<Order> and update OrderPage to use the returned status.",
      "confidence": 0.9
    }
  ],
  "assessment": "The PR adds retries to payment capture and returns the cancelled order from CancelOrder. The retry is unsafe without idempotency, and the API contract change is not mirrored in the front end. Otherwise the change is small and well tested.",
  "verifyCommands": [
    { "command": "dotnet build --no-restore", "exitCode": 0, "summary": "Build succeeded, 0 warnings." }
  ]
}
```

## Verification result (returned by the verification reviewer)

This pass runs last, once every file review and the contracts pass have finished. It gets the `blocking` and `should-fix` findings from both, already carrying the ids above, and returns only verdicts.

```json
{
  "verifications": [
    { "id": "F1", "verdict": "confirmed", "reason": "ChargeAsync has no idempotency parameter and the provider SDK documents timeouts as ambiguous." },
    { "id": "F3", "verdict": "refuted", "reason": "The null case is guarded in OrderController.Cancel at line 41 before this method is reachable." },
    { "id": "F5", "verdict": "confirmed", "reason": "Same defect as F1, seen from the gateway that OrderService calls.", "duplicateOf": "F1" }
  ]
}
```

## `integration-result.json`

The orchestrator writes the two results into one file, which is what the merge reads:

```json
{
  "verifications": [ "…from the verification pass…" ],
  "findings": [ "…from the contracts pass…" ],
  "assessment": "…from the contracts pass…",
  "verifyCommands": [ "…from the contracts pass…" ]
}
```

A pass that did not run leaves its part empty; the merge then treats the affected findings as `unverified` and says so in the report.

## Merge rules (implemented by `Merge-ReviewResults.ps1`)

1. Findings below `minConfidence` are dropped.
2. Verifications are applied to `blocking` and `should-fix` findings: `refuted` ones move to the `refuted` array and do not count; `confirmed` stay; anything not addressed, or everything when the verification pass did not run, becomes `unverified`. Nits and questions stay `not-checked`.
3. Duplicates are folded into one finding, in two passes:
   - **Declared.** A verification with `duplicateOf` folds that finding into the target, following chains and ignoring cycles and targets that did not survive steps 1 and 2. This is the only way findings in different files are merged.
   - **Undeclared.** As a safety net, two findings are also folded when they share file and category, their line ranges overlap, **and** their titles are similar (Jaccard similarity of 0.5 or more on title words). Two different defects on one line stay separate.

   The kept finding takes the more severe severity, the higher confidence and the stronger verification of the group, and lists every folded finding under `duplicates` with its id, file, lines, severity, title and source. Nothing is discarded.
4. Contracts findings are appended with `source: "integration"`.
5. Verdict: `request-changes` if any counted `blocking` finding remains (unverified ones count), else `approve-with-comments` if any `should-fix`, else `approve`. When no reviewable file produced a result the verdict is `incomplete`; whenever any reviewable file failed, `incomplete: true` is set alongside the verdict.
6. Coverage lists every manifest file as reviewed, skipped (with reason), deleted, or failed.

## `findings.json`

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-16T10:12:00Z",
  "target": {
    "pullRequestId": 123,
    "title": "Add retries to payment capture",
    "url": "https://dev.azure.com/org/project/_git/repo/pullrequest/123",
    "repository": "repo",
    "base": "develop",
    "baseSha": "a1b2c3d",
    "head": "feature/payment-retries",
    "headSha": "e4f5a6b"
  },
  "verdict": "request-changes",
  "summary": "1 blocking, 2 should-fix, 3 nits across 7 files.",
  "assessment": "…from the integration pass…",
  "counts": { "blocking": 1, "should-fix": 2, "nit": 3, "question": 0, "refuted": 1 },
  "findings": [
    {
      "id": "F1",
      "file": "src/Orders/OrderService.cs",
      "line": 88,
      "endLine": 94,
      "severity": "blocking",
      "category": "bug",
      "title": "Retry loop can charge the card twice on timeout",
      "detail": "…",
      "suggestion": "…",
      "confidence": 0.85,
      "source": "file-review",
      "verification": "confirmed",
      "verificationReason": "…",
      "duplicates": [
        { "id": "F5", "file": "src/Payments/PaymentGateway.cs", "line": 40, "endLine": 44, "severity": "blocking", "title": "Capture is retried without an idempotency key", "source": "file-review" }
      ]
    }
  ],
  "refuted": [],
  "coverage": {
    "reviewed": ["src/Orders/OrderService.cs"],
    "skipped": [{ "file": "src/Web/ClientApp/package-lock.json", "reason": "matches skip pattern **/package-lock.json" }],
    "deleted": ["src/Orders/LegacyRetry.cs"],
    "failed": []
  },
  "notes": [{ "file": "src/Orders/OrderService.cs", "note": "…" }],
  "verifyCommands": [],
  "integrationPassRan": true
}
```

The gate script counts a finding when its severity is `blocking` and its verification is not `refuted` (and, in `security` mode, its category is `security`). It also fails when the review is incomplete (any failed file, or verdict `incomplete`) unless `failOnIncomplete` is false in `config.json` or the gate is `none`.

## `report.md`

```markdown
# PR review: <title>

**Verdict:** <Request changes | Approve with comments | Approve> · **Base:** `<base>` ← **Head:** `<head>` · <n> files reviewed, <m> skipped, <k> deleted

<assessment paragraph from the integration pass>

## Blocking (<n>)

### F1 · `src/Orders/OrderService.cs:88-94` · bug · confidence 0.85 · confirmed
<detail>
**Suggestion:** <suggestion>

_Also reported as F5 at `src/Payments/PaymentGateway.cs:40-44`._

## Should fix (<n>)

### F2 · `path:line` · category · confidence · verification
…

## Nits (<n>)
- `path:line` · <title>. <detail>

## Questions (<n>)
- `path:line` · <title>. <detail>

## Integration notes
<verify command results and the file reviewers' cross-file notes, one line each>

## Coverage
**Reviewed:** `a.cs`, `b.ts` … · **Skipped:** `package-lock.json` (skip pattern) … · **Deleted:** `old.cs` · **Failed:** none

<details><summary>Refuted during verification (<n>)</summary>

- `path:line` · <title> — <verification reason>

</details>

_Generated by the pr-review skill: a subagent per changed file (files with tiny diffs share one), a contracts pass alongside them, and a verification pass after. Findings marked "unverified" need a human look._
```

Verdict and blocking findings first; one heading per blocking and should-fix finding; nits and questions as single bullet lines; "None" under Blocking when empty; other empty sections omitted.
