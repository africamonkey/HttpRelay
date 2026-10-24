# First-tap freeze of the "Enable Debugger Server" toggle

**Date:** 2026-10-24
**Status:** Implemented

## Symptom

The first tap of "Enable Debugger Server" froze the UI. Every tap after that
was instant, which is what made it look like a one-off.

## How it was measured

A `CADisplayLink` watchdog was added to the app temporarily: it reports every
gap in the main run loop that is longer than one frame (20 ms). Together with
timestamps around the individual steps of the tap handler, that gives the
exact cost of every piece of work on the tap path.

Everything below was measured on an iPhone 18 Pro simulator (Xcode 27.1,
iOS 26.2). The simulator is slower than a device, in particular for image
decoding, so the numbers are an upper bound.

## Where the time went (before the fix)

| Step | First tap | Later taps | On the main thread? |
|---|---|---|---|
| `NWListener` creation | 17-49 ms | 0.1-0.2 ms | yes |
| `getifaddrs()` / `getnameinfo()` | 2-7 ms | 0.1 ms | yes (the listener's queue was `.main`) |
| `isIdleTimerDisabled = true` | 26 ms | 0.3 ms | yes |
| SwiftUI's first layout of the "running" state | 22-82 ms | ~0 ms | yes |
| The setup guide sheet's first render | 160-380 ms | 67-83 ms | yes |
| **Total blocked main thread** | **~490 ms** | **~85 ms** | |

The three one-off costs have the same cause: they are the first time the
process does a particular thing.

- The first `NWListener` of a process initialises the Network framework.
- The first `getnameinfo()` call resolves the resolver libraries.
- The first change of `isIdleTimerDisabled` makes UIKit set up the machinery
  behind it.
- The first layout of the "running" state warms SwiftUI's layout machinery.
- The first render of the setup guide builds its view hierarchy for the
  first time.

## The fix

1. **The listener is created off the main thread.**
   `ProxyServer.start(runID:)` creates and starts the `NWListener` on the
   calling thread; the state handler still runs on the main queue.
   `ContentView` dispatches it to a background queue and flips the UI right
   away.

2. **The interface lookup runs off the main thread.**
   `publishLocalIP(for:)` does `getifaddrs()`/`getnameinfo()` on a background
   queue and only hops back to the main actor to publish the result.

3. **The Network framework and the idle timer are warmed up at launch.**
   `HttpRelayApp.init()` creates and cancels a throwaway listener on a
   background queue, and flips `isIdleTimerDisabled` on and off again. The
   cost moves to the first frame instead of the first tap.

4. **The setup guide is presented after the server is up.**
   It used to be presented from inside the tap handler, so its expensive
   first render landed right on the tap. It is now presented from the
   `onChange` of `proxyServerHolder.server?.isRunning`, i.e. once the
   listener is up and the device's IP address is known.

5. **The setup guide does not use a paged `TabView` any more.**
   A segmented `Picker` plus a conditional replaced it. Building both pages
   of a paged `TabView` roughly doubled the sheet's first render
   (377 ms -> 177 ms). The price: the guide can no longer be swiped between
   the Mac and the Windows instructions.

## Result

| | Before | After |
|---|---|---|
| The tap handler | 55-77 ms | 4-7 ms |
| Main thread blocked by the tap | ~490 ms | ~40 ms |

The setup guide still takes ~150 ms to appear, but that happens after the
server is up and no longer collides with the tap.

## What the fix had to get right

Moving the start to a background queue introduced a race that did not exist
before: the user can switch the server off while the listener is still being
created, and the pending start must not bring the proxy up afterwards.

`ProxyServer` therefore carries a `runID`:

- `beginRun()` registers the intent to run and returns the current id. It is
  called on the thread that owns the server, before the start is dispatched.
- `stop()` bumps the id and clears `wantsToRun`.
- `start(runID:)` compares the id it was given with the current one. If they
  differ, the server was stopped in the meantime and the listener is
  cancelled instead of started.

Two tests cover this: `a_start_that_was_cancelled_does_not_bring_the_proxy_up`
and `a_stale_start_does_not_take_over_a_newer_run`.

## Regressions this change could have caused

- A failed start left the uptime timer running and the idle timer disabled.
  Every way out of "running" now goes through `resetRunningState()`.
- The view did not actually observe the server, so the `onChange` handlers
  only fired when something else happened to re-evaluate the body.
  `ProxyServerHolder` now republishes the server's changes.
- A listener that fails to bind left the screen saying "Running".
  `ProxyServer.failureMessage` reports it, and the screen shows an alert.
