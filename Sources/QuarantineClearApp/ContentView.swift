import AppKit
import QuarantineCore
import SwiftUI

/// One window, one list, one action bar. No sidebar, no split view, no toolbar.
///
/// The chrome is deliberately almost empty: a list of apps, a count, and a single button
/// whose title states exactly what it will do. Everything else is a text link.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasScanned, !model.isBusy {
                emptyState
            } else {
                list
            }
            Divider()
            actionBar
        }
        .frame(minWidth: 560, minHeight: 380)
        .dropZone()
        .searchable(text: Bindable(model).searchText, placement: .toolbar,
                    prompt: "Filter by name")
        .task { model.loadDefaultFolderIfNeeded() }
        // Selecting a row is what opens it. Ties expansion to the selection the list
        // already owns, so the detail needs no extra control of its own.
        .onChange(of: model.selection) { _, selection in
            model.expandedID = selection.count == 1 ? selection.first : nil
        }
        .navigationTitle("")
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 18) {
            AppMark()

            VStack(spacing: 6) {
                Text("Drop apps or a folder here")
                    .font(.system(size: 17, weight: .medium))
                Text("Lists apps carrying the quarantine flag, and removes it. Open a row to "
                 + "ask Gatekeeper whether it would actually be refused.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Button("Scan Applications") { model.scanApplications() }
                Button("Choose Folder…") { model.chooseFolder() }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    /// Bound up front so the row can carry them into a detached task without dragging a
    /// main-actor reference along.
    private let inspect: @Sendable (AppTarget) -> Inspection = { target in
        AppModel.inspectShared(target)
    }

    private let assess: @Sendable (AppTarget) -> GatekeeperAssessor.Verdict = { target in
        GatekeeperAssessor.assess(bundleAt: target.url)
    }

    /// Launches the bundle. Fails quietly for a bundle that cannot start, because the row
    /// is about the quarantine flag and not about diagnosing broken software.
    private let openApp: @Sendable (AppTarget) -> Void = { target in
        NSWorkspace.shared.open(target.url)
    }

    @ViewBuilder
    private var list: some View {
        if model.visibleTargets.isEmpty, !model.isBusy {
            nothingMatches
        } else {
        List(selection: Bindable(model).selection) {
            ForEach(model.visibleTargets) { target in
                Row(target: target, isExpanded: model.expandedID == target.id,
                    inspect: inspect, assess: assess, openApp: openApp)
                    .contentShape(Rectangle())
                    .tag(target.id)
                    .contextMenu {
                        Button("Reveal in Finder") { NSWorkspaceBridge.reveal(target.url) }
                        Button("Copy xattr Command") {
                            NSWorkspaceBridge.copy(manualCommand(for: target))
                        }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .disabled(model.isBusy)
        .overlay(alignment: .top) { statusBanner }
        .overlay {
            if model.isBusy, model.fixProgress == nil, !model.isShowingStaleResults {
                scanningOverlay
            }
        }
        }
    }

    private var scanningOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Reading \(model.allTargets.isEmpty ? "your applications" : "attributes")…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    @ViewBuilder
    private var nothingMatches: some View {
        VStack(spacing: 8) {
            Text("Nothing matches")
                .font(.system(size: 15, weight: .medium))
            Text(model.hiddenCount > 0
                 ? "\(model.hiddenCount) app(s) hidden by the current filter"
                 : "No app bundles in this folder")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func manualCommand(for target: AppTarget) -> String {
        QuarantineAttribute.manualCommand(forPath: target.id)
    }

    /// Leads with what is actually stopped. "58 flagged" was the number that kept
    /// looking wrong, because 54 of those apps open without complaint.
    private var countLabel: String {
        var parts: [String] = []
        if model.blockedCount > 0 {
            parts.append("\(model.blockedCount) blocked")
        }
        let fine = model.flaggedCount - model.blockedCount
        if fine > 0 {
            parts.append("\(fine) flagged, open fine")
        }
        if model.verifyingCount > 0 {
            parts.append("checking \(model.verifyingCount)…")
        }
        if parts.isEmpty {
            parts.append(model.flaggedCount > 0 ? "flagged" : "clean")
        }
        var text = parts.joined(separator: " · ") + " · \(model.allTargets.count) apps"
        if model.hiddenCount > 0 {
            text = "\(model.visibleTargets.count) shown · " + text
        }
        return text
    }

    /// A determinate bar while a fix runs, and an indeterminate one only while a scan is in
    /// flight. A spinner that says "Scanning" after a fix finished is worse than no
    /// feedback, because it claims work the user never asked for.
    @ViewBuilder
    private var statusBanner: some View {
        if let progress = model.fixProgress, progress.total > 0 {
            VStack(spacing: 4) {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text("Fixing \(progress.done) of \(progress.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 10)
        } else if model.isBusy {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if model.report.result == nil {
                Text("Nothing scanned")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: 8)

            primaryButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// One button, and its title states precisely what pressing it will do. An ambiguous
    /// label is how a tool like this talks a user into an irreversible action.
    private var primaryButton: some View {
        let selected = model.selectedTargets
        return Button(actionLabel(for: selected)) {
            if selected.isEmpty { model.fixAll() } else { model.fixSelected() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(actionLabel(for: selected).isEmpty || model.isBusy)
        .help(actionLabel(for: selected))
    }

    private func actionLabel(for selected: [AppTarget]) -> String {
        if !selected.isEmpty { return "Fix Selected (\(selected.count))" }
        return model.blockedCount > 0 ? "Fix All (\(model.blockedCount))" : ""
    }
}

/// The app's own mark, drawn rather than loaded so the empty state matches the icon.
private struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.31, green: 0.48, blue: 1.0),
                                              Color(red: 0.13, green: 0.83, blue: 0.93)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
            Image(systemName: "lock.open")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}
