# Background Heartbeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make HttpRelay keep its TCP listener alive while the iOS app is in the background, by activating an `AVAudioSession` + `AVAudioEngine` that emits an audible 500 Hz "tick" every 3 seconds. The tick is the product-justified use of `UIBackgroundModes: audio`.

**Architecture:** Add a singleton `AudioHeartbeat` that owns an `AVAudioEngine` + `AVAudioPlayerNode` and a 3-second `DispatchSourceTimer`. Each tick schedules a 100 ms buffer containing a 20 ms 500 Hz sine burst (amplitude 1.0, fixed) and plays it. User volume is `mainMixer.outputVolume` (default 0.3) so volume = 0 is silent but engine still renders. ProxyServer hooks `start()`/`stop()`; ContentView exposes a toggle; SettingsView exposes a Slider.

**Tech Stack:** SwiftUI (iOS 26.2), AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioSession`, `AVAudioPCMBuffer`), Network framework (existing), DispatchSourceTimer.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `HttpRelay/AudioHeartbeat.swift` | **NEW** | AVAudioEngine singleton; buffer synthesis; 3-second tick timer; volume control; interruption recovery |
| `HttpRelay/ProxyServer.swift` | Modify | Call `AudioHeartbeat.shared.start()/stop()` around network start/stop; expose `heartbeatEnabled` toggle setter |
| `HttpRelay/ContentView.swift` | Modify | Add "心跳提示音" Toggle + status subtext below IP/Port block |
| `HttpRelay/SettingsView.swift` | Modify | Add "后台心跳" section with volume Slider + percentage label |
| `HttpRelay.xcodeproj/project.pbxproj` | Modify | Add `INFOPLIST_KEY_UIBackgroundModes = "audio"` to both Debug and Release configurations |

**Not touched:** `LogStore.swift`, `LogEntry.swift`, `TunnelManager.swift`, `SOCKS5.swift`, `HttpRelayApp.swift`.

---

## Task 1: Create AudioHeartbeat singleton skeleton

**Files:**
- Create: `HttpRelay/AudioHeartbeat.swift`

- [ ] **Step 1: Create the file with the singleton skeleton**

Create `HttpRelay/AudioHeartbeat.swift` with this exact content:

```swift
import Foundation
import AVFoundation

final class AudioHeartbeat {
    static let shared = AudioHeartbeat()

    private(set) var isRunning: Bool = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: DispatchSourceTimer?
    private var buffer: AVAudioPCMBuffer?

    private init() {}

    func start() throws {
        try configureSession()
        try prepareEngine()
        try prepareBuffer()
        startTimer()
        isRunning = true
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player.stop()
        engine.stop()
        engine.detach(player)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[AudioHeartbeat] setActive(false) failed: \(error)")
        }
        isRunning = false
    }

    func updateVolume(_ value: Float) {
        engine.mainMixerNode.outputVolume = max(0.0, min(1.0, value))
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    private func prepareEngine() throws {
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.3
        try engine.start()
    }

    private func prepareBuffer() throws {
        let sampleRate: Double = 44100
        let frameCapacity = AVAudioFrameCount(sampleRate * 0.1)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!, frameCapacity: frameCapacity) else {
            throw NSError(domain: "AudioHeartbeat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate PCM buffer"])
        }
        pcmBuffer.frameLength = frameCapacity
        guard let channel = pcmBuffer.floatChannelData?[0] else {
            throw NSError(domain: "AudioHeartbeat", code: 2, userInfo: [NSLocalizedDescriptionKey: "PCM buffer has no channel data"])
        }
        let amplitude: Float = 1.0
        let frequency: Float = 500.0
        let twoPi: Float = 2.0 * .pi
        for i in 0..<Int(frameCapacity) {
            let t = Float(i) / Float(sampleRate)
            if i < Int(sampleRate * 0.020) {
                let envelope: Float
                let sampleIndex = i
                let fadeFrames = Int(sampleRate * 0.005)
                if sampleIndex < fadeFrames {
                    envelope = Float(sampleIndex) / Float(fadeFrames)
                } else if sampleIndex > Int(sampleRate * 0.020) - fadeFrames {
                    envelope = Float(Int(sampleRate * 0.020) - sampleIndex) / Float(fadeFrames)
                } else {
                    envelope = 1.0
                }
                channel[i] = amplitude * envelope * sin(twoPi * frequency * t)
            } else {
                channel[i] = 0.0
            }
        }
        self.buffer = pcmBuffer
    }

    private func startTimer() {
        let queue = DispatchQueue(label: "com.africamonkey.httprelay.heartbeat")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3.0, repeating: 3.0)
        t.setEventHandler { [weak self] in
            guard let self = self, let buffer = self.buffer else { return }
            self.player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            self.player.play()
        }
        t.resume()
        self.timer = t
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run from the project root:
```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`. (The new file is not yet referenced from anywhere, so Swift won't actually call `start()`. Compile-check only.)

- [ ] **Step 3: Add the new file to the Xcode project**

The file is on disk but not in the project's file list yet. Use the Edit tool on `HttpRelay.xcodeproj/project.pbxproj` to register it.

Open the file and add the new file's `PBXFileReference`, the `PBXBuildFile`, and entries inside the `HttpRelay` group's `children = (...)` list and the target's `sources = (...)` phase. The exact UUIDs to add are generated by you (use `24-hex-char` unique IDs that don't collide).

