//
//  SkillAddFromURLSheet.swift
//  MCP Bundler
//
//  Installs a skill from a GitHub folder URL.
//

import SwiftUI
import SwiftData

struct SkillAddFromURLSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Query private var skills: [SkillRecord]

    @State private var urlText = ""
    @State private var previewSummary: SkillFrontMatterSummary?
    @State private var resolvedReference: SkillGitHubFolderReference?
    @State private var isValidating = false
    @State private var isInstalling = false
    @State private var errorMessage: String?

    private let service: SkillMarketplaceService
    private let onInstalled: () async -> Void

    init(onInstalled: @escaping () async -> Void,
         service: SkillMarketplaceService = SkillMarketplaceService()) {
        self.onInstalled = onInstalled
        self.service = service
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Skill from URL")
                .font(.title3.weight(.semibold))

            Text("Paste a GitHub folder URL that points to a SKILL.md skill.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("https://github.com/owner/repo/tree/branch/path", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    validateURL()
                }
                .onChange(of: urlText) { _, _ in
                    resetPreview()
                }

            if isValidating {
                ProgressView("Checking SKILL.md...")
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let previewSummary {
                GroupBox("Skill Preview") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(displayName(for: previewSummary.name))
                            .font(.headline)
                        Text(previewSummary.description.isEmpty ? "No description provided." : previewSummary.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                if previewSummary == nil {
                    Button("Check URL") {
                        validateURL()
                    }
                    .disabled(isValidating || isInstalling)
                } else {
                    Button("Install") {
                        installSkill()
                    }
                    .disabled(isInstalling)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360, alignment: .topLeading)
    }

    private var installedSlugs: Set<String> {
        Set(skills.map { $0.slug.lowercased() })
    }

    private func resetPreview() {
        previewSummary = nil
        resolvedReference = nil
        errorMessage = nil
    }

    private func displayName(for raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return spaced }
        return String(first).uppercased() + spaced.dropFirst()
    }

    private func validateURL() {
        guard !isValidating, !isInstalling else { return }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter a GitHub folder URL."
            return
        }

        isValidating = true
        errorMessage = nil
        previewSummary = nil
        resolvedReference = nil

        Task {
            do {
                let reference = try SkillMarketplaceService.parseGitHubFolderURL(from: trimmed)
                let summary = try await service.fetchSkillPreview(reference: reference)
                await MainActor.run {
                    resolvedReference = reference
                    previewSummary = summary
                }
            } catch let error as SkillMarketplaceError {
                await MainActor.run {
                    if case .missingSkillFile = error {
                        errorMessage = "No SKILL.md found at the provided URL."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isValidating = false
            }
        }
    }

    private func installSkill() {
        guard let reference = resolvedReference, previewSummary != nil else { return }
        guard !isInstalling else { return }

        isInstalling = true
        errorMessage = nil

        Task {
            do {
                _ = try await service.installSkillFromGitHubFolder(reference,
                                                                  existingSlugs: installedSlugs)
                await onInstalled()
                await MainActor.run {
                    dismiss()
                }
            } catch let error as SkillMarketplaceError {
                await MainActor.run {
                    if case .missingSkillFile = error {
                        errorMessage = "No SKILL.md found at the provided URL."
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }

            await MainActor.run {
                isInstalling = false
            }
        }
    }
}
