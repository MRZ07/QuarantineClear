import Foundation
import XCTest

@testable import QuarantineCore

final class QuarantineCoreTests: XCTestCase {
    private var fixture: Fixture!

    override func setUp() {
        super.setUp()
        fixture = Fixture()
    }
    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    // MARK: - Walker

    func testWalkIsDeterministic() throws {
        let app = try fixture.app(named: "Alpha")
        let first = try BundleWalker.walk(root: app)
        let second = try BundleWalker.walk(root: app)
        XCTAssertEqual(first.paths, second.paths)
        XCTAssertEqual(first.paths, first.paths.sorted())
    }

    func testWalkIncludesRootAndEveryNestedFile() throws {
        let app = try fixture.app(named: "Alpha")
        let result = try BundleWalker.walk(root: app)
        XCTAssertTrue(result.paths.contains(app))
        XCTAssertTrue(result.paths.contains { $0.hasSuffix("Contents/MacOS/Binary") })
        // Directories are inspected as well: an .app bundle is itself a directory, and the
        // root is the file Gatekeeper actually reads.
        XCTAssertEqual(result.paths.count, 5)
    }

    func testWalkDoesNotFollowSymlinkedDirectory() async throws {
        let app = try fixture.app(named: "Alpha")
        try fixture.plainFile("victim.txt", at: "outside", quarantined: true)
        let link = try fixture.symlink("escape", at: "apps/Alpha.app/Contents/Resources",
                                       to: "outside")

        let result = try BundleWalker.walk(root: app)
        XCTAssertFalse(result.paths.contains { $0.contains("victim.txt") })
        XCTAssertTrue(result.skipped.contains { $0.reason == .symlink(link) },
                      "the symlink is recorded as skipped, never descended into")

        // The out-of-tree victim must survive a clear of the bundle.
        let outcome = await clear(app)
        XCTAssertTrue(outcome.isSuccess)
        let victim = fixture.url("outside/victim.txt").path
        XCTAssertTrue(Xattr.has(attribute: QuarantineAttribute.name, atPath: victim),
                      "recursion escaped the bundle")
    }

