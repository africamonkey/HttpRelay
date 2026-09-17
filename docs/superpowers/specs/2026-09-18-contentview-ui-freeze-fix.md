# ContentView UI Freeze — Root Cause & Fix Design

**Date:** 2026-09-18
**Status:** Draft (awaiting user approval)

## Problem Statement

After enabling the proxy server on a real iOS device and pushing traffic through
it (e.g. a Windows client using the iOS device as an HTTP CONNECT / SOCKS5
proxy), the SwiftUI UI becomes completely unresponsive: no buttons respond, the
Toggle cannot be flipped, the gear / clear-logs buttons do nothing. The process
does not crash and does not produce a debugger trap — it stays alive but
starves the main run loop.

User-confirmed characteristics:

- Occurs "shortly after" the proxy is started and traffic flows.
- UI is fully frozen (not just slow).
- Reproduced on a real iOS device.
- User has console / profile output available.

## Root Cause (Hypothesis)

The main thread is saturated by SwiftUI re-renders driven by per-packet
`@Published` mutations on `LogStore`, combined with a `LogRowView` design that
forces every row to subscribe to the entire `LogStore` and do an O(n) lookup
inside its `body`.

Chain of events on each forwarded network packet:

1. `TunnelManager.forwardToClient()` (or SOCKS5's `clientToServer` / `serverToClient`)
   receives a chunk of bytes and creates `Task { @MainActor in
   logStore.addRxBytes(...) }` (TunnelManager.swift:359, 447; SOCKS5.swift:321,
   557) and likewise for `addTxBytes`. This is one structured concurrency
   task per packet.
2. On the main actor, `addRxBytes` (LogStore.swift:103-110) writes two
   `@Published` fields: `totalRxBytes += count` and
   `entries[index].rxBytes += count` (which mutates an element of the
   `@Published entries` array). Two `objectWillChange.send()` per call.
3. SwiftUI invalidates `ContentView.body`. `body` re-evaluates
   `logStore.filteredEntries` (a computed property — re-filters up to 500
   entries every time: LogStore.swift:16-43).
4. `ForEach(logStore.filteredEntries)` re-renders every `LogRowView`.
5. `LogRowView` declares `@ObservedObject var logStore: LogStore`
   (ContentView.swift:307). All rows are re-subscribed; every row's `body`
   calls `logStore.entries.first(where: { $0.id == entryId })`
   (ContentView.swift:309-311) — an **O(n) linear scan per row**.
6. `LogEntry.formattedTime` (LogEntry.swift:37-41) creates a new
   `DateFormatter` on every body evaluation.
7. Net cost per body pass: O(n) filteredEntries + O(n²) row lookups + 500
   `DateFormatter` allocations.
8. A 0.1s `Timer.scheduledTimer` (ContentView.swift:259) re-fires
   `uptimeString` every 100 ms, triggering another full body pass even when
   no traffic is flowing.

At high packet rates, the @MainActor task queue and SwiftUI update queue both
grow without bound. The main run loop is consumed by these queued tasks and
never gets back to draining UIKit event sources, so taps, gestures and the
toggle all become unresponsive.

This is **not** a deadlock (no `DispatchQueue.main.sync`, no recursive
synchronous work, no `RunLoop.main.run`). The main thread is simply saturated
by work whose cost is O(n²) per packet and is also triggered by a 10 Hz timer.

## Goals

- Eliminate UI freeze on real device under traffic load.
- Preserve existing functionality (logs, filters, bytes counters, connection
  counts, byte-formatted rows, detail view).
- No changes to wire protocol, SOCKS5 state machine, or proxying semantics.
- Keep the fix small and reviewable: defence-in-depth, not a rewrite.

## Non-Goals

- Migrating to `@Observable` / Observation framework (requires iOS 17;
  project targets iOS 16).
- Reducing log retention below 500 entries.
- Changing the `LogStore` API surface consumed by `ProxyServer` /
  `TunnelManager` / `SOCKS5`.

## Proposed Fix (Defence-in-Depth)

### Fix 1 — Throttle byte-counter @MainActor updates

Goal: collapse N packet-level `@Published` writes into at most one per
animation frame.

Add to `LogStore`:

```swift
private var pendingTxDelta: Int = 0
private var pendingRxDelta: Int = 0
private var pendingPerEntryTx: [UUID: Int] = [:]
private var pendingPerEntryRx: [UUID: Int] = [:]
private var flushScheduled = false

func addTxBytes(_ count: Int, to entry: LogEntry? = nil) {
    pendingTxDelta += count
    if let entry = entry {
        pendingPerEntryTx[entry.id, default: 0] += count
    }
    scheduleFlush()
}

func addRxBytes(_ count: Int, to entry: LogEntry? = nil) {
    pendingRxDelta += count
    if let entry = entry {
        pendingPerEntryRx[entry.id, default: 0] += count
    }
    scheduleFlush()
}

private func scheduleFlush() {
    if flushScheduled { return }
    flushScheduled = true
    Task { @MainActor [weak self] in
        await Task.yield()                  // let a frame elapse
        self?.flushPendingBytes()
    }
}

private func flushPendingBytes() {
    let tx = pendingTxDelta; pendingTxDelta = 0
    let rx = pendingRxDelta; pendingRxDelta = 0
    let perTx = pendingPerEntryTx; pendingPerEntryTx.removeAll(keepingCapacity: true)
    let perRx = pendingPerEntryRx; pendingPerEntryRx.removeAll(keepingCapacity: true)
    flushScheduled = false
    if tx > 0 { totalTxBytes += Int64(tx) }
    if rx > 0 { totalRxBytes += Int64(rx) }
    if !perTx.isEmpty || !perRx.isEmpty {
        for i in entries.indices {
            let id = entries[i].id
            let dtx = perTx[id] ?? 0
            let drx = perRx[id] ?? 0
            if dtx != 0 || drx != 0 {
                entries[i].txBytes += Int64(dtx)
                entries[i].rxBytes += Int64(drx)
            }
        }
    }
}
```

This is a single coalesced `@Published` write per main-actor hop per frame
instead of two writes per packet.

### Fix 2 — `LogRowView` no longer subscribes to `LogStore`

Replace the `entryId` + `@ObservedObject logStore` pattern with a direct
`entry: LogEntry` value parameter, and remove the `@ObservedObject`.

```swift
struct LogRowView: View {
    let entry: LogEntry                       // value, no observation
    var body: some View { /* unchanged */ }
}
```

In `ContentView.logsList`:

```swift
ForEach(logStore.filteredEntries) { entry in
    LogRowView(entry: entry)
        .onTapGesture {
            if let updatedEntry = logStore.entries.first(where: { $0.id == entry.id }) {
                selectedEntry = updatedEntry
            }
        }
}
```

Effect: rows are no longer invalidated when `totalTxBytes`/`totalRxBytes`
change. They only re-render when an entry they own is replaced (which happens
when its `txBytes`/`rxBytes` are flushed by Fix 1 — already coalesced).

### Fix 3 — Cache `filteredEntries` and only recompute when inputs change

Replace the computed property with a `@Published private(set) var
filteredEntries: [LogEntry] = []` and recompute in a single function
`recomputeFilteredEntries()` called whenever `entries`, `searchText`,
`selectedMethods`, or `selectedStatusFilters` change.

```swift
@Published private(set) var filteredEntries: [LogEntry] = []

private func recomputeFilteredEntries() {
    filteredEntries = entries.filter { /* same predicate */ }
}
```

Call sites: `log()`, `updateEntry()`, `completeEntry()`, `failEntry()`,
`addTxBytes`/`addRxBytes` (only when they change entries), `clear()`,
`clearFilters()`, and via a `didSet` on `searchText`/`selectedMethods`/
`selectedStatusFilters`. Implementation uses a helper `mutate(_:)` that
applies a state change then calls `recomputeFilteredEntries()` once.

The simplest version: add a `private func applyChange(_ block: () -> Void)`
that runs `block()` then `recomputeFilteredEntries()`. Each existing mutator
is wrapped in `applyChange { ... }`.

### Fix 4 — Cache the `DateFormatter` on `LogEntry`

```swift
private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

var formattedTime: String { Self.timeFormatter.string(from: timestamp) }
```

### Fix 5 — Lower the uptime timer to 1 Hz

`ContentView.swift:259`: change `withTimeInterval: 0.1` → `1.0`. The user
sees uptime tick once per second, which is plenty for a human.

### Fix 6 (optional, defer) — Cap entries lower or use `Identifiable` row diffing

The 500-entry cap was inherited from an earlier spec. With the above fixes
the per-body cost drops from O(n²) to O(n) on entries + O(1) for bytes.
Not changing the cap in this fix; revisit if profiling still shows hot
paths.

## Files Touched

| File | Change |
|---|---|
| `HttpRelay/LogEntry.swift` | Add static `timeFormatter` cache (Fix 4). |
| `HttpRelay/LogStore.swift` | Throttled byte flush (Fix 1), cached filteredEntries (Fix 3). |
| `HttpRelay/ContentView.swift` | `LogRowView(entry:)` (Fix 2), 1s timer (Fix 5). |

No changes to `ProxyServer.swift`, `TunnelManager.swift`, `SOCKS5.swift`,
`BackgroundKeepaliveCoordinator.swift`, `HttpRelayApp.swift`.

## Validation Strategy

1. **Build** with `xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay
   -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
   build` — must compile clean.
2. **Add temporary instrumentation** (then remove) in `ContentView.body` to
   print elapsed time per body evaluation, gated on a compile-time `#if
   DEBUG` flag. Validate on simulator first.
3. **On-device repro**: enable proxy, push traffic via the Windows client,
   confirm (a) Toggle still flips, (b) gear / trash buttons respond, (c) TX
   / RX counters still increment, (d) log rows still appear and update,
   (e) filter chips and search field still work.
4. **Sanity**: scroll to bottom of a 500-entry log and confirm no visible
   jank on simulator.

## Risks / Open Questions

- Coalesced bytes updates mean TX/RX counters may lag behind the wire by up
  to one frame (~16 ms at 60 Hz). This is acceptable for a human-visible
  counter; the per-entry bytes still accumulate correctly.
- Wrapping every existing `LogStore` mutator in `applyChange { }` is
  mechanical but easy to forget. Mitigation: keep the helper's name short
  and obvious, and add a comment.
- `searchText`, `selectedMethods`, `selectedStatusFilters` are still
  `@Published`; SwiftUI views observing them still re-render on each
  keystroke. That's correct (the filter UI must update) and the cost is
  now bounded by `recomputeFilteredEntries()` rather than scattered
  computed-property access.

## Out of Scope

- SOCKS5 UDP relay throttling (UDP packet rates are typically low; defer).
- Migrating to `@Observable` (iOS 17+ requirement).
- Persisting logs across launches.
