import Foundation
import QuarantineCore

// `| head` must not kill the process with a signal trace.
signal(SIGPIPE, SIG_IGN)

private let toolName = "quarantine-clear"

/// Usage errors go to stderr so `quarantine-clear scan --json > out.json` stays clean.
private func warn(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private struct Options {
    var command: Command = .help
    var paths: [String] = []
    var scope: FolderScope = .immediate
    var dryRun = false
    var deep = false
    var verifySeals = false
    var json = false

    enum Command { case scan, fix, help, version }
}

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    case scanFailed(String)

    var description: String {
        switch self {
        case .usage(let message), .scanFailed(let message): return message
        }
    }
}

private let usageText = """
\(toolName) — remove the com.apple.quarantine flag from macOS app bundles

USAGE
  \(toolName) scan [--scope immediate|recursive] [--deep] [--verify] [--json] <path>...
  \(toolName) fix [--dry-run] [--json] <path>...
  \(toolName) --help
  \(toolName) --version

COMMANDS
  scan   List app bundles and report which carry the quarantine flag. Mutates nothing.
         Reads the bundle root only, so it is fast; add --deep to walk each bundle and
         report how many files inside it carry the flag.
  fix    Remove the quarantine flag, then re-read the filesystem to verify.

OPTIONS
  --deep              Walk each bundle recursively and report per-file counts. Slower:
                      a full /Applications scan visits hundreds of thousands of paths.
  --verify            Check the seal of every flagged bundle and mark the ones Gatekeeper
                      would actually refuse. Same pass the app runs in the background.
  --scope immediate   Only .app bundles directly inside each folder (default).
  --scope recursive   Every .app bundle anywhere below each folder.
  --dry-run           Report what would change without changing anything.
  --json              Machine-readable output.
  -h, --help          Show this help.
  --version           Show the version.

NOTES
  <path> may be an .app bundle or a folder to search. Folders and bundles can be mixed.
  Quarantine attributes on unrelated files (for example com.apple.macl) are never touched.

EXIT CODES
  0  success
  1  at least one failure, or a result that could not be verified
  2  usage error
  3  scan error
"""

private func parse(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0

    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--help", "-h":
            options.command = .help
            return options
        case "--version":
            options.command = .version
            return options
        case "--json":
            options.json = true
        case "--dry-run":
            options.dryRun = true
        case "--deep":
            options.deep = true
        case "--verify":
            options.verifySeals = true
        case "--scope":
            index += 1
            guard index < arguments.count else {
                throw CLIError.usage("--scope needs a value: immediate or recursive")
            }
            switch arguments[index] {
            case "immediate": options.scope = .immediate
            case "recursive": options.scope = .recursive
            case let other:
                throw CLIError.usage("Unknown --scope value '\(other)'. Use immediate or recursive.")
            }
        default:
            if argument.hasPrefix("-") {
                throw CLIError.usage("Unknown option '\(argument)'.")
            }
            // The first bare word is the subcommand, as documented. Everything after it is
            // a path. Without this the documented form silently fell through to --help.
            if options.command == .help {
                switch argument {
                case "scan": options.command = .scan
                case "fix": options.command = .fix
                default:
                    throw CLIError.usage(
                        "Unknown command '\(argument)'. Expected scan or fix.")
                }
            } else {
                options.paths.append(argument)
            }
        }
        index += 1
    }

    if options.command != .help, options.command != .version, options.paths.isEmpty {
        throw CLIError.usage("No paths given. See \(toolName) --help.")
    }
    return options
}

private func manualCommand(for path: String) -> String {
    QuarantineAttribute.manualCommand(forPath: path)
}

private func printScan(_ result: ScanResult, asJSON: Bool) {
    if asJSON {
        let payload = result.targets.map { target -> [String: Any] in
            var row: [String: Any] = [
                "path": target.id,
                "name": target.name,
                "version": target.version as Any,
                "state": stateLabel(target.state),
                "quarantinedFiles": target.quarantinedFileCount,
                "totalFiles": target.totalFileCount,
            ]
            row["origin"] = target.origin?.identifier
            return row
        }
        print(encoder(payload))
        return
    }

    guard !result.targets.isEmpty else {
        print("No app bundles found in \(result.rootLabel).")
        return
    }
    let nameWidth = result.targets.map(\.name.count).max() ?? 4
    for target in result.targets {
        var line = target.name.padded(to: nameWidth)
        line += "  " + statusLabel(for: target).padded(to: 12)
        // A root-only scan does not walk the bundle, so it has no per-file totals to
        // report. Printing "1/0" would look like a broken measurement rather than an
        // absent one. `quarantine-clear scan --deep` is the way to get counts.
        if let counts = target.fileCounts {
            line += "  " + counts.padded(to: 9)
        } else {
            line += "  " + "-".padded(to: 9)
        }
        line += "  " + (target.origin?.identifier ?? target.id)
        print(line)
    }
    let quarantined = result.targets.filter(\.isQuarantined).count
    let blocked = result.targets.filter { RowStatus.of($0) == .blocked }.count
    let checked = result.targets.contains { $0.verification != .unchecked }
    print("")
    if checked, blocked > 0 {
        print("\(blocked) blocked · \(quarantined - blocked) flagged, open fine · " +
              "\(result.targets.count) in \(result.rootLabel).")
    } else {
        print("\(quarantined) flagged of \(result.targets.count) in \(result.rootLabel).")
    }
}

