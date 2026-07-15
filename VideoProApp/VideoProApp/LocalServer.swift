import Foundation
import Network

/// A tiny loopback-only HTTP/1.1 server built on Network.framework — no external
/// dependencies. It understands just enough HTTP to accept JSON batches from the
/// browser extension:
///
///   GET  /health   -> {"ok":true,"name":"VideoPro"}
///   POST /videos   -> {"ok":true,"count":N}   (body: IncomingBatch JSON)
///   OPTIONS *      -> 204 (CORS preflight)
///
/// All responses carry permissive CORS headers so a Chrome extension service
/// worker can reach it.
final class LocalServer {
    let port: UInt16
    /// Called (on an arbitrary queue) whenever a valid batch arrives.
    var onBatch: (@Sendable ([VideoMeta]) -> Void)?
    /// Called on listener state changes with a human-readable status.
    var onStatus: (@Sendable (Bool, String) -> Void)?

    private var listener: NWListener?
    // Concurrent so a slow/half-open connection can never head-of-line block the
    // listener or other connections.
    private let queue = DispatchQueue(label: "com.videopro.server", attributes: .concurrent)

    init(port: UInt16) { self.port = port }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStatus?(true, "Listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let err):
                self?.onStatus?(false, "Failed: \(err.localizedDescription)")
            case .cancelled:
                self?.onStatus?(false, "Stopped")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        // Loopback-only: drop any connection that isn't from 127.0.0.1 / ::1.
        if case let .hostPort(host, _) = conn.endpoint, !Self.isLoopback(host) {
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        // Safety net: never let a connection linger (e.g. a client that opens a
        // socket but never finishes its request). cancel() is idempotent.
        queue.asyncAfter(deadline: .now() + 15) { [weak conn] in conn?.cancel() }
        receive(conn, buffer: Data())
    }

    private static func isLoopback(_ host: NWEndpoint.Host) -> Bool {
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback
        case .name(let n, _): return n == "localhost"
        @unknown default: return false
        }
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let request = HTTPRequest(buf) {
                if request.isBodyComplete {
                    self.route(request, on: conn)
                } else {
                    self.receive(conn, buffer: buf)   // need the rest of the body
                }
            } else if error != nil || isComplete {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)       // headers not complete yet
            }
        }
    }

    private func route(_ req: HTTPRequest, on conn: NWConnection) {
        switch (req.method, req.path) {
        case ("OPTIONS", _):
            respond(conn, status: "204 No Content", json: nil)

        case ("GET", "/health"), ("GET", "/"):
            respond(conn, status: "200 OK", json: #"{"ok":true,"name":"VideoPro"}"#)

        case ("POST", "/videos"):
            guard let batch = try? JSONDecoder.videoPro.decode(IncomingBatch.self, from: req.body) else {
                respond(conn, status: "400 Bad Request", json: #"{"ok":false,"error":"bad json"}"#)
                return
            }
            let metas = VideoMapper.metas(from: batch)
            onBatch?(metas)
            respond(conn, status: "200 OK", json: #"{"ok":true,"count":\#(metas.count)}"#)

        default:
            respond(conn, status: "404 Not Found", json: #"{"ok":false,"error":"not found"}"#)
        }
    }

    private func respond(_ conn: NWConnection, status: String, json: String?) {
        let bodyData = json?.data(using: .utf8) ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Access-Control-Max-Age: 86400\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Minimal HTTP request parser: request line + headers + Content-Length body.
private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
    let isBodyComplete: Bool

    init?(_ data: Data) {
        // Locate end of headers.
        let sep = Data("\r\n\r\n".utf8)
        guard let range = data.firstRange(of: sep) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        self.method = String(parts[0]).uppercased()
        self.path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = range.upperBound
        let available = data.subdata(in: bodyStart..<data.endIndex)
        self.body = available
        self.isBodyComplete = available.count >= contentLength
    }
}

extension JSONDecoder {
    static let videoPro: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}
