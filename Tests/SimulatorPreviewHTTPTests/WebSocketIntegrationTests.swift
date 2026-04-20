import XCTest
import Foundation
import Network
@testable import SimulatorPreviewHTTP
@testable import SimulatorPreviewBridge

final class WebSocketIntegrationTests: XCTestCase {

    // MARK: - Test that the HTTP server upgrades a WebSocket request

    func testWebSocketUpgradeHandshake() async throws {
        let upgradeExpectation = expectation(description: "WebSocket upgrade handler called")

        let server = SimpleHTTPServer(
            requestedPort: 0,
            onWebSocketUpgrade: { request, connection in
                XCTAssertEqual(request.headers["upgrade"]?.lowercased(), "websocket")
                XCTAssertNotNil(request.headers["sec-websocket-key"])
                // Complete the handshake
                if let ws = WebSocketConnection.completeHandshake(
                    request: request,
                    connection: connection,
                    queue: DispatchQueue(label: "test-ws")
                ) {
                    // Connection established successfully
                    upgradeExpectation.fulfill()
                    ws.close()
                } else {
                    XCTFail("Handshake failed")
                    connection.cancel()
                }
            }
        ) { _ in
            SimpleHTTPResponse(statusCode: 200)
        }

        let port = try await server.start()

        // Connect with a raw TCP client and send a WebSocket upgrade request
        let clientConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let clientQueue = DispatchQueue(label: "test-client")

        let connected = expectation(description: "Client connected")
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state {
                connected.fulfill()
            }
        }
        clientConnection.start(queue: clientQueue)
        await fulfillment(of: [connected], timeout: 3)

