//
//  ProjectDetailView.swift
//  MCP Bundler
//
//  Displays the primary project management surface, including
//  server lists, environment configuration, and headless controls.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct ProjectPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Create your first project").font(.title2)
            Text("Group your MCP servers and switch contexts.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProjectDetailView: View {
    private static let serverDragType = UTType(exportedAs: "xyz.maketry.mcpbundler.server-token")

    @Environment(\.modelContext) private var modelContext
    @Environment(\.stdiosessionController) private var stdiosessionController
    @EnvironmentObject private var toastCenter: ToastCenter
    @EnvironmentObject private var installLinkCoordinator: InstallLinkCoordinator
    @Query private var allProjects: [Project]
    @Query private var locations: [SkillSyncLocation]

    @StateObject private var importClientStore: ImportClientStore
    @State private var showingAddServer = false
    @State private var editingServer: Server?
    @State private var serverToDelete: Server?
    @State private var selectedTab: DetailTab = .main
    @State private var mainSection: MainSection = .servers
    @State private var activeImportClient: ImportClientDescriptor?
    @State private var showingManualImport = false
    @State private var highlightOpacities: [UUID: Double] = [:]
    @State private var highlightTasks: [UUID: Task<Void, Never>] = [:]
    @State private var installLinkPresentation: InstallLinkPresentation?
    @State private var folderEditorMode: FolderEditorMode?
    @State private var folderNameDraft: String = ""
    @State private var folderValidationError: String?
    @State private var folderToDelete: ProviderFolder?
    @State private var isUnfolderDropTargeted: Bool = false
    @State private var isDraggingServer: Bool = false
    @State private var isDraggingServerFromFolder: Bool = false
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var serversTableView: NSTableView?
    @State private var serversTableAutoScroller = TableAutoScroller()
    @State private var ignoredSkillRules: [NativeSkillsSyncIgnoreRule] = []

    private let importer = ExternalConfigImporter()
    var project: Project

    init(project: Project) {
        self.project = project
        _importClientStore = StateObject(wrappedValue: ImportClientStore(executablePath: ProjectDetailView.resolveExecutablePath()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tabSelector

            Group {
                switch selectedTab {
                case .main:
                    mainTab
                case .logs:
                    logsTab
                case .settings:
                    settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding()
        .sheet(isPresented: $showingAddServer) {
            AddServerSheet(project: project)
                .frame(minWidth: 640, minHeight: 560)
        }
        .sheet(item: $editingServer) { server in
            ServerDetailSheet(server: server)
        }
        .sheet(item: $activeImportClient) { client in
            ImportServerPickerView(source: .client(client),
                                   importer: importer,
                                   project: project,
                                   onImported: handleImportResult,
                                   onReadFailure: handleImportFailure,
                                   onImportSummary: handleImportSummary)
        }
        .sheet(isPresented: $showingManualImport) {
            ImportJSONModalView(importer: importer,
                                project: project,
                                knownFormats: importClientStore.knownFormats,
                                onImported: handleImportResult,
                                onImportSummary: handleImportSummary)
        }
        .sheet(item: $installLinkPresentation) { presentation in
            ImportServerPickerView(source: .preloaded(description: presentation.description,
                                                      result: presentation.parseResult),
                                   importer: importer,
                                   project: project,
                                   onImported: handleImportResult,
                                   onReadFailure: handleImportFailure,
                                   onImportSummary: handleImportSummary)
        }
        .sheet(item: $folderEditorMode) { mode in
            NameEditSheet(title: mode.title,
                          placeholder: "Folder name",
                          name: $folderNameDraft,
                          validationError: $folderValidationError,
                          onSave: { name in
                              let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
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
        .alert("Delete Server?", isPresented: Binding(
            get: { serverToDelete != nil },
            set: { if !$0 { serverToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let server = serverToDelete {
                    let event = makeEvent(for: server, type: .serverRemoved)
                    modelContext.delete(server)
                    saveContext(events: [event], rebuildSnapshots: true)
                }
                serverToDelete = nil
            }
            Button("Cancel", role: .cancel) { serverToDelete = nil }
        } message: {
            if let alias = serverToDelete?.alias {
                Text("Are you sure you want to delete \"\(alias)\"? This removes the server and its cached capabilities.")
            } else {
                Text("Are you sure you want to delete this server? This removes the server and its cached capabilities.")
            }
        }
        .alert("Delete Folder?", isPresented: Binding(
            get: { folderToDelete != nil },
            set: { if !$0 { folderToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let folder = folderToDelete {
                    deleteFolder(folder)
                }
                folderToDelete = nil
            }
            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            if let name = folderToDelete?.name {
                Text("Delete folder \"\(name)\"? Servers will remain in the project as unfoldered.")
            } else {
                Text("Delete this folder? Servers will remain in the project as unfoldered.")
            }
        }
        .onReceive(installLinkCoordinator.$pendingPresentation) { _ in
            presentPendingInstallLinkIfNeeded()
        }
        .onAppear(perform: presentPendingInstallLinkIfNeeded)
    }

    // MARK: - Tab Views

    private var tabSelector: some View {
        HStack {
            Spacer()
            Picker("Section", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            Spacer()
        }
    }

    private var mainSectionPicker: some View {
        HStack {
            Spacer()
            Picker("Main Section", selection: $mainSection) {
                ForEach(MainSection.allCases) { section in
                    Text(section.title)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .labelsHidden()
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.thinMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            Spacer()
        }
    }

    private var mainTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            descriptionField
            mainSectionPicker
            Divider()

            switch mainSection {
            case .servers:
                serversContent
            case .skills:
                skillsContent
            }

            Divider()
            headlessSection

            Spacer()
        }
    }

    private var settingsTab: some View {
        List {
            SkillSyncLocationsView(displayStyle: .embedded)
            SkillMarketplaceSourcesView()

            if !ignoredSkillRules.isEmpty {
                skillsIgnoredSection
            }

            Section {
                settingsToggleRow(
                    icon: "eye.slash",
                    tint: .accentColor,
                    title: "Hide MCP tools under Search/Call Tools",
                    subtitle: "Show only search/call meta tools in the Tools menu while keeping full access via search.",
                    binding: contextOptimizationsBinding
                )
                settingsToggleRow(
                    icon: "wand.and.stars",
                    tint: .accentColor,
                    title: "Hide Skills for clients with native skills support (Claude, Codex)",
                    subtitle: "Hide Skills tools and resources for Claude Code and Codex MCP clients.",
                    binding: hideSkillsForNativeClientsBinding
                )
                settingsToggleRow(
                    icon: "text.document",
                    tint: .accentColor,
                    title: "Store large tool responses as files",
                    subtitle: "Writes oversized text replies to /tmp and returns a link instead of streaming everything inline.",
                    binding: largeResponseToggleBinding
                )
                if project.storeLargeToolResponsesAsFiles {
                    settingsThresholdRow
                }
            } header: {
                Text("Optimizations")
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .task {
            loadIgnoredSkillRules()
        }
    }

    private var skillsIgnoredSection: some View {
        Section {
            ForEach(ignoredSkillRules, id: \.self) { rule in
                settingsRow(
                    icon: ignoredToolIcon(for: rule.tool),
                    tint: .gray,
                    title: ignoredSkillTitle(for: rule),
                    subtitle: "\(ignoredToolTitle(for: rule.tool)): \(rule.directoryPath)"
                ) {
                    Button("Remove") {
                        let store = NativeSkillsSyncIgnoreStore()
                        store.removeIgnore(tool: rule.tool, directoryPath: rule.directoryPath)
                        loadIgnoredSkillRules()
                    }
                    .buttonStyle(.bordered)
                }
            }
        } header: {
            HStack {
                Text("Ignored Skills")
                Spacer()
                Button("Clear All") {
                    let store = NativeSkillsSyncIgnoreStore()
                    store.save([])
                    loadIgnoredSkillRules()
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Ignored skills are hidden from the “Detected in …” list across all projects.")
        }
    }

    private func loadIgnoredSkillRules() {
        let store = NativeSkillsSyncIgnoreStore()
        ignoredSkillRules = store.load()
            .sorted { lhs, rhs in
                let toolOrder = lhs.tool.localizedCaseInsensitiveCompare(rhs.tool)
                if toolOrder != .orderedSame {
                    return toolOrder == .orderedAscending
                }
                return lhs.directoryPath.localizedCaseInsensitiveCompare(rhs.directoryPath) == .orderedAscending
        }
    }

    private func ignoredSkillTitle(for rule: NativeSkillsSyncIgnoreRule) -> String {
        let trimmed = rule.directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Skill" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    private func ignoredToolTitle(for tool: String) -> String {
        if let location = locations.first(where: { $0.locationId == tool }) {
            return location.displayName
        }
        switch tool.lowercased() {
        case "claude":
            return "Claude Code"
        case "codex":
            return "Codex"
        default:
            return tool
        }
    }

    private func ignoredToolIcon(for tool: String) -> String {
        switch tool.lowercased() {
        case "claude":
            return "c.square"
        case "codex":
            return "terminal"
        default:
            return "eye.slash"
        }
    }

    private func settingsToggleRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        binding: Binding<Bool>
    ) -> some View {
        settingsRow(
            icon: icon,
            tint: tint,
            title: title,
            subtitle: subtitle
        ) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.regular)
        }
    }

    private var settingsThresholdRow: some View {
        settingsRow(
            icon: "gauge.with.dots.needle.100percent",
            tint: .accentColor,
            title: "Threshold",
            subtitle: "Characters before the response is written to disk."
        ) {
            HStack(spacing: 18) {
                Text(project.largeToolResponseThreshold.formatted())
                    .font(.title3.monospacedDigit())
                    .frame(minWidth: 70, alignment: .trailing)

                Stepper("", value: largeResponseThresholdBinding, in: 500...50000, step: 500)
                    .labelsHidden()
                    .controlSize(.regular)
            }
            .disabled(!project.storeLargeToolResponsesAsFiles)
        }
    }

    @ViewBuilder
    private func settingsRow<Content: View>(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            tint.opacity(0.28),
                            tint.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.white)
                )
                .frame(width: 38, height: 38)
                .shadow(color: tint.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 6)
    }

    private var contextOptimizationsBinding: Binding<Bool> {
        Binding(
            get: { project.contextOptimizationsEnabled },
            set: { newValue in
                guard project.contextOptimizationsEnabled != newValue else { return }
                project.contextOptimizationsEnabled = newValue
                saveContext()
            }
        )
    }

    private var hideSkillsForNativeClientsBinding: Binding<Bool> {
        Binding(
            get: { project.hideSkillsForNativeClients },
            set: { newValue in
                guard project.hideSkillsForNativeClients != newValue else { return }
                project.hideSkillsForNativeClients = newValue
                let event = makeSnapshotEvent(for: project)
                saveContext(events: [event], rebuildSnapshots: false)
            }
        )
    }

    private var largeResponseToggleBinding: Binding<Bool> {
        Binding(
            get: { project.storeLargeToolResponsesAsFiles },
            set: { newValue in
                guard project.storeLargeToolResponsesAsFiles != newValue else { return }
                project.storeLargeToolResponsesAsFiles = newValue
                let event = makeSnapshotEvent(for: project)
                saveContext(events: [event], rebuildSnapshots: false)
            }
        )
    }

    private var largeResponseThresholdBinding: Binding<Int> {
        Binding(
            get: { project.largeToolResponseThreshold },
            set: { newValue in
                let sanitized = max(0, newValue)
                guard project.largeToolResponseThreshold != sanitized else { return }
                project.largeToolResponseThreshold = sanitized
                let event = makeSnapshotEvent(for: project)
                saveContext(events: [event], rebuildSnapshots: false)
            }
        )
    }

    private var serversContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            serversSection
            if showProjectEnvironmentSection {
                Divider()
                projectEnvironmentSection
            }
        }
    }

    private var skillsContent: some View {
        ProjectSkillsView(project: project)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var logsTab: some View {
        LogsView(project: project)
    }

    // MARK: - Supporting Types

    private enum DetailTab: String, CaseIterable, Identifiable {
        case main
        case logs
        case settings

        var id: Self { self }

        var title: String {
            switch self {
            case .main: "Main"
            case .logs: "Project Logs"
            case .settings: "Project Settings"
            }
        }
    }

    private enum MainSection: String, CaseIterable, Identifiable {
        case servers
        case skills

        var id: Self { self }

        var title: String {
            switch self {
            case .servers: "Servers"
            case .skills: "Skills"
            }
        }
    }

    private enum FolderEditorMode: Identifiable {
        case create
        case rename(ProviderFolder)

        var id: String {
            switch self {
            case .create:
                return "create-folder"
            case .rename(let folder):
                return "rename-\(String(describing: folder.stableID))"
            }
        }

        var title: String {
            switch self {
            case .create: return "Add Folder"
            case .rename: return "Rename Folder"
            }
        }

        var folderReference: ProviderFolder? {
            switch self {
            case .create: return nil
            case .rename(let folder): return folder
            }
        }
    }

    private enum RowID: Hashable {
        case folderHeader(PersistentIdentifier)
        case server(PersistentIdentifier)
    }

    private struct RowItem: Identifiable {
        enum Kind {
            case folderHeader(ProviderFolder)
            case server(Server, ProviderFolder?)
        }
        let id: RowID
        let kind: Kind
    }

    private struct ServersTableDropDelegate: DropDelegate {
        var rowItems: [RowItem]
        var tableView: NSTableView?
        var autoScroller: TableAutoScroller
        var onDrop: (_ providers: [NSItemProvider], _ folder: ProviderFolder?) -> Bool

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [ProjectDetailView.serverDragType, UTType.text])
        }

        func dropExited(info: DropInfo) {
            autoScroller.stop()
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            guard let tableView, let pointerLocation = TablePointerLocator.pointerLocation(in: tableView) else {
                autoScroller.stop()
                return DropProposal(operation: .cancel)
            }

            autoScroller.update(tableView: tableView, pointerLocation: pointerLocation)

            let row = tableView.row(at: pointerLocation)
            guard (0..<rowItems.count).contains(row) else {
                return DropProposal(operation: .cancel)
            }
            return DropProposal(operation: .move)
        }

        func performDrop(info: DropInfo) -> Bool {
            autoScroller.stop()
            guard let tableView, let pointerLocation = TablePointerLocator.pointerLocation(in: tableView) else { return false }

            let row = tableView.row(at: pointerLocation)
            guard (0..<rowItems.count).contains(row) else { return false }

            let folder = folderTarget(for: rowItems[row])
            let providers = info.itemProviders(for: [ProjectDetailView.serverDragType, UTType.text])
            return onDrop(providers, folder)
        }

        private func folderTarget(for item: RowItem) -> ProviderFolder? {
            switch item.kind {
            case .folderHeader(let folder):
                return folder
            case .server(_, let folder):
                return folder
            }
        }

    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Project name", text: Binding(
                get: { project.name },
                set: { project.rename(to: $0) }
            ))
            .textFieldStyle(.roundedBorder)

            Button(project.isActive ? "Active" : "Set Active") {
                setActive(project)
            }
            .buttonStyle(.borderedProminent)
            .tint(project.isActive ? .green : .accentColor)
        }
    }

    private var descriptionField: some View {
        TextField("Description", text: Binding(
            get: { project.details ?? "" },
            set: { project.updateDetails($0) }
        ))
        .textFieldStyle(.roundedBorder)
    }

    private var serversSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Servers").font(.headline)
                Spacer()
                Button { showingAddServer = true } label: { Label("Add Server", systemImage: "plus") }
                Button {
                    folderNameDraft = ""
                    folderValidationError = nil
                    folderEditorMode = .create
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                Menu {
                    if importClientStore.clients.isEmpty {
                        Button("No importable configs found") {}
                            .disabled(true)
                    } else {
                        ForEach(importClientStore.clients) { client in
                            Button(client.displayName) {
                                activeImportClient = client
                            }
                        }
                    }
                    Divider()
                    Button("Import JSON/TOML…") {
                        showingManualImport = true
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.automatic)
            }

            ZStack(alignment: .bottom) {
                Table(rowItems) {
                    TableColumn("") { item in
                        switch item.kind {
                        case .folderHeader(let folder):
                            Toggle("", isOn: Binding(
                                get: { folder.isEnabled },
                                set: { newValue in setFolderEnabled(folder, isEnabled: newValue) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Enable/disable all servers in this folder")
                        case .server(let server, let folder):
                            let folderDisabled = (folder?.isEnabled == false)
                            Toggle("", isOn: Binding(
                                get: { folderDisabled ? false : server.isEnabled },
                                set: { newValue in
                                    if folderDisabled && newValue {
                                        return
                                    }
                                    server.isEnabled = newValue
                                    let event = makeEvent(for: server,
                                                          type: newValue ? .serverEnabled : .serverDisabled)
                                    saveContext(events: [event], rebuildSnapshots: true)
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .help("Enable/disable server")
                            .disabled(folderDisabled)
                            .background(rowHighlight(for: server))
                        }
                }
                .width(min: enableColumnWidth, ideal: enableColumnWidth)

                TableColumn("Name") { item in
                    switch item.kind {
                    case .folderHeader(let folder):
                        HStack(spacing: 8) {
                            Button {
                                toggleFolderCollapse(folder)
                            } label: {
                                Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            Image(systemName: folder.isEnabled ? "folder.fill" : "folder")
                                .foregroundStyle(folder.isEnabled ? Color.accentColor : Color.secondary)
                            Text(folder.name)
                                .font(.headline)
                            Spacer()
                            let count = folderServerCount(folder)
                            Text("\(count) \(count == 1 ? "server" : "servers")")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    case .server(let server, let folder):
                        let effectiveEnabled = server.isEffectivelyEnabled
                        let disabledByFolder = (folder != nil && (folder?.isEnabled == false))
                        HStack(alignment: .top, spacing: 0) {
                            Color.clear
                                .frame(width: folder == nil ? 0 : 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(server.alias)
                                        .foregroundStyle(effectiveEnabled ? Color.primary : Color.secondary)
                                    if disabledByFolder {
                                        Label("Disabled by folder", systemImage: "lock.fill")
                                            .labelStyle(.titleAndIcon)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text(serverKindLabel(for: server))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if server.kind == .remote_http_sse && server.usesOAuthAuthorization {
                                    OAuthStatusIndicator(status: server.oauthStatus)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(rowHighlight(for: server))
                        .onDrag {
                            beginDrag(for: server, source: "name")
                        }
                    }
                }
                .width(min: 220, ideal: 260)

                TableColumn("Tools") { item in
                    if case .server(let server, _) = item.kind {
                        HStack {
                            Text("\(totalTools(for: server))")
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(rowHighlight(for: server))
                        .onDrag {
                            beginDrag(for: server, source: "tools")
                        }
                    }
                }
                .width(min: toolsColumnWidth, ideal: toolsColumnWidth)

                TableColumn("Active Tools") { item in
                    if case .server(let server, _) = item.kind {
                        HStack {
                            Text("\(activeTools(for: server))")
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(rowHighlight(for: server))
                        .onDrag {
                            beginDrag(for: server, source: "activeTools")
                        }
                    }
                }
                .width(min: activeToolsColumnWidth, ideal: activeToolsColumnWidth)

                TableColumn("Status") { item in
                    if case .server(let server, _) = item.kind {
                        HStack {
                            HealthBadge(status: server.lastHealth)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(rowHighlight(for: server))
                        .onDrag {
                            beginDrag(for: server, source: "status")
                        }
                    }
                }
                .width(min: statusColumnWidth, ideal: statusColumnWidth)

                TableColumn("Actions") { item in
                    switch item.kind {
                    case .folderHeader(let folder):
                        HStack(spacing: 6) {
                            Menu {
                                Button {
                                    copyFolder(folder, into: project)
                                } label: {
                                    Label("Duplicate in \(project.name)", systemImage: "square.on.square")
                                }

                                let destinationProjects = allProjects.filter { $0 !== project }
                                if !destinationProjects.isEmpty {
                                    Divider()
                                    Menu("Copy to Project") {
                                        ForEach(Array(destinationProjects.enumerated()), id: \.offset) { pair in
                                            let destination = pair.element
                                            Button {
                                                copyFolder(folder, into: destination)
                                            } label: {
                                                Text(destination.name)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Copy folder", systemImage: "square.on.square")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: actionIconDimension, height: actionIconDimension)
                            .contentShape(Rectangle())
                            .help("Duplicate or copy this folder to another project")
                            .tint(actionIconTint)

                            Button {
                                folderNameDraft = folder.name
                                folderValidationError = nil
                                folderEditorMode = .rename(folder)
                            } label: {
                                Label("Rename folder", systemImage: "square.and.pencil")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                            }
                            .buttonStyle(.borderless)
                            .frame(width: actionIconDimension, height: actionIconDimension)
                            .contentShape(Rectangle())
                            .help("Rename this folder")
                            .tint(actionIconTint)

                            Button {
                                folderToDelete = folder
                            } label: {
                                Label("Delete folder", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                                    .frame(width: actionIconDimension, height: actionIconDimension)
                            }
                            .buttonStyle(.borderless)
                            .contentShape(Rectangle())
                            .help("Delete this folder")
                            .tint(actionIconTint)
                        }
                    case .server(let server, _):
                        HStack(spacing: 6) {
                            Menu {
                                Button {
                                    duplicate(server, into: project)
                                } label: {
                                    Label("Duplicate in \(project.name)", systemImage: "square.on.square")
                                }

                                let destinationProjects = allProjects.filter { $0 !== project }

                                if !destinationProjects.isEmpty {
                                    Divider()
                                    Menu("Copy to Project") {
                                        ForEach(Array(destinationProjects.enumerated()), id: \.offset) { pair in
                                            let destination = pair.element
                                            Button {
                                                duplicate(server, into: destination)
                                            } label: {
                                                Text(destination.name)
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Duplicate", systemImage: "square.on.square")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: actionIconDimension, height: actionIconDimension)
                            .contentShape(Rectangle())
                            .help("Duplicate or copy this server to another project")
                            .tint(actionIconTint)

                            Button {
                                showingAddServer = false
                                editingServer = server
                            } label: {
                                Label("Edit server", systemImage: "square.and.pencil")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                            }
                            .buttonStyle(.borderless)
                            .frame(width: actionIconDimension, height: actionIconDimension)
                            .contentShape(Rectangle())
                            .help("Edit this server")
                            .tint(actionIconTint)

                            Button {
                                serverToDelete = server
                            } label: {
                                Label("Delete server", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                                    .font(actionIconFont)
                                    .frame(width: actionIconDimension, height: actionIconDimension)
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .contentShape(Rectangle())
                            .help("Remove this server from the project")
                            .tint(actionIconTint)
                        }
                        .background(rowHighlight(for: server))
                    }
                }
                .width(min: actionsColumnWidth, ideal: actionsColumnWidth)
            }
            .onDrop(of: [ProjectDetailView.serverDragType, UTType.text],
                    delegate: ServersTableDropDelegate(rowItems: rowItems,
                                                      tableView: serversTableView,
                                                      autoScroller: serversTableAutoScroller,
                                                      onDrop: handleDrop))
            .background(TableViewAccessor(tableView: $serversTableView))
            .padding(.bottom, shouldShowUnfolderDropZone ? 64 : 0)
                if shouldShowUnfolderDropZone {
                    unfolderDropZone
                }
            }
            .frame(minHeight: 200)
        }
    }

    private var showProjectEnvironmentSection: Bool { false }

    private var projectEnvironmentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Environment (Project)").font(.headline)
                Spacer()
                Button { addEnvVar(to: project) } label: { Label("Add", systemImage: "plus") }
            }
            EnvEditor(envVars: project.envVars.sorted(by: { $0.position < $1.position }), onDelete: { env in
                if let idx = project.envVars.firstIndex(where: { $0 === env }) {
                    project.envVars.remove(at: idx)
                    project.envVars.normalizeEnvPositions()
                    saveContext()
                }
            })
        }
    }

    private var headlessSection: some View {
        HeadlessConnectionView(executablePath: headlessExecutablePath)
    }

    private var headlessExecutablePath: String {
        ProjectDetailView.resolveExecutablePath()
    }

    private var actionIconFont: Font { .system(size: 15, weight: .regular) }
    private var actionIconTint: Color { .primary }
    private var actionIconDimension: CGFloat { 28 }
    private var enableColumnWidth: CGFloat { 60 }
    private var toolsColumnWidth: CGFloat { 70 }
    private var activeToolsColumnWidth: CGFloat { 110 }
    private var statusColumnWidth: CGFloat { 120 }
    private var actionsColumnWidth: CGFloat { 140 }

    private var shouldShowUnfolderDropZone: Bool {
        isDraggingServer && isDraggingServerFromFolder
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
        .onDrop(of: [ProjectDetailView.serverDragType, UTType.text], isTargeted: $isUnfolderDropTargeted) { providers in
            handleDrop(providers: providers, into: nil)
        }
    }

    private struct PendingEvent {
        let projectToken: UUID
        let type: BundlerEvent.EventType
        let serverTokens: [UUID]
    }

    private func duplicate(_ server: Server, into target: Project) {
        let service = ServerDuplicationService(modelContext: modelContext)
        let clone = service.duplicate(server, into: target)

        let events = [makeEvent(for: clone, type: .serverAdded)]

        if target === project {
            saveContext(events: events, rebuildSnapshots: true)
            editingServer = clone
        } else {
            saveContext(extraProjects: [target], events: events, rebuildSnapshots: true)
        }
    }

    private func copyFolder(_ folder: ProviderFolder, into target: Project) {
        let service = ServerDuplicationService(modelContext: modelContext)
        let folderName = makeUniqueFolderName(for: folder.name, in: target)
        let cloneFolder = ProviderFolder(project: target,
                                         name: folderName,
                                         isEnabled: folder.isEnabled,
                                         isCollapsed: false)
        modelContext.insert(cloneFolder)
        if !target.folders.contains(where: { $0 === cloneFolder }) {
            target.folders.append(cloneFolder)
        }

        let members = project.servers
            .filter { $0.folder?.stableID == folder.stableID }
            .sorted { lhs, rhs in lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending }

        var events: [PendingEvent] = []
        for server in members {
            let cloneServer = service.duplicate(server, into: target)
            cloneServer.folder = cloneFolder
            if cloneFolder.isEnabled == false {
                cloneServer.isEnabled = false
            }
            events.append(makeEvent(for: cloneServer, type: .serverAdded))
        }

        if events.isEmpty {
            if target === project {
                saveContext(rebuildSnapshots: false)
            } else {
                saveContext(extraProjects: [target], rebuildSnapshots: false)
            }
        } else {
            if target === project {
                saveContext(events: events, rebuildSnapshots: true)
            } else {
                saveContext(extraProjects: [target], events: events, rebuildSnapshots: true)
            }
        }
        if target === project {
            toastCenter.push(text: "Duplicated folder", style: .success)
        } else {
            toastCenter.push(text: "Copied folder to \(target.name)", style: .success)
        }
    }

    private func makeUniqueFolderName(for rawName: String, in project: Project) -> String {
        let base = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            return fallbackFolderName(in: project)
        }

        if !projectContainsFolderName(base, in: project) {
            return base
        }

        var suffix = 2
        var candidate = "\(base)-copy"
        if !projectContainsFolderName(candidate, in: project) {
            return candidate
        }

        while true {
            candidate = "\(base)-copy-\(suffix)"
            if !projectContainsFolderName(candidate, in: project) {
                return candidate
            }
            suffix += 1
        }
    }

    private func projectContainsFolderName(_ name: String, in project: Project) -> Bool {
        project.folders.contains { folder in
            folder.name.compare(name, options: [.caseInsensitive]) == .orderedSame
        }
    }

    private func fallbackFolderName(in project: Project) -> String {
        var suffix = 1
        while true {
            let candidate = "folder-\(suffix)"
            if !projectContainsFolderName(candidate, in: project) {
                return candidate
            }
            suffix += 1
        }
    }

    private func makeEvent(for server: Server, type: BundlerEvent.EventType) -> PendingEvent {
        let projectToken = (server.project ?? project).eventToken
        return PendingEvent(projectToken: projectToken, type: type, serverTokens: [server.eventToken])
    }

    private func makeSnapshotEvent(for project: Project) -> PendingEvent {
        PendingEvent(projectToken: project.eventToken, type: .snapshotRebuilt, serverTokens: [])
    }

    private func saveContext(extraProjects: [Project] = [],
                             events: [PendingEvent] = [],
                             rebuildSnapshots: Bool = false) {
        do {
            try modelContext.save()
            guard rebuildSnapshots || !events.isEmpty else { return }
            let targets = [project] + extraProjects
            Task { @MainActor in
                var processed: Set<ObjectIdentifier> = []
                for candidate in targets {
                    let identifier = ObjectIdentifier(candidate)
                    if processed.insert(identifier).inserted {
                        if rebuildSnapshots {
                            try? await ProjectSnapshotCache.rebuildSnapshot(for: candidate)
                        }
                        let candidateToken = candidate.eventToken
                        let matching = events.filter { $0.projectToken == candidateToken }
                        var aggregatedTokens = Set<UUID>()
                        if matching.isEmpty {
                            // fall through and reload the entire project to keep preview in sync with snapshot
                        } else {
                            for event in matching {
                                aggregatedTokens.formUnion(event.serverTokens)
                                BundlerEventService.emit(in: modelContext,
                                                         projectToken: candidateToken,
                                                         serverTokens: event.serverTokens,
                                                         type: event.type)
                            }
                        }
                        let serverIDArray = candidate.servers
                            .filter { aggregatedTokens.contains($0.eventToken) }
                            .map { $0.persistentModelID }
                        let serverIDSet: Set<PersistentIdentifier>? = serverIDArray.isEmpty ? nil : Set(serverIDArray)
                        await stdiosessionController?.reload(projectID: candidate.persistentModelID,
                                                             serverIDs: serverIDSet)
                    }
                }
                if modelContext.hasChanges {
                    try? modelContext.save()
                }
            }
        } catch {
            assertionFailure("Failed to persist project changes: \(error)")
        }
    }

    // MARK: - Actions

    private func setActive(_ project: Project) {
        guard !project.isActive else { return }
        for candidate in allProjects {
            candidate.isActive = (candidate == project)
        }
        saveContext(rebuildSnapshots: true)
    }

    private func addEnvVar(to project: Project) {
        let nextPosition = project.envVars.nextEnvPosition()
        let env = EnvVar(project: project,
                         key: "",
                         valueSource: .plain,
                         plainValue: "",
                         position: nextPosition)
        project.envVars.append(env)
        saveContext()
    }

    private func serverKindLabel(for server: Server) -> String {
        server.kind == .local_stdio ? "Local STDIO" : "Remote HTTP/SSE"
    }

    private func totalTools(for server: Server) -> Int {
        server.latestDecodedCapabilities?.tools.count ?? 0
    }

    private func activeTools(for server: Server) -> Int {
        // If server is disabled, no tools are active
        guard server.isEffectivelyEnabled else {
            return 0
        }

        guard let capabilities = server.latestDecodedCapabilities else {
            return server.includeTools.isEmpty ? 0 : server.includeTools.count
        }

        guard !server.includeTools.isEmpty else {
            return capabilities.tools.count
        }

        let include = Set(server.includeTools)
        return capabilities.tools.reduce(into: 0) { count, tool in
            if include.contains(tool.name) {
                count += 1
            }
        }
    }

}

extension ProjectDetailView {
    private func handleImportResult(_ result: ImportPersistenceResult) {
        highlight(result.server)
    }

    private func handleImportFailure(_ clientName: String) {
        toastCenter.push(text: "Unable to read config for \(clientName)", style: .warning)
    }

    private func handleImportSummary(_ successes: Int, _ failures: Int) {
        guard successes > 0 || failures > 0 else { return }
        var components: [String] = []
        if successes > 0 {
            let suffix = successes == 1 ? "" : "s"
            components.append("Imported \(successes) server\(suffix)")
        }
        if failures > 0 {
            components.append("\(failures) failed")
        }
        let message = components.joined(separator: "; ")
        toastCenter.push(text: message, style: failures > 0 ? .warning : .success)
    }

    private func highlight(_ server: Server) {
        let token = server.eventToken
        highlightTasks[token]?.cancel()
        highlightOpacities[token] = 0.5
        let task = Task { @MainActor in
            withAnimation(.easeOut(duration: 15)) {
                highlightOpacities[token] = 0.0
            }
            try? await Task.sleep(nanoseconds: UInt64(15 * 1_000_000_000))
            highlightOpacities.removeValue(forKey: token)
            highlightTasks.removeValue(forKey: token)
        }
        highlightTasks[token] = task
    }

    private func rowHighlight(for server: Server) -> Color {
        guard let opacity = highlightOpacities[server.eventToken], opacity > 0 else {
            return .clear
        }
        return Color.yellow.opacity(opacity)
    }

    private var rowItems: [RowItem] {
        var seenFolderIDs = Set<PersistentIdentifier>()
        let uniqueFolders = project.folders.filter { folder in
            seenFolderIDs.insert(folder.stableID).inserted
        }
        let sortedFolders = uniqueFolders.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        var seenServerIDs = Set<PersistentIdentifier>()
        let uniqueServers = project.servers.filter { server in
            seenServerIDs.insert(server.persistentModelID).inserted
        }
        let sortedServers = uniqueServers.sorted { lhs, rhs in
            lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }

        var items: [RowItem] = []
        for folder in sortedFolders {
            items.append(RowItem(id: .folderHeader(folder.stableID), kind: .folderHeader(folder)))
            if !folder.isCollapsed {
                let members = sortedServers.filter { $0.folder?.stableID == folder.stableID }
                for server in members {
                    items.append(RowItem(id: .server(server.persistentModelID), kind: .server(server, folder)))
                }
            }
        }

        let unfoldered = sortedServers.filter { $0.folder == nil }
        for server in unfoldered {
            items.append(RowItem(id: .server(server.persistentModelID), kind: .server(server, nil)))
        }

        return items
    }

    private func setFolderEnabled(_ folder: ProviderFolder, isEnabled: Bool) {
        guard folder.isEnabled != isEnabled else { return }
        folder.isEnabled = isEnabled
        folder.updatedAt = Date()
        for server in project.servers where server.folder?.stableID == folder.stableID {
            server.isEnabled = isEnabled
        }
        folder.project?.markUpdated()
        let event = makeSnapshotEvent(for: project)
        saveContext(events: [event], rebuildSnapshots: true)
    }

    private func toggleFolderCollapse(_ folder: ProviderFolder) {
        folder.isCollapsed.toggle()
        folder.updatedAt = Date()
        saveContext()
    }

    private func assign(_ server: Server, to folder: ProviderFolder?) {
        if let folder, server.folder?.stableID == folder.stableID { return }
        if folder == nil && server.folder == nil { return }
        server.folder = folder
        if let folder, folder.isEnabled == false {
            server.isEnabled = false
        }
        server.project?.markUpdated()
        let event = makeSnapshotEvent(for: project)
        saveContext(events: [event], rebuildSnapshots: true)
    }

    private func validateFolderName(_ raw: String, excluding existing: ProviderFolder? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Folder name cannot be empty." }
        let conflict = project.folders.contains { folder in
            guard folder !== existing else { return false }
            return folder.name.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
        if conflict { return "A folder with this name already exists in this project." }
        return nil
    }

    private func createFolder(named name: String) {
        guard validateFolderName(name) == nil else { return }
        let folder = ProviderFolder(project: project, name: name, isEnabled: true, isCollapsed: false)
        modelContext.insert(folder)
        if !project.folders.contains(where: { $0 === folder }) {
            project.folders.append(folder)
        }
        project.markUpdated()
        saveContext()
    }

    private func renameFolder(_ folder: ProviderFolder, to name: String) {
        if folder.name.compare(name, options: [.caseInsensitive]) == .orderedSame { return }
        guard validateFolderName(name, excluding: folder) == nil else { return }
        folder.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.updatedAt = Date()
        folder.project?.markUpdated()
        saveContext()
    }

    private func deleteFolder(_ folder: ProviderFolder) {
        for server in project.servers where server.folder?.stableID == folder.stableID {
            server.folder = nil
        }
        project.folders.removeAll { $0.stableID == folder.stableID }
        modelContext.delete(folder)
        project.markUpdated()
        let event = makeSnapshotEvent(for: project)
        saveContext(events: [event], rebuildSnapshots: true)
    }

    private func handleDrop(providers: [NSItemProvider], into folder: ProviderFolder?) -> Bool {
        endDragSession()

        var handled = false
        for provider in providers {
            let supportsTokenDrop = provider.hasItemConformingToTypeIdentifier(ProjectDetailView.serverDragType.identifier)
                || provider.canLoadObject(ofClass: NSString.self)
            guard supportsTokenDrop else { continue }
            handled = true

            loadServerToken(from: provider) { token in
                guard let token else { return }

                Task { @MainActor in
                    let matches = project.servers.filter { $0.eventToken == token }
                    guard let server = matches.first else { return }
                    assign(server, to: folder)
                }
            }
        }
        return handled
    }

    private func loadServerToken(from provider: NSItemProvider, completion: @escaping (UUID?) -> Void) {
        ItemProviderStringLoader.loadString(from: provider,
                                            typeIdentifier: ProjectDetailView.serverDragType.identifier) { raw in
            guard let raw,
                  let token = UUID(uuidString: raw) else {
                completion(nil)
                return
            }
            completion(token)
        }
    }

    private func beginDrag(for server: Server, source: String) -> NSItemProvider {
        isDraggingServer = true
        isDraggingServerFromFolder = (server.folder != nil)
        dragCleanupTask?.cancel()
        dragCleanupTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            } catch {
                return
            }
            isDraggingServer = false
            isDraggingServerFromFolder = false
            isUnfolderDropTargeted = false
        }

        let tokenString = server.eventToken.uuidString
        let provider = NSItemProvider(object: tokenString as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: ProjectDetailView.serverDragType.identifier,
                                            visibility: .all) { completion in
            completion(tokenString.data(using: .utf8), nil)
            return nil
        }
        provider.suggestedName = server.alias

        return provider
    }

    private func endDragSession() {
        isDraggingServer = false
        dragCleanupTask?.cancel()
        dragCleanupTask = nil
        isDraggingServerFromFolder = false
        isUnfolderDropTargeted = false
        serversTableAutoScroller.stop()
    }

    private func folderServerCount(_ folder: ProviderFolder?) -> Int {
        guard let folder else { return 0 }
        return project.servers.filter { $0.folder?.stableID == folder.stableID }.count
    }

    private static func resolveExecutablePath() -> String {
        Bundle.main.executableURL?.path ?? "/Applications/MCPBundler.app/Contents/MacOS/MCPBundler"
    }

    private func presentPendingInstallLinkIfNeeded() {
        if let presentation = installLinkCoordinator.consumePresentation(matching: project.eventToken) {
            AppDelegate.writeToStderr("deeplink.detail.present project=\(project.name) desc=\(presentation.description)\n")
            installLinkPresentation = presentation
        }
    }
}

// MARK: - Duplication Helper

private struct ServerDuplicationService {
    let modelContext: ModelContext

    @MainActor
    func duplicate(_ source: Server, into targetProject: Project) -> Server {
        let alias = makeUniqueAlias(for: source.alias, in: targetProject)
        let clone = Server(project: targetProject, alias: alias, kind: source.kind)

        // Copy shared properties
        clone.execPath = source.execPath
        clone.args = source.args
        clone.cwd = source.cwd
        clone.baseURL = source.baseURL
        clone.includeTools = source.includeTools
        clone.isEnabled = source.isEnabled

        // Reset health metadata so the app revalidates the new clone.
        clone.lastHealth = .unknown
        clone.lastCheckedAt = nil
        clone.serverIdentity = nil

        // Copy environment overrides
        for envVar in source.envOverrides.sorted(by: { $0.position < $1.position }) {
            let newVar = EnvVar(
                server: clone,
                key: envVar.key,
                valueSource: envVar.valueSource,
                plainValue: envVar.plainValue,
                keychainRef: envVar.keychainRef,
                position: envVar.position
            )
            clone.envOverrides.append(newVar)
        }

        // Copy header bindings
        for header in source.headers {
            let newHeader = HeaderBinding(
                server: clone,
                header: header.header,
                valueSource: header.valueSource,
                plainValue: header.plainValue,
                keychainRef: header.keychainRef
            )
            clone.headers.append(newHeader)
        }

        modelContext.insert(clone)
        targetProject.servers.append(clone)
        targetProject.markUpdated()

        if let sourceProject = source.project, sourceProject !== targetProject {
            sourceProject.markUpdated()
        }

        return clone
    }

    // MARK: - Helpers

    @MainActor
    private func makeUniqueAlias(for rawAlias: String, in project: Project) -> String {
        let base = sanitize(rawAlias)
        guard !base.isEmpty else {
            return fallbackAlias(in: project)
        }

        if !projectContainsAlias(base, in: project) {
            return base
        }

        var suffix = 2
        var candidate = "\(base)-copy"
        if !projectContainsAlias(candidate, in: project) {
            return candidate
        }

        while true {
            candidate = "\(base)-copy-\(suffix)"
            if !projectContainsAlias(candidate, in: project) {
                return candidate
            }
            suffix += 1
        }
    }

    @MainActor
    private func projectContainsAlias(_ alias: String, in project: Project) -> Bool {
        project.servers.contains {
            $0.alias.compare(alias, options: [.caseInsensitive]) == .orderedSame
        }
    }

    private func sanitize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func fallbackAlias(in project: Project) -> String {
        var suffix = 1
        while true {
            let candidate = "server-\(suffix)"
            if !projectContainsAlias(candidate, in: project) {
                return candidate
            }
            suffix += 1
        }
    }

}
