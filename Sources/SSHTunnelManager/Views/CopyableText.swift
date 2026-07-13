import SwiftUI

/// A small monospaced text label (an IP address, ID, etc.) that copies itself to
/// the clipboard when clicked, briefly flashing a checkmark for feedback. Used in
/// the Network and ZeroTier browsers so any address is one click to copy.
struct CopyableText: View {
    let text: String
    /// Optional label to copy instead of the shown text (defaults to `text`).
    var copyValue: String?
    var font: Font = .system(.callout, design: .monospaced)

    @State private var copied = false

    var body: some View {
        Button {
            copy()
        } label: {
            HStack(spacing: 4) {
                Text(text).font(font)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(copied ? Color.green : Color.secondary.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied!" : "Click to copy \(copyValue ?? text)")
    }

    private func copy() {
        let value = copyValue ?? text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { copied = false }
        }
    }
}
