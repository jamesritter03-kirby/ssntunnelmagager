import Foundation
import Network

/// A minimal **MQTT 3.1.1** client implemented directly over the Network
/// framework. It connects to the profile's **forwarded local port** (the SSH
/// tunnel already maps `127.0.0.1:<port>` to the remote broker), authenticates
/// with an optional username / password, subscribes to everything (`#` and
/// `$SYS/#`), and exposes a live per‑topic view — the engine behind
/// `MQTTExplorerView`.
///
/// We implement the wire protocol rather than pull in a dependency: MQTT 3.1.1 is
/// a small binary protocol and we only need CONNECT / SUBSCRIBE / PUBLISH / PING.
/// QoS 0 is used for our own subscribe + publish; incoming QoS 1 messages are
/// acknowledged so compliant brokers don't stall.
///
/// Like `VNCClient`, this is a plain class: socket callbacks arrive on a private
/// queue and hop to the main queue (in FIFO order) before touching `@Published`
/// state, so the byte stream is parsed in sequence and the UI stays consistent.
final class MQTTClient: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
        case ended
    }

    /// The latest known state of one topic (what the explorer tree shows).
    struct TopicState {
        var payload: Data
        var retained: Bool
        var count: Int
        var lastUpdate: Date
        var payloadString: String { String(decoding: payload, as: UTF8.self) }
    }

    @Published private(set) var phase: Phase = .idle
    /// Every topic seen this session → its most recent payload + message count.
    @Published private(set) var topics: [String: TopicState] = [:]
    @Published private(set) var totalMessages: Int = 0
    @Published private(set) var lastActivity: Date?

    /// Mirrors connection state to the owning session's running indicator.
    var onRunningChanged: ((Bool) -> Void)?

    let host: String
    let port: Int
    private let username: String
    private let password: String
    private let clientID: String
    private let keepAlive: UInt16 = 30

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.local.sshtunnelmanager.mqtt")
    private var rxBuffer: [UInt8] = []
    private var packetID: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    /// Bumped on every (re)open / teardown so callbacks from a stale
    /// `NWConnection` are ignored.
    private var generation = 0
    /// Retries of the *initial* connect — right after launch the SSH tunnel may
    /// not have finished binding its forwarded port yet, so the first attempt can
    /// be refused. We retry quietly until it comes up.
    private var connectAttempts = 0
    private let maxConnectAttempts = 25
    private let retryDelay: TimeInterval = 1.2
    /// Set once the TCP socket reaches the broker; after that a drop is real.
    private var reachedServer = false

    init(host: String, port: Int, username: String, password: String) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.clientID = "sshtm-" + String(UUID().uuidString.prefix(8))
    }

    var isConnected: Bool { phase == .connected }

    // MARK: - Lifecycle

    func start() {
        guard phase != .connecting, phase != .connected else { return }
        connectAttempts = 0
        reachedServer = false
        phase = .connecting
        onRunningChanged?(true)
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
                    self.handleReady()
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

    /// Gracefully close the connection (sends DISCONNECT first).
    func disconnect() {
        guard phase == .connecting || phase == .connected else { return }
        send(MQTTPacket.disconnect())
        teardown()
        end()
    }

    /// Close and connect again from scratch, clearing the topic view.
    func reconnect() {
        teardown()
        topics = [:]
        totalMessages = 0
        phase = .idle
        start()
    }

    /// Forget all collected topics/messages (keeps the connection open).
    func clear() {
        topics = [:]
        totalMessages = 0
    }

    /// Publish a message to `topic` (QoS 0). Used by the explorer's publish panel.
    func publish(topic: String, payload: String, retain: Bool) {
        guard isConnected, !topic.isEmpty else { return }
        send(MQTTPacket.publish(topic: topic, payload: Data(payload.utf8), retain: retain))
    }

    // MARK: - Send / receive

    /// Runs on the main queue once the socket is ready: send CONNECT, then listen.
    private func handleReady() {
        send(MQTTPacket.connect(clientID: clientID,
                                username: username,
                                password: password,
                                keepAlive: keepAlive))
        receiveLoop(generation)
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(_ gen: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            // Hop to main in arrival order (FIFO) so the byte stream is parsed in
            // sequence and @Published updates land on the UI thread.
            DispatchQueue.main.async {
                guard gen == self.generation else { return }
                if let data, !data.isEmpty { self.ingest([UInt8](data)) }
                if isComplete || error != nil { self.end(); return }
                self.receiveLoop(gen)
            }
        }
    }

    private func ingest(_ bytes: [UInt8]) {
        rxBuffer.append(contentsOf: bytes)
        while let packet = MQTTPacket.next(from: &rxBuffer) {
            handle(packet)
        }
    }

    private func handle(_ packet: MQTTPacket.Incoming) {
        switch packet {
        case .connack(let accepted, let message):
            if accepted {
                phase = .connected
                send(MQTTPacket.subscribe(packetID: nextPacketID(), topics: ["#", "$SYS/#"]))
                startPing()
            } else {
                fail(message)
            }
        case .publish(let topic, let payload, let retained, let qos, let packetID):
            record(topic: topic, payload: payload, retained: retained)
            if qos == 1, let pid = packetID {
                send(MQTTPacket.puback(pid))
            }
        case .pingResp, .suback, .other:
            break
        }
    }

    private func record(topic: String, payload: Data, retained: Bool) {
        let now = Date()
        var state = topics[topic] ?? TopicState(payload: Data(), retained: retained, count: 0, lastUpdate: now)
        state.payload = payload
        state.retained = retained
        state.count += 1
        state.lastUpdate = now
        topics[topic] = state
        totalMessages += 1
        lastActivity = now
    }

    // MARK: - Keep‑alive

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Double(keepAlive), repeating: Double(keepAlive))
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.send(MQTTPacket.pingReq()) }
        }
        timer.resume()
        pingTimer = timer
    }

    private func nextPacketID() -> UInt16 {
        packetID &+= 1
        if packetID == 0 { packetID = 1 }
        return packetID
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
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
    }
}
