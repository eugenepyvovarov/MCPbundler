//
//  GlobalSkillsView.swift
//  MCP Bundler
//
//  Manage global skills and sync them with managed native skills folders.
//

import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

struct GlobalSkillsView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SkillRecord.slug, order: .forward)]) private var skills: [SkillRecord]
    @Query(sort: [SortDescriptor(\SkillSyncLocation.displayName, order: .forward)])
    private var locations: [SkillSyncLocation]
    @Query private var enablements: [SkillLocationEnablement]

    private let skillsLibrary = SkillsLibraryService()
    private let recordSync = SkillRecordSyncService()

    @StateObject private var nativeSync = NativeSkillsSyncService()

    @State private var isReloading = false
    @State private var errorMessage: String?
    @State private var importCandidate: NativeSkillsSyncService.UnmanagedSkillCandidate?

    private var managedLocations: [SkillSyncLocation] {
        locations.filter(\.isManaged)
            .sorted { lhs, rhs in
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private var pinnedLocations: [SkillSyncLocation] {
        let ordered = managedLocations.filter { $0.pinRank != nil }
            .sorted { ($0.pinRank ?? 0) < ($1.pinRank ?? 0) }
        return Array(ordered.prefix(3))
    }

    private func pinnedLocation(at index: Int) -> SkillSyncLocation? {
        guard pinnedLocations.indices.contains(index) else { return nil }
        return pinnedLocations[index]
    }

    private var otherLocations: [SkillSyncLocation] {
        let pinnedIDs = Set(pinnedLocations.map(\.locationId))
        return managedLocations.filter { !pinnedIDs.contains($0.locationId) }
    }

    private var managedLocationDescriptors: [SkillSyncLocationDescriptor] {
        managedLocations.map { location in
            SkillSyncLocationDescriptor(locationId: location.locationId,
                                        displayName: location.displayName,
                                        rootPath: location.rootPath,
                                        disabledRootPath: location.disabledRootPath)
        }
    }

    private var enablementsBySkillId: [String: Set<String>] {
        var mapping: [String: Set<String>] = [:]
        for enablement in enablements where enablement.enabled {
            guard let skill = enablement.skill,
                  let location = enablement.location else { continue }
            mapping[skill.skillId, default: []].insert(location.locationId)
        }
        return mapping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if isReloading {
                ProgressView("Refreshing skills…")
                    .progressViewStyle(.linear)
            }

            if let exportError = nativeSync.lastExportError {
                Text(exportError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let scanError = nativeSync.lastScanError {
                Text(scanError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if let syncError = nativeSync.lastSyncError {
                Text(syncError)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            GroupBox("Skills") {
                if skills.isEmpty {
                    Text("No skills found in the MCP Bundler library.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Table(skills) {
                        if let location = pinnedLocation(at: 0) {
                            TableColumn(location.displayName) { skill in
                                Toggle(isOn: locationBinding(for: skill, location: location)) { EmptyView() }
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .disabled(skill.isArchive)
                            }
                            .width(min: 80, ideal: 90)
                        }

                        if let location = pinnedLocation(at: 1) {
                            TableColumn(location.displayName) { skill in
                                Toggle(isOn: locationBinding(for: skill, location: location)) { EmptyView() }
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .disabled(skill.isArchive)
                            }
                            .width(min: 80, ideal: 90)
                        }

                        if let location = pinnedLocation(at: 2) {
                            TableColumn(location.displayName) { skill in
                                Toggle(isOn: locationBinding(for: skill, location: location)) { EmptyView() }
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .disabled(skill.isArchive)
                            }
                            .width(min: 80, ideal: 90)
                        }

                        if !otherLocations.isEmpty {
                            TableColumn("Other") { skill in
                                otherToggleCell(for: skill)
                            }
                            .width(min: 70, ideal: 80)
                        }

                        TableColumn("MCP") { skill in
                            Toggle(isOn: mcpBinding(for: skill)) { EmptyView() }
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .width(min: 60, ideal: 60)

                        TableColumn("Slug") { skill in
                            Text(skill.slug)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .width(min: 140, ideal: 160)

                        TableColumn("Name") { skill in
                            Text(skill.name)
                        }
                        .width(min: 180, ideal: 220)

                        TableColumn("Description") { skill in
                            Text(truncated(skill.descriptionText, limit: 180))
                                .lineLimit(3)
                        }
                        .width(min: 320, ideal: 420)

                        TableColumn("Source") { skill in
                            Text(skill.isArchive ? "Archive" : "Folder")
                                .foregroundStyle(skill.isArchive ? .orange : .secondary)
                        }
                        .width(min: 80, ideal: 90)
                    }
                    .frame(minHeight: 260)
                }
            }

            if !nativeSync.conflicts.isEmpty {
                GroupBox("Conflicts") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(nativeSync.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Skill: \(conflict.slug)")
                                    .font(.headline)

                                Text(conflict.states
                                    .filter(\.changedFromBaseline)
                                    .map(\.displayName)
                                    .joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                HStack(spacing: 8) {
                                    Button("Keep Bundler") {
                                        Task {
                                            await nativeSync.resolve(conflict: conflict,
                                                                     keeping: SkillSyncManifest.canonicalTool,
                                                                     locations: managedLocationDescriptors)
                                        }
                                    }
                                    ForEach(conflictResolutionStates(conflict), id: \.locationId) { state in
                                        Button("Keep \(state.displayName)") {
                                            Task {
                                                await nativeSync.resolve(conflict: conflict,
                                                                         keeping: state.locationId,
                                                                         locations: managedLocationDescriptors)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            GroupBox("Unmanaged Native Skills") {
                VStack(alignment: .leading, spacing: 10) {
                    if nativeSync.unmanagedCandidates.isEmpty {
                        Text("No unmanaged skills detected in managed locations.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(nativeSync.unmanagedCandidates) { candidate in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.locationName.uppercased())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(candidate.displayPath)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Button("Import & Manage") {
                                    importCandidate = candidate
                                }
                                Button("Ignore") {
                                    nativeSync.ignore(candidate)
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .task { await reloadSkills(reason: "initial") }
        .alert("Import Skill?", isPresented: Binding(get: { importCandidate != nil },
                                                     set: { if !$0 { importCandidate = nil } })) {
            Button("Import & Manage", role: .destructive) {
                if let candidate = importCandidate {
                    Task { await importAndManage(candidate) }
                }
                importCandidate = nil
            }
            Button("Cancel", role: .cancel) { importCandidate = nil }
        } message: {
            if let candidate = importCandidate {
                Text(importCandidateMessage(candidate))
            } else {
                Text("This moves the skill into MCP Bundler's library and replaces it with a managed export.")
            }
        }
        .alert("Operation Failed", isPresented: Binding(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text("Global Skills")
                .font(.title2.bold())
            if isReloading || nativeSync.isScanning || nativeSync.isSyncing {
                ProgressView()
            }
            Spacer()

            Button {
                Task { await reloadSkills(reason: "manual") }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isReloading)

            Button {
                Task { await nativeSync.scanUnmanaged(locations: managedLocationDescriptors) }
            } label: {
                Label("Scan Native Folders", systemImage: "magnifyingglass")
            }
            .disabled(nativeSync.isScanning)

            Button {
                Task {
                    await nativeSync.syncManaged(skills: skills,
                                                 enablementsBySkillId: enablementsBySkillId,
                                                 locations: managedLocationDescriptors)
                }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(nativeSync.isSyncing || skills.isEmpty)

            Button {
                browseSkillsFolder()
            } label: {
                Label("Browse Library", systemImage: "folder")
            }
        }
    }

    // MARK: - Bindings

    private func locationBinding(for skill: SkillRecord, location: SkillSyncLocation) -> Binding<Bool> {
        Binding(get: { isLocationEnabled(skill, location: location) },
                set: { newValue in
                    Task { await setLocationEnabled(skill, location: location, enabled: newValue) }
                })
    }

    private func mcpBinding(for skill: SkillRecord) -> Binding<Bool> {
        Binding(get: { skill.exposeViaMcp },
                set: { newValue in
                    Task { await setExposeViaMcp(skill, enabled: newValue) }
                })
    }

    private func isLocationEnabled(_ skill: SkillRecord, location: SkillSyncLocation) -> Bool {
        enablement(for: skill, location: location)?.enabled ?? false
    }

    private func enablement(for skill: SkillRecord, location: SkillSyncLocation) -> SkillLocationEnablement? {
        enablements.first { enablement in
            guard let enabledSkill = enablement.skill,
                  let enabledLocation = enablement.location else { return false }
            return enabledSkill.skillId == skill.skillId && enabledLocation.locationId == location.locationId
        }
    }

    private func otherToggleCell(for skill: SkillRecord) -> some View {
        let isEnabled = !otherLocations.isEmpty && !skill.isArchive
        let gate = ToggleBatchGate()
        let sources = otherLocations.map { location in
            MixedToggleSource(id: "\(skill.skillId)::\(location.locationId)",
                              isOn: Binding(get: { isLocationEnabled(skill, location: location) },
                                            set: { newValue in
                                                guard isEnabled else { return }
                                                gate.trigger {
                                                    Task {
                                                        await setOtherLocationsEnabled(for: skill, enabled: newValue)
                                                    }
                                                }
                                            }))
        }

        return Group {
            if sources.isEmpty {
                Toggle(isOn: .constant(false)) { EmptyView() }
            } else {
                Toggle(sources: sources, isOn: \.isOn) { EmptyView() }
            }
        }
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .disabled(!isEnabled)
    }

    private func conflictResolutionStates(_ conflict: NativeSkillsSyncConflict) -> [NativeSkillsSyncState] {
        conflict.states
            .filter { $0.locationId != SkillSyncManifest.canonicalTool }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: - Actions

    @MainActor
    private func reloadSkills(reason: String) async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        do {
            try await skillsLibrary.reload()
            let infos = await skillsLibrary.list()
            let impacted = try recordSync.synchronizeRecords(with: infos, in: modelContext)
            try await rebuildSnapshots(for: impacted)
        } catch {
            errorMessage = "Failed to refresh skills (\(reason)): \(error.localizedDescription)"
        }
    }

    @MainActor
    private func setLocationEnabled(_ skill: SkillRecord,
                                    location: SkillSyncLocation,
                                    enabled: Bool) async {
        let currentValue = isLocationEnabled(skill, location: location)
        guard currentValue != enabled else { return }

        updateEnablement(skill: skill, location: location, enabled: enabled)
        guard saveEnablementChanges(message: "Failed to save skill toggle") else { return }

        let descriptor = SkillSyncLocationDescriptor(locationId: location.locationId,
                                                     displayName: location.displayName,
                                                     rootPath: location.rootPath,
                                                     disabledRootPath: location.disabledRootPath)
        await nativeSync.applyExport(for: skill, location: descriptor, enabled: enabled)
    }

    @MainActor
    private func setOtherLocationsEnabled(for skill: SkillRecord, enabled: Bool) async {
        guard !otherLocations.isEmpty, !skill.isArchive else { return }
        var descriptors: [SkillSyncLocationDescriptor] = []
        for location in otherLocations {
            updateEnablement(skill: skill, location: location, enabled: enabled)
            descriptors.append(SkillSyncLocationDescriptor(locationId: location.locationId,
                                                           displayName: location.displayName,
                                                           rootPath: location.rootPath,
                                                           disabledRootPath: location.disabledRootPath))
        }
        guard saveEnablementChanges(message: "Failed to save other locations") else { return }
        for descriptor in descriptors {
            await nativeSync.applyExport(for: skill, location: descriptor, enabled: enabled)
        }
    }

    @MainActor
    private func updateEnablement(skill: SkillRecord,
                                  location: SkillSyncLocation,
                                  enabled: Bool) {
        if let existing = enablement(for: skill, location: location) {
            existing.setEnabled(enabled)
        } else {
            let enablement = SkillLocationEnablement(skill: skill, location: location, enabled: enabled)
            modelContext.insert(enablement)
        }
    }

    @MainActor
    private func saveEnablementChanges(message: String) -> Bool {
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            return true
        } catch {
            errorMessage = "\(message): \(error.localizedDescription)"
            return false
        }
    }

    @MainActor
    private func setExposeViaMcp(_ skill: SkillRecord, enabled: Bool) async {
        skill.setExposeViaMcp(enabled)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            try await rebuildAllSnapshots()
        } catch {
            errorMessage = "Failed to update MCP exposure: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importAndManage(_ candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) async {
        do {
            let root = skillsLibraryURL()
            let fileManager = FileManager.default
            let destination: URL

            switch candidate.source {
            case .directory(let directory):
                _ = try SkillDigest.sha256Hex(forSkillDirectory: directory)
                try await validateUnmanagedSkillDirectory(directory)

                destination = uniqueDestination(for: directory.lastPathComponent, root: root)
                do {
                    try fileManager.moveItem(at: directory, to: destination)
                } catch {
                    try fileManager.copyItem(at: directory, to: destination)
                    do {
                        try fileManager.removeItem(at: directory)
                    } catch {
                        try? fileManager.removeItem(at: destination)
                        throw error
                    }
                }

            case .rootFile(let skillFile):
                _ = try SkillDigest.sha256Hex(forFile: skillFile)
                let slug = try await validateUnmanagedSkillFileAndExtractSlug(skillFile)

                destination = uniqueDestination(for: slug, root: root)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                let destinationSkillFile = destination.appendingPathComponent("SKILL.md", isDirectory: false)
                try fileManager.copyItem(at: skillFile, to: destinationSkillFile)
                do {
                    try fileManager.removeItem(at: skillFile)
                } catch {
                    try? fileManager.removeItem(at: destination)
                    throw error
                }
            }

            await reloadSkills(reason: "import-unmanaged")

            let destinationPath = destination.standardizedFileURL.path
            let recordDescriptor = FetchDescriptor<SkillRecord>()
            let updatedRecords = try modelContext.fetch(recordDescriptor)
            guard let record = updatedRecords.first(where: {
                URL(fileURLWithPath: $0.sourcePath).standardizedFileURL.path == destinationPath
            }) else {
                errorMessage = "Imported skill did not appear in the library. Check SKILL.md validity."
                return
            }

            if let location = locations.first(where: { $0.locationId == candidate.locationId }) {
                updateEnablement(skill: record, location: location, enabled: true)
                guard saveEnablementChanges(message: "Failed to save skill toggle") else { return }

                let descriptor = SkillSyncLocationDescriptor(locationId: location.locationId,
                                                             displayName: location.displayName,
                                                             rootPath: location.rootPath,
                                                             disabledRootPath: location.disabledRootPath)
                await nativeSync.applyExport(for: record, location: descriptor, enabled: true)
            }

            await nativeSync.scanUnmanaged(locations: managedLocationDescriptors)
        } catch {
            errorMessage = "Failed to import skill: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func validateUnmanagedSkillDirectory(_ directory: URL) async throws {
        let fileManager = FileManager.default
        let validationRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcp-bundler-skill-validate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: validationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: validationRoot) }

        let candidateDestination = validationRoot.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: directory, to: candidateDestination)

        let validator = SkillsLibraryService(root: validationRoot, fileManager: fileManager)
        try await validator.reload()
        let infos = await validator.list()
        if infos.isEmpty {
            throw SkillsLibraryError.invalidSkill("Directory does not contain a valid SKILL.md")
        }
    }

    @MainActor
    private func validateUnmanagedSkillFileAndExtractSlug(_ skillFile: URL) async throws -> String {
        let fileManager = FileManager.default
        let validationRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcp-bundler-skillfile-validate-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: validationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: validationRoot) }

        let bundleRoot = validationRoot.appendingPathComponent("candidate", isDirectory: true)
        try fileManager.createDirectory(at: bundleRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: skillFile, to: bundleRoot.appendingPathComponent("SKILL.md", isDirectory: false))

        let validator = SkillsLibraryService(root: validationRoot, fileManager: fileManager)
        try await validator.reload()
        let infos = await validator.list()
        guard let info = infos.first else {
            throw SkillsLibraryError.invalidSkill("SKILL.md is not valid")
        }
        return info.slug
    }

    @MainActor
    private func rebuildSnapshots(for projects: [Project]) async throws {
        for project in projects {
            try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        }
    }

    @MainActor
    private func rebuildAllSnapshots() async throws {
        let descriptor = FetchDescriptor<Project>()
        let projects = try modelContext.fetch(descriptor)
        try await rebuildSnapshots(for: projects)
    }

    private func truncated(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func uniqueDestination(for slug: String, root: URL) -> URL {
        let fm = FileManager.default
        var candidate = root.appendingPathComponent(slug, isDirectory: true)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(slug)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private func browseSkillsFolder() {
        #if os(macOS)
        let folderURL = skillsLibraryURL()
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path) {
            NSWorkspace.shared.open(folderURL)
        }
        #endif
    }

    private func importCandidateMessage(_ candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) -> String {
        switch candidate.source {
        case .directory:
            return """
            This moves the skill folder into MCP Bundler's library and replaces it with a managed export.

            Path: \(candidate.displayPath)
            """
        case .rootFile:
            return """
            This moves the root SKILL.md into MCP Bundler's library and replaces it with a managed folder export.

            Path: \(candidate.displayPath)
            """
        }
    }
}
