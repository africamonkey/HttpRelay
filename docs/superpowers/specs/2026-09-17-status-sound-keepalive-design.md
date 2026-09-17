# HttpRelay - Status Sound Keepalive (Design)

Date: 2026-09-17

## Background and Goal

HttpRelay is an iOS HTTP CONNECT proxy server. The previous design (`2026-09-17-background-heartbeat-design.md`) used a periodic 500 Hz "tick" tone every 3 seconds as the audible justification for `UIBackgroundModes: audio`. The user found that design "useless" — it kept the app alive in the background but offered no real product value to the user.

This redesign splits the responsibilities:

- **Background keepalive** (silent, invisible) — keeps the proxy alive while the app is in the background.
- **Status sound** (audible, on user action) — gives the user immediate audio feedback when the Debugger Server is enabled/disabled.

Both work together: the silent engine satisfies `UIBackgroundModes: audio`; the status sound gives the user something they can hear and recognize. Together, the audio background mode has a real product justification.

## Goals

1. Keep the proxy alive while iOS backgrounds the app (same as previous design).
2. Play distinct system sounds when the user toggles the Debugger Server on/off.
3. Silent buffer keeps the audio render thread ticking — the user hears nothing during idle.
4. Volume = 0% system volume still keeps the app alive.

## Non-Goals

- No more "every 3 seconds tick" sound — that was the part the user found useless.
- No audio playback for individual connections (out of scope; spec said "user-controllable, audible silence is fine").
- No support for custom sound files.

## Approach: layered audio services

The audio subsystem is split into two single-responsibility components:

1. **`BackgroundKeepalive`** — owns `AVAudioEngine` + `AVAudioPlayerNode` + `DispatchSourceTimer`. Plays a **silent buffer** (all-zero samples) every 3 seconds. The buffer's amplitude is `0` and `mainMixerNode.outputVolume` defaults to `1.0`. Engine keeps running, audio render thread keeps ticking, iOS sees an active audio session and keeps the app alive. The user hears nothing.

2. **`StatusSound`** — wraps `AudioServicesPlaySystemSound`. Two methods:
   - `playEnabled()` — `AudioServicesPlaySystemSound(1057)` — **Tink** (system sound for "enabled / on")
   - `playDisabled()` — `AudioServicesPlaySystemSound(1054)` — **Tock** (system sound for "disabled / off")
   - No `AVAudioSession` involvement; system handles routing.

## Why this split

- **Single responsibility** — each component does one thing well.
- **Better UX** — the user hears a clear "Tink" / "Tock" pair when toggling. No 3-second metronome in their ear.
- **Simpler implementation** — `AudioServicesPlaySystemSound` is a one-liner; no buffer synthesis needed.
- **Tinker-able** — easy to swap sound IDs later if the user wants different sounds.

## Components

### `BackgroundKeepalive` (file: `HttpRelay/BackgroundKeepalive.swift`)

```swift
final class BackgroundKeepalive {
    static let shared = BackgroundKeepalive()

    private(set) var isRunning: Bool = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: DispatchSourceTimer?
    private var silentBuffer: AVAudioPCMBuffer?

    private init() {}

    func start() throws { ... }       // configures session + engine + silent buffer + timer
    func stop() { ... }               // cancels timer, stops engine, deactivates session
}
```

Details:
- `start()` is guarded with `guard !isRunning else { return }`.
- All engine/session setup runs on main thread (DispatchQueue.main.sync if off-main).
- `silentBuffer` is a 100 ms buffer at 44.1 kHz mono with **all-zero samples** (no sine burst, no fade).
- Timer schedules `silentBuffer` every 3 seconds.

### `StatusSound` (file: `HttpRelay/StatusSound.swift`)

```swift
import AudioToolbox

final class StatusSound {
    static let shared = StatusSound()

    private init() {}

    func playEnabled() {
        AudioServicesPlaySystemSound(1057)  // Tink
    }

    func playDisabled() {
        AudioServicesPlaySystemSound(1054)  // Tock
    }
}
```

No state, no session. Fire-and-forget.

### `ProxyServer` changes

`start()` — after `isStarted = true`, on success path only, call `StatusSound.shared.playEnabled()`.

`stop()` — after `isStarted = false`, call `StatusSound.shared.playDisabled()`.

The hook into `BackgroundKeepalive.shared.start()/stop()` is identical to the previous `AudioHeartbeat` wiring.

`ProxyServer.heartbeatEnabled` is renamed to `backgroundKeepaliveEnabled` (semantic match). It still defaults to `true` and reads from `UserDefaults` at init.

### UI changes

**`ContentView.swift`:**
- Toggle label: `"Background Keepalive"`
- Status subtext: `"Keepalive: On"` / `"Keepalive: Off"`
- Both use English (per project rule: no Chinese characters).

**`SettingsView.swift`:**
- "Background Keepalive" section has only the toggle.
- The volume Slider is **removed** — there's nothing for the user to adjust (the silent buffer has no audible output).
- Section header: `"Background Keepalive"`.
- Section footer text: explains that the proxy stays alive in the background even when silent.

## Data flow

**Enable path (user toggles Debugger Server on):**
```
ContentView Toggle -> ProxyServer.start(port) throws
    -> NWListener.start
    -> isStarted = true
    -> BackgroundKeepalive.shared.start()
        -> AVAudioSession.setCategory(.playback, .mixWithOthers).setActive(true)
        -> engine.attach(player) + connect + engine.start()
        -> DispatchSourceTimer fires every 3s -> player.scheduleBuffer(silentBuffer)
    -> StatusSound.shared.playEnabled()  // Tink
```

