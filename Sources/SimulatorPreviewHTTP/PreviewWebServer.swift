import Foundation
import Network
import SimulatorPreviewBridge
import SimulatorPreviewCore

public struct PreviewPageContext: Sendable {
    public let deviceName: String
    public let frameIntervalMilliseconds: Int

    public init(deviceName: String, frameIntervalMilliseconds: Int) {
        self.deviceName = deviceName
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
    }
}

public struct PreviewWebServerConfiguration: Sendable {
    public let host: String
    public let requestedPort: UInt16

    public init(host: String = "127.0.0.1", requestedPort: UInt16 = 38888) {
        self.host = host
        self.requestedPort = requestedPort
    }
}

public final class PreviewWebServer {
    private let configuration: PreviewWebServerConfiguration
    private let pageContextProvider: @Sendable () -> PreviewPageContext
    private let cachedFrameProvider: @Sendable () -> PreviewFrameSnapshot?
    private let freshFrameProvider: @Sendable () async throws -> PreviewFrameSnapshot?
    private let renderableFrameProvider: @Sendable () -> PreviewRenderableFrame?
    private let videoStatusProvider: @Sendable () -> PreviewVideoStreamStatus
    private let playlistProvider: @Sendable () -> Data?
    private let initializationSegmentProvider: @Sendable () -> Data?
    private let mediaSegmentProvider: @Sendable (String) -> Data?
    private let interactionHandler: @Sendable (PreviewInteractionEvent) async throws -> Void
    private let frameIntervalNanoseconds: UInt64

    private var server: SimpleHTTPServer?
    private var framePusher: WebSocketFramePusher?
    private(set) public var pageURL: URL?

    public init(
        configuration: PreviewWebServerConfiguration = PreviewWebServerConfiguration(),
        pageContextProvider: @escaping @Sendable () -> PreviewPageContext,
        cachedFrameProvider: @escaping @Sendable () -> PreviewFrameSnapshot?,
        freshFrameProvider: @escaping @Sendable () async throws -> PreviewFrameSnapshot?,
        renderableFrameProvider: @escaping @Sendable () -> PreviewRenderableFrame? = { nil },
        videoStatusProvider: @escaping @Sendable () -> PreviewVideoStreamStatus,
        playlistProvider: @escaping @Sendable () -> Data?,
        initializationSegmentProvider: @escaping @Sendable () -> Data?,
        mediaSegmentProvider: @escaping @Sendable (String) -> Data?,
        interactionHandler: @escaping @Sendable (PreviewInteractionEvent) async throws -> Void,
        frameIntervalNanoseconds: UInt64 = 33_000_000
    ) {
        self.configuration = configuration
        self.pageContextProvider = pageContextProvider
        self.cachedFrameProvider = cachedFrameProvider
        self.freshFrameProvider = freshFrameProvider
        self.renderableFrameProvider = renderableFrameProvider
        self.videoStatusProvider = videoStatusProvider
        self.playlistProvider = playlistProvider
        self.initializationSegmentProvider = initializationSegmentProvider
        self.mediaSegmentProvider = mediaSegmentProvider
        self.interactionHandler = interactionHandler
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
    }

    public func start() async throws -> URL {
        if let pageURL {
            return pageURL
        }

        let pusher = WebSocketFramePusher(
            frameProvider: renderableFrameProvider,
            interactionHandler: interactionHandler,
            frameIntervalNanoseconds: frameIntervalNanoseconds
        )
        self.framePusher = pusher

        let wsQueue = DispatchQueue(label: "simulator-preview-kit.websocket")

        let server = SimpleHTTPServer(
            requestedPort: configuration.requestedPort,
            onWebSocketUpgrade: { [weak pusher] request, connection in
                guard let pusher else { return }
                guard let ws = WebSocketConnection.completeHandshake(
                    request: request,
                    connection: connection,
                    queue: wsQueue
                ) else {
                    connection.cancel()
                    return
                }
                pusher.addConnection(ws)
            }
        ) { [
            pageContextProvider,
            cachedFrameProvider,
            freshFrameProvider,
            videoStatusProvider,
            playlistProvider,
            initializationSegmentProvider,
            mediaSegmentProvider,
            interactionHandler
        ] request in
            await Self.handle(
                request: request,
                pageContextProvider: pageContextProvider,
                cachedFrameProvider: cachedFrameProvider,
                freshFrameProvider: freshFrameProvider,
                videoStatusProvider: videoStatusProvider,
                playlistProvider: playlistProvider,
                initializationSegmentProvider: initializationSegmentProvider,
                mediaSegmentProvider: mediaSegmentProvider,
                interactionHandler: interactionHandler
            )
        }
        let port = try await server.start()
        self.server = server

        pusher.start()

        let pageURL = URL(string: "http://\(configuration.host):\(port)/")!
        self.pageURL = pageURL
        return pageURL
    }

