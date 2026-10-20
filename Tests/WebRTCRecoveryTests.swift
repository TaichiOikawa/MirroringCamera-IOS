import XCTest
@testable import MirroringCamera

final class WebRTCRecoveryTests: XCTestCase {
    func testTransientDisconnectionDoesNotRestart() {
        var state = WebRTCRecoveryState()
        state.awaitConnection(now: 0)
        XCTAssertFalse(state.shouldRestart(now: 9, signalingStable: true))
        state.connected()
        XCTAssertFalse(state.shouldRestart(now: 20, signalingStable: true))
    }

    func testRepeatedDisconnectCallbacksDoNotPostponeRecovery() {
        var state = WebRTCRecoveryState()
        state.awaitConnection(now: 0)
        state.awaitConnection(now: 8)
        XCTAssertTrue(state.shouldRestart(now: 10, signalingStable: true))
        XCTAssertFalse(state.shouldRestart(now: 11, signalingStable: true))
        XCTAssertTrue(state.shouldRestart(now: 20, signalingStable: true))
    }

    func testOutstandingOfferCannotBeOverwritten() {
        var state = WebRTCRecoveryState()
        state.awaitConnection(now: 0)
        XCTAssertFalse(state.shouldRestart(now: 15, signalingStable: false))
        XCTAssertTrue(state.shouldRestart(now: 16, signalingStable: true))
        state.connected()
        XCTAssertFalse(state.shouldRestart(now: 100, signalingStable: true))
        state.awaitConnection(now: 100)
        XCTAssertFalse(state.shouldRestart(now: 109, signalingStable: true))
        XCTAssertTrue(state.shouldRestart(now: 110, signalingStable: true))
    }
}
