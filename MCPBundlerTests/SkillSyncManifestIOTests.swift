import XCTest
@testable import MCPBundler

final class SkillSyncManifestIOTests: XCTestCase {
    func testManifestRoundTrip() throws {
        let fileManager = FileManager.default
        let directory = try makeTempDirectory(prefix: "skill-manifest")
        defer { try? fileManager.removeItem(at: directory) }

        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let manifest = SkillSyncManifest(skillId: "test-skill-id",
                                         canonical: true,
                                         tool: SkillSyncManifest.canonicalTool,
                                         lastSyncAt: date,
                                         lastSyncedHash: "deadbeef")
        try SkillSyncManifestIO.save(manifest, to: directory, fileManager: fileManager)

        let loaded = try XCTUnwrap(SkillSyncManifestIO.load(from: directory, fileManager: fileManager))
        XCTAssertEqual(loaded.version, SkillSyncManifest.currentVersion)
        XCTAssertEqual(loaded.skillId, "test-skill-id")
        XCTAssertEqual(loaded.managedBy, SkillSyncManifest.managedByValue)
        XCTAssertEqual(loaded.canonical, true)
        XCTAssertEqual(loaded.tool, SkillSyncManifest.canonicalTool)
        XCTAssertEqual(loaded.lastSyncedHash, "deadbeef")
        XCTAssertEqual(loaded.lastSyncAt, date)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