    public func stop() {
        framePusher?.stop()
        framePusher = nil
        server?.stop()
        server = nil
        pageURL = nil
    }

    private static func handle(
        request: SimpleHTTPRequest,
        pageContextProvider: @escaping @Sendable () -> PreviewPageContext,
        cachedFrameProvider: @escaping @Sendable () -> PreviewFrameSnapshot?,
        freshFrameProvider: @escaping @Sendable () async throws -> PreviewFrameSnapshot?,
        videoStatusProvider: @escaping @Sendable () -> PreviewVideoStreamStatus,
        playlistProvider: @escaping @Sendable () -> Data?,
        initializationSegmentProvider: @escaping @Sendable () -> Data?,
        mediaSegmentProvider: @escaping @Sendable (String) -> Data?,
        interactionHandler: @escaping @Sendable (PreviewInteractionEvent) async throws -> Void
    ) async -> SimpleHTTPResponse {
        let rawPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path

        switch (request.method.uppercased(), rawPath) {
        case ("GET", "/"):
            let context = pageContextProvider()
            return .text(
                EmbeddedWebAssets.indexHTML(
                    deviceName: context.deviceName,
                    frameIntervalMs: context.frameIntervalMilliseconds,
                    initialMode: "websocket"
                ),
                contentType: "text/html; charset=utf-8"
            )
        case ("GET", "/app.js"):
            return .text(EmbeddedWebAssets.appJS, contentType: "application/javascript; charset=utf-8")
        case ("GET", "/vendor/hls.min.js"):
            guard !EmbeddedWebAssets.hlsJS.isEmpty else {
                return .text("Not Found", statusCode: 404)
            }
            return .text(EmbeddedWebAssets.hlsJS, contentType: "application/javascript; charset=utf-8")
        case ("GET", "/styles.css"):
            return .text(EmbeddedWebAssets.stylesCSS, contentType: "text/css; charset=utf-8")
        case ("GET", "/stream.m3u8"):
            guard let playlist = playlistProvider() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: playlist
            )
        case ("GET", "/stream/init.mp4"):
            guard let initializationSegment = initializationSegmentProvider() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "video/mp4",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: initializationSegment
            )
        case ("GET", let path) where path.hasPrefix("/stream/segments/"):
            let name = String(path.dropFirst("/stream/segments/".count))
            guard let mediaSegment = mediaSegmentProvider(name) else {
                return .text("Not Found", statusCode: 404)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "video/iso.segment",
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: mediaSegment
            )
        case ("GET", "/stream/status"):
            let status = videoStatusProvider()
            var payload: [String: String] = [
                "ready": status.isReady ? "true" : "false",
                "segmentCount": String(status.segmentCount)
            ]
            if let lastError = status.lastError, !lastError.isEmpty {
                payload["lastError"] = lastError
            }
            return (try? .json(payload)) ?? .text("{}", contentType: "application/json; charset=utf-8")
        case ("GET", "/frame"):
            guard let frame = try? await freshFrameProvider() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": frame.contentType,
                    "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0"
                ],
                body: frame.imageData
            )
        case ("POST", "/input"):
            do {
                let event = try JSONDecoder().decode(PreviewInteractionEvent.self, from: request.body)
                try await interactionHandler(event)
                return try .json(["accepted": true], statusCode: 202)
            } catch {
                return .text(PreviewError.userMessage(for: error), statusCode: 400)
            }
        case ("GET", "/health"):
            let context = pageContextProvider()
            let videoStatus = videoStatusProvider()
            var payload: [String: String] = [
                "deviceName": context.deviceName,
                "frameAvailable": cachedFrameProvider() != nil ? "true" : "false",
                "mode": "websocket",
                "videoReady": videoStatus.isReady ? "true" : "false",
                "videoSegmentCount": String(videoStatus.segmentCount)
            ]
            if let lastError = videoStatus.lastError, !lastError.isEmpty {
                payload["videoLastError"] = lastError
            }
            return (try? .json(payload)) ?? .text("{}", contentType: "application/json; charset=utf-8")
        case ("POST", "/"), ("POST", "/frame"):
            return .text("Method Not Allowed", statusCode: 405)
        default:
            return .text("Not Found", statusCode: 404)
        }
    }
}
