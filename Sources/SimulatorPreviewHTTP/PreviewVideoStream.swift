import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SimulatorPreviewBridge
import SimulatorPreviewCore
import UniformTypeIdentifiers
import os.log

public struct PreviewVideoStreamStatus: Sendable {
    public let isReady: Bool
    public let segmentCount: Int
    public let lastError: String?

    public init(isReady: Bool, segmentCount: Int, lastError: String? = nil) {
        self.isReady = isReady
        self.segmentCount = segmentCount
        self.lastError = lastError
    }
}

public final class PreviewVideoStream: NSObject, @unchecked Sendable {
    private static let logger = Logger(subsystem: "SimulatorPreviewKit", category: "PreviewVideoStream")

    private struct Segment: Sendable {
        let name: String
        let sequence: Int
        let duration: Double
        let data: Data
    }

    private struct StreamState: Sendable {
        var initializationSegment: Data?
        var playlistData: Data?
        var segments: [Segment] = []
        var nextSequence = 0
        var lastError: String?

        var status: PreviewVideoStreamStatus {
            PreviewVideoStreamStatus(
                isReady: initializationSegment != nil && !segments.isEmpty,
                segmentCount: segments.count,
                lastError: lastError
            )
        }
    }

    private final class WriterState {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let renderSize: CGSize

        var frameIndex: Int64 = 0
        var lastFrame: PreviewRenderableFrame?

