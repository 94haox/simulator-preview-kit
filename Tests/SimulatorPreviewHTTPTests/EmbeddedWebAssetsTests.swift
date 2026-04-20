import XCTest
@testable import SimulatorPreviewHTTP

final class EmbeddedWebAssetsTests: XCTestCase {
    func testStylesCSSUsesWhitePageBackground() {
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains("--bg: #fff;"))
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains("color-scheme: light;"))
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains("background: var(--panel);"))
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains("background: #f8fafc;"))
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains(".media-stage {"))
        XCTAssertTrue(EmbeddedWebAssets.stylesCSS.contains("background: #fff;"))
    }

    func testAppJSUsesWebSocketWithImageFallback() {
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("function connectWebSocket()"))
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("new WebSocket(wsURL)"))
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("ws.send(json)"))
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("function startImageFallback(reason"))
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("function refreshFrame()"))
        XCTAssertTrue(EmbeddedWebAssets.appJS.contains("function sendEvent(payload)"))
    }

    func testIndexHTMLIncludesBootstrapValues() {
        let html = EmbeddedWebAssets.indexHTML(deviceName: "iPhone 17 Pro", frameIntervalMs: 33, initialMode: "websocket")
        XCTAssertTrue(html.contains("iPhone 17 Pro"))
        XCTAssertTrue(html.contains("frameIntervalMs: 33"))
        XCTAssertTrue(html.contains("initialMode: \"websocket\""))
        XCTAssertTrue(html.contains("/app.js"))
        XCTAssertTrue(html.contains("/styles.css"))
        XCTAssertTrue(html.contains("id=\"frame\""))
        XCTAssertTrue(html.contains("id=\"mode\""))
        XCTAssertTrue(html.contains("Mode: websocket"))
    }
}
