import AppKit
import SwiftUI

/// The real bundle icon once it is available, a neutral placeholder until then.
///
/// The icon comes from `IconCache` rather than from `NSWorkspace` in `body`, because a
/// synchronous IconServices read on the main thread is what made the window hang during a
/// fix. See `IconCache`.
struct AppIconView: View {
    @Environment(IconCache.self) private var cache
    let url: URL
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let image = cache.icon(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "app")
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: size, height: size)
    }
}
