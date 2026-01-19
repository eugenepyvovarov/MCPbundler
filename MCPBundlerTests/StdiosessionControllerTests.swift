import XCTest
import SwiftData
@testable import MCPBundler

@MainActor
final class StdiosessionControllerTests: XCTestCase {
    func testStartAndStopPreviewSession() async throws {
        let runner = MockRunner()
        let controller = StdiosessionController(previewRunnerFactory: { runner })

        XCTAssertFalse(controller.isRunning)

        try await controller.startPreviewSession()

        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(runner.beginCalls, 1)

        await controller.stopPreviewSession()

        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(runner.stopCalls, 1)
    }

    func testSecondStartRaisesError() async throws {
        let runner = MockRunner()
        let controller = StdiosessionController(previewRunnerFactory: { runner })

        try await controller.startPreviewSession()

        await XCTAssertThrowsErrorAsync(try await controller.startPreviewSession()) { error in
            guard case StdiosessionController.ControllerError.sessionAlreadyActive = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testReloadNoopWhenInactive() async {
        let runner = MockRunner()
        let controller = StdiosessionController(previewRunnerFactory: { runner })

        await controller.reload()
        XCTAssertTrue(runner.reloadCalls.isEmpty)
    }

    func testReloadForwardsWhenActive() async throws {
        let runner = MockRunner()
        let controller = StdiosessionController(previewRunnerFactory: { runner })

        try await controller.startPreviewSession()
        await controller.reload(projectID: nil, serverIDs: nil)

        XCTAssertEqual(runner.reloadCalls.count, 1)
        let call = runner.reloadCalls[0]
        XCTAssertNil(call.projectID)
        XCTAssertNil(call.serverIDs)
    }
}

// MARK: - Helpers

@MainActor
private final class MockRunner: StdiosessionRunning {
    var beginCalls = 0
    var stopCalls = 0
    var reloadCalls: [(projectID: PersistentIdentifier?, serverIDs: Set<PersistentIdentifier>?)] = []

    func begin() async throws -> StdiosessionStartResult {
        beginCalls += 1
        return StdiosessionStartResult(transport: nil, helperHandle: nil)
    }

    func waitForTermination() async throws {}

    func stop() async {
        stopCalls += 1
    }

    func reload(projectID: PersistentIdentifier?, serverIDs: Set<PersistentIdentifier>?) async {
        reloadCalls.append((projectID, serverIDs))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ errorHandler: (Error) -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
