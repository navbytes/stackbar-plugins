import Foundation

/// What a stub server answers from, changed by a test between requests or
/// refreshes.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    var current: Value { lock.withLock { value } }
    func change(_ edit: (inout Value) -> Void) { lock.withLock { edit(&value) } }
}

#if canImport(Network)
import Network

/// An HTTP server on loopback for the plugins that talk to a service (Jira,
/// GitHub, a LiteLLM proxy). The plugin's requests reach it through the host
/// like any other; `handle` answers each with a status and a JSON body, and
/// `requests` records each one as "METHOD path auth body".
final class LoopbackStub: @unchecked Sendable {
    let listener: NWListener
    let requests = Recorder<String>()
    var port: Int { Int(listener.port!.rawValue) }
    init(_ handle: @escaping @Sendable (_ method: String, _ path: String, _ auth: String, _ body: Data) -> (Int, String)) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let requests = requests
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            @Sendable func read(_ sofar: Data) {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
                    let buffer = sofar + (data ?? Data())
                    guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { if !done && error == nil { read(buffer) }; return }
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in head.dropFirst() { if let c = line.firstIndex(of: ":") { headers[line[..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) } }
                    let body = Data(buffer[end.upperBound...])
                    if body.count < (Int(headers["content-length"] ?? "0") ?? 0) && !done { read(buffer); return }
                    let parts = head[0].split(separator: " ").map(String.init)
                    let auth = headers["authorization"] ?? ""
                    requests.record("\(parts[0]) \(parts[1]) \(auth) \(String(decoding: body, as: UTF8.self))")
                    let (status, text) = handle(parts[0], parts[1], auth, body)
                    let payload = Data(text.utf8)
                    let reply = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8) + payload, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            read(Data())
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global()); ready.wait()
    }
    deinit { listener.cancel() }
}
#endif
