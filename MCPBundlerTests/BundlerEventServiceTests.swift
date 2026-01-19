import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class BundlerEventServiceTests: XCTestCase {
    func testEnqueueMarkAndDeleteLifecycle() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Lifecycle", isActive: true)
        context.insert(project)
        try context.save()

        let service = BundlerEventService(context: context)
        service.enqueue(for: project, type: .snapshotRebuilt)

        var events = service.fetchPendingEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .snapshotRebuilt)
        XCTAssertEqual(events.first?.projectToken, project.eventToken)
        XCTAssertFalse(events.first?.handled ?? true)

        service.markEventsHandled(events)
        XCTAssertTrue(events.allSatisfy { $0.handled })

        service.deleteEvents(events)
        events = service.fetchPendingEvents()
        XCTAssertTrue(events.isEmpty)
    }

    func testPruneRemovesStaleEvents() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Prune", isActive: true)
        context.insert(project)
        try context.save()

        let service = BundlerEventService(context: context)
        let staleDate = Date().addingTimeInterval(-172_800) // 2 days ago
        service.enqueue(for: project, type: .serverAdded, createdAt: staleDate)
        service.enqueue(for: project, type: .serverUpdated)

        XCTAssertEqual(service.fetchPendingEvents().count, 2)

        let cutoff = Date().addingTimeInterval(-86_400) // 1 day ago
        service.pruneEvents(olderThan: cutoff)

        let remaining = service.fetchPendingEvents()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.type, .serverUpdated)
    }

    func testEnqueueWithServersCapturesServerTokens() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Servers", isActive: true)
        let server = Server(project: project, alias: "alpha", kind: .local_stdio)
        project.servers.append(server)

        context.insert(project)
        try context.save()

        let service = BundlerEventService(context: context)
        service.enqueue(for: project, servers: [server], type: .serverDisabled)

        let events = service.fetchPendingEvents()
        XCTAssertEqual(events.count, 1)
        let event = events[0]
        XCTAssertEqual(event.type, .serverDisabled)
        XCTAssertEqual(event.projectToken, project.eventToken)
        XCTAssertEqual(event.serverTokens, [server.eventToken])
    }

    func testSnapshotRebuildEnqueuesEvent() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)

        let project = Project(name: "Snapshot", isActive: true)
        let server = Server(project: project, alias: "alpha", kind: .local_stdio)
        project.servers.append(server)

        context.insert(project)
        try context.save()

        try await ProjectSnapshotCache.rebuildSnapshot(for: project)

        let service = BundlerEventService(context: context)
        let events = service.fetchPendingEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .snapshotRebuilt)
        XCTAssertEqual(events.first?.projectToken, project.eventToken)
    }

}
