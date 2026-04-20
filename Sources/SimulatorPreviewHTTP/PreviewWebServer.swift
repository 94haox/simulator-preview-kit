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

// swiftlint:disable:next type_body_length
public final class PreviewWebServer {
    struct Providers {
        let pageContext: @Sendable () -> PreviewPageContext
        let cachedFrame: @Sendable () -> PreviewFrameSnapshot?
        let freshFrame: @Sendable () async throws -> PreviewFrameSnapshot?
        let renderableFrame: @Sendable () -> PreviewRenderableFrame?
        let videoStatus: @Sendable () -> PreviewVideoStreamStatus
        let playlist: @Sendable () -> Data?
        let initSegment: @Sendable () -> Data?
        let mediaSegment: @Sendable (String) -> Data?
        let interaction: @Sendable (PreviewInteractionEvent) async throws -> Void
    }

    private let configuration: PreviewWebServerConfiguration
    private let providers: Providers
    private let frameIntervalNanoseconds: UInt64

    private var server: SimpleHTTPServer?
    private var framePusher: WebSocketFramePusher?
    private(set) public var pageURL: URL?

    public init(
        configuration: PreviewWebServerConfiguration = .init(),
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
        self.providers = Providers(
            pageContext: pageContextProvider,
            cachedFrame: cachedFrameProvider,
            freshFrame: freshFrameProvider,
            renderableFrame: renderableFrameProvider,
            videoStatus: videoStatusProvider,
            playlist: playlistProvider,
            initSegment: initializationSegmentProvider,
            mediaSegment: mediaSegmentProvider,
            interaction: interactionHandler
        )
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
    }

    public func start() async throws -> URL {
        if let pageURL {
            return pageURL
        }

        let pusher = WebSocketFramePusher(
            frameProvider: providers.renderableFrame,
            interactionHandler: providers.interaction,
            frameIntervalNanoseconds: frameIntervalNanoseconds
        )
        self.framePusher = pusher

        let wsQueue = DispatchQueue(label: "simulator-preview-kit.websocket")
        let p = providers

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
            },
            handler: { request in
                await Self.handle(request: request, providers: p)
            }
        )
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

    // MARK: - Route handling

    private static func handle(
        request: SimpleHTTPRequest,
        providers p: Providers
    ) async -> SimpleHTTPResponse {
        let rawPath = request.path
            .split(separator: "?", maxSplits: 1)
            .first.map(String.init) ?? request.path

        switch (request.method.uppercased(), rawPath) {
        case ("GET", "/"):
            let ctx = p.pageContext()
            return .text(
                EmbeddedWebAssets.indexHTML(
                    deviceName: ctx.deviceName,
                    frameIntervalMs: ctx.frameIntervalMilliseconds,
                    initialMode: "websocket"
                ),
                contentType: "text/html; charset=utf-8"
            )
        case ("GET", "/app.js"):
            return .text(
                EmbeddedWebAssets.appJS,
                contentType: "application/javascript; charset=utf-8"
            )
        case ("GET", "/vendor/hls.min.js"):
            guard !EmbeddedWebAssets.hlsJS.isEmpty else {
                return .text("Not Found", statusCode: 404)
            }
            return .text(
                EmbeddedWebAssets.hlsJS,
                contentType: "application/javascript; charset=utf-8"
            )
        case ("GET", "/styles.css"):
            return .text(
                EmbeddedWebAssets.stylesCSS,
                contentType: "text/css; charset=utf-8"
            )
        case ("GET", "/stream.m3u8"):
            guard let playlist = p.playlist() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/vnd.apple.mpegurl",
                    "Cache-Control": "no-store, no-cache"
                ],
                body: playlist
            )
        case ("GET", "/stream/init.mp4"):
            guard let seg = p.initSegment() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "video/mp4",
                    "Cache-Control": "no-store, no-cache"
                ],
                body: seg
            )
        case ("GET", let path) where path.hasPrefix("/stream/segments/"):
            let name = String(path.dropFirst("/stream/segments/".count))
            guard let seg = p.mediaSegment(name) else {
                return .text("Not Found", statusCode: 404)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "video/iso.segment",
                    "Cache-Control": "no-store, no-cache"
                ],
                body: seg
            )
        case ("GET", "/stream/status"):
            let status = p.videoStatus()
            var payload: [String: String] = [
                "ready": status.isReady ? "true" : "false",
                "segmentCount": String(status.segmentCount)
            ]
            if let err = status.lastError, !err.isEmpty {
                payload["lastError"] = err
            }
            return (try? .json(payload))
                ?? .text("{}", contentType: "application/json; charset=utf-8")
        case ("GET", "/frame"):
            guard let frame = try? await p.freshFrame() else {
                return SimpleHTTPResponse(statusCode: 204)
            }
            return SimpleHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": frame.contentType,
                    "Cache-Control": "no-store, no-cache"
                ],
                body: frame.imageData
            )
        case ("POST", "/input"):
            do {
                let event = try JSONDecoder().decode(
                    PreviewInteractionEvent.self,
                    from: request.body
                )
                try await p.interaction(event)
                return try .json(["accepted": true], statusCode: 202)
            } catch {
                return .text(
                    PreviewError.userMessage(for: error),
                    statusCode: 400
                )
            }
        case ("GET", "/health"):
            let ctx = p.pageContext()
            let vs = p.videoStatus()
            var payload: [String: String] = [
                "deviceName": ctx.deviceName,
                "frameAvailable": p.cachedFrame() != nil ? "true" : "false",
                "mode": "websocket",
                "videoReady": vs.isReady ? "true" : "false",
                "videoSegmentCount": String(vs.segmentCount)
            ]
            if let err = vs.lastError, !err.isEmpty {
                payload["videoLastError"] = err
            }
            return (try? .json(payload))
                ?? .text("{}", contentType: "application/json; charset=utf-8")
        case ("POST", "/"), ("POST", "/frame"):
            return .text("Method Not Allowed", statusCode: 405)
        default:
            return .text("Not Found", statusCode: 404)
        }
    }
}
