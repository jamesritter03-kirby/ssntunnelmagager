import SwiftUI
import AppKit

// A live Connection Health window: every networked tab in the scope (a single
// tab or a whole workspace) is TCP-probed on a timer for reachability and
// round-trip latency. Results feed per-connection rows with sparklines plus an
// aggregate average-latency graph. Opened from the tab / workspace right-click
// menus, mirroring the cross-platform app's dialog.

/// Opens (and reuses) Connection Health windows, keyed so re-invoking the same
/// scope focuses the existing window instead of spawning duplicates.
@MainActor
final class ConnectionHealthWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [String: ConnectionHealthWindowController] = [:]

    private let key: String
    private var window: NSWindow?
    private let model: ConnectionHealthViewModel

    private init(key: String, title: String, provider: @escaping () -> [TerminalSession]) {
        self.key = key
        self.model = ConnectionHealthViewModel(title: title, provider: provider)
        super.init()
    }

    /// Show the health window for `title`/`key`, creating it if needed.
    static func open(key: String, title: String,
                     provider: @escaping () -> [TerminalSession]) {
        if let existing = controllers[key] {
            existing.focus()
            return
        }
        let controller = ConnectionHealthWindowController(key: key, title: title, provider: provider)
        controllers[key] = controller
        controller.present()
    }

    private func focus() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func present() {
        let root = ConnectionHealthView(model: model)
        let hosting = NSHostingView(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Connection Health — \(model.title)"
        win.contentView = hosting
        win.minSize = NSSize(width: 420, height: 360)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win
        focus()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        window = nil
        Self.controllers[key] = nil
    }
}

/// Drives the Connection Health window: refreshes the connection list from the
/// provider, probes each endpoint for latency, and rolls the aggregate graph.
@MainActor
final class ConnectionHealthViewModel: ObservableObject {
    let title: String
    private let provider: () -> [TerminalSession]
    private let manager = TerminalSessionManager.shared
    private let openedAt = Date()

    @Published private(set) var rows: [ConnectionHealthRow] = []
    @Published private(set) var aggregateHistory: [Double] = []
    @Published private(set) var averageLatency: Double = -1
    @Published private(set) var liveCount = 0
    @Published private(set) var totalTabs = 0
    @Published private(set) var lastUpdated = ""
    @Published var autoRefresh = true {
        didSet { autoRefresh ? start() : timer?.invalidate() }
    }

    private var timer: Timer?
    private var busy = false

    init(title: String, provider: @escaping () -> [TerminalSession]) {
        self.title = title
        self.provider = provider
        refresh()
        start()
    }

    var averageLatencyText: String { averageLatency < 0 ? "—" : "\(Int(averageLatency.rounded())) ms" }
    var summaryText: String { "\(liveCount) of \(rows.count) reachable · \(totalTabs) tabs" }
    var uptimeText: String { Self.span(Date().timeIntervalSince(openedAt)) }

    func manualRefresh() { refresh() }

    private func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        guard !busy else { return }
        busy = true

        let sessions = provider()
        totalTabs = sessions.count

        // The networked sessions we can probe, with their endpoints.
        let probeable: [(session: TerminalSession, host: String, port: Int)] =
            sessions.compactMap { s in
                guard let ep = manager.probeEndpoint(for: s) else { return nil }
                return (s, ep.host, ep.port)
            }

        // Drop rows whose tab is gone; add rows for new connections, in order.
        rows.removeAll { r in !probeable.contains { $0.session.id == r.id } }
        for (index, item) in probeable.enumerated() {
            if let existing = rows.first(where: { $0.id == item.session.id }) {
                existing.title = item.session.title
            } else {
                let row = ConnectionHealthRow(id: item.session.id,
                                              title: item.session.title,
                                              symbol: item.session.symbolName,
                                              host: item.host, port: item.port)
                rows.insert(row, at: min(index, rows.count))
            }
        }

