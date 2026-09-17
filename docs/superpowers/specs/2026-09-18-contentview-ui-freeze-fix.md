# ContentView UI Freeze — Root Cause & Fix Design (REVISED)

**Date:** 2026-09-18 (revised after /tmp/log.txt evidence)
**Status:** Draft (awaiting user approval)

## What changed from the previous revision

The first revision of this spec hypothesised a performance bottleneck on the
main thread driven by per-packet `@Published` writes. Evidence from
`/tmp/log.txt` (a real-device run with traffic) contradicts that:

- **166 occurrences** of `Publishing changes from background threads is not
  allowed; make sure to publish values from the main thread (via operators
  like receive(on:)) on model updates.` in the console.
- **Multiple** `LogStore.searchText is isolated to the main actor. Accessing
  it via Binding from a different actor will cause undefined behaviors, and
  potential data races; This warning will become a runtime crash in a future
  version of SwiftUI.` warnings.

These are not just noise. They mean the `LogStore` `@Published` properties are
being mutated off the main thread, which corrupts SwiftUI's observation
pipeline and is consistent with the observed UI freeze.

The performance-bottleneck hypothesis is **withdrawn**. The real root cause
is **actor-isolation violation** — `ProxyServer` and `TunnelManager` call
`@MainActor LogStore` methods synchronously from connection callbacks that
run on `DispatchQueue.global()` / the per-tunnel serial queue.

## Problem Statement

After enabling the proxy server on a real iOS device and pushing traffic
through it, the SwiftUI UI becomes completely unresponsive: no buttons
respond, the Toggle cannot be flipped, the gear / clear-logs buttons do
nothing. The process does not crash and does not produce a debugger trap.

User-confirmed characteristics:

- Occurs shortly after the proxy is started and traffic flows.
- UI is fully frozen (not just slow).
- Reproduced on a real iOS device.
- `/tmp/log.txt` shows 166 `Publishing changes from background threads`
  warnings and multiple `LogStore.searchText ... isolated to the main actor`
  warnings.

## Root Cause

`LogStore` is declared `@MainActor` (LogStore.swift:5). All of its mutating
methods (`log`, `incrementConnections`, `decrementConnections`,
`completeEntry`, `failEntry`, `updateEntry`, `addTxBytes`, `addRxBytes`)
are therefore main-actor-isolated.

The proxy server, however, calls these methods **synchronously from
non-main-actor callbacks**:

| Caller | Callback queue | Background logStore calls |
|---|---|---|
| `ProxyServer.processRequest` (line 284, 285, 291, 292) | `DispatchQueue.global()` (connection queue) | `log`, `incrementConnections`, `failEntry`, `decrementConnections` |
| `ProxyServer.handleHTTPPxoyRequest` (line 325, 326, 351, 352, 362, 363, 402) | `DispatchQueue.global()` | `log`, `incrementConnections`, `completeEntry`, `decrementConnections`, `failEntry`, `updateEntry` |
| `ProxyServer.establishTunnel` callbacks (line 470, 471, 481, 482) | `DispatchQueue.global()` | `completeEntry`, `decrementConnections`, `failEntry` |
| `TunnelManager.start` state handlers (line 75, 85, 93) | per-tunnel serial queue `com.httprelay.tunnel` | `failEntry`, `completeEntry` |
| `TunnelManager.startAsProxy` state handlers (line 170, 177, 185) | per-tunnel queue | `failEntry`, `completeEntry` |
| `TunnelManager.startProxyForwarding` / `continueProxyForwarding` (line 233, 282) | per-tunnel queue | `addRxBytes` |
| `TunnelManager.sendToServer` (line 314) | per-tunnel queue | `addTxBytes` |
| `TunnelManager.startForwarding` (line 360) | per-tunnel queue | `addRxBytes` |
| `TunnelManager.parseAndLogResponse` (line 413) | per-tunnel queue | `updateEntry` |
| `TunnelManager.forwardToClient` (line 448) | per-tunnel queue | `addRxBytes` |
| `TunnelManager.receiveClientData` (line 483) | per-tunnel queue | `addTxBytes` |
| `TunnelManager.scheduleConnectionTimeout` (line 520) | per-tunnel queue | `failEntry` |

`SOCKS5.swift` already wraps most calls in `Task { @MainActor in ... }`
(but `SOCKS5.swift:511` is missing the wrap and is also a bug).

Each synchronous cross-actor call mutates a `@Published` property from a
background thread. Consequences:

1. **Combine warning** `Publishing changes from background threads is not
   allowed` is emitted every time, producing log spam and signalling that
   `objectWillChange` is firing from the wrong thread.
