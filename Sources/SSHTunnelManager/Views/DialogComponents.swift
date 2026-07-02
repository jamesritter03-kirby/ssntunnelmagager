import SwiftUI

/// A consistent header for the app's sheets and dialogs: a tinted SF Symbol, a
/// title and an optional one-line subtitle, with optional trailing controls and
/// a contextual **?** help button. Used by the profile editor, the new-connection
/// sheets and the ZeroTier browser so every dialog reads as one visual family.
///
/// The caller supplies the surrounding padding, so the same header drops cleanly
/// into both the compact 440-pt connection sheets and the full-size browsers.
struct DialogHeader<Trailing: View>: View {
    private let icon: String
    private let title: String
    private let subtitle: String?
    /// When set, a small circular **?** button appears that opens this help article.
    private let helpArticleID: String?
    private let trailing: Trailing

    init(icon: String,
         title: String,
         subtitle: String? = nil,
         helpArticleID: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.helpArticleID = helpArticleID
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
            if let helpArticleID {
                HelpButton(articleID: helpArticleID)
            }
        }
    }
}

extension DialogHeader where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, helpArticleID: String? = nil) {
        self.init(icon: icon, title: title, subtitle: subtitle,
                  helpArticleID: helpArticleID) { EmptyView() }
    }
}

/// A small circular **?** button that opens a help article — the contextual-help
/// affordance for dialogs. Pass the `id` of a `HelpContent` article.
struct HelpButton: View {
    let articleID: String

    var body: some View {
        Button {
            HelpWindowController.shared.show(.article(articleID))
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 15))
        }
        .buttonStyle(.borderless)
        .help("Open Help for this window")
    }
}

/// A consistent placeholder shown when a list, folder or browser has nothing to
/// display: a tertiary SF Symbol, a title, an optional supporting line and an
/// optional actions area (e.g. a "Clear Filter" button). Routes every empty state
/// through one look (icon size, fonts, colours) instead of the per-view
/// variations that had accumulated.
struct EmptyStateView<Actions: View>: View {
    private let icon: String
    private let title: String
    private let message: String?
    private let actions: Actions

    init(icon: String,
         title: String,
         message: String? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}