        // Probe every endpoint; apply results and roll the aggregate.
        let group = DispatchGroup()
        let snapshot = rows
        var results: [(row: ConnectionHealthRow, ms: Double)] = []
        let lock = NSLock()
        for row in snapshot {
            group.enter()
            TCPProbe.latency(host: row.host, port: row.port, timeout: 2.0) { ms in
                lock.lock(); results.append((row, ms)); lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var sum = 0.0
            var live = 0
            for (row, ms) in results {
                row.apply(latency: ms)
                if ms >= 0 { sum += ms; live += 1 }
            }
            self.liveCount = live
            self.averageLatency = live > 0 ? sum / Double(live) : -1
            self.aggregateHistory.append(self.averageLatency)
            if self.aggregateHistory.count > 60 { self.aggregateHistory.removeFirst() }
            self.lastUpdated = "Updated " + Self.clock.string(from: Date())
            self.objectWillChange.send()
            self.busy = false
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private static func span(_ s: TimeInterval) -> String {
        if s >= 3600 { return "\(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" }
        if s >= 60 { return "\(Int(s / 60))m \(Int(s.truncatingRemainder(dividingBy: 60)))s" }
        return "\(Int(s))s"
    }
}

/// One connection in the health window: its endpoint, live reachability, latest
/// and rolling latency, connect/drop counters, and a bounded latency history.
@MainActor
final class ConnectionHealthRow: ObservableObject, Identifiable {
    let id: UUID
    let symbol: String
    let host: String
    let port: Int
    var endpoint: String { "\(host):\(port)" }

    @Published var title: String
    @Published private(set) var latencyMs: Double = -1
    @Published private(set) var isLive = false
    @Published private(set) var history: [Double] = []
    @Published private(set) var minMs: Double = -1
    @Published private(set) var maxMs: Double = -1
    @Published private(set) var avgMs: Double = -1
    @Published private(set) var connectCount = 0
    @Published private(set) var dropCount = 0
    @Published private(set) var uptimePercent: Double = -1

    private var firstProbe = true
    private var previousLive = false
    private var totalProbes = 0
    private var liveProbes = 0
    private var latencySum = 0.0
    private var latencySamples = 0
    private var lastConnectedAt: Date?
    private var lastDroppedAt: Date?

    init(id: UUID, title: String, symbol: String, host: String, port: Int) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.host = host
        self.port = port
    }

    var latencyText: String { latencyMs < 0 ? "timeout" : "\(Int(latencyMs.rounded())) ms" }
    var statusText: String { isLive ? "● reachable" : "● unreachable" }
    var statusColor: Color { isLive ? .green : .red }
    var rangeText: String {
        minMs < 0 ? "no samples yet"
                  : "min \(Int(minMs.rounded())) · avg \(Int(avgMs.rounded())) · max \(Int(maxMs.rounded())) ms"
    }
    var statsText: String {
        var parts = ["↑ \(connectCount) connect\(connectCount == 1 ? "" : "s")",
                     "↓ \(dropCount) drop\(dropCount == 1 ? "" : "s")"]
        if uptimePercent >= 0 { parts.append("\(Int(uptimePercent.rounded()))% uptime") }
        return parts.joined(separator: "  ")
    }

    func apply(latency ms: Double) {
        let live = ms >= 0
        latencyMs = ms
        isLive = live
        totalProbes += 1
        if live { liveProbes += 1 }
        uptimePercent = Double(liveProbes) / Double(totalProbes) * 100

        if firstProbe {
            firstProbe = false
            if live { lastConnectedAt = Date() }
        } else if !previousLive && live {
            connectCount += 1
            lastConnectedAt = Date()
        } else if previousLive && !live {
            dropCount += 1
            lastDroppedAt = Date()
        }
        previousLive = live

        if live {
            history.append(ms)
            if history.count > 60 { history.removeFirst() }
            latencySum += ms
            latencySamples += 1
            avgMs = latencySum / Double(latencySamples)
            minMs = minMs < 0 ? ms : Swift.min(minMs, ms)
            maxMs = Swift.max(maxMs, ms)
        }
    }
}

/// A simple line sparkline over a bounded series, auto-scaled to its own range.
private struct Sparkline: View {
    let values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let points = values.filter { $0 >= 0 }
            if points.count >= 2 {
                let lo = points.min() ?? 0
                let hi = points.max() ?? 1
                let span = max(0.0001, hi - lo)
                Path { path in
                    for (i, v) in points.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(points.count - 1)
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        i == 0 ? path.move(to: CGPoint(x: x, y: y))
                               : path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            } else {
                Rectangle().fill(Color.secondary.opacity(0.08))
            }
        }
    }
}

/// The Connection Health window contents.
struct ConnectionHealthView: View {
    @ObservedObject var model: ConnectionHealthViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.rows.isEmpty {
                empty
            } else {
                ScrollView { rowsStack }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline)
                    Text(model.summaryText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.averageLatencyText).font(.title3.monospacedDigit().weight(.semibold))
                    Text("avg latency").font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Sparkline(values: model.aggregateHistory)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            }
            HStack {
                Toggle("Auto-refresh", isOn: $model.autoRefresh)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text("open \(model.uptimeText)").font(.caption2).foregroundStyle(.secondary)
                if !model.lastUpdated.isEmpty {
                    Text("·").foregroundStyle(.secondary)
                    Text(model.lastUpdated).font(.caption2).foregroundStyle(.secondary)
                }
                Button { model.manualRefresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Probe now")
            }
        }
        .padding(14)
    }

    private var rowsStack: some View {
        VStack(spacing: 0) {
            ForEach(model.rows) { row in
                ConnectionHealthRowView(row: row)
                Divider()
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No networked connections").font(.headline)
            Text("Open an SSH, SFTP, VNC or forwarded-service tab to see its health here.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ConnectionHealthRowView: View {
    @ObservedObject var row: ConnectionHealthRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.symbol)
                .foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(.medium).lineLimit(1)
                    Text(row.endpoint).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(row.statusText).font(.caption).foregroundStyle(row.statusColor)
                    Text(row.latencyText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(row.statsText).font(.caption2).foregroundStyle(.secondary)
                Text(row.rangeText).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Sparkline(values: row.history, color: row.statusColor)
                .frame(width: 120, height: 34)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
