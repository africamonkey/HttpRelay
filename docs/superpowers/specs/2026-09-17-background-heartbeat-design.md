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
- App 启动代理时，激活 `AVAudioSession(.playback)` 并启动 `AVAudioEngine` 循环播放**静音 PCM**。
- 后台播放音频本身需要、也合法化 `UIBackgroundModes: audio` 的存在。
- 静音 PCM 对用户听觉零干扰，但给系统一个明确的"app 仍在工作"的信号。

把静音播放包装成一个对用户有语义的产品功能 —— **"后台心跳提示音"**：
- 心跳开启时：UI 状态区显示 "心跳：开启"，告诉用户代理在后台仍在工作。
- 心跳关闭时：UI 状态区显示 "心跳：关闭"，此时仅前台保持，锁屏后将挂起。

这样 `audio` 后台模式就有了"真实"用途（持续心跳提示），规避了"挂羊头卖狗肉"的设计诟病。

## 范围

**做：**
- 新增 `AudioHeartbeat.swift`（AVAudioEngine + AVAudioPlayerNode 循环静音 PCM）。
- 在 `ProxyServer.start()` / `stop()` 中分别启动/停止心跳。
- 修改 `ContentView` 增加心跳状态文字。
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

    func start() throws          // 配置 session、激活、起 engine、循环 buffer
    func stop()                  // 停 player、停 engine、反激活 session
}
```

- 用 `AVAudioPCMBuffer`（单声道、44.1kHz、约 100ms）填充全 0 样本。
- `player.scheduleBuffer(buffer, at: nil, options: .loops)` 形成循环。
- `mixer.outputVolume = 0` 保证硬件输出仍是静音（双保险：样本本身 + 主混音器音量）。
- 监听 `AVAudioSession.interruptionNotification`：中断结束后若仍处于 `isRunning` 状态，自动恢复 `engine.start()`。

### `ProxyServer` 改动

`start()` 末尾追加：
```swift
do {
    try AudioHeartbeat.shared.start()
} catch {
    logStore.log(host: "-", port: 0, status: .error)
    // 不阻塞代理启动；前台仍可工作。
}
```

`stop()` 开头追加：
```swift
AudioHeartbeat.shared.stop()
```

### `ContentView` 改动

- `@State private var heartbeatOn: Bool = false`，每 0.5s 轮询 `AudioHeartbeat.shared.isRunning` 更新（实际用 `Timer.publish` 或 `onReceive`）。
- 状态行副文字：当 `isRunning && heartbeatOn` → "心跳：开启"（绿色）；否则 "心跳：关闭"（灰色）。
- 文案：使用现有本地化字符串表（如有），否则直接 hardcode（与项目内现有 hardcode 风格一致）。

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
          ├─► engine.connect(player, to: mainMixer, format: silentFormat)
          ├─► engine.start()
          └─► player.scheduleBuffer(silentBuffer, at: nil, options: .loops, ...)
```

停止：
```
用户拨动开关
  → ProxyServer.stop()
      ├─► AudioHeartbeat.shared.stop()
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
      player.play()  // buffer 已被 scheduleBuffer(loops) 持续循环，无需重新 schedule
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
| 心跳启动但 proxy 未启动 | 不会出现：`start()` 调用顺序保证心跳在 listener 启动**之后**或**之前**均可，但只在 proxy start 内被调用 |

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
| `HttpRelay/ProxyServer.swift` | 修改 | start/stop 中 hook AudioHeartbeat |
| `HttpRelay/ContentView.swift` | 修改 | 状态行副文字 "心跳：开启/关闭" |
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
   - 启动 proxy → 锁屏（或切到其他 App）→ 等待 60s → 回到 HttpRelay
   - 从 Windows 侧发起新 HTTPS 请求
   - 预期：日志新增一行 `connected`，TX/RX 计数器递增

2. **心跳启动失败的降级路径**
   - 模拟音频会话被其他 App 占用、`setActive` 抛错的场景（如有 `am instrument` 工具可用）
   - 预期：日志出现 `error` 条目，但 proxy 仍能在前台正常工作；UI 显示"心跳：关闭"

3. **音频中断恢复**
   - 启动 proxy → 触发 Siri/来电 → 挂断 → 等待 30s
   - 预期：新连接仍能成功

4. **App 被杀重启**
   - 启动 → 锁屏 → 在多任务里上滑杀掉 → 重新打开 → 启动 proxy → 锁屏
   - 预期：心跳重新建立，后台保持

5. **多连接压力**
   - 启动 → 后台 → 用 ab / wrk 模拟 50 个并发 HTTPS 请求
   - 预期：所有连接成功，TX/RX 计数与请求量一致

### 单元测试
本次不引入 XCTest。后续若需要，可对 `AudioHeartbeat.start/stop` 做异步 XCTest 覆盖。

## 风险与权衡

- **App Store 审核风险**：`UIBackgroundModes: audio` 必须配真实音频用途，否则可能被拒。
  本设计在静音播放之外加了产品语义（"心跳提示"）和 UI 状态文字，作为合理化依据。
  本项目主要用于个人/团队自用，App Store 风险属可接受范围。

- **电量消耗**：持续后台音频引擎会增加少量耗电。
  静音 PCM + `.mixWithOthers` + 单声道 44.1kHz 已是最低配置。

- **macCatalyst / iPad 行为差异**：Apple Silicon iPad 上后台行为类似，但若用户使用多任务分屏
  心跳被切到非激活窗口时，iPadOS 不会立刻挂起，行为稳定。

## 参考

- `~/work/AirShout/AirShout/Core/Audio/AudioSessionConfig.swift` — AVAudioSession 配置参考
- `~/work/AirShout/Info.plist` — `UIBackgroundModes: audio` 范例
- `~/work/HttpRelay/AGENTS.md` — 现有项目结构与测试策略
