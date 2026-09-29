import Foundation

/// The one owner of every filesystem mutation. Serialised by an actor so a scan and a clear
/// can never interleave against the same paths.
public actor QuarantineEngine {
    public static let maxConcurrentFixes = 4

    public init() {}

    public func scan(targets: [URL], scope: FolderScope) async -> ScanResult {
        let rows = AppScanner.discover(in: targets, scope: scope).map(AppScanner.state(of:))
        let label = targets.count == 1
            ? targets[0].lastPathComponent
            : "\(targets.count) locations"
        return ScanResult(targets: rows, scannedAt: Date(), rootLabel: label,
                          skipped: [], rootURLs: targets)
    }

    public func clear(_ url: URL, dryRun: Bool = false) async -> ClearOutcome {
        let path = url.standardizedFileURL.path

        // The walk result is the authority for the whole operation. Verification reuses
        // the same traversal rather than re-deriving the file set by another route.
        guard let walk = try? BundleWalker.walk(root: path) else {
            return ClearOutcome(path: path, filesVisited: 0, flaggedFiles: 0,
                                attributesRemoved: 0,
                                failures: [FileFailure(path: path, reason: "Cannot read bundle")],
                                verifiedClean: false, verificationFailures: [], dryRun: dryRun)
        }
        // The walk always reports the root, so an empty bundle is "the root and nothing
        // else". Without this guard a vacuous success would be reported for a bundle that
        // holds no code at all.
        guard walk.paths.count > 1 else {
            return ClearOutcome(path: path, filesVisited: walk.paths.count, flaggedFiles: 0,
                                attributesRemoved: 0,
                                failures: [FileFailure(path: path, reason: "Bundle is empty")],
                                verifiedClean: false, verificationFailures: [], dryRun: dryRun)
        }

        let flagged = walk.paths.filter {
            Xattr.has(attribute: QuarantineAttribute.name, atPath: $0)
        }

        if dryRun {
            return ClearOutcome(path: path, filesVisited: walk.paths.count,
                                flaggedFiles: flagged.count, attributesRemoved: 0,
                                failures: [], verifiedClean: false,
                                verificationFailures: [], dryRun: true)
        }

        var removed = 0
        var failures: [FileFailure] = []
        for filePath in flagged {
            do {
                try Xattr.remove(attribute: QuarantineAttribute.name, atPath: filePath)
                removed += 1
            } catch let error as XattrError {
                // An attribute that vanished between the read and the remove is already
                // clean, which is success, not failure.
                if !error.isNotFound {
                    failures.append(FileFailure(path: filePath, reason: reason(for: error)))
                }
            } catch {
                failures.append(FileFailure(path: filePath, reason: error.localizedDescription))
            }
        }

        // Verify by re-reading the filesystem. The mutation's return value is never trusted
        // as proof: `xattr` reports success and failure identically, and a silent failure
        // would otherwise be reported to the user as "fixed".
        let verificationFailures = (try? BundleWalker.walk(root: path))
            .map { verifyWalk in
                verifyWalk.paths.compactMap { filePath -> FileFailure? in
                    guard Xattr.has(attribute: QuarantineAttribute.name, atPath: filePath)
                    else { return nil }
                    return FileFailure(path: filePath, reason: "Still quarantined after clearing")
                }
            } ?? [FileFailure(path: path, reason: "Verification could not read the bundle")]

        return ClearOutcome(path: path, filesVisited: walk.paths.count,
                            flaggedFiles: flagged.count, attributesRemoved: removed,
                            failures: failures, verifiedClean: verificationFailures.isEmpty,
                            verificationFailures: verificationFailures, dryRun: false)
    }

    /// Bounded fan-out: clearing hundreds of bundles is I/O-bound on one volume, and
    /// unbounded concurrency thrashes the APFS journal.
    ///
    /// `progress` reports (completed, total) as each bundle finishes, so the UI can show a
    /// determinate bar instead of an indeterminate spinner.
    public func clearAll(_ urls: [URL], dryRun: Bool = false,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [ClearOutcome] {
        var outcomes: [ClearOutcome?] = .init(repeating: nil, count: urls.count)
        var cursor = 0

        await withTaskGroup(of: (Int, ClearOutcome).self) { group in
            func enqueue() {
                guard cursor < urls.count else { return }
                let index = cursor
                cursor += 1
                group.addTask { [self] in
                    (index, await clear(urls[index], dryRun: dryRun))
                }
            }
            for _ in 0..<Swift.min(Self.maxConcurrentFixes, max(urls.count, 1)) { enqueue() }
            var completed = 0
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                completed += 1
                progress?(completed, urls.count)
                enqueue()
            }
        }
        return outcomes.compactMap { $0 }
    }

    /// The exhaustive per-file count for one bundle. Never part of a scan: walking every
    /// bundle in /Applications visits hundreds of thousands of paths.
    public func inspect(_ url: URL) -> Inspection {
        AppScanner.inspect(url)
    }

    /// Checks the seal of every flagged row, reporting each verdict as it lands so the UI
    /// updates progressively instead of after one long wait.
    ///
    /// Bounded like `clearAll` for the same reason: seal checks are I/O-bound, and an
    /// unbounded fan-out over dozens of bundles thrashes the volume they share.
    public func verify(_ targets: [AppTarget],
                       onVerdict: @Sendable @escaping (AppTarget, Verification) -> Void) async {
        let flagged = targets.filter(\.isQuarantined)
        guard !flagged.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var cursor = 0
            func enqueue() {
                guard cursor < flagged.count else { return }
                let target = flagged[cursor]
                cursor += 1
                group.addTask {
                    let verdict = SignatureInspector.verify(at: target.url)
                    onVerdict(target, verdict)
                }
            }
            for _ in 0..<Swift.min(Self.maxConcurrentFixes, flagged.count) { enqueue() }
            while await group.next() != nil { enqueue() }
        }
    }

    /// Populated only when the user opens the detail inspector; scanning every bundle up
    /// front would dominate scan time.
    public func signature(of url: URL) -> SignatureStatus {
        SignatureInspector.kind(at: url)
    }

    private func reason(for error: XattrError) -> String {
        switch error {
        case .denied(let path, let code):
            return "Permission denied (errno \(code)): \(path)"
        case .notFound(let path, let code):
            return "Attribute missing (errno \(code)): \(path)"
        case .failed(let path, let operation, let code):
            return "\(operation) failed (errno \(code)): \(path)"
        }
    }
}