    func testWalkStaysWithinBundleWhenBundleItselfIsALink() throws {
        let app = try fixture.app(named: "Alpha")
        let link = URL(fileURLWithPath: rootPath()).appendingPathComponent("link-to-app.app")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(fileURLWithPath: app))
        let result = try BundleWalker.walk(root: link.path)
        XCTAssertEqual(result.paths, [link.path],
                       "a bundle that is a symlink must resolve to the link itself only")
    }

    func testWalkEnforcesMaxDepth() throws {
        let app = try fixture.app(named: "Deep", files: ["A/B/C/D/leaf.txt"])
        let shallow = try BundleWalker.walk(root: app, limits: WalkLimits(maxDepth: 2))
        XCTAssertFalse(shallow.paths.contains { $0.hasSuffix("leaf.txt") })
        XCTAssertTrue(shallow.skipped.contains {
            if case .depthExceeded = $0.reason { return true }
            return false
        })
        let full = try BundleWalker.walk(root: app)
        XCTAssertTrue(full.paths.contains { $0.hasSuffix("leaf.txt") })
    }

    func testWalkReportsUnreadableRoot() throws {
        let missing = fixture.url("nope.app").path
        XCTAssertThrowsError(try BundleWalker.walk(root: missing))
    }

    func testWalkOfPlainFileReturnsThatFile() throws {
        let file = try fixture.plainFile("single.bin", at: "solo")
        let result = try BundleWalker.walk(root: file)
        XCTAssertEqual(result.paths, [file])
    }

    // MARK: - Scanner

    func testScannerFindsAppsAtBothScopes() throws {
        try fixture.app(named: "Top")
        try fixture.nestedApp(named: "Inner", in: "Top")

        let immediate = AppScanner.discover(in: [fixture.url("apps")], scope: .immediate)
        XCTAssertEqual(immediate.map(\.lastPathComponent), ["Top.app"],
                       "a nested helper bundle is not a top-level application")

        // Recursive searches subfolders but does not list bundles nested inside another
        // bundle: it is inside Top.app and is fixed through its parent.
        let recursive = AppScanner.discover(in: [fixture.url("apps")], scope: .recursive)
        XCTAssertEqual(recursive.map(\.lastPathComponent), ["Top.app"])
    }

    /// Regression: recursive discovery searched inside its roots without ever including
    /// them, so a folder reported only its nested helper bundles and dropped every
    /// top-level application.
    func testRecursiveScopeIncludesTopLevelBundles() throws {
        try fixture.app(named: "Top")
        try fixture.nestedApp(named: "Inner", in: "Top")

        let listed = AppScanner.discover(in: [fixture.url("apps")], scope: .recursive)
        XCTAssertEqual(listed.map(\.lastPathComponent), ["Top.app"])
    }

    /// Hiding nested bundles from the list must not hide them from the work: clearing a
    /// parent still has to clear the helper bundles inside it.
    func testClearingParentRemovesFlagsOfNestedHelperBundle() async throws {
        let parent = try fixture.app(named: "Top")
        let helper = try fixture.nestedApp(named: "Inner", in: "Top")
        XCTAssertNotEqual(parent, helper)

        let outcome = await clear(parent)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertFalse(Xattr.has(attribute: QuarantineAttribute.name, atPath: helper),
                       "the nested helper kept its flag")
    }

    /// A bundle the user names or drops directly is never filtered by the nesting rule.
    func testExplicitlyDroppedNestedBundleIsStillListed() throws {
        try fixture.app(named: "Top")
        let helper = try fixture.nestedApp(named: "Inner", in: "Top")

        let dropped = AppScanner.discover(in: [URL(fileURLWithPath: helper)], scope: .recursive)
        XCTAssertEqual(dropped.map(\.path), [helper],
                       "asking for a nested bundle by hand outranks the nesting rule")
    }

    func testNestingKeepsOnlyGenuineTopLevelBundles() {
        let urls = [
            URL(fileURLWithPath: "/Apps/Top.app"),
            URL(fileURLWithPath: "/Apps/Top.app/Contents/Frameworks/Inner.app"),
            URL(fileURLWithPath: "/Apps/TopX.app"),
            URL(fileURLWithPath: "/Apps/Other.app"),
        ]
        let kept = Nesting.topLevel(of: urls)
        XCTAssertEqual(kept.map(\.lastPathComponent).sorted(),
                       ["Other.app", "Top.app", "TopX.app"],
                       "a prefix match must respect the path separator")
    }

    func testScannerIgnoresNonAppEntriesInImmediateScope() throws {
        try fixture.app(named: "Real")
        try fixture.plainFile("notes.txt", at: "apps", quarantined: false)
        let found = AppScanner.discover(in: [fixture.url("apps")], scope: .immediate)
        XCTAssertEqual(found.map(\.lastPathComponent), ["Real.app"])
    }

    func testScannerKeepsAnExplicitlyDroppedBundle() throws {
        let app = try fixture.app(named: "Oddly Named")
        let found = AppScanner.discover(in: [URL(fileURLWithPath: app)], scope: .immediate)
        XCTAssertEqual(found.map(\.path), [app],
                       "an explicitly dropped bundle is kept whatever it is named")
    }

    func testScannerHandlesEmptyFolder() throws {
        let empty = try fixture.emptyDirectory("nothing")
        XCTAssertTrue(AppScanner.discover(in: [URL(fileURLWithPath: empty)], scope: .immediate)
            .isEmpty)
    }

    func testScannerDeduplicatesRepeatedPaths() throws {
        let app = try fixture.app(named: "Dup")
        let url = URL(fileURLWithPath: app)
        XCTAssertEqual(AppScanner.discover(in: [url, url], scope: .immediate).count, 1)
    }

    func testScannerReadsQuarantineFromRootAndNestedFiles() throws {
        let app = try fixture.app(named: "Alpha")
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertEqual(target.state, .quarantined)
        XCTAssertEqual(target.quarantinedFileCount, 1, "the root is the one file that is read")
        // The exhaustive counts live in the separate, on-demand pass.
        let inspection = AppScanner.inspect(URL(fileURLWithPath: app))
        XCTAssertEqual(inspection.flagged, 3, "root plus the two fixture files")
        XCTAssertEqual(inspection.total, 5)
    }

    func testScannerReportsCleanBundleAsClean() throws {
        let app = try fixture.app(named: "Clean", quarantine: false)
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertEqual(target.state, .clean)
        XCTAssertEqual(target.quarantinedFileCount, 0)
    }

    /// The regression this split exists for: the scan must cost one read per bundle, not a
    /// full recursive walk. A scan that walked would take ~31s across /Applications.
    func testStateDoesNotWalkTheBundle() throws {
        let app = try fixture.app(named: "Shallow", files: ["Contents/MacOS/Binary"])
        let start = Date()
        for _ in 0..<200 { _ = AppScanner.state(of: URL(fileURLWithPath: app)) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "200 root reads took \(elapsed)s — the scan is walking again")
    }

    /// A clear must still remove the flag everywhere, including on a bundle whose root is
    /// clean. A fast scan must not have narrowed what a fix is allowed to touch.
    func testClearStillRemovesNestedFlagOnRootCleanBundle() async throws {
        let app = try fixture.app(named: "NestedOnly", files: ["Contents/Info.plist"],
                                  quarantine: false)
        let nested = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Fixture.samplePayload.utf8),
                      atPath: nested.path)
        XCTAssertEqual(AppScanner.state(of: URL(fileURLWithPath: app)).state, .clean)

        let outcome = await clear(app)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertFalse(Xattr.has(attribute: QuarantineAttribute.name, atPath: nested.path))
    }

    func testScannerReportsPartiallyQuarantinedBundle() throws {
        let app = try fixture.app(named: "Partial", files: ["Contents/Info.plist"],
                                  quarantine: false)
        let nested = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        try Xattr.set(attribute: QuarantineAttribute.name, value: Data(Fixture.samplePayload.utf8),
                      atPath: nested.path)
        // A bundle whose root is clean but which has a flagged file inside is reported
        // clean, because that is what Gatekeeper decides on. The nested flag is still
        // reachable through the exhaustive pass, and is removed by a clear.
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertEqual(target.state, .clean)
        let inspection = AppScanner.inspect(URL(fileURLWithPath: app))
        XCTAssertEqual(inspection.flagged, 1)
        XCTAssertEqual(inspection.total, 3, "root, Contents, and Info.plist")
    }

    func testScannerReportsUnreadableTargetWithoutCrashing() {
        let missing = fixture.url("gone.app")
        let target = AppScanner.state(of: missing)
        guard case .unreadable(let reason) = target.state else {
            return XCTFail("a path that does not exist must never be reported as clean")
        }
        XCTAssertTrue(reason.contains("not found"), reason)
    }

    func testScannerExposesOriginFromRootAttribute() throws {
        let app = try fixture.app(named: "FromSafari")
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertEqual(target.origin?.identifier, "https://example.com/App.dmg")
        XCTAssertEqual(target.origin?.agent, "Safari")
    }

    func testScannerNamesBundleFromInfoPlistWhenPresent() throws {
        let app = try fixture.app(named: "Identified", files: ["Contents/Info.plist"])
        let plist = URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist")
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Pretty Name", "CFBundleShortVersionString": "2.1"],
            format: .xml, options: 0)
        try data.write(to: plist)
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertEqual(target.name, "Pretty Name")
        XCTAssertEqual(target.version, "2.1")
    }

    func testScannerSurvivesMalformedInfoPlist() throws {
        let app = try fixture.app(named: "Broken", files: ["Contents/Info.plist"])
        try Data("not a plist at all".utf8).write(
            to: URL(fileURLWithPath: app).appendingPathComponent("Contents/Info.plist"))
        let target = AppScanner.state(of: URL(fileURLWithPath: app))
        XCTAssertNil(target.version, "a malformed plist must yield nil, not a crash")
        XCTAssertEqual(target.state, .quarantined, "the flag itself is still readable")
    }

    // MARK: - Clear

    func testClearRemovesQuarantineFromRootAndNestedFiles() async throws {
        let app = try fixture.app(named: "Alpha")
        let outcome = await clear(app)
        XCTAssertTrue(outcome.isSuccess)
        XCTAssertTrue(outcome.verifiedClean)
        XCTAssertEqual(outcome.attributesRemoved, 3, "root plus the two fixture files")
        for path in try BundleWalker.walk(root: app).paths {
            XCTAssertFalse(Xattr.has(attribute: QuarantineAttribute.name, atPath: path), path)
        }
    }

    func testClearPreservesForeignExtendedAttributes() async throws {
        // Guards the design rule that `xattr -c` must never be used: it would destroy these.
        let app = try fixture.app(named: "WithMacl",
                                  extraXattrs: ["com.apple.macl": "", "com.apple.provenance": "abcd"])
        let outcome = await clear(app)
        XCTAssertTrue(outcome.isSuccess)
        let names = try Xattr.names(atPath: app)
        XCTAssertTrue(names.contains("com.apple.macl"))
        XCTAssertTrue(names.contains("com.apple.provenance"))
        XCTAssertFalse(names.contains(QuarantineAttribute.name))
    }

    func testClearOnAlreadyCleanBundleIsSuccessNotFailure() async throws {
        // The measured /usr/bin/xattr behaviour this test exists for: it exits 1 and prints
        // "No such xattr" for an already-clean file, so a naive wrapper reports a failure.
        let app = try fixture.app(named: "AlreadyClean", quarantine: false)
        let outcome = await clear(app)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.verifiedClean)
        XCTAssertEqual(outcome.attributesRemoved, 0)
        XCTAssertTrue(outcome.isSuccess)
    }

    func testDryRunMutatesNothing() async throws {
        let app = try fixture.app(named: "Untouched")
        let before = try BundleWalker.walk(root: app).paths
            .filter { Xattr.has(attribute: QuarantineAttribute.name, atPath: $0) }.count
        let outcome = await engine().clear(URL(fileURLWithPath: app), dryRun: true)
        XCTAssertTrue(outcome.dryRun)
        XCTAssertEqual(outcome.attributesRemoved, 0)
        XCTAssertEqual(outcome.flaggedFiles, 3, "a dry run reports what it would affect")
        // A dry run can never satisfy `verifiedClean`, because that is the point of it.
        // Without this the CLI would report every dry run as a failure.
        XCTAssertTrue(outcome.isSuccess)
        let after = try BundleWalker.walk(root: app).paths
            .filter { Xattr.has(attribute: QuarantineAttribute.name, atPath: $0) }.count
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, 3, "dry run must leave every attribute in place")
    }

    func testClearFailsLoudlyOnEmptyBundle() async throws {
        let empty = try fixture.emptyDirectory("Empty.app")
        let outcome = await clear(empty)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertEqual(outcome.failures.first?.reason, "Bundle is empty")
    }

    func testClearFailsLoudlyOnMissingBundle() async throws {
        let outcome = await clear(fixture.url("nope.app").path)
        XCTAssertFalse(outcome.isSuccess)
        XCTAssertFalse(outcome.verifiedClean)
    }

    func testClearAllVisitsEachFileExactlyOnce() async throws {
        var apps: [URL] = []
        for index in 0..<20 {
            apps.append(URL(fileURLWithPath: try fixture.app(named: "App\(index)")))
        }
        let outcomes = await engine().clearAll(apps)
        XCTAssertEqual(outcomes.count, 20)
        XCTAssertTrue(outcomes.allSatisfy(\.isSuccess))
        XCTAssertEqual(outcomes.reduce(0) { $0 + $1.filesVisited }, 100,
                       "20 bundles of 5 paths each, each visited exactly once")
        XCTAssertEqual(outcomes.reduce(0) { $0 + $1.attributesRemoved }, 60)
        XCTAssertEqual(outcomes.map(\.path), apps.map(\.path), "results keep input order")
    }

    func testClearAllOnEmptyInputReturnsNothing() async {
        let outcomes = await engine().clearAll([])
        XCTAssertTrue(outcomes.isEmpty)
    }

    // MARK: - Payload parser

    func testPayloadParserReadsAWellFormedValue() throws {
        let origin = try XCTUnwrap(
            QuarantinePayloadParser.parse(Data(Fixture.samplePayload.utf8)))
        XCTAssertEqual(origin.identifier, "https://example.com/App.dmg")
        XCTAssertEqual(origin.agent, "Safari")
        XCTAssertEqual(origin.kind, .url)
        XCTAssertNotNil(origin.timestamp)
        XCTAssertEqual(origin.raw, Fixture.samplePayload)
    }

    func testPayloadParserToleratesMissingIdentifier() throws {
        let origin = try XCTUnwrap(
            QuarantinePayloadParser.parse(Data("0083;68f5a0c0;Safari;7C7C;".utf8)))
        XCTAssertNil(origin.identifier, "a missing field must not be invented")
        XCTAssertEqual(origin.agent, "Safari")
    }

    func testPayloadParserReturnsNilForGarbageWithoutFabricatingAURL() throws {
        for garbage in ["not;a;payload", "", "x"] {
            let origin = QuarantinePayloadParser.parse(Data(garbage.utf8))
            if garbage == "not;a;payload" {
                // Three fields is still a real shape, so it parses but yields no URL.
                XCTAssertNil(origin?.identifier, garbage)
                XCTAssertEqual(origin?.raw, garbage)
            } else {
                XCTAssertNil(origin, garbage)
            }
        }
    }

    func testPayloadParserClassifiesKinds() throws {
        func kind(_ value: String) -> QuarantineKind? {
            QuarantinePayloadParser.parse(Data(value.utf8))?.kind
        }
        // A trailing empty field is a real shape, so it parses with no origin at all.
        XCTAssertEqual(kind("0083;68f5a0c0;Safari;7C7C;"), QuarantineKind.none)
        XCTAssertEqual(kind("0083;68f5a0c0;Safari;7C7C;https://a"), .url)
        XCTAssertEqual(kind("0083;68f5a0c0;Safari;7C7C;/tmp/a"), .filePath)
    }

    // MARK: - Xattr

    func testXattrNamesRoundTrip() throws {
        let file = try fixture.plainFile("attrs.bin", at: "solo", quarantined: false)
        try Xattr.set(attribute: "test.one", value: Data("1".utf8), atPath: file)
        try Xattr.set(attribute: "test.two", value: Data("2".utf8), atPath: file)

        let names = try Xattr.names(atPath: file)
        XCTAssertTrue(names.contains("test.one"))
        XCTAssertTrue(names.contains("test.two"))

        XCTAssertEqual(try Xattr.value(atPath: file, attribute: "test.one"), Data("1".utf8))
        try Xattr.remove(attribute: "test.one", atPath: file)
        XCTAssertFalse(try Xattr.names(atPath: file).contains("test.one"))
        XCTAssertTrue(try Xattr.names(atPath: file).contains("test.two"))
    }

    func testXattrRemoveThrowsNotFoundForAbsentAttribute() throws {
        let file = try fixture.plainFile("plain.bin", at: "solo", quarantined: false)
        XCTAssertThrowsError(try Xattr.remove(attribute: QuarantineAttribute.name, atPath: file)) {
            guard case XattrError.notFound = $0 else {
                return XCTFail("expected notFound, got \($0)")
            }
        }
        XCTAssertFalse(Xattr.has(attribute: QuarantineAttribute.name, atPath: file))
    }

    func testXattrValueThrowsNotFoundForAbsentAttribute() throws {
        let file = try fixture.plainFile("plain.bin", at: "solo", quarantined: false)
        XCTAssertThrowsError(try Xattr.value(atPath: file, attribute: "test.absent"))
    }

    func testXattrNamesOnMissingPathReportsFailure() {
        XCTAssertThrowsError(try Xattr.names(atPath: fixture.url("gone.bin").path))
    }

    func testXattrDoesNotFollowSymlinkWhenReading() throws {
        let target = try fixture.plainFile("target.txt", at: "solo", quarantined: true)
        let link = URL(fileURLWithPath: rootPath()).appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link,
                                                   withDestinationURL: URL(fileURLWithPath: target))
        // The link itself carries nothing, and NOFOLLOW must not borrow the target's value.
        XCTAssertFalse(Xattr.has(attribute: QuarantineAttribute.name, atPath: link.path))
    }

    // MARK: - ScanReport

    func testScanReportNeverPresentsStaleResultsAsCurrent() {
        let result = ScanResult(targets: [], scannedAt: Date(), rootLabel: "x", skipped: [])
        let scanning = ScanReport.scanning(previous: result)
        XCTAssertTrue(scanning.isBusy)
        XCTAssertEqual(scanning.result, result, "previous rows are retained but the case is .scanning")
        XCTAssertEqual(ScanReport.loaded(result).isBusy, false)
        XCTAssertEqual(ScanReport.failed(message: "x", previous: result).isBusy, false)
        XCTAssertNil(ScanReport.idle.result)
    }

    // MARK: - Helpers

    private func rootPath() -> String { fixture.root.path }

    private func engine() -> QuarantineEngine { QuarantineEngine() }

    private func clear(_ path: String) async -> ClearOutcome {
        await engine().clear(URL(fileURLWithPath: path))
    }
}

