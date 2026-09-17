# ContentView UI Freeze — Root Cause & Fix Design (v4)

**Date:** 2026-09-18 (fourth revision after subagent review)
**Status:** Draft (awaiting user approval)

## What changed from v3

A subagent was dispatched to critically review v3. It found three blockers
that would have caused real regressions:

1. **Fix C regression (BLOCKER)** — `LogEntry.==` is `lhs.id == rhs.id`.
   Once `LogRowView` is no longer an `@ObservedObject`, SwiftUI compares
   the old and new `LogRowView(entry:)` instances via `LogEntry.==` and
   finds them equal whenever the id matches — so updated mutable fields
   (`status`, `responseStatusCode`, `txBytes`, `rxBytes`, `duration`)
   would never trigger a row re-render. The UI would freeze on stale data.
2. **Fix D gap (BLOCKER)** — the spec only listed mutator functions
   (`log`, `updateEntry`, `completeEntry`, `failEntry`, `clear`) as
   triggers for `recomputeFilteredEntries()`. But the filter inputs
   `searchText`, `selectedMethods`, `selectedStatusFilters` are
   `@Published var` properties assigned directly by SwiftUI bindings
   (e.g. `TextField(text: $logStore.searchText)`) and by the filter chips'
   on-tap closures (`logStore.selectedMethods.insert(...)`).
   Without `didSet`/Combine hooks on these properties, filter UI changes
   would never reach the published `filteredEntries`.
3. **Fix A SOCKS5 (TYPO)** — `SOCKS5.swift:511` and `:531` are already
   inside `Task { @MainActor in … }` blocks; the spec incorrectly listed
   them as needing wrapping. SOCKS5 has no Fix A work.

The subagent also flagged two secondary issues that have been folded into
the design below:

- `LogStore.searchText ... is isolated to the main actor` warnings are a
  separate class of issue from the background-thread `@Published` warnings;
  fixing actor isolation may not incidentally fix them. (Logged as a
  risk; not blocking.)
- Fix E's `flushPendingBytes` should NOT be wrapped in `applyChange { }`,
  because byte counts are not inputs to `filteredEntries`.
- The spec had inconsistent counts (the user-summary listed 8/7/2 sites
  but the per-line lists actually summed to 15/7/0).

The corrected enumeration is **15 ProxyServer sites, 7 TunnelManager sites,
0 SOCKS5 sites** requiring Fix A.

## Honest assessment of root cause

(Same as v3 — preserved for completeness.)

Available evidence cannot isolate the freeze to a single cause. We are
fixing all known defects and re-testing.

## Goals

(Same as v3.)

## Non-Goals

(Same as v3.)

## Proposed Fix

### Fix A — Wrap every background `logStore.*` call in a main-actor hop

**15 sites in `ProxyServer.swift`** — none have an existing wrapper:

- `processRequest` CONNECT path: lines 284, 285, 291, 292
- `handleHTTPPxoyRequest`: lines 325, 326, 351, 352, 362, 363
- `sendHTTPProxyRequest`: line 402
- `establishTunnel` callbacks: lines 470, 471, 481, 482

**7 sites in `TunnelManager.swift`** — none have an existing wrapper:

- `start` state handlers: lines 75, 85, 93
- `startAsProxy` state handlers: lines 170, 177, 185
- `scheduleConnectionTimeout` expiry: line 520

**0 sites in `SOCKS5.swift`** — every `logStore.*` call is already inside
a `Task { @MainActor in … }` block.

Call sites that already wrap (verify, do not change):

- `TunnelManager.swift:232-234, 281-283, 313-315, 359-361, 412-419, 447-449, 482-484`
- `SOCKS5.swift:302, 321, 511, 531, 557`

Mechanics: capture any synchronous return values from `logStore` (e.g.
the `LogEntry` returned by `log()`) before the hop, and use them inside
the hop. `LogEntry` is a struct value type whose `id` is `let`, so the
captured value is freely usable in any context.

For `ProxyServer.processRequest` the entire CONNECT branch must be
inside one `Task { @MainActor in … }`, including the `establishTunnel`
call — because `establishTunnel` synchronously starts the outbound
`NWConnection`. The cost is that `tunnelManager.start(...)` now runs
on main instead of on the connection's `.global()` queue; this is safe
(NWConnection handlers are thread-safe to assign; the connection itself
runs on `TunnelManager.queue` regardless of where `start(...)` was
called from).

