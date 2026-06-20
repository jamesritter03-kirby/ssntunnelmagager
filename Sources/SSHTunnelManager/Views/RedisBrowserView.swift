import SwiftUI

/// The tab UI for a `.redis` session — a compact Redis browser: a scannable,
/// filterable key list on the left; a typed value viewer (string / list / set /
/// sorted-set / hash) with TTL and delete on the right; plus an arbitrary command
/// console. All operations go through the native `RedisClient`.
struct RedisBrowserView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var client: RedisClient

    @State private var keys: [String] = []
    @State private var cursor = "0"
    @State private var matchText = "*"
    @State private var scanning = false
    @State private var didInitialScan = false

    @State private var selectedKey: String?
    @State private var detail: RedisKeyDetail?
    @State private var loadingDetail = false

    @State private var commandText = ""
    @State private var consoleLines: [String] = []
    @State private var showConsole = false

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _client = ObservedObject(initialValue: session.redisClient
            ?? RedisClient(host: "127.0.0.1", port: 0, username: "", password: ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { startInitialScanIfReady() }
        .onChange(of: client.phase) { _ in startInitialScanIfReady() }
    }

    // MARK: - State screens

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .idle, .connecting:
            connectingScreen
        case .connected:
            browser
        case .failed(let message):
            statusScreen(icon: "exclamationmark.triangle.fill", tint: .orange,
                         title: "Couldn’t connect to Redis", message: message)
        case .ended:
            statusScreen(icon: "bolt.horizontal.circle.fill", tint: .secondary,
                         title: "Disconnected",
                         message: "The Redis connection was closed. Reconnect to resume.")
        }
    }

    private var connectingScreen: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Connecting to Redis…").foregroundStyle(.secondary)
            Text("\(client.host):\(client.port)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusScreen(icon: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button { session.restart() } label: {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Browser

    private var browser: some View {
        HSplitView {
            keyPane
            detailPane
        }
    }

    private var keyPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Match (e.g. user:*)", text: $matchText, onCommit: { runScan(reset: true) })
                    .textFieldStyle(.plain)
                    .font(.system(.caption, design: .monospaced))
                Button { runScan(reset: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Scan keys")
            }
            .padding(8)
            Divider()
            if keys.isEmpty {
                VStack(spacing: 8) {
                    if scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "key").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text("No keys").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedKey) {
                    ForEach(keys, id: \.self) { key in
                        Text(key)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .tag(key)
                    }
                }
                .listStyle(.inset)
            }
            if cursor != "0" {
                Divider()
                Button { runScan(reset: false) } label: {
                    Label(scanning ? "Scanning…" : "Load more", systemImage: "ellipsis.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .disabled(scanning)
                .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 220, idealWidth: 300, maxWidth: 460)
        .onChange(of: selectedKey) { key in loadDetail(key) }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if loadingDetail {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                keyDetail(detail)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 40)).foregroundStyle(.tint)
                    Text("Select a key").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            consolePanel
        }
        .frame(minWidth: 320)
    }

    private func keyDetail(_ detail: RedisKeyDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(detail.key)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button(role: .destructive) { deleteKey(detail.key) } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this key")
            }
            HStack(spacing: 10) {
                Text(detail.type.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(typeColor(detail.type).opacity(0.2))
                    .foregroundStyle(typeColor(detail.type))
                    .clipShape(Capsule())
                Label(ttlText(detail.ttl), systemImage: "timer")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            valueView(detail.value)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func valueView(_ value: RedisValue) -> some View {
        switch value {
        case .string(let s):
            ScrollView {
                Text(prettyString(s))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .list(let items):
            indexedTable(items)
        case .set(let items):
            indexedTable(items)
        case .zset(let pairs):
            pairTable(pairs.map { ($0.member, $0.score) }, left: "Member", right: "Score")
        case .hash(let pairs):
            pairTable(pairs.map { ($0.field, $0.value) }, left: "Field", right: "Value")
        case .unsupported(let type):
            Text("Can’t display values of type “\(type)”.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func indexedTable(_ items: [String]) -> some View {
        List {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Text("\(index)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text(item)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .listStyle(.inset)
    }

    private func pairTable(_ pairs: [(String, String)], left: String, right: String) -> some View {
        List {
            HStack {
                Text(left).frame(maxWidth: .infinity, alignment: .leading)
                Text(right).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.0)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(pair.1)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.inset)
    }

    private var consolePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("CONSOLE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !consoleLines.isEmpty {
                    Button { consoleLines.removeAll() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Clear the console")
                }
                Button { showConsole.toggle() } label: {
                    Image(systemName: showConsole ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }
            if showConsole && !consoleLines.isEmpty {
                ScrollView {
                    Text(consoleLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack(spacing: 8) {
                Text("redis>").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                TextField("command (e.g. GET key)", text: $commandText, onCommit: runCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Button { runCommand() } label: { Label("Run", systemImage: "return") }
                    .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty || !client.isConnected)
            }
        }
        .padding(10)
        .background(.bar)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if client.isConnected {
                Text("\(keys.count) keys loaded")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 14)
            Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reconnect to Redis")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusText: String {
        switch client.phase {
        case .idle:          return "Idle"
        case .connecting:    return "Connecting to \(client.host):\(client.port)…"
        case .connected:
            let version = client.serverVersion.isEmpty ? "" : " · Redis \(client.serverVersion)"
            return "Connected to \(client.host):\(client.port)\(version)"
        case .failed(let m): return m
        case .ended:         return "Disconnected"
        }
    }

    private var statusColor: Color {
        switch client.phase {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .failed:       return .red
        case .ended, .idle: return .secondary
        }
    }

    // MARK: - Actions

    private func startInitialScanIfReady() {
        guard client.isConnected, !didInitialScan else { return }
        didInitialScan = true
        runScan(reset: true)
    }

    private func runScan(reset: Bool) {
        guard client.isConnected, !scanning else { return }
        if reset {
            keys = []
            cursor = "0"
            selectedKey = nil
            detail = nil
        }
        scanning = true
        client.scan(cursor: cursor, match: matchText) { next, found in
            cursor = next
            var seen = Set(keys)
            for key in found where !seen.contains(key) {
                keys.append(key)
                seen.insert(key)
            }
            keys.sort()
            scanning = false
        }
    }

    private func loadDetail(_ key: String?) {
        guard let key else { detail = nil; return }
        loadingDetail = true
        client.load(key: key) { loaded in
            // Ignore a stale load if the selection moved on.
            guard selectedKey == key else { return }
            detail = loaded
            loadingDetail = false
        }
    }

    private func deleteKey(_ key: String) {
        client.delete(key: key) {
            keys.removeAll { $0 == key }
            if selectedKey == key { selectedKey = nil; detail = nil }
        }
    }

    private func runCommand() {
        let raw = commandText.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, client.isConnected else { return }
        let tokens = RESPParser.tokenize(raw)
        guard !tokens.isEmpty else { return }
        showConsole = true
        consoleLines.append("> \(raw)")
        commandText = ""
        client.command(tokens) { reply in
            consoleLines.append(reply.displayText)
            if consoleLines.count > 200 {
                consoleLines.removeFirst(consoleLines.count - 200)
            }
        }
    }

    // MARK: - Helpers

    private func ttlText(_ ttl: Int64?) -> String {
        guard let ttl else { return "No expiry" }
        if ttl < 60 { return "\(ttl)s" }
        if ttl < 3600 { return "\(ttl / 60)m \(ttl % 60)s" }
        return "\(ttl / 3600)h \((ttl % 3600) / 60)m"
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "string": return .blue
        case "list":   return .green
        case "set":    return .purple
        case "zset":   return .orange
        case "hash":   return .pink
        default:        return .secondary
        }
    }

    private func prettyString(_ s: String) -> String {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return s }
        return text
    }
}
