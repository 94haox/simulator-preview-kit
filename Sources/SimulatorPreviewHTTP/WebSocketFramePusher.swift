import CoreGraphics
import CoreImage
import Foundation
import IOSurface
import SimulatorPreviewBridge
import os.log

public final class WebSocketFramePusher: @unchecked Sendable {
    private static let logger = Logger(subsystem: "SimulatorPreviewKit", category: "WebSocketFramePusher")

    private let frameProvider: @Sendable () -> PreviewRenderableFrame?
    private let interactionHandler: @Sendable (PreviewInteractionEvent) async throws -> Void
    private let frameIntervalNanoseconds: UInt64
    private let jpegQuality: CGFloat
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: false,
    ])

    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ConnectionState] = [:]
    private var pushTask: Task<Void, Never>?
    private var lastFrameDate: Date = .distantPast
    private var cachedJPEG: Data?

    public init(
        frameProvider: @escaping @Sendable () -> PreviewRenderableFrame?,
        interactionHandler: @escaping @Sendable (PreviewInteractionEvent) async throws -> Void,
        frameIntervalNanoseconds: UInt64 = 33_000_000,
        jpegQuality: CGFloat = 0.65
    ) {
        self.frameProvider = frameProvider
        self.interactionHandler = interactionHandler
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.jpegQuality = jpegQuality
    }

    func addConnection(_ ws: WebSocketConnection) {
        let id = ObjectIdentifier(ws)
        let state = ConnectionState(connection: ws)

        ws.onReceiveText = { [weak self] text in
            self?.handleTextMessage(text)
        }

        ws.onDisconnect = { [weak self] in
            self?.removeConnection(id: id)
        }

        lock.withLock {
            connections[id] = state
        }

        Self.logger.info("WebSocket client connected (total: \(self.connectionCount))")
    }

    public var connectionCount: Int {
        lock.withLock { connections.count }
    }

    public func start() {
        guard pushTask == nil else { return }
        pushTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runPushLoop()
        }
    }

    public func stop() {
        pushTask?.cancel()
        pushTask = nil

        let allConnections = lock.withLock { () -> [ConnectionState] in
            let values = Array(connections.values)
            connections.removeAll()
            return values
        }

        for state in allConnections {
            state.connection.close()
        }
    }

    // MARK: - Push loop

    private func runPushLoop() async {
        while !Task.isCancelled {
            let tickStart = ContinuousClock.now

            pushFrameToAll()

            let elapsed = ContinuousClock.now - tickStart
            let targetInterval = Duration.nanoseconds(Int64(frameIntervalNanoseconds))
            let remaining = targetInterval - elapsed
            if remaining > .zero {
                do {
                    try await Task.sleep(for: remaining)
                } catch {
                    return
                }
            }
        }
    }

    private func pushFrameToAll() {
        let activeConnections = lock.withLock { Array(connections.values) }
        guard !activeConnections.isEmpty else { return }

        guard let frame = frameProvider() else { return }

        // Skip re-encoding if the frame hasn't changed
        let jpegData: Data
        if frame.updatedAt == lastFrameDate, let cached = cachedJPEG {
            jpegData = cached
        } else {
            guard let encoded = encodeJPEG(from: frame) else { return }
            jpegData = encoded
            lastFrameDate = frame.updatedAt
            cachedJPEG = encoded
        }

        for state in activeConnections {
            state.connection.sendBinary(jpegData)
        }
    }

    // MARK: - JPEG encoding

    private func encodeJPEG(from frame: PreviewRenderableFrame) -> Data? {
        let ciImage: CIImage
        switch frame.backing {
        case .ioSurface(let surface):
            ciImage = CIImage(
                ioSurface: surface,
                options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]
            )
        case .encodedImage(let data, let contentType):
            if contentType == "image/jpeg" {
                return data
            }
            guard let decoded = CIImage(data: data) else { return nil }
            ciImage = decoded
        }

        // Downscale if the source is larger than needed for web preview
        let extent = ciImage.extent
        let maxDimension: CGFloat = 844
        let scaled: CIImage
        if extent.height > maxDimension {
            let scale = maxDimension / extent.height
            scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = ciImage
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]
        )
    }

    // MARK: - Input handling

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let event = try JSONDecoder().decode(PreviewInteractionEvent.self, from: data)
            Task {
                try? await interactionHandler(event)
            }
        } catch {
            Self.logger.debug("Ignoring malformed WebSocket input: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection management

    private func removeConnection(id: ObjectIdentifier) {
        _ = lock.withLock {
            connections.removeValue(forKey: id)
        }
        Self.logger.info("WebSocket client disconnected (total: \(self.connectionCount))")
    }
}

private final class ConnectionState: @unchecked Sendable {
    let connection: WebSocketConnection

    init(connection: WebSocketConnection) {
        self.connection = connection
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
