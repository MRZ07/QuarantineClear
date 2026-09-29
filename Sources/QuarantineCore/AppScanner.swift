import Foundation
import UniformTypeIdentifiers

public enum AppScanner {
    public static let appExtension = "app"

    /// Turns dropped URLs into the bundles worth showing. A dropped `.app` is kept as-is; a
    /// dropped folder yields its `*.app` children at the requested scope; anything else is
    /// still kept as an explicit single target rather than silently dropped.
    public static func discover(in urls: [URL], scope: FolderScope) -> [URL] {
        var found: [String: URL] = [:]
        for url in urls {
            let standardized = url.standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path,
                                                 isDirectory: &isDir) else { continue }

            // An .app bundle is a directory, but a dropped bundle is a target in its own
            // right, not a container to enumerate. Treating it as a folder yields nothing.
            if isDir.boolValue, !isBundle(standardized) {
                // Folder contents are filtered: a helper bundle inside another bundle is
                // still scanned and still fixed through its parent, it is just not listed.
                for bundle in Nesting.topLevel(of: bundles(in: standardized, scope: scope)) {
                    found[bundle.standardizedFileURL.path] = bundle.standardizedFileURL
                }
            } else {
                found[standardized.path] = standardized
            }
        }
        return found.values.sorted { displayName(of: $0) < displayName(of: $1) }
    }

    /// `isDirectory` returns `Bool?`, so `(try? …) == true` would compare a `Bool??` and be
    /// permanently false. Bind the optional instead of collapsing it.
    private static func isDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return values.isDirectory ?? false
    }

    /// A bundle is anything macOS packages, not just `*.app`, so a `.plugin` or `.framework`
    /// dropped by the user is still honoured.
    static func isBundle(_ url: URL) -> Bool {
        let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if let type, type.conforms(to: .bundle) { return true }
        return url.pathExtension == appExtension
    }

    private static func bundles(in root: URL, scope: FolderScope) -> [URL] {
        switch scope {
        case .immediate:
            let children = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return children.filter { $0.pathExtension == appExtension }

        case .recursive:
            // Recursive means everything, which is a superset of immediate — not a
            // replacement for it. The top-level bundles are collected directly and the
            // children are searched concurrently, because one worker per top-level entry
            // is the whole speed-up: a 16-21 second single-threaded walk becomes about 3.
            let entries = ((try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                .filter(isDirectory)
            guard !entries.isEmpty else { return [] }
            let top = entries.filter { $0.pathExtension == appExtension }
            return top + NestedBundleFinder.findConcurrently(in: entries)
        }
    }

    /// Reads the bundle root only.
    ///
    /// The root is the file Gatekeeper actually consults, and it is the only read needed to
    /// answer "is this app blocked?". Walking every bundle instead costs 400,000 path visits
    /// and half a minute across /Applications, and its pessimistic answer is worse: a single
    /// flagged file buried in a resource cache would mark an app blocked that macOS opens
    /// without complaint. The exhaustive pass is `inspect(_:)`, run when a row is opened and
    /// as part of every clear.
    public static func state(of url: URL) -> AppTarget {
        let path = url.standardizedFileURL.path
        let name = displayName(of: url)
        let version = bundleVersion(at: url)

        // A path that is not there, or that we cannot read, is unreadable. Reporting it as
        // clean would put a broken row in a list whose whole purpose is telling the truth.
        guard FileManager.default.fileExists(atPath: path) else {
            return unreadable(url: url, path: path, name: name, version: version,
                              reason: "Bundle not found")
        }

        let payload: Data?
        do {
            payload = try Xattr.value(atPath: path, attribute: QuarantineAttribute.name)
        } catch let error as XattrError {
            switch error {
            case .denied:
                return unreadable(url: url, path: path, name: name, version: version,
                                  reason: "Permission denied: \(path)")
            case .notFound:
                payload = nil
            case .failed:
                return unreadable(url: url, path: path, name: name, version: version,
                                  reason: "Unreadable: \(path)")
            }
        } catch {
            return unreadable(url: url, path: path, name: name, version: version,
                              reason: "Unreadable: \(path)")
        }

        return AppTarget(id: path, url: url, name: name, version: version,
                         state: payload != nil ? .quarantined : .clean,
                         quarantinedFileCount: payload != nil ? 1 : 0,
                         totalFileCount: 0,
                         origin: payload.flatMap(QuarantinePayloadParser.parse),
                         signatureStatus: SignatureInspector.kind(at: url))
    }

    private static func unreadable(url: URL, path: String, name: String, version: String?,
                                   reason: String) -> AppTarget {
        AppTarget(id: path, url: url, name: name, version: version,
                  state: .unreadable(reason: reason), quarantinedFileCount: 0,
                  totalFileCount: 0, origin: nil, signatureStatus: .notChecked)
    }

    /// The exhaustive pass: every file in the bundle, with the same traversal the clear
    /// uses. Expensive by construction, so it is only ever called for one bundle at a time.
    public static func inspect(_ url: URL) -> Inspection {
        guard let walk = try? BundleWalker.walk(root: url.standardizedFileURL.path) else {
            return Inspection(flagged: 0, total: 0, skipped: 0)
        }
        let flagged = walk.paths.filter {
            Xattr.has(attribute: QuarantineAttribute.name, atPath: $0)
        }.count
        return Inspection(flagged: flagged, total: walk.paths.count,
                          skipped: walk.skipped.count)
    }

    /// Distinguishes "no flag here" from "we could not read this file". A permission
    /// failure must not be silently reported as clean.
    private static func readError(for path: String) -> XattrError? {
        do {
            _ = try Xattr.value(atPath: path, attribute: QuarantineAttribute.name)
            return nil
        } catch let error as XattrError {
            return error.isNotFound ? nil : error
        } catch {
            return nil
        }
    }

    static func displayName(of url: URL) -> String {
        if let info = bundleInfo(at: url), let name = info["CFBundleName"] as? String,
           !name.isEmpty {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    static func bundleVersion(at url: URL) -> String? {
        bundleInfo(at: url)?["CFBundleShortVersionString"] as? String
    }

    /// Tolerant by design: a malformed or missing `Info.plist` yields `nil`, never a throw.
    static func bundleInfo(at url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
    }
}