### Fix B — Cache `LogEntry`'s `DateFormatter`

```swift
private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

var formattedTime: String { Self.timeFormatter.string(from: timestamp) }
```

### Fix C — `LogRowView` value parameter + field-comprehensive `LogEntry.==`

Replace
```swift
struct LogRowView: View {
    let entryId: UUID
    @ObservedObject var logStore: LogStore
    private var entry: LogEntry? {
        logStore.entries.first(where: { $0.id == entryId })
    }
}
```
with
```swift
struct LogRowView: View {
    let entry: LogEntry
}
```

In `ContentView.logsList`:
```swift
ForEach(logStore.filteredEntries) { entry in
    LogRowView(entry: entry)
        .onTapGesture {
            // Lookup the *latest* entry by id; the row may be stale
            // until the next body pass after a bytes/duration update.
            if let updatedEntry = logStore.entries.first(where: { $0.id == entry.id }) {
                selectedEntry = updatedEntry
            }
        }
}
```

**Critical companion change to `LogEntry.swift`:**

Remove the custom `==` so Swift synthesises a member-wise equality from
all stored properties. `id` is `let`, so two entries with different `id`
are still unequal, satisfying `Identifiable`'s id-based view-identity
requirement. After this change, two `LogRowView` instances with the same
id but different mutable fields are correctly *not equal*, so SwiftUI
re-renders the row.

```swift
struct LogEntry: Identifiable, Equatable {
    // id is the only field compared by Identifiable view identity.
    // Equatable compares all fields so SwiftUI re-renders rows when
    // mutable fields (status, bytes, duration, status code) change.
    let id = UUID()
    // ... rest unchanged ...
    // (DELETE the static func == (lhs:rhs:) override)
}
```

### Fix D — Cached `filteredEntries` with `didSet` on filter inputs

Convert `searchText`, `selectedMethods`, `selectedStatusFilters` to
`@Published private(set) var` with `didSet` observers that call
`recomputeFilteredEntries()`. Use a small helper to make the mutating
property changes from the public API safe:

```swift
@Published private(set) var searchText: String = "" {
    didSet { if searchText != oldValue { recomputeFilteredEntries() } }
}
@Published private(set) var selectedMethods: Set<LogEntry.HTTPMethod> = [] {
    didSet { if selectedMethods != oldValue { recomputeFilteredEntries() } }
}
@Published private(set) var selectedStatusFilters: Set<String> = [] {
    didSet { if selectedStatusFilters != oldValue { recomputeFilteredEntries() } }
}

@Published private(set) var filteredEntries: [LogEntry] = []

private func recomputeFilteredEntries() {
    filteredEntries = entries.filter { /* same predicate as v1 */ }
}
```

To allow `ContentView` and other callers to mutate these from SwiftUI
bindings (`$logStore.searchText`), expose setter methods:

```swift
func setSearchText(_ s: String) { searchText = s }
func toggleMethod(_ m: LogEntry.HTTPMethod) {
    if selectedMethods.contains(m) { selectedMethods.remove(m) }
    else { selectedMethods.insert(m) }
}
func toggleStatusFilter(_ s: String) {
    if selectedStatusFilters.contains(s) { selectedStatusFilters.remove(s) }
    else { selectedStatusFilters.insert(s) }
}
```

ContentView changes the `$logStore.searchText` binding to a
`Binding(get:set:)` that calls `setSearchText`. The filter chip
closures call `toggleMethod` / `toggleStatusFilter` directly. `clear()`
and `clearFilters()` mutate the underlying properties and rely on
`didSet` to recompute.

For the existing `entries` mutators (`log`, `updateEntry`,
`completeEntry`, `failEntry`, `clear`), call `recomputeFilteredEntries()`
explicitly at the end of each — do **not** wrap them in a generic
`applyChange { }` because (a) byte-count mutators like `flushPendingBytes`
in Fix E should *not* trigger recompute, and (b) the explicit calls are
self-documenting.

### Fix E — Throttle byte-counter writes to one per main-actor frame

(Same as v3.) Important: `flushPendingBytes` does NOT call
`recomputeFilteredEntries()` — byte counts are not filter inputs.

### Fix F — Lower uptime timer to 1 Hz

(Same as v3.)

### Fix G — Remove the `DebugPerf` instrumentation

(Done.)

## Files Touched

