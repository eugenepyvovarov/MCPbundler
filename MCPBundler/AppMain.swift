//
//  AppMain.swift
//  MCP Bundler
//
//  Created by Eugene Pyvovarov on 12.09.2025.
//

import SwiftUI
import SwiftData
import AppKit
import Darwin
import MCP
import Dispatch
import SQLite3
#if canImport(Sparkle)
import Sparkle
#endif

func persistentStoreURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["MCP_BUNDLER_STORE_URL"], !override.isEmpty {
        let expanded = (override as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    let directoryName = "Lifeisgoodlabs.MCP-Bundler"
    let fileName = "mcp-bundler.sqlite"

    do {
        let fileManager = FileManager.default
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(fileName)
    } catch {
        fatalError("Could not determine persistence store URL: \(error)")
    }
}

private enum DatabaseMigrator {
    static func ensureCompatibility(at storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        var db: OpaquePointer?
        guard sqlite3_open(storeURL.path, &db) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        ensureColumnExists(name: "ZISOAUTHDEBUGLOGGINGENABLED",
                           table: "ZSERVER",
                           defaultValueClause: "INTEGER DEFAULT 0",
                           in: db)
        ensureColumnExists(name: "ZPROVIDERMETADATA",
                           table: "ZOAUTHSTATE",
                           defaultValueClause: "BLOB",
                           in: db)
        ensureColumnExists(name: "ZPOSITION",
                           table: "ZENVVAR",
                           defaultValueClause: "INTEGER DEFAULT 0",
                           in: db)
    }

    private static func ensureColumnExists(name: String,
                                           table: String,
                                           defaultValueClause: String,
                                           in db: OpaquePointer) {
        guard !columnExists(name: name, table: table, in: db) else { return }
        let statement = "ALTER TABLE \(table) ADD COLUMN \(name) \(defaultValueClause)"
        sqlite3_exec(db, statement, nil, nil, nil)
    }

    private static func columnExists(name: String,
                                     table: String,
                                     in db: OpaquePointer) -> Bool {
        let pragma = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragma, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }

        while sqlite3_step(statement) == SQLITE_ROW {
            if let cName = sqlite3_column_text(statement, 1) {
                let columnName = String(cString: cName)
                if columnName.caseInsensitiveCompare(name) == .orderedSame {
                    return true
                }
            }
        }
        return false
    }
}

private enum EnvVarPositionBackfill {
    static func ensurePositions(in container: ModelContainer) {
        let context = container.mainContext
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        var didMutate = false

        for project in projects {
            if needsNormalization(project.envVars) {
                project.envVars.normalizeEnvPositions()
                project.markUpdated()
                didMutate = true
            }

            for server in project.servers {
                if needsNormalization(server.envOverrides) {
                    server.envOverrides.normalizeEnvPositions()
                    server.project?.markUpdated()
                    didMutate = true
                }
            }
        }

        if didMutate {
            try? context.save()
        }
    }

    private static func needsNormalization(_ envs: [EnvVar]) -> Bool {
        guard !envs.isEmpty else { return false }
        var seen = Set<Int64>()
        for env in envs {
            if env.position <= 0 || !seen.insert(env.position).inserted {
                return true
            }
        }
        return false
    }
}

private enum ServerEventTokenBackfill {
    static func ensureUniqueTokens(in container: ModelContainer) {
        let context = container.mainContext
        let servers = (try? context.fetch(FetchDescriptor<Server>())) ?? []
        var seen = Set<UUID>()
        var repairedCount = 0

        for server in servers {
            let token = server.eventToken
            if !seen.insert(token).inserted {
                server.eventToken = makeUniqueToken(seen: &seen)
                repairedCount += 1
            }
        }

        if repairedCount > 0 {
            try? context.save()
            AppDelegate.writeToStderr("mcp-bundler: repaired \(repairedCount) duplicate server tokens\n")
        }
    }

    private static func makeUniqueToken(seen: inout Set<UUID>) -> UUID {
        while true {
            let candidate = UUID()
            if seen.insert(candidate).inserted {
                return candidate
            }
        }
    }
}

