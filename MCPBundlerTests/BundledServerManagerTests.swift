import XCTest
import SwiftData
import MCP
@testable import MCPBundler

@MainActor
final class BundledServerManagerTests: XCTestCase {
    func testUsesInjectedProviderFactory() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "FactoryTest", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .remote_http_sse)
        server.baseURL = "https://alpha.example"
        project.servers.append(server)
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: server)
        try context.save()
        let snapshot = try await rebuildSnapshot(for: project)

        var createdProviders: [String: RecordingUpstreamProvider] = [:]
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: false)
                createdProviders[server.alias] = stub
                return stub
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: StaticCapabilitiesProvider(alias: "alpha")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(createdProviders.keys.sorted(), ["alpha"])
        XCTAssertEqual(createdProviders["alpha"]?.warmUpCount, 0)
    }

    func testStartWarmUpSkipsProvidersWithoutKeepAlive() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "WarmToggle", isActive: true)
        let warm = MCPBundler.Server(project: project, alias: "warm", kind: .local_stdio)
        warm.execPath = "/usr/bin/warm"
        let cold = MCPBundler.Server(project: project, alias: "cold", kind: .remote_http_sse)
        cold.baseURL = "https://cold.example"
        project.servers.append(contentsOf: [warm, cold])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: warm)
        try TestCapabilitiesBuilder.prime(server: cold)
        try context.save()
        let snapshot = try await rebuildSnapshot(for: project)

        var stubs: [String: RecordingUpstreamProvider] = [:]
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let keepWarm = server.alias == "warm"
                let stub = RecordingUpstreamProvider(server: server, keepWarm: keepWarm)
                stubs[server.alias] = stub
                return stub
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            warm: StaticCapabilitiesProvider(alias: "warm"),
            cold: StaticCapabilitiesProvider(alias: "cold")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(stubs["warm"]?.warmUpCount, 1)
        XCTAssertEqual(stubs["cold"]?.warmUpCount, 0)
        XCTAssertEqual(stubs["warm"]?.resetCount, 0)
        XCTAssertEqual(stubs["cold"]?.resetCount, 0)
    }

    func testReloadWarmUpFailureResetsOnlyTargetedProvider() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "ReloadWarmup", isActive: true)
        let alpha = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        alpha.execPath = "/usr/bin/alpha"
        let beta = MCPBundler.Server(project: project, alias: "beta", kind: .local_stdio)
        beta.execPath = "/usr/bin/beta"
        project.servers.append(contentsOf: [alpha, beta])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: alpha)
        try TestCapabilitiesBuilder.prime(server: beta)
        try context.save()
        var snapshot = try await rebuildSnapshot(for: project)

        var stubs: [String: RecordingUpstreamProvider] = [:]
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: true)
                stubs[server.alias] = stub
                return stub
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            alpha: StaticCapabilitiesProvider(alias: "alpha"),
            beta: StaticCapabilitiesProvider(alias: "beta")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(stubs["alpha"]?.warmUpCount, 1)
        XCTAssertEqual(stubs["beta"]?.warmUpCount, 1)

        stubs["alpha"]?.nextWarmUpError = WarmUpTestError.failed

        alpha.args = ["--updated"]
        try context.save()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)

        let targeted: Set<PersistentIdentifier> = [try XCTUnwrap(alpha.persistentModelID)]

        try await manager.reload(project: project,
                                 snapshot: snapshot,
                                 providers: providers,
                                 serverIDs: targeted)

        XCTAssertEqual(stubs["alpha"]?.warmUpCount, 2)
        XCTAssertEqual(stubs["alpha"]?.resetCount, 1)
        XCTAssertEqual(stubs["beta"]?.warmUpCount, 1)
        XCTAssertEqual(stubs["beta"]?.resetCount, 0)
    }

    func testTargetedReloadWithoutChangesDoesNotWarmOrResetOthers() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "SelectiveReload", isActive: true)
        let alpha = MCPBundler.Server(project: project, alias: "alpha", kind: .remote_http_sse)
        alpha.baseURL = "https://alpha.example"
        let beta = MCPBundler.Server(project: project, alias: "beta", kind: .remote_http_sse)
        beta.baseURL = "https://beta.example"
        project.servers.append(contentsOf: [alpha, beta])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: alpha)
        try TestCapabilitiesBuilder.prime(server: beta)
        try context.save()
        let snapshot = try await rebuildSnapshot(for: project)

        var stubs: [String: RecordingUpstreamProvider] = [:]
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: true)
                stubs[server.alias] = stub
                return stub
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            alpha: StaticCapabilitiesProvider(alias: "alpha"),
            beta: StaticCapabilitiesProvider(alias: "beta")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(stubs["alpha"]?.warmUpCount, 1)
        XCTAssertEqual(stubs["beta"]?.warmUpCount, 1)

        let targeted: Set<PersistentIdentifier> = [try XCTUnwrap(beta.persistentModelID)]
        try await manager.reload(project: project,
                                 snapshot: snapshot,
                                 providers: providers,
                                 serverIDs: targeted)

        XCTAssertEqual(stubs["alpha"]?.warmUpCount, 1, "Non-targeted provider should stay untouched")
        XCTAssertEqual(stubs["alpha"]?.resetCount, 0)
        XCTAssertEqual(stubs["beta"]?.warmUpCount, 1, "Configuration unchanged so no warm-up")
        XCTAssertEqual(stubs["beta"]?.resetCount, 0)
    }

    func testReloadRemovesMissingServerAndDisconnects() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Removal", isActive: true)
        let alpha = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        alpha.execPath = "/usr/bin/alpha"
        let beta = MCPBundler.Server(project: project, alias: "beta", kind: .local_stdio)
        beta.execPath = "/usr/bin/beta"
        project.servers.append(contentsOf: [alpha, beta])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: alpha)
        try TestCapabilitiesBuilder.prime(server: beta)
        try context.save()
        var snapshot = try await rebuildSnapshot(for: project)

        var stubs: [String: RecordingUpstreamProvider] = [:]
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: true)
                stubs[server.alias] = stub
                return stub
            }
        )

        var providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            alpha: StaticCapabilitiesProvider(alias: "alpha"),
            beta: StaticCapabilitiesProvider(alias: "beta")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(stubs["alpha"]?.disconnectReasons, [])
        XCTAssertEqual(stubs["beta"]?.disconnectReasons, [])

        project.servers.removeAll { $0 === beta }
        context.delete(beta)
        providers.removeValue(forKey: beta)
        try context.save()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)

        try await manager.reload(project: project,
                                 snapshot: snapshot,
                                 providers: providers,
                                 serverIDs: nil)

        XCTAssertEqual(stubs["alpha"]?.disconnectReasons, [], "Existing provider persists")
        XCTAssertEqual(stubs["beta"]?.disconnectReasons, [.removed], "Dropped provider should disconnect with .removed")
    }

    func testRehydratesProviderAfterStop() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Rehydrate", isActive: true)
        let server = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        server.execPath = "/usr/bin/alpha"
        project.servers.append(server)
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: server)
        try context.save()
        let snapshot = try await rebuildSnapshot(for: project)

        var latestStub: RecordingUpstreamProvider?
        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: true)
                latestStub = stub
                return stub
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: StaticCapabilitiesProvider(alias: "alpha")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)
        XCTAssertNotNil(latestStub)

        await manager.stop()

        let revived = await manager.fetchOrRehydrateProvider(alias: "alpha")
        let recording = try XCTUnwrap(revived as? RecordingUpstreamProvider)
        _ = try await recording.ensureClient()
    }

    func testNotificationsLogCountsMaintainForUntouchedProviders() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "NotificationScope", isActive: true)
        let alpha = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        alpha.execPath = "/usr/bin/alpha"
        let beta = MCPBundler.Server(project: project, alias: "beta", kind: .local_stdio)
        beta.execPath = "/usr/bin/beta"
        project.servers.append(contentsOf: [alpha, beta])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: alpha)
        try TestCapabilitiesBuilder.prime(server: beta)
        try context.save()
        var snapshot = try await rebuildSnapshot(for: project)

        var logsByAlias: [String: [String]] = [:]

        let manager = BundledServerManager(
            providerFactory: { server, _, logSink in
                let capturingSink: BundledServerManager.LogSink = { level, category, message in
                    if category == "upstream.lifecycle" && message.contains("event=notificationsInitialized") {
                        logsByAlias[server.alias, default: []].append(message)
                    }
                    await logSink(level, category, message)
                }

                return RecordingUpstreamProvider(server: server, keepWarm: true, logSink: capturingSink)
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            alpha: StaticCapabilitiesProvider(alias: "alpha"),
            beta: StaticCapabilitiesProvider(alias: "beta")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)

        XCTAssertEqual(logsByAlias["alpha"]?.last?.contains("count=1"), true)
        XCTAssertEqual(logsByAlias["beta"]?.last?.contains("count=1"), true)

        alpha.args = ["--updated"]
        try context.save()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)

        try await manager.reload(project: project,
                                 snapshot: snapshot,
                                 providers: providers,
                                 serverIDs: [try XCTUnwrap(alpha.persistentModelID)])

        XCTAssertEqual(logsByAlias["alpha"]?.last?.contains("count=2"), true, "Targeted provider should increment notification count")
        XCTAssertEqual(logsByAlias["beta"]?.last?.contains("count=1"), true, "Untouched provider should retain notification count")
    }

    func testCustomWarmUpHandlerRunsOncePerInvocation() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "HandlerCount", isActive: true)
        let alpha = MCPBundler.Server(project: project, alias: "alpha", kind: .local_stdio)
        alpha.execPath = "/usr/bin/alpha"
        let beta = MCPBundler.Server(project: project, alias: "beta", kind: .local_stdio)
        beta.execPath = "/usr/bin/beta"
        project.servers.append(contentsOf: [alpha, beta])
        context.insert(project)
        try context.save()

        try TestCapabilitiesBuilder.prime(server: alpha)
        try TestCapabilitiesBuilder.prime(server: beta)
        try context.save()
        var snapshot = try await rebuildSnapshot(for: project)

        var stubs: [String: RecordingUpstreamProvider] = [:]
        var handlerInvocations: [Set<String>] = []
        let initialWarmUpExpectation = expectation(description: "initial warm-up")
        let reloadWarmUpExpectation = expectation(description: "reload warm-up")

        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: true)
                stubs[server.alias] = stub
                return stub
            },
            warmUpHandler: { providers in
                let aliases = Set(providers.map(\.alias))
                handlerInvocations.append(aliases)
                if aliases == Set(["alpha", "beta"]) {
                    initialWarmUpExpectation.fulfill()
                } else if aliases == Set(["alpha"]) {
                    reloadWarmUpExpectation.fulfill()
                }
                for provider in providers {
                    try? await provider.ensureWarmConnection()
                }
            }
        )

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            alpha: StaticCapabilitiesProvider(alias: "alpha"),
            beta: StaticCapabilitiesProvider(alias: "beta")
        ]

        try await manager.start(project: project, snapshot: snapshot, providers: providers)
        await fulfillment(of: [initialWarmUpExpectation], timeout: 1.0)
        XCTAssertEqual(handlerInvocations.first, Set(["alpha", "beta"]))

        alpha.args = ["--updated"]
        try context.save()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)

        try await manager.reload(project: project,
                                 snapshot: snapshot,
                                 providers: providers,
                                 serverIDs: [try XCTUnwrap(alpha.persistentModelID)])

        await fulfillment(of: [reloadWarmUpExpectation], timeout: 1.0)
        XCTAssertEqual(handlerInvocations.count, 2)
        XCTAssertEqual(handlerInvocations.last, Set(["alpha"]))
    }

    func testSecurityScopeLogsIncludeExecAndBaseURL() async throws {
        var captured: [(String, String)] = []
        let sink: BundledServerManager.LogSink = { _, category, message in
            captured.append((category, message))
        }

        let localProject = Project(name: "Local", isActive: true)
        let localServer = MCPBundler.Server(project: localProject, alias: "local", kind: .local_stdio)
        localServer.execPath = "/usr/bin/local"
        localServer.cwd = "/tmp"
        let localProvider = RecordingUpstreamProvider(server: localServer, keepWarm: true, logSink: sink)
        try await localProvider.ensureClient()

        XCTAssertTrue(captured.contains(where: { category, message in
            category == "security.scope" && message.contains("alias=local") && message.contains("exec=/usr/bin/local") && message.contains("cwd=/tmp")
        }))

        var remoteCaptured: [(String, String)] = []
        let remoteSink: BundledServerManager.LogSink = { _, category, message in
            remoteCaptured.append((category, message))
        }

        let remoteProject = Project(name: "Remote", isActive: true)
        let remoteServer = MCPBundler.Server(project: remoteProject, alias: "remote", kind: .remote_http_sse)
        remoteServer.baseURL = "https://remote.example"
        let remoteProvider = RecordingUpstreamProvider(server: remoteServer, keepWarm: false, logSink: remoteSink)
        try await remoteProvider.ensureClient()

        XCTAssertTrue(remoteCaptured.contains(where: { category, message in
            category == "security.scope" && message.contains("alias=remote") && message.contains("baseURL=https://remote.example")
        }))

        await localProvider.disconnect(reason: .manual)
        await remoteProvider.disconnect(reason: .manual)
    }

    // MARK: - Context Optimization Tests

    func testContextOptimizationsDisabledReturnsOriginalTools() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)
        let (client, _, teardown) = try await makeContextOptimizationClient(projectOptimizationsEnabled: false,
                                                                            serverAlias: alias,
                                                                            tools: tools)
        defer { Task { await teardown() } }

        let (listedTools, _) = try await client.listTools()
        let listedNames = listedTools.map(\.name).sorted()
        let expectedNames = (tools.map(\.namespaced) + ["fetch_temp_file"]).sorted()
        XCTAssertEqual(listedNames, expectedNames)
    }

    func testContextOptimizationSearchToolIncludesSkillsAndFilters() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)
        let (client, _, teardown) = try await makeContextOptimizationClient(serverAlias: alias, tools: tools)
        defer { Task { await teardown() } }

        let (listedTools, _) = try await client.listTools()
        XCTAssertEqual(listedTools.map(\.name), ["search_tool", "call_tool"])

        let payloadAll = try await fetchSearchPayload(client: client, query: nil)
        XCTAssertEqual(payloadAll["total"] as? Int, 3)
        let allMatches = payloadAll["matches"] as? [[String: Any]]
        XCTAssertEqual(allMatches?.count, 3)
        let allAliases = Set(allMatches?.compactMap { $0["alias"] as? String } ?? [])
        XCTAssertTrue(allAliases.contains(alias))
        XCTAssertTrue(allAliases.contains(SkillsCapabilitiesBuilder.alias))
        XCTAssertTrue(allAliases.contains("mcpbundler"))

        let payloadFiltered = try await fetchSearchPayload(client: client, query: "demo")
        let filteredMatches = payloadFiltered["matches"] as? [[String: Any]]
        XCTAssertEqual(filteredMatches?.count, 1)
        XCTAssertEqual(filteredMatches?.first?["alias"] as? String, SkillsCapabilitiesBuilder.alias)
    }

    func testContextOptimizationCallToolProxiesToUpstream() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)
        let (client, providers, teardown) = try await makeContextOptimizationClient(serverAlias: alias, tools: tools)
        defer { Task { await teardown() } }

        let provider = try XCTUnwrap(providers[alias])
        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": "alpha result"]],
                "isError": false
            ]
        ])

        let callArgs: [String: Value] = [
            "tool_name": .string("\(alias)__summarize"),
            "arguments": .object(["topic": .string("context optimizations")])
        ]

        let (result, isError) = try await client.callTool(name: "call_tool", arguments: callArgs)
        XCTAssertEqual(isError ?? false, false)
        let text = try extractText(from: result)
        XCTAssertTrue(text.contains("alpha result"))

        let methodNames = await provider.observedMethodCalls()
        XCTAssertTrue(methodNames.contains("tools/call"))
    }

    // MARK: - Skills Visibility

    func testHideSkillsForNativeClientsFiltersToolsList() async throws {
        let alias = "alpha"
        var tools = makeContextTools(for: alias)
        tools.append(makeFetchResourceTool())

        let context = try makeSkillVisibilityContext(templateKey: SkillSyncLocationTemplates.claudeKey,
                                                     slug: "demo_skill")
        let (client, _, teardown) = try await makeContextOptimizationClient(
            projectOptimizationsEnabled: false,
            serverAlias: alias,
            tools: tools,
            clientName: "claude-code",
            persistenceContext: context,
            configureProject: { project in
                project.hideSkillsForNativeClients = true
            }
        )
        defer { Task { await teardown() } }

        let (listedTools, _) = try await client.listTools()
        let names = Set(listedTools.map(\.name))
        XCTAssertTrue(names.contains("\(alias)__summarize"))
        XCTAssertTrue(names.contains("fetch_temp_file"))
        XCTAssertFalse(names.contains("\(SkillsCapabilitiesBuilder.alias)__demo_skill"))
        XCTAssertFalse(names.contains(SkillsCapabilitiesBuilder.compatibilityToolName))
    }

    func testHideSkillsForNativeClientsRejectsSkillToolCalls() async throws {
        let alias = "alpha"
        var tools = makeContextTools(for: alias)
        tools.append(makeFetchResourceTool())

        let context = try makeSkillVisibilityContext(templateKey: SkillSyncLocationTemplates.codexKey,
                                                     slug: "demo_skill")
        let (client, _, teardown) = try await makeContextOptimizationClient(
            projectOptimizationsEnabled: false,
            serverAlias: alias,
            tools: tools,
            clientName: "codex-mcp-client",
            persistenceContext: context,
            configureProject: { project in
                project.hideSkillsForNativeClients = true
            }
        )
        defer { Task { await teardown() } }

        let skillName = "\(SkillsCapabilitiesBuilder.alias)__demo_skill"
        let (contents, isError) = try await client.callTool(name: skillName)
        XCTAssertEqual(isError ?? false, true)
        XCTAssertEqual(try extractText(from: contents), "Unknown tool: \(skillName)")

        let (fetchContents, fetchIsError) = try await client.callTool(name: SkillsCapabilitiesBuilder.compatibilityToolName)
        XCTAssertEqual(fetchIsError ?? false, true)
        XCTAssertEqual(try extractText(from: fetchContents),
                       "Unknown tool: \(SkillsCapabilitiesBuilder.compatibilityToolName)")
    }

    func testHideSkillsForNativeClientsExcludesSkillsFromSearchToolPayload() async throws {
        let alias = "alpha"
        var tools = makeContextTools(for: alias)
        tools.append(makeFetchResourceTool())

        let context = try makeSkillVisibilityContext(templateKey: SkillSyncLocationTemplates.claudeKey,
                                                     slug: "demo_skill")
        let (client, _, teardown) = try await makeContextOptimizationClient(
            serverAlias: alias,
            tools: tools,
            clientName: "claude-code",
            persistenceContext: context,
            configureProject: { project in
                project.hideSkillsForNativeClients = true
            }
        )
        defer { Task { await teardown() } }

        let payloadAll = try await fetchSearchPayload(client: client, query: nil)
        XCTAssertEqual(payloadAll["total"] as? Int, 2)
        let matchesAll = payloadAll["matches"] as? [[String: Any]]
        XCTAssertEqual(matchesAll?.count, 2)
        let aliasesAll = Set(matchesAll?.compactMap { $0["alias"] as? String } ?? [])
        XCTAssertTrue(aliasesAll.contains(alias))
        XCTAssertTrue(aliasesAll.contains("mcpbundler"))
        XCTAssertFalse(aliasesAll.contains(SkillsCapabilitiesBuilder.alias))

        let payloadDemo = try await fetchSearchPayload(client: client, query: "demo")
        let matchesDemo = payloadDemo["matches"] as? [[String: Any]]
        XCTAssertEqual(matchesDemo?.count, 0)
    }

    func testHideSkillsForNativeClientsFiltersResourcesAndDeniesRead() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)

        let skillOriginalURI = "mcpbundler-skill://demo/readme.md"
        let skillBundledURI = BundlerURI.wrap(alias: SkillsCapabilitiesBuilder.alias, originalURI: skillOriginalURI)
        let skillResource = NamespacedResource(name: "\(SkillsCapabilitiesBuilder.alias)__demo/readme.md",
                                               uri: skillBundledURI,
                                               alias: SkillsCapabilitiesBuilder.alias,
                                               originalURI: skillOriginalURI,
                                               description: nil)

        let upstreamOriginalURI = "file:///demo.txt"
        let upstreamBundledURI = BundlerURI.wrap(alias: alias, originalURI: upstreamOriginalURI)
        let upstreamResource = NamespacedResource(name: "\(alias)__demo.txt",
                                                  uri: upstreamBundledURI,
                                                  alias: alias,
                                                  originalURI: upstreamOriginalURI,
                                                  description: nil)

        let context = try makeSkillVisibilityContext(templateKey: SkillSyncLocationTemplates.codexKey,
                                                     slug: "demo_skill")
        let (client, _, teardown) = try await makeContextOptimizationClient(
            projectOptimizationsEnabled: false,
            serverAlias: alias,
            tools: tools,
            resources: [skillResource, upstreamResource],
            clientName: "codex-mcp-client",
            persistenceContext: context,
            configureProject: { project in
                project.hideSkillsForNativeClients = true
            }
        )
        defer { Task { await teardown() } }

        let (resources, _) = try await client.listResources()
        let uriSet = Set(resources.map(\.uri))
        XCTAssertTrue(uriSet.contains(upstreamBundledURI))
        XCTAssertFalse(uriSet.contains(skillBundledURI))

        let contents = try await client.readResource(uri: skillBundledURI)
        XCTAssertTrue(contents.isEmpty)
    }

    func testHideSkillsForNativeClientsFiltersPromptsAndDeniesGetPrompt() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)

        let skillPromptName = "\(SkillsCapabilitiesBuilder.alias)__demo_prompt"
        let skillPrompt = NamespacedPrompt(namespaced: skillPromptName,
                                           alias: SkillsCapabilitiesBuilder.alias,
                                           original: "demo_prompt",
                                           description: "Skill prompt")

        let upstreamPromptName = "\(alias)__demo_prompt"
        let upstreamPrompt = NamespacedPrompt(namespaced: upstreamPromptName,
                                              alias: alias,
                                              original: "demo_prompt",
                                              description: "Upstream prompt")

        let context = try makeSkillVisibilityContext(templateKey: SkillSyncLocationTemplates.claudeKey,
                                                     slug: "demo_skill")
        let (client, _, teardown) = try await makeContextOptimizationClient(
            projectOptimizationsEnabled: false,
            serverAlias: alias,
            tools: tools,
            prompts: [skillPrompt, upstreamPrompt],
            clientName: "claude-code",
            persistenceContext: context,
            configureProject: { project in
                project.hideSkillsForNativeClients = true
            }
        )
        defer { Task { await teardown() } }

        let (prompts, _) = try await client.listPrompts()
        let promptNames = Set(prompts.map(\.name))
        XCTAssertTrue(promptNames.contains(upstreamPromptName))
        XCTAssertFalse(promptNames.contains(skillPromptName))

        let (description, messages) = try await client.getPrompt(name: skillPromptName)
        XCTAssertNil(description)
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - Large Response Storage

    func testLargeResponsesStayInlineWhenFeatureDisabled() async throws {
        let tempDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let response = String(repeating: "inline-response", count: 600)

        let (client, provider, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = false
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        let (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        let text = try extractText(from: contents)
        XCTAssertEqual(text.count, response.count)
        XCTAssertFalse(text.contains("Saved response to"))
    }

    func testLargeResponsesPersistToTemporaryFileWhenEnabled() async throws {
        let tempDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "beta"
        let tool = makeSingleTool(for: alias)
        let response = String(repeating: "{\"value\":42}", count: 500)

        let (client, provider, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 100
            }
        )
        defer { Task { await teardown() } }

        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        let (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        let pointer = try extractText(from: contents)
        XCTAssertTrue(pointer.hasPrefix("Saved response to "), "Expected pointer text, got \(pointer)")
        XCTAssertTrue(pointer.contains("Size:"), "Pointer should include size instructions")
        XCTAssertTrue(pointer.contains("read it in chunks"), "Pointer should mention chunk-reading guidance")
        XCTAssertTrue(pointer.contains("If your client can't reach /tmp or /var/folders"), "Pointer should mention fetch_temp_file escape hatch")
        XCTAssertTrue(pointer.contains("fetch_temp_file({ \"path\": \""), "Pointer should show direct fetch_temp_file invocation")
        XCTAssertTrue(pointer.contains("To read just a portion"), "Pointer should include chunking explanation")
        XCTAssertTrue(pointer.contains("\"offset\": 0, \"length\": 2000"), "Pointer should show offset/length example")
        XCTAssertFalse(pointer.contains("call_tool("), "Pointer should not mention call_tool when context optimizations are disabled")
        let savedPath = extractPath(fromPointer: pointer)
        XCTAssertTrue(savedPath.hasSuffix(".json"), "Expected .json extension for JSON-looking payloads (\(savedPath))")
        let savedData = try String(contentsOfFile: savedPath, encoding: .utf8)
        XCTAssertEqual(savedData, response)
        XCTAssertNil(extractResourceURI(from: contents))
    }

    func testLargeResponsePointerUsesCallToolWhenContextOptimizationsEnabled() async throws {
        let tempDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "epsilon"
        let tool = makeSingleTool(for: alias)
        let response = String(repeating: "{\"value\":89}", count: 400)

        let (client, provider, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.contextOptimizationsEnabled = true
                project.largeToolResponseThreshold = 100
            }
        )
        defer { Task { await teardown() } }

        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        let (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        let pointer = try extractText(from: contents)
        XCTAssertTrue(pointer.contains("call_tool(\"fetch_temp_file\"")), "Pointer should reference call_tool when context optimizations are enabled")
        XCTAssertTrue(pointer.contains("/tmp or /var/folders"), "Pointer should mention allowed temp directories")
        XCTAssertFalse(pointer.contains("fetch_temp_file({ \"path\": \""), "Pointer should avoid direct invocation copy when call_tool is required")
    }

    func testLargeResponseResourceReadableViaResourcesRead() async throws {
        let tempDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "gamma"
        let tool = makeSingleTool(for: alias)
        let response = String(repeating: "long-response", count: 800)

        let (client, provider, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 100
            }
        )
        defer { Task { await teardown() } }

        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        let (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertNil(extractResourceURI(from: contents))
    }

    func testEnablingLargeResponseStorageDuringActiveSessionPersistsPointer() async throws {
        let tempDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "delta"
        let tool = makeSingleTool(for: alias)
        let response = String(repeating: "{\"value\":77}", count: 400)

        let project = Project(name: "RuntimeToggle", isActive: true)
        project.storeLargeToolResponsesAsFiles = false
        project.largeToolResponseThreshold = 100

        let server = MCPBundler.Server(project: project, alias: alias, kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)

        let snapshot = makeSnapshot(for: [tool])
        var providerByAlias: [String: RecordingUpstreamProvider] = [:]

        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: false)
                providerByAlias[server.alias] = stub
                return stub
            },
            warmUpHandler: nil,
            temporaryDirectoryProvider: { tempDirectory }
        )

        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(nil)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: "RuntimeToggleClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let teardown = { @Sendable () async in
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }
        defer { Task { await teardown() } }

        let provider = try XCTUnwrap(providerByAlias[alias])
        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        var (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        let inlineText = try extractText(from: contents)
        XCTAssertFalse(inlineText.contains("Saved response to"), "Feature disabled; expected inline response")

        project.storeLargeToolResponsesAsFiles = true
        try await host.reload(project: project,
                              snapshot: snapshot,
                              providers: providers)

        await provider.updateResponses([
            "tools/call": [
                "content": [["type": "text", "text": response]],
                "isError": false
            ]
        ])

        (contents, isError) = try await client.callTool(name: tool.namespaced)
        XCTAssertEqual(isError ?? false, false)
        let pointer = try extractText(from: contents)
        XCTAssertTrue(pointer.hasPrefix("Saved response to "), "Expected pointer text after enabling storage")
        let savedPath = extractPath(fromPointer: pointer)
        let savedData = try String(contentsOfFile: savedPath, encoding: .utf8)
        XCTAssertEqual(savedData, response)
    }

    // MARK: - Fetch Temp File Tool

    func testToolsListAlwaysIncludesFetchTempFile() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = false
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let (listedTools, _) = try await client.listTools()
        let names = listedTools.map(\.name)
        XCTAssertTrue(names.contains(tool.namespaced))
        XCTAssertTrue(names.contains("fetch_temp_file"))
    }

    func testFetchTempFileDirectCallReturnsContents() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let body = "temporary output\nline two"
        let fileURL = tempDirectory.appendingPathComponent("fetch-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let args: [String: Value] = ["path": .string(fileURL.path)]
        let (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), body)
    }

    func testFetchTempFileSupportsOffsetAndLength() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let body = "0123456789"
        let fileURL = tempDirectory.appendingPathComponent("slice-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: {
                $0.storeLargeToolResponsesAsFiles = true
                $0.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        var args: [String: Value] = [
            "path": .string(fileURL.path),
            "offset": .int(2),
            "length": .int(4)
        ]
        var (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), "2345")

        args = [
            "path": .string(fileURL.path),
            "offset": .int(8)
        ]
        (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), "89")

        args = [
            "path": .string(fileURL.path),
            "offset": .int(body.count)
        ]
        (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), "")
    }

    func testFetchTempFileRejectsInvalidOffsetsAndLengths() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let body = "abcdef"
        let fileURL = tempDirectory.appendingPathComponent("slice-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: {
                $0.storeLargeToolResponsesAsFiles = true
                $0.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        var args: [String: Value] = [
            "path": .string(fileURL.path),
            "offset": .int(-1)
        ]
        var (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, true)
        XCTAssertTrue(try extractText(from: contents).contains("offset"), "Expected offset error")

        args = [
            "path": .string(fileURL.path),
            "length": .int(0)
        ]
        (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, true)
        XCTAssertTrue(try extractText(from: contents).contains("length"), "Expected length error")

        args = [
            "path": .string(fileURL.path),
            "offset": .int(999)
        ]
        (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, true)
        XCTAssertTrue(try extractText(from: contents).contains("Offset exceeds"), "Expected offset beyond length error")
    }

    func testFetchTempFileRejectsPathsOutsideTmp() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let args: [String: Value] = ["path": .string("/etc/passwd")]
        let (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, true)
        let text = try extractText(from: contents)
        XCTAssertTrue(text.contains("Path must begin with /tmp or /var/folders"))
    }

    func testFetchTempFileAcceptsVarFoldersPaths() async throws {
        let scratchDirectory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let body = "var folders content"
        let fileURL = scratchDirectory.appendingPathComponent("fetch-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: scratchDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let args: [String: Value] = ["path": .string(fileURL.path)]
        let (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), body)
    }

    func testFetchTempFileRejectsOversizeFiles() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let oversizeLimit = 2 * 1024 * 1024
        let oversizedBody = String(repeating: "A", count: oversizeLimit + 1)
        let fileURL = tempDirectory.appendingPathComponent("fetch-\(UUID().uuidString).txt")
        try oversizedBody.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = true
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let args: [String: Value] = ["path": .string(fileURL.path)]
        let (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, true)
        let text = try extractText(from: contents)
        XCTAssertTrue(text.contains("supported limit"))
    }

    func testFetchTempFileViaCallToolUnderContextOptimizations() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tools = makeContextTools(for: alias)
        let body = "context fetch body"
        let fileURL = tempDirectory.appendingPathComponent("fetch-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeContextOptimizationClient(serverAlias: alias,
                                                                            tools: tools,
                                                                            configureProject: { project in
                                                                                project.storeLargeToolResponsesAsFiles = false
                                                                                project.largeToolResponseThreshold = 50
                                                                            })
        defer { Task { await teardown() } }

        let args: [String: Value] = [
            "tool_name": .string("fetch_temp_file"),
            "arguments": .object(["path": .string(fileURL.path)])
        ]
        let (contents, isError) = try await client.callTool(name: "call_tool", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), body)
    }

    func testSearchToolIncludesFetchTempFile() async throws {
        let alias = "alpha"
        let tools = makeContextTools(for: alias)
        let (client, _, teardown) = try await makeContextOptimizationClient(serverAlias: alias,
                                                                            tools: tools,
                                                                            configureProject: { project in
                                                                                project.storeLargeToolResponsesAsFiles = false
                                                                                project.largeToolResponseThreshold = 10
                                                                            })
        defer { Task { await teardown() } }

        let payload = try await fetchSearchPayload(client: client, query: "fetch")
        XCTAssertEqual(payload["total"] as? Int, 3)
        let matches = payload["matches"] as? [[String: Any]]
        XCTAssertEqual(matches?.count, 1)
        let matchNames = matches?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(matchNames, ["fetch_temp_file"])
        XCTAssertEqual(matches?.first?["alias"] as? String, "mcpbundler")
    }

    func testFetchTempFileAvailableWhenStorageDisabled() async throws {
        let tempDirectory = try makeTmpDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let alias = "alpha"
        let tool = makeSingleTool(for: alias)
        let body = "disabled toggle still allows fetching"
        let fileURL = tempDirectory.appendingPathComponent("fetch-\(UUID().uuidString).txt")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)

        let (client, _, teardown) = try await makeLargeResponseClient(
            alias: alias,
            tool: tool,
            tempDirectory: tempDirectory,
            configureProject: { project in
                project.storeLargeToolResponsesAsFiles = false
                project.largeToolResponseThreshold = 10
            }
        )
        defer { Task { await teardown() } }

        let args: [String: Value] = ["path": .string(fileURL.path)]
        let (contents, isError) = try await client.callTool(name: "fetch_temp_file", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        XCTAssertEqual(try extractText(from: contents), body)
    }

    private func makeContextOptimizationClient(projectOptimizationsEnabled: Bool = true,
                                               serverAlias: String,
                                               tools: [NamespacedTool],
                                               resources: [NamespacedResource] = [],
                                               prompts: [NamespacedPrompt] = [],
                                               clientName: String = "ContextClient",
                                               persistenceContext: ModelContext? = nil,
                                               configureProject: ((Project) -> Void)? = nil) async throws -> (Client, [String: RecordingUpstreamProvider], @Sendable () async -> Void) {
        let project = Project(name: "ContextProject", isActive: true)
        project.contextOptimizationsEnabled = projectOptimizationsEnabled
        configureProject?(project)

        let server = MCPBundler.Server(project: project, alias: serverAlias, kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)

        let snapshot = makeSnapshot(for: tools, resources: resources, prompts: prompts)
        var providerByAlias: [String: RecordingUpstreamProvider] = [:]

        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: false)
                providerByAlias[server.alias] = stub
                return stub
            }
        )

        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        if let persistenceContext {
            persistenceContext.insert(project)
            try? persistenceContext.save()
        }
        host.setPersistenceContext(persistenceContext)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: clientName, version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let teardown = { @Sendable () async in
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }

        return (client, providerByAlias, teardown)
    }

    private func makeSkillVisibilityContext(templateKey: String,
                                            slug: String) throws -> ModelContext {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let skill = SkillRecord(slug: slug,
                                name: "Demo Skill",
                                descriptionText: "Skill description",
                                sourcePath: "/tmp/\(slug)",
                                isArchive: false)
        let location = SkillSyncLocation(locationId: templateKey,
                                         displayName: templateKey.capitalized,
                                         rootPath: "/tmp/\(templateKey)/skills",
                                         disabledRootPath: "/tmp/\(templateKey)/skills.disabled",
                                         isManaged: true,
                                         pinRank: 0,
                                         templateKey: templateKey,
                                         kind: .builtIn)
        let enablement = SkillLocationEnablement(skill: skill, location: location, enabled: true)

        context.insert(skill)
        context.insert(location)
        context.insert(enablement)
        try context.save()
        return context
    }

    private func makeContextTools(for alias: String) -> [NamespacedTool] {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return [
            NamespacedTool(namespaced: "\(alias)__summarize",
                           alias: alias,
                           original: "summarize",
                           title: "Summarize",
                           description: "Summarize content",
                           inputSchema: schema,
                           annotations: nil),
            NamespacedTool(namespaced: "\(SkillsCapabilitiesBuilder.alias)__demo_skill",
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: "demo_skill",
                           title: "Demo Skill",
                           description: "Skill-provided tool",
                           inputSchema: schema,
                           annotations: nil)
        ]
    }

    private func makeFetchResourceTool() -> NamespacedTool {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return NamespacedTool(namespaced: SkillsCapabilitiesBuilder.compatibilityToolName,
                              alias: SkillsCapabilitiesBuilder.alias,
                              original: SkillsCapabilitiesBuilder.compatibilityToolName,
                              title: "Fetch Skill Resource",
                              description: "Compatibility helper for clients without resources/read.",
                              inputSchema: schema,
                              annotations: nil)
    }

    private func makeSnapshot(for tools: [NamespacedTool],
                              resources: [NamespacedResource] = [],
                              prompts: [NamespacedPrompt] = []) -> BundlerAggregator.Snapshot {
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

    private func makeSingleTool(for alias: String) -> NamespacedTool {
        let schema: Value = .object([
            "type": .string("object"),
            "properties": .object([:])
        ])
        return NamespacedTool(namespaced: "\(alias)__demoTool",
                              alias: alias,
                              original: "demoTool",
                              title: "Demo Tool",
                              description: "Returns demo content",
                              inputSchema: schema,
                              annotations: nil)
    }

    private func makeLargeResponseClient(alias: String,
                                         tool: NamespacedTool,
                                         tempDirectory: URL,
                                         configureProject: (Project) -> Void) async throws -> (Client, RecordingUpstreamProvider, @Sendable () async -> Void) {
        let project = Project(name: "LargeResponse-\(alias)", isActive: true)
        configureProject(project)

        let server = MCPBundler.Server(project: project, alias: alias, kind: .local_stdio)
        server.execPath = "/usr/bin/mock"
        project.servers.append(server)

        let snapshot = makeSnapshot(for: [tool])
        var providerByAlias: [String: RecordingUpstreamProvider] = [:]

        let manager = BundledServerManager(
            providerFactory: { server, _, _ in
                let stub = RecordingUpstreamProvider(server: server, keepWarm: false)
                providerByAlias[server.alias] = stub
                return stub
            },
            warmUpHandler: nil,
            temporaryDirectoryProvider: { tempDirectory }
        )

        let (factory, clientTransport, teardownTransport) = BundledServerHost.TransportFactory.inMemoryLoopback()
        let host = BundledServerHost(manager: manager, transportFactory: factory)
        host.setPersistenceContext(nil)

        let providers: [MCPBundler.Server: any CapabilitiesProvider] = [
            server: InlineCapabilitiesProvider(capabilities: TestCapabilitiesBuilder.makeDefaultCapabilities(for: server))
        ]

        try await host.start(project: project,
                             snapshot: snapshot,
                             providers: providers)

        let client = Client(name: "LargeResponseClient", version: "1.0.0")
        _ = try await client.connect(transport: clientTransport)

        let teardown = { @Sendable () async in
            await client.disconnect()
            await host.stop()
            await teardownTransport()
        }

        let provider = try XCTUnwrap(providerByAlias[alias])
        return (client, provider, teardown)
    }

    private func fetchSearchPayload(client: Client, query: String?) async throws -> [String: Any] {
        var args: [String: Value] = [:]
        if let query {
            args["query"] = .string(query)
        }
        let (content, isError) = try await client.callTool(name: "search_tool", arguments: args)
        XCTAssertEqual(isError ?? false, false)
        let text = try extractText(from: content)
        let data = Data(text.utf8)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        return try XCTUnwrap(json)
    }

    private func extractText(from contents: [Tool.Content]) throws -> String {
        for content in contents {
            if case let .text(value) = content {
                return value
            }
        }
        XCTFail("Expected text content")
        return ""
    }

    private func extractResourceURI(from contents: [Tool.Content]) -> String? {
        for content in contents {
            if case let .resource(uri, _, _) = content {
                return uri
            }
        }
        return nil
    }

    private func extractPath(fromPointer pointer: String) -> String {
        let prefix = "Saved response to "
        guard let prefixRange = pointer.range(of: prefix) else { return pointer }
        let remainder = pointer[prefixRange.upperBound...]
        if let newline = remainder.firstIndex(of: "\n") {
            return remainder[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    }


    private func rebuildSnapshot(for project: Project) async throws -> BundlerAggregator.Snapshot {
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        return try ProjectSnapshotCache.snapshot(for: project)
    }

    private func makeTmpDirectory() throws -> URL {
        let base = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let url = base.appendingPathComponent("BundlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScratchDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("BundlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct StaticCapabilitiesProvider: CapabilitiesProvider {
    let alias: String

    func fetchCapabilities(for server: MCPBundler.Server) async throws -> MCPCapabilities {
        TestCapabilitiesBuilder.makeDefaultCapabilities(for: server)
    }
}

private enum WarmUpTestError: Error {
    case failed
}

@MainActor
final class SkillsCapabilitiesBuilderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testCompatibilityToolRenamedAndDescriptionsStayAuthorProvided() async throws {
        let library = SkillsLibraryService(root: tempDirectory)
        let (directory, skillSlug) = try writeSkillFixture(at: tempDirectory,
                                                           name: "Demo Skill",
                                                           description: "Author provided description",
                                                           body: "Use me wisely.")
        try await library.reload()

        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "Skills", isActive: true)
        context.insert(project)

        let skillRecord = SkillRecord(slug: skillSlug,
                                      name: "Demo Skill",
                                      descriptionText: "Stored description",
                                      sourcePath: directory.path,
                                      isArchive: false)
        context.insert(skillRecord)
        let selection = ProjectSkillSelection(project: project, skillSlug: skillSlug, enabled: true)
        context.insert(selection)
        try context.save()

        let caps = await SkillsCapabilitiesBuilder.capabilities(for: project,
                                                                library: library,
                                                                in: context)
        let toolNames = caps.tools.map { $0.name }
        XCTAssertTrue(toolNames.contains(skillSlug))
        XCTAssertTrue(toolNames.contains(SkillsCapabilitiesBuilder.compatibilityToolName))
        XCTAssertEqual(toolNames.filter { $0 == SkillsCapabilitiesBuilder.compatibilityToolName }.count, 1)

        let compatibility = caps.tools.first { $0.name == SkillsCapabilitiesBuilder.compatibilityToolName }
        let demoTool = caps.tools.first { $0.name == skillSlug }

        XCTAssertEqual(demoTool?.description, "Author provided description")
        XCTAssertEqual(compatibility?.title, "Fetch Skill Resource")
        let description = try XCTUnwrap(compatibility?.description)
        XCTAssertTrue(description.contains("resources/read"))
        XCTAssertTrue(description.contains(SkillsCapabilitiesBuilder.compatibilityToolName))
    }
}

@MainActor
final class BundledServerSkillsTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testSkillInvocationWrapsUsageAndInstructions() async throws {
        let (manager, slug, instructionBody) = try makeSkillRuntime(subjectName: "Demo Skill",
                                                                    body: "Follow the steps carefully.")

        let result = await manager.handleSkillInvocation(slug: slug,
                                                         arguments: ["task": .string("Summarize docs")])
        XCTAssertEqual(result.isError, false)
        let text = try extractText(from: result.content)
        let payload = try XCTUnwrap(parseSkillPayload(text))

        let usage = try XCTUnwrap(payload["usage"] as? String)
        XCTAssertEqual(usage, SkillsInstructionCopy.skillsUsageText)
        XCTAssertTrue(usage.contains(SkillsCapabilitiesBuilder.compatibilityToolName))

        let decorated = try XCTUnwrap(payload["instructions"] as? String)
        let preamble = SkillsInstructionCopy.skillInstructionPreamble(displayName: "Demo Skill")
        XCTAssertTrue(decorated.hasPrefix(preamble))
        XCTAssertTrue(decorated.contains(instructionBody))
    }

    func testExistingPreambleIsNotDuplicated() async throws {
        let existing = "[Skill Notice] Custom preamble already present.\nAdditional details."
        let (manager, slug, _) = try makeSkillRuntime(subjectName: "Legacy Skill", body: existing)

        let result = await manager.handleSkillInvocation(slug: slug,
                                                         arguments: ["task": .string("Check duplication")])
        let text = try extractText(from: result.content)
        let payload = try XCTUnwrap(parseSkillPayload(text))
        let decorated = try XCTUnwrap(payload["instructions"] as? String)
        XCTAssertEqual(decorated, existing)
    }

    private func makeSkillRuntime(subjectName: String,
                                  body: String) throws -> (BundledServerManager, String, String) {
        let library = SkillsLibraryService(root: tempDirectory)
        let (directory, slug) = try writeSkillFixture(at: tempDirectory,
                                                      name: subjectName,
                                                      description: "Runtime description",
                                                      body: body,
                                                      allowedTools: ["http.get"])

        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "Runtime", isActive: true)
        context.insert(project)
        let record = SkillRecord(slug: slug,
                                 name: subjectName,
                                 descriptionText: "Runtime description",
                                 sourcePath: directory.path,
                                 isArchive: false)
        context.insert(record)
        let selection = ProjectSkillSelection(project: project, skillSlug: slug, enabled: true)
        context.insert(selection)
        try context.save()

        let manager = BundledServerManager(temporaryDirectoryProvider: { FileManager.default.temporaryDirectory },
                                           skillsLibrary: library)
        manager.setPersistenceContext(context)
        return (manager, slug, body)
    }

    private func parseSkillPayload(_ json: String) throws -> [String: Any]? {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
    }

    private func extractText(from contents: [Tool.Content]) throws -> String {
        for content in contents {
            if case let .text(value) = content {
                return value
            }
        }
        XCTFail("Expected text content")
        return ""
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SkillsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func writeSkillFixture(at root: URL,
                               name: String,
                               description: String,
                               body: String,
                               allowedTools: [String] = []) throws -> (URL, String) {
    let slug = makeSlug(from: name)
    let directory = root.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    var frontMatter = ["name: \(name)", "description: \(description)"]
    if !allowedTools.isEmpty {
        frontMatter.append("allowed-tools:")
        for tool in allowedTools {
            frontMatter.append("  - \(tool)")
        }
    }
    let header = frontMatter.joined(separator: "\n")
    let contents = """
    ---
    \(header)
    ---
    \(body)
    """
    let skillFile = directory.appendingPathComponent("SKILL.md")
    try contents.write(to: skillFile, atomically: true, encoding: .utf8)
    return (directory, slug)
}

private func makeSlug(from name: String) -> String {
    let lowered = name.lowercased()
    let mapped = lowered.map { character -> Character in
        if character.isLetter || character.isNumber {
            return character
        }
        return "-"
    }
    var slug = String(mapped)
    while slug.contains("--") {
        slug = slug.replacingOccurrences(of: "--", with: "-")
    }
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}
