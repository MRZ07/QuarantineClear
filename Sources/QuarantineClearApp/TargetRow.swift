import QuarantineCore
import SwiftUI

/// One app, one line. Opens on selection to show the per-file detail.
struct Row: View {
    let target: AppTarget
    let isExpanded: Bool
    let inspect: @Sendable (AppTarget) -> Inspection
    let assess: @Sendable (AppTarget) -> GatekeeperAssessor.Verdict
    let openApp: @Sendable (AppTarget) -> Void

    @State private var inspection: Inspection?
    @State private var verdict: GatekeeperAssessor.Verdict?
    @State private var isAssessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line
            if isExpanded {
                detail
                    .padding(.leading, 36)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        // Single click expands; double click launches. Finder's convention, and the reason
        // a list of applications should behave like a list of applications.
        .onTapGesture(count: 2) { openApp(target) }
        .task(id: taskKey) {
            // Fetched only while the row is open. The walk can touch hundreds of thousands
            // of paths, so it runs off the main actor and is cancellable: re-sorting or
            // re-filtering the list while this is in flight must not leave a stale count
            // and must not leave the walk running.
            guard isExpanded else { return }
            let count = await Task.detached(priority: .userInitiated) {
                inspect(target)
            }.value
            guard !Task.isCancelled else { return }
            inspection = count
        }
    }

    /// Re-runs on identity *and* on state, so the count follows the filesystem.
    private var taskKey: String {
        "\\(target.id)|\\(target.quarantinedFileCount)"
    }

    private var line: some View {
        HStack(spacing: 10) {
            AppIconView(url: target.url, size: 26)

            Text(target.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)

            if let version = target.version {
                Text(version)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            Dot(status: RowStatus.of(target))
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let origin = target.origin {
                detailRow("From", origin.identifier ?? origin.raw,
                          mono: origin.identifier == nil)
                if let agent = origin.agent {
                    detailRow("Flagged by", agent, mono: false)
                }
                if let date = origin.timestamp {
                    detailRow("Flagged", date.formatted(date: .abbreviated, time: .shortened),
                              mono: false)
                }
            } else if case .unreadable(let reason) = target.state {
                detailRow("Problem", reason, mono: false)
            } else {
                detailRow("Origin", "no quarantine attribute on this bundle", mono: false)
            }

            signatureRow
            gatekeeperRow

            if let inspection {
                if inspection.total > 0 {
                    detailRow("Files flagged",
                              "\\(inspection.flagged) of \\(inspection.total)", mono: true)
                } else {
                    detailRow("Files", "inspecting…", mono: false)
                }
            }

            HStack(spacing: 12) {
                Button("Reveal") { NSWorkspaceBridge.reveal(target.url) }
                Button("Copy Command") {
                    NSWorkspaceBridge.copy(QuarantineAttribute.manualCommand(forPath: target.id))
                }
            }
            .buttonStyle(.link)
            .font(.caption)
            .padding(.top, 2)
        }
    }

    /// The only honest answer to "will this app actually open", asked on demand.
    ///
    /// Nothing derivable from the quarantine flag or the code signature predicts it: over
    /// the flagged apps in /Applications, the flag is present on 54 apps Gatekeeper accepts
    /// and 4 it rejects, while the signature check accepts the rejected ones. So the tool
    /// asks Gatekeeper rather than guessing, and only for the app actually being asked
    /// about, because it costs about 1.7s.
    @ViewBuilder
    private var gatekeeperRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch verdict {
            case .some(let result):
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Gatekeeper")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(result.summary)
                        .font(.caption)
                        .foregroundStyle(result.isRejection ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            case .none:
                Button("Ask Gatekeeper whether this is blocked") {
                    isAssessing = true
                    // Off the main actor: this blocks on a subprocess for over a second.
                    Task.detached(priority: .userInitiated) {
                        let result = assess(target)
                        await MainActor.run { verdict = result }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(isAssessing)
            }
        }
    }

    @ViewBuilder
    private var signatureRow: some View {
        if target.state == .quarantined {
            detailRow("Signature", signatureText, mono: false)
            detailRow("Status", verificationText, mono: false)
        }
    }

    /// What the background pass found, or that it is still looking. The row never claims
    /// "blocked" or "fine" before the check has run — that claim is the whole bug being
    /// fixed.
    private var verificationText: String {
        switch target.verification {
        case .unchecked, .verifying: return "Checking whether Gatekeeper would refuse it…"
        case .opensFine: return "Opens fine — the flag is inert"
        case .blocked(let reason): return "Would be refused — \(reason)"
        }
    }

    private var signatureText: String {
        switch target.signatureStatus {
        case .trusted: return "Developer ID or App Store — trusted"
        case .adHoc: return "Ad-hoc — no certificate chain"
        case .unsigned: return "Unsigned"
        case .otherCertificate(let detail): return detail
        case .notChecked: return "Not checked"
        }
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }
}

/// A dot that answers one question: is this app actually stopped by its flag?
///
/// It used to answer a different one — "is the flag present" — and painted 58 rows
/// orange on a machine where Gatekeeper refused 2 of them. `RowStatus` is the single
/// derivation now; the dot renders it and nothing else.
struct Dot: View {
    let status: RowStatus

    var body: some View {
        Group {
            switch status {
            case .blocked:
                Circle().fill(Color.orange)
            case .flaggedUnknown:
                // Hollow: present, but the check has not run yet. A filled dot would
                // claim a verdict that does not exist.
                Circle().stroke(Color.secondary, lineWidth: 1.5)
            case .flaggedFine:
                Circle().fill(Color.secondary.opacity(0.6))
            case .clean:
                Circle().fill(Color.green.opacity(0.45))
            case .unreadable:
                Circle().fill(Color.red)
            }
        }
        .frame(width: 7, height: 7)
        .help(label)
    }

    private var label: String {
        switch status {
        case .blocked: return "Blocked — Gatekeeper would refuse this app"
        case .flaggedUnknown: return "Flagged — still checking"
        case .flaggedFine: return "Flagged, but opens fine"
        case .clean: return "No quarantine flag"
        case .unreadable: return "Unreadable"
        }
    }
}
