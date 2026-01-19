import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class SkillMarketplaceSourceBackfillTests: XCTestCase {
    func testBackfillInsertsDefaultMarketplaces() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        SkillMarketplaceSourceBackfill.perform(in: container)

        let sources = try context.fetch(FetchDescriptor<SkillMarketplaceSource>())
        let normalized = Set(sources.map(\.normalizedKey))

        XCTAssertTrue(normalized.contains("eugenepyvovarov/mcpbundler-agent-skills-marketplace"))
        XCTAssertTrue(normalized.contains("composiohq/awesome-claude-skills"))

        let curated = sources.first { $0.normalizedKey == "eugenepyvovarov/mcpbundler-agent-skills-marketplace" }
        XCTAssertEqual(curated?.displayName, "MCPBundler Currated Marketplace")
    }

    func testDefaultSortingPrefersCuratedMarketplace() {
        let curated = SkillMarketplaceSource(owner: "eugenepyvovarov",
                                             repo: "mcpbundler-agent-skills-marketplace",
                                             displayName: "MCPBundler Currated Marketplace")
        let awesome = SkillMarketplaceSource(owner: "ComposioHQ",
                                             repo: "awesome-claude-skills",
                                             displayName: "awesome-claude-skills")
        let sorted = SkillMarketplaceSourceDefaults.sortSources([awesome, curated])

        XCTAssertEqual(sorted.first?.normalizedKey, "eugenepyvovarov/mcpbundler-agent-skills-marketplace")
    }
}
