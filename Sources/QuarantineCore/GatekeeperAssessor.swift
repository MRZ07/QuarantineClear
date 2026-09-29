import Foundation

/// Asks Gatekeeper directly whether a bundle would be refused.
///
/// This exists because the cheap signals lie in both directions. A quarantine flag is
/// present on plenty of apps that open without complaint, and a valid code signature is
/// present on Developer ID builds whose notarisation is missing — `spctl` rejects those
/// while `SecStaticCodeCheckValidity` accepts them. Measured over the flagged apps in
/// /Applications: 54 accepted, 4 rejected, which is nothing like what either cheap check
/// predicts.
///
/// It costs roughly 1.7s per bundle, so it is never run for a whole folder. It runs for
/// the one bundle the user is asking about, on demand, and the answer is a fact rather
/// than an estimate.
public enum GatekeeperAssessor {
    public enum Verdict: Equatable, Sendable {
        case accepted(source: String)
        case rejected(reason: String)
        case unavailable(String)

        public var summary: String {
            switch self {
            case .accepted(let source): return "Accepted\(source.isEmpty ? "" : " · \(source)")"
            case .rejected(let reason): return "Rejected · \(reason)"
            case .unavailable(let reason): return "Could not assess · \(reason)"
            }
        }
    }

    private static let assessor = "/usr/sbin/spctl"

    public static func assess(bundleAt url: URL) -> Verdict {
        guard FileManager.default.isExecutableFile(atPath: assessor) else {
            return .unavailable("spctl not found")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: assessor)
        process.arguments = ["--assess", "--type", "execute", "-vv", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return .unavailable(error.localizedDescription)
        }
        // Belt and braces: spctl is fast, but a wedged assessor must not hang the window.
        let deadline = DispatchTime.now() + .seconds(20)
        process.waitUntilExit()
        if DispatchTime.now() > deadline { return .unavailable("timed out") }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus == 0 {
            return .accepted(source: field(named: "source", in: text) ?? "")
        }
        return .rejected(reason: field(named: "reason", in: text)
            ?? (trimmed.isEmpty ? "refused by Gatekeeper" : trimmed))
    }

    /// spctl -vv prints one `key=value` per line. Read the named field rather than the
    /// whole blob so the UI shows just the part it wants.
    private static func field(named key: String, in text: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}

extension GatekeeperAssessor.Verdict {
    public var isRejection: Bool {
        if case .rejected = self { return true }
        return false
    }
}
