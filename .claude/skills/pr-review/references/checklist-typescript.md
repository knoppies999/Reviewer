# TypeScript / JavaScript checklist

Applies to `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs`, `.vue` and `.svelte`. Read [checklist-general.md](./checklist-general.md) as well; this file adds the TypeScript/JavaScript-specific traps. Framework sections apply only where the repository uses that framework.

## Promises and async

- A promise created but not awaited or returned (unhandled rejection; work continues after the response was sent). `async` callbacks inside `forEach` or `map` without `Promise.all`; `Promise.all` where one failure should not discard the rest (`allSettled`).
- `await` inside a loop over independent calls (sequential when it could be parallel), or `Promise.all` over hundreds of calls with no concurrency limit.
- `try/catch` around an un-awaited promise (catches nothing); `.then` chains without `.catch`; async functions handed to event emitters or timers that swallow rejections.
- Fetches without timeouts or `AbortController`; unbounded retries; retries of non-idempotent calls.

## Types

- `any` introduced (explicitly, via `as any`, untyped JSON, or `Record<string, any>`); `as T` casts where a type guard belongs; non-null assertions `!` where the value can be undefined at runtime.
- Optional chaining `?.` that silently turns a missing value into `undefined` and lets the flow continue; `||` for defaults where `??` is meant (`0`, `''` and `false` are valid values).
- Discriminated unions and enums: `switch` without an exhaustiveness check (`never`); string literals where the union type exists; enum values reordered or renamed while persisted or serialized.
- Shared API or DTO types changed in a way that breaks consumers (removed optional fields, widened to `string`, changed nullability), especially types mirrored from the C# back end.
- `@ts-ignore`, `@ts-expect-error` or `eslint-disable` added; `tsconfig` strictness reduced.

## Runtime and data

- Mutation of inputs, props, state or module-level objects (`sort`, `reverse`, `splice` in place; `Object.assign` onto a shared object); shallow copies where nested data changes.
- `==` vs `===`; `typeof x === 'object'` with `null`; `for…in` over arrays; accidental string concatenation with `+`.
- Numbers: floating-point money math; `parseInt` without a radix; `Number()` on user input; `JSON.parse` without `try/catch` or validation; big integers through JSON.
- Dates: `new Date(string)` with non-ISO input; local vs UTC; zero-based `getMonth()`; mutation through `setX`.
- Regular expressions: user input in `new RegExp` without escaping; nested quantifiers (ReDoS); the `g` flag with `test()` (stateful `lastIndex`).
- Node: user input in `child_process` or `exec`; file paths joined with user input (traversal); `eval` or `new Function`; prototype pollution through deep merges of untrusted objects; `process.env` read at import time in code that also runs in the browser bundle.
- Browser: `innerHTML` or `dangerouslySetInnerHTML` with untrusted content; secrets in `localStorage`; `window.location` assigned from a parameter (open redirect); `postMessage` without an origin check.

## React (if used)

- Hooks: missing or wrong dependency arrays (stale closures); effects without cleanup (subscriptions, timers, abort); effects used to compute derived state; hooks called conditionally or in loops; state updates after unmount.
- Keys: array index as key on reorderable lists; duplicate keys.
- Rendering: expensive work in render that visibly matters without `useMemo`; new object or function identities passed to memoized children every render; context values recreated each render.
- Inputs: controlled/uncontrolled switches; `value` without `onChange`.
- Data fetching: stale responses applied after props changed; missing loading and error states; fetching in render.

## Angular (if used)

- Subscriptions without `unsubscribe`, `takeUntilDestroyed` or the `async` pipe; nested subscribes instead of operators.
- Change detection: arrays or objects mutated under `OnPush`; functions called in template bindings; `ngFor` without `trackBy` on large lists.
- Services: `providedIn` scope changes; HTTP calls without error handling; interceptor order.

## Vue / Svelte (if used)

- Reactivity broken by replacing reactive objects or mutating nested state outside the store; watchers without cleanup; `v-html` with untrusted content; missing `key` on `v-for`.

## Modules and dependencies

- Importing a whole library for one function (bundle size); circular imports introduced; side-effect imports removed; default vs named export mismatches.
- `package.json`: a new dependency for something already available; major version bumps; `^`/`~` ranges inconsistent with the repo; lock file out of sync; a dev dependency used at runtime.
- Environment-specific code (`process.env.NODE_ENV`, `window`) in shared modules; `.env` files with secrets committed.

## Tests (Jest / Vitest / Playwright / Cypress)

- Async tests that neither `await` nor return the promise (pass vacuously); `done` callbacks mixed with async code; `expect` inside a callback that never runs.
- Over-mocking (asserting the mock was called instead of the outcome); mocking the module under test; snapshots of large trees (noise); `test.only` or `describe.skip` left behind.
- Timers and dates: real waits instead of fake timers; `Date.now()` in assertions.
- End-to-end: selectors tied to styling classes; arbitrary sleeps; tests depending on shared data or order.

## Style that matters (nits, only when not enforced by ESLint or Prettier in the repo)

- `let` where `const` works; `function` vs arrow style inconsistent with the file; `console.log` leftovers; magic numbers or strings where a named constant exists nearby.
