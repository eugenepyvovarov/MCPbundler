import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class OAuthMigrationTests: XCTestCase {
    func testBackfillCreatesOAuthRecordsForRemoteServers() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()

        let authoringContext = ModelContext(container)
        authoringContext.autosaveEnabled = false

        let project = Project(name: "Test", isActive: true)
        authoringContext.insert(project)

        let server = Server(project: project, alias: "Remote", kind: .remote_http_sse)
        server.oauthConfiguration = nil
        server.oauthState = nil
        authoringContext.insert(server)

        try authoringContext.save()

        let timestamp = Date(timeIntervalSince1970: 123)
        try OAuthMigration.performInitialBackfill(in: container, clock: { timestamp })

        let verificationContext = ModelContext(container)
        let fetch = FetchDescriptor<Server>(predicate: #Predicate { $0.alias == "Remote" })
        let servers = try verificationContext.fetch(fetch)
        guard let fetched = servers.first else {
            XCTFail("Expected to fetch backfilled server")
            return
        }

        XCTAssertNotNil(fetched.oauthConfiguration, "Backfill should create OAuth configuration")
        XCTAssertNotNil(fetched.oauthState, "Backfill should create OAuth state")
        XCTAssertEqual(fetched.oauthStatus, .unauthorized)
        XCTAssertEqual(fetched.oauthConfiguration?.discoveredAt, timestamp)
    }

    func testBackfillDoesNotDuplicateExistingOAuthRecords() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()

        let context = ModelContext(container)
        context.autosaveEnabled = false

        let project = Project(name: "Existing", isActive: true)
        context.insert(project)

        let server = Server(project: project, alias: "RemoteExisting", kind: .remote_http_sse)
        let configuration = OAuthConfiguration(server: server)
        let state = OAuthState(server: server)
        server.oauthConfiguration = configuration
        server.oauthState = state
        server.oauthStatus = .authorized
        context.insert(server)
        context.insert(configuration)
        context.insert(state)

        try context.save()

        try OAuthMigration.performInitialBackfill(in: container)

        let verificationContext = ModelContext(container)
        let fetch = FetchDescriptor<OAuthConfiguration>(predicate: #Predicate { $0.server?.alias == "RemoteExisting" })
        let configurations = try verificationContext.fetch(fetch)
        XCTAssertEqual(configurations.count, 1, "Backfill should not duplicate configurations")

        let stateFetch = FetchDescriptor<OAuthState>(predicate: #Predicate { $0.server?.alias == "RemoteExisting" })
        let states = try verificationContext.fetch(stateFetch)
        XCTAssertEqual(states.count, 1, "Backfill should not duplicate states")
    }
}
