import Foundation

public struct SimulatorPreviewApp: Equatable, Sendable {
    public let appBundleURL: URL
    public let bundleIdentifier: String
    public let displayName: String

    public init(appBundleURL: URL, bundleIdentifier: String? = nil, displayName: String? = nil) throws {
        let standardizedURL = appBundleURL.standardizedFileURL
        guard standardizedURL.pathExtension == "app" else {
            throw PreviewError.invalidAppBundle(standardizedURL.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PreviewError.invalidAppBundle(standardizedURL.path)
        }

        let infoPlistURL = standardizedURL.appendingPathComponent("Info.plist")
        let infoPlist = try Self.loadInfoPlist(from: infoPlistURL)
        let resolvedBundleIdentifier = bundleIdentifier
            ?? infoPlist["CFBundleIdentifier"] as? String
        guard let resolvedBundleIdentifier, !resolvedBundleIdentifier.isEmpty else {
            throw PreviewError.missingBundleIdentifier(standardizedURL.path)
        }

        let resolvedDisplayName = displayName
            ?? infoPlist["CFBundleDisplayName"] as? String
            ?? infoPlist["CFBundleName"] as? String
            ?? standardizedURL.deletingPathExtension().lastPathComponent

        self.appBundleURL = standardizedURL
        self.bundleIdentifier = resolvedBundleIdentifier
        self.displayName = resolvedDisplayName
    }

    private static func loadInfoPlist(from url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else {
            return [:]
        }
        return dictionary
    }
}
