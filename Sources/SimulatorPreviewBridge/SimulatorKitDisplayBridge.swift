import AppKit
import CoreImage
import Darwin
import Foundation
import IOSurface
import ObjectiveC.runtime
import SimulatorPreviewCore
import os.log

private let displayLogger = Logger(subsystem: "SimulatorPreviewKit", category: "DisplayBridge")

final class SimulatorKitDisplayBridge: @unchecked Sendable {
    private enum BridgeError: LocalizedError {
        case frameworkUnavailable(String)
        case runtimeUnavailable(String)
        case deviceUnavailable(String)
        case portUnavailable(String)
        case surfaceUnavailable(String)
        case imageDecodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable(let detail),
                 .runtimeUnavailable(let detail),
                 .deviceUnavailable(let detail),
                 .portUnavailable(let detail),
                 .surfaceUnavailable(let detail),
                 .imageDecodeFailed(let detail):
                return detail
            }
        }
    }

    private struct CallbackRegistration {
        let registrationID: NSUUID
        let callbackQueue: DispatchQueue?
        let ioSurfaceCallback: AnyObject?
        let frameCallback: AnyObject?
        let surfacesChangedCallback: AnyObject?
        let propertiesChangedCallback: AnyObject?
    }

    private final class SessionState {
        let session: IsolatedSimulatorSession
        let device: AnyObject
        let ioClient: AnyObject
        let descriptor: AnyObject
        let callbackRegistration: CallbackRegistration?

        init(
            session: IsolatedSimulatorSession,
            device: AnyObject,
            ioClient: AnyObject,
            descriptor: AnyObject,
            callbackRegistration: CallbackRegistration?
        ) {
            self.session = session
            self.device = device
            self.ioClient = ioClient
            self.descriptor = descriptor
            self.callbackRegistration = callbackRegistration
        }
    }

    private typealias RegisterIOSurfaceCallbackFn = @convention(c) (AnyObject, Selector, NSUUID, AnyObject) -> Void
    private typealias RegisterScreenCallbacksFn = @convention(c) (
        AnyObject,
        Selector,
        NSUUID,
        DispatchQueue,
        AnyObject,
        AnyObject,
        AnyObject
    ) -> Void
    private typealias SurfaceGetterFn = @convention(c) (AnyObject, Selector) -> IOSurface?

    private static let surfaceSelectors = [
        "maskedFramebufferSurface",
        "framebufferSurface",
        "ioSurface",
        "surface",
    ]

    private let developerDir: String
    private let ciContext: CIContext
    private var state: SessionState?
    private var cachedSurface: IOSurface?

    init(
        developerDir: String = "/Applications/Xcode.app/Contents/Developer",
        ciContext: CIContext = CIContext(options: [.cacheIntermediates: false])
    ) {
        self.developerDir = developerDir
        self.ciContext = ciContext
    }

    func prepare(session: IsolatedSimulatorSession) throws {
        if let state,
           state.session.deviceSetPath == session.deviceSetPath,
           state.session.device.udid == session.device.udid {
            return
        }

        try loadFramework(
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
            name: "CoreSimulator"
        )
        try loadFramework(
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Frameworks/CoreSimDeviceIO.framework/CoreSimDeviceIO",
            name: "CoreSimDeviceIO"
        )

        guard let serviceContextClass = NSClassFromString("SimServiceContext") else {
            throw BridgeError.runtimeUnavailable("SimServiceContext was not available.")
        }

        let contextClassObject = serviceContextClass as AnyObject
        guard let context = invoke(
            contextClassObject,
            "sharedServiceContextForDeveloperDir:error:",
            developerDir as NSString,
            nil
        ) else {
            throw BridgeError.runtimeUnavailable("CoreSimulator service context could not be created.")
        }

        guard let deviceSet = invoke(
            context,
            "deviceSetWithPath:error:",
            session.deviceSetPath as NSString,
            nil
        ) else {
            throw BridgeError.runtimeUnavailable("CoreSimulator device set could not be opened.")
        }

        let device = try findDevice(in: deviceSet, udid: session.device.udid)
        guard let ioClient = invoke(device, "io") else {
            throw BridgeError.runtimeUnavailable("SimDevice IO client was unavailable.")
        }

        let descriptor = try displayDescriptor(from: ioClient)
        let callbackRegistration = registerCallbacksIfAvailable(on: descriptor)

        state = SessionState(
            session: session,
            device: device,
            ioClient: ioClient,
            descriptor: descriptor,
            callbackRegistration: callbackRegistration
        )

        _ = waitForInitialSurface(on: descriptor)
    }

    func invalidate() {
        cachedSurface = nil
        state = nil
    }

    func currentSurface() throws -> IOSurface {
        if let cachedSurface {
            return cachedSurface
        }

        guard let state else {
            throw BridgeError.runtimeUnavailable("Display bridge was not prepared.")
        }

        if let surface = preferredSurfaceIfAvailable(from: state.descriptor) {
            cachedSurface = surface
            return surface
        }

        throw BridgeError.surfaceUnavailable("Display surface was not available from framebuffer.display.")
    }

    func captureImage() throws -> NSImage {
        let surface = try currentSurface()
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0 else {
            throw BridgeError.surfaceUnavailable("Display surface size was invalid.")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ciImage = CIImage(ioSurface: surface, options: [CIImageOption.colorSpace: colorSpace])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = ciContext.createCGImage(ciImage, from: bounds) else {
            throw BridgeError.imageDecodeFailed("Display surface could not be converted into an image.")
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func displayDescriptor(from ioClient: AnyObject) throws -> AnyObject {
        guard let portsObject = invoke(ioClient, "ioPorts") else {
            throw BridgeError.portUnavailable("SimDevice IO ports were unavailable.")
        }

        let ports = portObjects(from: portsObject)
        guard !ports.isEmpty else {
            throw BridgeError.portUnavailable("SimDevice IO ports were empty.")
        }

        let displayPorts = ports.filter { port in
            guard let id = invoke(port, "portIdentifier") as? String else { return false }
            return id == "com.apple.framebuffer.display"
        }

        guard !displayPorts.isEmpty else {
            let portIDs = ports.compactMap { invoke($0, "portIdentifier") as? String }
            throw BridgeError.portUnavailable("Display IO port was not available. Ports: \(portIDs)")
        }

        var fallbackDescriptor: AnyObject?
        for port in displayPorts {
            guard let descriptor = invoke(port, "descriptor") else {
                continue
            }

            if preferredSurfaceIfAvailable(from: descriptor) != nil {
                return descriptor
            }

            if fallbackDescriptor == nil {
                let className = String(describing: type(of: descriptor))
                if className.contains("SimDisplayIOSurfaceRenderable") {
                    fallbackDescriptor = descriptor
                }
            }
        }

        if let last = displayPorts.last.flatMap({ invoke($0, "descriptor") }) {
            let className = String(describing: type(of: last))
            if className.contains("SimDisplayIOSurfaceRenderable") {
                return last
            }
        }

        if let fallbackDescriptor {
            return fallbackDescriptor
        }

        throw BridgeError.portUnavailable("No display descriptor with surface capability found.")
    }

    private func preferredSurfaceIfAvailable(from descriptor: AnyObject) -> IOSurface? {
        for selector in Self.surfaceSelectors {
            if let surface = invokeSurface(descriptor, selector: selector) {
                return surface
            }
        }
        return nil
    }

    private func invokeSurface(_ descriptor: AnyObject, selector: String) -> IOSurface? {
        let selectorValue = NSSelectorFromString(selector)
        guard descriptor.responds(to: selectorValue) else { return nil }

        if let msgSend = dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend") {
            let send = unsafeBitCast(msgSend, to: SurfaceGetterFn.self)
            if let surface = send(descriptor, selectorValue) {
                return surface
            }
        }

        if let result = descriptor.perform(selectorValue)?.takeUnretainedValue() as? IOSurface {
            return result
        }

        return nil
    }

    private func waitForInitialSurface(on descriptor: AnyObject) -> Bool {
        let maxAttempts = 60
        for _ in 0..<maxAttempts {
            if let surface = preferredSurfaceIfAvailable(from: descriptor) {
                cachedSurface = surface
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func registerCallbacksIfAvailable(on descriptor: AnyObject) -> CallbackRegistration? {
        let registrationID = NSUUID()
        var callbackQueue: DispatchQueue?
        var ioSurfaceCallback: AnyObject?
        var frameCallback: AnyObject?
        var surfacesChangedCallback: AnyObject?
        var propertiesChangedCallback: AnyObject?

        let ioSurfaceSelector = NSSelectorFromString("registerCallbackWithUUID:ioSurfacesChangeCallback:")
        if descriptor.responds(to: ioSurfaceSelector) {
            let callback: @convention(block) () -> Void = { [weak self] in
                self?.handleSurfaceReplaced(from: descriptor)
            }
            let callbackObject = unsafeBitCast(callback, to: AnyObject.self)
            let send = unsafeBitCast(
                dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")!,
                to: RegisterIOSurfaceCallbackFn.self
            )
            send(descriptor, ioSurfaceSelector, registrationID, callbackObject)
            ioSurfaceCallback = callbackObject
        }

        let screenCallbacksSelector = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        if descriptor.responds(to: screenCallbacksSelector) {
            let queue = DispatchQueue(label: "simulator-preview-kit.display.bridge")
            let frameBlock: @convention(block) () -> Void = {}
            let surfacesBlock: @convention(block) () -> Void = { [weak self] in
                self?.handleSurfaceReplaced(from: descriptor)
            }
            let propertiesBlock: @convention(block) () -> Void = {}

            let frameObject = unsafeBitCast(frameBlock, to: AnyObject.self)
            let surfacesObject = unsafeBitCast(surfacesBlock, to: AnyObject.self)
            let propertiesObject = unsafeBitCast(propertiesBlock, to: AnyObject.self)

            let send = unsafeBitCast(
                dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")!,
                to: RegisterScreenCallbacksFn.self
            )
            send(
                descriptor,
                screenCallbacksSelector,
                registrationID,
                queue,
                frameObject,
                surfacesObject,
                propertiesObject
            )

            callbackQueue = queue
            frameCallback = frameObject
            surfacesChangedCallback = surfacesObject
            propertiesChangedCallback = propertiesObject
        }

        guard ioSurfaceCallback != nil || frameCallback != nil || surfacesChangedCallback != nil || propertiesChangedCallback != nil else {
            return nil
        }

        return CallbackRegistration(
            registrationID: registrationID,
            callbackQueue: callbackQueue,
            ioSurfaceCallback: ioSurfaceCallback,
            frameCallback: frameCallback,
            surfacesChangedCallback: surfacesChangedCallback,
            propertiesChangedCallback: propertiesChangedCallback
        )
    }

    private func handleSurfaceReplaced(from descriptor: AnyObject) {
        cachedSurface = preferredSurfaceIfAvailable(from: descriptor)
    }

    private func findDevice(in deviceSet: AnyObject, udid: String) throws -> AnyObject {
        guard let devicesValue = deviceSet.value(forKey: "devices") else {
            throw BridgeError.deviceUnavailable("Simulator device list was unavailable.")
        }

        let devices = portObjects(from: devicesValue)
        guard let device = devices.first(where: { deviceUDID(for: $0) == udid }) else {
            throw BridgeError.deviceUnavailable("Preview simulator \(udid) was not found in the isolated device set.")
        }
        return device
    }

    private func portObjects(from value: Any) -> [AnyObject] {
        if let array = value as? [AnyObject] {
            return array
        }
        if let array = value as? NSArray {
            return array.compactMap { $0 as AnyObject }
        }
        if let set = value as? NSSet {
            return set.allObjects.compactMap { $0 as AnyObject }
        }
        return []
    }

    private func deviceUDID(for device: AnyObject) -> String? {
        if let uuid = device.value(forKey: "UDID") as? UUID {
            return uuid.uuidString
        }
        if let uuid = device.value(forKey: "UDID") as? NSUUID {
            return uuid.uuidString
        }
        if let string = device.value(forKey: "UDID") as? String {
            return string
        }
        return nil
    }

    private func loadFramework(_ path: String, name: String) throws {
        guard dlopen(path, RTLD_NOW) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown error"
            displayLogger.error("\(name, privacy: .public) load failed: \(detail, privacy: .public)")
            throw BridgeError.frameworkUnavailable("\(name) could not be loaded: \(detail)")
        }
    }

    private func invoke(_ target: AnyObject, _ selector: String, _ args: Any?...) -> AnyObject? {
        let selectorValue = NSSelectorFromString(selector)
        switch args.count {
        case 0:
            return target.perform(selectorValue)?.takeUnretainedValue() as AnyObject?
        case 1:
            return target.perform(selectorValue, with: args[0])?.takeUnretainedValue() as AnyObject?
        default:
            return target.perform(selectorValue, with: args[0], with: args[1])?.takeUnretainedValue() as AnyObject?
        }
    }
}
