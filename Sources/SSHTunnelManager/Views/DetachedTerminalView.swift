import SwiftUI

/// Contents of a detached terminal window: a slim toolbar (always-on-top pin +
/// re-attach) above the same `TerminalContainer` used in the main window's tabs.
struct DetachedTerminalView: View {
    @ObservedObject var model: DetachedWindowModel
    @ObservedObject private var session: TerminalSession

    init(model: DetachedWindowModel) {
        self.model = model
        _session = ObservedObject(initialValue: model.session)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Image(systemName: session.kind == .ssh ? "network" : "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 12)

                Toggle(isOn: pinBinding) {
                    Image(systemName: model.alwaysOnTop ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .help("Always on top — keep this window above the others")

                Button {
                    model.onReattach()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .help("Re-attach this terminal to the main window")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            TerminalContainer(session: session)
        }
        .frame(minWidth: 420, minHeight: 240)
    }

    /// Toggling the pin updates the model *and* the real window level.
    private var pinBinding: Binding<Bool> {
        Binding(
            get: { model.alwaysOnTop },
            set: { model.alwaysOnTop = $0; model.onSetAlwaysOnTop($0) }
        )
    }

    private var statusColor: Color {
        if session.isRunning { return .green }
        if let code = session.exitCode, code != 0 { return .red }
        return .secondary
    }
}
