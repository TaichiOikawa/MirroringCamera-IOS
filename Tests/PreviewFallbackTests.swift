import XCTest
@testable import MirroringCamera

final class PreviewFallbackTests: XCTestCase {
    func testNoViewersNeverSendsJPEG() {
        let state = PreviewFallbackState()
        XCTAssertFalse(state.isActive(now: 100))
    }

    func testWaitsSixSecondsBeforeFallback() {
        var state = PreviewFallbackState()
        state.subscribe("a", now: 10)
        XCTAssertFalse(state.isActive(now: 15.99))
        XCTAssertTrue(state.isActive(now: 16))
    }

    func testRecoveryStopsFallbackAndNewFailureGetsGrace() {
        var state = PreviewFallbackState()
        state.subscribe("a", now: 0)
        XCTAssertTrue(state.isActive(now: 6))
        state.setConnected(true, id: "a", now: 7)
        XCTAssertFalse(state.isActive(now: 100))
        XCTAssertTrue(state.hasLiveViewer)
        state.setConnected(false, id: "a", now: 100)
        XCTAssertFalse(state.isActive(now: 105))
        XCTAssertTrue(state.isActive(now: 106))
    }

    func testConnectedViewerDoesNotSuppressFallbackForOtherViewer() {
        var state = PreviewFallbackState()
        state.subscribe("a", now: 0)
        state.subscribe("b", now: 1)
        state.setConnected(true, id: "b", now: 2)
        XCTAssertTrue(state.isActive(now: 20))
        state.unsubscribe("b", now: 20)
        XCTAssertTrue(state.isActive(now: 25))
        XCTAssertTrue(state.isActive(now: 26))
        state.unsubscribe("a", now: 27)
        XCTAssertFalse(state.isActive(now: 40))
    }

    func testLateCallbacksCannotReviveRemovedSession() {
        var state = PreviewFallbackState()
        state.subscribe("old", now: 0)
        state.unsubscribe("old", now: 1)
        state.setConnected(true, id: "old", now: 2)
        XCTAssertFalse(state.hasLiveViewer)
        state.subscribe("new", now: 3)
        state.reset()
        state.setConnected(true, id: "new", now: 4)
        XCTAssertFalse(state.hasLiveViewer)
        XCTAssertFalse(state.isActive(now: 100))
    }
}