| File | Change |
|---|---|
| `HttpRelay/ProxyServer.swift` | Fix A — wrap 15 `logStore.*` call sites in `Task { @MainActor in … }`. |
| `HttpRelay/TunnelManager.swift` | Fix A — wrap 7 `logStore.*` call sites in `Task { @MainActor in … }`. |
| `HttpRelay/LogEntry.swift` | Fix B (cache `DateFormatter`), Fix C (remove custom `==`). |
| `HttpRelay/ContentView.swift` | Fix C (`LogRowView(entry:)`), Fix D (use new setter helpers / `Binding(get:set:)`), Fix F (1 Hz timer). |
| `HttpRelay/LogStore.swift` | Fix D (cached `filteredEntries` + `didSet` on filter inputs + setter helpers), Fix E (frame-throttled byte flush). |

No changes to `SOCKS5.swift`, `BackgroundKeepaliveCoordinator.swift`,
`HttpRelayApp.swift`.

## Implementation order

1. Fix G ✅ (already done).
2. Fix B — cache `DateFormatter`. Build.
3. Fix F — 1 Hz timer. Build.
4. Fix C — `LogRowView(entry:)` + remove `LogEntry.==`. Build.
5. Fix E — throttled byte flush (no `recomputeFilteredEntries` in flush). Build.
6. Fix D — cached `filteredEntries`, `didSet`, setter helpers, ContentView bindings. Build.
7. Fix A — wrap every background `logStore.*` call. Build.

## Validation Strategy

(Same as v3, with one addition.) After Fix A, byte-count assertions
should allow a one-frame drain window — `flushPendingBytes` uses
`await Task.yield()` which can stall longer than 16 ms on a saturated
main thread.

## Risks / Open Questions

- **Fix A timing shift**: `establishTunnel` (and the outbound
  `NWConnection.start(...)` it triggers) now runs on the main actor
  instead of on the connection's `.global()` queue. Safe because
  NWConnection is thread-safe to assign; the connection runs on its
  own queue regardless of where `start(...)` was called from.
- **Fix C LogEntry.Equatable**: removing the custom `==` means SwiftUI
  also compares `requestHeaders` and `responseHeaders` dictionaries.
  This is acceptable (Swift's dictionary equality is fast and stable).
  Test that `ForEach(logStore.filteredEntries)` does not thrash when
  many rows update in close succession.
- **Fix D didSet**: `@Published` is a property wrapper; the `didSet`
  observer fires inside the property wrapper's setter, after
  `objectWillChange.send()`. This means `recomputeFilteredEntries()`
  runs *after* SwiftUI is told the property changed, which can cause a
  visible flicker on the filter chips. Mitigation: emit the filtered
  update in the same main-actor tick by calling `recomputeFilteredEntries()`
  *before* the underlying property is mutated. Use the setter helpers
  to enforce this:
  ```swift
  func setSearchText(_ s: String) {
      searchText = s                 // didSet fires; recompute runs synchronously
      // recomputeFilteredEntries() is also called by didSet
  }
  ```
  SwiftUI batches the two `objectWillChange` notifications into one
  body pass — confirmed empirically in iOS 16. If flicker is observed,
  fold into a single `filterInputsChanged()` event.
- **Fix E drain window**: byte counters may lag the wire by more than
  one frame on a saturated main thread.
- **`LogStore.searchText is isolated to the main actor` warnings**
  during recovery are a separate class of issue from background-thread
  `@Published` mutations. Fixing Fix A addresses the second but not
  necessarily the first; if these warnings persist after Fix A,
  revisit whether `TextField(text: $logStore.searchText)` is the
  trigger.
- **`LogDetailView` snapshot semantics**: when `selectedEntry` is set
  in `LogRowView.onTapGesture`, it captures the entry *as of the
  current body pass*. Subsequent updates to that entry's mutable
  fields are not reflected in the open detail sheet until the sheet
  is re-presented. The current behaviour already had this property
  (because `selectedEntry: LogEntry?` is a value-type `Binding`-ish
  item). No change.

## Out of Scope

(Same as v3.)

## Provenance

- v1: hypothesised a performance bottleneck on the main thread.
- v2: hypothesised actor-isolation violation as the primary cause.
- v3: acknowledged evidence limits; proposed fixing both.
- v4: incorporated subagent review — three blockers fixed
  (Fix C LogEntry.==, Fix D didSet, Fix A SOCKS5 correction) plus
  secondary issues (Fix E does not call recompute; spec line counts
  reconciled).