// MARK: - Gatekeeper

final class GatekeeperAssessorTests: XCTestCase {
    /// The classification this project got wrong: without kSecCSSigningInformation the
    /// certificate list is absent and every app looks ad-hoc signed.
    func testReadsRealCertificateChain() throws {
        let trust = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        guard FileManager.default.fileExists(atPath: trust.path) else {
            throw XCTSkip("no system app to inspect")
        }
        XCTAssertEqual(SignatureInspector.kind(at: trust), .trusted)
    }

    func testReportsUnsignedForSomethingUnsigned() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-bundle-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(SignatureInspector.kind(at: directory), .unsigned)
    }

    /// A freshly created directory has no signature and is not a bundle, so the assessor
    /// reports a refusal rather than inventing a pass.
    func testAssessorRefusesAnUnsignedDirectory() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gk-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let verdict = GatekeeperAssessor.assess(bundleAt: directory)
        switch verdict {
        case .accepted:
            XCTFail("an unsigned directory must not be reported as accepted")
        case .rejected, .unavailable:
            break
        }
    }

    func testVerdictSummaryIsNeverEmpty() {
        for verdict in [GatekeeperAssessor.Verdict.accepted(source: "Notarized Developer ID"),
                        .accepted(source: ""),
                        .rejected(reason: "no usable signature"),
                        .unavailable("spctl missing")] {
            XCTAssertFalse(verdict.summary.isEmpty)
        }
    }
}