func buildModelContainer() -> ModelContainer {
    let schema = Schema(versionedSchema: MCPBundlerSchemaV2.self)
    let storeURL = persistentStoreURL()
    DatabaseMigrator.ensureCompatibility(at: storeURL)
    let modelConfiguration = ModelConfiguration(
        nil,
        schema: schema,
        url: storeURL
    )

    do {
        let container = try ModelContainer(for: schema,
                                           migrationPlan: MCPBundlerMigrationPlan.self,
                                           configurations: [modelConfiguration])
        do {
            try OAuthMigration.performInitialBackfill(in: container)
        } catch {
            AppDelegate.writeToStderr("mcp-bundler: OAuth migration failed: \(error)\n")
        }
        EnvVarPositionBackfill.ensurePositions(in: container)
        SkillSyncLocationBackfill.perform(in: container)
        SkillMarketplaceSourceBackfill.perform(in: container)
        ServerEventTokenBackfill.ensureUniqueTokens(in: container)
        return container
    } catch {
        AppDelegate.writeToStderr("mcp-bundler: ModelContainer initialization failed: \(error)\n")
        preconditionFailure("ModelContainer initialization failed: \(error)")
    }
}

@main
enum MainEntryPoint {
    static func main() {
        if CommandLine.arguments.contains("--stdio-server") {
            HeadlessEntrypoint.run()
        } else {
            MCP_BundlerApp.main()
        }
    }
}

enum HeadlessEntrypoint {
    static func run() -> Never {
        let container = buildModelContainer()

        Task { @MainActor in
            let preserveStdIOEnv = ProcessInfo.processInfo.environment["MCP_BUNDLER_PERSIST_STDIO"]
            let preserveStdIO = preserveStdIOEnv == nil ? true : preserveStdIOEnv == "1"
            let persistenceMessage = preserveStdIO ? "enabled" : "disabled"
            writeToStderr("mcp-bundler.headless: stdio persistence \(persistenceMessage) (MCP_BUNDLER_PERSIST_STDIO=\(preserveStdIOEnv ?? "default"))\n")

            ensureDefaultProjectIfNeeded(in: container)
            let verboseStdIO = ProcessInfo.processInfo.environment["MCP_BUNDLER_STDIO_VERBOSE"] == "1"
            let hostOptions = BundledServerHost.Options(preserveProvidersOnTransportClose: preserveStdIO,
                                                        logLifecycle: verboseStdIO,
                                                        emitListChangedNotifications: true)
            let host = BundledServerHost(transportFactory: .standardIO(), options: hostOptions)
            let runner = StdioBundlerRunner(container: container, host: host, logLifecycle: verboseStdIO)
            let eventLoopTask = startEventDispatchLoop(container: container, runner: runner)

            do {
                if verboseStdIO {
                    writeToStderr("mcp-bundler.headless: starting stdio runner")
                }
                _ = try await runner.start()
                if verboseStdIO {
                    writeToStderr("mcp-bundler.headless: runner.start returned, waiting for termination")
                }
                try await runner.waitForTermination()
                if verboseStdIO {
                    writeToStderr("mcp-bundler.headless: runner.waitForTermination completed")
                }
            } catch is CancellationError {
                if verboseStdIO {
                    writeToStderr("mcp-bundler.headless: cancellation received")
                }
            } catch let runnerError as StdioBundlerRunner.RunnerError {
                switch runnerError {
                case .noActiveProject:
                    writeToStderr("mcp-bundler: No active project configured. Set one active in the app.\n")
                case .noServers:
                    writeToStderr("mcp-bundler: Active project has no servers. Add one in the app.\n")
                case .missingSnapshot:
                    writeToStderr("mcp-bundler: Cached snapshot unavailable. Open the app to rebuild capabilities.\n")
                case .snapshotUnavailable:
                    writeToStderr("mcp-bundler: Cached snapshot still rebuilding; open the app to finish syncing.\n")
                }
            } catch {
                writeToStderr("mcp-bundler: Error: \(error.localizedDescription)\n")
                writeToStderr("mcp-bundler: Error type: \(type(of: error))\n")
            }

            await runner.stop()
            eventLoopTask.cancel()
            await eventLoopTask.value

            fflush(stdout)
            fflush(stderr)
            exit(EXIT_SUCCESS)
        }

        dispatchMain()
    }

