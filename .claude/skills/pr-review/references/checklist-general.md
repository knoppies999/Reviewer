# General review checklist (all languages)

Use this as a lens over the diff, not a form to fill in. Skip what does not apply; dig into what does. Each item is the question to ask; it becomes a finding only when you can point at the line and name the consequence.

## Correctness

- Does the change do what the PR says on the main path *and* on the paths the author probably did not try: empty input, null/undefined, zero, negative, very large, duplicates, unicode, concurrent callers?
- Off-by-one, inclusive vs exclusive ranges, comparison in the wrong direction, inverted boolean, operator precedence, integer division, floating-point equality.
- Copy-paste drift: near-duplicate blocks where one was updated and the other was not.
- State: is something mutated that a caller still holds (a shared list, a cached object, a static)? Is state changed before validation passes, or before the operation that can fail?
- Early returns and exceptions: does every exit path release or roll back what was acquired?
- Time: timezone assumptions, local vs UTC, DST, month arithmetic, comparing dates of different precision.
- Removed code: did anything depend on the deleted behaviour (a side effect, an ordering, a default)?

## Error handling

- Errors swallowed (empty catch, log-and-continue on a path that should stop), or turned into a misleading success.
- Catching too broadly and hiding programming errors; rethrowing in a way that loses the stack or the original error.
- Retries: bounded, backed off, and only for transient failures? Is the retried operation idempotent?
- Partial failure: a loop that fails on item 5 of 10. What state is left behind, and does the caller learn about it?
- User-facing messages that leak internals (stack traces, connection strings, file paths).

## Security

- Untrusted input reaching: SQL/NoSQL/LDAP queries, OS commands, file paths (traversal), URLs (SSRF, open redirect), HTML (XSS), log lines (log injection), deserializers, regular expressions (catastrophic backtracking), format strings.
- Authorization: is the check on every new endpoint or handler, and does it check the *resource* (this user's order) rather than only "is logged in"? Mass assignment / over-posting on models bound from requests.
- Secrets or tokens in code, config, tests, logs, URLs or error messages. New dependencies from unknown sources.
- Crypto: home-made hashing or encryption, weak algorithms, static IVs or salts, secrets compared with `==`.
- Anything that widens a permission, disables a validation, relaxes CORS/CSP/TLS, or adds an "allow all" default.

## Concurrency and resources

- Shared mutable state without synchronization; check-then-act races; non-thread-safe collections used concurrently.
- Locks held across I/O or awaits, taken in inconsistent order, or protecting the wrong thing.
- Resource lifetime: handles, connections, streams, timers, subscriptions, event handlers. Every acquire has a release on every path.
- Unbounded growth: caches without eviction, queues without limits, lists that only grow, recursion without a floor.

## Performance (only when it plausibly matters)

- N+1 queries, queries inside loops, fetching whole tables to filter in memory, missing pagination.
- Blocking calls in async or request paths; repeated expensive work that could be computed once; unnecessary serialization.
- Hot-path allocations or string building in loops; quadratic behaviour over inputs that can be large.

## Data and persistence

- Schema or migration changes: reversible? Compatible with the currently deployed code during rollout? Defaults for existing rows? Indexes for the new query patterns?
- Serialization contracts: renamed or removed fields that stored data or another service still uses; enum values reordered.
- Transactions: multi-step writes that must be atomic but are not; long transactions holding locks.

## Tests

- New behaviour without tests; changed behaviour with tests edited to match rather than to verify; deleted tests.
- Tests that cannot fail (no assertion, asserting on the mock), tests coupled to implementation details, flaky ingredients (real time, real network, shared static state, order dependence).
- Does the test name still describe what is tested?

## Configuration, dependencies, build

- New config keys: safe default, documented, present in every environment's configuration and pipeline variables?
- Dependency changes: major version bumps, lock file consistency, licences, transitive risk; removed packages still referenced?
- Build or CI changes that weaken checks (skipped tests, disabled analyzers, suppressed warnings).

## Leftovers

- Debug output, commented-out code, TODO/FIXME without an owner or ticket, temporary flags, hard-coded local paths, disabled lint rules, merge-conflict markers, unused imports/variables/parameters introduced by the change.

## Readability (light touch; nits at most)

- Names that lie or are too generic for their scope; functions doing several unrelated things; deep nesting where an early return would do; comments that explain *what* instead of *why*, or that no longer match the code.
- Documentation for new public surface.

## Integration (for the whole-PR pass)

- Every changed or removed signature, interface, type, enum, route, event, message, config key, environment variable or feature flag: find all consumers (other projects, tests, front end, scripts, infrastructure code, docs). Updated in this PR, or backward compatible?
- Back end and front end contracts: C# DTO, enum and route changes mirrored in TypeScript types and clients, and vice versa; serialization casing and nullability.
- Wiring: DI registrations for new services, endpoint mapping, middleware order, background jobs, migrations for model changes, feature flags read where they are set.
- Deleted or renamed files: nothing still references them (project files, imports, build scripts, docs, configuration).
- Consistency across files: the same concept done two ways; duplicated constants; different error or logging conventions in sibling code.
- Test delta vs production delta; PR description vs what actually changed (missing pieces, unexpected extras).
