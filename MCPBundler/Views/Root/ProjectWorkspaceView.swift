//
//  ProjectWorkspaceView.swift
//  MCP Bundler
//
//  Root navigation shell for the project workspace.
//

import SwiftUI
import SwiftData
import AppKit
import Foundation

struct ProjectWorkspaceView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Project.name) private var projects: [Project]
    @State private var selection: Project?
    @State private var showDeleteConfirmation = false
    @StateObject private var toastCenter = ToastCenter()
    @StateObject private var installLinkCoordinator = InstallLinkCoordinator()
    @State private var projectOrderTokens: [UUID] = ProjectOrderPersistence.load()
    @State private var installLinkError: InstallLinkServiceError?
    private let installLinkService = InstallLinkService()

    private var orderedProjectList: [Project] {
        orderedProjects(from: projects)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                ProjectSidebarView(
                    projects: orderedProjectList,
                    selection: $selection,
                    onDelete: deleteProjects,
                    onMove: moveProjects
                )
                .navigationTitle("Projects")
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                .toolbar { toolbar }
            } detail: {
                if let project = selection ?? orderedProjectList.first {
                    ProjectDetailView(project: project)
                } else {
                    ProjectPlaceholderView()
                }
            }
            .modifier(WindowTitleSetter(title: windowTitle))
            .onAppear {
                ensureUniqueProjectTokens(projects)
                syncProjectOrder(with: projects)
                ensureSelection()
                InstallLinkRequestStore.shared.markWorkspaceReady()
            }
            .onDisappear {
                InstallLinkRequestStore.shared.markWorkspaceNotReady()
            }
            .onChange(of: projects, perform: handleProjectsChange)
            .alert("Delete Project?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive, action: deleteSelectedProject)
                Button("Cancel", role: .cancel) { }
            } message: {
                let name = selection?.name ?? "this project"
                Text("Deleting \(name) removes all servers, environments, and logs.")
            }
            .environmentObject(toastCenter)

            if !toastCenter.queue.isEmpty {
                ToastHost(center: toastCenter)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
            }
        }
        .environmentObject(installLinkCoordinator)
        .onReceive(NotificationCenter.default.publisher(for: .oauthToastRequested)) { notification in
            guard let payload = OAuthToastPayload(notification: notification) else { return }
            let displayText = payload.message.isEmpty ? payload.title : "\(payload.title): \(payload.message)"
            toastCenter.push(text: displayText, style: payload.kind.style)
            if payload.shouldNotify && payload.kind == .warning {
                OAuthUserNotificationDispatcher.deliverWarning(title: payload.title,
                                                               body: payload.message.isEmpty ? payload.title : payload.message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .installLinkRequest)) { notification in
            guard let payload = InstallLinkNotificationPayload(notification: notification) else { return }
            handleInstallLinkRequest(payload.request)
        }
        .onReceive(NotificationCenter.default.publisher(for: .installLinkFailure)) { notification in
            if let payload = InstallLinkFailurePayload(notification: notification) {
                installLinkError = .unsupportedLink(payload.message)
            }
        }
        .alert(item: $installLinkError) { error in
            Alert(title: Text("Install Link"),
                  message: Text(error.errorDescription ?? "Unknown error"),
                  dismissButton: .default(Text("OK")))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: addProject) {
                Label("Add Project", systemImage: "plus")
            }
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Project", systemImage: "trash")
            }
            .disabled(selection == nil)
        }
    }

    private func addProject() {
        let shouldActivate = !projects.contains { $0.isActive }

        withAnimation {
            let project = Project(name: defaultProjectName(), isActive: shouldActivate)
            modelContext.insert(project)
            selection = project
        }
        saveContext()
    }

    private func deleteProjects(_ offsets: IndexSet) {
        let targets = offsets.compactMap { index -> Project? in
            guard orderedProjectList.indices.contains(index) else { return nil }
            return orderedProjectList[index]
        }
        deleteProjects(targets)
    }

    private func deleteProjects(_ projectsToDelete: [Project]) {
        guard !projectsToDelete.isEmpty else { return }
        let removedTokens = Set(projectsToDelete.map(\.eventToken))

        withAnimation {
            for project in projectsToDelete {
                ProjectSnapshotCache.clearCache(for: project)
                modelContext.delete(project)
            }
            if let current = selection, removedTokens.contains(current.eventToken) {
                selection = nil
            }
            ensureSelection()
        }

        let updatedOrder = projectOrderTokens.filter { !removedTokens.contains($0) }
        updateProjectOrderTokens(updatedOrder)
        saveContext()
    }

    private func handleInstallLinkRequest(_ request: InstallLinkRequest) {
        guard let targetProject = selection ?? orderedProjectList.first else {
            installLinkError = .noProjects
            return
        }
        AppDelegate.writeToStderr("deeplink.workspace.handle name=\(request.name) project=\(targetProject.name)\n")
        do {
            let parseResult = try installLinkService.parse(request: request)
            let presentation = InstallLinkPresentation(projectToken: targetProject.eventToken,
                                                       description: parseResult.sourceDescription,
                                                       parseResult: parseResult)
            installLinkCoordinator.enqueue(presentation)
        } catch let error as InstallLinkServiceError {
            installLinkError = error
        } catch {
            installLinkError = .unsupportedLink(error.localizedDescription)
        }
    }

    private func deleteSelectedProject() {
        guard let project = selection else { return }
        selection = nil
        deleteProjects([project])
    }

    private func moveProjects(from source: IndexSet, to destination: Int) {
        var tokens = orderedProjectList.map(\.eventToken)
        tokens.move(fromOffsets: source, toOffset: destination)
        updateProjectOrderTokens(tokens)
    }

    private func orderedProjects(from projects: [Project]) -> [Project] {
        // Build a safe lookup that tolerates duplicate tokens in persisted state
        var indexLookup: [UUID: Int] = [:]
        for (idx, token) in projectOrderTokens.enumerated() {
            if indexLookup[token] == nil { indexLookup[token] = idx }
        }

        return projects.sorted { lhs, rhs in
            switch (indexLookup[lhs.eventToken], indexLookup[rhs.eventToken]) {
            case let (lhsIndex?, rhsIndex?):
                if lhsIndex == rhsIndex {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhsIndex < rhsIndex
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func syncProjectOrder(with projects: [Project]) {
        let availableTokens = Set(projects.map(\.eventToken))
        var updatedOrder: [UUID] = []
        var seenTokens = Set<UUID>()

        for token in projectOrderTokens where availableTokens.contains(token) {
            if seenTokens.insert(token).inserted {
                updatedOrder.append(token)
            }
        }

        let missingProjects = projects
            .filter { !seenTokens.contains($0.eventToken) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }

        updatedOrder.append(contentsOf: missingProjects.map(\.eventToken))
        updateProjectOrderTokens(updatedOrder)
    }

    private func updateProjectOrderTokens(_ tokens: [UUID]) {
        guard tokens != projectOrderTokens else { return }
        projectOrderTokens = tokens
        ProjectOrderPersistence.save(tokens)
    }

    private func saveContext() {
        do {
            try modelContext.save()
            let currentProjects = projects
            Task { @MainActor in
                for project in currentProjects {
                    await ProjectSnapshotCache.ensureSnapshot(for: project)
                }
                if modelContext.hasChanges {
                    try? modelContext.save()
                }
            }
        } catch {
            assertionFailure("Failed to persist project changes: \(error)")
        }
    }

    private func ensureSelection() {
        if selection == nil {
            selection = projects.first(where: { $0.isActive }) ?? projects.first
        }
    }

    private func handleProjectsChange(_ newProjects: [Project]) {
        ensureUniqueProjectTokens(newProjects)
        guard let current = selection else {
            selection = newProjects.first(where: { $0.isActive }) ?? newProjects.first
            return
        }
        if !newProjects.contains(where: { $0 == current }) {
            selection = newProjects.first(where: { $0.isActive }) ?? newProjects.first
        }
    }

    private func ensureUniqueProjectTokens(_ projects: [Project]) {
        var seen = Set<UUID>()
        var mutated = false
        for project in projects {
            if seen.contains(project.eventToken) {
                project.eventToken = UUID()
                mutated = true
            }
            seen.insert(project.eventToken)
        }
        if mutated {
            saveContext()
        }
    }

    private var windowTitle: String {
        let defaultTitle = "MCP Bundler"
        guard !projects.isEmpty else { return defaultTitle }
        let activeProject = selection ?? orderedProjectList.first(where: { $0.isActive }) ?? orderedProjectList.first
        return activeProject?.name ?? defaultTitle
    }
}

// MARK: - Helpers

private func defaultProjectName() -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return "Project " + formatter.string(from: Date())
}

#Preview {
    ProjectWorkspaceView()
        .modelContainer(for: MCPBundlerSchemaV2.models, inMemory: true)
}

private struct WindowTitleSetter: ViewModifier {
    var title: String

    func body(content: Content) -> some View {
        content.background(WindowAccessor(title: title))
    }

    private struct WindowAccessor: NSViewRepresentable {
        var title: String

        final class Coordinator {
            var lastTitle: String?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            // Defer until attached to a window, but only if the title actually changed.
            DispatchQueue.main.async { [weak view] in
                guard let win = view?.window else { return }
                if context.coordinator.lastTitle != title && win.title != title {
                    context.coordinator.lastTitle = title
                    win.title = title
                }
            }
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            // Avoid triggering a relayout loop by re-setting the same title on every pass.
            // Only update when the title actually changes.
            DispatchQueue.main.async { [weak nsView] in
                guard let win = nsView?.window else { return }
                if context.coordinator.lastTitle != title && win.title != title {
                    context.coordinator.lastTitle = title
                    win.title = title
                }
            }
        }
    }
}

// MARK: - Persistence (Project Order)

private enum ProjectOrderPersistence {
    private static let storageKey = "ProjectSidebarOrderTokens"

    static func save(_ tokens: [UUID]) {
        let raw = tokens.map { $0.uuidString }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    static func load() -> [UUID] {
        guard let raw = UserDefaults.standard.stringArray(forKey: storageKey), !raw.isEmpty else { return [] }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for s in raw {
            if let id = UUID(uuidString: s), !seen.contains(id) {
                seen.insert(id)
                result.append(id)
            }
        }
        return result
    }
}
