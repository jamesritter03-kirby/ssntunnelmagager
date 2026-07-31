import SwiftUI
import Charts

/// One timestamped set of numeric readings feeding a live graph.
struct NumericGraphSample {
    let time: Date
    let values: [String: Double]
}

/// A live line graph shared by the MQTT and Redis tabs: chips toggle each numeric
/// series, and a **Stack** switch splits the selected series into individually
/// auto-scaled charts stacked vertically instead of sharing one axis.
struct NumericSeriesGraph: View {
    let samples: [NumericGraphSample]
    /// The series the user has chosen to plot; owned by the caller so it survives
    /// this view being torn down and rebuilt.
    @Binding var selection: Set<String>
    @Binding var stack: Bool
    var emptyTitle: String = "Nothing to graph yet"
    var emptyMessage: String

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
                if fields.count > 1 {
                    HStack(spacing: 8) {
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
                        Toggle("Stack", isOn: $stack)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Give each series its own stacked chart")
                    }
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
}

/// One plotted point: a single numeric series at a moment in time.
private struct SeriesPoint: Identifiable {
    let field: String
    let time: Date
    let value: Double
    /// Stable across redraws so Swift Charts animates instead of rebuilding.
    var id: String { field + "@" + String(time.timeIntervalSince1970) }
}
