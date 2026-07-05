import SwiftUI
import Charts

/// The tab UI for a `.mqtt` session — a compact "MQTT Explorer": a live,
/// filterable **tree** of every topic the broker has published (grouped by the
/// `/`-delimited path), a detail pane that pretty-prints the latest payload
/// (JSON when possible), and a publish panel. All data comes from the native
/// `MQTTClient` driving the connection.
struct MQTTExplorerView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var client: MQTTClient

    @State private var filterText = ""
    @State private var publishTopic = ""
    @State private var publishPayload = ""
    @State private var publishRetain = false

    /// Whether the detail pane shows the raw payload or the live graph, plus which
    /// numeric series ("items") are plotted. Both reset when the topic changes.
    @State private var detailTab: TopicDetailTab = .payload
    @State private var graphSelection: Set<String> = []

    // The topic tree's selection and expansion live on the (session-owned)
    // `client`, not on view `@State`, so switching tabs/workspaces — which tears
    // this view down and rebuilds it — no longer collapses the tree or re-expands
    // everything. These proxies read/write that persistent state.

    /// The currently-selected topic/branch id.
    private var selectedNodeID: String? {
        get { client.uiSelectedTopicID }
        nonmutating set { client.uiSelectedTopicID = newValue }
    }
    /// A binding to the selection for `List(selection:)`.
    private var selectedNodeBinding: Binding<String?> {
        Binding(get: { client.uiSelectedTopicID },
                set: { client.uiSelectedTopicID = $0 })
    }
    /// Branch node ids the user has expanded in the topic tree.
    private var expanded: Set<String> {
        get { client.uiExpandedBranches }
        nonmutating set { client.uiExpandedBranches = newValue }
    }
    /// Branch ids we've already auto-expanded once, so brand-new topics open by
    /// default while the user's later manual collapses still stick.
    private var seenBranches: Set<String> {
        get { client.uiSeenBranches }
        nonmutating set { client.uiSeenBranches = newValue }
    }

    init(session: TerminalSession) {
        _session = ObservedObject(initialValue: session)
        _client = ObservedObject(initialValue: session.mqttClient
            ?? MQTTClient(host: "127.0.0.1", port: 0, username: "", password: ""))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - State screens

    @ViewBuilder
    private var content: some View {
        switch client.phase {
        case .idle, .connecting:
            connectingScreen
        case .connected:
            explorer
        case .failed(let message):
            statusScreen(icon: "exclamationmark.triangle.fill", tint: .orange,
                         title: "Couldn’t connect to the broker", message: message)
        case .ended:
            statusScreen(icon: "bolt.horizontal.circle.fill", tint: .secondary,
                         title: "Disconnected",
                         message: "The MQTT connection was closed. Reconnect to resume.")
        }
    }

    private var connectingScreen: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Connecting to the MQTT broker…").foregroundStyle(.secondary)
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

    // MARK: - Explorer

    private var explorer: some View {
        HSplitView {
            topicList
            detail
        }
    }

    // MARK: - Topic tree

    /// The topics that match the current filter (empty filter ⇒ all).
    private var filteredTopics: [String] {
        let keys = client.topics.keys.sorted()
        let q = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return keys }
        return keys.filter { $0.lowercased().contains(q) }
    }

    /// Whether a filter is active (the whole filtered tree is shown expanded).
    private var isFiltering: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The filtered topics arranged into a `/`-delimited tree.
    private var tree: [MQTTTreeNode] {
        MQTTTreeNode.build(from: filteredTopics, states: client.topics)
    }

    /// The tree flattened to the currently-visible rows (respecting expansion).
    private var visibleRows: [MQTTTreeRow] {
        var rows: [MQTTTreeRow] = []
        appendRows(tree, depth: 0, into: &rows)
        return rows
    }

    private func appendRows(_ nodes: [MQTTTreeNode], depth: Int, into rows: inout [MQTTTreeRow]) {
        for node in nodes {
            rows.append(MQTTTreeRow(node: node, depth: depth))
            if let children = node.children, isFiltering || expanded.contains(node.id) {
                appendRows(children, depth: depth + 1, into: &rows)
            }
        }
    }

    private var topicList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter topics", text: $filterText).textFieldStyle(.plain)
            }
            .padding(8)
            Divider()
            if client.topics.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for messages…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selectedNodeBinding) {
                    ForEach(visibleRows) { row in
                        treeRow(row.node, depth: row.depth)
                            .tag(row.node.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 240, idealWidth: 320, maxWidth: 460)
        .onAppear { autoExpandNewBranches() }
        .onChange(of: client.topics.count) { _ in autoExpandNewBranches() }
    }

    private func treeRow(_ node: MQTTTreeNode, depth: Int) -> some View {
        let state = node.topic.flatMap { client.topics[$0] }
        return HStack(spacing: 4) {
            // A disclosure triangle for branches; a fixed-width spacer for leaves
            // keeps the names aligned.
            if node.children != nil {
                Image(systemName: (isFiltering || expanded.contains(node.id)) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { toggle(node.id) }
            } else {
                Spacer().frame(width: 12)
            }
            Image(systemName: node.topic != nil ? "number" : "folder.fill")
                .font(.caption2)
                .foregroundStyle(node.topic != nil ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name.isEmpty ? "/" : node.name)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let state {
                    Text(state.payloadString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if let state {
                if state.retained {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                countBadge(state.count, secondary: false)
            } else {
                countBadge(node.topicCount, secondary: true)
            }
        }
        .padding(.leading, CGFloat(depth) * 12)
        .contentShape(Rectangle())
        .contextMenu { treeContextMenu(for: node) }
    }

    /// The right-click menu for a tree row: expand/collapse this branch plus the
    /// whole tree.
    @ViewBuilder
    private func treeContextMenu(for node: MQTTTreeNode) -> some View {
        if node.children != nil {
            Button("Expand Branch") { expandSubtree(node) }
            Button("Collapse Branch") { collapseSubtree(node) }
            Divider()
        }
        Button("Expand All") { expandAll() }
        Button("Collapse All") { collapseAll() }
    }

    private func countBadge(_ value: Int, secondary: Bool) -> some View {
        Text("\(value)")
            .font(.caption2).monospacedDigit()
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// Open every branch in the tree.
    private func expandAll() {
        let branches = MQTTTreeNode.branchIDs(for: Array(client.topics.keys))
        expanded = branches
        seenBranches.formUnion(branches)
    }

    /// Close every branch. Mark them all “seen” so auto-expand doesn’t reopen
    /// the existing ones (newly-arriving topics still expand by default).
    private func collapseAll() {
        seenBranches.formUnion(MQTTTreeNode.branchIDs(for: Array(client.topics.keys)))
        expanded.removeAll()
    }

    /// All branch ids at or beneath `node`.
    private func branchIDs(under node: MQTTTreeNode) -> Set<String> {
        let all = MQTTTreeNode.branchIDs(for: Array(client.topics.keys))
        let prefix = node.id + "/"
        return all.filter { $0 == node.id || $0.hasPrefix(prefix) }
    }

    private func expandSubtree(_ node: MQTTTreeNode) {
        let ids = branchIDs(under: node)
        expanded.formUnion(ids)
        seenBranches.formUnion(ids)
    }

    private func collapseSubtree(_ node: MQTTTreeNode) {
        expanded.subtract(branchIDs(under: node))
        seenBranches.formUnion(branchIDs(under: node))
    }

    /// Auto-expand branches the first time we see them, so new topics appear
    /// opened while still honoring the user's later manual collapses.
    private func autoExpandNewBranches() {
        let branches = MQTTTreeNode.branchIDs(for: Array(client.topics.keys))
        let fresh = branches.subtracting(seenBranches)
        guard !fresh.isEmpty else { return }
        seenBranches.formUnion(fresh)
        expanded.formUnion(fresh)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let id = selectedNodeID, let state = client.topics[id] {
                topicDetail(id, state)
            } else if let id = selectedNodeID {
                branchDetail(id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 40)).foregroundStyle(.tint)
                    Text("Select a topic").foregroundStyle(.secondary)
                    Text("\(client.topics.count) topics · \(client.totalMessages) messages")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            publishPanel
        }
        .frame(minWidth: 320)
        .onChange(of: selectedNodeID) { _ in
            detailTab = .payload
            graphSelection = []
        }
    }

    /// Shown when a branch (a topic prefix that carries no message of its own) is
    /// selected: a summary of everything beneath it.
    private func branchDetail(_ id: String) -> some View {
        let prefix = id + "/"
        let matches = client.topics.filter { $0.key == id || $0.key.hasPrefix(prefix) }
        let messages = matches.values.reduce(0) { $0 + $1.count }
        return VStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(id)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("\(matches.count) topics · \(messages) messages")
                .font(.caption).foregroundStyle(.secondary)
            Button { publishTopic = prefix } label: {
                Label("Use as publish topic", systemImage: "arrowshape.turn.up.left")
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func topicDetail(_ topic: String, _ state: MQTTClient.TopicState) -> some View {
        let fields = availableFields(for: topic)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(topic)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                Spacer()
                Button { publishTopic = topic } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }
                .buttonStyle(.borderless)
                .help("Use this topic in the publish panel")
            }
            HStack(spacing: 14) {
                Label("\(state.count)", systemImage: "number")
                if state.retained {
                    Label("Retained", systemImage: "pin.fill").foregroundStyle(.orange)
                }
                Label(state.lastUpdate.formatted(date: .omitted, time: .standard),
                      systemImage: "clock")
            }
            .font(.caption).foregroundStyle(.secondary)
            Picker("View", selection: $detailTab) {
                Text("Payload").tag(TopicDetailTab.payload)
                Text("Graph").tag(TopicDetailTab.graph)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Divider()
            if detailTab == .graph {
                graphSection(topic: topic, fields: fields)
            } else {
                ScrollView {
                    Text(prettyPayload(state.payload))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Graphing

    /// The graph pane: chips to toggle each numeric "item" plus a live line chart
    /// of the selected series over time.
    private func graphSection(topic: String, fields: [String]) -> some View {
        let shown = plottedFields(fields)
        let points = chartPoints(topic: topic, fields: shown)
        let showSymbols = points.count <= 60   // dots so 1–2 samples are visible
        return VStack(alignment: .leading, spacing: 8) {
            if fields.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Nothing to graph yet")
                        .font(.callout.weight(.medium))
                    Text("This topic hasn’t sent a numeric value. A bare number, or numeric fields inside a JSON payload, will appear here as live series as new messages arrive.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if fields.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(fields, id: \.self) { field in
                                Button { toggleField(field, in: fields) } label: {
                                    fieldChip(field, selected: shown.contains(field))
                                }
                                .buttonStyle(.plain)
                                .help("Show or hide this series")
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.time),
                                 y: .value("Value", point.value))
                            .foregroundStyle(by: .value("Series", point.field))
                            .interpolationMethod(.monotone)
                        if showSymbols {
                            PointMark(x: .value("Time", point.time),
                                      y: .value("Value", point.value))
                                .symbolSize(26)
                                .foregroundStyle(by: .value("Series", point.field))
                        }
                    }
                }
                .chartYScale(domain: yDomain(for: points))
                .chartLegend(shown.count > 1 ? .visible : .hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text("\(samplePointCount(topic: topic)) sample\(samplePointCount(topic: topic) == 1 ? "" : "s") · \(shown.count) of \(fields.count) item\(fields.count == 1 ? "" : "s") shown")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Numeric series available to graph for a topic — the sorted union of keys
    /// seen across its retained history.
    private func availableFields(for topic: String) -> [String] {
        guard let series = client.history[topic], !series.isEmpty else { return [] }
        var keys = Set<String>()
        for sample in series { keys.formUnion(sample.values.keys) }
        return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The series actually plotted: the user's picks (intersected with what's
    /// available), or a sensible default before they choose — all of them when
    /// there are only a few, otherwise just the first.
    private func plottedFields(_ available: [String]) -> [String] {
        let chosen = graphSelection.intersection(available)
        if !chosen.isEmpty { return available.filter { chosen.contains($0) } }
        return available.count <= 6 ? available : Array(available.prefix(1))
    }

    private func toggleField(_ field: String, in available: [String]) {
        var chosen = Set(plottedFields(available))
        if chosen.contains(field) {
            guard chosen.count > 1 else { return }   // keep at least one series
            chosen.remove(field)
        } else {
            chosen.insert(field)
        }
        graphSelection = chosen
    }

    private func chartPoints(topic: String, fields: [String]) -> [MQTTChartPoint] {
        guard let series = client.history[topic] else { return [] }
        let shown = Set(fields)
        var points: [MQTTChartPoint] = []
        points.reserveCapacity(series.count * max(shown.count, 1))
        for sample in series {
            for (key, value) in sample.values where shown.contains(key) {
                points.append(MQTTChartPoint(field: key, time: sample.time, value: value))
            }
        }
        return points
    }

    private func samplePointCount(topic: String) -> Int {
        client.history[topic]?.count ?? 0
    }

    /// A **padded** Y-axis domain for the plotted points. Swift Charts renders a
    /// zero-height domain as a blank plot — which is exactly what an automatic
    /// domain produces for a single sample or a constant series (a sensor that
    /// keeps reporting the same number, a status topic, …), so the line/dots
    /// vanish and the graph looks broken. Guaranteeing a non-zero span keeps the
    /// series visible; when the values do vary we just pad the real range a touch
    /// so points aren't flush against the top/bottom edges.
    private func yDomain(for points: [MQTTChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi {
            // Single or constant value: center it with a small margin.
            let pad = Swift.max(abs(lo) * 0.05, 0.5)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.08
        return (lo - pad)...(hi + pad)
    }

    private func fieldChip(_ field: String, selected: Bool) -> some View {
        Text(field)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(selected ? Color.accentColor.opacity(0.25)
                                 : Color.secondary.opacity(0.12),
                        in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
    }

    private var publishPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PUBLISH")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Topic", text: $publishTopic)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            HStack(spacing: 8) {
                TextField("Payload", text: $publishPayload)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Toggle("Retain", isOn: $publishRetain)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button {
                    client.publish(topic: publishTopic, payload: publishPayload, retain: publishRetain)
                } label: {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .disabled(publishTopic.trimmingCharacters(in: .whitespaces).isEmpty || !client.isConnected)
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
                Text("\(client.topics.count) topics · \(client.totalMessages) msgs")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().frame(height: 14)
                Button {
                    client.clear()
                    selectedNodeID = nil
                    expanded.removeAll()
                    seenBranches.removeAll()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.borderless).font(.caption)
                .help("Forget the collected topics")
            }
            Divider().frame(height: 14)
            Button { session.restart() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Reconnect to the broker")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var statusText: String {
        switch client.phase {
        case .idle:               return "Idle"
        case .connecting:         return "Connecting to \(client.host):\(client.port)…"
        case .connected:          return "Connected to \(client.host):\(client.port)"
        case .failed(let m):      return m
        case .ended:              return "Disconnected"
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

    // MARK: - Helpers

    /// Render a payload as pretty JSON when it parses, otherwise as UTF-8 text,
    /// falling back to a hex dump for binary blobs.
    private func prettyPayload(_ data: Data) -> String {
        if data.isEmpty { return "(empty payload)" }
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: pretty, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}

// MARK: - Topic tree model

/// One node in the MQTT topic tree. A node is a single `/`-delimited path
/// segment; it can be a real **topic** (carries a payload), a **branch** (a
/// prefix shared by deeper topics), or both at once.
struct MQTTTreeNode: Identifiable {
    /// The full `/`-joined path — also the topic string for real topics.
    let id: String
    /// The last path segment (what the row shows).
    let name: String
    /// The full topic if this node received a message, else `nil` (pure branch).
    let topic: String?
    let children: [MQTTTreeNode]?
    /// Number of real topics in this subtree (including self).
    let topicCount: Int

    /// Build a sorted tree from a flat list of topic strings.
    static func build(from topics: [String], states: [String: MQTTClient.TopicState]) -> [MQTTTreeNode] {
        let root = Builder(name: "", path: "")
        for topic in topics {
            let segments = topic.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var node = root
            var path = ""
            for segment in segments {
                path = path.isEmpty ? segment : path + "/" + segment
                if let existing = node.children[segment] {
                    node = existing
                } else {
                    let child = Builder(name: segment, path: path)
                    node.children[segment] = child
                    node = child
                }
            }
            node.isTopic = true
        }
        return root.children.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { $0.materialize() }
    }

    /// All branch ids (proper topic prefixes) implied by a set of topics.
    static func branchIDs(for topics: [String]) -> Set<String> {
        var result: Set<String> = []
        for topic in topics {
            let segments = topic.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count > 1 else { continue }
            var path = ""
            for segment in segments.dropLast() {
                path = path.isEmpty ? String(segment) : path + "/" + segment
                result.insert(path)
            }
        }
        return result
    }

    /// Mutable scaffold used while assembling the tree.
    private final class Builder {
        let name: String
        let path: String
        var isTopic = false
        var children: [String: Builder] = [:]
        init(name: String, path: String) { self.name = name; self.path = path }

        func materialize() -> MQTTTreeNode {
            let kids = children.values
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { $0.materialize() }
            let descendantTopics = kids.reduce(0) { $0 + $1.topicCount }
            return MQTTTreeNode(
                id: path,
                name: name,
                topic: isTopic ? path : nil,
                children: kids.isEmpty ? nil : kids,
                topicCount: (isTopic ? 1 : 0) + descendantTopics
            )
        }
    }
}

/// A flattened, indented tree row (what the list actually renders).
struct MQTTTreeRow: Identifiable {
    let node: MQTTTreeNode
    let depth: Int
    var id: String { node.id }
}

// MARK: - Graph models

/// Which face of the topic detail pane is showing.
private enum TopicDetailTab: Hashable { case payload, graph }

/// One plotted point: a single numeric `item` of a topic at a moment in time.
private struct MQTTChartPoint: Identifiable {
    let field: String
    let time: Date
    let value: Double
    /// Stable across redraws so Swift Charts animates instead of rebuilding.
    var id: String { field + "@" + String(time.timeIntervalSince1970) }
}
