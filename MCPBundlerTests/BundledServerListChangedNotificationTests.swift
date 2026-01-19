import XCTest
import SwiftData
import MCP
@testable import MCPBundler

@MainActor
final class BundledServerListChangedNotificationTests: XCTestCase {
    func testListChangedNotificationsEmitOnSnapshotRevisionChange() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "ListChanged", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)
        context.insert(project)
        try context.save()

        let initialTool = makeTool(alias: "alpha", name: "tool_a")
        let initialPrompt = makePrompt(alias: "alpha", name: "prompt_a")
        let initialResource = makeResource(alias: "alpha", name: "resource_a", uri: "file:///resource_a")
        let initialSnapshot = makeSnapshot(tools: [initialTool],
                                            prompts: [initialPrompt],
                                            resources: [initialResource])

        let manager = BundledServerManager(
            providerFactory: { server, _, logSink in
                RecordingUpstreamProvider(server: server, keepWarm: false, logSink: logSink)
            },
            warmUpHandler: nil,
            listChangedNotificationsEnabled: true
        )

        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: initialSnapshot,
                             providers: providers)

        let client = Client(name: "ListChangedClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let toolExpectation = expectation(description: "tools list changed")
        let promptExpectation = expectation(description: "prompts list changed")
        let resourceExpectation = expectation(description: "resources list changed")

        await client.onNotification(ToolListChangedNotification.self) { _ in
            toolExpectation.fulfill()
        }
        await client.onNotification(PromptListChangedNotification.self) { _ in
            promptExpectation.fulfill()
        }
        await client.onNotification(ResourceListChangedNotification.self) { _ in
            resourceExpectation.fulfill()
        }

        let teardown: @Sendable () async -> Void = {
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        project.snapshotRevision &+= 1
        let nextTool = makeTool(alias: "alpha", name: "tool_b")
        let nextSnapshot = makeSnapshot(tools: [nextTool],
                                        prompts: [initialPrompt],
                                        resources: [initialResource])
        try await host.reload(project: project,
                              snapshot: nextSnapshot,
                              providers: providers)

        await fulfillment(of: [toolExpectation, promptExpectation, resourceExpectation], timeout: 2.0)
    }

    func testCapabilitiesAdvertiseListChangedWhenSnapshotEmpty() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "EmptySnapshot", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)
        context.insert(project)
        try context.save()

        let snapshot = makeSnapshot(tools: [], prompts: [], resources: [])

        let manager = BundledServerManager(listChangedNotificationsEnabled: true)
        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: "CapabilitiesClient", version: "1.0.0")
        let initResult = try await client.connect(transport: clientTransport)

        let teardown: @Sendable () async -> Void = {
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        XCTAssertEqual(initResult.capabilities.tools?.listChanged, true)
        XCTAssertEqual(initResult.capabilities.prompts?.listChanged, true)
        XCTAssertEqual(initResult.capabilities.resources?.listChanged, true)
    }

    func testListChangedEmitsWhenActiveProjectChanges() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let projectA = Project(name: "Alpha", isActive: true)
        let serverA = MCPBundler.Server(project: projectA, alias: "alpha", kind: .local_stdio)
        serverA.execPath = "/usr/bin/mock"
        projectA.servers.append(serverA)
        projectA.snapshotRevision = 1

        let projectB = Project(name: "Beta", isActive: false)
        let serverB = MCPBundler.Server(project: projectB, alias: "beta", kind: .local_stdio)
        serverB.execPath = "/usr/bin/mock"
        projectB.servers.append(serverB)
        projectB.snapshotRevision = 1

        context.insert(projectA)
        context.insert(serverA)
        context.insert(projectB)
        context.insert(serverB)
        try context.save()

        let snapshotA = makeSnapshot(tools: [makeTool(alias: "alpha", name: "tool_a")],
                                     prompts: [],
                                     resources: [])
        let snapshotB = makeSnapshot(tools: [makeTool(alias: "beta", name: "tool_b")],
                                     prompts: [],
                                     resources: [])

        let manager = BundledServerManager(listChangedNotificationsEnabled: true)
        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providersA: [MCPBundler.Server: any CapabilitiesProvider] = [
            serverA: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: serverA))
        ]
        let providersB: [MCPBundler.Server: any CapabilitiesProvider] = [
            serverB: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: serverB))
        ]

        try await host.start(project: projectA,
                             snapshot: snapshotA,
                             providers: providersA)

        let client = Client(name: "ActiveProjectClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let toolExpectation = expectation(description: "tools list changed on project switch")
        let promptExpectation = expectation(description: "prompts list changed on project switch")
        let resourceExpectation = expectation(description: "resources list changed on project switch")

        await client.onNotification(ToolListChangedNotification.self) { _ in
            toolExpectation.fulfill()
        }
        await client.onNotification(PromptListChangedNotification.self) { _ in
            promptExpectation.fulfill()
        }
        await client.onNotification(ResourceListChangedNotification.self) { _ in
            resourceExpectation.fulfill()
        }

        let teardown: @Sendable () async -> Void = {
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        try await host.reload(project: projectB,
                              snapshot: snapshotB,
                              providers: providersB)

        await fulfillment(of: [toolExpectation, promptExpectation, resourceExpectation], timeout: 2.0)
    }

    func testListChangedEmitsWhenServerDisabled() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "ServerToggle", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)
        project.snapshotRevision = 1

        context.insert(project)
        context.insert(server)
        try context.save()

        let snapshot = makeSnapshot(tools: [makeTool(alias: "alpha", name: "tool_a")],
                                    prompts: [],
                                    resources: [])

        let manager = BundledServerManager(listChangedNotificationsEnabled: true)
        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: "ServerToggleClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let toolExpectation = expectation(description: "tools list changed on server disable")
        let promptExpectation = expectation(description: "prompts list changed on server disable")
        let resourceExpectation = expectation(description: "resources list changed on server disable")

        await client.onNotification(ToolListChangedNotification.self) { _ in
            toolExpectation.fulfill()
        }
        await client.onNotification(PromptListChangedNotification.self) { _ in
            promptExpectation.fulfill()
        }
        await client.onNotification(ResourceListChangedNotification.self) { _ in
            resourceExpectation.fulfill()
        }

        let teardown: @Sendable () async -> Void = {
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        server.isEnabled = false
        project.snapshotRevision &+= 1
        let disabledSnapshot = makeSnapshot(tools: [], prompts: [], resources: [])

        try await host.reload(project: project,
                              snapshot: disabledSnapshot,
                              providers: [:])

        await fulfillment(of: [toolExpectation, promptExpectation, resourceExpectation], timeout: 2.0)
    }

    func testListChangedEmitsWhenFolderDisabled() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "FolderToggle", isActive: true)
        let folder = ProviderFolder(project: project, name: "Group", isEnabled: true, isCollapsed: false)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        server.folder = folder
        project.folders.append(folder)
        project.servers.append(server)
        project.snapshotRevision = 1

        context.insert(project)
        context.insert(folder)
        context.insert(server)
        try context.save()

        let snapshot = makeSnapshot(tools: [makeTool(alias: "alpha", name: "tool_a")],
                                    prompts: [],
                                    resources: [])

        let manager = BundledServerManager(listChangedNotificationsEnabled: true)
        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(context)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: "FolderToggleClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let toolExpectation = expectation(description: "tools list changed on folder disable")
        let promptExpectation = expectation(description: "prompts list changed on folder disable")
        let resourceExpectation = expectation(description: "resources list changed on folder disable")

        await client.onNotification(ToolListChangedNotification.self) { _ in
            toolExpectation.fulfill()
        }
        await client.onNotification(PromptListChangedNotification.self) { _ in
            promptExpectation.fulfill()
        }
        await client.onNotification(ResourceListChangedNotification.self) { _ in
            resourceExpectation.fulfill()
        }

        let teardown: @Sendable () async -> Void = {
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        folder.isEnabled = false
        server.isEnabled = false
        project.snapshotRevision &+= 1
        let disabledSnapshot = makeSnapshot(tools: [], prompts: [], resources: [])

        try await host.reload(project: project,
                              snapshot: disabledSnapshot,
                              providers: [:])

        await fulfillment(of: [toolExpectation, promptExpectation, resourceExpectation], timeout: 2.0)
    }

    // MARK: - Helpers

    private func makeSnapshot(tools: [NamespacedTool],
                              prompts: [NamespacedPrompt],
                              resources: [NamespacedResource]) -> BundlerAggregator.Snapshot {
        let toolMap = Dictionary(uniqueKeysWithValues: tools.map { ($0.namespaced, ($0.alias, $0.original)) })
        let promptMap = Dictionary(uniqueKeysWithValues: prompts.map { ($0.namespaced, ($0.alias, $0.original)) })
        let resourceMap = Dictionary(uniqueKeysWithValues: resources.map { ($0.uri, ($0.alias, $0.originalURI)) })
        return BundlerAggregator.Snapshot(tools: tools,
                                          prompts: prompts,
                                          resources: resources,
                                          toolMap: toolMap,
                                          promptMap: promptMap,
                                          resourceMap: resourceMap)
    }

    private func makeTool(alias: String, name: String) -> NamespacedTool {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return NamespacedTool(namespaced: "\(alias)__\(name)",
                              alias: alias,
                              original: name,
                              title: name,
                              description: "Tool \(name)",
                              inputSchema: schema,
                              annotations: nil)
    }

    private func makePrompt(alias: String, name: String) -> NamespacedPrompt {
        NamespacedPrompt(namespaced: "\(alias)__\(name)",
                         alias: alias,
                         original: name,
                         description: "Prompt \(name)")
    }

    private func makeResource(alias: String, name: String, uri: String) -> NamespacedResource {
        let wrapped = BundlerURI.wrap(alias: alias, originalURI: uri)
        return NamespacedResource(name: "\(alias)__\(name)",
                                  uri: wrapped,
                                  alias: alias,
                                  originalURI: uri,
                                  description: "Resource \(name)")
    }
}

private struct InlineCapabilitiesProvider: CapabilitiesProvider {
    let capabilities: MCPCapabilities

    func fetchCapabilities(for server: MCPBundler.Server) async throws -> MCPCapabilities {
        capabilities
    }
}
