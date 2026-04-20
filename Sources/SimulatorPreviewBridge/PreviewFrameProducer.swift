import AppKit
import Foundation
import IOSurface
import SimulatorPreviewCore

public struct PreviewFrameSnapshot: Sendable {
    public let imageData: Data
    public let contentType: String
    public let pixelSize: CGSize
    public let updatedAt: Date

    public init(imageData: Data, contentType: String = "image/png", pixelSize: CGSize, updatedAt: Date = Date()) {
        self.imageData = imageData
        self.contentType = contentType
        self.pixelSize = pixelSize
        self.updatedAt = updatedAt
    }
}

public enum PreviewFrameBacking: Sendable {
    case ioSurface(IOSurface)
    case encodedImage(data: Data, contentType: String)
}

public struct PreviewRenderableFrame: Sendable {
    public let backing: PreviewFrameBacking
    public let pixelSize: CGSize
    public let updatedAt: Date

    public init(backing: PreviewFrameBacking, pixelSize: CGSize, updatedAt: Date = Date()) {
        self.backing = backing
        self.pixelSize = pixelSize
        self.updatedAt = updatedAt
    }
}

public final class PreviewFrameProducer {
    private struct CaptureResult: Sendable {
        let snapshot: PreviewFrameSnapshot?
        let renderableFrame: PreviewRenderableFrame
    }

    private let hostService: IsolatedSimulatorHostService
    private let lock = NSLock()
    private let frameIntervalNanoseconds: UInt64

    private var pollTask: Task<Void, Never>?
    private var latestFrameSnapshot: PreviewFrameSnapshot?
    private var latestRenderableFrame: PreviewRenderableFrame?
    private var displayBridge: SimulatorKitDisplayBridge?
    private var currentSession: IsolatedSimulatorSession?

    public init(
        hostService: IsolatedSimulatorHostService,
        frameIntervalNanoseconds: UInt64 = 120_000_000
    ) {
        self.hostService = hostService
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
    }

    public func start(session: IsolatedSimulatorSession) async throws {
        stop()
        currentSession = session

        let displayBridge = SimulatorKitDisplayBridge()
        self.displayBridge = displayBridge
        _ = try? await Task.detached(priority: .userInitiated) {
            try displayBridge.prepare(session: session)
        }.value

        try await refresh(session: session, includeSnapshot: true)

        pollTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.pollFrames(session: session)
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        displayBridge?.invalidate()
        displayBridge = nil
        currentSession = nil
    }

    public func currentFrame() -> PreviewFrameSnapshot? {
        lock.withScopedLock {
            latestFrameSnapshot
        }
    }

    public func currentRenderableFrame() -> PreviewRenderableFrame? {
        lock.withScopedLock {
            latestRenderableFrame
        }
    }

    public func latestFrameEnsuringFresh() async throws -> PreviewFrameSnapshot? {
        guard let session = currentSession else {
            return currentFrame()
        }

        try await refresh(session: session, includeSnapshot: true)
        return currentFrame()
    }

    public func refresh(session: IsolatedSimulatorSession, includeSnapshot: Bool = true) async throws {
        let captureResult = try await Task.detached(priority: .userInitiated) { [hostService, displayBridge] in
            try Self.capture(
                session: session,
                hostService: hostService,
                displayBridge: displayBridge,
                includeSnapshot: includeSnapshot
            )
        }.value
        lock.withScopedLock {
            if let snapshot = captureResult.snapshot {
                latestFrameSnapshot = snapshot
            }
            latestRenderableFrame = captureResult.renderableFrame
        }
    }

    private func pollFrames(session: IsolatedSimulatorSession) async {
        while !Task.isCancelled {
            do {
                try await refresh(session: session, includeSnapshot: false)
            } catch {
                // Keep polling; the fallback path can recover on the next tick.
            }

            do {
                try await Task.sleep(nanoseconds: frameIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private static func capture(
        session: IsolatedSimulatorSession,
        hostService: IsolatedSimulatorHostService,
        displayBridge: SimulatorKitDisplayBridge?,
        includeSnapshot: Bool
    ) throws -> CaptureResult {
        if let displayBridge,
           let surface = try? displayBridge.currentSurface() {
            let pixelSize = CGSize(
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface)
            )

            let snapshot: PreviewFrameSnapshot?
            if includeSnapshot {
                if let image = try? displayBridge.captureImage(),
                   let pngData = pngData(from: image) {
                    snapshot = PreviewFrameSnapshot(
                        imageData: pngData,
                        pixelSize: image.size
                    )
                } else {
                    let pngData = try hostService.captureScreenshotData(of: session)
                    guard let image = NSImage(data: pngData) else {
                        throw PreviewError.message("Preview frame could not be decoded.")
                    }
                    snapshot = PreviewFrameSnapshot(
                        imageData: pngData,
                        pixelSize: image.size
                    )
                }
            } else {
                snapshot = nil
            }

            return CaptureResult(
                snapshot: snapshot,
                renderableFrame: PreviewRenderableFrame(
                    backing: .ioSurface(surface),
                    pixelSize: pixelSize
                )
            )
        }

        let pngData = try hostService.captureScreenshotData(of: session)
        guard let image = NSImage(data: pngData) else {
            throw PreviewError.message("Preview frame could not be decoded.")
        }
        let snapshot = PreviewFrameSnapshot(
            imageData: pngData,
            pixelSize: image.size
        )
        return CaptureResult(
            snapshot: snapshot,
            renderableFrame: PreviewRenderableFrame(
                backing: .encodedImage(data: pngData, contentType: snapshot.contentType),
                pixelSize: image.size
            )
        )
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension NSLock {
    func withScopedLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
