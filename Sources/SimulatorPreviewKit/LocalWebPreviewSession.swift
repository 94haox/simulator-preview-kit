import Foundation
import SimulatorPreviewBridge
import SimulatorPreviewCore
import SimulatorPreviewHTTP

public struct LocalWebPreviewConfiguration: Sendable {
    public let preferredDeviceName: String?
    public let frameIntervalNanoseconds: UInt64
    public let webServer: PreviewWebServerConfiguration

    public init(
        preferredDeviceName: String? = nil,
        frameIntervalNanoseconds: UInt64 = 16_000_000,
        webServer: PreviewWebServerConfiguration = PreviewWebServerConfiguration()
    ) {
        self.preferredDeviceName = preferredDeviceName
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.webServer = webServer
    }
}

public final class LocalWebPreviewSession {
    private let configuration: LocalWebPreviewConfiguration
    private let hostService: IsolatedSimulatorHostService
    private let hidBridge: SimulatorKitHIDBridge
    private let frameProducer: PreviewFrameProducer
    private lazy var videoStream = PreviewVideoStream(
        frameProvider: { [weak self] in
            self?.frameProducer.currentRenderableFrame()
        },
        frameIntervalNanoseconds: configuration.frameIntervalNanoseconds
    )
    private let stateLock = NSLock()

    private var currentSession: IsolatedSimulatorSession?
    private var currentApp: SimulatorPreviewApp?
    private lazy var webServer = PreviewWebServer(
        configuration: configuration.webServer,
        pageContextProvider: { [weak self] in
            self?.pageContext() ?? PreviewPageContext(deviceName: "Preview Device", frameIntervalMilliseconds: 16)
        },
        cachedFrameProvider: { [weak self] in
            self?.frameProducer.currentFrame()
        },
        freshFrameProvider: { [weak self] in
            try await self?.frameProducer.latestFrameEnsuringFresh()
        },
        renderableFrameProvider: { [weak self] in
            self?.frameProducer.currentRenderableFrame()
        },
        videoStatusProvider: { [weak self] in
            self?.videoStream.status() ?? PreviewVideoStreamStatus(isReady: false, segmentCount: 0)
        },
        playlistProvider: { [weak self] in
            self?.videoStream.playlistData()
        },
        initializationSegmentProvider: { [weak self] in
            self?.videoStream.initializationSegmentData()
        },
        mediaSegmentProvider: { [weak self] name in
            self?.videoStream.segmentData(named: name)
        },
        interactionHandler: { [weak self] event in
            guard let self else { return }
            try await self.handle(event: event)
        },
        frameIntervalNanoseconds: configuration.frameIntervalNanoseconds
    )

    public init(
        configuration: LocalWebPreviewConfiguration = LocalWebPreviewConfiguration(),
        hostService: IsolatedSimulatorHostService = IsolatedSimulatorHostService()
    ) {
        self.configuration = configuration
        self.hostService = hostService
        self.hidBridge = SimulatorKitHIDBridge()
        self.frameProducer = PreviewFrameProducer(
            hostService: hostService,
            frameIntervalNanoseconds: configuration.frameIntervalNanoseconds
        )
    }

    public func start(app: SimulatorPreviewApp) async throws -> URL {
        await stop()

        let session = try await Task.detached(priority: .userInitiated) { [hostService, configuration] in
            try hostService.preparePreviewSession(
                app: app,
                preferredDeviceName: configuration.preferredDeviceName
            )
        }.value

        try await Task.detached(priority: .userInitiated) { [hidBridge] in
            try hidBridge.prepare(session: session)
            try hidBridge.warmUpPointerIfNeeded()
        }.value

        try await frameProducer.start(session: session)

        stateLock.withScopedLock {
            currentApp = app
            currentSession = session
        }

        return try await webServer.start()
    }

    public func stop() async {
        frameProducer.stop()
        hidBridge.invalidate()
        webServer.stop()

        stateLock.withScopedLock {
            currentApp = nil
            currentSession = nil
        }
    }

    public func pageURL() -> URL? {
        webServer.pageURL
    }

    public func openSimulatorWindow() throws {
        let session = stateLock.withScopedLock {
            currentSession
        }
        guard let session else {
            throw PreviewError.message("No active preview session.")
        }
        try hostService.openSimulatorWindow(for: session)
    }

    private func handle(event: PreviewInteractionEvent) async throws {
        let frameSize = frameProducer.currentFrame()?.pixelSize ?? CGSize(width: 390, height: 844)
        try await Task.detached(priority: .userInitiated) { [hidBridge] in
            try hidBridge.sendInteraction(event, frameSize: frameSize)
        }.value
    }

    private func pageContext() -> PreviewPageContext {
        let (app, session) = stateLock.withScopedLock {
            (currentApp, currentSession)
        }

        let deviceName = session?.device.name ?? app?.displayName ?? "Preview Device"
        let intervalMs = Int(max(1, configuration.frameIntervalNanoseconds / 1_000_000))
        return PreviewPageContext(deviceName: deviceName, frameIntervalMilliseconds: intervalMs)
    }
}

private extension NSLock {
    func withScopedLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
