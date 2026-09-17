# ContentView UI Freeze — Root Cause & Fix Design (v3)

**Date:** 2026-09-18 (third revision after user clarification)
**Status:** Draft (awaiting user approval)

## What changed from v2

The v2 revision argued that the UI freeze is *caused* by actor-isolation
violations (166 `Publishing changes from background threads` warnings plus
61 `Updating ObservedObject<LogStore> from background threads` warnings in
`/tmp/log.txt`).

User clarification: **`/tmp/log.txt` was captured after the UI recovered,
not during the freeze.** The warnings are real, but we cannot pin the
freeze on them alone — they may have been emitted while the system was
cleaning up after the freeze, or while the app was still processing
leftover traffic. Debugging capability is limited to console output;
Instruments / LLDB stack sampling is not available.

User decision: **fix both the actor-isolation violations and the
performance hotspots** identified in v1. Defensive in depth — neither
fix is provably *the* root cause from the available evidence, but both
are real defects that should be corrected.

## Honest assessment of root cause

The available evidence supports, but does not prove, the following:

| Evidence | What it shows | What it does not show |
|---|---|---|
| 166 `Publishing changes from background threads` warnings | `@Published` fields are mutated off the main actor | That this mutation *caused* the freeze (warnings are tolerated in iOS 16) |
| 61 `Updating ObservedObject<LogStore> from background threads will cause undefined behavior` | SwiftUI's own diagnostic on the same issue | The specific runtime consequence (could be anything) |
| 9 `LogStore.searchText is isolated to the main actor. ... This warning will become a runtime crash in a future version of SwiftUI.` | SwiftUI compiler-time warning about future crash | That today's freeze is *that* future crash |
| `LogRowView` does O(n) `entries.first(where:)` per body | O(n²) work per body pass when entries ≈ 100+ | That the work is on the critical path of the freeze |
| 0.1s `Timer` driving `uptimeString` updates | 10 Hz re-render trigger | That 1 Hz would have been enough |

The freeze could be any of:
1. SwiftUI observation pipeline corruption from background `@Published`
   writes (the v2 hypothesis).
2. Main thread saturation by O(n²) `LogRowView` work × 10 Hz timer ×
   per-packet body invalidation (the v1 hypothesis).
3. A deadlock between `Task { @MainActor in ... }` queues and the
   main runloop's input source that we have not yet seen.
4. Some combination.

Because we cannot distinguish (1)–(4) from the available evidence, the
safest course is to fix all known defects and re-test. If the freeze
recurs after these fixes, we will need better tooling (Instruments).

## Goals

- Eliminate all background-thread `@Published` mutations on `LogStore`
  (zero "Publishing changes from background threads" warnings).
- Reduce per-body work from O(n²) to O(n) for the log list.
- Reduce the body's re-render trigger rate from 10 Hz to 1 Hz.
- Cache the `DateFormatter` used by `LogEntry.formattedTime`.
- Throttle per-packet `addTxBytes` / `addRxBytes` to a frame rate.

## Non-Goals

- Migrating to `@Observable` / Observation framework (requires iOS 17).
- Reducing log retention below 500 entries.
- Removing `@MainActor` from `LogStore`.
- Rewriting the proxy / SOCKS5 state machines.

## Proposed Fix

### Fix A — Wrap every background logStore call in a main-actor hop

For each of the call sites listed below, route the call through the main
actor. Two patterns depending on the call site:

1. **Synchronous callback on a connection / tunnel queue** — use
   `Task { @MainActor in ... }`. Existing call sites that already use
   this pattern stay as they are; we only fix the ones that don't.

2. **Inside an async context that already awaits** — same pattern.

Mechanical change: insert the Task wrapper, capture any return values
(e.g. `LogEntry` from `log()`) **before** the hop, and pass them into
the body of the Task.

Call sites to fix (none have an existing wrapper):

- `ProxyServer.swift:284, 285, 291, 292` — `processRequest` CONNECT path
- `ProxyServer.swift:325, 326, 351, 352, 362, 363` — `handleHTTPPxoyRequest`
- `ProxyServer.swift:402` — `sendHTTPProxyRequest`
- `ProxyServer.swift:470, 471, 481, 482` — `establishTunnel` callbacks
- `TunnelManager.swift:75, 85, 93` — `start` state handlers
- `TunnelManager.swift:170, 177, 185` — `startAsProxy` state handlers
- `TunnelManager.swift:520` — `scheduleConnectionTimeout` expiry
- `SOCKS5.swift:511, 531` — UDP relay forward completion

Call sites that already wrap (verify, do not change):
- `TunnelManager.swift:232-234, 281-283, 313-315, 359-361, 412-419, 447-449, 482-484`
- `SOCKS5.swift:302, 321, 557`

### Fix B — Cache `LogEntry`'s `DateFormatter`

```swift
private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

var formattedTime: String { Self.timeFormatter.string(from: timestamp) }
```

### Fix C — `LogRowView` value parameter instead of `@ObservedObject`

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
        .onTapGesture { ... }
}
```

Effect: rows no longer subscribe to `LogStore`. They only re-render when
their `entry` value is replaced. Per-body work drops from O(n²) to O(n).

### Fix D — Cache `filteredEntries` as `@Published`

Replace the computed property with a `@Published private(set) var
filteredEntries: [LogEntry] = []` and recompute in a single function
called whenever inputs change. Wrap each existing mutator in
`applyChange { ... }` so `recomputeFilteredEntries()` is called once per
mutator invocation.

### Fix E — Throttle byte-counter writes to one per main-actor frame

In `LogStore`:

```swift
private var pendingTxDelta: Int = 0
private var pendingRxDelta: Int = 0
private var pendingPerEntryTx: [UUID: Int] = [:]
private var pendingPerEntryRx: [UUID: Int] = [:]
private var flushScheduled = false