**Disable path (user toggles Debugger Server off):**
```
ContentView Toggle -> ProxyServer.stop()
    -> BackgroundKeepalive.shared.stop()
        -> timer.cancel(); player.stop(); engine.stop()
        -> AVAudioSession.setActive(false, .notifyOthersOnDeactivation)
    -> listener.cancel()
    -> isStarted = false
    -> StatusSound.shared.playDisabled()  // Tock
```

**Idle path (proxy running, no user action):**
- BackgroundKeepalive keeps AVAudioEngine running, schedules silent buffer every 3s.
- iOS keeps app alive in background because audio session is active.
- No sound is played — user hears nothing.

## Lifecycle and Error Handling

| Scenario | Behavior |
|---|---|
| `AVAudioSession.setActive(true)` throws | Log error in LogStore, `BackgroundKeepalive.isRunning = false`, proxy continues in foreground; no `StatusSound.playEnabled()` (no success sound on failure) — user sees keepalive subtext stay "Off" |
| `engine.start()` throws | Same as above |
| Incoming call / Siri | `interruptionNotification` handler resumes engine when interruption ends |
| Other app takes over audio | `.mixWithOthers` allows coexistence; BackgroundKeepalive keeps ticking |
| Headphones unplugged | No effect on engine |
| `BackgroundKeepalive.start()` is called when already running | `guard !isRunning else { return }` makes it idempotent |
| App killed by user | Heartbeat gone, must be restarted by re-enabling Debugger Server |
| `BackgroundKeepalive.stop()` is called when not running | Idempotent (timer/stop calls are nil-safe) |
| `StatusSound` plays during silent system (volume = 0) | Silent as expected — that's the user's choice |
| `StatusSound` fails to play (extremely rare for system sounds) | Silent failure; log error if needed |

## File changes

| File | Status | Description |
|---|---|---|
| `HttpRelay/BackgroundKeepalive.swift` | **NEW** | AVAudioEngine + silent buffer; replaces `AudioHeartbeat.swift` |
| `HttpRelay/StatusSound.swift` | **NEW** | `AudioServicesPlaySystemSound` wrapper |
| `HttpRelay/ProxyServer.swift` | Modify | Rename `heartbeatEnabled` -> `backgroundKeepaliveEnabled`; hook StatusSound on start/stop |
| `HttpRelay/ContentView.swift` | Modify | Toggle label "Background Keepalive"; English status subtext |
| `HttpRelay/SettingsView.swift` | Modify | Remove volume Slider; keep toggle |
| `HttpRelay/AudioHeartbeat.swift` | **DELETE** | Replaced by BackgroundKeepalive |
| `HttpRelay/HeartbeatConstants.swift` | **RENAME** | To `StatusSoundConstants.swift` (or similar) |

**Not touched:** `LogStore.swift`, `LogEntry.swift`, `TunnelManager.swift`, `HttpRelayApp.swift`, `Info.plist` (already configured with `UIBackgroundModes: audio`).

## Testing / Verification

### Build verification
```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

### Manual verification (real device)

1. **Tink on enable**
   - Launch app, toggle "Enable Debugger Server" on.
   - Expected: audible Tink sound; UI shows "Keepalive: On".

2. **Tock on disable**
   - With proxy running, toggle "Enable Debugger Server" off.
   - Expected: audible Tock sound; UI subtext disappears.

3. **Background keepalive (silent)**
   - Enable proxy, lock screen.
   - Wait 60 seconds.
   - Return to app.
   - From Windows client, send a new HTTPS request.
   - Expected: log entry appears; TX/RX counters increment; no sound was heard during the 60 seconds.

4. **Volume = 0 still keepalive**
   - Set iOS system volume to 0.
   - Enable proxy (no Tink heard — volume = 0).
   - Lock screen, wait 60s.
   - From Windows client, send a new HTTPS request.
   - Expected: connection succeeds; proxy is alive.

5. **Audio interruption recovery**
   - Enable proxy.
   - Trigger Siri / accept a phone call, then end it.
   - Wait 30s.
   - Expected: new connections still succeed.

6. **Toggle off -> lock screen -> app does not keep alive**
   - Disable proxy, lock screen.
   - Wait 60s.
   - New connections should fail (proxy not running).

### Unit tests

Not introduced. Consistent with project convention.

## Risks

- **App Review still requires audio justification.** This design's justification is more legitimate: Tink/Tock are user-perceivable feedback. App Review may still probe (e.g. "why does a developer-tools app need audio?"). The recommended app-store description (per previous spec) still applies.
- **System sound IDs may change across iOS versions.** System sound IDs are public but not contractually stable. If Tink/Tock breaks on a future iOS, the user would hear nothing — silent failure of the status feature. Acceptable risk.
- **Silent buffer may be flagged as abuse.** Same risk as previous design — but the visible/audible Tink/Tock gives a stronger user-perceivable reason.

## Reference

- Previous design: `docs/superpowers/specs/2026-09-17-background-heartbeat-design.md` (superseded)
- iOS Background Modes docs: https://developer.apple.com/documentation/bundleresources/information_property_list/uibackgroundmodes
- System sound catalog: AudioServicesPlaySystemSound (1057 = Tink, 1054 = Tock)
