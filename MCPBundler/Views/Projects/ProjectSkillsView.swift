//
//  ProjectSkillsView.swift
//  MCP Bundler
//
//  Presents the skills library where users can enable skills per project,
//  manage global overrides, and import/delete skill bundles.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import os.log
#if os(macOS)
import AppKit
#endif

struct ProjectSkillsView: View {
    @Environment(\.modelContext) private var modelContext

    private static let skillDragType = UTType(exportedAs: "xyz.maketry.mcpbundler.skill-id")

    private let skillsLibrary = SkillsLibraryService()
    private let recordSync = SkillRecordSyncService()
    private let log = Logger(subsystem: "mcp-bundler", category: "skills.project.selection")

    let project: Project

    @Query private var skills: [SkillRecord]
    @Query private var folders: [SkillFolder]
    @Query(sort: [SortDescriptor(\SkillSyncLocation.displayName, order: .forward)])
    private var locations: [SkillSyncLocation]
    @Query private var enablements: [SkillLocationEnablement]
    @StateObject private var nativeSync = NativeSkillsSyncService()
    @State private var isReloading = false
    @State private var errorMessage: String?
    @State private var editingSkill: SkillRecord?
    @State private var skillPendingDeletion: SkillRecord?
    @State private var previewData: SkillPreviewData?
    @State private var showingMarketplaceInstall = false
    @State private var showingAddFromURL = false
    @State private var selectionLookup: [String: ProjectSkillSelection] = [:]
    @State private var folderEditorMode: SkillFolderEditorMode?
    @State private var folderNameDraft: String = ""
    @State private var folderValidationError: String?
    @State private var folderPendingDeletion: SkillFolder?
    @State private var isDraggingSkill: Bool = false
    @State private var isDraggingSkillFromFolder: Bool = false
    @State private var isUnfolderDropTargeted: Bool = false
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var skillsTableView: NSTableView?
    @State private var skillsTableAutoScroller = TableAutoScroller()
    @State private var bulkUpdatingFolderIDs: Set<PersistentIdentifier> = []

