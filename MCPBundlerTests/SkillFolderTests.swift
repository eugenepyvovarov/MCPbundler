import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class SkillFolderTests: XCTestCase {
    func testDeletingFolderNullifiesFolderRelationship() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        let folder = SkillFolder(name: "Utilities")
        context.insert(folder)

        let record = SkillRecord(skillId: UUID().uuidString,
                                 slug: "demo",
                                 name: "Demo",
                                 descriptionText: "Demo skill",
                                 exposeViaMcp: false,
                                 sourcePath: "/tmp/demo",
                                 isArchive: false)
        record.folder = folder
        context.insert(record)
        try context.save()

        context.delete(folder)
        try context.save()

        let descriptor = FetchDescriptor<SkillRecord>()
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.folder)
    }
}
