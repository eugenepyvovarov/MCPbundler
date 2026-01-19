import Foundation
import XCTest
@testable import MCPBundler

final class SkillMarketplaceServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MarketplaceMockURLProtocol.handlers = [:]
    }

    func testParseGitHubRepositoryAcceptsValidURLs() throws {
        let repo = try SkillMarketplaceService.parseGitHubRepository(from: "https://github.com/acme/skills")
        XCTAssertEqual(repo.owner, "acme")
        XCTAssertEqual(repo.repo, "skills")

        let withSuffix = try SkillMarketplaceService.parseGitHubRepository(from: "https://github.com/acme/skills.git/")
        XCTAssertEqual(withSuffix.owner, "acme")
        XCTAssertEqual(withSuffix.repo, "skills")
    }

    func testParseGitHubRepositoryRejectsInvalidURLs() {
        XCTAssertThrowsError(try SkillMarketplaceService.parseGitHubRepository(from: "http://github.com/acme/skills"))
        XCTAssertThrowsError(try SkillMarketplaceService.parseGitHubRepository(from: "https://gitlab.com/acme/skills"))
        XCTAssertThrowsError(try SkillMarketplaceService.parseGitHubRepository(from: "https://github.com/acme"))
        XCTAssertThrowsError(try SkillMarketplaceService.parseGitHubRepository(from: "https://github.com/acme/skills/tree/main"))
    }

    func testMarketplaceJSONDecoding() throws {
        let json = """
        {
          "name": "Demo Market",
          "owner": {"name": "Acme", "email": "dev@acme.test"},
          "metadata": {"description": "Sample", "version": "1.0.0"},
          "plugins": [
            {"name": "demo-skill", "description": "Demo", "source": "./demo-skill", "category": "General"}
          ]
        }
        """
        let document = try JSONDecoder().decode(SkillMarketplaceDocument.self, from: Data(json.utf8))
        XCTAssertEqual(document.name, "Demo Market")
        XCTAssertEqual(document.plugins.count, 1)
        XCTAssertEqual(document.plugins.first?.name, "demo-skill")
    }

    func testMarketplaceJSONDecodingMissingRequiredFields() {
        let json = """
        {
          "name": "Demo Market",
          "metadata": {"version": "1.0.0"}
        }
        """
        XCTAssertThrowsError(try JSONDecoder().decode(SkillMarketplaceDocument.self, from: Data(json.utf8)))
    }

    func testRewriteSkillNameHandlesScalarAndBlock() throws {
        let scalar = """
        ---
        name: Demo Skill
        description: Example
        ---
        Body
        """
        let updatedScalar = try SkillFrontMatterRewriter.rewriteName(in: scalar,
                                                                     sourcePath: "SKILL.md",
                                                                     newName: "Demo Skill Copy")
        XCTAssertTrue(updatedScalar.contains("name: Demo Skill Copy"))

        let block = """
        ---
        name: |
          Demo Skill
        description: Example
        ---
        Body
        """
        let updatedBlock = try SkillFrontMatterRewriter.rewriteName(in: block,
                                                                    sourcePath: "SKILL.md",
                                                                    newName: "Demo Skill Copy")
        XCTAssertTrue(updatedBlock.contains("name: Demo Skill Copy"))
        XCTAssertFalse(updatedBlock.contains("name: |"))
    }

    func testInstallPluginDownloadsFolder() async throws {
        let session = makeSession()
        let service = SkillMarketplaceService(session: session)

        let repoURL = URL(string: "https://api.github.com/repos/acme/skills")!
        let marketplaceURL = URL(string: "https://api.github.com/repos/acme/skills/contents/.claude-plugin/marketplace.json?ref=main")!
        let pluginURL = URL(string: "https://api.github.com/repos/acme/skills/contents/plugins/demo-skill?ref=main")!
        let assetsURL = URL(string: "https://api.github.com/repos/acme/skills/contents/plugins/demo-skill/assets?ref=main")!
        let skillRawURL = URL(string: "https://raw.githubusercontent.com/acme/skills/main/plugins/demo-skill/SKILL.md")!
        let readmeRawURL = URL(string: "https://raw.githubusercontent.com/acme/skills/main/plugins/demo-skill/assets/readme.txt")!

        let marketplaceJSON = """
        {
          "name": "Demo Market",
          "owner": {"name": "Acme", "email": "dev@acme.test"},
          "metadata": {"description": "Sample", "version": "1.0.0"},
          "plugins": [
            {"name": "demo-skill", "description": "Demo", "source": "./plugins/demo-skill", "category": "General"}
          ]
        }
        """
        let marketplaceBase64 = Data(marketplaceJSON.utf8).base64EncodedString()

        let marketplaceEntry: [String: Any] = [
            "name": "marketplace.json",
            "path": ".claude-plugin/marketplace.json",
            "type": "file",
            "download_url": NSNull(),
            "url": marketplaceURL.absoluteString,
            "encoding": "base64",
            "content": marketplaceBase64
        ]

        let pluginEntries: [[String: Any]] = [
            [
                "name": "SKILL.md",
                "path": "plugins/demo-skill/SKILL.md",
                "type": "file",
                "download_url": skillRawURL.absoluteString,
                "url": pluginURL.absoluteString
            ],
            [
                "name": "assets",
                "path": "plugins/demo-skill/assets",
                "type": "dir",
                "download_url": NSNull(),
                "url": assetsURL.absoluteString
            ],
            [
                "name": ".mcp-bundler",
                "path": "plugins/demo-skill/.mcp-bundler",
                "type": "dir",
                "download_url": NSNull(),
                "url": "https://api.github.com/repos/acme/skills/contents/plugins/demo-skill/.mcp-bundler?ref=main"
            ]
        ]

        let assetsEntries: [[String: Any]] = [
            [
                "name": "readme.txt",
                "path": "plugins/demo-skill/assets/readme.txt",
                "type": "file",
                "download_url": readmeRawURL.absoluteString,
                "url": assetsURL.absoluteString
            ]
        ]

        MarketplaceMockURLProtocol.handlers[repoURL] = { _ in
            let payload = ["default_branch": "main"]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [])
            return (status: 200, headers: [:], data: data)
        }

        MarketplaceMockURLProtocol.handlers[marketplaceURL] = { _ in
            let data = try JSONSerialization.data(withJSONObject: marketplaceEntry, options: [])
            return (status: 200, headers: [:], data: data)
        }

        MarketplaceMockURLProtocol.handlers[pluginURL] = { _ in
            let data = try JSONSerialization.data(withJSONObject: pluginEntries, options: [])
            return (status: 200, headers: [:], data: data)
        }

        MarketplaceMockURLProtocol.handlers[assetsURL] = { _ in
            let data = try JSONSerialization.data(withJSONObject: assetsEntries, options: [])
            return (status: 200, headers: [:], data: data)
        }

        MarketplaceMockURLProtocol.handlers[skillRawURL] = { _ in
            let contents = """
            ---
            name: Demo Skill
            description: Demo description
            ---
            Body
            """
            return (status: 200, headers: [:], data: Data(contents.utf8))
        }

        MarketplaceMockURLProtocol.handlers[readmeRawURL] = { _ in
            return (status: 200, headers: [:], data: Data("Readme".utf8))
        }

        let listing = try await service.fetchMarketplace(owner: "acme", repo: "skills")
        let plugin = try XCTUnwrap(listing.document.plugins.first)

        let libraryRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let result = try await service.installPlugin(plugin,
                                                     from: listing,
                                                     existingSlugs: [],
                                                     libraryRoot: libraryRoot)

        XCTAssertEqual(result.slug, "demo-skill")

        let skillFile = libraryRoot
            .appendingPathComponent(result.slug, isDirectory: true)
            .appendingPathComponent("SKILL.md", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))

        let contents = try String(contentsOf: skillFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("name: Demo Skill"))

        let readmeFile = libraryRoot
            .appendingPathComponent(result.slug, isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("readme.txt", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: readmeFile.path))

        let forbidden = libraryRoot
            .appendingPathComponent(result.slug, isDirectory: true)
            .appendingPathComponent(".mcp-bundler", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: forbidden.path))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MarketplaceMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MarketplaceMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (status: Int, headers: [String: String], data: Data?)

    static var handlers: [URL: Handler] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return handlers.keys.contains(url)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        guard let handler = MarketplaceMockURLProtocol.handlers[url] else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        do {
            let result = try handler(request)
            let response = HTTPURLResponse(url: url,
                                           statusCode: result.status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = result.data {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MarketplaceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
