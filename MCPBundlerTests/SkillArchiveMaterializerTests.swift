import XCTest
@testable import MCPBundler

final class SkillArchiveMaterializerTests: XCTestCase {
    func testMaterializeArchiveCreatesDirectorySkillAndManifest() throws {
        let fileManager = FileManager.default
        let workspace = try makeTempDirectory(prefix: "skill-archive-materialize")
        defer { try? fileManager.removeItem(at: workspace) }

        let sourceRoot = workspace.appendingPathComponent("source", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let skillDir = sourceRoot.appendingPathComponent("test-skill", isDirectory: true)
        try fileManager.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---
        """.data(using: .utf8)).write(to: skillDir.appendingPathComponent("SKILL.md", isDirectory: false))
        try XCTUnwrap("ref".data(using: .utf8)).write(to: skillDir.appendingPathComponent("REFERENCE.md", isDirectory: false))

        let archiveURL = workspace.appendingPathComponent("test-skill.zip", isDirectory: false)
        try createZipArchive(at: archiveURL, from: skillDir, workingDirectory: sourceRoot)

        let skillId = UUID().uuidString
        let materialized = try SkillArchiveMaterializer.materializeArchive(at: archiveURL,
                                                                          to: destinationRoot,
                                                                          skillId: skillId,
                                                                          fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: materialized.appendingPathComponent("SKILL.md").path))

        let manifest = try XCTUnwrap(SkillSyncManifestIO.load(from: materialized, fileManager: fileManager))
        XCTAssertEqual(manifest.skillId, skillId)
        XCTAssertEqual(manifest.tool, SkillSyncManifest.canonicalTool)
        XCTAssertEqual(manifest.canonical, true)
    }

    private func createZipArchive(at archiveURL: URL, from directory: URL, workingDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workingDirectory
        process.arguments = ["-qr", archiveURL.path, directory.lastPathComponent]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        defer {
            stderr.fileHandleForReading.closeFile()
        }

        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            XCTFail("zip failed: \(message)")
        }
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
