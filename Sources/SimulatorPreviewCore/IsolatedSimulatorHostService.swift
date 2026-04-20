import CryptoKit
import Foundation

public struct IsolatedSimulatorSession: Codable, Equatable, Sendable {
    public let deviceSetPath: String
    public let device: SelectedSimulator
    public let bundleId: String
    public let appPath: String

    public init(deviceSetPath: String, device: SelectedSimulator, bundleId: String, appPath: String) {
        self.deviceSetPath = deviceSetPath
        self.device = device
        self.bundleId = bundleId
        self.appPath = appPath
    }
}

public struct IsolatedSimulatorHostConfiguration: Codable, Equatable, Sendable {
    public let deviceSetPath: String
    public let preferredDeviceName: String?

    public init(deviceSetPath: String = Self.defaultDeviceSetPath().path, preferredDeviceName: String? = nil) {
        self.deviceSetPath = deviceSetPath
        self.preferredDeviceName = preferredDeviceName
    }

    public static func defaultDeviceSetPath() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("SimulatorPreviewKit/Devices", isDirectory: true)
    }
}

public struct IsolatedSimulatorHostService {
    struct InstalledAppState: Codable, Equatable {
        let deviceUDID: String
        let bundleID: String
        let appPath: String
        let appFingerprint: String
    }

    struct InstalledAppStateEnvelope: Codable, Equatable {
        var entries: [String: InstalledAppState] = [:]
    }

    private let processRunner: ProcessRunner
    private let configuration: IsolatedSimulatorHostConfiguration
    private let fileManager: FileManager

    public init(
        processRunner: ProcessRunner = ProcessRunner(),
        configuration: IsolatedSimulatorHostConfiguration = IsolatedSimulatorHostConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.configuration = configuration
        self.fileManager = fileManager
    }

    @discardableResult
    public func ensureDeviceSetExists() throws -> URL {
        let deviceSetURL = URL(fileURLWithPath: configuration.deviceSetPath, isDirectory: true)
        try fileManager.createDirectory(at: deviceSetURL, withIntermediateDirectories: true, attributes: nil)
        return deviceSetURL
    }

    public func preparePreviewSession(
        app: SimulatorPreviewApp,
        preferredDeviceName: String? = nil
    ) throws -> IsolatedSimulatorSession {
        let selectedDevice = try selectOrCreatePreferredIPhoneDevice(
            preferredName: preferredDeviceName ?? configuration.preferredDeviceName
        )
        _ = try? terminate(bundleId: app.bundleIdentifier, in: selectedDevice)
        let arch = Self.requiresRosetta(appURL: app.appBundleURL) ? "x86_64" : nil
        try boot(selectedDevice, arch: arch)
        try waitForBoot(selectedDevice)
        try ensureInstalledAppIsCurrent(appURL: app.appBundleURL, bundleID: app.bundleIdentifier, device: selectedDevice)
        try launchOrInstallIfNeeded(appURL: app.appBundleURL, bundleID: app.bundleIdentifier, device: selectedDevice)

        return IsolatedSimulatorSession(
            deviceSetPath: configuration.deviceSetPath,
            device: selectedDevice,
            bundleId: app.bundleIdentifier,
            appPath: app.appBundleURL.path
        )
    }

    public func prepareHomeScreenSession(preferredDeviceName: String? = nil) throws -> IsolatedSimulatorSession {
        let selectedDevice = try selectOrCreatePreferredIPhoneDevice(preferredName: preferredDeviceName ?? configuration.preferredDeviceName)
        _ = try? shutdown(selectedDevice)
        try boot(selectedDevice)
        try waitForBoot(selectedDevice)
        return IsolatedSimulatorSession(
            deviceSetPath: configuration.deviceSetPath,
            device: selectedDevice,
            bundleId: "",
            appPath: ""
        )
    }

    @discardableResult
    public func captureScreenshot(of session: IsolatedSimulatorSession, outputURL: URL) throws -> URL {
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw PreviewError.message("Preview screenshots must be saved as PNG files.")
        }