    init(project: Project) {
        self.project = project
        _skills = Query(sort: [SortDescriptor(\SkillRecord.slug, order: .forward)])
        _folders = Query(sort: [SortDescriptor(\SkillFolder.name, order: .forward)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Text("Skills are shared across projects with the same statuses (for now).")
                .font(.callout)
                .foregroundStyle(.secondary)

            if isReloading {
                ProgressView("Loading skills…")
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

            skillsTable
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await reloadSkills(reason: "initial")
        }
        .sheet(item: $previewData) { data in
            SkillPreviewSheet(data: data)
        }
        .sheet(item: $editingSkill) { skill in
            SkillOverrideEditor(skill: skill,
                                onSave: { display, description in
                                    Task { await updateOverrides(for: skill, displayName: display, description: description) }
                                })
            .frame(width: 520, height: 360)
        }
        .sheet(isPresented: $showingMarketplaceInstall) {
            SkillMarketplaceInstallSheet(onInstalled: {
                await reloadSkills(reason: "marketplace-install")
            })
        }
        .sheet(isPresented: $showingAddFromURL) {
            SkillAddFromURLSheet(onInstalled: {
                await reloadSkills(reason: "url-install")
            })
        }
        .sheet(item: $folderEditorMode) { mode in
            NameEditSheet(title: mode.title,
                          placeholder: "Folder name",
                          name: $folderNameDraft,
                          validationError: $folderValidationError,
                          onSave: { raw in
                              let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                              let validation = validateFolderName(trimmed, excluding: mode.folderReference)
                              if let validation {
                                  folderValidationError = validation
                                  return
                              }
                              switch mode {
                              case .create:
                                  createFolder(named: trimmed)
                              case .rename(let folder):
                                  renameFolder(folder, to: trimmed)
                              }
                              folderEditorMode = nil
                          },
                          onCancel: {
                              folderEditorMode = nil
                          })
        }
        .alert("Delete Skill?", isPresented: Binding(
            get: { skillPendingDeletion != nil },
            set: { if !$0 { skillPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let skill = skillPendingDeletion {
                    Task { await deleteSkill(skill) }
                }
                skillPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { skillPendingDeletion = nil }
        } message: {
            if let skill = skillPendingDeletion {
                Text("This will delete the skill from disk and remove it from all projects.\n\nSlug: \(skill.slug)")
            } else {
                Text("This will delete the skill from disk and remove it from all projects.")
            }
        }
        .alert("Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { folderPendingDeletion != nil },
            set: { if !$0 { folderPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let folder = folderPendingDeletion {
                    deleteFolder(folder)
                }
                folderPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: {
            if let folder = folderPendingDeletion {
                Text("Delete folder \"\(folder.name)\"? Skills will remain in the library as unfoldered.")
            } else {
                Text("Delete this folder? Skills will remain in the library as unfoldered.")
            }
        }
    }

    // MARK: - Header & Empty State

    private var header: some View {
        HStack(spacing: 12) {
            Text("Skills").font(.title3.bold())
            if isReloading || nativeSync.isScanning || nativeSync.isSyncing {
                ProgressView()
            }
            Spacer()
            Menu {
                Button {
                    importSkill()
                } label: {
                    Label("Add manually", systemImage: "folder.badge.plus")
                }
                Button {
                    showingAddFromURL = true
                } label: {
                    Label("Add from URL", systemImage: "link")
                }
                Button {
                    showingMarketplaceInstall = true
                } label: {
                    Label("Add from marketplace", systemImage: "tray.and.arrow.down")
                }
            } label: {
                Label("Add Skill", systemImage: "plus")
            }
            .disabled(isReloading)

            Button {
                folderNameDraft = ""
                folderValidationError = nil
                folderEditorMode = .create
            } label: {
                Label("Add Folder", systemImage: "folder.badge.plus")
            }
            .disabled(isReloading)

            Button {
                Task { await reloadSkills(reason: "manual") }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Reload skills and sync native exports")
            .disabled(isReloading)

            Button {
                browseSkillsFolder()
            } label: {
                Label("Browse", systemImage: "folder")
            }
        }
    }

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

    private var showsOtherLocationsToggle: Bool {
        !otherLocations.isEmpty
    }

    private var showNativeControls: Bool {
        !managedLocations.isEmpty
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

    private enum SkillsTableRow: Identifiable {
        case folderHeader(SkillFolder)
        case conflict(NativeSkillsSyncConflict)
        case unmanaged(NativeSkillsSyncService.UnmanagedSkillCandidate)
        case managed(SkillRecord, SkillFolder?)

        var id: String {
            switch self {
            case .folderHeader(let folder):
                return "folder::\(String(describing: folder.stableID))"
            case .conflict(let conflict):
                return "conflict::\(conflict.skillId)"
            case .unmanaged(let candidate):
                return "unmanaged::\(candidate.id)"
            case .managed(let skill, _):
                return "managed::\(skill.skillId)"
            }
        }
    }

    private var skillsTableRows: [SkillsTableRow] {
        var rows: [SkillsTableRow] = []
        if showNativeControls {
            rows.append(contentsOf: nativeSync.conflicts.map(SkillsTableRow.conflict))
            rows.append(contentsOf: nativeSync.unmanagedCandidates.map(SkillsTableRow.unmanaged))
        }

        let sortedFolders = folders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        for folder in sortedFolders {
            rows.append(.folderHeader(folder))
            if !folder.isCollapsed {
                let members = skills.filter { $0.folder?.stableID == folder.stableID }
                for skill in members {
                    rows.append(.managed(skill, folder))
                }
            }
        }

        let unfoldered = skills.filter { $0.folder == nil }
        rows.append(contentsOf: unfoldered.map { SkillsTableRow.managed($0, nil) })
        return rows
    }

    private func highlightColor(for row: SkillsTableRow) -> Color? {
        switch row {
        case .unmanaged:
            return Color.yellow.opacity(0.16)
        case .conflict:
            return Color.orange.opacity(0.16)
        case .managed, .folderHeader:
            return nil
        }
    }
#if os(macOS)
    private var tableRowHighlights: [Int: NSColor] {
        var highlights: [Int: NSColor] = [:]
        highlights.reserveCapacity(skillsTableRows.count)

        for (index, row) in skillsTableRows.enumerated() {
            switch row {
            case .unmanaged:
                highlights[index] = NSColor.systemYellow.withAlphaComponent(0.16)
            case .conflict:
                highlights[index] = NSColor.systemOrange.withAlphaComponent(0.16)
            case .managed, .folderHeader:
                continue
            }
        }

        return highlights
    }
#endif

    private enum SkillsTableLayout {
        static let enabledColumnWidth: CGFloat = 60
        static let nativeColumnWidth: CGFloat = 70
        static let actionsColumnWidth: CGFloat = 120
        static let minDisplayNameWidth: CGFloat = 220
        static let minDescriptionWidth: CGFloat = 360
    }

    private enum SkillsTableActionStyle {
        static let iconFont: Font = .system(size: 13, weight: .semibold)
        static let iconDimension: CGFloat = 28
        static let iconTint: Color = .secondary
    }

    private struct SkillsTableDropDelegate: DropDelegate {
        var rowItems: [SkillsTableRow]
        var tableView: NSTableView?
        var autoScroller: TableAutoScroller
        var onDrop: (_ providers: [NSItemProvider], _ folder: SkillFolder?) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [ProjectSkillsView.skillDragType, UTType.text])
        }

        func dropExited(info: DropInfo) {
            autoScroller.stop()
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let tableView,
                  let pointerLocation = TablePointerLocator.pointerLocation(in: tableView) else {
                autoScroller.stop()
                return DropProposal(operation: .cancel)
            }

            autoScroller.update(tableView: tableView, pointerLocation: pointerLocation)

            let row = tableView.row(at: pointerLocation)
            guard (0..<rowItems.count).contains(row) else {
                return DropProposal(operation: .cancel)
            }

            switch rowItems[row] {
            case .folderHeader, .managed:
                return DropProposal(operation: .move)
            case .conflict, .unmanaged:
                return DropProposal(operation: .cancel)
            }
        }

        func performDrop(info: DropInfo) -> Bool {
            autoScroller.stop()
            guard let tableView,
                  let pointerLocation = TablePointerLocator.pointerLocation(in: tableView) else {
                return false
            }

            let row = tableView.row(at: pointerLocation)
            guard (0..<rowItems.count).contains(row) else { return false }

            let folder = folderTarget(for: rowItems[row])
            let providers = info.itemProviders(for: [ProjectSkillsView.skillDragType, UTType.text])
            return onDrop(providers, folder)
        }

        private func folderTarget(for item: SkillsTableRow) -> SkillFolder? {
            switch item {
            case .folderHeader(let folder):
                return folder
            case .managed(_, let folder):
                return folder
            case .conflict, .unmanaged:
                return nil
            }
        }
    }

    @ViewBuilder
    private var skillsTable: some View {
        if skillsTableRows.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ZStack(alignment: .bottom) {
                Table(skillsTableRows) {
                    TableColumn("Enabled") { row in
                        skillsTableEnabledToggleCell(row)
                    }
                    .width(min: SkillsTableLayout.enabledColumnWidth,
                           ideal: SkillsTableLayout.enabledColumnWidth,
                           max: SkillsTableLayout.enabledColumnWidth)

                    if let location = pinnedLocation(at: 0) {
                        TableColumn(location.displayName) { row in
                            skillsTableLocationToggleCell(row, location: location)
                        }
                        .width(min: SkillsTableLayout.nativeColumnWidth,
                               ideal: SkillsTableLayout.nativeColumnWidth,
                               max: SkillsTableLayout.nativeColumnWidth)
                    }

                    if let location = pinnedLocation(at: 1) {
                        TableColumn(location.displayName) { row in
                            skillsTableLocationToggleCell(row, location: location)
                        }
                        .width(min: SkillsTableLayout.nativeColumnWidth,
                               ideal: SkillsTableLayout.nativeColumnWidth,
                               max: SkillsTableLayout.nativeColumnWidth)
                    }

                    if let location = pinnedLocation(at: 2) {
                        TableColumn(location.displayName) { row in
                            skillsTableLocationToggleCell(row, location: location)
                        }
                        .width(min: SkillsTableLayout.nativeColumnWidth,
                               ideal: SkillsTableLayout.nativeColumnWidth,
                               max: SkillsTableLayout.nativeColumnWidth)
                    }

                    if showsOtherLocationsToggle {
                        TableColumn("Other") { row in
                            skillsTableOtherToggleCell(row)
                        }
                        .width(min: SkillsTableLayout.nativeColumnWidth,
                               ideal: SkillsTableLayout.nativeColumnWidth,
                               max: SkillsTableLayout.nativeColumnWidth)
                    }

                    TableColumn("Display Name") { row in
                        skillsTableCell(row) {
                            skillsTableDisplayNameCell(row)
                        }
                    }
                    .width(min: SkillsTableLayout.minDisplayNameWidth, ideal: SkillsTableLayout.minDisplayNameWidth)

                    TableColumn("Description") { row in
                        skillsTableCell(row) {
                            skillsTableDescriptionCell(row)
                        }
                    }
                    .width(min: SkillsTableLayout.minDescriptionWidth, ideal: SkillsTableLayout.minDescriptionWidth)

                    TableColumn("Actions") { row in
                        skillsTableCell(row) {
                            skillsTableActionsCell(row)
                        }
                    }
                    .width(min: SkillsTableLayout.actionsColumnWidth, ideal: SkillsTableLayout.actionsColumnWidth)
                }
#if os(macOS)
                .background(SkillsTableRowHighlighter(rowHighlights: tableRowHighlights)
                    .allowsHitTesting(false))
#endif
                .onDrop(of: [ProjectSkillsView.skillDragType, UTType.text],
                        delegate: SkillsTableDropDelegate(rowItems: skillsTableRows,
                                                          tableView: skillsTableView,
                                                          autoScroller: skillsTableAutoScroller,
                                                          onDrop: handleDrop))
                .background(TableViewAccessor(tableView: $skillsTableView))
                .padding(.bottom, shouldShowUnfolderDropZone ? 64 : 0)

                if shouldShowUnfolderDropZone {
                    unfolderDropZone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func skillsTableCell<RowContent: View>(_ row: SkillsTableRow,
                                                   alignment: Alignment = .leading,
                                                   @ViewBuilder content: () -> RowContent) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    @ViewBuilder
    private func skillsTableEnabledToggleCell(_ row: SkillsTableRow) -> some View {
        skillsTableCell(row, alignment: .center) {
            switch row {
            case .managed(let skill, _):
                Toggle(isOn: binding(for: skill)) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Enable this skill for the current project")
            case .unmanaged, .conflict:
                EmptyView()
            case .folderHeader(let folder):
                folderBulkMcpToggleCell(folder)
            }
        }
    }

    @ViewBuilder
    private func skillsTableLocationToggleCell(_ row: SkillsTableRow, location: SkillSyncLocation) -> some View {
        skillsTableCell(row, alignment: .center) {
            switch row {
            case .managed(let skill, _):
                Toggle(isOn: locationBinding(for: skill, location: location)) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(skill.isArchive)
                    .help(skill.isArchive ? "Archive skills are extracted automatically on refresh." :
                        "Export this skill to \(location.displayName)")
            case .unmanaged, .conflict:
                EmptyView()
            case .folderHeader(let folder):
                folderBulkLocationToggleCell(folder, location: location)
            }
        }
    }

    @ViewBuilder
    private func skillsTableOtherToggleCell(_ row: SkillsTableRow) -> some View {
        skillsTableCell(row, alignment: .center) {
            switch row {
            case .managed(let skill, _):
                otherToggleCell(for: skill)
            case .unmanaged, .conflict:
                EmptyView()
            case .folderHeader(let folder):
                folderBulkOtherToggleCell(folder)
            }
        }
    }

    private func bulkToggleSources<Item>(items: [Item],
                                         isEnabled: Bool,
                                         id: (Item) -> String,
                                         isOn: @escaping (Item) -> Bool,
                                         onSetEnabled: @escaping (Bool) -> Void) -> [MixedToggleSource] {
        let gate = ToggleBatchGate()
        return items.map { item in
            MixedToggleSource(id: id(item),
                              isOn: Binding(get: { isOn(item) },
                                            set: { newValue in
                                                guard isEnabled else { return }
                                                gate.trigger { onSetEnabled(newValue) }
                                            }))
        }
    }

    private func folderBulkMcpToggleCell(_ folder: SkillFolder) -> some View {
        let isBusy = bulkUpdatingFolderIDs.contains(folder.stableID)
        let folderSkills = skills.filter { $0.folder?.stableID == folder.stableID }
        let isEnabled = !folderSkills.isEmpty
        let onSetEnabled: (Bool) -> Void = { enabled in
            Task { await setMcpEnabled(in: folder, enabled: enabled) }
        }
        let sources = bulkToggleSources(items: folderSkills,
                                        isEnabled: isEnabled,
                                        id: { $0.skillId },
                                        isOn: { isSkillEnabled($0) },
                                        onSetEnabled: onSetEnabled)

        return AnyView(bulkToggleButton(sources: sources,
                                        isEnabled: isEnabled,
                                        isBusy: isBusy,
                                        help: "Enable/disable all skills in this folder for the current project",
                                        onSetEnabled: onSetEnabled))
    }

    private func folderBulkLocationToggleCell(_ folder: SkillFolder, location: SkillSyncLocation) -> some View {
        let isBusy = bulkUpdatingFolderIDs.contains(folder.stableID)
        let folderSkills = skills.filter { $0.folder?.stableID == folder.stableID && !$0.isArchive }
        let isEnabled = !folderSkills.isEmpty
        let onSetEnabled: (Bool) -> Void = { enabled in
            Task { await setLocationEnabled(in: folder, location: location, enabled: enabled) }
        }
        let sources = bulkToggleSources(items: folderSkills,
                                        isEnabled: isEnabled,
                                        id: { $0.skillId },
                                        isOn: { isLocationEnabled($0, location: location) },
                                        onSetEnabled: onSetEnabled)
        let helpText = "Enable/disable exporting all eligible folder skills to \(location.displayName)"

        return AnyView(bulkToggleButton(sources: sources,
                                        isEnabled: isEnabled,
                                        isBusy: isBusy,
                                        help: helpText,
                                        onSetEnabled: onSetEnabled))
    }

    private func folderBulkOtherToggleCell(_ folder: SkillFolder) -> some View {
        guard !otherLocations.isEmpty else { return AnyView(EmptyView()) }
        let isBusy = bulkUpdatingFolderIDs.contains(folder.stableID)
        let folderSkills = skills.filter { $0.folder?.stableID == folder.stableID && !$0.isArchive }
        let isEnabled = !folderSkills.isEmpty
        let onSetEnabled: (Bool) -> Void = { enabled in
            Task { await setOtherLocationsEnabled(in: folder, enabled: enabled) }
        }
        let pairs = folderSkills.flatMap { skill in
            otherLocations.map { location in (skill, location) }
        }
        let sources = bulkToggleSources(items: pairs,
                                        isEnabled: isEnabled,
                                        id: { "\($0.0.skillId)::\($0.1.locationId)" },
                                        isOn: { isLocationEnabled($0.0, location: $0.1) },
                                        onSetEnabled: onSetEnabled)

        return AnyView(bulkToggleButton(sources: sources,
                                        isEnabled: isEnabled,
                                        isBusy: isBusy,
                                        help: "Enable/disable other locations for all eligible folder skills",
                                        onSetEnabled: onSetEnabled))
    }

    private func bulkToggleButton(sources: [MixedToggleSource],
                                  isEnabled: Bool,
                                  isBusy: Bool,
                                  help: String,
                                  onSetEnabled: @escaping (Bool) -> Void) -> some View {
        if isBusy {
            return AnyView(ProgressView().controlSize(.small))
        }

        let toggle = Group {
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
        .help(help)
        .contextMenu {
            if isEnabled {
                Button("Enable all") { onSetEnabled(true) }
                Button("Disable all") { onSetEnabled(false) }
            }
        }

        return AnyView(toggle)
    }

    private func otherToggleCell(for skill: SkillRecord) -> some View {
        let isEnabled = !otherLocations.isEmpty && !skill.isArchive
        let onSetEnabled: (Bool) -> Void = { enabled in
            Task { await setOtherLocationsEnabled(for: skill, enabled: enabled) }
        }
        let sources = bulkToggleSources(items: otherLocations,
                                        isEnabled: isEnabled,
                                        id: { "\(skill.skillId)::\($0.locationId)" },
                                        isOn: { isLocationEnabled(skill, location: $0) },
                                        onSetEnabled: onSetEnabled)

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
        .help("Enable/disable other locations for this skill")
    }

    private func unmanagedDetectedLine(for candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) -> String {
        return "Detected in \(candidate.locationName) skill folder. Choose Keep to import to MCP Bundler."
    }

#if os(macOS)
    private struct SkillsTableRowHighlighter: NSViewRepresentable {
        let rowHighlights: [Int: NSColor]

        func makeNSView(context: Context) -> HighlighterView {
            HighlighterView()
        }

        func updateNSView(_ nsView: HighlighterView, context: Context) {
            nsView.updateHighlights(rowHighlights)
        }

        final class HighlighterView: NSView {
            private static let highlightIdentifier = NSUserInterfaceItemIdentifier("mcp-bundler.skillsRowHighlight")

            private var highlights: [Int: NSColor] = [:]
            private var observedContentView: NSClipView?
            private var boundsObserver: NSObjectProtocol?
            private weak var cachedTableView: NSTableView?

            deinit {
                cleanupObservation()
            }

            func updateHighlights(_ newValue: [Int: NSColor]) {
                highlights = newValue
                scheduleApply()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                scheduleApply()
            }

            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                scheduleApply()
            }

            override func layout() {
                super.layout()
                scheduleApply()
            }

            private func scheduleApply() {
                DispatchQueue.main.async { [weak self] in
                    self?.applyHighlights()
                }
            }

            private func applyHighlights() {
                guard let tableView = locateTableView() else { return }
                if cachedTableView !== tableView {
                    cachedTableView = tableView
                    configureObservation(for: tableView)
                }

                let visibleRows = tableView.rows(in: tableView.visibleRect)
                guard visibleRows.location != NSNotFound else { return }
                let upperBound = visibleRows.location + visibleRows.length
                guard upperBound >= visibleRows.location else { return }

                let visibleRange = visibleRows.location..<upperBound
                for row in visibleRange {
                    guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
                    updateRowView(rowView, highlightColor: highlights[row])
                }
            }

            private func updateRowView(_ rowView: NSTableRowView, highlightColor: NSColor?) {
                if let highlightColor {
                    let highlightView = findOrCreateHighlightView(in: rowView)
                    highlightView.layer?.backgroundColor = highlightColor.cgColor
                } else {
                    removeHighlightView(from: rowView)
                }
            }

            private func findOrCreateHighlightView(in rowView: NSTableRowView) -> NSView {
                if let existing = rowView.subviews.first(where: { $0.identifier == Self.highlightIdentifier }) {
                    return existing
                }

                let highlightView = RowHighlightView()
                highlightView.identifier = Self.highlightIdentifier
                highlightView.wantsLayer = true
                highlightView.layer?.cornerRadius = 10
                highlightView.layer?.masksToBounds = true
                highlightView.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(highlightView, positioned: .below, relativeTo: rowView.subviews.first)

                NSLayoutConstraint.activate([
                    highlightView.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 8),
                    highlightView.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -8),
                    highlightView.topAnchor.constraint(equalTo: rowView.topAnchor, constant: 2),
                    highlightView.bottomAnchor.constraint(equalTo: rowView.bottomAnchor, constant: -2),
                ])

                return highlightView
            }

            private func removeHighlightView(from rowView: NSTableRowView) {
                rowView.subviews
                    .filter { $0.identifier == Self.highlightIdentifier }
                    .forEach { $0.removeFromSuperview() }
            }

            private func configureObservation(for tableView: NSTableView) {
                cleanupObservation()
                guard let clipView = tableView.enclosingScrollView?.contentView else { return }
                observedContentView = clipView
                clipView.postsBoundsChangedNotifications = true
                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    self?.applyHighlights()
                }
            }

            private func cleanupObservation() {
                if let boundsObserver {
                    NotificationCenter.default.removeObserver(boundsObserver)
                    self.boundsObserver = nil
                }
                observedContentView = nil
            }

            private func locateTableView() -> NSTableView? {
                var ancestor: NSView? = self
                for _ in 0..<8 {
                    guard let current = ancestor else { break }
                    if let found = searchTableView(in: current) {
                        return found
                    }
                    ancestor = current.superview
                }
                return nil
            }

            private func searchTableView(in view: NSView) -> NSTableView? {
                if let tableView = view as? NSTableView {
                    return tableView
                }

                for subview in view.subviews {
                    if let found = searchTableView(in: subview) {
                        return found
                    }
                }

                return nil
            }

            private final class RowHighlightView: NSView {
                override var isOpaque: Bool { false }

                override func hitTest(_ point: NSPoint) -> NSView? {
                    nil
                }
            }
        }
    }
#endif

    @ViewBuilder
    private func skillsTableDisplayNameCell(_ row: SkillsTableRow) -> some View {
        switch row {
        case .folderHeader(let folder):
            HStack(spacing: 8) {
                Button {
                    toggleFolderCollapse(folder)
                } label: {
                    Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)

                Image(systemName: "folder.fill")
                    .foregroundStyle(Color.accentColor)

                Text(folder.name)
                    .font(.headline)

                Spacer()

                let count = skills.filter { $0.folder?.stableID == folder.stableID }.count
                Text("\(count) \(count == 1 ? "skill" : "skills")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if bulkUpdatingFolderIDs.contains(folder.stableID) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        case .managed(let skill, let folder):
            HStack(alignment: .center, spacing: 0) {
                Color.clear
                    .frame(width: folder == nil ? 0 : 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: skill))
                    if let override = skill.displayNameOverride,
                       !override.isEmpty {
                        Text("Override")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .onDrag {
                beginDrag(for: skill)
            }
        case .unmanaged(let candidate):
            VStack(alignment: .leading, spacing: 4) {
                Text(unmanagedTitle(for: candidate))
                    .font(.body)

                Text(unmanagedDetectedLine(for: candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .conflict(let conflict):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Conflict")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.35))
                        .clipShape(Capsule())

                    Text(conflict.slug)
                        .font(.body)
                }

                Text(conflictStatesDescription(conflict))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func skillsTableDescriptionCell(_ row: SkillsTableRow) -> some View {
        switch row {
        case .folderHeader:
            EmptyView()
        case .managed(let skill, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(truncatedDescription(for: skill))
                    .lineLimit(5)
                if let override = skill.descriptionOverride,
                   !override.isEmpty {
                    Text("Override")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .unmanaged(let candidate):
            if let description = candidate.skillDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
               !description.isEmpty {
                Text(truncated(description))
                    .lineLimit(5)
            } else if let parseError = candidate.parseError?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !parseError.isEmpty {
                Text("Invalid SKILL.md: \(parseError)")
                    .foregroundStyle(.red)
                    .lineLimit(5)
            } else {
                Text("No description found in SKILL.md.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .conflict:
            Text("Skill differs between Bundler and native exports. Choose which version to keep.")
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private func skillsTableActionsCell(_ row: SkillsTableRow) -> some View {
        switch row {
        case .folderHeader(let folder):
            HStack(spacing: 8) {
                Button {
                    folderNameDraft = folder.name
                    folderValidationError = nil
                    folderEditorMode = .rename(folder)
                } label: {
                    Label("Rename folder", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                        .font(SkillsTableActionStyle.iconFont)
                }
                .buttonStyle(.borderless)
                .frame(width: SkillsTableActionStyle.iconDimension, height: SkillsTableActionStyle.iconDimension)
                .contentShape(Rectangle())
                .help("Rename this folder")
                .tint(SkillsTableActionStyle.iconTint)

                Button(role: .destructive) {
                    folderPendingDeletion = folder
                } label: {
                    Label("Delete folder", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(SkillsTableActionStyle.iconFont)
                        .frame(width: SkillsTableActionStyle.iconDimension, height: SkillsTableActionStyle.iconDimension)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help("Delete this folder")
                .tint(SkillsTableActionStyle.iconTint)
            }
        case .managed(let skill, _):
            HStack(spacing: 8) {
                Button {
                    previewSkill(skill)
                } label: {
                    Label("Preview skill", systemImage: "eye")
                        .labelStyle(.iconOnly)
                        .font(SkillsTableActionStyle.iconFont)
                }
                .buttonStyle(.borderless)
                .frame(width: SkillsTableActionStyle.iconDimension, height: SkillsTableActionStyle.iconDimension)
                .contentShape(Rectangle())
                .help("Preview this skill")
                .tint(SkillsTableActionStyle.iconTint)

                Button {
                    editingSkill = skill
                } label: {
                    Label("Edit skill", systemImage: "square.and.pencil")
                        .labelStyle(.iconOnly)
                        .font(SkillsTableActionStyle.iconFont)
                }
                .buttonStyle(.borderless)
                .frame(width: SkillsTableActionStyle.iconDimension, height: SkillsTableActionStyle.iconDimension)
                .contentShape(Rectangle())
                .help("Edit this skill")
                .tint(SkillsTableActionStyle.iconTint)

                Button(role: .destructive) {
                    skillPendingDeletion = skill
                } label: {
                    Label("Delete skill", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(SkillsTableActionStyle.iconFont)
                        .frame(width: SkillsTableActionStyle.iconDimension, height: SkillsTableActionStyle.iconDimension)
                }
                .buttonStyle(.borderless)
                .contentShape(Rectangle())
                .help("Delete this skill")
                .tint(SkillsTableActionStyle.iconTint)
            }
        case .unmanaged(let candidate):
            HStack(spacing: 8) {
                Button("Preview") { previewCandidate(candidate) }
                    .buttonStyle(.bordered)

                Button("Keep") {
                    Task { await importAndManage(candidate) }
                }
                .buttonStyle(.borderedProminent)

                Button("Ignore") {
                    nativeSync.ignore(candidate)
                }
                .buttonStyle(.bordered)
            }
        case .conflict(let conflict):
            HStack(spacing: 8) {
                Button("Keep Bundler") {
                    Task {
                        await nativeSync.resolve(conflict: conflict,
                                                 keeping: SkillSyncManifest.canonicalTool,
                                                 locations: managedLocationDescriptors)
                    }
                }
                .buttonStyle(.borderedProminent)

                ForEach(conflictResolutionStates(conflict), id: \.locationId) { state in
                    Button("Keep \(state.displayName)") {
                        Task {
                            await nativeSync.resolve(conflict: conflict,
                                                     keeping: state.locationId,
                                                     locations: managedLocationDescriptors)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No skills found")
                .font(.title3)
            Text("Import a folder or archive containing SKILL.md to add reusable instructions.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private func binding(for skill: SkillRecord) -> Binding<Bool> {
        Binding(
            get: { isSkillEnabled(skill) },
            set: { newValue in
                Task { await setSkill(skill, enabled: newValue) }
            }
        )
    }

    private func locationBinding(for skill: SkillRecord, location: SkillSyncLocation) -> Binding<Bool> {
        Binding(get: { isLocationEnabled(skill, location: location) },
                set: { newValue in
                    Task { await setLocationEnabled(skill, location: location, enabled: newValue) }
                })
    }

    private func isSkillEnabled(_ skill: SkillRecord) -> Bool {
        selection(for: skill.slug)?.enabled ?? false
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

    private func selection(for slug: String) -> ProjectSkillSelection? {
        selectionLookup[slug]
    }

    // MARK: - Display Helpers

    private func displayName(for skill: SkillRecord) -> String {
        if let override = skill.displayNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return skill.name
    }

    private func descriptionText(for skill: SkillRecord) -> String {
        if let override = skill.descriptionOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return skill.descriptionText
    }

    private func truncatedDescription(for skill: SkillRecord) -> String {
        let full = descriptionText(for: skill)
        guard full.count > 150 else { return full }
        let prefix = full.prefix(150)
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func unmanagedTitle(for candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) -> String {
        if let name = candidate.skillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }

        switch candidate.source {
        case .directory(let directory):
            return directory.lastPathComponent
        case .rootFile:
            return "SKILL.md (root)"
        }
    }

    private func truncated(_ text: String, limit: Int = 150) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func conflictStatesDescription(_ conflict: NativeSkillsSyncConflict) -> String {
        let changed = conflict.states
            .filter(\.changedFromBaseline)
            .map { $0.displayName }

        if changed.isEmpty {
            return "Changes detected."
        }
        return "Changed in: " + changed.joined(separator: ", ")
    }

    private func conflictResolutionStates(_ conflict: NativeSkillsSyncConflict) -> [NativeSkillsSyncState] {
        conflict.states
            .filter { $0.locationId != SkillSyncManifest.canonicalTool }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
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
    // MARK: - Actions

    private func importSkill() {
        #if os(macOS)
        guard let selectionURL = presentSkillImportPanel() else { return }
        Task {
            await importSkill(from: selectionURL)
        }
        #endif
    }

    private func browseSkillsFolder() {
        #if os(macOS)
        let folderURL = skillsLibraryURL()
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path) {
            NSWorkspace.shared.open(folderURL)
        }
        #endif
    }

    @MainActor
    private func setSkill(_ skill: SkillRecord, enabled: Bool) async {
        do {
            if enabled {
                if let existing = selectionLookup[skill.slug] {
                    existing.setEnabled(true)
                } else {
                    let selection = ProjectSkillSelection(project: project, skillSlug: skill.slug, enabled: true)
                    modelContext.insert(selection)
                    selectionLookup[skill.slug] = selection
                }
            } else if let existing = selectionLookup[skill.slug] {
                modelContext.delete(existing)
                selectionLookup.removeValue(forKey: skill.slug)
            }

            project.markUpdated()
            if modelContext.hasChanges {
                try modelContext.save()
            }

            try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        } catch {
            errorMessage = "Failed to update skill selection: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func updateOverrides(for skill: SkillRecord,
                                 displayName: String?,
                                 description: String?) async {
        let cleanedDisplay = overrideValue(from: displayName, defaultValue: skill.name)
        let cleanedDescription = overrideValue(from: description, defaultValue: skill.descriptionText)

        skill.applyDisplayNameOverride(cleanedDisplay)
        skill.applyDescriptionOverride(cleanedDescription)

        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
            let descriptor = FetchDescriptor<ProjectSkillSelection>()
            let selections = try modelContext.fetch(descriptor)
                .filter { $0.skillSlug == skill.slug && $0.enabled }
            let impacted = selections.compactMap { $0.project }
            let targets = uniqueProjects(impacted + [project])
            project.markUpdated()
            if modelContext.hasChanges {
                try modelContext.save()
            }
            try await rebuildSnapshots(for: targets)
        } catch {
            errorMessage = "Failed to save overrides: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func deleteSkill(_ skill: SkillRecord) async {
        do {
            try await nativeSync.removeExports(for: skill, locations: managedLocationDescriptors)
            try removeSkillFromDisk(skill)
            let impacted = try removeSelections(for: skill.slug)
            modelContext.delete(skill)
            if modelContext.hasChanges {
                try modelContext.save()
            }
            let targets = uniqueProjects(impacted + [project])
            try await rebuildSnapshots(for: targets)
            await reloadSkills(reason: "delete")
        } catch {
            errorMessage = "Failed to delete skill: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importSkill(from url: URL) async {
        do {
            let destination = try copySkillSource(from: url)
            await reloadSkills(reason: "import-\(destination.lastPathComponent)")
            project.markUpdated()
            if modelContext.hasChanges {
                try modelContext.save()
            }
            try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        } catch {
            errorMessage = "Failed to import skill: \(error.localizedDescription)"
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
                _ = try SkillDigest.sha256Hex(forSkillDirectory: directory, fileManager: fileManager)
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
                _ = try SkillDigest.sha256Hex(forFile: skillFile, fileManager: fileManager)
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

    // MARK: - Library Synchronization

    @MainActor
    private func reloadSkills(reason: String) async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        do {
            try await skillsLibrary.reload()
            let infos = await skillsLibrary.list()
            let impacted = try recordSync.synchronizeRecords(with: infos, in: modelContext)
            if !impacted.isEmpty {
                let unique = uniqueProjects(impacted + [project])
                try await rebuildSnapshots(for: unique)
            }
            try refreshSelectionCache()

            if showNativeControls {
                let descriptor = FetchDescriptor<SkillRecord>(sortBy: [SortDescriptor(\SkillRecord.slug, order: .forward)])
                let currentSkills = try modelContext.fetch(descriptor)
                await nativeSync.syncManaged(skills: currentSkills,
                                             enablementsBySkillId: enablementsBySkillId,
                                             locations: managedLocationDescriptors)
                await nativeSync.scanUnmanaged(locations: managedLocationDescriptors)
            }
        } catch {
            errorMessage = "Failed to refresh skills (\(reason)): \(error.localizedDescription)"
        }
    }

    @MainActor
    private func refreshSelectionCache() throws {
        let descriptor = FetchDescriptor<ProjectSkillSelection>()
        let matches = try modelContext.fetch(descriptor)
            .filter { $0.project == project && $0.enabled }
        selectionLookup = [:]

        let sorted = matches.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.createdAt > rhs.createdAt
        }

        var duplicates: [ProjectSkillSelection] = []
        for selection in sorted {
            if selectionLookup[selection.skillSlug] == nil {
                selectionLookup[selection.skillSlug] = selection
            } else {
                duplicates.append(selection)
            }
        }

        if !duplicates.isEmpty {
            log.error("Found \(duplicates.count, privacy: .public) duplicate ProjectSkillSelection rows for project '\(project.name, privacy: .public)'")
            for duplicate in duplicates {
                modelContext.delete(duplicate)
            }
            if modelContext.hasChanges {
                try modelContext.save()
            }
        }
    }

    // MARK: - Folder management

    private enum SkillFolderEditorMode: Identifiable {
        case create
        case rename(SkillFolder)

        var id: String {
            switch self {
            case .create:
                return "create-skill-folder"
            case .rename(let folder):
                return "rename-skill-folder-\(String(describing: folder.stableID))"
            }
        }

        var title: String {
            switch self {
            case .create: return "Add Folder"
            case .rename: return "Rename Folder"
            }
        }

        var folderReference: SkillFolder? {
            switch self {
            case .create: return nil
            case .rename(let folder): return folder
            }
        }
    }

    private func validateFolderName(_ raw: String, excluding existing: SkillFolder? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Folder name cannot be empty." }
        let conflict = folders.contains { folder in
            guard folder !== existing else { return false }
            return folder.name.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
        if conflict { return "A folder with this name already exists." }
        return nil
    }

    @MainActor
    private func createFolder(named name: String) {
        guard validateFolderName(name) == nil else { return }
        let folder = SkillFolder(name: name, isCollapsed: false)
        modelContext.insert(folder)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            errorMessage = "Failed to create folder: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func renameFolder(_ folder: SkillFolder, to name: String) {
        if folder.name.compare(name, options: [.caseInsensitive]) == .orderedSame { return }
        guard validateFolderName(name, excluding: folder) == nil else { return }
        folder.rename(to: name)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            errorMessage = "Failed to rename folder: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func deleteFolder(_ folder: SkillFolder) {
        for skill in skills where skill.folder?.stableID == folder.stableID {
            skill.folder = nil
            skill.markUpdated()
        }
        modelContext.delete(folder)
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            errorMessage = "Failed to delete folder: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func toggleFolderCollapse(_ folder: SkillFolder) {
        folder.isCollapsed.toggle()
        folder.markUpdated()
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            errorMessage = "Failed to save folder state: \(error.localizedDescription)"
        }
    }

    // MARK: - Drag and drop

    private var shouldShowUnfolderDropZone: Bool {
        isDraggingSkill && isDraggingSkillFromFolder
    }

    private var unfolderDropZone: some View {
        let borderColor = isUnfolderDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35)
        let backgroundOpacity = isUnfolderDropTargeted ? 0.22 : 0.12

        return HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isUnfolderDropTargeted ? Color.accentColor : Color.secondary)
            Text("Drop here to remove from folder")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(backgroundOpacity),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
        .padding(10)
        .onDrop(of: [ProjectSkillsView.skillDragType, UTType.text], isTargeted: $isUnfolderDropTargeted) { providers in
            handleDrop(providers: providers, into: nil)
        }
    }

    private func beginDrag(for skill: SkillRecord) -> NSItemProvider {
        isDraggingSkill = true
        isDraggingSkillFromFolder = (skill.folder != nil)
        dragCleanupTask?.cancel()
        dragCleanupTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            } catch {
                return
            }
            endDragSession()
        }

        let idString = skill.skillId
        let provider = NSItemProvider(object: idString as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: ProjectSkillsView.skillDragType.identifier,
                                            visibility: .all) { completion in
            completion(idString.data(using: .utf8), nil)
            return nil
        }
        provider.suggestedName = skill.slug
        return provider
    }

    private func endDragSession() {
        isDraggingSkill = false
        dragCleanupTask?.cancel()
        dragCleanupTask = nil
        isDraggingSkillFromFolder = false
        isUnfolderDropTargeted = false
        skillsTableAutoScroller.stop()
    }

    private func handleDrop(providers: [NSItemProvider], into folder: SkillFolder?) -> Bool {
        endDragSession()

        var handled = false
        for provider in providers {
            let supportsDrop = provider.hasItemConformingToTypeIdentifier(ProjectSkillsView.skillDragType.identifier)
                || provider.canLoadObject(ofClass: NSString.self)
            guard supportsDrop else { continue }
            handled = true

            ItemProviderStringLoader.loadString(from: provider,
                                                typeIdentifier: ProjectSkillsView.skillDragType.identifier) { raw in
                guard let raw else { return }
                Task { @MainActor in
                    guard let skill = skills.first(where: { $0.skillId == raw }) else { return }
                    assign(skill, to: folder)
                }
            }
        }

        return handled
    }

    @MainActor
    private func assign(_ skill: SkillRecord, to folder: SkillFolder?) {
        if let folder, skill.folder?.stableID == folder.stableID { return }
        if folder == nil && skill.folder == nil { return }
        skill.folder = folder
        skill.markUpdated()
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            errorMessage = "Failed to update skill folder: \(error.localizedDescription)"
        }
    }

    // MARK: - Folder bulk actions

    @MainActor
    private func setMcpEnabled(in folder: SkillFolder, enabled: Bool) async {
        guard bulkUpdatingFolderIDs.insert(folder.stableID).inserted else { return }
        defer { bulkUpdatingFolderIDs.remove(folder.stableID) }

        let folderSkills = skills.filter { $0.folder?.stableID == folder.stableID }
        guard !folderSkills.isEmpty else { return }

        do {
            if enabled {
                for skill in folderSkills {
                    if selectionLookup[skill.slug] != nil { continue }
                    let selection = ProjectSkillSelection(project: project, skillSlug: skill.slug, enabled: true)
                    modelContext.insert(selection)
                    selectionLookup[skill.slug] = selection
                }
            } else {
                for skill in folderSkills {
                    if let selection = selectionLookup[skill.slug] {
                        modelContext.delete(selection)
                        selectionLookup.removeValue(forKey: skill.slug)
                    }
                }
            }

            project.markUpdated()
            if modelContext.hasChanges {
                try modelContext.save()
            }

            try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        } catch {
            errorMessage = "Failed to update folder MCP toggles: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func setLocationEnabled(in folder: SkillFolder,
                                    location: SkillSyncLocation,
                                    enabled: Bool) async {
        guard bulkUpdatingFolderIDs.insert(folder.stableID).inserted else { return }
        defer { bulkUpdatingFolderIDs.remove(folder.stableID) }

        let eligible = skills.filter { $0.folder?.stableID == folder.stableID && !$0.isArchive }
        guard !eligible.isEmpty else { return }

        for skill in eligible {
            updateEnablement(skill: skill, location: location, enabled: enabled)
        }

        guard saveEnablementChanges(message: "Failed to save folder export toggles") else { return }

        guard showNativeControls else { return }
        if !enabled {
            let descriptor = SkillSyncLocationDescriptor(locationId: location.locationId,
                                                         displayName: location.displayName,
                                                         rootPath: location.rootPath,
                                                         disabledRootPath: location.disabledRootPath)
            for skill in eligible {
                await nativeSync.applyExport(for: skill, location: descriptor, enabled: false)
            }
        }
        await nativeSync.syncManaged(skills: skills,
                                     enablementsBySkillId: enablementsBySkillId,
                                     locations: managedLocationDescriptors)
    }

    @MainActor
    private func setOtherLocationsEnabled(in folder: SkillFolder, enabled: Bool) async {
        guard bulkUpdatingFolderIDs.insert(folder.stableID).inserted else { return }
        defer { bulkUpdatingFolderIDs.remove(folder.stableID) }

        let locations = otherLocations
        guard !locations.isEmpty else { return }
        let eligible = skills.filter { $0.folder?.stableID == folder.stableID && !$0.isArchive }
        guard !eligible.isEmpty else { return }

        for skill in eligible {
            for location in locations {
                updateEnablement(skill: skill, location: location, enabled: enabled)
            }
        }

        guard saveEnablementChanges(message: "Failed to save folder export toggles") else { return }

        guard showNativeControls else { return }
        if !enabled {
            let descriptors = locations.map { location in
                SkillSyncLocationDescriptor(locationId: location.locationId,
                                            displayName: location.displayName,
                                            rootPath: location.rootPath,
                                            disabledRootPath: location.disabledRootPath)
            }
            for skill in eligible {
                for descriptor in descriptors {
                    await nativeSync.applyExport(for: skill, location: descriptor, enabled: false)
                }
            }
        }
        await nativeSync.syncManaged(skills: skills,
                                     enablementsBySkillId: enablementsBySkillId,
                                     locations: managedLocationDescriptors)
    }

    // MARK: - Helpers

    private func overrideValue(from input: String?, defaultValue: String) -> String? {
        guard let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if trimmed == defaultValue {
            return nil
        }
        return trimmed
    }

    @MainActor
    private func removeSelections(for slug: String) throws -> [Project] {
        let descriptor = FetchDescriptor<ProjectSkillSelection>()
        let matches = try modelContext.fetch(descriptor)
            .filter { $0.skillSlug == slug }
        var affected: [Project] = []
        var seen: Set<PersistentIdentifier> = []
        for selection in matches {
            if let project = selection.project,
               !seen.contains(project.persistentModelID) {
                affected.append(project)
                seen.insert(project.persistentModelID)
            }
            modelContext.delete(selection)
        }
        selectionLookup.removeValue(forKey: slug)
        return affected
    }

    private func removeSkillFromDisk(_ skill: SkillRecord) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: skill.sourcePath) {
            try fm.removeItem(atPath: skill.sourcePath)
        }
    }

    private func copySkillSource(from url: URL) throws -> URL {
        let root = skillsLibraryURL()
        let fm = FileManager.default

        let standardizedURL = url.standardizedFileURL
        if !standardizedURL.hasDirectoryPath {
            let ext = standardizedURL.pathExtension.lowercased()
            if ext == "zip" || ext == "skill" {
                return try SkillArchiveMaterializer.materializeArchive(at: standardizedURL, to: root, fileManager: fm)
            }
        }

        // If the file already resides in the skills directory, reuse it.
        if standardizedURL.path.hasPrefix(root.standardizedFileURL.path) {
            return standardizedURL
        }

        let destination = uniqueDestination(for: standardizedURL, root: root)
        try fm.copyItem(at: standardizedURL, to: destination)
        return destination
    }

    private func previewSkill(_ skill: SkillRecord) {
        Task { await loadPreview(for: skill) }
    }

    private func previewCandidate(_ candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) {
        Task { await loadPreview(for: candidate) }
    }

    @MainActor
    private func loadPreview(for skill: SkillRecord) async {
        do {
            try await skillsLibrary.reload()
            let infos = await skillsLibrary.list()
            guard let info = infos.first(where: { $0.slug == skill.slug }) else {
                errorMessage = "Skill \(skill.slug) is missing from the library."
                return
            }
            let instructions = try await skillsLibrary.readInstructions(slug: info.slug)
            previewData = SkillPreviewData(
                slug: info.slug,
                displayName: displayName(for: skill),
                description: descriptionText(for: skill),
                instructions: instructions,
                license: info.license,
                allowedTools: info.allowedTools,
                extra: info.extra,
                resources: info.resources
            )
        } catch {
            errorMessage = "Failed to load preview: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadPreview(for candidate: NativeSkillsSyncService.UnmanagedSkillCandidate) async {
        let fileManager = FileManager.default
        let previewRoot = fileManager.temporaryDirectory
            .appendingPathComponent("mcp-bundler-unmanaged-preview-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: previewRoot, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: previewRoot) }

            switch candidate.source {
            case .directory(let directory):
                let destination = previewRoot.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
                try fileManager.copyItem(at: directory, to: destination)

            case .rootFile(let skillFile):
                let destination = previewRoot.appendingPathComponent("candidate", isDirectory: true)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                let destinationFile = destination.appendingPathComponent("SKILL.md", isDirectory: false)
                try fileManager.copyItem(at: skillFile, to: destinationFile)
            }

            let previewLibrary = SkillsLibraryService(root: previewRoot, fileManager: fileManager)
            try await previewLibrary.reload()
            let infos = await previewLibrary.list()
            guard let info = infos.first else {
                throw SkillsLibraryError.invalidSkill("Candidate does not contain a valid SKILL.md")
            }
            let instructions = try await previewLibrary.readInstructions(slug: info.slug)
            previewData = SkillPreviewData(
                slug: info.slug,
                displayName: info.name,
                description: info.description,
                instructions: instructions,
                license: info.license,
                allowedTools: info.allowedTools,
                extra: info.extra,
                resources: info.resources
            )
        } catch {
            errorMessage = "Failed to load preview: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func rebuildSnapshots(for projects: [Project]) async throws {
        for target in uniqueProjects(projects) {
            try await ProjectSnapshotCache.rebuildSnapshot(for: target)
        }
    }

    @MainActor
    private func uniqueProjects(_ projects: [Project]) -> [Project] {
        var seen: Set<PersistentIdentifier> = []
        var result: [Project] = []
        for project in projects {
            let id = project.persistentModelID
            if !seen.contains(id) {
                seen.insert(id)
                result.append(project)
            }
        }
        return result
    }

    private func uniqueDestination(for source: URL, root: URL) -> URL {
        let fm = FileManager.default
        var candidate = root.appendingPathComponent(source.lastPathComponent, isDirectory: source.hasDirectoryPath)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        let baseName = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            let suffix = "\(baseName)-\(counter)"
            if ext.isEmpty {
                candidate = root.appendingPathComponent(suffix, isDirectory: source.hasDirectoryPath)
            } else {
                candidate = root.appendingPathComponent(suffix).appendingPathExtension(ext)
            }
            counter += 1
        }
        return candidate
    }

    #if os(macOS)
    private func presentSkillImportPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Import Skill"
        panel.message = "Select a skill folder or archive (.zip or .skill)."

        let supportedTypes: [UTType] = [
            UTType.zip,
            UTType(filenameExtension: "skill") ?? .data
        ]
        panel.allowedContentTypes = supportedTypes

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return nil }
        if url.hasDirectoryPath {
            return url
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "skill" else {
            errorMessage = "Selected file must be a folder, .zip, or .skill archive."
            return nil
        }
        return url
    }
    #else
    #endif
}

// MARK: - Override Editor

private struct SkillOverrideEditor: View {
    @Environment(\.dismiss) private var dismiss

    let skill: SkillRecord
    let onSave: (String?, String?) -> Void

    @State private var displayName: String = ""
    @State private var descriptionText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Skill Overrides")
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Display Name")
                    .font(.headline)
                TextField(skill.name, text: $displayName, prompt: Text(skill.name))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Description")
                    .font(.headline)
                TextField(skill.descriptionText,
                          text: $descriptionText,
                          prompt: Text(skill.descriptionText),
                          axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 160)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Reset") {
                    displayName = skill.name
                    descriptionText = skill.descriptionText
                }
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Save") {
                    onSave(displayName, descriptionText)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear {
            displayName = skill.displayNameOverride ?? skill.name
            descriptionText = skill.descriptionOverride ?? skill.descriptionText
        }
    }
}

private struct SkillPreviewData: Identifiable {
    let id = UUID()
    let slug: String
    let displayName: String
    let description: String
    let instructions: String
    let license: String?
    let allowedTools: [String]
    let extra: [String: String]
    let resources: [SkillResourceInfo]
}

private struct SkillPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let data: SkillPreviewData

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(data.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text("Slug: \(data.slug)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if !data.description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description").font(.headline)
                            Text(data.description)
                                .foregroundStyle(.secondary)
                        }
                    }

                    metadataSection

                    if !data.resources.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resources")
                                .font(.headline)
                            ForEach(data.resources, id: \.relativePath) { resource in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(resource.relativePath)
                                        .font(.body)
                                    if let mime = resource.mimeType {
                                        Text(mime)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Instructions")
                            .font(.headline)
                        Text(data.instructions)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 600, minHeight: 500)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata").font(.headline)

            if let license = data.license, !license.isEmpty {
                detailRow(title: "License", value: license)
            }

            if !data.allowedTools.isEmpty {
                let value = data.allowedTools.joined(separator: ", ")
                detailRow(title: "Allowed Tools", value: value)
            }

            if !data.extra.isEmpty {
                ForEach(data.extra.keys.sorted(), id: \.self) { key in
                    if let value = data.extra[key], !value.isEmpty {
                        detailRow(title: key, value: value)
                    }
                }
            }
        }
    }

    private func detailRow(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
