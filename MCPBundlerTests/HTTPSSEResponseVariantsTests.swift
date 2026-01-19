import XCTest
@testable import MCPBundler
import MCP

@MainActor
final class HTTPSSEResponseVariantsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        InMemoryHTTPSSEServer.register()
    }
    override class func tearDown() {
        InMemoryHTTPSSEServer.unregister()
        super.tearDown()
    }

    func test_capabilities_skip_missing_resources_and_prompts() async throws {
        InMemoryHTTPSSEServer.reset()
        InMemoryHTTPSSEServer.config = InMemoryHTTPSSEServer.Config()
        InMemoryHTTPSSEServer.config.emitEndpointAfter = 0
        InMemoryHTTPSSEServer.config.initialBasePostStatus = nil
        InMemoryHTTPSSEServer.config.endpointVariant = .relative

        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = ModelContext(container)
        let project = Project(name: "Compat", isActive: true)
        context.insert(project)
        let server = Server(project: project, alias: "obsidian", kind: .remote_http_sse)
        server.baseURL = InMemoryHTTPSSEServer.config.baseURL.absoluteString
        context.insert(server)
        try context.save()

        let provider = SDKRemoteHTTPProvider()
        let caps = try await provider.fetchCapabilities(for: server)
        XCTAssertEqual(caps.tools.first?.name, "hello")
        XCTAssertNil(caps.resources)
        XCTAssertNil(caps.prompts)

        let entries = try context.fetch(FetchDescriptor<LogEntry>())
        let category = "server.\(normalizedAliasForLogs(server.alias)).compat"
        let compatEntries = entries.filter { $0.project == project && $0.category == category }
        let decoder = JSONDecoder()
        let methods = compatEntries.compactMap { entry -> String? in
            guard let data = entry.metadata,
                  let metadata = try? decoder.decode([String: String].self, from: data) else {
                return nil
            }
            return metadata["method"]
        }

        XCTAssertTrue(methods.contains("resources/list"), "Expected compat log for resources/list.")
        XCTAssertTrue(methods.contains("prompts/list"), "Expected compat log for prompts/list.")
    }
}

private func normalizedAliasForLogs(_ alias: String) -> String {
    let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "unnamed" }
    return trimmed.replacingOccurrences(of: #"[^A-Za-z0-9_\-]"#, with: "-", options: .regularExpression)
}
