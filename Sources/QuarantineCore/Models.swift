import Foundation

public enum QuarantineState: Equatable, Sendable {
    case clean
    case quarantined
    case unreadable(reason: String)
}

public enum SignatureStatus: Equatable, Sendable {
    case notChecked
    case trusted
    case otherCertificate(String)
    case adHoc
    case unsigned
}

/// What a seal check found. Separate from the signature pedigree on purpose: a Developer
/// ID app with a broken seal is refused, and an unsigned app is refused, but for
/// different reasons — and "trusted" alone is not an all-clear, which is exactly the
/// mistake the old `isBlocking` predicate made.
public enum Verification: Equatable, Sendable {
    /// Not checked yet. The dot must not claim anything until the pass has run.
    case unchecked
    /// The background pass is working through the flagged rows.
    case verifying
    /// The seal verifies. Combined with a trusted signature, Gatekeeper serves the app.
    case opensFine
    /// The seal does not verify. Gatekeeper refuses the app while the flag is set.
    case blocked(reason: String)
}

/// The one question a row answers, derived from everything the scan knows.
///
/// There used to be two competing answers — the dot read the flag, and a predicate read
/// the signature — and they disagreed silently. `RowStatus.of` is the single derivation,
/// and it is a pure function so the mapping is pinned by tests rather than by looking.
public enum RowStatus: Equatable, Sendable {
    case clean
    /// Flag set, verdict not in yet. Shown, never claimed.
    case flaggedUnknown
    /// Flag set, seal verifies, signature trusted. Opens without complaint.
    case flaggedFine
    /// Flag set, and either the seal fails or the signature is untrusted.
    case blocked
    case unreadable

    public static func of(_ target: AppTarget) -> RowStatus {
        switch target.state {
        case .unreadable: return .unreadable
        case .clean: return .clean
        case .quarantined: break
        }
        switch target.verification {
        case .blocked: return .blocked
        case .opensFine: return .flaggedFine
        case .unchecked, .verifying: break
        }
        // No verdict yet. An untrusted signature is refused by definition, so it needs
        // no seal check to be called blocked; a trusted one waits for the pass.
        return target.signatureStatus == .trusted ? .flaggedUnknown : .blocked
    }
}

public enum FolderScope: Sendable, Equatable {
    case immediate
    case recursive

    public var label: String {
        switch self {
        case .immediate: return "This folder only"
        case .recursive: return "This folder and everything inside"
        }
    }
}

public struct AppTarget: Identifiable, Equatable, Sendable {
    /// The absolute path is the stable identity: two rows for one bundle are the same row.
    public let id: String
    public let url: URL
    public let name: String
    public let version: String?
    public let state: QuarantineState
    public let quarantinedFileCount: Int
    public let totalFileCount: Int
    public let origin: QuarantineOrigin?
    public let signatureStatus: SignatureStatus
    /// Per-file counts, present only when the bundle was actually walked. A root-only scan
    /// has no total, and saying so beats printing a meaningless ratio.
    public let fileCounts: String?
    /// Seal verdict. Filled in by the background pass after the scan, never during it.
    public let verification: Verification

    public init(id: String, url: URL, name: String, version: String?,
                state: QuarantineState, quarantinedFileCount: Int, totalFileCount: Int,
                origin: QuarantineOrigin?, signatureStatus: SignatureStatus,
                fileCounts: String? = nil, verification: Verification = .unchecked) {
        self.id = id
        self.url = url
        self.name = name
        self.version = version
        self.state = state
        self.quarantinedFileCount = quarantinedFileCount
        self.totalFileCount = totalFileCount
        self.origin = origin
        self.signatureStatus = signatureStatus
        self.fileCounts = fileCounts
        self.verification = verification
    }

    public func withFileCounts(_ inspection: Inspection) -> AppTarget {
        AppTarget(id: id, url: url, name: name, version: version, state: state,
                  quarantinedFileCount: inspection.flagged, totalFileCount: inspection.total,
                  origin: origin, signatureStatus: signatureStatus,
                  fileCounts: "\(inspection.flagged)/\(inspection.total)",
                  verification: verification)
    }

