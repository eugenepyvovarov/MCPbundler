import XCTest
@testable import MCPBundler

@MainActor
final class ProviderFolderTests: XCTestCase {
    func testEffectiveEnablementAndSnapshotRespectsFolderToggle() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        let project = Project(name: "Test Project")
        context.insert(project)

        let folder = ProviderFolder(project: project, name: "Group A", isEnabled: false, isCollapsed: false)
        context.insert(folder)
        project.folders.append(folder)

        let server = Server(project: project, alias: "srv-1", kind: .local_stdio)
        server.folder = folder
        let capabilities = MCPCapabilities(serverName: "srv-1",
                                           serverDescription: nil,
                                           tools: [MCPTool(name: "tool-1")],
                                           resources: nil,
                                           prompts: nil)
        if let payload = try? JSONEncoder().encode(capabilities) {
            let cache = CapabilityCache(server: server, payload: payload)
            server.capabilityCaches.append(cache)
        }
        project.servers.append(server)

        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        var snapshot = try ProjectSnapshotCache.snapshot(for: project)
        XCTAssertTrue(snapshot.tools.isEmpty, "Disabled folder should prevent server from appearing in snapshot")

        folder.isEnabled = true
        project.markUpdated()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)
        XCTAssertEqual(snapshot.tools.count, 1, "Enabling folder should allow enabled servers to appear")

        folder.isEnabled = false
        project.markUpdated()
        try await ProjectSnapshotCache.rebuildSnapshot(for: project)
        snapshot = try ProjectSnapshotCache.snapshot(for: project)
        XCTAssertTrue(snapshot.tools.isEmpty, "Disabling folder again should remove server from snapshot")
    }
}