2. **SwiftUI's observation pipeline** is confused: the `@Published` setter
   runs on a background thread, but the views are bound on the main thread.
   In iOS 16, this can leave SwiftUI in a state where it never finishes a
   body update cycle, which manifests as the observed freeze.
3. **`searchText` warning** appears when the `TextField` binding writes from
   a non-main actor context; SwiftUI's diagnostic points at undefined
   behaviour and future crashes.

The 0.1s `Timer` and the O(n²) `LogRowView` work are real costs but are
**not** the primary cause of the freeze — they are amplifiers that turn the
already-broken observation pipeline into a hard hang.

## Goals

- Eliminate the 166 `Publishing changes from background threads` warnings.
- Restore main-actor isolation for every `LogStore` mutator.
- Stop the UI freeze on a real device under traffic load.
- Preserve existing functionality (logs, filters, bytes counters, connection
  counts, byte-formatted rows, detail view, SOCKS5).
- No changes to wire protocol, SOCKS5 state machine, or proxying semantics.

## Non-Goals

- Migrating to `@Observable` / Observation framework (requires iOS 17).
- Reducing log retention below 500 entries.
- Removing `@MainActor` from `LogStore` (the actor isolation is correct; the
  callers are wrong).

## Proposed Fix

### Fix A — Wrap every background logStore call in a MainActor hop

For every site listed in the table above, route the call through the main
actor. Two patterns depending on the call site:

1. **Inside a callback that can become async / already uses `Task`** — wrap
   in `Task { @MainActor in ... }`. Used when the caller is already in a
   `Task` block or when we want to coalesce with the existing task.

2. **Inside a synchronous callback** — wrap in
   `DispatchQueue.main.async { ... }` (or `Task { @MainActor in ... }`,
   which is equivalent on iOS 16 when not awaiting).

For each call site the change is mechanical: insert one extra closure. The
return values that flow back into the caller (e.g. `LogEntry` from `log()`)
must be captured **before** the hop. Example:

```swift
// Before (ProxyServer.swift:284)
let logEntry = logStore.log(host: host, port: port, path: path,
                            query: query, method: method,
                            requestHeaders: requestHeaders)
logStore.incrementConnections()
do {
    try establishTunnel(host: host, port: port, clientConnection: connection,
                        logEntry: logEntry)
} catch {
    logStore.failEntry(logEntry)
    logStore.decrementConnections()
    sendErrorResponse(connection, code: "502 Bad Gateway")
}
```

Becomes:

```swift
let requestHeaders = parseHeaders(from: request)
let path: String
let query: String?
(path, query) = parsePathAndQuery(from: request)
logStore.append(.init(host: host, port: port, path: path, query: query,
                      method: method, requestHeaders: requestHeaders))
// or: enqueue on main and continue after the LogEntry is assigned
```

The cleanest refactor is to introduce a small **dispatcher on `LogStore`**:

```swift
extension LogStore {
    /// Capture the necessary values on the caller's thread, then hop to the
    /// main actor to perform the mutation. Returns the LogEntry on the main
    /// actor via the completion closure.
    func appendOnMain(_ payload: LogPayload,
                      completion: @MainActor @escaping (LogEntry) -> Void) {
        Task { @MainActor in
            let entry = self.log(host: payload.host, port: payload.port, ...)
            self.incrementConnections()
            completion(entry)
        }
    }
}
```

But that pushes awkwardness onto the call sites that need the `LogEntry`
back synchronously (e.g. `establishTunnel(host:port:clientConnection:logEntry:)`).
A simpler and equally correct shape is:

1. Compute all values that are needed on the calling thread (host, port,
   path, query, method, requestHeaders, responseHeaders, statusCode,
   duration, byte counts, etc.) **before** the hop.
2. Hop to main with `Task { @MainActor in ... }` (or
   `DispatchQueue.main.async`) and do all `LogStore` work inside the hop.
3. If a callback the caller needs (e.g. `establishTunnel`) needs to run
   after the `LogEntry` exists, schedule that from inside the hop.

This costs one extra dispatch per log lifecycle event (1 log + 1 done per
request) — well below the rate at which `objectWillChange` was being
mis-fired.

### Fix B — `SOCKS5.swift:511` and `531`

Both `addTxBytes` calls inside `SOCKS5UDPRelay.forward` are inside the
`outbound.send(...)` completion closure, which runs on the socks5 queue
(not the main actor). Wrap them in `Task { @MainActor in ... }` like the
other SOCKS5 call sites.

### Fix C — `TunnelManager.receiveClientData` (line 483)

