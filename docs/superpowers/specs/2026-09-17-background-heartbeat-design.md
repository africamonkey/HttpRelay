# HttpRelay — 后台心跳保持连接（设计）

日期：2026-09-17

## 背景与目标

HttpRelay 是一个 iOS HTTP CONNECT 代理服务器，让 Windows 客户端把 HTTP/HTTPS 流量通过 iOS 设备中转。
当前问题：当 iOS 设备切到后台，系统会在几秒内挂起进程，NWListener 失去响应，
Windows 侧代理连接中断，用户必须把 iOS 设备留在前台。

目标：让 HttpRelay 在后台（含锁屏状态）持续运行，整个会话周期内 NWListener 保持活跃，
新连接照常被接受。

## 思路（"让 audio 后台模式"用得其所）

iOS 唯一允许"长时间后台运行任意任务"的合法模式之一是 `UIBackgroundModes: audio`，
搭配 `AVAudioSession` 激活会话。本设计复用 AirShout 的成功模式：
- App 启动代理时，激活 `AVAudioSession(.playback)` 并启动 `AVAudioEngine` **周期性播放可听的"滴答"提示音**。
- 后台播放音频本身需要、也合法化 `UIBackgroundModes: audio` 的存在。

把后台播放包装成一个对用户有语义的产品功能 —— **"后台心跳提示音"**：
- 心跳开启时：每 3 秒发出一声极轻的"滴答"音（约 20ms 短脉冲，振幅 ~0.1），
  形似 iOS 后台录音的指示条，告知用户"代理仍在后台工作"。
- 心跳关闭时：UI 状态区显示 "心跳：关闭"，此时仅前台保持，锁屏后将挂起。

**为什么不是静音 PCM：**
静音 PCM 在 iOS 后台保活层面"技术上有效"，但 App Review 规则明确要求
`UIBackgroundModes: audio` 必须有用户可感知的音频内容。纯静音是经典的 abuse pattern，
会被标记为 misuse 并拒绝上架。本设计用真实可听的滴答音，让该后台模式有正当的产品理由。

## 范围

**做：**
- 新增 `AudioHeartbeat.swift`（AVAudioEngine + AVAudioPlayerNode 周期性播放"滴答"提示音）。
- 在 `ProxyServer.start()` / `stop()` 中根据用户开关决定是否启动心跳。
- 修改 `ContentView`：
  - 新增"心跳提示音" toggle（默认开启，proxy 运行前/后都可切换）
  - 状态行显示 "心跳：开启/关闭（后台时）"
- 修改 `SettingsView`：
  - 新增"心跳音量" Slider（0.0 - 1.0，默认 0.3）
  - 持久化到 `UserDefaults`，key: `heartbeatVolume`
- 修改 Xcode project 把 `UIBackgroundModes=audio` 注入 Info.plist。

**不做：**
- 不引入 `XCTest` 单测（与现有项目测试策略一致：构建验证 + 手动验证）。
- 不改 `LogStore`、`LogEntry`、`TunnelManager`、proxy 网络逻辑。
- 不做应用间音频协调优化（仅 `.mixWithOthers` 兜底）。
- 不引入后台远程通知 / push 来唤醒。

## 架构

新增组件：

### `AudioHeartbeat`（单例，文件：`HttpRelay/AudioHeartbeat.swift`）

```
final class AudioHeartbeat {
    static let shared = AudioHeartbeat()
    private(set) var isRunning: Bool = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var timer: DispatchSourceTimer?
    private var volume: Float = 0.3   // 默认 30%

    func start() throws                              // 配置 session、激活、起 engine、起 timer
    func stop()                                      // 停 timer、停 player、停 engine、反激活 session
    func updateVolume(_ value: Float)                // 重新合成 buffer，下一拍生效
}
```

- **滴答音合成**：用一个 100ms 的 `AVAudioPCMBuffer`（单声道、44.1kHz、Float32），
  在前 20ms 写入一个 500Hz 正弦波（带 5ms 淡入淡出），振幅为**用户配置的音量**（默认 0.3）；
  其余样本为 0。
- **调度方式**：每次 timer 触发时 `player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)`，
  然后 `player.play()`；播放完毕后 player 自然停在 idle。
- **周期**：`DispatchSourceTimer`，每 3 秒触发一次。
- **音量实现**：buffer 内的正弦波振幅按 `UserDefaults.standard.double(forKey: "heartbeatVolume")` 写入；
  `mainMixer.outputVolume = 1.0`（保留样本内的真实振幅），用户系统音量自然控制最终响度。
- **运行时调音量**：用户在 SettingsView 拖动 Slider → 写入 `UserDefaults` →
  `AudioHeartbeat.shared.updateVolume(newValue)` → 重新合成并替换 buffer（下一拍生效）。
- **中断恢复**：监听 `AVAudioSession.interruptionNotification`，中断结束后若仍处于 `isRunning`
  状态，重新 `engine.start()` 并恢复 timer。
- **节流**：player 仅在 scheduleBuffer 之后短暂 play，避免持续占用 audio render thread。

### `ProxyServer` 改动

