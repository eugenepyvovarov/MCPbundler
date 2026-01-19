import XCTest
@testable import MCPBundler

final class NativeSkillsSyncEngineTests: XCTestCase {
    func testScanUnmanagedIncludesRootSkillFile() throws {
        let fileManager = FileManager.default
        let home = try makeTempDirectory(prefix: "native-sync-scan-root-file")
        defer { try? fileManager.removeItem(at: home) }

        let location = makeLocationDescriptor(id: "codex", in: home)
        let engine = NativeSkillsSyncEngine(fileManager: fileManager)

        try fileManager.createDirectory(at: location.rootURL, withIntermediateDirectories: true)
        let skillFile = location.rootURL.appendingPathComponent("SKILL.md", isDirectory: false)
        try XCTUnwrap("""
        ---
        name: root-skill
        description: Root-level skill file.
        ---
        """.data(using: .utf8)).write(to: skillFile, options: .atomic)

        let candidates = try engine.scanUnmanagedSkills(in: location)
        XCTAssertEqual(candidates.count, 1)
        guard let candidate = candidates.first else { return }
        XCTAssertEqual(candidate.locationId, location.locationId)
        XCTAssertEqual(candidate.skillFile.standardizedFileURL.path, skillFile.standardizedFileURL.path)
    }

    func testExportAndDisableMovesSkillToStash() throws {
        let fileManager = FileManager.default
        let home = try makeTempDirectory(prefix: "native-sync-home")
        defer { try? fileManager.removeItem(at: home) }

        let location = makeLocationDescriptor(id: "codex", in: home)
        let engine = NativeSkillsSyncEngine(fileManager: fileManager)

        let canonical = home.appendingPathComponent("canonical-skill", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---
        """.data(using: .utf8)).write(to: canonical.appendingPathComponent("SKILL.md", isDirectory: false))

        let skillId = UUID().uuidString
        try engine.ensureCanonicalManifest(skillId: skillId, canonicalDirectory: canonical)
        try engine.exportSkillDirectory(from: canonical,
                                        preferredSlug: "test-skill",
                                        skillId: skillId,
                                        to: location)

        let exported = location.rootURL.appendingPathComponent("test-skill", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: exported.appendingPathComponent("SKILL.md").path))
        let manifest = try XCTUnwrap(SkillSyncManifestIO.load(from: exported, fileManager: fileManager))
        XCTAssertEqual(manifest.skillId, skillId)
        XCTAssertEqual(manifest.tool, location.locationId)
        XCTAssertEqual(manifest.canonical, false)

        try engine.disableSkillExport(skillId: skillId, preferredSlug: "test-skill", in: location)
        XCTAssertFalse(fileManager.fileExists(atPath: exported.path))
        let disabledEntries = (try? fileManager.contentsOfDirectory(at: location.disabledRootURL,
                                                                    includingPropertiesForKeys: nil,
                                                                    options: [])) ?? []
        XCTAssertTrue(disabledEntries.contains(where: { $0.lastPathComponent.hasPrefix("test-skill") }))
    }

    func testExportRemovesDisabledCopyWhenReenabled() throws {
        let fileManager = FileManager.default
        let home = try makeTempDirectory(prefix: "native-sync-reenable")
        defer { try? fileManager.removeItem(at: home) }

        let location = makeLocationDescriptor(id: "codex", in: home)
        let engine = NativeSkillsSyncEngine(fileManager: fileManager)

        let canonical = home.appendingPathComponent("canonical-skill", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---
        """.data(using: .utf8)).write(to: canonical.appendingPathComponent("SKILL.md", isDirectory: false))

        let skillId = UUID().uuidString
        try engine.ensureCanonicalManifest(skillId: skillId, canonicalDirectory: canonical)
        try engine.exportSkillDirectory(from: canonical,
                                        preferredSlug: "test-skill",
                                        skillId: skillId,
                                        to: location)
        try engine.disableSkillExport(skillId: skillId, preferredSlug: "test-skill", in: location)

        let disabledEntriesBefore = (try? fileManager.contentsOfDirectory(at: location.disabledRootURL,
                                                                          includingPropertiesForKeys: nil,
                                                                          options: [])) ?? []
        XCTAssertTrue(disabledEntriesBefore.contains(where: { $0.lastPathComponent.hasPrefix("test-skill") }))

        try engine.exportSkillDirectory(from: canonical,
                                        preferredSlug: "test-skill",
                                        skillId: skillId,
                                        to: location)

        let disabledEntriesAfter = (try? fileManager.contentsOfDirectory(at: location.disabledRootURL,
                                                                         includingPropertiesForKeys: nil,
                                                                         options: [])) ?? []
        XCTAssertFalse(disabledEntriesAfter.contains(where: { $0.lastPathComponent.hasPrefix("test-skill") }))
    }