        init(
            writer: AVAssetWriter,
            input: AVAssetWriterInput,
            adaptor: AVAssetWriterInputPixelBufferAdaptor,
            renderSize: CGSize
        ) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.renderSize = renderSize
        }
    }

    private let frameProvider: @Sendable () -> PreviewRenderableFrame?
    private let frameIntervalNanoseconds: UInt64
    private let segmentDurationSeconds: Double
    private let retainedSegmentCount: Int
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    private var appendTask: Task<Void, Never>?
    private var writerState: WriterState?
    private var streamState = StreamState()

    public init(
        frameProvider: @escaping @Sendable () -> PreviewRenderableFrame?,
        frameIntervalNanoseconds: UInt64 = 120_000_000,
        segmentDurationSeconds: Double = 1.0,
        retainedSegmentCount: Int = 6
    ) {
        self.frameProvider = frameProvider
        self.frameIntervalNanoseconds = frameIntervalNanoseconds
        self.segmentDurationSeconds = segmentDurationSeconds
        self.retainedSegmentCount = max(3, retainedSegmentCount)
    }

    public func start() async throws {
        await stop()

        appendTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() async {
        appendTask?.cancel()
        appendTask = nil

        let writerState = lock.withScopedLock { () -> WriterState? in
            defer { self.writerState = nil }
            return self.writerState
        }

        if let writerState {
            writerState.input.markAsFinished()
            writerState.writer.flushSegment()
            await withCheckedContinuation { continuation in
                writerState.writer.finishWriting {
                    continuation.resume()
                }
            }
        }

        lock.withScopedLock {
            streamState = StreamState()
        }
    }

    public func playlistData() -> Data? {
        lock.withScopedLock { streamState.playlistData }
    }

    public func initializationSegmentData() -> Data? {
        lock.withScopedLock { streamState.initializationSegment }
    }

    public func segmentData(named name: String) -> Data? {
        lock.withScopedLock {
            streamState.segments.first(where: { $0.name == name })?.data
        }
    }

    public func status() -> PreviewVideoStreamStatus {
        lock.withScopedLock { streamState.status }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await appendNextFrameIfPossible()
            } catch {
                recordError(error)
            }

            do {
                try await Task.sleep(nanoseconds: frameIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func appendNextFrameIfPossible() async throws {
        guard let snapshot = frameProvider() ?? lock.withScopedLock({ self.writerState?.lastFrame }) else {
            return
        }

        let state = try prepareWriterIfNeeded(for: snapshot)
        lock.withScopedLock {
            state.lastFrame = snapshot
        }

        guard state.input.isReadyForMoreMediaData else {
            return
        }

        guard let pixelBufferPool = state.adaptor.pixelBufferPool else {
            throw PreviewError.message("Video stream pixel buffer pool was unavailable.")
        }

        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)
        guard result == kCVReturnSuccess, let pixelBuffer else {
            throw PreviewError.message("Video stream pixel buffer allocation failed.")
        }

        try render(snapshot: snapshot, to: pixelBuffer, renderSize: state.renderSize)

        let frameDuration = CMTime(
            value: Int64(frameIntervalNanoseconds),
            timescale: 1_000_000_000
        )
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(state.frameIndex))

        guard state.adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            let message = state.writer.error?.localizedDescription ?? "unknown error"
            throw PreviewError.message("Video stream append failed: \(message)")
        }
        state.frameIndex += 1
    }

    private func prepareWriterIfNeeded(for snapshot: PreviewRenderableFrame) throws -> WriterState {
        if let existing = lock.withScopedLock({ writerState }) {
            return existing
        }

        let renderSize = CGSize(
            width: max(1, round(snapshot.pixelSize.width)),
            height: max(1, round(snapshot.pixelSize.height))
        )

        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            throw PreviewError.message("UTType.mp4 was unavailable for video stream output.")
        }
        let writer = AVAssetWriter(contentType: contentType)
        writer.delegate = self
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(
            seconds: segmentDurationSeconds,
            preferredTimescale: 600
        )
        writer.initialSegmentStartTime = .zero

        let fps = max(1, Int(round(1_000_000_000.0 / Double(frameIntervalNanoseconds))))
        let keyFrameInterval = max(1, Int(round(segmentDurationSeconds * Double(fps))))
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(500_000, Int(renderSize.width * renderSize.height * 4)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: keyFrameInterval,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )

        guard writer.canAdd(input) else {
            throw PreviewError.message("Video stream writer could not add a video input.")
        }
        writer.add(input)

        guard writer.startWriting() else {
            let message = writer.error?.localizedDescription ?? "unknown error"
            throw PreviewError.message("Video stream writer could not start: \(message)")
        }
        writer.startSession(atSourceTime: .zero)

        let state = WriterState(
            writer: writer,
            input: input,
            adaptor: adaptor,
            renderSize: renderSize
        )
        lock.withScopedLock {
            streamState.lastError = nil
            writerState = state
        }
        return state
    }

    private func render(
        snapshot: PreviewRenderableFrame,
        to pixelBuffer: CVPixelBuffer,
        renderSize: CGSize
    ) throws {
        let image: CIImage
        switch snapshot.backing {
        case .ioSurface(let surface):
            image = CIImage(
                ioSurface: surface,
                options: [CIImageOption.colorSpace: CGColorSpaceCreateDeviceRGB()]
            )
        case .encodedImage(let data, _):
            guard let decoded = CIImage(data: data) else {
                throw PreviewError.message("Video stream could not decode preview frame.")
            }
            image = decoded
        }

        let targetRect = CGRect(origin: .zero, size: renderSize)
        let extent = image.extent.integral
        let scaledImage = image.transformed(by: CGAffineTransform(
            scaleX: targetRect.width / max(extent.width, 1),
            y: targetRect.height / max(extent.height, 1)
        ))

        ciContext.render(
            scaledImage,
            to: pixelBuffer,
            bounds: targetRect,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    private func appendInitializationSegment(_ data: Data) {
        lock.withScopedLock {
            streamState.initializationSegment = data
            streamState.lastError = nil
            rebuildPlaylist()
        }
    }

    private func appendMediaSegment(_ data: Data, duration: Double) {
        lock.withScopedLock {
            let sequence = streamState.nextSequence
            streamState.nextSequence += 1
            streamState.segments.append(
                Segment(
                    name: "segment-\(sequence).m4s",
                    sequence: sequence,
                    duration: max(0.1, duration),
                    data: data
                )
            )
            if streamState.segments.count > retainedSegmentCount {
                streamState.segments.removeFirst(streamState.segments.count - retainedSegmentCount)
            }
            streamState.lastError = nil
            rebuildPlaylist()
        }
    }

    private func recordError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Self.logger.error("HLS stream error: \(message, privacy: .public)")
        lock.withScopedLock {
            streamState.lastError = message
        }
    }

    private func rebuildPlaylist() {
        guard streamState.initializationSegment != nil, !streamState.segments.isEmpty else {
            streamState.playlistData = nil
            return
        }

        let targetDuration = Int(ceil(streamState.segments.map(\.duration).max() ?? segmentDurationSeconds))
        let mediaSequence = streamState.segments.first?.sequence ?? 0

        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(max(1, targetDuration))",
            "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"/stream/init.mp4\"",
        ]

        for segment in streamState.segments {
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("/stream/segments/\(segment.name)")
        }

        streamState.playlistData = Data(lines.joined(separator: "\n").appending("\n").utf8)
    }
}

extension PreviewVideoStream: AVAssetWriterDelegate {
    public func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {
        switch segmentType {
        case .initialization:
            appendInitializationSegment(segmentData)
        case .separable:
            appendMediaSegment(segmentData, duration: segmentDurationSeconds)
        @unknown default:
            break
        }
    }

    public func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType,
        segmentReport: AVAssetSegmentReport?
    ) {
        switch segmentType {
        case .initialization:
            appendInitializationSegment(segmentData)
        case .separable:
            let duration = segmentReport?
                .trackReports
                .first(where: { $0.mediaType == .video })?
                .duration
                .seconds ?? segmentDurationSeconds
            appendMediaSegment(segmentData, duration: duration)
        @unknown default:
            break
        }
    }
}

private extension NSLock {
    func withScopedLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
