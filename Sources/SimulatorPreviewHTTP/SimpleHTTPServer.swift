import Foundation
import Network
import SimulatorPreviewCore

struct SimpleHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct SimpleHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    static func text(_ string: String, statusCode: Int = 200, contentType: String = "text/plain; charset=utf-8") -> Self {
        Self(
            statusCode: statusCode,
            headers: ["Content-Type": contentType],
            body: Data(string.utf8)
        )
    }

    static func json<T: Encodable>(_ value: T, statusCode: Int = 200) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: try encoder.encode(value)
        )
    }

    func serialized() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        var mergedHeaders = headers
        mergedHeaders["Content-Length"] = String(body.count)
        mergedHeaders["Connection"] = "close"
        for (key, value) in mergedHeaders.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 101: return "Switching Protocols"
        case 500: return "Internal Server Error"
        default: return "HTTP Response"
        }
    }
}

final class SimpleHTTPServer {
    private final class StartResolution: @unchecked Sendable {
        var isResolved = false
    }

    typealias Handler = @Sendable (SimpleHTTPRequest) async -> SimpleHTTPResponse
    typealias WebSocketUpgradeHandler = @Sendable (SimpleHTTPRequest, NWConnection) -> Void

    private enum ParseResult {
        case incomplete
        case request(SimpleHTTPRequest)
    }

    private let requestedPort: UInt16
    private let handler: Handler
    private let onWebSocketUpgrade: WebSocketUpgradeHandler?
    private let queue = DispatchQueue(label: "simulator-preview-kit.http-server")
    private var listener: NWListener?

    init(
        requestedPort: UInt16,
        onWebSocketUpgrade: WebSocketUpgradeHandler? = nil,
        handler: @escaping Handler
    ) {
        self.requestedPort = requestedPort
        self.onWebSocketUpgrade = onWebSocketUpgrade
        self.handler = handler
    }

    func start() async throws -> UInt16 {
        if listener != nil {
            throw PreviewError.message("HTTP server is already running.")
        }

        let port: NWEndpoint.Port = requestedPort == 0
            ? .any
            : NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            let resolution = StartResolution()
            listener.stateUpdateHandler = { state in
                guard !resolution.isResolved else { return }
                switch state {
                case .ready:
                    resolution.isResolved = true
                    continuation.resume(returning: listener.port?.rawValue ?? self.requestedPort)
                case .failed(let error):
                    resolution.isResolved = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data {
                buffer.append(data)
            }

            switch Self.parseRequest(from: buffer) {
            case .request(let request):
                if let onWebSocketUpgrade = self.onWebSocketUpgrade,
                   request.headers["upgrade"]?.lowercased() == "websocket",
                   request.headers["connection"]?.lowercased().contains("upgrade") == true {
                    onWebSocketUpgrade(request, connection)
                } else {
                    Task {
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: SimpleHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(from data: Data) -> ParseResult {
        let headerSeparator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: headerSeparator) else {
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .incomplete
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .incomplete
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .incomplete
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count >= bodyStart + bodyLength else {
            return .incomplete
        }

        let body = Data(data[bodyStart..<(bodyStart + bodyLength)])
        return .request(
            SimpleHTTPRequest(
                method: String(parts[0]),
                path: String(parts[1]),
                headers: headers,
                body: body
            )
        )
    }
}
