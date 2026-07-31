import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

/// One timestamped set of numeric readings feeding a live graph.
struct NumericGraphSample {
    let time: Date
    let values: [String: Double]
}

/// A live line graph shared by the MQTT and Redis tabs: chips toggle each numeric
/// series, and a **Stack** switch splits the selected series into individually
/// auto-scaled charts stacked vertically instead of sharing one axis. Also exports
/// the plotted history (CSV / JSON) and the chart itself (PNG, save or copy).
struct NumericSeriesGraph: View {
    let samples: [NumericGraphSample]
    /// The series the user has chosen to plot; owned by the caller so it survives
    /// this view being torn down and rebuilt.
    @Binding var selection: Set<String>
    @Binding var stack: Bool
    var emptyTitle: String = "Nothing to graph yet"
    var emptyMessage: String
    /// A human name for the graphed source (MQTT topic / Redis key), used as the
    /// export title and default filename.
    var exportName: String = "graph"

    /// Numeric series available to graph — the sorted union of keys seen across
    /// the retained samples.
    private var fields: [String] {
        var keys = Set<String>()
        for sample in samples { keys.formUnion(sample.values.keys) }
        return keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        let fields = self.fields
        let shown = plottedFields(fields)
        let points = chartPoints(fields: shown)
        let showSymbols = points.count <= 60   // dots so 1–2 samples are visible
        VStack(alignment: .leading, spacing: 8) {
            if fields.isEmpty {
                emptyState
            } else {
                HStack(spacing: 8) {
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
                    } else {
                        Spacer(minLength: 0)
                    }
                    if fields.count > 1 {
                        Toggle("Stack", isOn: $stack)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Give each series its own stacked chart")
                    }
                    exportMenu(shown: shown)
                }
                if stack && shown.count > 1 {
                    stackedCharts(points: points, fields: shown, showSymbols: showSymbols)
                } else {
                    overlaidChart(points: points, shown: shown, showSymbols: showSymbols)
                }
                Text("\(samples.count) sample\(samples.count == 1 ? "" : "s") · \(shown.count) of \(fields.count) item\(fields.count == 1 ? "" : "s") shown")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Export the plotted series as data or an image.
    private func exportMenu(shown: [String]) -> some View {
        Menu {
            Button { saveChartImage(shown: shown) } label: {
                Label("Save Chart Image…", systemImage: "photo")
            }
            Button { copyChartImage(shown: shown) } label: {
                Label("Copy Chart Image", systemImage: "doc.on.doc")
            }
            Divider()
            Button { exportData(.csv, shown: shown) } label: {
                Label("Export Data as CSV…", systemImage: "tablecells")
            }
            Button { exportData(.json, shown: shown) } label: {
                Label("Export Data as JSON…", systemImage: "curlybraces")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Export this graph’s history or image")
        .disabled(shown.isEmpty || samples.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 32)).foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.callout.weight(.medium))
            Text(emptyMessage)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// All selected series overlaid on a single shared axis.
    private func overlaidChart(points: [SeriesPoint], shown: [String], showSymbols: Bool) -> some View {
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
    }

    /// One chart per series, stacked vertically, each with its own auto-scaled
    /// Y-axis so series with very different ranges stay readable.
    private func stackedCharts(points: [SeriesPoint], fields: [String], showSymbols: Bool) -> some View {
        let byField = Dictionary(grouping: points, by: \.field)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(fields, id: \.self) { field in
                    let seriesPoints = byField[field] ?? []
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Chart {
                            ForEach(seriesPoints) { point in
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
                        .chartYScale(domain: yDomain(for: seriesPoints))
                        .chartLegend(.hidden)
                        .frame(height: 140)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The series actually plotted: the user's picks (intersected with what's
    /// available), or a sensible default before they choose — all of them when
    /// there are only a few, otherwise just the first.
    private func plottedFields(_ available: [String]) -> [String] {
        let chosen = selection.intersection(available)
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
        selection = chosen
    }

    private func chartPoints(fields: [String]) -> [SeriesPoint] {
        let shown = Set(fields)
        var points: [SeriesPoint] = []
        points.reserveCapacity(samples.count * max(shown.count, 1))
        for sample in samples {
            for (key, value) in sample.values where shown.contains(key) {
                points.append(SeriesPoint(field: key, time: sample.time, value: value))
            }
        }
        return points
    }

    /// A **padded** Y-axis domain for the plotted points. Swift Charts renders a
    /// zero-height domain as a blank plot — which is exactly what an automatic
    /// domain produces for a single sample or a constant series, so the line/dots
    /// vanish and the graph looks broken. Guaranteeing a non-zero span keeps the
    /// series visible; when the values do vary we just pad the real range a touch
    /// so points aren't flush against the top/bottom edges.
    private func yDomain(for points: [SeriesPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi {
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

    // MARK: - Export

    private enum DataFormat { case csv, json }

    /// Write the plotted series' full history to a CSV or JSON file.
    private func exportData(_ format: DataFormat, shown: [String]) {
        let fields = shown.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !fields.isEmpty else { return }
        let (ext, type, text): (String, UTType, String) = {
            switch format {
            case .csv:  return ("csv", .commaSeparatedText, csvText(fields: fields))
            case .json: return ("json", .json, jsonText(fields: fields))
            }
        }()
        save(defaultName: "\(sanitizedName)-history.\(ext)", type: type) { url in
            try text.data(using: .utf8)?.write(to: url)
        }
    }

    /// A CSV with an ISO-8601 `Time` column plus one column per plotted series.
    private func csvText(fields: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func escape(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        var lines = [(["Time"] + fields).map(escape).joined(separator: ",")]
        for sample in samples {
            let cells = [formatter.string(from: sample.time)] + fields.map { field in
                sample.values[field].map { formatNumber($0) } ?? ""
            }
            lines.append(cells.map(escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A JSON document describing the graphed source and its sample history.
    private func jsonText(fields: [String]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sampleObjects: [[String: Any]] = samples.map { sample in
            var values: [String: Double] = [:]
            for field in fields where sample.values[field] != nil {
                values[field] = sample.values[field]
            }
            return ["time": formatter.string(from: sample.time), "values": values]
        }
        let root: [String: Any] = [
            "name": exportName,
            "exportedAt": formatter.string(from: Date()),
            "series": fields,
            "samples": sampleObjects,
        ]
        guard let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private func formatNumber(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15
            ? String(Int64(value))
            : String(value)
    }

    /// Render the current chart to a PNG and save it.
    @MainActor private func saveChartImage(shown: [String]) {
        guard let image = renderChartImage(shown: shown) else { return }
        save(defaultName: "\(sanitizedName).png", type: .png) { url in
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: url)
        }
    }

    /// Render the current chart and place it on the pasteboard.
    @MainActor private func copyChartImage(shown: [String]) {
        guard let image = renderChartImage(shown: shown) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    /// Rasterize the plotted chart (respecting the Stack toggle) at a fixed,
    /// print-friendly size for saving or copying.
    @MainActor private func renderChartImage(shown: [String]) -> NSImage? {
        let points = chartPoints(fields: shown)
        guard !points.isEmpty else { return nil }
        let width: CGFloat = 900
        let stacked = stack && shown.count > 1
        let chartHeight: CGFloat = stacked ? CGFloat(shown.count) * 180 : 420
        let content = VStack(alignment: .leading, spacing: 10) {
            Text(exportName)
                .font(.headline)
                .lineLimit(2)
            if stacked {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(shown, id: \.self) { field in
                        let seriesPoints = points.filter { $0.field == field }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field).font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            exportChart(points: seriesPoints, legend: false)
                                .frame(height: 150)
                        }
                    }
                }
            } else {
                exportChart(points: points, legend: shown.count > 1)
                    .frame(height: chartHeight)
            }
            Text("\(samples.count) samples · exported \(Date().formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.nsImage
    }

    /// A scroll-free chart used only for image export.
    private func exportChart(points: [SeriesPoint], legend: Bool) -> some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time),
                         y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.field))
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: yDomain(for: points))
        .chartLegend(legend ? .visible : .hidden)
    }

    /// A filename-safe version of the export name (topic paths carry slashes).
    private var sanitizedName: String {
        let cleaned = exportName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "graph" : cleaned
    }

    /// Present a save panel and hand the chosen URL to `write`.
    private func save(defaultName: String, type: UTType, write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? write(url)
    }
}

/// One plotted point: a single numeric series at a moment in time.
private struct SeriesPoint: Identifiable {
    let field: String
    let time: Date
    let value: Double
    /// Stable across redraws so Swift Charts animates instead of rebuilding.
    var id: String { field + "@" + String(time.timeIntervalSince1970) }
}
