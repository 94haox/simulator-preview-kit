import AppKit
import WebKit

@MainActor
enum EmbeddedPreviewWindow {
    static func run(pageURL: URL, title: String) {
        let application = NSApplication.shared
        let delegate = AppDelegate(pageURL: pageURL, title: title)

        application.setActivationPolicy(.regular)
        application.delegate = delegate
        application.activate(ignoringOtherApps: true)
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let pageURL: URL
    private let title: String
    private var window: NSWindow?

    init(pageURL: URL, title: String) {
        self.pageURL = pageURL
        self.title = title
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.load(URLRequest(url: pageURL))

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 430, height: 930))
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 930),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = title
        window.contentView = contentView
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
