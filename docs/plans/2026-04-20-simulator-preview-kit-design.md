# SimulatorPreviewKit 设计说明

## 目标

把以下能力从 Kaveh 一类宿主应用里剥离出来，做成一个独立 repo / Swift Package：

1. 启动隔离的 simulator session
2. 安装并启动已有 `.app`
3. 采集 simulator 画面
4. 在本地 web 页面中显示画面
5. 把 web 端的交互回传给 simulator

## 为什么做成独立 package

- 避免宿主仓库承担 simulator 私有桥接细节
- 让 session 管理、画面采集、web 预览成为可替换能力
- 让 Kaveh 这类宿主只负责“何时 preview、把 URL 放在哪里显示”

## 模块拆分

### `SimulatorPreviewCore`

负责与 UI 无关的稳定基础能力：

- `SimulatorPreviewApp`：从 `.app` bundle 读取元信息
- `IsolatedSimulatorHostService`：device set、boot、install、launch、screenshot
- `ProcessRunner` 与错误模型

### `SimulatorPreviewBridge`

负责 Apple 私有预览桥接：

- `SimulatorKitDisplayBridge`：从 simulator framebuffer 取 `IOSurface`
- `SimulatorKitHIDBridge`：把输入事件送回 simulator
- `PreviewFrameProducer`：把 bridge 输出统一成图片帧

这里刻意不保留 Kaveh 的 SwiftUI 视图，因为独立包的职责是提供 preview 能力，不是规定宿主 UI。

### `SimulatorPreviewHTTP`

负责本地页面传输：

- `SimpleHTTPServer`：最小本地 HTTP 服务
- `PreviewWebServer`：页面、帧图、输入事件接口

当前选型是“图片帧轮询 + JSON 输入 POST”，而不是 WebSocket / WebRTC。这样做的原因是：

- 纯 SwiftPM、无额外 server 依赖
- 更容易嵌进任意宿主
- 先验证模块边界，再决定是否升级到低延迟流

### `SimulatorPreviewKit`

宿主真正接入的一层：

- `LocalWebPreviewSession`

它负责把前面三层串起来，对外只暴露：

- 输入 `.app`
- 启动 preview
- 返回本地页面 URL

## 运行时链路

1. 宿主构造 `SimulatorPreviewApp`
2. `LocalWebPreviewSession.start(app:)`
3. `IsolatedSimulatorHostService.preparePreviewSession(app:)`
4. `SimulatorKitHIDBridge.prepare(session:)`
5. `PreviewFrameProducer.start(session:)`
6. `PreviewWebServer.start()`
7. 宿主把返回的 `http://127.0.0.1:<port>/` 放进 web 预览容器

## 后续可演进方向

1. 从图片轮询升级到 WebSocket 二进制帧
2. 再进一步升级到视频流
3. 补一个 macOS demo app，而不只是 CLI
4. 对外抽象出 transport protocol，允许宿主自己替换 web 层