    public func withVerification(_ verification: Verification) -> AppTarget {
        AppTarget(id: id, url: url, name: name, version: version, state: state,
                  quarantinedFileCount: quarantinedFileCount, totalFileCount: totalFileCount,
                  origin: origin, signatureStatus: signatureStatus,
                  fileCounts: fileCounts, verification: verification)
    }

    public var isQuarantined: Bool { state == .quarantined }
}

/// Result of the expensive, exhaustive pass. Only computed on demand — a recursive walk of
/// /Applications touches over 400,000 paths, so it must never run during a scan.
public struct Inspection: Equatable, Sendable {
    public let flagged: Int
    public let total: Int
    public let skipped: Int
    public init(flagged: Int, total: Int, skipped: Int) {
        self.flagged = flagged
        self.total = total
        self.skipped = skipped
    }
}

public struct FileFailure: Equatable, Sendable {
    public let path: String
    public let reason: String
    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ScanResult: Equatable, Sendable {
    public let targets: [AppTarget]
    public let scannedAt: Date
    public let rootLabel: String
    public let skipped: [WalkSkip]
    /// The locations that were handed to the scanner. A rescan reuses these rather than
    /// re-deriving its input from a different route, so discovery stays deterministic.
    public let rootURLs: [URL]

    public init(targets: [AppTarget], scannedAt: Date, rootLabel: String,
                skipped: [WalkSkip], rootURLs: [URL] = []) {
        self.targets = targets
        self.scannedAt = scannedAt
        self.rootLabel = rootLabel
        self.skipped = skipped
        self.rootURLs = rootURLs
    }

    /// Replaces the rows, keeping everything else about the scan. Used when per-file
    /// counts are filled in after a root-only pass.
    public func replacingTargets(_ targets: [AppTarget]) -> ScanResult {
        ScanResult(targets: targets, scannedAt: scannedAt, rootLabel: rootLabel,
                   skipped: skipped, rootURLs: rootURLs)
    }

    /// Every bundle this result covered, which is the correct input to a rescan after a
    /// clear: the bundles exist and are still there, only their flags changed.
    public var coveredURLs: [URL] {
        rootURLs.isEmpty ? targets.map(\.url) : rootURLs
    }
}

/// Scan lifecycle as a single value. There is deliberately no `isScanning` boolean to fall
/// out of sync with a results array, and no way to present stale rows as current: a rescan
/// in flight must be `.scanning(previous:)` and the UI is required to mark those rows stale.
public enum ScanReport: Equatable, Sendable {
    case idle
    case scanning(previous: ScanResult?)
    case loaded(ScanResult)
    case failed(message: String, previous: ScanResult?)

    public var result: ScanResult? {
        switch self {
        case .idle: return nil
        case .scanning(let previous): return previous
        case .loaded(let result): return result
        case .failed(_, let previous): return previous
        }
    }

    public var isBusy: Bool {
        if case .scanning = self { return true }
        return false
    }
}

public struct ClearOutcome: Equatable, Sendable {
    public let path: String
    public let filesVisited: Int
    /// Files that carried the flag when the operation started. For a dry run this is the
    /// number that *would* be affected, which is the only useful thing a dry run can report.
    public let flaggedFiles: Int
    public let attributesRemoved: Int
    public let failures: [FileFailure]
    public let verifiedClean: Bool
    public let verificationFailures: [FileFailure]
    public let dryRun: Bool

    public init(path: String, filesVisited: Int, flaggedFiles: Int, attributesRemoved: Int,
                failures: [FileFailure], verifiedClean: Bool,
                verificationFailures: [FileFailure], dryRun: Bool) {
        self.path = path
        self.filesVisited = filesVisited
        self.flaggedFiles = flaggedFiles
        self.attributesRemoved = attributesRemoved
        self.failures = failures
        self.verifiedClean = verifiedClean
        self.verificationFailures = verificationFailures
        self.dryRun = dryRun
    }

    /// A dry run's contract is "changed nothing", which it always honours, so demanding
    /// `verifiedClean` of one would make every dry run report failure.
    public var isSuccess: Bool {
        failures.isEmpty && verificationFailures.isEmpty && (dryRun || verifiedClean)
    }
}
