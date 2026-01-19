import SwiftUI

struct IntegrityRepairPrompt: View {
    let summary: IntegrityReportSummary
    let isProcessing: Bool
    let onRepair: () -> Void
    let onContinue: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Data Integrity Issues Detected")
                    .font(.title2.weight(.semibold))
                Text("We found stored data issues that can cause crashes when rebuilding snapshots.")
                    .foregroundStyle(.secondary)
            }

            summarySection

            HStack(spacing: 12) {
                Button("Quit") { onQuit() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isProcessing)

                Button("Continue Without Repair") { onContinue() }
                    .disabled(isProcessing)

                Spacer()

                Button(action: onRepair) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Repair & Relaunch")
                            .fontWeight(.medium)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620)
    }

    private var summarySection: some View {
        GroupBox("Summary") {
            VStack(alignment: .leading, spacing: 8) {
                summaryRow(label: "Duplicate aliases", count: summary.duplicateAliasCount)
                summaryRow(label: "Orphan env vars", count: summary.orphanEnvVarCount)
                summaryRow(label: "Duplicate capability caches", count: summary.duplicateCacheCount)
                summaryRow(label: "Invalid capability caches", count: summary.invalidCacheCount)
                summaryRow(label: "Duplicate capability names", count: summary.duplicateCapabilityNameCount)
                summaryRow(label: "Corrupt servers (will disable)", count: summary.corruptServerCount)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func summaryRow(label: String, count: Int) -> some View {
        if count > 0 {
            HStack {
                Text(label)
                Spacer()
                Text("\(count)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