    @MainActor
    private static func ensureDefaultProjectIfNeeded(in container: ModelContainer) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<Project>()
        if let projects = try? context.fetch(descriptor), projects.isEmpty {
            let defaultProject = Project(name: "Default Project")
            defaultProject.isActive = true
            context.insert(defaultProject)
            try? context.save()
        }
    }

    @MainActor
    private static func startEventDispatchLoop(container: ModelContainer,
                                               runner: StdioBundlerRunner) -> Task<Void, Never> {
        Task { @MainActor in
            let context = container.mainContext
            let service = BundlerEventService(context: context)
            var lastPrune = Date()

            while !Task.isCancelled {
                await processPendingEvents(using: service, context: context, runner: runner)

                let now = Date()
                if now.timeIntervalSince(lastPrune) >= 86_400 {
                    let cutoff = now.addingTimeInterval(-86_400)
                    service.pruneEvents(olderThan: cutoff)
                    lastPrune = now
                }

                do {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                } catch {
                    break
                }
            }
        }
    }

    @MainActor
    private static func processPendingEvents(using service: BundlerEventService,
                                             context: ModelContext,
                                             runner: StdioBundlerRunner) async {
        let events = service.fetchPendingEvents()
        guard !events.isEmpty else { return }

        let grouped = Dictionary(grouping: events, by: { $0.projectToken })
        for (projectToken, projectEvents) in grouped {
            let projectDescriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.eventToken == projectToken })
            guard let project = (try? context.fetch(projectDescriptor))?.first else {
                service.deleteEvents(projectEvents)
                continue
            }

            let targetedTokens = Set(projectEvents.flatMap { $0.serverTokens })
            let serverIDSet: Set<PersistentIdentifier>?
            if targetedTokens.isEmpty {
                serverIDSet = nil
            } else {
                let matched = project.servers
                    .filter { targetedTokens.contains($0.eventToken) }
                    .map { $0.persistentModelID }
                serverIDSet = matched.isEmpty ? nil : Set(matched)
            }

            await runner.reload(projectID: project.persistentModelID,
                                serverIDs: serverIDSet)

            service.markEventsHandled(projectEvents)
            service.deleteEvents(projectEvents)
        }
    }

    private static func writeToStderr(_ message: String) {
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

struct AppDelegateKey: EnvironmentKey {
    static var defaultValue: AppDelegate? { nil }
}

extension EnvironmentValues {
    var appDelegate: AppDelegate? {
        get { self[AppDelegateKey.self] }
        set { self[AppDelegateKey.self] = newValue }
    }
}

struct MCP_BundlerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let isHeadless: Bool = ProcessInfo.processInfo.arguments.contains("--stdio-server")
#if canImport(Sparkle)
    private let sparkleUpdaterController: SPUStandardUpdaterController?
#endif
    private let stdiosessionController: StdiosessionController
    @StateObject private var integrityCoordinator: IntegrityRepairCoordinator

    var sharedModelContainer: ModelContainer = buildModelContainer()

    init() {
#if canImport(Sparkle)
        if isHeadless {
            sparkleUpdaterController = nil
        } else {
            sparkleUpdaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
#endif
        let container = sharedModelContainer
        _integrityCoordinator = StateObject(wrappedValue: IntegrityRepairCoordinator(container: container))
        let controller = StdiosessionController.live(container: sharedModelContainer)
        self.stdiosessionController = controller
        appDelegate.configure(container: sharedModelContainer, sessionController: controller, isHeadless: isHeadless)
        if !isHeadless {
            integrityCoordinator.scheduleInitialScan()
        }
    }

    var body: some Scene {
        mainWindowScene
        Window("Project Mockup", id: "projectMockup") {
            ProjectWorkspaceMockupView()
        }
        .defaultSize(width: 1180, height: 720)

        Window("Project Selector Mockup", id: "projectSelectorMockup") {
            ProjectSelectorMockupView()
        }
        .defaultSize(width: 320, height: 360)
    }

    private var mainWindowScene: some Scene {
        Window("MCP Bundler", id: "mainWindow") {
            Group {
                if isHeadless {
                    EmptyView()
                } else {
                    ProjectWorkspaceView()
                }
            }
            .sheet(item: $integrityCoordinator.promptState) { state in
                IntegrityRepairPrompt(summary: state.summary,
                                      isProcessing: integrityCoordinator.isProcessing,
                                      onRepair: integrityCoordinator.repairAndRelaunch,
                                      onContinue: integrityCoordinator.continueWithoutRepair,
                                      onQuit: integrityCoordinator.quit)
                    .interactiveDismissDisabled()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }
        }
        // Ensure deep links reuse the single persistent window instead of spawning new ones.
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .windowResizability(isHeadless ? .contentSize : .automatic)
        .modelContainer(sharedModelContainer)
        .environment(\.stdiosessionController, stdiosessionController)
        .environment(\.appDelegate, appDelegate)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MCP Bundler") {
                    showAboutPanel()
                }
#if canImport(Sparkle)
                if let sparkleUpdaterController {
                    Divider()
                    Button("Check for Updates…") {
                        sparkleUpdaterController.checkForUpdates(nil)
                    }
                }
#endif
            }
        }
    }

    
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: ModelContainer?
    func configure(container: ModelContainer, sessionController _: StdiosessionController, isHeadless _: Bool) {
        self.container = container
    }

    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        // GUI-only behavior lives here; headless mode is handled by HeadlessEntrypoint
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        bringExistingWindowToFrontIfNeeded()
        for url in urls {
            AppDelegate.writeToStderr("deeplink.delegate url=\(url.absoluteString)\n")
            if OAuthService.shared.handleRedirectURL(url) {
                continue
            }
            guard InstallLinkRequestStore.shared.claimURL(url) else {
                continue
            }
            do {
                if let request = try InstallLinkRouter.parse(url) {
                    InstallLinkRequestStore.shared.enqueueRequest(request)
                }
            } catch let error as InstallLinkRouterError {
                InstallLinkRequestStore.shared.enqueueFailure(error.errorDescription ?? "Unable to open install link.")
            } catch {
                InstallLinkRequestStore.shared.enqueueFailure("Unable to open install link.")
            }
        }
    }

    static func writeToStderr(_ message: String) {
        if let data = message.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private extension MCP_BundlerApp {
    func handleIncomingURL(_ url: URL) {
        AppDelegate.writeToStderr("deeplink.onOpenURL url=\(url.absoluteString)\n")
        if OAuthService.shared.handleRedirectURL(url) {
            return
        }
        guard InstallLinkRequestStore.shared.claimURL(url) else {
            return
        }
        do {
            guard let request = try InstallLinkRouter.parse(url) else { return }
            InstallLinkRequestStore.shared.enqueueRequest(request)
        } catch let error as InstallLinkRouterError {
            InstallLinkRequestStore.shared.enqueueFailure(error.errorDescription ?? "Unable to open install link.")
        } catch {
            InstallLinkRequestStore.shared.enqueueFailure("Unable to open install link.")
        }
    }

    func showAboutPanel() {
        let options = Self.aboutPanelOptions
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let html = """
        <p style="font-size:13px; text-align:center;">
            <a href="https://mcp-bundler.maketry.xyz">Homepage</a><br/>
            <a href="https://x.com/selfhosted_ai">Follow us on X</a>
        </p>
        """
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let data = html.data(using: .utf8),
           let attributed = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil
           ) {
            options[.credits] = attributed
        }
        return options
    }
}

private extension AppDelegate {
    func bringExistingWindowToFrontIfNeeded() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