// MARK: - Merge

/// A fix used to re-run the whole recursive discovery, putting a multi-second scan in
/// front of the user for bundles they had just finished with. Rows that were acted on are
/// replaced from a fresh read; the rest of the scan is left alone.
final class MergeTests: XCTestCase {
    func testFreshReadReplacesOnlyTheClearedRows() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fixed = try fixture.app(named: "Fixed")
        let untouched = try fixture.app(named: "Untouched")

        let before = ScanResult(
            targets: [AppScanner.state(of: URL(fileURLWithPath: fixed)),
                      AppScanner.state(of: URL(fileURLWithPath: untouched))],
            scannedAt: Date(), rootLabel: "test", skipped: [], rootURLs: [])
        XCTAssertEqual(before.targets.filter(\.isQuarantined).count, 2)

        let outcome = await QuarantineEngine().clear(URL(fileURLWithPath: fixed))
        XCTAssertTrue(outcome.isSuccess)

        let after = ScanResult(
            targets: [AppScanner.state(of: URL(fileURLWithPath: fixed))],
            scannedAt: Date(), rootLabel: "test", skipped: [], rootURLs: [])
        let fresh = Dictionary(after.targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let merged = before.targets.map { row in
            fresh[row.id] ?? row
        }

        let stillFlagged = merged.filter { $0.isQuarantined }.map(\.name)
        XCTAssertEqual(stillFlagged, ["Untouched"])
        XCTAssertEqual(merged.count, 2, "the row that was not acted on must survive")
    }
}

