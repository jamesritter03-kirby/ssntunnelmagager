import Foundation
import Network

/// A small **Redis** client implemented over the Network framework, speaking
/// RESP2. It connects to the profile's **forwarded local port** (the SSH tunnel
/// maps `127.0.0.1:<port>` to the remote server), optionally authenticates, and
/// offers the operations the browser UI needs: key scanning, typed value
/// inspection, TTL, delete and an arbitrary‑command console.
///
/// Replies are well‑framed, so commands are matched to responses in FIFO order:
/// each `send` enqueues a continuation that the receive loop resolves as soon as
/// a complete RESP value is parsed.
///
/// Like `VNCClient`, this is a plain class: socket callbacks arrive on a private
/// queue and hop to the main queue (in FIFO order) before touching `@Published`
/// state or the `pending` queue, keeping replies matched to their commands.
final class RedisClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case ended
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var serverVersion: String = ""

    var onRunningChanged: ((Bool) -> Void)?

    let host: String
    let port: Int
    private let username: String
    private let password: String

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.local.sshtunnelmanager.redis")
    private var rxBuffer: [UInt8] = []
    private var pending: [(RESPValue) -> Void] = []
    /// Bumped on every (re)open / teardown so callbacks from a stale
    /// `NWConnection` are ignored.
    private var generation = 0
    /// Retries of the *initial* connect — right after launch the SSH tunnel may
    /// not have finished binding its forwarded port yet, so the first attempt can
    /// be refused. We retry quietly until it comes up.
    private var connectAttempts = 0
    private let maxConnectAttempts = 25
    private let retryDelay: TimeInterval = 1.2
    /// Set once the TCP socket reaches the server; after that a drop is real.
    private var reachedServer = false

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    var isConnected: Bool { phase == .connected }

    // MARK: - Lifecycle

    func start() {
        guard phase != .connecting, phase != .connected else { return }
        connectAttempts = 0
        reachedServer = false
        phase = .connecting
        onRunningChanged?(true)
        pending.removeAll()
        openConnection()
    }

    /// Open a fresh TCP connection and wire up its callbacks. Used by `start()`
    /// and by the initial-connect retry.
    private func openConnection() {
        generation += 1
        let gen = generation
        rxBuffer.removeAll()

        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            fail("Invalid port \(port).")
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.reachedServer = true
                    self.handshake()
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.connectionFailed(error.localizedDescription)
                }
            case .cancelled:
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.end()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        receiveLoop(gen)
    }

    /// A socket-level failure. Right after launch this is usually “connection
    /// refused” because the SSH tunnel hasn’t finished binding its forwarded
    /// port — so retry quietly (staying in `.connecting`) until it comes up.
    private func connectionFailed(_ message: String) {
        guard phase == .connecting, !reachedServer else {
            fail(message)
            return
        }
        generation += 1            // ignore this dead socket's remaining callbacks
        connection?.cancel()
        connection = nil
        connectAttempts += 1
        guard connectAttempts < maxConnectAttempts else {
            fail(message)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, self.phase == .connecting, self.connection == nil else { return }
            self.openConnection()
        }
    }

    func disconnect() {
        guard phase == .connecting || phase == .connected else { return }
        teardown()
        end()
    }

    func reconnect() {
        teardown()
        phase = .idle
        serverVersion = ""
        start()
    }

    // MARK: - Handshake

    private func handshake() {
        // Authenticate if a password was provided, then verify with a PING and
        // grab the server version for the status bar.
        if !password.isEmpty {
            let authArgs = username.isEmpty || username == "default"
                ? ["AUTH", password]
                : ["AUTH", username, password]
            command(authArgs) { [weak self] reply in
                guard let self else { return }
                if case .error(let message) = reply {
                    self.fail("Authentication failed: \(message)")
                } else {
                    self.finishConnect()
                }
            }
        } else {
            finishConnect()
        }
    }

    private func finishConnect() {
        phase = .connected
        onRunningChanged?(true)
        command(["INFO", "server"]) { [weak self] reply in
            guard let self, let text = reply.stringValue else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("redis_version:") {
                self.serverVersion = line
                    .replacingOccurrences(of: "redis_version:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: - Commands

    /// Send a command, delivering its single RESP reply to `completion`.
    func command(_ args: [String], completion: @escaping (RESPValue) -> Void) {
        guard let connection else { completion(.error("Not connected")); return }
        pending.append(completion)
        connection.send(content: RESPParser.encode(command: args), completion: .contentProcessed { _ in })
    }

    /// SCAN one page of keys. Returns the next cursor ("0" when done) and the keys.
    func scan(cursor: String, match: String, completion: @escaping (_ cursor: String, _ keys: [String]) -> Void) {
        var args = ["SCAN", cursor]
        let pattern = match.trimmingCharacters(in: .whitespaces)
        if !pattern.isEmpty { args += ["MATCH", pattern] }
        args += ["COUNT", "300"]
        command(args) { reply in
            guard case .array(let items?) = reply, items.count == 2,
                  let next = items[0].stringValue else {
                completion("0", [])
                return
            }
            completion(next, items[1].arrayStrings)
        }
    }

    /// Load a key's type, TTL and value in one shot.
    func load(key: String, completion: @escaping (RedisKeyDetail) -> Void) {
        command(["TYPE", key]) { [weak self] typeReply in
            guard let self else { return }
            let type = typeReply.stringValue ?? "none"
            self.command(["TTL", key]) { ttlReply in
                let ttl: Int64? = { if case .integer(let n) = ttlReply, n >= 0 { return n }; return nil }()
                self.fetchValue(key: key, type: type) { value in
                    completion(RedisKeyDetail(key: key, type: type, ttl: ttl, value: value))
                }
            }
        }
    }

    private func fetchValue(key: String, type: String, completion: @escaping (RedisValue) -> Void) {
        switch type {
        case "string":
            command(["GET", key]) { completion(.string($0.stringValue ?? "")) }
        case "list":
            command(["LRANGE", key, "0", "-1"]) { completion(.list($0.arrayStrings)) }
        case "set":
            command(["SMEMBERS", key]) { completion(.set($0.arrayStrings)) }
        case "zset":
            command(["ZRANGE", key, "0", "-1", "WITHSCORES"]) { reply in
                let flat = reply.arrayStrings
                var pairs: [(String, String)] = []
                var i = 0
                while i + 1 < flat.count { pairs.append((flat[i], flat[i + 1])); i += 2 }
                completion(.zset(pairs))
            }
        case "hash":
            command(["HGETALL", key]) { reply in
                let flat = reply.arrayStrings
                var pairs: [(String, String)] = []
                var i = 0
                while i + 1 < flat.count { pairs.append((flat[i], flat[i + 1])); i += 2 }
                completion(.hash(pairs))
            }
        default:
            completion(.unsupported(type))
        }
    }

    func delete(key: String, completion: @escaping () -> Void) {
        command(["DEL", key]) { _ in completion() }
    }

    // MARK: - Receive

    private func receiveLoop(_ gen: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            // FIFO hop to main so replies are parsed in order and matched to the
            // pending commands correctly.
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let data, !data.isEmpty { self.ingest([UInt8](data)) }
                if isComplete || error != nil {
                    if self.reachedServer { self.end() }
                    else { self.connectionFailed("Connection closed") }
                    return
                }
                self.receiveLoop(gen)
            }
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        rxBuffer.append(contentsOf: bytes)
        var index = 0
        while let (value, next) = RESPParser.parse(rxBuffer, at: index) {
            index = next
            if pending.isEmpty { continue }
            let completion = pending.removeFirst()
            completion(value)
        }
        if index > 0 { rxBuffer.removeFirst(index) }
    }

    // MARK: - State transitions

    private func fail(_ message: String) {
        teardown()
        phase = .failed(message)
        onRunningChanged?(false)
    }

    private func end() {
        if case .failed = phase { return }
        teardown()
        phase = .ended
        onRunningChanged?(false)
    }

    private func teardown() {
        generation += 1
        // Resolve any in‑flight commands so their UI doesn't hang.
        let stillPending = pending
        pending.removeAll()
        for completion in stillPending { completion(.error("Disconnected")) }
        connection?.cancel()
        connection = nil
    }
}

/// How a key's value is rendered, by Redis type.
enum RedisValue {
    case string(String)
    case list([String])
    case set([String])
    case zset([(member: String, score: String)])
    case hash([(field: String, value: String)])
    case unsupported(String)
}

/// Everything the detail pane shows for one key.
struct RedisKeyDetail {
    let key: String
    let type: String
    let ttl: Int64?
    let value: RedisValue
}
