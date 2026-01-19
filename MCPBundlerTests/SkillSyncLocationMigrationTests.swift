import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class SkillSyncLocationMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SkillSyncLocationMigrationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testBackfillCreatesLocationsAndEnablements() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        let skill = SkillRecord(slug: "demo-skill",
                                name: "Demo Skill",
                                descriptionText: "A test skill.",
                                enabledInCodex: true,
                                enabledInClaude: true,
                                exposeViaMcp: false,
                                sourcePath: "/tmp/demo-skill",
                                isArchive: false)
        context.insert(skill)
        try context.save()

        defaults.set(true, forKey: NativeSkillsSyncPreferences.syncCodexEnabledKey)
        defaults.set(true, forKey: NativeSkillsSyncPreferences.syncClaudeEnabledKey)

        SkillSyncLocationBackfill.perform(in: container, userDefaults: defaults)

        let locations = try context.fetch(FetchDescriptor<SkillSyncLocation>())
        let codex = locations.first { $0.locationId == SkillSyncLocationTemplates.codexKey }
        let claude = locations.first { $0.locationId == SkillSyncLocationTemplates.claudeKey }

        XCTAssertNotNil(codex)
        XCTAssertNotNil(claude)
        XCTAssertEqual(codex?.isManaged, true)
        XCTAssertEqual(claude?.isManaged, true)
        XCTAssertEqual(codex?.pinRank, 0)
        XCTAssertEqual(claude?.pinRank, 1)

        let enablements = try context.fetch(FetchDescriptor<SkillLocationEnablement>())
        let codexEnablement = enablements.first {
            $0.location?.locationId == SkillSyncLocationTemplates.codexKey &&
                $0.skill?.skillId == skill.skillId
        }
        let claudeEnablement = enablements.first {
            $0.location?.locationId == SkillSyncLocationTemplates.claudeKey &&
                $0.skill?.skillId == skill.skillId
        }

        XCTAssertEqual(codexEnablement?.enabled, true)
        XCTAssertEqual(claudeEnablement?.enabled, true)
    }

    func testBackfillLeavesLocationsUnmanagedWhenPreferencesDisabled() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        let skill = SkillRecord(slug: "demo-skill",
                                name: "Demo Skill",
                                descriptionText: "A test skill.",
                                enabledInCodex: true,
                                enabledInClaude: false,
                                exposeViaMcp: false,
                                sourcePath: "/tmp/demo-skill",
                                isArchive: false)
        context.insert(skill)
        try context.save()

        defaults.set(false, forKey: NativeSkillsSyncPreferences.syncCodexEnabledKey)
        defaults.set(false, forKey: NativeSkillsSyncPreferences.syncClaudeEnabledKey)

        SkillSyncLocationBackfill.perform(in: container, userDefaults: defaults)

        let locations = try context.fetch(FetchDescriptor<SkillSyncLocation>())
        let codex = locations.first { $0.locationId == SkillSyncLocationTemplates.codexKey }
        let claude = locations.first { $0.locationId == SkillSyncLocationTemplates.claudeKey }

        XCTAssertNotNil(codex)
        XCTAssertNotNil(claude)
        XCTAssertEqual(codex?.isManaged, false)
        XCTAssertEqual(claude?.isManaged, false)

        let enablements = try context.fetch(FetchDescriptor<SkillLocationEnablement>())
        let codexEnablement = enablements.first {
            $0.location?.locationId == SkillSyncLocationTemplates.codexKey &&
                $0.skill?.skillId == skill.skillId
        }
        XCTAssertEqual(codexEnablement?.enabled, true)
    }
}