// MARK: - RowStatus

/// The mapping the dot renders. Every branch is pinned here because the previous version
/// of this mapping — "orange means the flag is present" — was wrong for 54 of 58 apps.
final class RowStatusTests: XCTestCase {
    private func row(state: QuarantineState = .quarantined,
                     signature: SignatureStatus = .trusted,
                     verification: Verification = .unchecked) -> AppTarget {
        AppTarget(id: "/x", url: URL(fileURLWithPath: "/x"), name: "x", version: nil,
                  state: state, quarantinedFileCount: 1, totalFileCount: 1,
                  origin: nil, signatureStatus: signature, verification: verification)
    }

    func testUnreadableAndCleanIgnoreEverythingElse() {
        XCTAssertEqual(RowStatus.of(row(state: .unreadable(reason: "x"),
                                        verification: .blocked(reason: "x"))), .unreadable)
        XCTAssertEqual(RowStatus.of(row(state: .clean,
                                        verification: .blocked(reason: "x"))), .clean)
    }

    func testBlockedVerdictWinsOverATrustedSignature() {
        // Bionic.app: Developer ID signature, broken seal, refused by Gatekeeper.
        XCTAssertEqual(RowStatus.of(row(signature: .trusted,
                                        verification: .blocked(reason: "x"))), .blocked)
    }