For reference, locate a similar single-file Swift entry already in the project (e.g. `LogEntry.swift`, `LogStore.swift`) and mirror its 3 entries (file ref, build file, group/source phase insertion) for `AudioHeartbeat.swift`.

If you can't confidently edit `project.pbxproj`, stop and ask the user — they prefer we don't risk corrupting it.

Expected after this step: `xcodebuild` finds and compiles `AudioHeartbeat.swift` (no actual symbol references yet — that's OK).

- [ ] **Step 4: Commit**

```bash
git add HttpRelay/AudioHeartbeat.swift HttpRelay.xcodeproj/project.pbxproj
git commit -m "feat: add AudioHeartbeat singleton (skeleton, not yet wired)"
```

---

## Task 2: Add Info.plist UIBackgroundModes=audio

**Files:**
- Modify: `HttpRelay.xcodeproj/project.pbxproj:402-411` (Debug config) and `:439-448` (Release config)

> Apple Xcode generates the actual `Info.plist` from `INFOPLIST_KEY_*` build settings. Adding the key below makes `UIBackgroundModes = ["audio"]` end up in the generated plist. No manual Info.plist editing required.

- [ ] **Step 1: Add the build setting to the Debug configuration**

In `HttpRelay.xcodeproj/project.pbxproj`, find the Debug app-target buildSettings block (the one that already has `INFOPLIST_KEY_CFBundleDisplayName = "HTTP Debugger+";`). Add this line **inside that block**, in alphabetical order with the other `INFOPLIST_KEY_*` entries (after `INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;` and before `INFOPLIST_KEY_UILaunchScreen_Generation = YES;`):

```
				INFOPLIST_KEY_UIBackgroundModes = "audio";
```

The exact line including the leading tab characters is critical — match the indentation of the neighboring `INFOPLIST_KEY_*` lines.

- [ ] **Step 2: Add the same build setting to the Release configuration**

Find the second block (Release app-target buildSettings — also has `INFOPLIST_KEY_CFBundleDisplayName = "HTTP Debugger+";`) and add the same line in the same relative position.

- [ ] **Step 3: Verify the generated plist contains UIBackgroundModes**

Build once and inspect the generated `Info.plist`:
```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Then:
```bash
find ~/Library/Developer/Xcode/DerivedData/HttpRelay-* -name 'Info.plist' -path '*/Debug-iphonesimulator/*' | head -1 | xargs /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes"
```
Expected output: `Array { audio }`. If empty or missing, the key was inserted in the wrong location — re-check indentation and block.

- [ ] **Step 4: Commit**

```bash
git add HttpRelay.xcodeproj/project.pbxproj
git commit -m "feat: declare UIBackgroundModes=audio for proxy keepalive"
```

---

## Task 3: Wire AudioHeartbeat into ProxyServer

**Files:**
- Modify: `HttpRelay/ProxyServer.swift:4-21, 62-96`

- [ ] **Step 1: Add `heartbeatEnabled` property to ProxyServer**

Replace the entire `ProxyServer` class declaration (lines 4-21) with:

```swift
final class ProxyServer {
    typealias ConnectionHandler = (NWConnection) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private let logStore: LogStore
    private let socks5Server: SOCKS5Server
    private var activeTunnels: [String: TunnelManager] = [:]
    private let tunnelsLock = NSLock()
    private(set) var localIP: String = "—"

    var onLocalIPReady: ((String) -> Void)?

    var heartbeatEnabled: Bool = true {
        didSet {
            guard isStarted else { return }
            if heartbeatEnabled {
                startHeartbeat()
            } else {
                AudioHeartbeat.shared.stop()
            }
        }
    }

    private var isStarted = false

    init(port: UInt16 = 10808, logStore: LogStore) {
        self.port = port
        self.logStore = logStore
        self.socks5Server = SOCKS5Server(logStore: logStore)
    }
```

Note: `var heartbeatEnabled` is `Bool` with default `true`, matching the spec.

- [ ] **Step 2: Add heartbeat start/stop hooks to ProxyServer.start() and .stop()**

Replace `start()` (line 62-90) so it ends with the heartbeat hook:

```swift
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[ProxyServer] listening on port \(self.port)")
                self.localIP = self.getLocalIPAddress() ?? "—"
                print("[ProxyServer] local IP: \(self.localIP)")
                self.socks5Server.setLocalIP(self.localIP)
                self.onLocalIPReady?(self.localIP)
            case .failed(let error):
                print("[ProxyServer] failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            print("[ProxyServer] new connection from \(connection.endpoint)")
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: .main)
        isStarted = true
        if heartbeatEnabled {
            startHeartbeat()
        }
    }
```

Replace `stop()` (line 92-96) to start with the heartbeat teardown:

```swift
    func stop() {
        AudioHeartbeat.shared.stop()
        listener?.cancel()
        listener = nil
        socks5Server.stop()
        isStarted = false
    }
```

- [ ] **Step 3: Add the private `startHeartbeat()` helper**

Insert this new method just after `stop()` (i.e., between the closing brace of `stop()` and the next existing method in the file). The simplest place is at the end of the class — after the existing `getLocalIPAddress()`-related helpers. **Search for the `findTunnelKey` method (around line 150-ish) and insert the new helper just before it.** If the file is ordered differently in your checkout, just add it at the end of the class before the closing brace.

```swift
    private func startHeartbeat() {
        let initialVolume = Float(UserDefaults.standard.double(forKey: "heartbeatVolume"))
        let volume = initialVolume == 0 ? 0.3 : initialVolume
        AudioHeartbeat.shared.updateVolume(volume)
        do {
            try AudioHeartbeat.shared.start()
        } catch {
            print("[ProxyServer] heartbeat start failed: \(error)")
        }
    }
```

Why read `UserDefaults` here: the volume Slider is in SettingsView. When the proxy starts, we want the most recent user choice applied immediately. If the key is absent (`double(forKey:)` returns 0), we fall back to the spec's default of 0.3.

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`. If you see "Cannot find 'AudioHeartbeat' in scope", Task 1's pbxproj registration didn't take — re-check.

- [ ] **Step 5: Commit**

```bash
git add HttpRelay/ProxyServer.swift
git commit -m "feat: hook AudioHeartbeat into ProxyServer start/stop"
```

---

## Task 4: Add heartbeat toggle + status subtext in ContentView

**Files:**
- Modify: `HttpRelay/ContentView.swift:1-21, 116-141`

- [ ] **Step 1: Add the new state variables**

Replace the `@State` declarations block (lines 5-20) so it now includes the heartbeat toggle persistence and the heartbeat status. Specifically, after line 20 (`@AppStorage("showTutorial") private var showTutorialOnStart: Bool = true`), add:

```swift
    @AppStorage("heartbeatEnabled") private var heartbeatOn: Bool = true
    @State private var heartbeatRunning: Bool = false
```

- [ ] **Step 2: Add a timer that polls `AudioHeartbeat.shared.isRunning`**

Inside the `Toggle` setter binding (the giant `Binding(get:set:)` for `isRunning` near line 26), do NOT add polling logic — instead, add a `Timer.publish` style poll elsewhere. The cleanest spot: add a `.task` modifier on the `NavigationStack` (or on the outer `VStack`) that polls every 0.5s.

Add this `.task` modifier to the outer `VStack` (find the chain `.padding() ... .toolbar { ... }` — add `.task` immediately after `.padding()`):

```swift
            .padding()
            .task {
                while !Task.isCancelled {
                    heartbeatRunning = AudioHeartbeat.shared.isRunning
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
```

- [ ] **Step 3: Insert the heartbeat Toggle + status subtext below the IP/Port block**

Find the IP/Port `VStack` block — it ends just before `filterBar` (line 122). The block currently has `.padding()` `.background(Color(.systemGray6)) .cornerRadius(12)` (lines 118-120).

Insert a new block **between the IP/Port VStack and `filterBar`**:

```swift
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $heartbeatOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("心跳提示音")
                            if isRunning {
                                Text(heartbeatRunning ? "心跳：开启" : "心跳：关闭")
                                    .font(.caption)
                                    .foregroundColor(heartbeatRunning ? .green : .secondary)
                            }
                        }
                    }
                    .onChange(of: heartbeatOn) { _, newValue in
                        if isRunning, let server = proxyServer {
                            server.heartbeatEnabled = newValue
                        }
                    }
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)

```

- [ ] **Step 4: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add HttpRelay/ContentView.swift
git commit -m "feat: heartbeat toggle + status subtext in ContentView"
```

---

## Task 5: Add heartbeat volume Slider in SettingsView

**Files:**
- Modify: `HttpRelay/SettingsView.swift:1-42`

- [ ] **Step 1: Add the AppStorage property and new Section**

Replace the entire `body` of `SettingsView` so the new section is included. The result should be:

```swift
struct SettingsView: View {
    @AppStorage("showTutorial") private var showTutorial: Bool = true
    @AppStorage("heartbeatEnabled") private var heartbeatEnabled: Bool = true
    @AppStorage("heartbeatVolume") private var heartbeatVolume: Double = 0.3
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Tutorial on Startup", isOn: $showTutorial)
                } footer: {
                    Text("When enabled, the setup guide will appear each time you start the debugger server.")
                }

                Section {
                    Toggle("Heartbeat Sound", isOn: $heartbeatEnabled)
                    Slider(value: $heartbeatVolume, in: 0.0...1.0, step: 0.05) {
                        Text("Heartbeat Volume")
                    }
                    HStack {
                        Text("Volume")
                        Spacer()
                        Text("\(Int(heartbeatVolume * 100))%")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Background Keepalive")
                } footer: {
                    Text("When enabled, the proxy keeps its connection in the background by emitting an audible tick. Set volume to 0% for silence — the connection still stays alive.")
                }
                .onChange(of: heartbeatVolume) { _, newValue in
                    AudioHeartbeat.shared.updateVolume(Float(newValue))
                }

                Section {
                    Link(destination: URL(string: "https://github.com/africamonkey/HttpRelay")!) {
                        Text("Github Repository")
                    }
                    NavigationLink(destination: AboutView()) {
                        Text("About")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
```

Notes:
- The default of 0.3 matches the spec.
- The volume Slider writes to `UserDefaults.standard` via `@AppStorage`. When changed, `.onChange` calls `AudioHeartbeat.shared.updateVolume(...)` — if the proxy isn't running, this is a harmless no-op on a stopped engine; if it is running, it takes effect on the next tick (≤ 3 s).
- The `Heartbeat Sound` toggle mirrors the ContentView toggle so the user can also flip it here. Both write to the same `UserDefaults` key `heartbeatEnabled`.

- [ ] **Step 2: Build to verify**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add HttpRelay/SettingsView.swift
git commit -m "feat: heartbeat volume slider + mirror toggle in Settings"
```

---

## Task 6: End-to-end build verification

**Files:** none (verification only)

- [ ] **Step 1: Clean build**

```bash
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' clean build
```
Expected: `BUILD SUCCEEDED`. Fix any compile errors before moving on.

- [ ] **Step 2: Confirm generated plist still has UIBackgroundModes=audio**

```bash
find ~/Library/Developer/Xcode/DerivedData/HttpRelay-* -name 'Info.plist' -path '*/Debug-iphonesimulator/*' | head -1 | xargs /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes"
```
Expected: `Array { audio }`. If the array is empty or the key is gone, Task 2's edit got overwritten by another build setting insertion — re-check.

- [ ] **Step 3: Manual smoke test on simulator**

```bash
open -a Simulator
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/HttpRelay-*/Build/Products/Debug-iphonesimulator/HttpRelay.app
xcrun simctl launch booted com.africamonkey.HttpRelay
```

Then in the running app:
1. Toggle "Enable Debugger Server" on.
2. Press Cmd+Shift+H to go home (simulating background).
3. Wait 30 seconds.
4. Return to HttpRelay.
5. Verify the app did not crash and the listener is still in the "Running" state.

Note: the simulator does not enforce background-suspension the same way a real device does, so this is a smoke test, not a full background-test. Real-device verification is required for the spec's "核心：后台存活" test (see Task 7).

- [ ] **Step 4: Commit any incidental fixes**

If steps 1-3 surfaced minor issues you fixed (typos, missing parens, etc.):
```bash
git add -A
git commit -m "fix: post-integration cleanup"
```

---

## Task 7: Manual verification checklist (real device, requires human)

**Files:** none — verification only

The spec defines 9 manual tests. Run them in order on a real iOS device. Each test must pass before the feature is "done."

- [ ] **Test 1 — 后台存活（核心）**
  1. Launch app, enable proxy (heartbeat on by default).
  2. Lock screen (or switch to another app).
  3. Wait 60 seconds.
  4. Unlock / return to app.
  5. From a Windows client, issue a new HTTPS request through the proxy.
  6. **Expected:** A new log entry appears, TX/RX counters increment.

- [ ] **Test 2 — 心跳 UI 开关**
  1. Launch app, enable proxy.
  2. Toggle off "心跳提示音".
  3. Lock screen.
  4. Wait 60 seconds.
  5. **Expected:** Lock-screen disconnect — new requests from Windows fail/time out.
  6. Return to app, toggle on "心跳提示音", lock screen, wait 60s.
  7. **Expected:** Connections succeed (back to the keepalive state).

- [ ] **Test 3 — 心跳音量**
  1. Launch app, enable proxy.
  2. Open Settings, drag volume slider to 0%.
  3. Return to main screen, listen for 10 seconds.
  4. **Expected:** Silence.
  5. Drag to 100%, listen.
  6. **Expected:** Tick is clearly audible.
  7. Drag to 30% (default), listen.
  8. **Expected:** Audible but unobtrusive.

- [ ] **Test 4 — 音量 0% 仍保活（关键）**
  1. Launch app, enable proxy.
  2. Settings → volume → 0%.
  3. Lock screen.
  4. Wait 60 seconds.
  5. Return to app.
  6. From Windows, issue new HTTPS request.
  7. **Expected:** New log entry, TX/RX increment. **This is the core guarantee** — silence ≠ suspended.

- [ ] **Test 5 — 心跳启动失败的降级路径**
  1. Hard to simulate reliably without an audio-session-conflict scenario. If you can arrange one (e.g. start another app that holds the audio session exclusively), do so.
  2. **Expected:** App's log shows a heartbeat-start error, but proxy still runs in the foreground; UI shows "心跳：关闭".

- [ ] **Test 6 — 音频中断恢复**
  1. Launch app, enable proxy.
  2. Trigger Siri or accept an incoming call, then end it.
  3. Wait 30 seconds.
  4. **Expected:** New connections still succeed.

- [ ] **Test 7 — 滴答音可听性**
  1. Launch app, enable proxy.
  2. In a quiet environment, listen for 10 seconds.
  3. **Expected:** Audible "tick" once per 3 seconds. (If iOS system volume is at 0, it's silent — that's expected.)

- [ ] **Test 8 — App 被杀重启**
  1. Launch app, enable proxy, lock screen.
  2. From the app switcher, swipe up to kill the app.
  3. Re-launch, enable proxy, lock screen.
  4. **Expected:** Heartbeat re-establishes, background keepalive works again.

- [ ] **Test 9 — 多连接压力**
  1. Launch app, enable proxy.
  2. Send to background.
  3. From a host machine, run `wrk -t 4 -c 50 -H "Host: example.com" --proxy <iOS-IP>:10808 https://example.com/` (or similar).
  4. **Expected:** All connections succeed; TX/RX in app reflect total bytes.

---

## Self-Review Checklist (do not skip)

When all tasks above are done:

- [ ] All 5 file changes are committed.
- [ ] `xcodebuild ... build` succeeds from a clean state.
- [ ] Generated `Info.plist` contains `UIBackgroundModes = [audio]`.
- [ ] At least tests 1, 3, 4, 6, 7 pass on a real device. (Tests 2, 5, 8, 9 are bonus coverage; if any fail, investigate and fix before considering the feature complete.)
