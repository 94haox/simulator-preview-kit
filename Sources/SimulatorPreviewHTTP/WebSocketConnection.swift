import CommonCrypto
import Foundation
import Network

final class WebSocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    var onReceiveText: (@Sendable (String) -> Void)?
    var onReceiveBinary: (@Sendable (Data) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

    private var isClosed = false

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    static func completeHandshake(
        request: SimpleHTTPRequest,
        connection: NWConnection,
        queue: DispatchQueue
    ) -> WebSocketConnection? {
        guard let clientKey = request.headers["sec-websocket-key"], !clientKey.isEmpty else {
            return nil
        }

        let accept = acceptValue(for: clientKey)
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "", ""
        ].joined(separator: "\r\n")

        let ws = WebSocketConnection(connection: connection, queue: queue)

        connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
            if error != nil {
                ws.handleDisconnect()
            } else {
                ws.readNextFrame()
            }
        })

        return ws
    }

    func sendBinary(_ data: Data) {
        guard !isClosed else { return }
        let frame = encodeFrame(opcode: 0x02, payload: data)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.handleDisconnect()
            }
        })
    }

    func sendText(_ string: String) {
        guard !isClosed else { return }
        let frame = encodeFrame(opcode: 0x01, payload: Data(string.utf8))
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.handleDisconnect()
            }
        })
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let frame = encodeFrame(opcode: 0x08, payload: Data())
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    // MARK: - Frame reading

    private func readNextFrame() {
        // Read at least 2 bytes (minimum WebSocket frame header)
        connection.receive(minimumIncompleteLength: 2, maximumLength: 16 * 1024 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }

            if isComplete || error != nil {
                self.handleDisconnect()
                return
            }

            guard let data, data.count >= 2 else {
                self.handleDisconnect()
                return
            }

            self.parseFrame(data)
        }
    }

    private func parseFrame(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else {
            handleDisconnect()
            return
        }

        let opcode = bytes[0] & 0x0F
        let isMasked = (bytes[1] & 0x80) != 0
        var payloadLength = UInt64(bytes[1] & 0x7F)
        var offset = 2

        if payloadLength == 126 {
            guard bytes.count >= offset + 2 else {
                handleDisconnect()
                return
            }
            payloadLength = UInt64(bytes[offset]) << 8 | UInt64(bytes[offset + 1])
            offset += 2
        } else if payloadLength == 127 {
            guard bytes.count >= offset + 8 else {
                handleDisconnect()
                return
            }
            payloadLength = 0
            for i in 0..<8 {
                payloadLength = (payloadLength << 8) | UInt64(bytes[offset + i])
            }
            offset += 8
        }

        var maskKey: [UInt8] = []
        if isMasked {
            guard bytes.count >= offset + 4 else {
                handleDisconnect()
                return
            }
            maskKey = Array(bytes[offset..<(offset + 4)])
            offset += 4
        }

        let expectedEnd = offset + Int(payloadLength)
        guard bytes.count >= expectedEnd else {
            // Need more data — read the remainder
            let remaining = expectedEnd - bytes.count
            connection.receive(minimumIncompleteLength: remaining, maximumLength: remaining + 1024) { [weak self] moreData, _, isComplete, error in
                guard let self, !self.isClosed else { return }
                if isComplete || error != nil || moreData == nil {
                    self.handleDisconnect()
                    return
                }
                var combined = data
                combined.append(moreData!)
                self.parseFrame(combined)
            }
            return
        }

        var payload = Data(bytes[offset..<expectedEnd])
        if isMasked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        switch opcode {
        case 0x01: // text
            if let text = String(data: payload, encoding: .utf8) {
                onReceiveText?(text)
            }
        case 0x02: // binary
            onReceiveBinary?(payload)
        case 0x08: // close
            close()
            return
        case 0x09: // ping → send pong
            let pong = encodeFrame(opcode: 0x0A, payload: payload)
            connection.send(content: pong, completion: .contentProcessed { _ in })
        case 0x0A: // pong — ignore
            break
        default:
            break
        }

        readNextFrame()
    }

    // MARK: - Frame writing

    private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()

        // FIN + opcode
        frame.append(0x80 | opcode)

        // Payload length (server frames are NOT masked)
        let length = payload.count
        if length <= 125 {
            frame.append(UInt8(length))
        } else if length <= 65535 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    // MARK: - Lifecycle

    private func handleDisconnect() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onDisconnect?()
    }

    // MARK: - WebSocket accept key (RFC 6455)

    private static let webSocketMagicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private static func acceptValue(for clientKey: String) -> String {
        let combined = clientKey + webSocketMagicGUID
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = Array(combined.utf8)
        CC_SHA1(data, CC_LONG(data.count), &hash)
        return Data(hash).base64EncodedString()
    }
}