    func testTrustedAndVerifiedMeansOpensFine() {
        XCTAssertEqual(RowStatus.of(row(signature: .trusted,
                                        verification: .opensFine)), .flaggedFine)
    }

    func testUntrustedNeedsNoSealCheckToBeCalledBlocked() {
        // An unsigned or ad-hoc flagged app is refused by definition; waiting for a
        // check that can only confirm it would leave the dot lying in the meantime.
        for signature in [SignatureStatus.adHoc, .unsigned,
                          .otherCertificate("x"), .notChecked] {
            XCTAssertEqual(RowStatus.of(row(signature: signature,
                                            verification: .unchecked)), .blocked, "\(signature)")
            XCTAssertEqual(RowStatus.of(row(signature: signature,
                                            verification: .verifying)), .blocked, "\(signature)")
        }
    }

    func testTrustedWithoutAVerdictStaysUnknown() {
        // A filled dot here would claim a verdict that does not exist yet.
        XCTAssertEqual(RowStatus.of(row(signature: .trusted,
                                        verification: .unchecked)), .flaggedUnknown)
        XCTAssertEqual(RowStatus.of(row(signature: .trusted,
                                        verification: .verifying)), .flaggedUnknown)
    }

    func testWithVerificationPreservesTheRow() {
        let original = row()
        let updated = original.withVerification(.opensFine)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.name, original.name)
        XCTAssertEqual(updated.signatureStatus, original.signatureStatus)
        XCTAssertEqual(updated.verification, .opensFine)
        XCTAssertEqual(RowStatus.of(updated), .flaggedFine)
    }
}

