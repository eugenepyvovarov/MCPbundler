import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct ImportJSONModalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.stdiosessionController) private var stdiosessionController
    @EnvironmentObject private var toastCenter: ToastCenter

    let importer: ExternalConfigImporter
    let project: Project
    let knownFormats: [ClientInstallInstruction.ConfigFile.ImportFormat]
    let onImported: (ImportPersistenceResult) -> Void
    let onImportSummary: (Int, Int) -> Void

    @State private var textInput: String = ""
    @State private var selectedFileName: String?
    @State private var parseState: ParseState = .idle
    @State private var selectedCandidateIDs: Set<UUID> = []
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showingPreview = false
    @State private var selectedFolderID: PersistentIdentifier?
    @State private var showingFolderCreation = false
    @State private var folderCreationDraft: String = ""
    @State private var folderCreationError: String?

    private enum ParseState {
        case idle
        case parsing
        case loaded(ImportParseResult)
        case failed(String)
    }

    private var isParsing: Bool {
        if case .parsing = parseState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import JSON / TOML")
                .font(.title2)

            instructions
            folderPicker

            if showingPreview, let result = parsedResult {
                previewSection(result)
            } else {
                editorSection
                statusSection
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import Selected", action: importSelection)
                    .disabled(!canImport)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 600, height: 560)
        .padding()
        .onChange(of: textInput) { _ in showingPreview = false }
        .sheet(isPresented: $showingFolderCreation) {
            folderCreationSheet
        }
    }

    private var instructions: some View {
        Text("Paste the contents of a MCP client configuration file or choose a JSON/TOML file. The importer will try every known format and show the best match.")
            .font(.footnote)
            .foregroundStyle(.secondary)
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

    private var parsedResult: ImportParseResult? {
        if case .loaded(let result) = parseState { return result }
        return nil
    }

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextEditor(text: $textInput)
                .font(.body.monospaced())
                .border(Color.secondary.opacity(0.2))
                .frame(minHeight: 140)

            HStack(spacing: 12) {
                Button("Choose File…", action: chooseFile)
                if let selectedFileName {
                    Text(selectedFileName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Preview Servers", action: parseManualInput)
                    .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isParsing)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch parseState {
        case .parsing:
            HStack(spacing: 8) {
                ProgressView()
                Text("Parsing…")
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message)
                .foregroundStyle(.orange)
        default:
            Text("Paste or choose a file, then click Preview to analyze servers.")
                .foregroundStyle(.secondary)
        }
    }

    private func previewSection(_ result: ImportParseResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Back to Input") {
                    showingPreview = false
                }
                Spacer()
                Text(result.sourceDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ImportCandidateTableView(candidates: result.candidates,
                                    selection: $selectedCandidateIDs)
                .frame(maxWidth: .infinity, minHeight: 260)

            if result.failureCount > 0 {
                Label("Detected \(result.successCount) servers; \(result.failureCount) entries failed to parse.", systemImage: "exclamationmark.bubble")
                    .font(.footnote)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .json,
            .init(filenameExtension: "toml") ?? .text,
            .plainText
        ]
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                if let text = String(data: data, encoding: .utf8) {
                    textInput = text
                    selectedFileName = url.lastPathComponent
                    parseState = .idle
                    showingPreview = false
                } else {
                    toastCenter.push(text: "File is not UTF-8 text", style: .warning)
                }
            } catch {
                toastCenter.push(text: "Failed to read \(url.lastPathComponent)", style: .warning)
            }
        }
    }

    private func parseManualInput() {
        guard !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        parseState = .parsing
        selectedCandidateIDs.removeAll()
        errorMessage = nil
        let description = selectedFileName.map { "Manual import — \($0)" } ?? "Manual import"
        let data = Data(textInput.utf8)
        Task {
            let result = await importer.parseManualInput(data,
                                                          formats: knownFormats,
                                                          description: description)
            await MainActor.run {
                switch result {
                case .success(let parseResult):
                    parseState = .loaded(parseResult)
                    showingPreview = true
                case .failure(let error):
                    parseState = .failed(error.localizedDescription)
                    showingPreview = false
                    toastCenter.push(text: error.localizedDescription, style: .warning)
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
        guard canImport,
              case .loaded(let result) = parseState else {
            return
        }
        isImporting = true
        errorMessage = nil
        Task {
            await importSelectedCandidates(result: result)
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
        let conflict = project.folders.contains { folder in
            folder.name.compare(name, options: [.caseInsensitive]) == .orderedSame
        }
        if conflict {
            return "A folder with this name already exists."
        }
        return nil
    }

    @MainActor
    private func importSelectedCandidates(result: ImportParseResult) async {
        var failures: [String] = []
        var successes = 0
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
                successes += 1
            } catch {
                failures.append(candidate.alias)
            }
        }

        if successes > 0 {
            dismiss()
        }

        if !failures.isEmpty {
            errorMessage = "Failed to import: \(failures.joined(separator: ", "))"
        }

        onImportSummary(successes, failures.count)
        isImporting = false
    }
}
