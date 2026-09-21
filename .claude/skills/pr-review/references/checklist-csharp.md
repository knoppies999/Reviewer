# C# / .NET checklist

Applies to `.cs`, `.razor`, `.cshtml` and related files. Read [checklist-general.md](./checklist-general.md) as well; this file only adds the .NET-specific traps.

## Async and threading

- `async void` anywhere except event handlers. `.Result`, `.Wait()` or `.GetAwaiter().GetResult()` on a request path (deadlocks under synchronization contexts, thread-pool starvation under load).
- A `Task` created but neither awaited nor returned (fire-and-forget: exceptions vanish, work dies with the request). `return SomethingAsync()` inside a `using` or `try` block disposes before the task finishes.
- `CancellationToken` accepted but not passed on to the calls that actually wait; new async APIs without a token parameter.
- `Task.Run` in ASP.NET Core to "make it async"; `Parallel.ForEach` or `Task.WhenAll` over a `DbContext` or other non-thread-safe object.
- `ConfigureAwait(false)` missing in library code meant to be context-free; a `SemaphoreSlim` acquired without a `try/finally` release.
- `async` lambdas passed where a `Task` is not observed (`List<T>.ForEach`, `Select` without `WhenAll`, event handlers).

## Disposal and lifetimes

- `IDisposable` / `IAsyncDisposable` created without `using` / `await using` (streams, `HttpResponseMessage`, `DbContext`, connections, timers, `CancellationTokenSource`).
- `new HttpClient()` per call (socket exhaustion) instead of `IHttpClientFactory` or a typed client; a shared `HttpClient` whose `BaseAddress` or headers are mutated per request.
- DI lifetimes: a singleton capturing a scoped or transient dependency (captive dependency); a `DbContext` used from a singleton or a hosted service without creating a scope; `IServiceProvider` used as a service locator.
- Static mutable state; static caches without invalidation; `DateTime.Now`, `Random` or `Guid.NewGuid()` inside domain logic where a clock or generator should be injected (untestable, timezone-dependent).

## Nullability and types

- Nullable reference types: `!` used to silence a warning where the value really can be null; `?.` chains that turn a bug into a silent no-op; `FirstOrDefault()` dereferenced; `default` for reference types.
- Public API nullability changed (`string` to `string?` or back) without updating consumers; `int` where `long` or `decimal` belongs (ids, money); `double` for money.
- Culture: `ToString()` / `Parse` on numbers and dates without `CultureInfo.InvariantCulture`; `ToLower()` for keys instead of `ToLowerInvariant()` or `StringComparison.OrdinalIgnoreCase`.
- Records and structs: mutable structs; equality semantics changed by switching class to record; `with` on records that hold collections (shallow copy).
- Enums: new members inserted in the middle (breaks persisted integers); `switch` without a default that throws on unknown values; `Enum.Parse` on user input instead of `TryParse`.

## Exceptions

- `throw ex;` instead of `throw;` (stack lost). `catch (Exception)` that swallows or logs and continues on a path that must stop. Exceptions as control flow on hot paths.
- Specific exception types replaced by broad catches. `OperationCanceledException` treated as an error and retried.
- Custom exceptions that drop the message or inner exception.

## LINQ and collections

- Multiple enumeration of an `IEnumerable<T>` (especially one wrapping a query or generator); materialize once when reused.
- `Count() > 0` instead of `Any()`; `Where(...).First()` on large lists inside loops; `OrderBy(...).First()` instead of `MinBy` / `MaxBy`.
- Mutating a collection while enumerating it. Exposing `List<T>` where `IReadOnlyList<T>` was intended.
- Dictionary indexer on a missing key; `ContainsKey` followed by the indexer instead of `TryGetValue`; plain `Dictionary` shared across threads.

## Entity Framework Core and data access

- Query evaluated in memory: `ToList()` / `AsEnumerable()` before `Where`, or a method EF cannot translate.
- N+1: per-item queries in a loop, lazy loading, missing `Include` or projection; loading whole entities to read one column.
- Tracking: read-only queries without `AsNoTracking()`; `Update()` on an already tracked entity; detached graphs re-attached with duplicate keys.
- `SaveChanges` inside a loop; several `SaveChanges` calls that must be atomic without a transaction; `SaveChangesAsync` without the cancellation token.
- Raw SQL with string interpolation (`FromSqlRaw($"...")`, `ExecuteSqlRaw`) instead of `FromSqlInterpolated` or parameters: injection.
- Migrations: model changed without a migration; a migration edited after it may have been applied elsewhere; destructive migration (drop column or table) without a backfill or rollout plan; missing index for a new filter or join column; snapshot inconsistent with the migrations.
- `DateTime` columns: `Kind` assumptions (UTC vs unspecified); `DateTimeOffset` and `DateTime` mixed.

## ASP.NET Core

- New endpoint, controller or handler without `[Authorize]` or a policy, or authorized by role only when the resource needs an ownership check; `[AllowAnonymous]` added.
- Model binding: `[FromBody]` on entity types (over-posting); model validation not enforced before use; `[ApiController]` behaviours changed.
- Wrong status codes or return types (`Ok(null)` for not found, exceptions for expected outcomes); `ProducesResponseType` out of date.
- Middleware order changes (authentication before routing, exception handler position); `AllowAnyOrigin` combined with credentials; anti-forgery removed on forms.
- Reading `Request.Body` twice without buffering; uploads without size limits; `HttpContext` captured in a background task.
- Options: `IOptions` where `IOptionsSnapshot` / `IOptionsMonitor` is needed for reloadable settings; secrets committed in `appsettings*.json`.
- Blazor / Razor: async work in `OnInitialized` instead of `OnInitializedAsync`; `StateHasChanged` from a non-UI thread; event handlers that are `async void`.

## Logging and diagnostics

- String interpolation in log calls (`LogInformation($"...")`) instead of message templates: loses structure and allocates even when the level is off.
- Logging PII or secrets; `LogError` for expected conditions or `LogDebug` for real failures; exceptions logged without the exception object.

## Tests (xUnit / NUnit / MSTest)

- `async void` tests; tests that await nothing; `Task.Delay` used to wait for background work; `DateTime.Now` in assertions.
- Shared static fixtures mutated across tests; a failing test renamed or removed instead of fixed; assertions on mock internals instead of outcomes.
- EF InMemory provider used to test behaviour that differs from SQL (case sensitivity, `Include`, transactions, raw SQL).

## Style that matters (nits, only when not enforced by an analyzer or `.editorconfig` in the repo)

- `var` vs explicit types, expression-bodied members, file-scoped namespaces, pattern matching: mention only when the change is inconsistent with the surrounding file.
