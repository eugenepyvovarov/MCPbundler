import XCTest
@testable import MCPBundler

final class NativeSkillsVisibilityFilterTests: XCTestCase {
    func testFilterToolsHidesOnlyMatchingSkills() {
        let tools = [
            NamespacedTool(namespaced: "mcpbundler_skills__a",
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: "a",
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil),
            NamespacedTool(namespaced: SkillsCapabilitiesBuilder.compatibilityToolName,
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: SkillsCapabilitiesBuilder.compatibilityToolName,
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil),
            NamespacedTool(namespaced: "mcpbundler_skills__b",
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: "b",
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil),
            NamespacedTool(namespaced: "other__search",
                           alias: "other",
                           original: "search",
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil)
        ]

        let filtered = NativeSkillsVisibilityFilter.filterTools(tools, hiddenSkillSlugs: ["a"])
        XCTAssertFalse(filtered.contains(where: { $0.alias == SkillsCapabilitiesBuilder.alias && $0.original == "a" }))
        XCTAssertTrue(filtered.contains(where: { $0.alias == SkillsCapabilitiesBuilder.alias && $0.original == "b" }))
        XCTAssertTrue(filtered.contains(where: { $0.original == SkillsCapabilitiesBuilder.compatibilityToolName }))
        XCTAssertTrue(filtered.contains(where: { $0.alias == "other" }))
    }

    func testFilterToolsRemovesCompatibilityToolWhenNoSkillToolsRemain() {
        let tools = [
            NamespacedTool(namespaced: SkillsCapabilitiesBuilder.compatibilityToolName,
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: SkillsCapabilitiesBuilder.compatibilityToolName,
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil),
            NamespacedTool(namespaced: "mcpbundler_skills__a",
                           alias: SkillsCapabilitiesBuilder.alias,
                           original: "a",
                           title: nil,
                           description: nil,
                           inputSchema: nil,
                           annotations: nil)
        ]

        let filtered = NativeSkillsVisibilityFilter.filterTools(tools, hiddenSkillSlugs: ["a"])
        XCTAssertTrue(filtered.isEmpty)
    }

    func testFilterResourcesHidesOnlyMatchingSkillURIs() {
        let resources = [
            NamespacedResource(name: "mcpbundler_skills__a/REFERENCE.md",
                               uri: "mcp-bundler://mcpbundler_skills/a",
                               alias: SkillsCapabilitiesBuilder.alias,
                               originalURI: "mcpbundler-skill://a/REFERENCE.md",
                               description: nil),
            NamespacedResource(name: "mcpbundler_skills__b/REFERENCE.md",
                               uri: "mcp-bundler://mcpbundler_skills/b",
                               alias: SkillsCapabilitiesBuilder.alias,
                               originalURI: "mcpbundler-skill://b/REFERENCE.md",
                               description: nil),
            NamespacedResource(name: "other__file",
                               uri: "mcp-bundler://other/file",
                               alias: "other",
                               originalURI: "file://example",
                               description: nil)
        ]

        let filtered = NativeSkillsVisibilityFilter.filterResources(resources, hiddenSkillSlugs: ["a"])
        XCTAssertFalse(filtered.contains(where: { $0.alias == SkillsCapabilitiesBuilder.alias && $0.originalURI.contains("://a/") }))
        XCTAssertTrue(filtered.contains(where: { $0.alias == SkillsCapabilitiesBuilder.alias && $0.originalURI.contains("://b/") }))
        XCTAssertTrue(filtered.contains(where: { $0.alias == "other" }))
    }

    func testShouldHideHelpers() {
        XCTAssertTrue(NativeSkillsVisibilityFilter.shouldHideSkillsTool(originalToolName: "a", hiddenSkillSlugs: ["a"]))
        XCTAssertFalse(NativeSkillsVisibilityFilter.shouldHideSkillsTool(originalToolName: SkillsCapabilitiesBuilder.compatibilityToolName,
                                                                        hiddenSkillSlugs: ["a"]))
        XCTAssertTrue(NativeSkillsVisibilityFilter.shouldHideSkillsResource(originalURI: "mcpbundler-skill://a/file.txt",
                                                                           hiddenSkillSlugs: ["a"]))
        XCTAssertFalse(NativeSkillsVisibilityFilter.shouldHideSkillsResource(originalURI: "mcpbundler-skill://b/file.txt",
                                                                            hiddenSkillSlugs: ["a"]))
    }
}

