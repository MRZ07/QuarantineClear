import AppKit

/// The two AppKit calls the UI needs, in one place, so no view reaches for AppKit directly.
enum NSWorkspaceBridge {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
