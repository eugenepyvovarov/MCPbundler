import XCTest
@testable import MCPBundler

final class InstallLinkServiceTests: XCTestCase {
    private let service = InstallLinkService()

    func testParsesStdIOServer() throws {
        let json = """
        {
          "postgres": {
            "kind": "stdio",
            "command": "/usr/bin/postgres",
            "args": ["--flag"],
            "cwd": "/tmp",
            "env": {
              "TOKEN": "abc"
            }
          }
        }
        """
        let request = InstallLinkRequest(kind: .server,
                                         name: "postgres",
                                         base64Config: base64URL(json))
        let result = try service.parse(request: request)
        XCTAssertEqual(result.candidates.count, 1)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertNil(candidate.error)
        XCTAssertEqual(candidate.alias, "postgres")
        XCTAssertEqual(candidate.summary.transportLabel, "STDIO")
        XCTAssertEqual(candidate.details.first?.label, "Command")
    }

    func testParsesHTTPServerWithParams() throws {
        let json = """
        {
          "support": {
            "kind": "http",
            "url": "https://api.example.com/mcp",
            "transport": "httpOnly",
            "params": {
              "workspace": "acme"
            },
            "headers": {
              "Authorization": "Bearer 123"
            }
          }
        }
        """
        let request = InstallLinkRequest(kind: .server,
                                         name: "support",
                                         base64Config: base64URL(json))
        let result = try service.parse(request: request)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertNil(candidate.error)
        XCTAssertEqual(candidate.summary.transportLabel, "HTTP/SSE")
        XCTAssertTrue(candidate.details.contains(where: { $0.label == "Query Params" }))
        XCTAssertEqual(candidate.headers.count, 1)
    }

    func testMissingCommandIsFlagged() throws {
        let json = """
        {
          "broken": {
            "kind": "stdio"
          }
        }
        """
        let request = InstallLinkRequest(kind: .server,
                                         name: "broken",
                                         base64Config: base64URL(json))
        let result = try service.parse(request: request)
        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertNotNil(candidate.error)
        XCTAssertFalse(candidate.isSelectable)
    }

    func testPayloadTooLargeThrows() {
        let data = Data(count: 200_000)
        let encoded = base64URL(data: data)
        let request = InstallLinkRequest(kind: .server,
                                         name: "large",
                                         base64Config: encoded)
        XCTAssertThrowsError(try service.parse(request: request)) { error in
            guard let serviceError = error as? InstallLinkServiceError else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertEqual(serviceError, .payloadTooLarge)
        }
    }

    private func base64URL(_ string: String) -> String {
        base64URL(data: Data(string.utf8))
    }

    private func base64URL(data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
