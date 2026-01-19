import SwiftUI
import SwiftData

struct ImportServerPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.stdiosessionController) private var stdiosessionController
    let source: Source
    let importer: ExternalConfigImporter
    let project: Project
    let onImported: (ImportPersistenceResult) -> Void
    let onReadFailure: (String) -> Void
    let onImportSummary: (Int, Int) -> Void

    @State private var parseState: ParseState = .loading
    @State private var selectedCandidateIDs: Set<UUID> = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var selectedFolderID: PersistentIdentifier?
    @State private var showingFolderCreation = false
    @State private var folderCreationDraft: String = ""
    @State private var folderCreationError: String?

    private enum ParseState {
        case loading
        case loaded(ImportParseResult)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Servers")
                .font(.title2)

            Text(source.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            folderPicker

            content

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Import Selected", action: importSelection)
                    .disabled(!canImport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520, height: 520)
        .padding()
        .task(id: source.taskIdentifier) {
            await loadCandidates()
        }
        .sheet(isPresented: $showingFolderCreation) {
            folderCreationSheet
        }
    }

    @ViewBuilder
    private var content: some View {
        switch parseState {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Reading configuration…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Retry") {
                    Task { await loadCandidates() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let result):
            VStack(alignment: .leading, spacing: 12) {
                if result.candidates.isEmpty {
                    Text("No servers found in this configuration.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ImportCandidateTableView(candidates: result.candidates,
                                            selection: $selectedCandidateIDs)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }

                if result.failureCount > 0 {
                    Label("Detected \(result.successCount) servers; \(result.failureCount) entries failed to parse.", systemImage: "exclamationmark.bubble")
                        .font(.footnote)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var canImport: Bool {
        guard case .loaded(let result) = parseState,
              !isImporting else {
            return false
        }
        let validIDs = Set(result.candidates.filter { $0.isSelectable }.map(\.id))
        return !validIDs.intersection(selectedCandidateIDs).isEmpty
    }

    private func importSelection() {
        guard canImport else { return }
        guard case .loaded(let result) = parseState else { return }
        isImporting = true
        errorMessage = nil
        Task { await importSelectedCandidates(result: result) }
    }

    private func loadCandidates() async {
        parseState = .loading
        selectedCandidateIDs.removeAll()
        errorMessage = nil

        switch source {
        case .client(let client):
            let result = await importer.parse(client: client)
            await MainActor.run {
                switch result {
                case .success(let parseResult):
                    parseState = .loaded(parseResult)
                case .failure(let error):
                    parseState = .failed(error.localizedDescription)
                    onReadFailure(client.displayName)
                }
            }
        case .preloaded(_, let result):
            await MainActor.run {
                parseState = .loaded(result)
                selectedCandidateIDs = Set(result.candidates.filter { $0.isSelectable }.map(\.id))
            }
        }
    }

    @MainActor
    private func importSelectedCandidates(result: ImportParseResult) async {
        var failures: [String] = []
        var importedCount = 0
        for candidate in result.candidates where selectedCandidateIDs.contains(candidate.id) {
            guard let serverDefinition = candidate.server else { continue }
            do {
                let summary = try await importer.persist(serverDefinition,
                                                          originalAlias: candidate.alias,
                                                          project: project,
                                                          context: modelContext,
                                                          stdiosessionController: stdiosessionController,
                                                          folder: selectedFolder)
                onImported(summary)
                importedCount += 1
            } catch {
                failures.append(candidate.alias)
            }
        }

        if importedCount > 0 {
            dismiss()
        }

        if !failures.isEmpty {
            errorMessage = "Failed to import: \(failures.joined(separator: ", "))"
        }

        onImportSummary(importedCount, failures.count)
        isImporting = false
    }
    enum Source {
        case client(ImportClientDescriptor)
        case preloaded(description: String, result: ImportParseResult)

        var subtitle: String {
            switch self {
            case .client(let descriptor):
                return descriptor.summary
            case .preloaded(let description, _):
                return description
            }
        }

        var taskIdentifier: String {
            switch self {
            case .client(let descriptor):
                return descriptor.id
            case .preloaded(let description, _):
                return "preloaded-\(description)"
            }
        }
    }

    private var sortedFolders: [ProviderFolder] {
        project.folders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var selectedFolder: ProviderFolder? {
        guard let id = selectedFolderID else { return nil }
        return sortedFolders.first { $0.stableID == id }
    }

    private var folderPicker: some View {
        HStack(spacing: 8) {
            Text("Assign imported servers to:")
                .font(.subheadline)
            Spacer()
            Picker("Folder", selection: $selectedFolderID) {
                Text("Unfoldered").tag(PersistentIdentifier?.none)
                ForEach(sortedFolders, id: \.stableID) { folder in
                    Text(folder.name).tag(folder.stableID as PersistentIdentifier?)
                }
            }
            .labelsHidden()
            Button {
                folderCreationDraft = ""
                folderCreationError = nil
                showingFolderCreation = true
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
        }
    }

    private var folderCreationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Folder")
                .font(.title3.weight(.semibold))
            TextField("Folder name", text: $folderCreationDraft)
                .textFieldStyle(.roundedBorder)
            if let folderCreationError {
                Text(folderCreationError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingFolderCreation = false
                }
                Button("Create") {
                    let trimmed = folderCreationDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let error = validateFolderName(trimmed) {
                        folderCreationError = error
                        return
                    }
                    let folder = ProviderFolder(project: project, name: trimmed, isEnabled: true, isCollapsed: false)
                    modelContext.insert(folder)
                    if !project.folders.contains(where: { $0 === folder }) {
                        project.folders.append(folder)
                    }
                    project.markUpdated()
                    try? modelContext.save()
                    selectedFolderID = folder.stableID
                    showingFolderCreation = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 320)
    }

    private func validateFolderName(_ name: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Folder name cannot be empty."
        }
        let conflict = project.folders.contains {
            $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame
        }
        if conflict {
            return "A folder with this name already exists."
        }
        return nil
    }
}
