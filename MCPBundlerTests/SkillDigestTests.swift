import XCTest
@testable import MCPBundler

final class SkillDigestTests: XCTestCase {
    func testDigestIgnoresManagedAndOSArtifacts() throws {
        let fileManager = FileManager.default
        let root = try makeTempDirectory(prefix: "skill-digest")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root.appendingPathComponent(".mcp-bundler", isDirectory: true),
                                        withIntermediateDirectories: true)
        try XCTUnwrap("hello".data(using: .utf8))
            .write(to: root.appendingPathComponent("SKILL.md", isDirectory: false))
        try XCTUnwrap("resource".data(using: .utf8))
            .write(to: root.appendingPathComponent("REFERENCE.md", isDirectory: false))
        try XCTUnwrap("manifest-v1".data(using: .utf8))
            .write(to: root.appendingPathComponent(".mcp-bundler/manifest.json"))
        try XCTUnwrap("ds-store".data(using: .utf8))
            .write(to: root.appendingPathComponent(".DS_Store", isDirectory: false))
        let macosx = root.appendingPathComponent("__MACOSX", isDirectory: true)
        try fileManager.createDirectory(at: macosx, withIntermediateDirectories: true)
        try XCTUnwrap("junk".data(using: .utf8))
            .write(to: macosx.appendingPathComponent("junk.txt", isDirectory: false))

        let digest1 = try SkillDigest.sha256Hex(forSkillDirectory: root, fileManager: fileManager)

        try XCTUnwrap("manifest-v2".data(using: .utf8))
            .write(to: root.appendingPathComponent(".mcp-bundler/manifest.json"), options: .atomic)
        try XCTUnwrap("ds-store-v2".data(using: .utf8))
            .write(to: root.appendingPathComponent(".DS_Store", isDirectory: false), options: .atomic)
        try XCTUnwrap("junk-v2".data(using: .utf8))
            .write(to: macosx.appendingPathComponent("junk.txt", isDirectory: false), options: .atomic)

        let digest2 = try SkillDigest.sha256Hex(forSkillDirectory: root, fileManager: fileManager)
        XCTAssertEqual(digest1, digest2)

        try XCTUnwrap("resource-v2".data(using: .utf8))
            .write(to: root.appendingPathComponent("REFERENCE.md", isDirectory: false), options: .atomic)
        let digest3 = try SkillDigest.sha256Hex(forSkillDirectory: root, fileManager: fileManager)
        XCTAssertNotEqual(digest1, digest3)
    }

    func testDigestFailsOnSymlinksByDefault() throws {
        let fileManager = FileManager.default
        let root = try makeTempDirectory(prefix: "skill-digest-symlink")
        defer { try? fileManager.removeItem(at: root) }

        try XCTUnwrap("hello".data(using: .utf8))
            .write(to: root.appendingPathComponent("SKILL.md", isDirectory: false))
        try XCTUnwrap("target".data(using: .utf8))
            .write(to: root.appendingPathComponent("target.txt", isDirectory: false))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("link.txt", isDirectory: false),
                                           withDestinationURL: root.appendingPathComponent("target.txt", isDirectory: false))

        XCTAssertThrowsError(try SkillDigest.sha256Hex(forSkillDirectory: root, fileManager: fileManager)) { error in
            guard case SkillDigestError.containsSymlink = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testFileDigestChangesWhenContentsChange() throws {
        let fileManager = FileManager.default
        let root = try makeTempDirectory(prefix: "skill-file-digest")
        defer { try? fileManager.removeItem(at: root) }

        let file = root.appendingPathComponent("SKILL.md", isDirectory: false)
        try XCTUnwrap("v1".data(using: .utf8)).write(to: file, options: .atomic)
        let digest1 = try SkillDigest.sha256Hex(forFile: file, fileManager: fileManager)

        try XCTUnwrap("v2".data(using: .utf8)).write(to: file, options: .atomic)
        let digest2 = try SkillDigest.sha256Hex(forFile: file, fileManager: fileManager)

        XCTAssertNotEqual(digest1, digest2)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
