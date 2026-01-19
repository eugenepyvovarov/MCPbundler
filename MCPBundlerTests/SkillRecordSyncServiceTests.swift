import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class SkillRecordSyncServiceTests: XCTestCase {
    func testSynchronizeRecordsUpdatesSelectionsOnSlugRename() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SkillRecordSyncService(fileManager: .default)

        let project = Project(name: "Test Project")
        context.insert(project)
        try context.save()

        let skillDirectory = try makeTempDirectory(prefix: "record-sync-skill")
        defer { try? FileManager.default.removeItem(at: skillDirectory) }

        let skillId = UUID().uuidString
        let manifest = SkillSyncManifest(skillId: skillId,
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: "baseline")
        try SkillSyncManifestIO.save(manifest, to: skillDirectory, fileManager: .default)

        let oldInfo = SkillInfo(slug: "old-slug",
                                name: "Old",
                                description: "Old desc",
                                license: nil,
                                allowedTools: [],
                                extra: [:],
                                resources: [],
                                source: skillDirectory,
                                isArchive: false)

        _ = try service.synchronizeRecords(with: [oldInfo], in: context)
        context.insert(ProjectSkillSelection(project: project, skillSlug: "old-slug", enabled: true))
        try context.save()

        let newInfo = SkillInfo(slug: "new-slug",
                                name: "New",
                                description: "New desc",
                                license: nil,
                                allowedTools: [],
                                extra: [:],
                                resources: [],
                                source: skillDirectory,
                                isArchive: false)

        let impacted = try service.synchronizeRecords(with: [newInfo], in: context)
        XCTAssertEqual(impacted.map(\.name), ["Test Project"])

        let selectionDescriptor = FetchDescriptor<ProjectSkillSelection>(predicate: #Predicate { $0.enabled })
        let selections = try context.fetch(selectionDescriptor)
        XCTAssertEqual(selections.count, 1)
        XCTAssertEqual(selections.first?.skillSlug, "new-slug")
    }

    func testSynchronizeRecordsPreservesFolderMembershipAcrossSlugRename() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SkillRecordSyncService(fileManager: .default)

        let folder = SkillFolder(name: "Utilities")
        context.insert(folder)

        let skillDirectory = try makeTempDirectory(prefix: "record-sync-folder")
        defer { try? FileManager.default.removeItem(at: skillDirectory) }

        let skillId = UUID().uuidString
        let manifest = SkillSyncManifest(skillId: skillId,
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: "baseline")
        try SkillSyncManifestIO.save(manifest, to: skillDirectory, fileManager: .default)

        let oldInfo = SkillInfo(slug: "old-slug",
                                name: "Old",
                                description: "Old desc",
                                license: nil,
                                allowedTools: [],
                                extra: [:],
                                resources: [],
                                source: skillDirectory,
                                isArchive: false)

        _ = try service.synchronizeRecords(with: [oldInfo], in: context)

        let initialDescriptor = FetchDescriptor<SkillRecord>()
        let initial = try context.fetch(initialDescriptor)
        XCTAssertEqual(initial.count, 1)

        initial.first?.folder = folder
        try context.save()

        let newInfo = SkillInfo(slug: "new-slug",
                                name: "New",
                                description: "New desc",
                                license: nil,
                                allowedTools: [],
                                extra: [:],
                                resources: [],
                                source: skillDirectory,
                                isArchive: false)

        _ = try service.synchronizeRecords(with: [newInfo], in: context)

        let descriptor = FetchDescriptor<SkillRecord>()
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.skillId, skillId)
        XCTAssertEqual(records.first?.slug, "new-slug")
        XCTAssertEqual(records.first?.folder?.name, "Utilities")
    }

    func testSynchronizeRecordsRepairsDuplicateSkillIdsAndStaleArchivePaths() throws {
        let container = try TestModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SkillRecordSyncService(fileManager: .default)

        let firstDirectory = try makeTempDirectory(prefix: "record-sync-dup-a")
        let secondDirectory = try makeTempDirectory(prefix: "record-sync-dup-b")
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let duplicateSkillId = UUID().uuidString
        let manifest = SkillSyncManifest(skillId: duplicateSkillId,
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: Date(),
                                         lastSyncedHash: "baseline")
        try SkillSyncManifestIO.save(manifest, to: firstDirectory, fileManager: .default)
        try SkillSyncManifestIO.save(manifest, to: secondDirectory, fileManager: .default)

        // Simulate a pre-existing canonical record (directory-backed) and a stale archive record that still points to
        // an archive path even though the skill is now materialized as a directory.
        let firstRecord = SkillRecord(skillId: duplicateSkillId,
                                      slug: "skill-a",
                                      name: "Skill A",
                                      descriptionText: "Desc A",
                                      exposeViaMcp: false,
                                      sourcePath: firstDirectory.path(percentEncoded: false),
                                      isArchive: false)
        let secondRecord = SkillRecord(skillId: duplicateSkillId,
                                       slug: "skill-b",
                                       name: "Skill B",
                                       descriptionText: "Desc B",
                                       exposeViaMcp: false,
                                       sourcePath: secondDirectory.appendingPathExtension("zip").path(percentEncoded: false),
                                       isArchive: true)
        context.insert(firstRecord)
        context.insert(secondRecord)
        try context.save()

        let infos = [
            SkillInfo(slug: "skill-a",
                      name: "Skill A",
                      description: "Desc A",
                      license: nil,
                      allowedTools: [],
                      extra: [:],
                      resources: [],
                      source: firstDirectory,
                      isArchive: false),
            SkillInfo(slug: "skill-b",
                      name: "Skill B",
                      description: "Desc B",
                      license: nil,
                      allowedTools: [],
                      extra: [:],
                      resources: [],
                      source: secondDirectory,
                      isArchive: false)
        ]

        _ = try service.synchronizeRecords(with: infos, in: context)

        let descriptor = FetchDescriptor<SkillRecord>(sortBy: [SortDescriptor(\SkillRecord.slug, order: .forward)])
        let records = try context.fetch(descriptor)
        XCTAssertEqual(records.count, 2)

        guard let updatedFirst = records.first(where: { $0.slug == "skill-a" }),
              let updatedSecond = records.first(where: { $0.slug == "skill-b" }) else {
            XCTFail("Expected records not found after sync")
            return
        }

        XCTAssertEqual(updatedFirst.skillId, duplicateSkillId)
        XCTAssertNotEqual(updatedSecond.skillId, duplicateSkillId)
        XCTAssertNotEqual(updatedFirst.skillId, updatedSecond.skillId)

        XCTAssertEqual(URL(fileURLWithPath: updatedFirst.sourcePath).standardizedFileURL.path,
                       firstDirectory.standardizedFileURL.path)
        XCTAssertEqual(URL(fileURLWithPath: updatedSecond.sourcePath).standardizedFileURL.path,
                       secondDirectory.standardizedFileURL.path)
        XCTAssertFalse(updatedSecond.isArchive)

        let secondManifest = try SkillSyncManifestIO.load(from: secondDirectory, fileManager: .default)
        XCTAssertEqual(secondManifest?.managedBy, SkillSyncManifest.managedByValue)
        XCTAssertEqual(secondManifest?.canonical, true)
        XCTAssertEqual(secondManifest?.tool, SkillSyncManifest.canonicalTool)
        XCTAssertEqual(secondManifest?.skillId, updatedSecond.skillId)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
