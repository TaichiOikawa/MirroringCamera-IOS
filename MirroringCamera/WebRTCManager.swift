import AVFoundation
import Foundation
import WebRTC

/// Camera-side offerer. Session work and peer teardown run off WebRTC's callback threads.
final class WebRTCManager: NSObject {
    static let shared = WebRTCManager()
    private let queue = DispatchQueue(label: "com.mirroringcamera.webrtc")
    private let frameLock = NSLock()
    private var hasSubscribers = false
    private var outputSize: (width: Int32, height: Int32)?
    private var recoveryTimer: DispatchSourceTimer?
    private let factory: RTCPeerConnectionFactory
    private let source: RTCVideoSource
    private let track: RTCVideoTrack
    private let capturer: RTCVideoCapturer
    private var sessions: [String: Session] = [:]
    private var fallback = PreviewFallbackState()
    private var sendSignal: (([String: Any]) -> Void)?

    private final class Session {
        let controlID: String
        let id: String
        var peer: RTCPeerConnection?
        var recovery = WebRTCRecoveryState()
        var creatingOffer = false
        var applyingAnswer = false
        var remoteDescriptionReady = false
        var pendingICE: [RTCIceCandidate] = []
        var localOfferSent = false
        var pendingLocalICE: [RTCIceCandidate] = []
        init(controlID: String, id: String) { self.controlID = controlID; self.id = id }
    }

