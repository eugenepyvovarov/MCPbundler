import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class SkillsCapabilitiesBuilderTests: XCTestCase {
    func testProjectSelectionIncludesSkillWithoutExposeViaMcp() async throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext

        let project = Project(name: "Test Project")
        context.insert(project)
        try context.save()

        let root = try makeTempDirectory(prefix: "skills-library-selection")
        defer { try? FileManager.default.removeItem(at: root) }

        let skillDirectory = root.appendingPathComponent("selected-skill-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: selected-skill
        description: Selected skill.
        ---
        """.data(using: .utf8)).write(to: skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false))

        let library = SkillsLibraryService(root: root, fileManager: .default)
        try await library.reload()

        let record = SkillRecord(slug: "selected-skill",
                                 name: "selected-skill",
                                 descriptionText: "Selected skill.",
                                 exposeViaMcp: false,
                                 sourcePath: skillDirectory.path(percentEncoded: false),
                                 isArchive: false)
        context.insert(record)
        context.insert(ProjectSkillSelection(project: project, skillSlug: "selected-skill", enabled: true))
        try context.save()

        let caps = await SkillsCapabilitiesBuilder.capabilities(for: project, library: library, in: context)
        XCTAssertTrue(Set(caps.tools.map(\.name)).contains("selected-skill"))
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