// MARK: - Verification

final class VerificationTests: XCTestCase {
    /// Fixture bundles are unsigned, so the seal check must refuse them. This is the one
    /// branch of the predictor a hermetic test can exercise; the trusted branches are
    /// pinned against live measurements in the commit, not here.
    func testUnsignedBundleIsBlocked() throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = try fixture.app(named: "Unsigned")
        let verdict = SignatureInspector.verify(at: URL(fileURLWithPath: path))
        guard case .blocked = verdict else {
            return XCTFail("an unsigned bundle must verify as blocked, got \(verdict)")
        }
    }

    func testVerifySkipsCleanRows() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let clean = try fixture.app(named: "Clean", quarantine: false)
        let engine = QuarantineEngine()
        let result = await engine.scan(targets: [URL(fileURLWithPath: clean)],
                                       scope: .immediate)
        let box = VerdictBox()
        await engine.verify(result.targets) { target, verdict in
            box.append(target.withVerification(verdict))
        }
        XCTAssertEqual(box.rows.count, 0, "clean rows have nothing to check")
    }

    func testVerifyReportsEveryFlaggedRow() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let one = try fixture.app(named: "One")
        let two = try fixture.app(named: "Two")
        let engine = QuarantineEngine()
        let result = await engine.scan(targets: [URL(fileURLWithPath: one),
                                                 URL(fileURLWithPath: two)],
                                       scope: .immediate)
        let box = VerdictBox()
        await engine.verify(result.targets) { target, verdict in
            box.append(target.withVerification(verdict))
        }
        let rows = box.rows
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { RowStatus.of($0) == .blocked },
                      "unsigned fixtures must all verify as blocked")
    }
}

/// Lock-guarded box: verdicts land from worker threads, so a bare captured array
/// would be the same data race the drop handler and the parallel finder had.
private final class VerdictBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppTarget] = []
    func append(_ row: AppTarget) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(row)
    }
    var rows: [AppTarget] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
