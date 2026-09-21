# Severity, categories and confidence

## Severity

- **blocking**: merging this as it is would ship a defect a reasonable team would not accept. Incorrect behaviour on a realistic path, data loss or corruption, a security vulnerability, breaking a contract other code depends on without a migration, a crash, unbounded resource use, a broken build or test suite. The test: "If this ships, will someone have to hotfix it?"
- **should-fix**: a real problem that is not shipping-critical. Wrong only in an unlikely edge case, new behaviour without a test, a maintainability trap that will cause a bug later (captive dependency, duplicated logic that will drift), a performance problem that matters only at scale, a misleading name or API shape.
- **nit**: would improve the code; the author may reasonably decline. Readability, minor naming, a small simplification, a stale comment. Only report nits a formatter or linter would not already catch.
- **question**: you cannot tell whether it is a problem without knowledge you lack (intent, environment, data volumes). Phrase it so a human can answer in one line. Also used for important **pre-existing** issues in untouched code (category `pre-existing`).

## Categories

`bug`, `security`, `performance`, `concurrency`, `data` (persistence, migrations, serialization), `tests`, `maintainability`, `style`, `docs`, `integration` (cross-file, contract or wiring), `dependencies`, `pre-existing`.

The pipeline gate in `security` mode counts only `blocking` findings with category `security`, so use that category only for actual security impact (injection, authorization, secrets, crypto, unsafe deserialization, SSRF, XSS and the like), not for "robustness".

## Confidence

Confidence is your estimate of the probability that a competent reviewer with full context would agree this is a problem at the severity you gave it.

- **0.9 and above**: you can point to the exact input or state that triggers it.
- **0.7 to 0.9**: strong reasoning, but one link in the chain is unconfirmed (a caller you did not read, a runtime setting).
- **0.6 to 0.7**: plausible and worth a human look. The default threshold reports these.
- **below 0.6**: do not report. If it matters across files, mention it in `notes` instead.

Severity and confidence are independent. A blocking finding at 0.6 means "if I am right, this must not ship". Do not lower the severity to express doubt; lower the confidence.

## Things that are not findings

Restating the diff. "Consider …" without a concrete reason. Personal style. Anything a formatter changes. Problems in code the PR did not touch (use a `pre-existing` question if it is important). Speculation about requirements. A missing feature the PR never claimed to deliver.
