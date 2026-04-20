import Foundation

public struct SelectedSimulator: Codable, Equatable, Sendable {
    public let name: String
    public let udid: String
    public let runtime: String
    public let runtimeName: String

    public init(name: String, udid: String, runtime: String, runtimeName: String) {
        self.name = name
        self.udid = udid
        self.runtime = runtime
        self.runtimeName = runtimeName
    }
}

internal struct SimctlDevicesPayload: Decodable {
    let devices: [String: [SimulatorDevice]]
}

internal struct SimulatorDevice: Decodable {
    let name: String
    let udid: String
    let isAvailable: Bool?
}

internal struct SimctlDeviceTypesPayload: Decodable {
    let devicetypes: [SimctlDeviceType]
}

internal struct SimctlDeviceType: Decodable {
    let name: String
    let identifier: String
}

internal struct SimctlRuntimesPayload: Decodable {
    let runtimes: [SimctlRuntime]
}

internal struct SimctlRuntime: Decodable {
    let identifier: String
    let name: String
    let isAvailable: Bool?
    let availabilityError: String?
}

internal enum SimulatorSupport {
    static func simctlArguments(command: [String], deviceSetPath: String? = nil) -> [String] {
        var args = ["simctl"]
        if let deviceSetPath {
            args += ["--set", deviceSetPath]
        }
        args += command
        return args
    }

    static func decodeAvailableIOSDevices(from output: String) throws -> [SelectedSimulator] {
        let payload = try JSONDecoder().decode(SimctlDevicesPayload.self, from: Data(output.utf8))
        let runtimes = payload.devices.keys
            .filter { $0.contains("iOS") }
            .sorted { compareRuntime($0, $1) > 0 }

        return runtimes.flatMap { runtime in
            (payload.devices[runtime] ?? [])
                .filter { $0.isAvailable ?? true }
                .map { device in
                    SelectedSimulator(
                        name: device.name,
                        udid: device.udid,
                        runtime: runtime,
                        runtimeName: displayRuntimeName(runtime)
                    )
                }
        }
    }

    static func decodeDeviceTypes(from output: String) throws -> [SimctlDeviceType] {
        let payload = try JSONDecoder().decode(SimctlDeviceTypesPayload.self, from: Data(output.utf8))
        return payload.devicetypes
    }

    static func decodeAvailableIOSRuntimes(from output: String) throws -> [SimctlRuntime] {
        let payload = try JSONDecoder().decode(SimctlRuntimesPayload.self, from: Data(output.utf8))
        return payload.runtimes
            .filter { $0.identifier.contains("iOS") }
            .filter { ($0.isAvailable ?? true) && $0.availabilityError == nil }
            .sorted { compareRuntime($0.identifier, $1.identifier) > 0 }
    }

    static func selectPreferredDevice(from devices: [SelectedSimulator], preferredName: String?) -> SelectedSimulator? {
        let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exact = preferred.isEmpty ? nil : devices.first { $0.name == preferred }
        let partial = preferred.isEmpty ? nil : devices.first { $0.name.contains(preferred) }
        let defaults = [
            "iPhone 17 Pro Max",
            "iPhone 17 Pro",
            "iPhone 17",
            "iPhone 16",
        ]

        let fallback = defaults.lazy.compactMap { name in
            devices.first { $0.name == name }
        }.first ?? devices.first { $0.name.contains("iPhone") }

        return exact ?? partial ?? fallback
    }

    static func selectPreferredDeviceType(from deviceTypes: [SimctlDeviceType], preferredName: String?) -> SimctlDeviceType? {
        let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let exact = preferred.isEmpty ? nil : deviceTypes.first { $0.name == preferred }
        let partial = preferred.isEmpty ? nil : deviceTypes.first { $0.name.contains(preferred) }
        let defaults = [
            "iPhone 17 Pro Max",
            "iPhone 17 Pro",
            "iPhone 17",
            "iPhone 16",
        ]

        let fallback = defaults.lazy.compactMap { name in
            deviceTypes.first { $0.name == name }
        }.first ?? deviceTypes.first { $0.name.contains("iPhone") }

        return exact ?? partial ?? fallback
    }

    static func selectLatestRuntime(from runtimes: [SimctlRuntime]) -> SimctlRuntime? {
        runtimes.max { compareRuntime($0.identifier, $1.identifier) < 0 }
    }

    static func compareRuntime(_ left: String, _ right: String) -> Int {
        let a = parseRuntimeVersion(left)
        let b = parseRuntimeVersion(right)
        for index in 0..<max(a.count, b.count) {
            let delta = (index < a.count ? a[index] : 0) - (index < b.count ? b[index] : 0)
            if delta != 0 {
                return delta
            }
        }
        return 0
    }

    static func parseRuntimeVersion(_ runtime: String) -> [Int] {
        guard let range = runtime.range(of: #"iOS-([0-9-]+)"#, options: .regularExpression) else {
            return [0]
        }
        return runtime[range]
            .replacingOccurrences(of: "iOS-", with: "")
            .split(separator: "-")
            .map { Int($0) ?? 0 }
    }

    static func displayRuntimeName(_ runtime: String) -> String {
        runtime
            .split(separator: ".")
            .last
            .map(String.init)?
            .replacingOccurrences(of: "iOS-", with: "iOS ")
            .replacingOccurrences(of: "-", with: ".") ?? runtime
    }
}
