import XCTest
import WebRTC
@testable import MirroringCamera

final class WebRTCSignalingTests: XCTestCase {
    func testUnreachablePeerGetsNewICECredentialsWithoutResubscribing() async throws {
        let rtc = WebRTCManager.shared
        rtc.closeAll()
        defer { rtc.closeAll() }
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let receiver = try XCTUnwrap(factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer { receiver.close() }
        let restarted = expectation(description: "ICE restart offer")
        var firstCredentials: String?
        rtc.configureSignaling { payload in
            guard payload["type"] as? String == "rtc_offer", let sdp = payload["sdp"] as? String else { return }
            let credentials = sdp.components(separatedBy: "\r\n").first { $0.hasPrefix("a=ice-ufrag:") }
            if let firstCredentials {
                XCTAssertNotEqual(credentials, firstCredentials)
                restarted.fulfill()
                rtc.unsubscribe(sessionID: "unreachable")
                return
            }
            firstCredentials = credentials
            XCTAssertNotNil(credentials)
            receiver.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { error in
                XCTAssertNil(error)
                receiver.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                    XCTAssertNil(error)
                    guard let answer else { XCTFail("Missing answer"); return }
                    // Deliberately withhold all candidates: SDP succeeds but ICE cannot connect.
                    rtc.answer(sessionID: "unreachable", sdp: answer.sdp)
                }
            }
        }
        rtc.subscribe(controlID: "control", sessionID: "unreachable")
        await fulfillment(of: [restarted], timeout: 25)
    }

    func testMultipleViewersReceiveVideoOnlyH264Offers() async throws {
        let rtc = WebRTCManager.shared
        rtc.closeAll()
        defer { rtc.closeAll() }
        let offers = expectation(description: "Offers for two independent viewers")
        offers.expectedFulfillmentCount = 2
        rtc.configureSignaling { payload in
            guard payload["type"] as? String == "rtc_offer" else { return }
            let sdp = payload["sdp"] as? String ?? ""
            XCTAssertTrue(sdp.contains("m=video"))
            XCTAssertTrue(sdp.contains("a=sendonly"))
            XCTAssertTrue(sdp.contains("H264/90000"))
            XCTAssertFalse(sdp.contains("m=audio"))
            XCTAssertNotNil(payload["control_id"])
            XCTAssertNotNil(payload["session_id"])
            offers.fulfill()
        }
        rtc.subscribe(controlID: "control-a", sessionID: "session-a")
        rtc.subscribe(controlID: "control-a", sessionID: "session-a") // duplicate must not create another offer
        rtc.subscribe(controlID: "control-b", sessionID: "session-b")
        await fulfillment(of: [offers], timeout: 10)
        rtc.unsubscribe(sessionID: "session-a")
        rtc.controlGone(controlID: "control-b")
        XCTAssertFalse(rtc.isFallbackActive)
    }
}
