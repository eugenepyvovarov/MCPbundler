import XCTest
@testable import MCPBundler

final class ServerURLNormalizerTests: XCTestCase {
    func testStripsDefaultHttpsPort() {
        let normalized = ServerURLNormalizer.normalize(" https://mcp.atlassian.com:443/v1/sse ")
        XCTAssertEqual(normalized, "https://mcp.atlassian.com/v1/sse")
    }

    func testKeepsCustomPort() {
        let normalized = ServerURLNormalizer.normalize("http://localhost:8080/api")
        XCTAssertEqual(normalized, "http://localhost:8080/api")
    }

    func testNormalizesEmptyToNil() {
        XCTAssertNil(ServerURLNormalizer.normalizeOptional("   "))
        XCTAssertNil(ServerURLNormalizer.normalizeOptional(nil))
    }
}
