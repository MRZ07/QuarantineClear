import AppKit
import Foundation
import Observation
import QuarantineCore

@MainActor
@Observable
final class AppModel {
    /// The single authority for what the user is looking at. There is no separate results
    /// array and no `isScanning` flag that could fall out of sync with it.
    private(set) var report: ScanReport = .idle

    var selection: Set<String> = []
    /// The row currently showing its details. Expansion is per-row and replaces what a
    /// third detail pane would have done, with far less chrome.
    var expandedID: String?
    var searchText = ""
    var isDropTargeted = false
    /// (completed, total) for a fix in flight. Nil when idle, which is what makes the bar
    /// determinate rather than an endless spinner.
    var fixProgress: (done: Int, total: Int)?

    private let engine = QuarantineEngine()
    private var didLoadDefaultFolder = false
    /// Bumps on every new scan. A verification pass merges only into the generation it
    /// started from, so a slow verdict can never land in a newer list.
    private var verificationGeneration = 0

    var allTargets: [AppTarget] { report.result?.targets ?? [] }
    var hasScanned: Bool { report.result != nil }

    /// Filtering is derived, never stored: there is one list and two predicates over it, so
    /// a cached "filtered" array could only ever disagree with the source.
    var visibleTargets: [AppTarget] {
        let list = allTargets
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query)
        }
    }

    /// What a filter is hiding, so the bar can say "3 of 133 shown" instead of pretending
    /// the list is complete.
    var hiddenCount: Int { allTargets.count - visibleTargets.count }

    var selectedTargets: [AppTarget] { allTargets.filter { selection.contains($0.id) } }
    var flaggedCount: Int { allTargets.filter(\.isQuarantined).count }
    var blockedCount: Int { allTargets.filter { RowStatus.of($0) == .blocked }.count }
    var verifyingCount: Int {
        allTargets.filter {
            RowStatus.of($0) == .flaggedUnknown && $0.verification == .verifying
        }.count
    }
    var isBusy: Bool { report.isBusy }
    var isShowingStaleResults: Bool {
        if case .scanning = report { return report.result != nil }
        return false
    }
    var errorMessage: String? {
        if case .failed(let message, _) = report { return message }
        return nil
    }

    // MARK: - Scanning

    /// Always recursive. Nested helper bundles carry the same flag as their parent, and a
    /// parent is cleared through its whole tree anyway, so there is no decision to expose.
    let scope = FolderScope.recursive

    /// Loads /Applications on first appearance so the window is useful the moment it opens.
    func loadDefaultFolderIfNeeded() {
        guard !didLoadDefaultFolder else { return }
        didLoadDefaultFolder = true
        scanApplications()
    }

    func scan(paths: [URL]) {
        guard !paths.isEmpty else { return }
        report = .scanning(previous: report.result)
        Task {
            let result = await engine.scan(targets: paths, scope: scope)
            finishLoading(result)
        }
    }

    /// Everything a finished scan implies: publish it, fix up the selection, and start
    /// the background seal pass over the flagged rows. There is exactly one place a
    /// report lands, so a verdict pass can never be forgotten for a new list.
    private func finishLoading(_ result: ScanResult) {
        report = .loaded(result)
        reconcileSelection(after: result)
        verifyFlagged()
    }

    func scanApplications() {
        scan(paths: [URL(fileURLWithPath: "/Applications", isDirectory: true)])
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder of applications to scan"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(paths: [url])
    }

    /// Dropping while a scan is in flight would report against a half-built list, so drops
    /// are ignored for the duration rather than queued silently.
    func acceptDrop(_ urls: [URL]) {
        guard !isBusy else { return }
        scan(paths: urls)
    }

    // MARK: - Clearing

    func fixSelected() {
        let urls = selectedTargets.filter(\.isQuarantined).map(\.url)
        guard !urls.isEmpty else { return }
        run(clearing: urls)
    }

    /// Removes the flag from every row Gatekeeper would actually refuse. Fixing an inert
    /// flag changes nothing, so it is not swept into a bulk action the user never asked
    /// for. An explicit selection is still honoured for any flagged row — the user naming
    /// it outranks the verdict.
    func fixAll() {
        let urls = allTargets.filter { RowStatus.of($0) == .blocked }.map(\.url)
        guard !urls.isEmpty else { return }
        run(clearing: urls)
    }

    private func run(clearing urls: [URL]) {
        report = .scanning(previous: report.result)
        fixProgress = (0, urls.count)
        let engine = self.engine
        let previous = report.result

        Task { @MainActor in
            // A fix covers the bundles it touched, not the whole disk. Re-running the
            // recursive discovery afterwards put a multi-second scan in front of the user
            // for work they did not ask for; this is a root read per cleared bundle.
            // Coalesce progress. A callback per bundle meant one list re-render per
            // bundle, and each render cost a synchronous icon read per visible row.
            let step = max(1, urls.count / 20)
            let throttle = Throttle(step: step)
            let total = urls.count
            _ = await engine.clearAll(urls, dryRun: false) { done, finished in
                guard throttle.shouldReport(done, total: finished) else { return }
                Task { @MainActor in self.fixProgress = (done, finished) }
            }
            // Belt and braces: the bar always reaches full, whatever the throttle decided.
            self.fixProgress = (total, total)
            report = .scanning(previous: previous)
            let result = await engine.scan(targets: urls, scope: .immediate)
            merge(result, into: previous)
            fixProgress = nil
        }
    }

    /// Checks the seal of every flagged row in the background and merges each verdict as
    /// it lands. Rows update one by one over a few seconds instead of all at once after
    /// one long wait — the scan stays fast and the dots still end up telling the truth.
    private func verifyFlagged() {
        verificationGeneration += 1
        let generation = verificationGeneration
        guard let current = report.result else { return }
        let flagged = current.targets.filter(\.isQuarantined)
        guard !flagged.isEmpty else { return }

        // Mark first, so the UI shows "checking" instead of silently sitting on grey.
        var marking = Dictionary(uniqueKeysWithValues: flagged.map { ($0.id, $0) })
        let marked = current.targets.map { marking.removeValue(forKey: $0.id)?.withVerification(.verifying) ?? $0 }
        report = .loaded(ScanResult(targets: marked, scannedAt: current.scannedAt,
                                    rootLabel: current.rootLabel, skipped: current.skipped,
                                    rootURLs: current.rootURLs))

        Task { @MainActor in
            await engine.verify(flagged) { target, verdict in
                Task { @MainActor in
                    guard generation == self.verificationGeneration,
                          let live = self.report.result else { return }
                    let updated = live.targets.map {
                        $0.id == target.id ? $0.withVerification(verdict) : $0
                    }
                    self.report = .loaded(ScanResult(targets: updated,
                                                     scannedAt: live.scannedAt,
                                                     rootLabel: live.rootLabel,
                                                     skipped: live.skipped,
                                                     rootURLs: live.rootURLs))
                }
            }
        }
    }

    /// Replaces just the rows that were acted on, leaving the rest of the scan untouched.
    /// The replacement values come from a fresh read, so nothing is patched optimistically.
    /// Fresh rows arrive unchecked, so the verification pass restarts for anything still
    /// flagged — a cleared app that somehow kept its flag must not inherit an old all-clear.
    private func merge(_ fresh: ScanResult, into previous: ScanResult?) {
        guard let previous else {
            finishLoading(fresh)
            return
        }
        var byPath = Dictionary(uniqueKeysWithValues: fresh.targets.map { ($0.id, $0) })
        let updated = previous.targets.map { byPath.removeValue(forKey: $0.id) ?? $0 }
        finishLoading(ScanResult(targets: updated, scannedAt: Date(),
                                 rootLabel: previous.rootLabel, skipped: previous.skipped,
                                 rootURLs: previous.rootURLs))
    }

    private func reconcileSelection(after result: ScanResult) {
        let ids = Set(result.targets.map(\.id))
        selection.formIntersection(ids)
        if let expandedID, !ids.contains(expandedID) { self.expandedID = nil }
    }

    // MARK: - On-demand detail

    /// The exhaustive per-file count. Deliberately not part of a scan: walking every bundle
    /// in /Applications costs hundreds of thousands of path visits.
    func inspect(_ target: AppTarget) async -> Inspection {
        await engine.inspect(target.url)
    }

    /// Asks Gatekeeper about one bundle. Roughly 1.7s, so it is never run for a folder.
    /// Sendable statics so a row can run them off the main actor: `GatekeeperAssessor`
    /// blocks on a subprocess for over a second, which would otherwise freeze the window.
    nonisolated static func assessShared(_ target: AppTarget) -> GatekeeperAssessor.Verdict {
        GatekeeperAssessor.assess(bundleAt: target.url)
    }

    nonisolated static func inspectShared(_ target: AppTarget) -> Inspection {
        AppScanner.inspect(target.url)
    }
}

/// Rate-limits progress updates. The callback runs on whichever worker finished, so the
/// bookkeeping is locked rather than captured as a bare `var`.
private final class Throttle: @unchecked Sendable {
    private let lock = NSLock()
    private let step: Int
    private var lastReported = 0

    init(step: Int) { self.step = step }

    func shouldReport(_ done: Int, total: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // The final update is never suppressed, or the bar would stall short of full.
        if done == total, done - lastReported >= step {
            lastReported = done
            return true
        }
        guard done - lastReported >= step else { return false }
        lastReported = done
        return true
    }
}
