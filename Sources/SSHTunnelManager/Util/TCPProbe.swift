import Foundation
import Network

/// A tiny TCP reachability probe used by the tunnel-health indicator: it tries
/// to open a connection to a forwarded local port and reports whether it was
/// accepted, without sending any data.
enum TCPProbe {
    /// Attempt to connect to `host:port`, calling `completion(true)` if the
    /// connection becomes ready within `timeout`, else `completion(false)`.
    static func isReachable(host: String, port: Int, timeout: TimeInterval,
                            completion: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: port)), port > 0 else {
            completion(false); return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "TCPProbe")
        var finished = false
        let finish: (Bool) -> Void = { ok in
            queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                completion(ok)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:            finish(true)
            case .failed, .cancelled:
                finish(false)
            default:                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
    }

    /// Probe several endpoints; `completion(true)` only if **every** one is
    /// reachable (the tunnel is fully healthy), else `completion(false)`.
    static func allReachable(_ endpoints: [(host: String, port: Int)], timeout: TimeInterval,
                             completion: @escaping (Bool) -> Void) {
        guard !endpoints.isEmpty else { completion(true); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var allOK = true
        for endpoint in endpoints {
            group.enter()
            isReachable(host: endpoint.host, port: endpoint.port, timeout: timeout) { ok in
                lock.lock(); if !ok { allOK = false }; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(allOK) }
    }
}
