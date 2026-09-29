import AppKit
import Observation

/// Bundle icons, loaded once, off the main thread.
///
/// The obvious implementation — `NSWorkspace.shared.icon(forFile:)` directly inside a
/// view's `body` — is a main-thread stall that re-runs on every re-render. It looked fine
/// in testing and then hung the window during a fix, because a fix re-renders the list
/// once per bundle and each render re-read every visible icon through IconServices.
@MainActor
@Observable
final class IconCache {
    private(set) var icons: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func icon(for url: URL) -> NSImage? {
        let path = url.standardizedFileURL.path
        if let cached = icons[path] { return cached }
        request(path)
        return nil
    }

    private func request(_ path: String) {
        guard !inFlight.contains(path) else { return }
        inFlight.insert(path)
        Task.detached(priority: .utility) {
            let image = NSWorkspace.shared.icon(forFile: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.icons[path] = image
                self.inFlight.remove(path)
            }
        }
    }
}
