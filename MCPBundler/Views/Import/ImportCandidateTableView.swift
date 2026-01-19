import SwiftUI

struct ImportCandidateTableView: View {
    let candidates: [ImportCandidate]
    @Binding var selection: Set<UUID>

    @State private var detailCandidate: ImportCandidate?

    private var sortedCandidates: [ImportCandidate] {
        candidates.sorted { lhs, rhs in
            lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    var body: some View {
        Table(sortedCandidates) {
            TableColumn("Import") { candidate in
                Toggle("", isOn: binding(for: candidate))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!candidate.isSelectable)
                    .help(candidate.isSelectable ? "Select to import" : (candidate.error ?? "Unable to import"))
            }
            .width(min: 70, ideal: 80)

            TableColumn("Name") { candidate in
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.alias)
                        .fontWeight(.semibold)
                    Text(candidate.summary.transportLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TableColumn("Status") { candidate in
                Text(candidate.summary.enabledSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110)

            TableColumn("Details") { candidate in
                Button("Details") {
                    detailCandidate = candidate
                }
                .buttonStyle(.bordered)
                .disabled(!candidate.isSelectable)
            }
            .width(min: 90, ideal: 120)
        }
        .frame(minHeight: 200)
        .popover(item: $detailCandidate) { candidate in
            ImportCandidateDetailView(candidate: candidate)
                .frame(width: 360)
                .padding()
        }
    }

    private func binding(for candidate: ImportCandidate) -> Binding<Bool> {
        Binding(
            get: { selection.contains(candidate.id) },
            set: { newValue in
                if newValue {
                    guard candidate.isSelectable else { return }
                    selection.insert(candidate.id)
                } else {
                    selection.remove(candidate.id)
                }
            }
        )
    }
}

private struct ImportCandidateDetailView: View {
    let candidate: ImportCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(candidate.alias)
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 6) {
                detailRow(title: "Transport", value: candidate.summary.transportLabel)
                detailRow(title: "Executable", value: candidate.summary.executable)
                detailRow(title: "URL", value: candidate.summary.remoteURL)
                detailRow(title: "Arguments", value: candidate.summary.arguments)
                detailRow(title: "Environment", value: candidate.summary.envSummary)
                detailRow(title: "Headers", value: candidate.summary.headerSummary)
            }

            if !candidate.details.isEmpty {
                Divider()
                Text("Basics").font(.headline)
                ForEach(candidate.details) { detail in
                    detailRow(title: detail.label, value: detail.value)
                }
            }

            if !candidate.envVars.isEmpty {
                Divider()
                Text("Env Vars").font(.headline)
                ForEach(candidate.envVars) { env in
                    detailRow(title: env.label, value: env.value)
                }
            }

            if !candidate.headers.isEmpty {
                Divider()
                Text("Headers").font(.headline)
                ForEach(candidate.headers) { header in
                    detailRow(title: header.label, value: header.value)
                }
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title + ":")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
