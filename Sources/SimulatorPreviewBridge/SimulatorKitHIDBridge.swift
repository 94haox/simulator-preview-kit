import AppKit
import Darwin
import Foundation
import ObjectiveC.runtime
import SimulatorPreviewCore
import os.log

private let hidLogger = Logger(subsystem: "SimulatorPreviewKit", category: "HIDBridge")

public final class SimulatorKitHIDBridge: @unchecked Sendable {
    private enum BridgeError: LocalizedError {
        case frameworkUnavailable(String)
        case symbolUnavailable(String)
        case runtimeUnavailable(String)
        case deviceUnavailable(String)
        case messageCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .frameworkUnavailable(let detail),
                 .symbolUnavailable(let detail),
                 .runtimeUnavailable(let detail),
                 .deviceUnavailable(let detail),
                 .messageCreationFailed(let detail):
                return detail
            }
        }
    }

    private final class SessionState {
        let session: IsolatedSimulatorSession
        let device: AnyObject
        let pointerTarget: UInt32?
        var lastPointerLocation: CGPoint?
        private let xpcKeepAlive: [AnyObject]

        init(session: IsolatedSimulatorSession, device: AnyObject, pointerTarget: UInt32?, keepAlive: [AnyObject]) {
            self.session = session
            self.device = device
            self.pointerTarget = pointerTarget
            self.xpcKeepAlive = keepAlive
        }
    }

    private static let touchDigitizerTarget: UInt32 = 0x32

    private struct RuntimeSymbols {
        typealias KeyboardMessageFn = @convention(c) (NSEvent) -> UnsafeMutableRawPointer?
        typealias MouseMessageFn = @convention(c) (
            UnsafePointer<CGPoint>,
            UnsafePointer<CGPoint>?,
            UInt32,
            UInt32,
            UInt32,
            Double,
            Double,
            Double,
            Double
        ) -> UnsafeMutableRawPointer?
        typealias ScrollMessageFn = @convention(c) (
            UInt32,
            Double,
            Double,
            Double
        ) -> UnsafeMutableRawPointer?
        typealias MessageFactoryFn = @convention(c) () -> UnsafeMutableRawPointer?
        typealias ScreenTargetFn = @convention(c) (UInt32) -> UInt32

        let serviceContextClass: AnyClass
        let hidClientClass: AnyClass
        let keyboardMessage: KeyboardMessageFn
        let mouseMessage: MouseMessageFn
        let scrollMessage: ScrollMessageFn
        let createPointerService: MessageFactoryFn
        let createMouseService: MessageFactoryFn
        let screenTargetForScreen: ScreenTargetFn
        let objcMsgSend: UnsafeMutableRawPointer

        static func load() throws -> RuntimeSymbols {
            try loadFramework(
                "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",
                name: "CoreSimulator"
            )
            try loadFramework(
                "/Applications/Xcode.app/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit",
                name: "SimulatorKit"
            )

            guard let serviceContextClass = NSClassFromString("SimServiceContext") else {
                throw BridgeError.runtimeUnavailable("SimServiceContext was not available.")
            }
            let hidClientClassName = "_TtC12SimulatorKit24SimDeviceLegacyHIDClient"
            guard let hidClientClass = NSClassFromString(hidClientClassName) else {
                throw BridgeError.runtimeUnavailable("SimDeviceLegacyHIDClient was not available (tried \(hidClientClassName)).")
            }
            guard let msgSend = dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend") else {
                throw BridgeError.runtimeUnavailable("Could not resolve objc_msgSend.")
            }

            return RuntimeSymbols(
                serviceContextClass: serviceContextClass,
                hidClientClass: hidClientClass,
                keyboardMessage: try loadSymbol("IndigoHIDMessageForKeyboardNSEvent"),
                mouseMessage: try loadSymbol("IndigoHIDMessageForMouseNSEvent"),
                scrollMessage: try loadSymbol("IndigoHIDMessageForScrollEvent"),
                createPointerService: try loadSymbol("IndigoHIDMessageToCreatePointerService"),
                createMouseService: try loadSymbol("IndigoHIDMessageToCreateMouseService"),
                screenTargetForScreen: try loadSymbol("IndigoHIDTargetForScreen"),
                objcMsgSend: msgSend
            )
        }

        func send(_ message: UnsafeMutableRawPointer, forDevice device: AnyObject) throws {
            let client = try createHIDClient(for: device)
            let sendSelector = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")

            typealias SendFn = @convention(c) (
                AnyObject, Selector,
                UnsafeMutableRawPointer,
                ObjCBool,
                DispatchQueue?,
                (@convention(block) (NSError?) -> Void)?
            ) -> Void
            let fn = unsafeBitCast(objcMsgSend, to: SendFn.self)
            fn(client, sendSelector, message, ObjCBool(false), nil, nil)
            _ = client
        }

        func createHIDClient(for device: AnyObject) throws -> AnyObject {
            let allocSelector = NSSelectorFromString("alloc")
            let initSelector = NSSelectorFromString("initWithDevice:error:")
            guard let allocated = (hidClientClass as AnyObject)
                .perform(allocSelector)?
                .takeUnretainedValue() else {
                throw BridgeError.runtimeUnavailable("SimDeviceLegacyHIDClient alloc failed.")
            }
            typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<AnyObject?>) -> AnyObject?
            let initFn = unsafeBitCast(objcMsgSend, to: InitFn.self)
            var initError: AnyObject?
            guard let client = initFn(allocated, initSelector, device, &initError) else {
                let errorDesc = (initError as? NSError)?.localizedDescription ?? "unknown"
                throw BridgeError.runtimeUnavailable("SimDeviceLegacyHIDClient init failed: \(errorDesc)")
            }
            return client
        }

        private static func loadFramework(_ path: String, name: String) throws {
            guard dlopen(path, RTLD_NOW) != nil else {
                let detail = dlerror().map { String(cString: $0) } ?? "unknown error"
                throw BridgeError.frameworkUnavailable("\(name) could not be loaded: \(detail)")
            }
        }

        private static func loadSymbol<T>(_ name: String) throws -> T {
            let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
            guard let pointer = dlsym(defaultHandle, name) else {
                throw BridgeError.symbolUnavailable("\(name) was not available.")
            }
            return unsafeBitCast(pointer, to: T.self)
        }
    }

    private let processRunner: ProcessRunner
    private let developerDir: String

    private var runtimeSymbols: RuntimeSymbols?
    private var state: SessionState?

    public init(
        processRunner: ProcessRunner = ProcessRunner(),
        developerDir: String = "/Applications/Xcode.app/Contents/Developer"
    ) {
        self.processRunner = processRunner
        self.developerDir = developerDir
    }

    public func prepare(session: IsolatedSimulatorSession) throws {
        if let state,
           state.session.deviceSetPath == session.deviceSetPath,
           state.session.device.udid == session.device.udid {
            return
        }

        let runtimeSymbols = try runtimeSymbols ?? RuntimeSymbols.load()
        let (device, keepAlive) = try resolveDevice(runtimeSymbols: runtimeSymbols, session: session)
        _ = try runtimeSymbols.createHIDClient(for: device)
        let pointerTarget = try resolvePointerTarget(for: session, runtimeSymbols: runtimeSymbols)

        self.runtimeSymbols = runtimeSymbols
        self.state = SessionState(session: session, device: device, pointerTarget: pointerTarget, keepAlive: keepAlive)
    }

    public func invalidate() {
        state = nil
    }

    public func warmUpPointerIfNeeded() throws {
        guard let runtimeSymbols, let state, state.pointerTarget != nil else { return }
        if let pointerService = runtimeSymbols.createPointerService() {
            try runtimeSymbols.send(pointerService, forDevice: state.device)
        }
        if let mouseService = runtimeSymbols.createMouseService() {
            try runtimeSymbols.send(mouseService, forDevice: state.device)
        }
    }

    public func sendInteraction(_ event: PreviewInteractionEvent, frameSize: CGSize) throws {
        switch event.kind {
        case .touchDown, .touchMove, .touchUp:
            let type: CGEventType
            switch event.kind {
            case .touchDown: type = .leftMouseDown
            case .touchMove: type = .leftMouseDragged
            case .touchUp: type = .leftMouseUp
            default: fatalError()
            }

            try sendTouch(
                type,
                normalizedLocation: CGPoint(
                    x: max(0, min(1, event.x ?? 0)),
                    y: max(0, min(1, event.y ?? 0))
                ),
                screenSize: frameSize
            )
        case .scroll:
            try sendScroll(deltaX: event.deltaX ?? 0, deltaY: event.deltaY ?? 0)
        case .keyDown:
            try sendKey(code: event.code ?? "", key: event.key ?? "", modifiers: event.modifiers ?? PreviewKeyModifiers())
        }
    }

    private func sendKey(code: String, key: String, modifiers: PreviewKeyModifiers) throws {
        guard let runtimeSymbols, let state else { return }
        guard let keyCode = DOMKeyboardMapper.keyCode(for: code, key: key) else {
            hidLogger.warning("Ignoring unmapped key event code=\(code, privacy: .public) key=\(key, privacy: .public)")
            return
        }

        let characters = DOMKeyboardMapper.characters(for: key)
        let flags = DOMKeyboardMapper.modifierFlags(from: modifiers)

        try sendKeyboardEvent(
            type: .keyDown,
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: characters,
            modifierFlags: flags,
            runtimeSymbols: runtimeSymbols,
            device: state.device
        )
        try sendKeyboardEvent(
            type: .keyUp,
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: characters,
            modifierFlags: flags,
            runtimeSymbols: runtimeSymbols,
            device: state.device
        )
    }

    private func sendTouch(_ type: CGEventType, normalizedLocation: CGPoint, screenSize: CGSize) throws {
        guard let runtimeSymbols, let state else { return }

        var point = CGPoint(x: normalizedLocation.x, y: normalizedLocation.y)

        let nsEventType: UInt32
        let direction: UInt32
        switch type {
        case .leftMouseDown:
            nsEventType = UInt32(NSEvent.EventType.leftMouseDown.rawValue)
            direction = 1
        case .leftMouseDragged:
            nsEventType = UInt32(NSEvent.EventType.leftMouseDragged.rawValue)
            direction = 0
        case .leftMouseUp:
            nsEventType = UInt32(NSEvent.EventType.leftMouseUp.rawValue)
            direction = 2
        default:
            return
        }

        guard let message = runtimeSymbols.mouseMessage(
            &point,
            nil,
            Self.touchDigitizerTarget,
            nsEventType,
            direction,
            1.0,
            1.0,
            Double(screenSize.width),
            Double(screenSize.height)
        ) else {
            throw BridgeError.messageCreationFailed("Touch input could not be encoded for the simulator.")
        }

        try runtimeSymbols.send(message, forDevice: state.device)
    }

    private func sendScroll(deltaX: CGFloat, deltaY: CGFloat) throws {
        guard let runtimeSymbols, let state else { return }

        guard let message = runtimeSymbols.scrollMessage(
            Self.touchDigitizerTarget,
            Double(deltaX),
            Double(deltaY),
            0
        ) else {
            throw BridgeError.messageCreationFailed("Scroll input could not be encoded for the simulator.")
        }

        try runtimeSymbols.send(message, forDevice: state.device)
    }

    private func sendKeyboardEvent(
        type: NSEvent.EventType,
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags,
        runtimeSymbols: RuntimeSymbols,
        device: AnyObject
    ) throws {
        guard let keyEvent = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            throw BridgeError.messageCreationFailed("Keyboard input could not be encoded for the simulator.")
        }

        guard let message = runtimeSymbols.keyboardMessage(keyEvent) else {
            throw BridgeError.messageCreationFailed("Keyboard input could not be encoded for the simulator.")
        }

        try runtimeSymbols.send(message, forDevice: device)
    }

    private func resolveDevice(runtimeSymbols: RuntimeSymbols, session: IsolatedSimulatorSession) throws -> (AnyObject, [AnyObject]) {
        let contextClassObject = runtimeSymbols.serviceContextClass as AnyObject
        let sharedSelector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let context = contextClassObject
            .perform(sharedSelector, with: developerDir, with: nil)?
            .takeUnretainedValue() as AnyObject? else {
            throw BridgeError.runtimeUnavailable("CoreSimulator service context could not be created.")
        }

        let connectSelector = NSSelectorFromString("connectWithError:")
        if context.responds(to: connectSelector) {
            _ = context.perform(connectSelector, with: nil)
        }

        let deviceSetSelector = NSSelectorFromString("deviceSetWithPath:error:")
        guard let deviceSet = context
            .perform(deviceSetSelector, with: session.deviceSetPath, with: nil)?
            .takeUnretainedValue() as AnyObject? else {
            throw BridgeError.runtimeUnavailable("CoreSimulator device set could not be opened.")
        }

        let device = try findDevice(in: deviceSet, udid: session.device.udid)
        return (device, [context, deviceSet])
    }

    private func findDevice(in deviceSet: AnyObject, udid: String) throws -> AnyObject {
        guard let devicesValue = deviceSet.value(forKey: "devices") else {
            throw BridgeError.deviceUnavailable("Simulator device list was unavailable.")
        }

        let devices = deviceObjects(from: devicesValue)
        guard let device = devices.first(where: { deviceUDID(for: $0) == udid }) else {
            throw BridgeError.deviceUnavailable("Preview simulator \(udid) was not found in the isolated device set.")
        }
        return device
    }

    private func deviceObjects(from value: Any) -> [AnyObject] {
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

    private func resolvePointerTarget(
        for session: IsolatedSimulatorSession,
        runtimeSymbols: RuntimeSymbols
    ) throws -> UInt32? {
        guard let screenID = try primaryScreenID(for: session) else {
            return nil
        }
        return runtimeSymbols.screenTargetForScreen(screenID)
    }

    private func primaryScreenID(for session: IsolatedSimulatorSession) throws -> UInt32? {
        let output = try processRunner.capture(
            "xcrun",
            ["simctl", "--set", session.deviceSetPath, "io", session.device.udid, "enumerate"],
            maxBytes: 256 * 1024
        )
        return parseIntegratedScreenID(from: output) ?? 1
    }

    private func parseIntegratedScreenID(from output: String) -> UInt32? {
        let lines = output.components(separatedBy: .newlines)
        var inConnectedScreens = false
        var currentScreenID: UInt32?
        var currentScreenType: String?
        var firstConnectedScreenID: UInt32?

        func flushCurrentScreen() -> UInt32? {
            defer {
                currentScreenID = nil
                currentScreenType = nil
            }

            guard let currentScreenID else { return nil }
            if firstConnectedScreenID == nil {
                firstConnectedScreenID = currentScreenID
            }
            if currentScreenType == "Integrated" {
                return currentScreenID
            }
            return nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed == "Connected Screens:" {
                inConnectedScreens = true
                continue
            }

            guard inConnectedScreens else { continue }

            if trimmed == "Port:" {
                if let integratedScreenID = flushCurrentScreen() {
                    return integratedScreenID
                }
                break
            }

            if trimmed.hasPrefix("("), trimmed.hasSuffix(":") {
                if let integratedScreenID = flushCurrentScreen() {
                    return integratedScreenID
                }

                let idString = trimmed
                    .dropFirst()
                    .dropLast(2)
                currentScreenID = UInt32(idString)
                continue
            }

            if trimmed.hasPrefix("Type: ") {
                currentScreenType = String(trimmed.dropFirst("Type: ".count))
            }
        }

        return flushCurrentScreen() ?? firstConnectedScreenID
    }
}
