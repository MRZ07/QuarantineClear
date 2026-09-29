import Foundation

/// Drops bundles that live inside another discovered bundle.
///
/// A Chromium or Electron app ships hundreds of helper bundles under
/// `Contents/Frameworks`. They carry the same flag as their parent, but they are not
/// things anyone acts on individually: clearing the parent walks its whole tree and
/// removes their flags too. Listing them buries the actual applications under noise.
///
/// They are not excluded from the work, only from the list. A bundle dropped or named
/// directly is never filtered — the user asking for one by hand outranks this heuristic.
public enum Nesting {
    public static func topLevel(of bundles: [URL]) -> [URL] {
        // Shallowest first, so a container is always decided before anything inside it.
        let ordered = bundles
            .map { $0.standardizedFileURL }
            .sorted { $0.pathComponents.count < $1.pathComponents.count }

        var kept: [URL] = []
        var keptPrefixes: [String] = []

        for url in ordered {
            let path = url.path
            // The trailing separator is what stops "…/Foo.app/Bar" matching "…/Foo.appX".
            if keptPrefixes.contains(where: { path.hasPrefix($0) }) { continue }
            kept.append(url)
            keptPrefixes.append(path + "/")
        }
        return kept
    }
}