`start()` 末尾追加：
```swift
if heartbeatEnabled {
    do {
        try AudioHeartbeat.shared.start()
    } catch {
        logStore.log(host: "-", port: 0, status: .error)
    }
}
```

`stop()` 开头追加：
```swift
AudioHeartbeat.shared.stop()
```

`heartbeatEnabled` 由 `ContentView` 通过 setter 注入（如 `proxyServer.heartbeatEnabled = heartbeatOn`）。
若 proxy 运行中切换 toggle，立即同步启停 `AudioHeartbeat.shared.start()/stop()`。

### `ContentView` 改动

- `@AppStorage("heartbeatEnabled") private var heartbeatOn: Bool = true`（默认开启）
- `@State private var heartbeatRunning: Bool = false`（来自 `AudioHeartbeat.shared.isRunning`）
- UI 元素：
  - 状态行副文字：`isRunning ? (heartbeatRunning ? "心跳：开启（后台时）" : "心跳：关闭（后台时）") : ""`
  - 在端口 / IP 区域下方加一个 `Toggle("心跳提示音", isOn: $heartbeatOn)`，proxy 运行中也允许切换
- 切换逻辑：proxy 运行时 `heartbeatOn` 的变化立即调用 `AudioHeartbeat.shared.start()/stop()`；
  proxy 停止时仅更新 `heartbeatOn` 持久值，下次启动时按此值决定是否启心跳。
- 文案：直接 hardcode（与项目内现有 hardcode 风格一致）。

### `SettingsView` 改动

在现有 Form 内追加一个 Section：

```
Section {
    Slider(value: $heartbeatVolume, in: 0.0...1.0, step: 0.05) {
        Text("心跳音量")
    }
    HStack {
        Text("预览")
        Spacer()
        Text("\(Int(heartbeatVolume * 100))%")
            .foregroundColor(.secondary)
    }
} header: {
    Text("后台心跳")
} footer: {
    Text("锁屏后代理保持连接时会播放此音量的提示音。设为 0% 可静音。")
}
```

- `@AppStorage("heartbeatVolume") private var heartbeatVolume: Double = 0.3`
- `Slider` onChange 立即调用 `AudioHeartbeat.shared.updateVolume(Float(heartbeatVolume))`
  （若 proxy 未运行则只更新持久值，下次启动生效）

## 生命周期与数据流

启动：
```
用户拨动开关
  → ContentView.isRunning = true
  → ProxyServer.start(port)
      ├─► NWListener.start (既有)
      └─► AudioHeartbeat.shared.start()
          ├─► AVAudioSession.setCategory(.playback, options: .mixWithOthers)
          ├─► AVAudioSession.setActive(true)
          ├─► engine.attach(player)
          ├─► engine.connect(player, to: mainMixer, format: tickFormat)
          ├─► engine.start()
          └─► DispatchSourceTimer.schedule(deadline: now + 3s, repeating: 3s)
              └─► 每 3s：player.scheduleBuffer(tickBuffer) + player.play()
```

停止：
```
用户拨动开关
  → ProxyServer.stop()
      ├─► AudioHeartbeat.shared.stop()
      │     ├─► timer.cancel()
      │     ├─► player.stop()
      │     ├─► engine.stop()
      │     ├─► engine.detach(player)
      │     └─► AVAudioSession.setActive(false, options: .notifyOthersOnDeactivation)
      └─► NWListener.cancel (既有)
```

音频中断恢复：
```
AVAudioSession.interruptionNotification (ended)
  → 若 AudioHeartbeat.shared.isRunning 仍为 true：
      engine.start()
      timer.resume()  // 重新调度下一拍滴答
```

## 边界与错误

| 情形 | 处理 |
|---|---|
| `AVAudioSession.setActive(true)` 抛错 | 捕获异常，LogStore 写 `.error`，isRunning 保持 false；**不阻塞** ProxyServer 启动 |
| `engine.start()` 抛错 | 同上 |
| 来电 / Siri 中断 | 监听 `interruptionNotification`，结束后自动恢复 engine |
| 其他 App 抢占音频 | `.mixWithOthers` 选项允许共存，心跳不被抢占 |
| 耳机拔出 / 路由变化 | 不影响 engine，继续循环 |
| App 被系统彻底杀掉 | 用户重新开启代理时心跳重建，无需特殊处理 |
| 心跳启动但 proxy 未启动 | 不会出现：心跳仅在 proxy start 内被调用 |
| 用户在 proxy 运行中关闭心跳 toggle | 立即 `AudioHeartbeat.shared.stop()`；proxy 继续运行，但锁屏后会被挂起 |
| 用户在 proxy 运行中开启心跳 toggle | 立即 `AudioHeartbeat.shared.start()` |
| 用户在 SettingsView 拖动音量 Slider | `AudioHeartbeat.shared.updateVolume()`，下一拍滴答生效；proxy 未运行时仅持久化 |

## Info.plist 改动

HttpRelay 当前用 Xcode "自动生成 Info.plist"（`GENERATE_INFOPLIST_FILE = YES`）。
在 `HttpRelay.xcodeproj/project.pbxproj` 的两个 Debug/Release build configuration 中追加：