        let directoryURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }

        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.screenshotArguments(
                    deviceSetPath: session.deviceSetPath,
                    deviceUDID: session.device.udid,
                    outputURL: outputURL
                ),
                maxBytes: 2 * 1024 * 1024
            )
        )

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw CommandFailure(message: "Preview screenshot was not created.")
        }
        return outputURL
    }

    public func captureScreenshotData(of session: IsolatedSimulatorSession) throws -> Data {
        let result = try processRunner.runCapturingData(
            "xcrun",
            Self.screenshotStdoutArguments(
                deviceSetPath: session.deviceSetPath,
                deviceUDID: session.device.udid
            ),
            maxBytes: 16 * 1024 * 1024
        )

        guard result.exitCode == 0 else {
            throw CommandFailure(message: result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !result.stdout.isEmpty else {
            throw CommandFailure(message: "Preview screenshot data was empty.")
        }
        return result.stdout
    }

    public func openSimulatorWindow(for session: IsolatedSimulatorSession) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "open",
                Self.openSimulatorArguments(deviceSetPath: session.deviceSetPath, deviceUDID: session.device.udid)
            )
        )
    }

    public func uninstallApp(bundleId: String) throws {
        let device = try selectOrCreatePreferredIPhoneDevice(preferredName: configuration.preferredDeviceName)
        _ = try? terminate(bundleId: bundleId, in: device)
        _ = try? uninstall(bundleId: bundleId, in: device)
        try? removeInstalledAppState(bundleID: bundleId, deviceUDID: device.udid)
    }

    func selectOrCreatePreferredIPhoneDevice(preferredName: String?) throws -> SelectedSimulator {
        _ = try ensureDeviceSetExists()
        let devicesOutput = try processRunner.capture(
            "xcrun",
            SimulatorSupport.simctlArguments(
                command: ["list", "devices", "available", "--json"],
                deviceSetPath: configuration.deviceSetPath
            ),
            maxBytes: 8 * 1024 * 1024
        )
        let devices = try SimulatorSupport.decodeAvailableIOSDevices(from: devicesOutput)
        if let selected = SimulatorSupport.selectPreferredDevice(from: devices, preferredName: preferredName) {
            return selected
        }

        let deviceType = try preferredDeviceType(preferredName: preferredName)
        let runtime = try latestRuntime()
        let udid = try processRunner.capture(
            "xcrun",
            Self.createDeviceArguments(
                deviceSetPath: configuration.deviceSetPath,
                name: deviceType.name,
                deviceTypeIdentifier: deviceType.identifier,
                runtimeIdentifier: runtime.identifier
            ),
            maxBytes: 1024
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !udid.isEmpty else {
            throw CommandFailure(message: "simctl create did not return a device UDID.")
        }

        return SelectedSimulator(
            name: deviceType.name,
            udid: udid,
            runtime: runtime.identifier,
            runtimeName: runtime.name
        )
    }

    func boot(_ device: SelectedSimulator, arch: String? = nil) throws {
        _ = try? processRunner.runCapturing(
            "xcrun",
            Self.bootArguments(
                deviceSetPath: configuration.deviceSetPath,
                deviceUDID: device.udid,
                arch: arch
            )
        )
    }

    func waitForBoot(_ device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.bootStatusArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid)
            )
        )
    }

    func install(_ appURL: URL, into device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.installArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid, appPath: appURL.path)
            )
        )
    }

    func launch(bundleId: String, in device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.launchArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid, bundleID: bundleId)
            )
        )
    }

    func terminate(bundleId: String, in device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.terminateArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid, bundleID: bundleId)
            )
        )
    }

    func uninstall(bundleId: String, in device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.uninstallArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid, bundleID: bundleId)
            )
        )
    }

    func shutdown(_ device: SelectedSimulator) throws {
        try requireSuccess(
            processRunner.runCapturing(
                "xcrun",
                Self.shutdownArguments(deviceSetPath: configuration.deviceSetPath, deviceUDID: device.udid)
            )
        )
    }

    private func preferredDeviceType(preferredName: String?) throws -> SimctlDeviceType {
        let output = try processRunner.capture(
            "xcrun",
            SimulatorSupport.simctlArguments(command: ["list", "devicetypes", "--json"]),
            maxBytes: 2 * 1024 * 1024
        )
        let deviceTypes = try SimulatorSupport.decodeDeviceTypes(from: output)
        guard let selected = SimulatorSupport.selectPreferredDeviceType(from: deviceTypes, preferredName: preferredName) else {
            throw CommandFailure(message: "No available iPhone Simulator device type found.")
        }
        return selected
    }

    private func latestRuntime() throws -> SimctlRuntime {
        let output = try processRunner.capture(
            "xcrun",
            SimulatorSupport.simctlArguments(command: ["list", "runtimes", "available", "--json"]),
            maxBytes: 4 * 1024 * 1024
        )
        let runtimes = try SimulatorSupport.decodeAvailableIOSRuntimes(from: output)
        guard let runtime = SimulatorSupport.selectLatestRuntime(from: runtimes) else {
            throw CommandFailure(message: "No available iOS Simulator runtime found.")
        }
        return runtime
    }

    static func createDeviceArguments(
        deviceSetPath: String,
        name: String,
        deviceTypeIdentifier: String,
        runtimeIdentifier: String
    ) -> [String] {
        SimulatorSupport.simctlArguments(
            command: ["create", name, deviceTypeIdentifier, runtimeIdentifier],
            deviceSetPath: deviceSetPath
        )
    }

    static func bootArguments(
        deviceSetPath: String,
        deviceUDID: String,
        arch: String? = nil
    ) -> [String] {
        var command = ["boot"]
        if let arch {
            command += ["--arch=\(arch)"]
        }
        command.append(deviceUDID)
        return SimulatorSupport.simctlArguments(
            command: command,
            deviceSetPath: deviceSetPath
        )
    }

    static func bootStatusArguments(deviceSetPath: String, deviceUDID: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["bootstatus", deviceUDID, "-b"], deviceSetPath: deviceSetPath)
    }

    static func installArguments(deviceSetPath: String, deviceUDID: String, appPath: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["install", deviceUDID, appPath], deviceSetPath: deviceSetPath)
    }

    static func launchArguments(deviceSetPath: String, deviceUDID: String, bundleID: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["launch", deviceUDID, bundleID], deviceSetPath: deviceSetPath)
    }

    static func terminateArguments(deviceSetPath: String, deviceUDID: String, bundleID: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["terminate", deviceUDID, bundleID], deviceSetPath: deviceSetPath)
    }

    static func uninstallArguments(deviceSetPath: String, deviceUDID: String, bundleID: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["uninstall", deviceUDID, bundleID], deviceSetPath: deviceSetPath)
    }

    static func screenshotArguments(deviceSetPath: String, deviceUDID: String, outputURL: URL) -> [String] {
        SimulatorSupport.simctlArguments(
            command: ["io", deviceUDID, "screenshot", "--type=png", outputURL.path],
            deviceSetPath: deviceSetPath
        )
    }

    static func screenshotStdoutArguments(deviceSetPath: String, deviceUDID: String) -> [String] {
        SimulatorSupport.simctlArguments(
            command: ["io", deviceUDID, "screenshot", "--type=png", "-"],
            deviceSetPath: deviceSetPath
        )
    }

    static func openSimulatorArguments(deviceSetPath: String, deviceUDID: String) -> [String] {
        ["-a", "Simulator", "--args", "-CurrentDeviceUDID", deviceUDID, "-DeviceSetPath", deviceSetPath]
    }

    static func shutdownArguments(deviceSetPath: String, deviceUDID: String) -> [String] {
        SimulatorSupport.simctlArguments(command: ["shutdown", deviceUDID], deviceSetPath: deviceSetPath)
    }

    static func shouldInstallApp(
        appPath: String,
        appFingerprint: String,
        cachedState: InstalledAppState?
    ) -> Bool {
        guard let cachedState else {
            return true
        }

        return cachedState.appPath != appPath || cachedState.appFingerprint != appFingerprint
    }

    private func ensureInstalledAppIsCurrent(
        appURL: URL,
        bundleID: String,
        device: SelectedSimulator
    ) throws {
        let fingerprint = try appFingerprint(for: appURL)
        let cachedState = try loadInstalledAppState(bundleID: bundleID, deviceUDID: device.udid)
        guard Self.shouldInstallApp(
            appPath: appURL.path,
            appFingerprint: fingerprint,
            cachedState: cachedState
        ) else {
            return
        }

        try install(appURL, into: device)
        try saveInstalledAppState(
            InstalledAppState(
                deviceUDID: device.udid,
                bundleID: bundleID,
                appPath: appURL.path,
                appFingerprint: fingerprint
            )
        )
    }

    private func launchOrInstallIfNeeded(
        appURL: URL,
        bundleID: String,
        device: SelectedSimulator
    ) throws {
        do {
            try launch(bundleId: bundleID, in: device)
        } catch {
            try install(appURL, into: device)
            try saveInstalledAppState(
                InstalledAppState(
                    deviceUDID: device.udid,
                    bundleID: bundleID,
                    appPath: appURL.path,
                    appFingerprint: try appFingerprint(for: appURL)
                )
            )
            try launch(bundleId: bundleID, in: device)
        }
    }

    private func installStateFileURL() throws -> URL {
        try ensureDeviceSetExists()
            .appendingPathComponent("preview-install-state.json")
    }

    private func installStateKey(bundleID: String, deviceUDID: String) -> String {
        "\(deviceUDID)|\(bundleID)"
    }

    private func loadInstalledAppState(bundleID: String, deviceUDID: String) throws -> InstalledAppState? {
        let stateFileURL = try installStateFileURL()
        guard fileManager.fileExists(atPath: stateFileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: stateFileURL)
        let decoder = JSONDecoder()
        let envelope = try decoder.decode(InstalledAppStateEnvelope.self, from: data)
        return envelope.entries[installStateKey(bundleID: bundleID, deviceUDID: deviceUDID)]
    }

    private func saveInstalledAppState(_ state: InstalledAppState) throws {
        let stateFileURL = try installStateFileURL()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var envelope: InstalledAppStateEnvelope
        if fileManager.fileExists(atPath: stateFileURL.path) {
            let data = try Data(contentsOf: stateFileURL)
            envelope = (try? decoder.decode(InstalledAppStateEnvelope.self, from: data)) ?? InstalledAppStateEnvelope()
        } else {
            envelope = InstalledAppStateEnvelope()
        }

        envelope.entries[installStateKey(bundleID: state.bundleID, deviceUDID: state.deviceUDID)] = state
        let data = try encoder.encode(envelope)
        try data.write(to: stateFileURL, options: .atomic)
    }

    private func removeInstalledAppState(bundleID: String, deviceUDID: String) throws {
        let stateFileURL = try installStateFileURL()
        guard fileManager.fileExists(atPath: stateFileURL.path) else { return }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try Data(contentsOf: stateFileURL)
        var envelope = (try? decoder.decode(InstalledAppStateEnvelope.self, from: data)) ?? InstalledAppStateEnvelope()
        envelope.entries.removeValue(forKey: installStateKey(bundleID: bundleID, deviceUDID: deviceUDID))
        let updatedData = try encoder.encode(envelope)
        try updatedData.write(to: stateFileURL, options: .atomic)
    }

    private func appFingerprint(for appURL: URL) throws -> String {
        guard let enumerator = fileManager.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CommandFailure(message: "Built app could not be inspected: \(appURL.path)")
        }

        var lines: [String] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else {
                continue
            }

            let relativePath = String(fileURL.path.dropFirst(appURL.path.count + 1))
            let size = values.fileSize ?? 0
            let modifiedAt = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            lines.append("\(relativePath)|\(size)|\(modifiedAt)")
        }

        lines.sort()
        let data = Data(lines.joined(separator: "\n").utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func requiresRosetta(appURL: URL) -> Bool {
        let execName = appURL.deletingPathExtension().lastPathComponent
        let execURL = appURL.appendingPathComponent(execName)
        guard FileManager.default.fileExists(atPath: execURL.path) else {
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/file")
        process.arguments = [execURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let hasArm64 = output.contains("arm64")
            let hasX86 = output.contains("x86_64")
            return hasX86 && !hasArm64
        } catch {
            return false
        }
    }

    private func requireSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw CommandFailure(message: result.combinedOutput)
        }
    }
}
