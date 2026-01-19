//
//  SkillMarketplaceSourcesView.swift
//  MCP Bundler
//
//  Manages global marketplace sources for skills.
//

import SwiftUI
import SwiftData

struct SkillMarketplaceSourcesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query private var sources: [SkillMarketplaceSource]

    @State private var showingAddSheet = false
    @State private var addURLDraft: String = ""
    @State private var addNameDraft: String = ""
    @State private var addError: String?
    @State private var addDidEditName = false
    @State private var isAutoUpdatingName = false
    @State private var isValidatingMarketplace = false
    @State private var sectionError: String?

    @State private var sourceToRename: SkillMarketplaceSource?
    @State private var renameDraft: String = ""
    @State private var renameError: String?

    @State private var sourceToDelete: SkillMarketplaceSource?

    private let marketplaceService = SkillMarketplaceService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text("Add GitHub marketplaces that distribute SKILL.md-based skills.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let sectionError {
                Text(sectionError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if sources.isEmpty {
                Text("No marketplaces added yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Table(sortedSources) {
                TableColumn("Name") { source in
                    Text(source.displayName)
                        .font(.callout)
                }
                .width(min: 180, ideal: 220)

                TableColumn("Repo") { source in
                    Text("\(source.owner)/\(source.repo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .width(min: 220, ideal: 320)

                TableColumn("Skills") { source in
                    if let count = source.cachedSkillNames()?.count {
                        Text("\(count)")
                            .font(.callout)
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Actions") { source in
                    HStack(spacing: 10) {
                        Button {
                            beginRename(source)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Rename Marketplace")

                        Button(role: .destructive) {
                            sourceToDelete = source
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove Marketplace")
                    }
                }
                .width(min: 90, ideal: 110, max: 140)
            }
            .frame(minHeight: 140)

            Text("Marketplace sources are shared across all projects.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showingAddSheet) {
            addSheet
        }
        .sheet(item: $sourceToRename) { source in
            NameEditSheet(title: "Rename Marketplace",
                          placeholder: "Display name",
                          name: $renameDraft,
                          validationError: $renameError,
                          onSave: { name in
                              rename(source, to: name)
                          },
                          onCancel: {
                              sourceToRename = nil
                          })
        }
        .alert("Remove Marketplace?", isPresented: Binding(
            get: { sourceToDelete != nil },
            set: { if !$0 { sourceToDelete = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let source = sourceToDelete {
                    remove(source)
                }
                sourceToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                sourceToDelete = nil
            }
        } message: {
            if let source = sourceToDelete {
                Text("Remove \"\(source.displayName)\"? Installed skills stay in the library.")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Skill Marketplaces")
                .font(.headline)
            Spacer()
            Button {
                beginAdd()
            } label: {
                Label("Add Marketplace...", systemImage: "plus")
            }
        }
    }

    private var sortedSources: [SkillMarketplaceSource] {
        SkillMarketplaceSourceDefaults.sortSources(sources)
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Marketplace")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("GitHub URL")
                    .font(.subheadline)
                TextField("https://github.com/owner/repo", text: $addURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: addURLDraft) { _, _ in
                        guard !addDidEditName else { return }
                        if let repo = try? SkillMarketplaceService.parseGitHubRepository(from: addURLDraft) {
                            isAutoUpdatingName = true
                            addNameDraft = repo.repo
                            isAutoUpdatingName = false
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Display name")
                    .font(.subheadline)
                TextField("Display name", text: $addNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: addNameDraft) { _, _ in
                        if !isAutoUpdatingName {
                            addDidEditName = true
                        }
                    }
            }

            if let addError {
                Text(addError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            if isValidatingMarketplace {
                ProgressView("Validating marketplace...")
                    .font(.footnote)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingAddSheet = false
                }
                Button("Add") {
                    Task { await saveSource() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isValidatingMarketplace)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }

    private func beginAdd() {
        addURLDraft = ""
        addNameDraft = ""
        addError = nil
        addDidEditName = false
        isAutoUpdatingName = false
        isValidatingMarketplace = false
        sectionError = nil
        showingAddSheet = true
    }

    @MainActor
    private func saveSource() async {
        guard !isValidatingMarketplace else { return }
        do {
            let repo = try SkillMarketplaceService.parseGitHubRepository(from: addURLDraft)
            let name = addNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                addError = "Display name cannot be empty."
                return
            }
            let normalized = "\(repo.owner)/\(repo.repo)".lowercased()
            let conflict = sources.contains { $0.normalizedKey == normalized }
            if conflict {
                addError = "Marketplace already added."
                return
            }
        } catch {
            addError = error.localizedDescription
        }

        guard addError == nil else { return }

        isValidatingMarketplace = true
        defer { isValidatingMarketplace = false }

        do {
            let repo = try SkillMarketplaceService.parseGitHubRepository(from: addURLDraft)
            let result = try await marketplaceService.fetchMarketplaceSkills(owner: repo.owner,
                                                                             repo: repo.repo,
                                                                             cachedManifestSHA: nil,
                                                                             cachedMarketplaceJSON: nil,
                                                                             cachedSkillNames: nil,
                                                                             cachedDefaultBranch: nil)
            let availableSkills = result.listing.document.plugins
            guard !availableSkills.isEmpty else {
                addError = "Marketplace has no SKILL.md skills."
                return
            }

            let source = SkillMarketplaceSource(owner: repo.owner,
                                                repo: repo.repo,
                                                displayName: addNameDraft.trimmingCharacters(in: .whitespacesAndNewlines))

            if let update = result.cacheUpdate {
                source.updateMarketplaceCache(manifestSHA: update.manifestSHA,
                                              defaultBranch: update.defaultBranch,
                                              manifestJSON: update.manifestJSON,
                                              skillNames: update.skillNames)
            } else {
                source.cachedDefaultBranch = result.listing.defaultBranch
                source.cacheUpdatedAt = Date()
            }

            modelContext.insert(source)
            try modelContext.save()
            showingAddSheet = false
        } catch {
            addError = error.localizedDescription
        }
    }

    private func beginRename(_ source: SkillMarketplaceSource) {
        renameDraft = source.displayName
        renameError = nil
        sourceToRename = source
    }

    private func rename(_ source: SkillMarketplaceSource, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renameError = "Display name cannot be empty."
            return
        }
        source.rename(to: trimmed)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            sourceToRename = nil
            sectionError = nil
        } catch {
            renameError = "Failed to rename marketplace: \(error.localizedDescription)"
        }
    }

    private func remove(_ source: SkillMarketplaceSource) {
        modelContext.delete(source)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            sectionError = nil
        } catch {
            sectionError = "Failed to remove marketplace: \(error.localizedDescription)"
        }
    }
}