func addTxBytes(_ count: Int, to entry: LogEntry? = nil) {
    pendingTxDelta += count
    if let entry = entry { pendingPerEntryTx[entry.id, default: 0] += count }
    scheduleFlush()
}
func addRxBytes(_ count: Int, to entry: LogEntry? = nil) {
    pendingRxDelta += count
    if let entry = entry { pendingPerEntryRx[entry.id, default: 0] += count }
    scheduleFlush()
}
private func scheduleFlush() {
    if flushScheduled { return }
    flushScheduled = true
    Task { @MainActor [weak self] in
        await Task.yield()
        self?.flushPendingBytes()
    }
}
```

`flushPendingBytes` then writes the deltas to `@Published` fields in one
shot per frame.

### Fix F — Lower uptime timer to 1 Hz

`ContentView.swift:259`: change `withTimeInterval: 0.1` to `1.0`.

### Fix G — Remove the `DebugPerf` instrumentation after validation

The `DebugPerf` enum, the `// DEBUG_PERF` comments in `LogStore.swift`,
and the temporary `CACurrentMediaTime` measurement in `addTxBytes` /
`addRxBytes` are added for the v1 instrumentation step. They MUST be
removed before the final commit.

## Files Touched

| File | Change |
|---|---|
| `HttpRelay/ProxyServer.swift` | Fix A (wrap `logStore.*` calls in `processRequest`, `handleHTTPPxoyRequest`, `sendHTTPProxyRequest`, `establishTunnel` callbacks). |
| `HttpRelay/TunnelManager.swift` | Fix A (wrap `logStore.*` calls in `start`, `startAsProxy`, `scheduleConnectionTimeout`). |
| `HttpRelay/SOCKS5.swift` | Fix A (fix `SOCKS5UDPRelay.forward` lines 511, 531). |
| `HttpRelay/LogEntry.swift` | Fix B (cache `DateFormatter`). |
| `HttpRelay/ContentView.swift` | Fix C (`LogRowView` value param), Fix F (1 Hz timer). |
| `HttpRelay/LogStore.swift` | Fix D (cached `filteredEntries`), Fix E (frame-throttled byte flush). Fix G (remove `DebugPerf`). |

## Implementation order

1. Fix G — remove `DebugPerf` instrumentation from `ContentView.swift` and
   `LogStore.swift`. Build and run; confirm clean console (no
   `// DEBUG_PERF` markers).
2. Fix B — cache `DateFormatter`. Build.
3. Fix F — 1 Hz timer. Build.
4. Fix C — `LogRowView` value parameter. Build.
5. Fix D — cached `filteredEntries`. Build.
6. Fix E — throttled byte flush. Build.
7. Fix A — wrap every background `logStore.*` call. Build.
8. Final clean build + on-device validation.

This order keeps each change small and buildable. Fixes B, F, C, D, E
are pure refactors that don't change behaviour. Fix A is the largest
mechanical change.

## Validation Strategy

1. Build with `xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay
   -configuration Debug -destination 'platform=iOS Simulator,name=iPhone
   17 Pro' build` — must compile clean at each step.
2. Re-deploy with no `DebugPerf` instrumentation. Push traffic.
3. Confirm in `/tmp/log.txt` (capture during a fresh run, ideally while
   the UI is responsive):
   - **Zero** `Publishing changes from background threads` warnings.
   - **Zero** `Updating ObservedObject<LogStore>` warnings.
   - **Zero** `LogStore.searchText is isolated to the main actor`
     warnings.
4. Confirm UI remains responsive during traffic: Toggle flips, gear /
   trash buttons work, filter chips respond, log entries scroll.
5. If the freeze still occurs, the freeze is *not* caused by (1) actor
   isolation or (2) performance hotspots identified here. Reopen
   debugging with Instruments.

## Risks / Open Questions

- Fix A: `processRequest` currently does
  `let logEntry = logStore.log(...)` synchronously and then passes
  `logEntry` to `establishTunnel`. After wrapping, the `logEntry` is
  only available on the main actor. `establishTunnel` must be scheduled
  from inside the main-actor hop. The semantics are unchanged — the
  tunnel is only created after the log entry exists.
- Fix A: receive loops that re-arm from `client.send(...)`'s completion
  run on the connection queue, not the main actor. The `logStore` hop
  must not delay the re-arm.
- Fix C: with `LogRowView` taking a value `LogEntry`, when an entry's
  `txBytes` / `rxBytes` are updated by Fix E's flush, every visible row
  whose entry changed is re-rendered. SwiftUI's `Identifiable` diff
  handles this correctly because `UUID` doesn't change.
- Fix D: `searchText`, `selectedMethods`, `selectedStatusFilters` remain
  `@Published`. Views observing them still re-render on each keystroke —
  that's correct (filter UI must update), and `recomputeFilteredEntries`
  bounds the cost.
- Fix E: counters lag the wire by one frame (~16 ms at 60 Hz). Acceptable
  for a human-visible counter; per-entry bytes still accumulate
  correctly.

## Out of Scope

- Migrating to `@Observable` (iOS 17+ requirement).
- Persisting logs across launches.
- Profiling with Instruments (requires additional tooling).

## Provenance

- v1 (initial): hypothesised a performance bottleneck on the main thread.
- v2 (revised): hypothesised actor-isolation violation as the primary
  cause.
- v3 (this revision): acknowledges that we cannot isolate the cause from
  the available evidence (`/tmp/log.txt` was captured *after* recovery),
  and proposes fixing both.