    func testSyncPropagatesSingleWriterChange() throws {
        let fileManager = FileManager.default
        let home = try makeTempDirectory(prefix: "native-sync-propagate")
        defer { try? fileManager.removeItem(at: home) }

        let location = makeLocationDescriptor(id: "codex", in: home)
        let engine = NativeSkillsSyncEngine(fileManager: fileManager)

        let canonical = home.appendingPathComponent("canonical-skill", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---

        v1
        """.data(using: .utf8)).write(to: canonical.appendingPathComponent("SKILL.md", isDirectory: false))

        let skillId = UUID().uuidString
        XCTAssertEqual(try engine.syncSkill(skillId: skillId,
                                            preferredSlug: "test-skill",
                                            canonicalDirectory: canonical,
                                            enabledLocationIds: [location.locationId],
                                            locations: [location],
                                            forceSource: nil),
                       .exportsCreated([location.locationId]))

        let codexExport = location.rootURL.appendingPathComponent("test-skill", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: codexExport.path))
        let skillFile = codexExport.appendingPathComponent("SKILL.md", isDirectory: false)
        let updatedContents = """
        ---
        name: test-skill
        description: A test skill.
        ---

        v2
        """
        try XCTUnwrap(updatedContents.data(using: .utf8)).write(to: skillFile, options: .atomic)

        let outcome = try engine.syncSkill(skillId: skillId,
                                           preferredSlug: "test-skill",
                                           canonicalDirectory: canonical,
                                           enabledLocationIds: [location.locationId],
                                           locations: [location],
                                           forceSource: nil)
        XCTAssertEqual(outcome, .propagated(source: location.locationId))

        let canonicalData = try Data(contentsOf: canonical.appendingPathComponent("SKILL.md", isDirectory: false))
        let canonicalText = String(data: canonicalData, encoding: .utf8)
        XCTAssertTrue(canonicalText?.contains("v2") == true)
    }

    func testSyncDetectsConflictWhenMultipleLocationsChange() throws {
        let fileManager = FileManager.default
        let home = try makeTempDirectory(prefix: "native-sync-conflict")
        defer { try? fileManager.removeItem(at: home) }

        let location = makeLocationDescriptor(id: "codex", in: home)
        let engine = NativeSkillsSyncEngine(fileManager: fileManager)

        let canonical = home.appendingPathComponent("canonical-skill", isDirectory: true)
        try fileManager.createDirectory(at: canonical, withIntermediateDirectories: true)
        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---

        baseline
        """.data(using: .utf8)).write(to: canonical.appendingPathComponent("SKILL.md", isDirectory: false))

        let skillId = UUID().uuidString
        _ = try engine.syncSkill(skillId: skillId,
                                 preferredSlug: "test-skill",
                                 canonicalDirectory: canonical,
                                 enabledLocationIds: [location.locationId],
                                 locations: [location],
                                 forceSource: nil)

        let codexExport = location.rootURL.appendingPathComponent("test-skill", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: codexExport.path))

        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---

        canonical change
        """.data(using: .utf8)).write(to: canonical.appendingPathComponent("SKILL.md", isDirectory: false), options: .atomic)

        try XCTUnwrap("""
        ---
        name: test-skill
        description: A test skill.
        ---

        codex change
        """.data(using: .utf8)).write(to: codexExport.appendingPathComponent("SKILL.md", isDirectory: false), options: .atomic)

        let outcome = try engine.syncSkill(skillId: skillId,
                                           preferredSlug: "test-skill",
                                           canonicalDirectory: canonical,
                                           enabledLocationIds: [location.locationId],
                                           locations: [location],
                                           forceSource: nil)
        guard case .conflict = outcome else {
            XCTFail("Expected conflict, got \(outcome)")
            return
        }
    }

    private func makeLocationDescriptor(id: String, in base: URL) -> SkillSyncLocationDescriptor {
        let root = base.appendingPathComponent("\(id)-skills", isDirectory: true)
        let disabled = base.appendingPathComponent("\(id)-skills.disabled", isDirectory: true)
        return SkillSyncLocationDescriptor(locationId: id,
                                            displayName: id.capitalized,
                                            rootPath: root.path,
                                            disabledRootPath: disabled.path)
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let fileManager = FileManager.default
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
