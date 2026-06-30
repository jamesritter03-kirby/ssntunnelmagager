import AppKit
import Combine

/// Bridges the open **Profile Editor** sheet (SwiftUI) and the AppKit quit flow
/// so quitting with unsaved profile edits can prompt "Save / Don't Save /
/// Cancel". `ProfileStore` auto-saves committed profiles, so the *only* unsaved
/// state that can exist is a profile editor that's open with pending edits — this
/// coordinator tracks exactly that.
///
/// The confirmation itself is a **SwiftUI** alert (presented by `ContentView`)
/// rather than an AppKit modal run from inside `applicationShouldTerminate`,
/// because running a modal there is unreliable when the quit arrives via an Apple
/// Event (the Dock's *Quit*, `osascript`, etc.). Instead the terminate is
/// cancelled, the SwiftUI alert is shown, and the user's choice re-issues a clean
/// programmatic quit.
final class ProfileEditCoordinator: ObservableObject {
    static let shared = ProfileEditCoordinator()
    private init() {}

    /// True while a profile editor sheet is on screen.
    @Published var isOpen = false
    /// True when the open editor has edits that differ from what was loaded.
    @Published var isDirty = false
    /// True when the open editor's profile is valid enough to save.
    @Published var canSave = false

    /// Drives the SwiftUI "save changes before quitting?" alert in `ContentView`.
    @Published var showQuitConfirmation = false

    /// Set by the coordinator to ask the open editor to commit its edits (run its
    /// normal Save path). The editor watches this and clears it.
    @Published var commitRequested = false

    /// Set just before we re-issue a quit ourselves, so `applicationShouldTerminate`
    /// lets that quit through instead of prompting again.
    private(set) var isForceQuitting = false
    /// True while we're waiting for the editor to finish saving before quitting.
    private var pendingQuitAfterSave = false
    /// Safety valve so a missed editor commit can't strand the quit forever.
    private var saveFallback: DispatchWorkItem?

    /// Whether quitting right now would lose unsaved profile edits.
    var hasUnsavedEdits: Bool { isOpen && isDirty }

    // MARK: - Quit flow

    /// Ask the user (via the SwiftUI alert) whether to save before quitting.
    /// Called from `applicationShouldTerminate` after it cancels the quit.
    func requestQuitConfirmation() {
        showQuitConfirmation = true
    }

    /// "Save" — commit the open editor's edits, then quit once it reports back.
    func saveAndQuit() {
        showQuitConfirmation = false
        pendingQuitAfterSave = true
        commitRequested = true
        // If the editor never reports back (e.g. it was torn down), quit anyway
        // after a short grace period so we don't strand the user.
        let work = DispatchWorkItem { [weak self] in self?.finishPendingSaveQuit() }
        saveFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// "Don't Save" — discard the pending edits and quit.
    func discardAndQuit() {
        showQuitConfirmation = false
        isDirty = false          // so the re-issued quit doesn't prompt again
        performCleanQuit()
    }

    /// "Cancel" — abandon the quit and leave the editor open.
    func cancelQuit() {
        showQuitConfirmation = false
    }

    /// Called by the editor once it has finished committing the edits a pending
    /// quit was waiting on.
    func editorDidFinishCommit() {
        finishPendingSaveQuit()
    }

    private func finishPendingSaveQuit() {
        saveFallback?.cancel()
        saveFallback = nil
        guard pendingQuitAfterSave else { return }
        pendingQuitAfterSave = false
        performCleanQuit()
    }

    /// Re-issue the quit, this time letting it through without prompting.
    private func performCleanQuit() {
        isForceQuitting = true
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
