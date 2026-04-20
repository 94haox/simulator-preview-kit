# AGENTS.md

本文档给进入本仓库工作的 agent 一个可直接执行的入口。

## 仓库目标

`SimulatorPreviewKit` 是一个独立的 macOS Swift Package。它把下面这条能力链路从宿主应用里剥离出来：

1. 启动隔离的 iOS Simulator session
2. 安装并启动已有 `.app` bundle
3. 采集 simulator 画面
4. 通过本地 web 页面显示
5. 把网页里的点击、滚动、键盘事件回传给 simulator

当前仓库不负责：

- 生成 iOS 工程
- 构建 `.app`
- 设计宿主 UI
- 远程公网传输

## 对话与文档语言

- 与用户默认使用中文。
- README、设计文档、使用文档优先写中文。
- 代码标识符、命令、Apple API 名称保持英文。

## 先看什么

如果你是第一次进入这个仓库，按这个顺序读：

1. [README.md](README.md)
2. [docs/agent-quickstart.md](docs/agent-quickstart.md)
3. [docs/plans/2026-04-20-simulator-preview-kit-design.md](docs/plans/2026-04-20-simulator-preview-kit-design.md)
4. [Package.swift](Package.swift)

如果用户问“入口在哪里”：

- 宿主接入入口在 `Sources/SimulatorPreviewKit/LocalWebPreviewSession.swift`
- CLI demo 入口在 `Sources/simulator-preview-demo/SimulatorPreviewDemo.swift`

## 模块边界

改动前先确认应该落在哪层，不要把边界重新搅乱：

- `SimulatorPreviewCore`
  - `ProcessRunner`
  - `SimulatorPreviewApp`
  - `IsolatedSimulatorHostService`
  - `SelectedSimulator` / `IsolatedSimulatorSession`
  - 职责：不关心 UI，只管 app bundle、simctl、device set、session 生命周期

- `SimulatorPreviewBridge`
  - `SimulatorKitDisplayBridge`
  - `SimulatorKitHIDBridge`
  - `PreviewFrameProducer`
  - `PreviewInteractionEvent`
  - 职责：Apple 私有桥接、帧采集、输入回传

- `SimulatorPreviewHTTP`
  - `SimpleHTTPServer`
  - `PreviewWebServer`
  - `EmbeddedWebAssets`
  - 职责：本地页面、帧接口、输入接口

- `SimulatorPreviewKit`
  - `LocalWebPreviewSession`
  - 职责：给宿主一个窄接口，把前面三层串起来

### 不要这样改

- 不要把宿主应用特有状态塞进 `SimulatorPreviewCore`
- 不要把 SwiftUI / AppKit 视图塞进这个 package
- 不要让 `SimulatorPreviewHTTP` 反向依赖宿主类型
- 不要在 `LocalWebPreviewSession` 里堆具体 simulator 私有实现细节

## 最常见任务

### 1. 验证 package 还能编

在仓库根目录运行：

```sh
swift build
swift test
```

### 2. 验证 demo CLI 参数入口

```sh
swift run simulator-preview-demo --help
```

### 3. 用一个已有 `.app` 做本地预览

```sh
swift run simulator-preview-demo --app /path/to/MyApp.app --open
```

如果宿主应用已经有 `.app` 路径，优先用这个方式做 smoke check。

### 4. 给宿主接入

宿主只需要：

1. 依赖 package
2. 创建 `SimulatorPreviewApp`
3. 创建 `LocalWebPreviewSession`
4. `start(app:)`
5. 把返回的 URL 放进 web preview 容器

## 改动建议

### 如果用户要改“画面怎么传”

先看：

- `PreviewFrameProducer.swift`
- `PreviewWebServer.swift`
- `EmbeddedWebAssets.swift`

优先保持 `LocalWebPreviewSession` 的 public surface 稳定。

### 如果用户要改“输入怎么回传”

先看：

- `PreviewInteractionEvent.swift`
- `DOMKeyboardMapper.swift`
- `SimulatorKitHIDBridge.swift`

注意：

- web 事件模型和 simulator HID 映射是两层，不要混在一起。

### 如果用户要改“如何起 session / 装 app”

先看：

- `SimulatorPreviewApp.swift`
- `IsolatedSimulatorHostService.swift`
- `SimulatorSupport.swift`

优先保持 device set 隔离，不要默认回退到用户的全局 simulator 状态。

## 验证要求

按风险选择最小但足够的验证：

- 文档变更：不强制跑构建
- Public API / package graph 变更：`swift build`
- 行为变更：`swift build && swift test`
- CLI 参数或入口变更：补跑 `swift run simulator-preview-demo --help`
- 真机能否跑通是另一层验证；除非用户明确要求，不要默认尝试启动一个真实 app bundle

## 故障排查起点

### 预览起不来

先检查：

1. `.app` 是否存在
2. `.app/Info.plist` 是否有 `CFBundleIdentifier`
3. 本机是否安装了 Xcode 和 iOS Simulator runtime
4. `xcrun simctl list devices available --json` 是否正常

### 画面有但不响应输入

先检查：

1. `PreviewInteractionEvent` 是否正确落到 `/input`
2. `DOMKeyboardMapper` 是否覆盖该按键
3. `SimulatorKitHIDBridge` 是否 prepare 成功

### 页面能开但没有画面

先检查：

1. `/stream/status` 是否一直 `ready=false`
2. `/stream.m3u8` 是否返回 `204`
3. `/frame` 是否返回 `204`
4. `PreviewFrameProducer.currentFrame()` 是否为空
5. `IsolatedSimulatorHostService.captureScreenshotData(of:)` 是否成功

## 输出给用户时的口径

- 明确区分“已验证”和“按代码推断”
- 如果没跑真实 `.app` smoke test，要直说
- 如果只改了文档，不要说自己验证了运行行为