This is called from `ProxyServer.receiveHTTPRequest`'s callback, which runs
on `DispatchQueue.global()`. The current code does:

```swift
Task { @MainActor in
    self.logStore.addTxBytes(data.count, to: self.logEntry)
}
```

…which is correct — `addTxBytes` is hopped. **No change needed**; just
leave it as-is. Same for `parseAndLogResponse`'s `updateEntry` (already
inside a `Task { @MainActor in ... }`).

### Fix D — Don't relax `LogStore` actor isolation

Do **not** remove `@MainActor` from `LogStore`. The class is a SwiftUI
`ObservableObject`; SwiftUI expects mutations on the main actor. The
correctness fix is on the callers, not the model.

### Fix E (retain from first revision) — Cache the `DateFormatter`

`LogEntry.formattedTime` creates a new `DateFormatter` on every body
evaluation. Cache it as a `static let`. Cheap, isolated, no callers
change.

### Fix F (defer) — The performance improvements from the first revision

Fixes 1 (throttled byte flush), 2 (`LogRowView` value parameter), 3
(cached `filteredEntries`), and 5 (1 Hz timer) from the previous revision
are real wins but are **not** required to fix the freeze. Defer them to a
follow-up spec once the freeze is gone and we can profile honestly.

## Files Touched

| File | Change |
|---|---|
| `HttpRelay/ProxyServer.swift` | Wrap all `logStore.*` calls in `processRequest`, `handleHTTPPxoyRequest`, `establishTunnel`, callbacks, and `sendHTTPProxyRequest` in main-actor hops. |
| `HttpRelay/TunnelManager.swift` | Wrap all `logStore.*` calls in `start`, `startAsProxy`, `startProxyForwarding`, `continueProxyForwarding`, `sendToServer`, `startForwarding`, `parseAndLogResponse`, `forwardToClient`, `receiveClientData`, `scheduleConnectionTimeout` in main-actor hops. (Several are already inside `Task { @MainActor in ... }`; verify each.) |
| `HttpRelay/SOCKS5.swift` | Fix lines 511 and 531 to wrap `addTxBytes` in `Task { @MainActor in ... }`. |
| `HttpRelay/LogEntry.swift` | Cache `DateFormatter` as `static let` (Fix E). |

No changes to `ContentView.swift`, `LogStore.swift`, `BackgroundKeepaliveCoordinator.swift`, `HttpRelayApp.swift`.

## Validation Strategy

1. **Build** with `xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay
   -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17
   Pro' build` — must compile clean.
2. **Re-deploy with the existing `DebugPerf` instrumentation** (still in
   `ContentView.swift` and `LogStore.swift` from the previous step). Confirm
   that `[DEBUG bytes]` lines appear in console and that `maxMs` is small
   (sub-millisecond) under traffic.
3. **Re-deploy and run the same scenario that produced `/tmp/log.txt`**.
   Confirm:
   - **Zero** `Publishing changes from background threads` warnings.
   - **Zero** `LogStore.searchText is isolated to the main actor` warnings.
   - The Toggle still flips and the gear / trash buttons still respond
     while traffic flows.
4. **Remove the `DebugPerf` instrumentation** and the temporary
   `addTxBytes/addRxBytes` measurement blocks (`// DEBUG_PERF` markers).
   Re-build, re-deploy, and confirm a clean console.

## Risks / Open Questions

- Some call sites currently use the synchronous return value of
  `logStore.log(...)` (the `LogEntry` is passed into
  `establishTunnel`). After wrapping, the `LogEntry` is only available on
  the main actor, so `establishTunnel` must be scheduled from inside the
  main-actor hop. The semantics are unchanged: a tunnel is only created
  once we have a log entry. We need to verify that no caller relies on
  the tunnel being created synchronously with `processRequest`.
- The receive loop on `NWConnection` is re-armed from the completion
  handler of a `send` (e.g. `client.send(...)` in
  `forwardToClient`). These completions run on the connection queue
  (global), not the main actor. Wrapping the `logStore.addRxBytes` in a
  `Task { @MainActor in ... }` does **not** delay the re-arm — we must
  schedule the re-arm independently of the logStore hop.
- Each existing `Task { @MainActor in self.logStore.addRxBytes(...) }`
  creates a fresh `Task` per packet. With the fix in place this is the
  same cost as today — but now it's correctly isolated. If profiling
  later shows this is too expensive, throttle as in Fix F.

## Out of Scope

- Migrating to `@Observable` (iOS 17+ requirement).
- Throttling bytes updates (Fix F from first revision).
- Persisting logs across launches.
