@testable import MCPBundler
import XCTest

final class StreamingFallbackDecisionTests: XCTestCase {
    func testForcedStreamingOverridesOtherSignals() {
        let decision = StreamingFallbackDecision.decide(usingStreaming: false,
                                                        forceStreaming: true)
        XCTAssertEqual(decision.action, .reuseStreaming)
        XCTAssertEqual(decision.reason, .forced)
    }

    func testActiveStreamingKeepsUsingSSE() {
        let decision = StreamingFallbackDecision.decide(usingStreaming: true,
                                                        forceStreaming: false)
        XCTAssertEqual(decision.action, .reuseStreaming)
        XCTAssertEqual(decision.reason, .alreadyStreaming)
    }

    func testDefaultPrefersHttpFirst() {
        let decision = StreamingFallbackDecision.decide(usingStreaming: false,
                                                        forceStreaming: false)
        XCTAssertEqual(decision.action, .httpFirst)
        XCTAssertEqual(decision.reason, .httpFirst)
    }
}
