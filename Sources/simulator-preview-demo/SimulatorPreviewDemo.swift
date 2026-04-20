import Foundation
import SimulatorPreviewKit

@main
struct SimulatorPreviewDemo {
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            let session = LocalWebPreviewSession(
                configuration: LocalWebPreviewConfiguration(
                    preferredDeviceName: arguments.deviceName,
                    frameIntervalNanoseconds: arguments.frameIntervalMilliseconds * 1_000_000,
                    webServer: PreviewWebServerConfiguration(requestedPort: arguments.port)
                )
            )

            let app = try SimulatorPreviewApp(appBundleURL: URL(fileURLWithPath: arguments.appBundlePath))
            let pageURL = try await session.start(app: app)

            FileHandle.standardOutput.write(Data((pageURL.absoluteString + "\n").utf8))
            FileHandle.standardError.write(Data(("App: \(app.displayName) (\(app.bundleIdentifier))\n").utf8))
            FileHandle.standardError.write(Data("Press Ctrl+C to stop.\n".utf8))

            if arguments.openBrowser {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [pageURL.absoluteString]
                try? process.run()
            }

            if arguments.embedPreview {
                await MainActor.run {
                    EmbeddedPreviewWindow.run(
                        pageURL: pageURL,
                        title: "\(app.displayName) Preview"
                    )
                }
                await session.stop()
                return
            }

            while true {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        } catch {
            fputs("error: \(PreviewError.userMessage(for: error))\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct Arguments {
    let appBundlePath: String
    let port: UInt16
    let deviceName: String?
    let openBrowser: Bool
    let embedPreview: Bool
    let frameIntervalMilliseconds: UInt64

    static func parse(_ argv: [String]) throws -> Arguments {
        var appBundlePath: String?
        var port: UInt16 = 38888
        var deviceName: String?
        var openBrowser = false
        var embedPreview = false
        var frameIntervalMilliseconds: UInt64 = 120

        var iterator = argv.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--app":
                appBundlePath = iterator.next()
            case "--port":
                if let value = iterator.next(), let portValue = UInt16(value) {
                    port = portValue
                }
            case "--device":
                deviceName = iterator.next()
            case "--open":
                openBrowser = true
            case "--embed":
                embedPreview = true
            case "--frame-interval-ms":
                if let value = iterator.next(), let interval = UInt64(value) {
                    frameIntervalMilliseconds = interval
                }
            case "--help", "-h":
                throw PreviewError.message(usage)
            default:
                break
            }
        }

        guard let appBundlePath else {
            throw PreviewError.message(usage)
        }

        return Arguments(
            appBundlePath: appBundlePath,
            port: port,
            deviceName: deviceName,
            openBrowser: openBrowser,
            embedPreview: embedPreview,
            frameIntervalMilliseconds: frameIntervalMilliseconds
        )
    }

    private static let usage = """
    Usage:
      swift run simulator-preview-demo --app /path/to/MyApp.app [--port 38888] [--device "iPhone 17"] [--open] [--embed] [--frame-interval-ms 120]
    """
}