```
INFOPLIST_KEY_UIBackgroundModes = "audio";
```

（Xcode 自动生成的 INFOPLIST_KEY 形式会以单空格分隔字符串展开为 array，
不需要新建 Info.plist 文件。）

不引入 `INFOPLIST_KEY_*` 之外的额外 plist 键。

## 文件改动清单

| 文件 | 类型 | 说明 |
|---|---|---|
| `HttpRelay/AudioHeartbeat.swift` | 新增 | AVAudioEngine 心跳封装 |
| `HttpRelay/ProxyServer.swift` | 修改 | start/stop 中按开关状态 hook AudioHeartbeat；暴露 `heartbeatEnabled` |
| `HttpRelay/ContentView.swift` | 修改 | 心跳 toggle、状态行副文字 "心跳：开启/关闭（后台时）" |
| `HttpRelay/SettingsView.swift` | 修改 | 新增"心跳音量" Slider 段 |
| `HttpRelay.xcodeproj/project.pbxproj` | 修改 | 添加 `INFOPLIST_KEY_UIBackgroundModes = "audio"` |

不改动：`LogStore.swift`、`LogEntry.swift`、`TunnelManager.swift`、`HttpRelayApp.swift`。

## 测试 / 验证

### 构建验证
```
xcodebuild -project HttpRelay.xcodeproj -scheme HttpRelay \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
必须 BUILD SUCCEEDED。

### 手动验证（模拟器 + 真机）

1. **后台存活（核心）**
   - 启动 proxy（心跳默认开启）→ 锁屏（或切到其他 App）→ 等待 60s → 回到 HttpRelay
   - 从 Windows 侧发起新 HTTPS 请求
   - 预期：日志新增一行 `connected`，TX/RX 计数器递增

2. **心跳 UI 开关**
   - 启动 proxy → 关闭"心跳提示音"toggle → 锁屏 → 等待 60s
   - 预期：锁屏后 proxy 挂起，新连接不响应；回到前台后恢复
   - 再开启 toggle → 锁屏 → 预期：保持连接

3. **心跳音量**
   - 启动 proxy → 进入 Settings → 把音量拖到 0% → 回到主界面听 10 秒
   - 预期：完全静音
   - 把音量拖到 100% → 预期：滴答音明显可听
   - 把音量拖到 30%（默认）→ 预期：能听到但不影响日常

3. **心跳启动失败的降级路径**
   - 模拟音频会话被其他 App 占用、`setActive` 抛错的场景（如有 `am instrument` 工具可用）
   - 预期：日志出现 `error` 条目，但 proxy 仍能在前台正常工作；UI 显示"心跳：关闭"

3. **音频中断恢复**
   - 启动 proxy → 触发 Siri/来电 → 挂断 → 等待 30s
   - 预期：新连接仍能成功

6. **滴答音可听性**
   - 启动 proxy → 静音环境 → 听 10 秒
   - 预期：可听到每 3 秒一次的轻微"滴"声；系统音量调至 0 时听不到（预期内）

4. **App 被杀重启**
   - 启动 → 锁屏 → 在多任务里上滑杀掉 → 重新打开 → 启动 proxy → 锁屏
   - 预期：心跳重新建立，后台保持

5. **多连接压力**
   - 启动 → 后台 → 用 ab / wrk 模拟 50 个并发 HTTPS 请求
   - 预期：所有连接成功，TX/RX 计数与请求量一致

### 单元测试
本次不引入 XCTest。后续若需要，可对 `AudioHeartbeat.start/stop` 做异步 XCTest 覆盖。

## 风险与权衡

- **App Store 审核风险**：`UIBackgroundModes: audio` 必须有真实可听的音频内容。
  本设计以"后台心跳提示音"为产品语义（每 3s 一次轻滴答），UI 上**提供用户可关闭的 toggle**，
  让用户对后台音频有控制权 —— 这是 Apple 审核的重要信号。
  本项目主要用于个人/团队自用，App Store 风险属可接受范围。
  后续发布到 App Store 时，**建议在应用描述里写明**：
  > "HttpRelay 作为 HTTP CONNECT 代理服务器，需在后台持续监听端口以保持连接。
  > 可关闭的心跳提示音用于告知用户代理仍在后台运行。"
  这段描述是把 audio 后台模式"合理化"的关键。

- **电量 / 用户体验**：周期性滴答音每 3s 一次，每次 20ms，对电量影响极小；
  音量由用户系统音量控制；用户可从 UI 看到"心跳：开启"状态并预期到声音存在。

- **macCatalyst / iPad 行为差异**：Apple Silicon iPad 上后台行为类似，但若用户使用多任务分屏
  心跳被切到非激活窗口时，iPadOS 不会立刻挂起，行为稳定。

## 参考

- `~/work/AirShout/AirShout/Core/Audio/AudioSessionConfig.swift` — AVAudioSession 配置参考
- `~/work/AirShout/Info.plist` — `UIBackgroundModes: audio` 范例
- `~/work/HttpRelay/AGENTS.md` — 现有项目结构与测试策略
