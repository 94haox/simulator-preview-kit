# Agent Quickstart

这份文档面向第一次接手 `SimulatorPreviewKit` 的 agent。目标是让你在最短时间内知道：

1. 仓库解决什么问题
2. 入口在哪
3. 怎么跑
4. 该改哪里
5. 出问题先查什么

## 一句话理解

给一个已有的 iOS `.app`，这个 package 可以：

- 在隔离的 simulator device set 里启动它
- 拿到画面
- 把画面放到本地 web 页面
- 把页面里的交互再送回 simulator

宿主应用最终拿到的是一个本地 URL，例如：

```text
http://127.0.0.1:38888/
```

## 你最可能用到的入口

### 宿主接入入口

文件：

- `Sources/SimulatorPreviewKit/LocalWebPreviewSession.swift`

用途：

- 给宿主一个窄接口
- 避免宿主直接碰 `simctl` / 私有 simulator bridge / 本地 HTTP server

最小调用：

```swift
import SimulatorPreviewKit

let preview = LocalWebPreviewSession()
let app = try SimulatorPreviewApp(appBundleURL: appURL)
let url = try await preview.start(app: app)
```

### CLI smoke test 入口

文件：

- `Sources/simulator-preview-demo/main.swift`
- `Sources/simulator-preview-demo/SimulatorPreviewDemo.swift`

命令：

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app --open
```

如果你要验证“宿主内嵌 web preview 容器”这条路径：

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app --embed
```

什么时候先用 CLI：

- 你想验证 package 本身是否工作
- 用户给了一个现成 `.app`
- 你不想先接入宿主应用

## 建议的阅读顺序

### 如果你要接入宿主应用

1. `README.md`
2. `Sources/SimulatorPreviewKit/LocalWebPreviewSession.swift`
3. `Sources/SimulatorPreviewHTTP/PreviewWebServer.swift`

### 如果你要改 simulator session 行为

1. `Sources/SimulatorPreviewCore/SimulatorPreviewApp.swift`
2. `Sources/SimulatorPreviewCore/IsolatedSimulatorHostService.swift`
3. `Sources/SimulatorPreviewCore/SimulatorSupport.swift`

### 如果你要改画面输出

1. `Sources/SimulatorPreviewBridge/PreviewFrameProducer.swift`
2. `Sources/SimulatorPreviewBridge/SimulatorKitDisplayBridge.swift`
3. `Sources/SimulatorPreviewHTTP/EmbeddedWebAssets.swift`

### 如果你要改输入回传

1. `Sources/SimulatorPreviewBridge/PreviewInteractionEvent.swift`
2. `Sources/SimulatorPreviewBridge/DOMKeyboardMapper.swift`
3. `Sources/SimulatorPreviewBridge/SimulatorKitHIDBridge.swift`

## 运行前提

在你继续之前，默认先假设这些条件成立：

- macOS 环境
- 本机装了 Xcode
- 本机装了至少一个 iOS Simulator runtime
- 有一个可安装的 `.app` bundle

如果这些前提不满足，这个仓库本身不负责补环境。

## 常用命令

### 编译

```sh
swift build
```

### 测试

```sh
swift test
```

### 看 demo 帮助

```sh
swift run simulator-preview-demo --help
```

### 真正启动一个 preview

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app --open
```

## 运行时链路

### Host path

```text
LocalWebPreviewSession.start(app:)
  -> IsolatedSimulatorHostService.preparePreviewSession(app:)
  -> SimulatorKitHIDBridge.prepare(session:)
  -> PreviewFrameProducer.start(session:)
  -> PreviewWebServer.start()
  -> return local page URL
```

### Web path

```text
Browser page
  -> GET /
  -> GET /styles.css
  -> GET /app.js
  -> GET /stream/status
  -> GET /stream.m3u8
  -> GET /stream/init.mp4
  -> GET /stream/segments/*.m4s
  -> fallback polling GET /frame
  -> POST /input
```

## 什么时候改哪一层

### 只想换网页样式或前端交互

只动：

- `EmbeddedWebAssets.swift`
- 必要时少量改 `PreviewWebServer.swift`

不要动 simulator bridge。

### 只想换帧传输协议

优先改：

- `PreviewWebServer.swift`
- `PreviewFrameProducer.swift`
- `PreviewVideoStream.swift`

尽量保持 `LocalWebPreviewSession` 对宿主的接口不变。

### 只想支持更多键盘/输入事件

优先改：

- `PreviewInteractionEvent.swift`
- `DOMKeyboardMapper.swift`
- `SimulatorKitHIDBridge.swift`

### 只想换 simulator 选择 / 安装策略

优先改：

- `IsolatedSimulatorHostService.swift`
- `SimulatorSupport.swift`

## 常见坑

### 1. 以为这个仓库负责 build app

不是。这里默认输入是“已有 `.app` bundle”。

### 2. 以为页面打不开就是 web server 坏了

更常见的是 preview session 根本没起来，或者没有新帧。

### 3. 以为输入走 Accessibility

当前主路径不是 CGEvent 打窗口，而是走 SimulatorKit HID bridge。

### 4. 以为这是通用跨平台方案

不是。当前实现强依赖 Apple simulator 私有接口，范围就是 macOS + Xcode simulator。

## 出问题时的排查顺序

### 页面打不开

先查：

1. `LocalWebPreviewSession.start(app:)` 是否成功返回 URL
2. CLI 是否打印了 preview URL
3. 端口是否冲突

### 页面打开但没有画面

先查：

1. `/stream/status` 是否一直 `ready=false`
2. `/stream.m3u8` 是否持续返回 `204`
3. `/frame` 是否持续返回 `204`
4. `PreviewFrameProducer.currentFrame()` 是否为空
5. screenshot fallback 是否成功

### 有画面但不能点

先查：

1. 前端有没有发 `/input`
2. `PreviewInteractionEvent` 解码是否成功
3. `SimulatorKitHIDBridge.prepare(session:)` 是否成功

### 有触摸但键盘不对

先查：

1. `code` / `key` 是否正确上报
2. `DOMKeyboardMapper` 是否覆盖该按键

## 如果你要继续往前做

比较合理的增量方向是：

1. 先补一个真实 `.app` 的端到端 smoke test runbook
2. 再考虑把本地 HLS 流扩成 WebRTC 或远程访问
3. 如果还有必要，再评估是否保留图片 fallback

如果用户没有明确要求，不要直接把当前实现扩成远程公网服务。
