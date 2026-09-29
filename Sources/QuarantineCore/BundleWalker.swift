import Darwin
import Foundation

public struct WalkLimits: Sendable {
    public var maxDepth: Int
    public init(maxDepth: Int = 64) { self.maxDepth = maxDepth }
}

public struct WalkSkip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case symlink(String)
        case otherDevice(String)
        case unreadable(path: String, errno: Int32)
        case depthExceeded(String)
    }
    public let reason: Reason
    public init(reason: Reason) { self.reason = reason }
}

public struct WalkResult: Equatable, Sendable {
    public let paths: [String]
    public let skipped: [WalkSkip]
    public init(paths: [String], skipped: [WalkSkip]) {
        self.paths = paths
        self.skipped = skipped
    }
}

public enum BundleWalkerError: Error, Equatable, Sendable {
    case rootUnreadable(path: String, errno: Int32)
}

/// Deterministic, symlink-safe recursive traversal.
///
/// Three invariants matter and are covered by tests:
///   * `lstat` only. A symlink is recorded in `skipped` and never descended into, so a
///     crafted bundle cannot redirect the walk at files outside itself.
///   * Everything stays on the root's device. A mount point inside an app bundle is never
///     legitimate and is an escape vector.
///   * Output order is pre-order sorted, so two scans of one tree are byte-identical.
public enum BundleWalker {
    public static func walk(root: String, limits: WalkLimits = WalkLimits()) throws -> WalkResult {
        var rootStat = Darwin.stat()
        guard lstat(root, &rootStat) == 0 else {
            throw BundleWalkerError.rootUnreadable(path: root, errno: errno)
        }
        guard isDirectory(rootStat) else {
            return WalkResult(paths: [root], skipped: [])
        }

        // The root itself is in scope. An .app bundle is a directory, and its root is
        // exactly the file Gatekeeper reads, so omitting it would miss the attribute that
        // matters most while still reporting the bundle as inspected.
        var paths: [String] = [root]
        var skipped: [WalkSkip] = []
        var visitedDevice = rootStat.st_dev
        paths.reserveCapacity(256)
        descend(root, depth: 0, limits: limits, device: visitedDevice,
                paths: &paths, skipped: &skipped)
        paths.sort()
        return WalkResult(paths: paths, skipped: skipped)
    }

    private static func descend(_ directory: String, depth: Int, limits: WalkLimits,
                                device: dev_t, paths: inout [String],
                                skipped: inout [WalkSkip]) {
        guard depth <= limits.maxDepth else {
            skipped.append(WalkSkip(reason: .depthExceeded(directory)))
            return
        }
        let entries = directoryEntries(at: directory)
        guard let entries else {
            skipped.append(WalkSkip(reason: .unreadable(path: directory, errno: errno)))
            return
        }

        for name in entries {
            let path = (directory as NSString).appendingPathComponent(name)

            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else {
                // One file vanishing mid-scan must not abort the whole traversal.
                skipped.append(WalkSkip(reason: .unreadable(path: path, errno: errno)))
                continue
            }
            if isSymbolicLink(info) {
                skipped.append(WalkSkip(reason: .symlink(path)))
                continue
            }
            if info.st_dev != device {
                skipped.append(WalkSkip(reason: .otherDevice(path)))
                continue
            }

            paths.append(path)
            if isDirectory(info) {
                descend(path, depth: depth + 1, limits: limits, device: device,
                        paths: &paths, skipped: &skipped)
            }
        }
    }

    private static func directoryEntries(at path: String) -> [String]? {
        guard let handle = opendir(path) else { return nil }
        defer { closedir(handle) }

        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> String in
                let bytes = raw.prefix(while: { $0 != 0 })
                return String(decoding: bytes, as: UTF8.self)
            }
            guard name != ".", name != ".." else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    private static func isSymbolicLink(_ info: Darwin.stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFLNK
    }
    private static func isDirectory(_ info: Darwin.stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFDIR
    }
}
