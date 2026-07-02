import SwiftUI
import AppKit

// MARK: - Help content model

/// A block of help content, rendered generically so topics stay easy to author.
enum HelpBlock {
    case paragraph(String)
    case bullets([String])
    case steps([String])
    case tip(String)
    case shortcuts([(String, String)])

    /// Flattened text used for the sidebar search.
    var plainText: String {
        switch self {
        case .paragraph(let s): return s
        case .bullets(let xs), .steps(let xs): return xs.joined(separator: " ")
        case .tip(let s): return s
        case .shortcuts(let rows): return rows.map { "\($0.0) \($0.1)" }.joined(separator: " ")
        }
    }
}

/// One help topic shown in the sidebar.
struct HelpArticle: Identifiable {
    let id: String
    let title: String
    let icon: String
    let blocks: [HelpBlock]

    var searchText: String {
        (title + " " + blocks.map(\.plainText).joined(separator: " ")).lowercased()
    }
}

/// What the Help window is currently showing.
enum HelpSelection: Hashable {
    case article(String)
    case releaseNotes
    case olderVersions
}

// MARK: - Help window root

struct HelpView: View {
    @State private var selection: HelpSelection
    @State private var search = ""

    init(initial: HelpSelection = .article("getting-started")) {
        _selection = State(initialValue: initial)
    }

    private var filteredArticles: [HelpArticle] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpContent.articles }
        return HelpContent.articles.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Guide") {
                    ForEach(filteredArticles) { article in
                        Label(article.title, systemImage: article.icon)
                            .tag(HelpSelection.article(article.id))
                    }
                    if filteredArticles.isEmpty {
                        Text("No topics match “\(search)”.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("About") {
                    Label("Release Notes", systemImage: "doc.text")
                        .tag(HelpSelection.releaseNotes)
                    Label("Download Older Versions", systemImage: "clock.arrow.circlepath")
                        .tag(HelpSelection.olderVersions)
                }
            }
            // `navigationSplitViewColumnWidth` alone is ignored here (a SwiftUI
            // quirk when the sidebar also hosts a `.searchable`), so pin the List's
            // own width to actually widen the column enough for the topic titles.
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            .searchable(text: $search, placement: .sidebar, prompt: "Search help")
        } detail: {
            ScrollView {
                detail
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(28)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .article(let id):
            if let article = HelpContent.articles.first(where: { $0.id == id }) {
                HelpArticleView(article: article)
            } else {
                Text("Select a topic.").foregroundStyle(.secondary)
            }
        case .releaseNotes:
            ReleaseNotesView()
        case .olderVersions:
            OlderVersionsView()
        }
    }
}

// MARK: - Article rendering

private struct HelpArticleView: View {
    let article: HelpArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: article.icon)
                    .font(.title2).foregroundStyle(.tint).frame(width: 30)
                Text(article.title).font(.largeTitle.weight(.bold))
            }
            ForEach(Array(article.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(.init(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
                        Text(.init(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .steps(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").font(.body.weight(.semibold)).foregroundStyle(.tint)
                            .frame(width: 20, alignment: .trailing)
                        Text(.init(item)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .tip(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                Text(.init(text)).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .shortcuts(let rows):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                            .frame(width: 150, alignment: .leading)
                        Text(row.1).font(.callout)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    if i < rows.count - 1 { Divider() }
                }
            }
        }
    }
}

// MARK: - Release notes

private struct ReleaseNotesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Release Notes").font(.largeTitle.weight(.bold))
            Text("You're running **\(ReleaseCatalog.currentShortVersion) (build \(ReleaseCatalog.currentBuild))**.")
                .foregroundStyle(.secondary)
            ForEach(ReleaseCatalog.all) { release in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(release.displayVersion).font(.title3.weight(.semibold))
                        if ReleaseCatalog.isInstalled(release) {
                            Text("Installed").font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        } else if !release.isDownloadable {
                            Text("In development").font(.caption.weight(.semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                        }
                        Spacer()
                        Text(release.date).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(release.highlights, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.tertiary)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Older versions

private struct OlderVersionsView: View {
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Download Older Versions").font(.largeTitle.weight(.bold))
            Text("""
            Normally the app keeps itself up to date automatically. If you need to \
            go back to an earlier build, download its archive below, unzip it, and \
            replace the copy in your Applications folder.
            """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    updater.checkForUpdates()
                } label: {
                    Label("Check for the Latest Version…", systemImage: "arrow.down.circle")
                }
                .disabled(!updater.canCheckForUpdates)
                Button {
                    NSWorkspace.shared.open(ReleaseCatalog.releasesPageURL)
                } label: {
                    Label("All Releases on GitHub", systemImage: "safari")
                }
            }

            Divider()

            ForEach(ReleaseCatalog.olderVersions) { release in
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox")
                        .font(.title3).foregroundStyle(.secondary).frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(release.displayVersion).font(.headline)
                        Text(release.highlights.first ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(release.date).font(.caption).foregroundStyle(.secondary)
                    if let url = release.downloadURL {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Download", systemImage: "arrow.down.circle.fill")
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
            if ReleaseCatalog.olderVersions.isEmpty {
                Text("No older versions are listed.").foregroundStyle(.secondary)
            }

            Label(
                "Downloads are verified by Sparkle's signature only during automatic updates. When installing a manual download, make sure it came from the official GitHub releases page.",
                systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
