# SimulatorPreviewKit 使用说明

这份文档给宿主开发者。目标是让你在自己的工程里把 `SimulatorPreviewKit` 跑起来，并知道每个参数、每个接口的用法与边界。

如果你是第一次接手这个仓库，先看 [agent-quickstart.md](agent-quickstart.md)；如果你想直接用，看本文即可。

## 目录

- [1. 运行前提](#1-运行前提)
- [2. 安装](#2-安装)
- [3. 最小示例](#3-最小示例)
- [4. 核心类型](#4-核心类型)
  - [4.1 `SimulatorPreviewApp`](#41-simulatorpreviewapp)
  - [4.2 `LocalWebPreviewSession`](#42-localwebpreviewsession)
  - [4.3 `LocalWebPreviewConfiguration`](#43-localwebpreviewconfiguration)
  - [4.4 `PreviewWebServerConfiguration`](#44-previewwebserverconfiguration)
- [5. 生命周期](#5-生命周期)
- [6. 在宿主 app 中嵌入 preview 页面](#6-在宿主-app-中嵌入-preview-页面)
- [7. CLI demo](#7-cli-demo)
- [8. Web 端接口](#8-web-端接口)
- [9. 常见配置建议](#9-常见配置建议)
- [10. 错误与排查](#10-错误与排查)
- [11. 能力边界](#11-能力边界)

## 1. 运行前提

在使用 `SimulatorPreviewKit` 之前，你的环境需要满足：

- macOS 13 或更高（`Package.swift` 中 `platforms: [.macOS(.v13)]`）
- 已安装 Xcode
- 至少装了一个 iOS Simulator runtime
- 手上已有一个可安装的 `.app` bundle（本 package 不负责构建 `.app`）
- `.app/Info.plist` 里存在 `CFBundleIdentifier`

如果任意一条不满足，这个 package 本身**不会**帮你补环境，会在 `start(app:)` 阶段抛错。

## 2. 安装

在宿主工程的 `Package.swift` 中加入依赖：

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YourHostApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://example.com/your-fork/simulator-preview-kit.git", branch: "main")
    ],
    targets: [
        .target(
            name: "YourHostApp",
            dependencies: [
                .product(name: "SimulatorPreviewKit", package: "simulator-preview-kit")
            ]
        )
    ]
)
```

> 仓库 URL 按你实际镜像填写。包名固定是 `SimulatorPreviewKit`。

库产物一览（如果只需要宿主入口，只需要 `SimulatorPreviewKit`）：

| 产物 | 用途 |
| --- | --- |
| `SimulatorPreviewKit` | 宿主主要依赖的薄接口（`LocalWebPreviewSession` 等） |
| `SimulatorPreviewCore` | `SimulatorPreviewApp`、`simctl`、隔离 device set |
| `SimulatorPreviewBridge` | 画面采集、HID 输入、键盘映射 |
| `SimulatorPreviewHTTP` | 本地 HTTP server、网页资源、HLS/帧/输入接口 |
| `simulator-preview-demo` | 命令行 smoke test |

## 3. 最小示例

```swift
import Foundation
import SimulatorPreviewKit

@main
struct Example {
    static func main() async throws {
        let appURL = URL(fileURLWithPath: "/path/to/MyApp.app")

        let app = try SimulatorPreviewApp(appBundleURL: appURL)
        let preview = LocalWebPreviewSession()

        let pageURL = try await preview.start(app: app)
        print("Preview available at: \(pageURL)")

        // 把 pageURL 塞到你的 WKWebView / NSWindow / WebView 容器即可
        // 退出前记得释放资源：
        await preview.stop()
    }
}
```

拿到 `pageURL` 之后，宿主的工作就是把它交给一个 web 容器。`SimulatorPreviewKit` 不限制你用 WKWebView、SwiftUI `WebView`、或干脆让用户用系统浏览器打开。

## 4. 核心类型

### 4.1 `SimulatorPreviewApp`

包装一个已有 `.app` bundle。

```swift
public struct SimulatorPreviewApp: Equatable, Sendable {
    public let appBundleURL: URL
    public let bundleIdentifier: String
    public let displayName: String

    public init(appBundleURL: URL,
                bundleIdentifier: String? = nil,
                displayName: String? = nil) throws
}
```

构造时会：

- 校验路径后缀必须是 `.app`，且是目录
- 读 `Info.plist`
- 解析 `CFBundleIdentifier`（如果没传且 plist 中也没有，抛 `PreviewError.missingBundleIdentifier`）
- 解析 display name（优先 `CFBundleDisplayName`，其次 `CFBundleName`，再退化为文件名）

常见错误：

| 错误 | 触发条件 |
| --- | --- |
| `invalidAppBundle` | 路径不是 `.app` 或不是目录 |
| `missingBundleIdentifier` | 无法解析到 `CFBundleIdentifier` |

### 4.2 `LocalWebPreviewSession`

宿主真正的入口。

```swift
public final class LocalWebPreviewSession {
    public init(configuration: LocalWebPreviewConfiguration = .init(),
                hostService: IsolatedSimulatorHostService = .init())

    public func start(app: SimulatorPreviewApp) async throws -> URL
    public func stop() async
    public func pageURL() -> URL?
    public func openSimulatorWindow() throws
}
```

方法语义：

- `start(app:)`
  - 若已有 session，会先隐式 `stop()`
  - 准备 isolated simulator session → 准备 HID bridge → 启动帧采集 → 启动 web server
  - 返回可直接在 web 容器中打开的 `URL`
- `stop()`
  - 停止帧采集、HID bridge、web server
  - 不会抛错
- `pageURL()`
  - 如果 web server 已经启动，返回页面 URL；否则返回 `nil`
- `openSimulatorWindow()`
  - 临时把当前 isolated session 里的设备窗口暴露给 `Simulator.app`，便于人工排查
  - 没有活跃 session 时抛错

### 4.3 `LocalWebPreviewConfiguration`

```swift
public struct LocalWebPreviewConfiguration: Sendable {
    public let preferredDeviceName: String?
    public let frameIntervalNanoseconds: UInt64    // 默认 16_000_000（约 60 FPS）
    public let webServer: PreviewWebServerConfiguration

    public init(preferredDeviceName: String? = nil,
                frameIntervalNanoseconds: UInt64 = 16_000_000,
                webServer: PreviewWebServerConfiguration = .init())
}
```

字段说明：

- `preferredDeviceName`
  - 类似 `"iPhone 17"`、`"iPhone 15 Pro"`
  - `nil` 时走默认优先级挑一个 iPhone
- `frameIntervalNanoseconds`
  - 帧采样间隔。默认 `16_000_000`，即约 16ms / 60 FPS 目标
  - 影响 HLS 流取帧节奏，也影响前端图片 fallback 的轮询节奏
  - 想更省电、更省 CPU，可以调成 `33_000_000`（≈ 30 FPS）或更大
- `webServer`
  - 见 4.4

### 4.4 `PreviewWebServerConfiguration`

```swift
public struct PreviewWebServerConfiguration: Sendable {
    public let host: String          // 默认 "127.0.0.1"
    public let requestedPort: UInt16 // 默认 38888

    public init(host: String = "127.0.0.1", requestedPort: UInt16 = 38888)
}
```

- `host` 默认就是 loopback。不建议改成 `0.0.0.0` 或公网地址，这个 package 没设计成远程可访问的服务（参见 [11. 能力边界](#11-能力边界)）
- `requestedPort` 是“偏好值”；如果端口被占，底层 HTTP server 会决定最终端口，`pageURL` 以它为准

## 5. 生命周期

典型调用顺序：

```text
init LocalWebPreviewSession
  -> start(app:)
    -> 返回 pageURL
    -> 把 pageURL 交给 web 容器
  -> (可选) openSimulatorWindow()
  -> stop()
```

注意事项：

- 一个 `LocalWebPreviewSession` 一次只跑一个 session。再次 `start(app:)` 会先 `stop()`
- `stop()` 后 `pageURL()` 会变 `nil`
- 宿主退出前应显式 `await session.stop()`，否则 isolated simulator device set 可能留在磁盘上
- `stop()` 是 idempotent，可以多次调用

## 6. 在宿主 app 中嵌入 preview 页面

把返回的 URL 放到 WKWebView：

```swift
import AppKit
import WebKit
import SimulatorPreviewKit

final class PreviewWindowController: NSWindowController {
    private let session = LocalWebPreviewSession()
    private let webView = WKWebView()

    func open(appURL: URL) async throws {
        let app = try SimulatorPreviewApp(appBundleURL: appURL)
        let pageURL = try await session.start(app: app)

        await MainActor.run {
            webView.load(URLRequest(url: pageURL))
            showWindow(nil)
        }
    }

    func close() async {
        await session.stop()
    }
}
```

要点：

- `WKWebView` 默认允许访问 loopback，不需要额外 ATS 豁免
- 如果你用 sandboxed app，**需要**开启 `com.apple.security.network.client`（访问本地 HTTP 服务）
- 如果你的宿主需要在 SwiftUI 里承载，用 `NSViewRepresentable` 包一层 `WKWebView` 即可

## 7. CLI demo

仓库自带 `simulator-preview-demo`，可不写代码先验证端到端链路。

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app \
  [--port 38888] \
  [--device "iPhone 17"] \
  [--open] \
  [--embed] \
  [--frame-interval-ms 120]
```

参数：

| 参数 | 说明 |
| --- | --- |
| `--app` | **必填**，已有 `.app` bundle 路径 |
| `--port` | 本地 web server 端口，默认 `38888` |
| `--device` | 指定 simulator 设备名；不传时走默认优先级 |
| `--open` | 启动后自动用浏览器打开页面 |
| `--embed` | 启动一个内嵌 `WKWebView` 窗口承载 preview 页面，模拟宿主应用里的 web preview 容器 |
| `--frame-interval-ms` | 帧采样间隔，默认 `120ms`。同时影响 HLS 取帧节奏和图片 fallback 刷新节奏 |

常见用法：

```sh
# 最小验证
swift run simulator-preview-demo --app ./Build/MyApp.app --open

# 模拟宿主内嵌容器
swift run simulator-preview-demo --app ./Build/MyApp.app --embed

# 指定设备 + 降低 CPU 占用
swift run simulator-preview-demo --app ./Build/MyApp.app \
  --device "iPhone 15" --frame-interval-ms 200 --open
```

## 8. Web 端接口

页面（`pageURL`）是一个最小的单页应用。网络层会用到以下接口：

| 路径 | 方法 | 用途 |
| --- | --- | --- |
| `/` | GET | 页面入口 HTML |
| `/styles.css` | GET | 样式 |
| `/app.js` | GET | 前端脚本 |
| `/stream/status` | GET | 查询 HLS 流是否就绪 |
| `/stream.m3u8` | GET | HLS playlist（未就绪时 `204`） |
| `/stream/init.mp4` | GET | HLS fMP4 init segment |
| `/stream/segments/*.m4s` | GET | HLS 媒体分片 |
| `/frame` | GET | 当前帧图片 fallback（HLS 不可用时前端会轮询） |
| `/input` | POST | 触摸 / 滚动 / 键盘事件回传 |

面向宿主，唯一稳定的约定是：**把 `pageURL` 丢进 web 容器就行**。上述接口属于内部协议，未来可能替换。

## 9. 常见配置建议

- CPU 紧张或远程同屏：`frameIntervalNanoseconds: 33_000_000`（≈ 30 FPS）起
- 需要更流畅的滑动：保持默认 `16_000_000`（≈ 60 FPS）
- 多实例共存：为每个 `LocalWebPreviewSession` 显式给不同 `requestedPort`，避免都打 `38888` 去竞争
- 指定设备：`LocalWebPreviewConfiguration(preferredDeviceName: "iPhone 15 Pro")`
- 调试时想看到真实 simulator 窗口：`try session.openSimulatorWindow()`

## 10. 错误与排查

### 10.1 `start(app:)` 抛错

常见原因：

- `SimulatorPreviewApp` 构造阶段失败 → 检查 `.app` 路径 / `Info.plist` / `CFBundleIdentifier`
- `simctl` 报错 → 检查是否有可用 iOS Simulator runtime；`xcrun simctl list runtimes`
- HID bridge 准备失败 → 通常意味着 simulator 没起来或权限异常

### 10.2 页面打开但空白

顺序排查：

1. `GET /stream/status` 的 `ready` 是否长期为 `false`
2. `GET /stream.m3u8` 是否持续 `204`
3. `GET /frame` 是否持续 `204`
4. 程序里调用 `PreviewFrameProducer.currentFrame()` 是否 `nil`
5. `openSimulatorWindow()` 打开真实 simulator 窗口看看 app 本身是否启动成功

### 10.3 有画面但点不动

顺序排查：

1. 前端有没有发 `POST /input`
2. `PreviewInteractionEvent` 反序列化是否成功
3. `SimulatorKitHIDBridge.prepare(session:)` 是否成功（看日志）

### 10.4 键盘不对

顺序排查：

1. 浏览器 `keydown` 里的 `code` / `key` 是否已经上报
2. `DOMKeyboardMapper` 是否覆盖该按键 — 未覆盖就会被忽略

## 11. 能力边界

`SimulatorPreviewKit` 的定位是**本地 macOS 开发辅助**，明确**不做**以下事情：

- 不构建 `.app`，也不管 signing
- 不提供远程 / 公网访问方案；默认绑 loopback
- 不提供跨平台支持（Linux、Windows、iOS 宿主都不在范围内）
- 不承诺规避 Apple 私有 simulator / HID bridge；这是当前实现的前提
- 不提供 UI 录制、重放、断言等测试框架功能

如果你的场景超出上面这些，请基于这个 package 在自己的工程里再封一层，而不是直接扩展本仓库。
