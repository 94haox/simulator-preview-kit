# SimulatorPreviewKit

`SimulatorPreviewKit` 是一个独立的 macOS Swift Package。它把 iOS Simulator 的隔离 session、画面采集和本地 web 预览剥离成可复用模块，方便别的宿主应用按 SPM 方式接入。

它不试图替代 Xcode 或完整 IDE，而是专注提供一条明确的能力链路：

1. 启动隔离的 simulator device set
2. 安装并启动已有 `.app` bundle
3. 采集 simulator 画面
4. 通过本地 `http://127.0.0.1:<port>/` 页面显示
5. 将网页中的点击、滚动、键盘输入回传给 simulator

## 适合什么场景

- 宿主应用已经能产出一个 iOS `.app`
- 宿主希望把 preview 显示在自己的 web 容器里
- 宿主不想直接承担 `simctl`、私有 Simulator bridge、本地 HTTP server 的细节

## 不适合什么场景

- 需要这个仓库负责构建 iOS 工程
- 需要公网远程访问
- 需要跨平台支持
- 需要标准公开 API、避免 Apple 私有桥接

## 快速开始

### 方式 1：先用 CLI demo 验证链路

```sh
swift build
swift run simulator-preview-demo --app /path/to/MyApp.app --open
```

如果一切正常，命令会打印一个本地 URL，例如：

```text
http://127.0.0.1:38888/
```

页面会自动打开，里面显示 simulator 画面。点击页面里的设备区域后，触摸、滚动和键盘事件会回传给 simulator。

### 方式 2：直接在宿主工程中接入

```swift
import SimulatorPreviewKit

let preview = LocalWebPreviewSession()
let app = try SimulatorPreviewApp(appBundleURL: appURL)
let pageURL = try await preview.start(app: app)

print(pageURL)
```

宿主应用只需要把 `pageURL` 放进自己的 web preview 容器即可。

## 运行前提

开始之前，默认需要满足这些条件：

- macOS 环境
- 本机已安装 Xcode
- 本机已安装至少一个 iOS Simulator runtime
- 输入是一个已有的 `.app` bundle
- `.app/Info.plist` 中存在 `CFBundleIdentifier`

如果这些条件不满足，这个 package 本身不会帮你补环境。

## 模块结构

- `SimulatorPreviewCore`
  - `ProcessRunner`
  - `SimulatorPreviewApp`
  - `IsolatedSimulatorHostService`
  - `SelectedSimulator` / `IsolatedSimulatorSession`
  - 负责 app bundle、device set、`simctl`、session 生命周期

- `SimulatorPreviewBridge`
  - `SimulatorKitDisplayBridge`
  - `SimulatorKitHIDBridge`
  - `PreviewFrameProducer`
  - `PreviewInteractionEvent`
  - 负责画面采集和输入回传

- `SimulatorPreviewHTTP`
  - `SimpleHTTPServer`
  - `PreviewWebServer`
  - `EmbeddedWebAssets`
  - 负责本地页面、帧接口和输入接口

- `SimulatorPreviewKit`
  - `LocalWebPreviewSession`
  - 面向宿主的薄接口

- `simulator-preview-demo`
  - 一个最小 CLI demo

## 公开入口

### `SimulatorPreviewApp`

用来包装一个已有 `.app` bundle：

```swift
let app = try SimulatorPreviewApp(appBundleURL: appURL)
```

它会做这些事：

- 校验路径是不是 `.app`
- 读取 `Info.plist`
- 解析 `CFBundleIdentifier`
- 推断展示名称

### `LocalWebPreviewSession`

宿主真正该依赖的是这个类型：

```swift
let session = LocalWebPreviewSession()
let pageURL = try await session.start(app: app)
```

它负责：

- 准备 isolated simulator session
- 准备 HID bridge
- 启动画面采集
- 启动本地 web server
- 返回页面 URL

如果宿主需要生命周期控制：

```swift
await session.stop()
```

如果宿主想临时打开外部 `Simulator.app` 看同一个 session：

```swift
try session.openSimulatorWindow()
```

## CLI demo 参数

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app \
  [--port 38888] \
  [--device "iPhone 17"] \
  [--open] \
  [--embed] \
  [--frame-interval-ms 120]
```

参数说明：

- `--app`
  - 必填，已有 `.app` bundle 路径
- `--port`
  - 本地 web server 端口，默认 `38888`
- `--device`
  - 指定 simulator 设备名；不传时会按默认优先级挑一个 iPhone
- `--open`
  - 启动后自动用浏览器打开页面
- `--embed`
  - 启动后直接用一个内嵌 `WKWebView` 窗口承载 preview 页面，模拟宿主应用里的 web preview 容器
- `--frame-interval-ms`
  - 帧采样间隔，默认 `120ms`。同时影响 HLS 视频流的取帧节奏和图片 fallback 的刷新节奏。

## 运行时链路

### 宿主侧链路

```text
LocalWebPreviewSession.start(app:)
  -> IsolatedSimulatorHostService.preparePreviewSession(app:)
  -> SimulatorKitHIDBridge.prepare(session:)
  -> PreviewFrameProducer.start(session:)
  -> PreviewVideoStream.start()
  -> PreviewWebServer.start()
  -> return page URL
```

### 页面侧链路

```text
GET /
GET /styles.css
GET /app.js
GET /stream/status
GET /stream.m3u8
GET /stream/init.mp4
GET /stream/segments/*.m4s
fallback polling GET /frame
POST /input
```

## 当前实现边界

- 输入回传已接通：touch / scroll / keyboard
- 画面输出现在是**本地 HLS 视频流优先**，页面在视频流未就绪时自动回退到图片帧轮询
- 预览输入依赖 Apple 私有 simulator / HID bridge
- 当前只覆盖 `已有 .app bundle -> web preview`
- 不负责构建 `.app`

## 其它 agent 的建议入口

如果你是新进入这个仓库的 agent，不要直接从 bridge 细节开始。按这个顺序看：

1. [AGENTS.md](AGENTS.md)
2. [docs/agent-quickstart.md](docs/agent-quickstart.md)
3. [docs/plans/2026-04-20-simulator-preview-kit-design.md](docs/plans/2026-04-20-simulator-preview-kit-design.md)
4. `Sources/SimulatorPreviewKit/LocalWebPreviewSession.swift`

## 排查建议

### 页面打不开

先看：

- `LocalWebPreviewSession.start(app:)` 是否成功
- CLI 是否打印了 URL
- 端口是否被占用

### 页面打开但没有画面

先看：

- `/stream/status` 里的 `ready` 是否一直是 `false`
- `/stream.m3u8` 是否返回 `204`
- `/frame` 是否一直返回 `204`
- `PreviewFrameProducer.currentFrame()` 是否为空
- screenshot fallback 是否能成功

### 有画面但不能交互

先看：

- `/input` 请求有没有发出去
- `PreviewInteractionEvent` 是否正确解码
- `SimulatorKitHIDBridge.prepare(session:)` 是否成功

## 验证命令

```sh
swift build
swift test
swift run simulator-preview-demo --help
```
