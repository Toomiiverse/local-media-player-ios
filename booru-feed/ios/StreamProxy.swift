#if canImport(UIKit)
import Foundation
import Network

/// Lets VLC stream feed videos from the PC without the PC loosening its security: VLC asks this app on 127.0.0.1
/// (random port, random per-run token), and the app forwards the request — Range included, for seeking — to the PC
/// with the paired session cookie, exactly like its other downloads. Nothing outside the phone can reach it.
@MainActor
final class StreamProxy {
    static let shared = StreamProxy()
    private var listener: NWListener?
    private var port: UInt16 = 0
    private let token = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
    private var routes = [String: URL](), order = [String]()
    private weak var api: FeedAPI?

    /// A 127.0.0.1 address VLC can play for a signed /api/media URL; nil if the proxy could not start.
    func localURL(for remote: URL, api: FeedAPI) async -> URL? {
        guard await start() else { return nil }
        self.api = api
        let id = (0..<2).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        routes[id] = remote; order.append(id)
        while order.count > 50 { routes[order.removeFirst()] = nil }
        return URL(string: "http://127.0.0.1:\(port)/\(token)/\(id)")
    }

    private func start() async -> Bool {
        if port != 0 { return true }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return false }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.serve(connection) } }
        let ready: Bool = await withCheckedContinuation { continuation in
            var answered = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if !answered { answered = true; continuation.resume(returning: true) }
                case .failed, .cancelled: if !answered { answered = true; continuation.resume(returning: false) }
                default: break
                }
            }
            listener.start(queue: .main)
        }
        port = ready ? listener.port?.rawValue ?? 0 : 0
        if port == 0 { listener.cancel(); self.listener = nil }
        return port != 0
    }

    private func serve(_ connection: NWConnection) { connection.start(queue: .main); readHead(connection, Data()) }
    private func readHead(_ connection: NWConnection, _ buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: LoopbackRequest.maxHead) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var head = buffered; if let data { head.append(data) }
                if head.range(of: Data("\r\n\r\n".utf8)) == nil {
                    if error != nil || complete || head.count > LoopbackRequest.maxHead { connection.cancel() } else { self.readHead(connection, head) }
                    return
                }
                guard let request = LoopbackRequest.parse(head, token: self.token), let remote = self.routes[request.id], let api = self.api else {
                    _ = await self.send(connection, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); connection.cancel(); return
                }
                await self.forward(request, to: remote, api: api, over: connection)
                connection.cancel()
            }
        }
    }

    private func forward(_ request: LoopbackRequest.Head, to remote: URL, api: FeedAPI, over connection: NWConnection) async {
        var upstream = await api.request(remote)
        upstream.httpMethod = request.method
        if let range = request.range { upstream.setValue(range, forHTTPHeaderField: "Range") }
        guard let result = try? await URLSession.shared.bytes(for: upstream), let http = result.1 as? HTTPURLResponse else {
            _ = await send(connection, Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
        }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\r\n"
        for field in ["Content-Type", "Content-Length", "Content-Range", "Accept-Ranges"] { if let value = http.value(forHTTPHeaderField: field) { head += "\(field): \(value)\r\n" } }
        head += "Connection: close\r\n\r\n"
        guard await send(connection, Data(head.utf8)), request.method == "GET" else { return }
        // ponytail: byte-wise AsyncBytes with 64 KB chunks; switch to a URLSessionDataDelegate if CPU shows up in profiles.
        var chunk = Data(); chunk.reserveCapacity(65536)
        do {
            for try await byte in result.0 {
                chunk.append(byte)
                if chunk.count == 65536 { guard await send(connection, chunk) else { return }; chunk.removeAll(keepingCapacity: true) }
            }
            if !chunk.isEmpty { _ = await send(connection, chunk) }
        } catch { return }   // VLC seeked away or the PC dropped: just close
    }

    /// Waits until the bytes are handed to the socket, so a slow reader slows the download (backpressure).
    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0 == nil) }) }
    }
}
#endif
