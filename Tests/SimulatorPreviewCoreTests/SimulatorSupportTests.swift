import Foundation
import XCTest
@testable import SimulatorPreviewBridge
@testable import SimulatorPreviewCore

final class SimulatorSupportTests: XCTestCase {
    func testPreviewAppLoadsBundleIdentifierAndDisplayName() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Example.app", isDirectory: true)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleDisplayName": "Example Demo"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Info.plist"))

        let app = try SimulatorPreviewApp(appBundleURL: appURL)
        XCTAssertEqual(app.bundleIdentifier, "com.example.demo")
        XCTAssertEqual(app.displayName, "Example Demo")
    }

    func testPreviewAppRejectsMissingBundleIdentifier() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = root.appendingPathComponent("Broken.app", isDirectory: true)
        try fileManager.createDirectory(at: appURL, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleDisplayName": "Broken"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: appURL.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try SimulatorPreviewApp(appBundleURL: appURL))
    }

    func testInteractionEventDecoding() throws {
        let json = """
        {
          "kind": "keyDown",
          "key": "a",
          "code": "KeyA",
          "modifiers": {
            "shift": false,
            "control": false,
            "option": false,
            "command": false
          }
        }
        """

        let event = try JSONDecoder().decode(PreviewInteractionEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.kind, .keyDown)
        XCTAssertEqual(event.key, "a")
        XCTAssertEqual(event.code, "KeyA")
    }
}
