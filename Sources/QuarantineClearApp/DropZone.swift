import SwiftUI
import UniformTypeIdentifiers

/// Window-wide drop target.
///
/// Uses `onDrop` with the raw `NSItemProvider` list rather than `dropDestination(for:)`.
/// The typed variant negotiates a `URL` round trip that Finder file drags do not always
/// satisfy, and it silently drops the payload when the target view swallows the drag —
/// which a `List` full of rows and a row of link buttons both do.
struct DropZone: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL], isTargeted: Bindable(model).isDropTargeted) {
                providers in
                handle(providers)
            }
            .overlay {
                if model.isDropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.accentColor,
                                      style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.06)))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
    }

    private func handle(_ providers: [NSItemProvider]) -> Bool {
        // `loadObject` completes on an arbitrary queue, so the accumulator is shared state
        // and must be guarded. Without the lock two completions can race and lose a drop.
        let collected = Collector()
        let group = DispatchGroup()

        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { collected.append(url) }
                group.leave()
            }
        }

        // A provider that never calls back must not wedge the window.
        guard group.wait(timeout: .now() + 5) == .success else { return false }
        let urls = collected.urls
        guard !urls.isEmpty else { return false }
        model.acceptDrop(urls)
        return true
    }
}

/// Minimal guarded box. `NSLock` rather than an actor, because the drop handler has to
/// collect synchronously before it can return.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(url)
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

extension View {
    func dropZone() -> some View { modifier(DropZone()) }
}