        // Send HTTP upgrade request
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgradeRequest = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "", ""
        ].joined(separator: "\r\n")

        clientConnection.send(
            content: Data(upgradeRequest.utf8),
            completion: .contentProcessed { error in
                XCTAssertNil(error)
            }
        )

        await fulfillment(of: [upgradeExpectation], timeout: 5)

        clientConnection.cancel()
        server.stop()
    }

    // MARK: - Test that regular HTTP still works alongside WebSocket

    func testRegularHTTPStillWorks() async throws {
        let server = SimpleHTTPServer(
            requestedPort: 0,
            onWebSocketUpgrade: { _, connection in
                connection.cancel()
            }
        ) { request in
            if request.path == "/health" {
                return .text("ok")
            }
            return .text("Not Found", statusCode: 404)
        }

        let port = try await server.start()

        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let httpResponse = response as! HTTPURLResponse
        XCTAssertEqual(httpResponse.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")

        server.stop()
    }

    // MARK: - Test WebSocket binary frame push from WebSocketFramePusher

    func testFramePusherSendsBinaryFrames() async throws {
        // Create a mock renderable frame (encoded PNG image)
        let mockPNGData = createMinimalPNG()
        let mockFrame = PreviewRenderableFrame(
            backing: .encodedImage(data: mockPNGData, contentType: "image/png"),
            pixelSize: CGSize(width: 2, height: 2)
        )

        let receivedFrame = expectation(description: "Received binary frame via WebSocket")

        let pusher = WebSocketFramePusher(
            frameProvider: { mockFrame },
            interactionHandler: { _ in },
            frameIntervalNanoseconds: 50_000_000, // 50ms for fast test
            jpegQuality: 0.5
        )

        let server = SimpleHTTPServer(
            requestedPort: 0,
            onWebSocketUpgrade: { request, connection in
                let wsQueue = DispatchQueue(label: "test-ws-push")
                guard let ws = WebSocketConnection.completeHandshake(
                    request: request,
                    connection: connection,
                    queue: wsQueue
                ) else {
                    connection.cancel()
                    return
                }
                pusher.addConnection(ws)
            }
        ) { _ in
            SimpleHTTPResponse(statusCode: 404)
        }

        let port = try await server.start()
        pusher.start()

        // Connect a raw TCP client
        let clientConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let clientQueue = DispatchQueue(label: "test-ws-client")

        let connected = expectation(description: "Client connected")
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state {
                connected.fulfill()
            }
        }
        clientConnection.start(queue: clientQueue)
        await fulfillment(of: [connected], timeout: 3)

        // Send upgrade
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgradeRequest = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "", ""
        ].joined(separator: "\r\n")

        let upgradeSent = expectation(description: "Upgrade sent")
        clientConnection.send(content: Data(upgradeRequest.utf8), completion: .contentProcessed { _ in
            upgradeSent.fulfill()
        })
        await fulfillment(of: [upgradeSent], timeout: 3)

        // Read the 101 response + at least one binary frame
        // We'll read in a loop looking for a binary WebSocket frame (opcode 0x82 = FIN + binary)
        readUntilBinaryFrame(on: clientConnection, queue: clientQueue) { data in
            // We should receive JPEG data
            XCTAssertGreaterThan(data.count, 0)
            // JPEG starts with FF D8
            if data.count >= 2 {
                XCTAssertEqual(data[0], 0xFF)
                XCTAssertEqual(data[1], 0xD8)
            }
            receivedFrame.fulfill()
        }

        await fulfillment(of: [receivedFrame], timeout: 10)

        pusher.stop()
        clientConnection.cancel()
        server.stop()
    }

    // MARK: - Test input events over WebSocket

    func testInputEventsOverWebSocket() async throws {
        let receivedEvent = expectation(description: "Received interaction event")
        var capturedEvent: PreviewInteractionEvent?

        let pusher = WebSocketFramePusher(
            frameProvider: { nil }, // no frames needed for this test
            interactionHandler: { event in
                capturedEvent = event
                receivedEvent.fulfill()
            },
            frameIntervalNanoseconds: 100_000_000
        )

        let server = SimpleHTTPServer(
            requestedPort: 0,
            onWebSocketUpgrade: { request, connection in
                let wsQueue = DispatchQueue(label: "test-ws-input")
                guard let ws = WebSocketConnection.completeHandshake(
                    request: request,
                    connection: connection,
                    queue: wsQueue
                ) else {
                    connection.cancel()
                    return
                }
                pusher.addConnection(ws)
            }
        ) { _ in
            SimpleHTTPResponse(statusCode: 404)
        }

        let port = try await server.start()
        pusher.start()

        // Connect a raw TCP client
        let clientConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        let clientQueue = DispatchQueue(label: "test-ws-input-client")

        let connected = expectation(description: "Connected")
        clientConnection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        clientConnection.start(queue: clientQueue)
        await fulfillment(of: [connected], timeout: 3)

        // Send upgrade
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgradeRequest = [
            "GET /ws HTTP/1.1",
            "Host: 127.0.0.1:\(port)",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "", ""
        ].joined(separator: "\r\n")

        let upgradeSent = expectation(description: "Upgrade sent")
        clientConnection.send(content: Data(upgradeRequest.utf8), completion: .contentProcessed { _ in
            upgradeSent.fulfill()
        })
        await fulfillment(of: [upgradeSent], timeout: 3)

        // Wait a bit for handshake to complete, then read the 101 response
        try await Task.sleep(nanoseconds: 500_000_000)

        // Drain the 101 response
        let drained = expectation(description: "Drained 101")
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
            drained.fulfill()
        }
        await fulfillment(of: [drained], timeout: 3)

        // Send a masked text frame with a touchDown event
        let eventJSON = #"{"kind":"touchDown","x":0.5,"y":0.5}"#
        let maskedFrame = createMaskedTextFrame(eventJSON)
        let frameSent = expectation(description: "Frame sent")
        clientConnection.send(content: maskedFrame, completion: .contentProcessed { _ in
            frameSent.fulfill()
        })
        await fulfillment(of: [frameSent], timeout: 3)

        await fulfillment(of: [receivedEvent], timeout: 5)

        XCTAssertEqual(capturedEvent?.kind, .touchDown)
        XCTAssertEqual(capturedEvent?.x, 0.5)
        XCTAssertEqual(capturedEvent?.y, 0.5)

        pusher.stop()
        clientConnection.cancel()
        server.stop()
    }

    // MARK: - Helpers

    private func createMinimalPNG() -> Data {
        // A minimal valid 2x2 white PNG
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAADklEQVQI12P4z8BQDwAEgAF/QualzQAAAABJRU5ErkJggg=="
        return Data(base64Encoded: base64) ?? Data()
    }

    private func createMaskedTextFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        let maskKey: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]

        var frame = Data()
        // FIN + text opcode
        frame.append(0x81)

        // MASK bit + length
        let length = payload.count
        if length <= 125 {
            frame.append(UInt8(length) | 0x80)
        } else if length <= 65535 {
            frame.append(126 | 0x80)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127 | 0x80)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        // Masking key
        frame.append(contentsOf: maskKey)

        // Masked payload
        var masked = payload
        for i in 0..<masked.count {
            masked[i] ^= maskKey[i % 4]
        }
        frame.append(masked)

        return frame
    }

    private func readUntilBinaryFrame(
        on connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping (Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
            guard let data, !data.isEmpty else {
                if !isComplete && error == nil {
                    self.readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
                }
                return
            }

            // Look for a WebSocket binary frame (first byte 0x82 = FIN + binary opcode)
            let bytes = [UInt8](data)

            // Skip past the HTTP 101 response if present
            if let httpEnd = data.range(of: Data("\r\n\r\n".utf8)) {
                let remaining = Data(data[httpEnd.upperBound...])
                if remaining.isEmpty {
                    // Keep reading for the actual WS frame
                    self.readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
                    return
                }
                // Parse the WS frame from remaining
                self.parseBinaryFrame(from: remaining, on: connection, queue: queue, handler: handler)
                return
            }

            // Try parsing as WS frame directly
            if bytes.count >= 2 && (bytes[0] & 0x0F) == 0x02 {
                self.parseBinaryFrame(from: data, on: connection, queue: queue, handler: handler)
                return
            }

            // Not what we're looking for, keep reading
            self.readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
        }
    }

    private func parseBinaryFrame(
        from data: Data,
        on connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping (Data) -> Void
    ) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
            return
        }

        let opcode = bytes[0] & 0x0F
        guard opcode == 0x02 else {
            // Not a binary frame, keep reading
            readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
            return
        }

        var payloadLength = Int(bytes[1] & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard bytes.count >= 4 else {
                readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
                return
            }
            payloadLength = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if payloadLength == 127 {
            guard bytes.count >= 10 else {
                readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
                return
            }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = (payloadLength << 8) | Int(bytes[offset + i])
            }
            offset = 10
        }

        let expectedEnd = offset + payloadLength
        if bytes.count >= expectedEnd {
            let payload = Data(bytes[offset..<expectedEnd])
            handler(payload)
        } else {
            // Need more data
            readUntilBinaryFrame(on: connection, queue: queue, handler: handler)
        }
    }
}