    private override init() {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        if let h264 = RTCDefaultVideoEncoderFactory.supportedCodecs().first(where: {
            $0.name == "H264" && $0.parameters["profile-level-id"]?.hasPrefix("42") == true
        }) { encoder.preferredCodec = h264 }
        factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: RTCDefaultVideoDecoderFactory())
        source = factory.videoSource()
        track = factory.videoTrack(with: source, trackId: "cam-video")
        capturer = RTCVideoCapturer(delegate: source)
        super.init()
    }

    /// Bind a sender that is guarded by the current WebSocket generation.
    func configureSignaling(_ sender: @escaping ([String: Any]) -> Void) {
        queue.async { self.sendSignal = sender }
    }

    var isFallbackActive: Bool {
        queue.sync { fallback.isActive(now: ProcessInfo.processInfo.systemUptime) }
    }

    func subscribe(controlID: String, sessionID: String) {
        queue.async {
            guard self.sessions[sessionID] == nil else { return }
            let session = Session(controlID: controlID, id: sessionID)
            self.sessions[sessionID] = session
            session.recovery.awaitConnection(now: self.now)
            self.fallback.subscribe(sessionID, now: self.now)
            self.updateFrameState()
            self.startRecoveryTimer()
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
            guard let peer = self.factory.peerConnection(with: config,
                    constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
            else { return } // Keep the subscription for JPEG fallback.
            session.peer = peer
            let initial = RTCRtpTransceiverInit()
            initial.direction = .sendOnly
            initial.streamIds = ["cam-stream"]
            guard let transceiver = peer.addTransceiver(with: self.track, init: initial) else { return }
            let codecs = self.factory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs.filter {
                $0.name == "H264" && $0.parameters["profile-level-id"]?.hasPrefix("42") == true
            }
            if !codecs.isEmpty {
                _ = try? transceiver.setCodecPreferences(codecs, error: ())
            }
            self.makeOffer(for: session, restartingICE: false)
        }
    }

    private func makeOffer(for session: Session, restartingICE: Bool) {
        guard isCurrent(session), let peer = session.peer,
              !session.creatingOffer, !session.applyingAnswer,
              peer.signalingState == .stable else { return }
        session.creatingOffer = true
        session.localOfferSent = false
        session.remoteDescriptionReady = false
        session.pendingLocalICE.removeAll()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: restartingICE ? ["IceRestart": "true"] : nil,
            optionalConstraints: nil)
        peer.offer(for: constraints) { [weak self, weak session] sdp, error in
            guard let self, let session else { return }
            self.queue.async {
                guard self.isCurrent(session) else { return }
                guard let sdp, error == nil else {
                    session.creatingOffer = false
                    self.logError("create offer", error)
                    return
                }
                peer.setLocalDescription(sdp) { [weak self, weak session] error in
                    guard let self, let session else { return }
                    self.queue.async {
                        guard self.isCurrent(session) else { return }
                        session.creatingOffer = false
                        guard error == nil else {
                            self.logError("set local description", error)
                            return
                        }
                        self.sendSignal?(["type": "rtc_offer", "control_id": session.controlID,
                                          "session_id": session.id, "sdp": sdp.sdp])
                        session.localOfferSent = true
                        session.pendingLocalICE.forEach { self.sendICE($0, for: session) }
                        session.pendingLocalICE.removeAll()
                    }
                }
            }
        }
    }

    private func startRecoveryTimer() {
        guard recoveryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for session in self.sessions.values {
                guard let peer = session.peer else { continue }
                let stable = peer.signalingState == .stable && !session.creatingOffer && !session.applyingAnswer
                if session.recovery.shouldRestart(now: self.now, signalingStable: stable) {
                    self.makeOffer(for: session, restartingICE: true)
                }
            }
        }
        recoveryTimer = timer
        timer.resume()
    }

    private func logError(_ operation: String, _ error: Error?) {
        if let error { NSLog("WebRTC %@ failed: %@", operation, error.localizedDescription) }
    }

    func answer(sessionID: String, sdp: String) {
        queue.async {
            guard let session = self.sessions[sessionID], let peer = session.peer,
                  session.localOfferSent, !session.applyingAnswer,
                  peer.signalingState == .haveLocalOffer else { return }
            session.applyingAnswer = true
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak manager = self, weak pendingSession = session] error in
                guard let self = manager, let session = pendingSession else { return }
                self.queue.async {
                    guard self.isCurrent(session) else { return }
                    session.applyingAnswer = false
                    guard error == nil else { self.logError("set remote description", error); return }
                    if peer.iceConnectionState != .connected && peer.iceConnectionState != .completed {
                        session.recovery.awaitConnection(now: self.now)
                    }
                    session.remoteDescriptionReady = true
                    session.pendingICE.forEach { peer.add($0, completionHandler: { self.logError("add ICE", $0) }) }
                    session.pendingICE.removeAll()
                }
            }
        }
    }

    func ice(sessionID: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        queue.async {
            guard let session = self.sessions[sessionID], let peer = session.peer else { return }
            let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            if session.remoteDescriptionReady { peer.add(ice, completionHandler: { self.logError("add ICE", $0) }) }
            else if session.pendingICE.count < 256 { session.pendingICE.append(ice) }
        }
    }

    func unsubscribe(sessionID: String) {
        queue.async { self.remove(sessionID) }
    }

    func controlGone(controlID: String) {
        queue.async {
            let ids = self.sessions.values.filter { $0.controlID == controlID }.map(\.id)
            ids.forEach { self.remove($0) }
        }
    }

    func closeAll() {
        queue.async {
            let peers = self.sessions.values.compactMap(\.peer)
            self.recoveryTimer?.cancel()
            self.recoveryTimer = nil
            self.sessions.removeAll()
            self.fallback.reset()
            self.updateFrameState()
            self.sendSignal = nil
            peers.forEach { $0.close() }
        }
    }

    /// The output connection already rotates pixels; do not apply a second rotation in WebRTC.
    func pushFrame(_ sampleBuffer: CMSampleBuffer) {
        frameLock.lock()
        let active = hasSubscribers
        frameLock.unlock()
        guard active, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let scale = min(1, 1920.0 / Double(max(width, height)))
        let target = (width: Int32(Double(width) * scale) / 2 * 2,
                      height: Int32(Double(height) * scale) / 2 * 2)
        if outputSize?.width != target.width || outputSize?.height != target.height {
            source.adaptOutputFormat(toWidth: target.width, height: target.height, fps: 30)
            outputSize = target
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, !timestamp.isIndefinite else { return }
        let nanos = Int64(CMTimeGetSeconds(timestamp) * 1_000_000_000)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: nanos)
        source.capturer(capturer, didCapture: frame)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func isCurrent(_ session: Session) -> Bool { sessions[session.id] === session }
    private func remove(_ id: String) {
        let session = sessions.removeValue(forKey: id)
        fallback.unsubscribe(id, now: now)
        updateFrameState()
        session?.peer?.close()
        if sessions.isEmpty { recoveryTimer?.cancel(); recoveryTimer = nil }
    }
    private func sendICE(_ candidate: RTCIceCandidate, for session: Session) {
        sendSignal?([
            "type": "rtc_ice", "control_id": session.controlID, "session_id": session.id,
            "candidate": ["candidate": candidate.sdp, "sdpMid": candidate.sdpMid as Any? ?? NSNull(),
                          "sdpMLineIndex": candidate.sdpMLineIndex]
        ])
    }

    private func updateFrameState() {
        frameLock.lock()
        hasSubscribers = !sessions.isEmpty
        frameLock.unlock()
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queue.async {
            guard let session = self.sessions.values.first(where: { $0.peer === peerConnection }) else { return }
            if session.localOfferSent { self.sendICE(candidate, for: session) }
            else if session.pendingLocalICE.count < 256 { session.pendingLocalICE.append(candidate) }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        queue.async {
            guard let session = self.sessions.values.first(where: { $0.peer === peerConnection }) else { return }
            // Keep feeding the source during recovery; JPEG covers unavailable viewers.
            self.fallback.setConnected(newState == .connected, id: session.id, now: self.now)
            self.updateFrameState()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        queue.async {
            guard let session = self.sessions.values.first(where: { $0.peer === peerConnection }) else { return }
            switch newState {
            case .connected, .completed:
                session.recovery.connected()
            case .disconnected, .failed:
                session.recovery.awaitConnection(now: self.now)
                self.fallback.setConnected(false, id: session.id, now: self.now)
                self.updateFrameState()
            default: break
            }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