/// The state column reports the verdict when there is one, and the flag otherwise. A row
/// whose seal was never checked must not read as either fine or blocked.
private func statusLabel(for target: AppTarget) -> String {
    switch RowStatus.of(target) {
    case .blocked: return "BLOCKED"
    case .flaggedFine: return "flagged"
    case .flaggedUnknown: return stateLabel(target.state)
    case .clean, .unreadable: return stateLabel(target.state)
    }
}

private func isUnreadable(_ state: QuarantineState) -> Bool {
    if case .unreadable = state { return true }
    return false
}

private func stateLabel(_ state: QuarantineState) -> String {
    switch state {
    case .clean: return "clean"
    case .quarantined: return "FLAGGED"
    case .unreadable: return "unreadable"
    }
}

private func printOutcome(_ outcome: ClearOutcome) {
    let action = outcome.dryRun ? "would remove" : "removed"
    let head = outcome.dryRun
        ? "DRY RUN  \(outcome.flaggedFiles) of \(outcome.filesVisited) files in \(outcome.path) would be cleared (nothing changed)"
        : "\(action) \(outcome.attributesRemoved) attribute(s) from \(outcome.filesVisited) file(s) in \(outcome.path)"

    if outcome.dryRun {
        print(head)
    } else if outcome.verifiedClean {
        print(head + " — verified clean")
    } else {
        print(head + " — NOT VERIFIED")
    }
    for failure in outcome.failures + outcome.verificationFailures {
        print("  ! \(failure.path): \(failure.reason)")
    }
    if !outcome.dryRun, !outcome.verifiedClean {
        print("  Check manually: \(manualCommand(for: outcome.path))")
    }
}

private func encoder(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

private func run() async -> Int32 {
    let options: Options
    do {
        options = try parse(Array(CommandLine.arguments.dropFirst()))
    } catch {
        warn("\(toolName): \(error)")
        warn("Run \(toolName) --help for usage.")
        return 2
    }

    switch options.command {
    case .help:
        print(usageText)
        return 0
    case .version:
        print("\(toolName) 0.1.0")
        return 0
    case .scan, .fix:
        break
    }

    let engine = QuarantineEngine()
    let urls = options.paths.map { URL(fileURLWithPath: $0) }

    switch options.command {
    case .scan:
        let scanned = await engine.scan(targets: urls, scope: options.scope)
        var rows = scanned.targets
        if options.deep {
            var walked: [AppTarget] = []
            for target in rows {
                walked.append(target.withFileCounts(
                    await engine.inspect(target.url)))
            }
            rows = walked
        }
        if options.verifySeals {
            // Verdicts land from worker threads; the accumulator is locked, not a bare var.
            let collected = VerdictBox()
            await engine.verify(rows) { target, verdict in
                collected.append(target.withVerification(verdict))
            }
            let checked = collected.rows
            rows = scanned.targets.map { row in
                checked.first { $0.id == row.id } ?? row
            }
        }
        let result = scanned.replacingTargets(rows)
        printScan(result, asJSON: options.json)
        return result.targets.contains { isUnreadable($0.state) } ? 1 : 0

    case .fix:
        // Every discovered bundle is cleared, not just the listed ones. A helper bundle
        // hidden from the list is still inside its parent, and the parent's clear walks the
        // whole tree anyway — so this is belt and braces, never a filter.
        let discovered = AppScanner.discover(in: urls, scope: options.scope)
        let outcomes = await engine.clearAll(discovered, dryRun: options.dryRun)
        if options.json {
            print(encoder(outcomes.map(outcomePayload)))
        } else {
            for outcome in outcomes { printOutcome(outcome) }
        }
        // The engine decides success, never the CLI's exit arithmetic, so the terminal and
        // the app can never disagree about what happened.
        return outcomes.allSatisfy(\.isSuccess) ? 0 : 1

    case .help, .version:
        return 0
    }
}

/// Lock-guarded box for verdicts arriving from concurrent workers.
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

private func outcomePayload(_ outcome: ClearOutcome) -> [String: Any] {
    var payload: [String: Any] = [
        "path": outcome.path,
        "filesVisited": outcome.filesVisited,
        "flaggedFiles": outcome.flaggedFiles,
        "attributesRemoved": outcome.attributesRemoved,
        "verifiedClean": outcome.verifiedClean,
        "dryRun": outcome.dryRun,
        "failures": outcome.failures.map { ["path": $0.path, "reason": $0.reason] },
        "verificationFailures": outcome.verificationFailures.map { ["path": $0.path, "reason": $0.reason] },
    ]
    payload["command"] = manualCommand(for: outcome.path)
    return payload
}

exit(await run())
