import Foundation
import WebRTC

/// カメラ端末（offerer）側の WebRTC を管理する。
///
/// CameraController/docs/api.md §2-4 に従い、カメラ端末が offerer となる。`rtc_subscribe` を受信すると
/// `(control_id, session_id)` ペアごとに `RTCPeerConnection` を生成し、共有の sendonly H.264 映像トラックを
/// 載せて `rtc_offer` を送信する。視聴者ごとに `RTCPeerConnection` を持つが、`RTCVideoSource` /
/// `RTCVideoTrack` / エンコーダは1本を全 sender で共有して端末の発熱を抑える（Android 実装と同じ設計）。
///
/// シグナリングはアプリ側の WebSocket（`WebSocketManager`）から届き、カメラフレームは
/// `ExternalDisplayStore` のビデオ出力から `pushFrame` で供給される。
/// 内部状態の更新・WebRTC コールバックは `stateQueue`（シリアル）上で直列化する。`@MainActor` にはしない
/// （WebRTC のコールバックは WebRTC 自身のスレッドで届くため）。
final class WebRTCManager: NSObject {
    static let shared = WebRTCManager()

    private static let videoTrackID = "cam-video"
    private static let streamID = "cam-stream"
    private static let stunURL = "stun:stun.l.google.com:19302"

    // MARK: - シグナリング送信コールバック（WebSocketManager に配線）

    /// カメラ -> サーバー: `rtc_offer`
    var onLocalOffer: ((_ controlId: String, _ sessionId: String, _ sdp: String) -> Void)?
    /// カメラ -> サーバー: `rtc_ice`
    var onLocalIce: ((_ controlId: String, _ sessionId: String, _ candidate: String, _ sdpMid: String?, _ sdpMLineIndex: Int32) -> Void)?
    /// カメラ -> サーバー: `rtc_close`（任意）
    var onLocalClose: ((_ controlId: String, _ sessionId: String) -> Void)?

    // MARK: - 内部状態

    private static let fallbackGraceSeconds: TimeInterval = 6.0

    private let stateQueue = DispatchQueue(label: "com.mirroringcamera.webrtc.state")
    private var sessions: [String: Session] = [:] // session_id -> Session
    private var connectedSessions: Set<String> = [] // session_ids with a live PC
    private var graceWorkItem: DispatchWorkItem?
    private var _isFallbackActive = false
    private var initialized = false

    private var factory: RTCPeerConnectionFactory!
    private var videoSource: RTCVideoSource!
    private var videoTrack: RTCVideoTrack!
    private var frameCapturer: RTCVideoCapturer!

    private final class Session {
        let controlId: String
        let sessionId: String
        let pc: RTCPeerConnection
        let delegate: PeerDelegate
        var remoteDescriptionSet = false
        var pendingCandidates: [RTCIceCandidate] = []

        init(controlId: String, sessionId: String, pc: RTCPeerConnection, delegate: PeerDelegate) {
            self.controlId = controlId
            self.sessionId = sessionId
            self.pc = pc
            self.delegate = delegate
        }
    }

    private override init() {
        super.init()
    }

    // MARK: - 共有リソースの遅延生成

    /// stateQueue 上で呼ぶこと。
    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true

        RTCInitializeSSL()

        // H.264 を優先（api.md §2-4 推奨。iOS ハードウェアエンコーダで発熱も抑えられる）。
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let h264Codecs = encoderFactory.supportedCodecs().filter { $0.name == kRTCVideoCodecH264Name }
        // Constrained Baseline level 3.1（profile-level-id "42e01f"）を優先、無ければ任意の H.264。
        if let preferred = h264Codecs.first(where: { ($0.parameters["profile-level-id"] ?? "").hasPrefix("42e0") }) ?? h264Codecs.first {
            encoderFactory.preferredCodec = preferred
        }
        let decoderFactory = RTCDefaultVideoDecoderFactory()

        factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)

        // 全視聴者で共有する単一の source / track。
        videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource, trackId: Self.videoTrackID)
        videoTrack.isEnabled = true
        frameCapturer = RTCVideoCapturer(delegate: videoSource)
    }

    // MARK: - 受信シグナリング（サーバーから WebSocketManager 経由）

    /// 視聴開始: PeerConnection を生成して offer を送る。
    func onSubscribe(controlId: String, sessionId: String) {
        stateQueue.async {
            self.ensureInitialized()
            guard self.sessions[sessionId] == nil else { return }

            let config = RTCConfiguration()
            config.iceServers = [RTCIceServer(urlStrings: [Self.stunURL])]
            config.sdpSemantics = .unifiedPlan

            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let delegate = PeerDelegate(controlId: controlId, sessionId: sessionId, manager: self)
            guard let pc = self.factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
                print("WebRTC: peerConnection 生成失敗 session=\(sessionId)")
                return
            }

            let transceiverInit = RTCRtpTransceiverInit()
            transceiverInit.direction = .sendOnly
            transceiverInit.streamIds = [Self.streamID]
            _ = pc.addTransceiver(with: self.videoTrack, init: transceiverInit)

            let session = Session(controlId: controlId, sessionId: sessionId, pc: pc, delegate: delegate)
            self.sessions[sessionId] = session
            self.createAndSendOffer(session)
            self.updateFallback()
        }
    }

    /// answer を受信: setRemoteDescription。
    func onRemoteAnswer(sessionId: String, sdp: String) {
        stateQueue.async {
            guard let session = self.sessions[sessionId] else { return }
            let answer = RTCSessionDescription(type: .answer, sdp: sdp)
            session.pc.setRemoteDescription(answer) { [weak self] error in
                guard let self else { return }
                if let error = error {
                    print("WebRTC: setRemoteDescription(answer) 失敗: \(error.localizedDescription)")
                    return
                }
                // remote 設定後に保留中の ICE candidate を流す。
                self.stateQueue.async {
                    guard let s = self.sessions[sessionId] else { return }
                    s.remoteDescriptionSet = true
                    for cand in s.pendingCandidates {
                        s.pc.add(cand) { _ in }
                    }
                    s.pendingCandidates.removeAll()
                }
            }
        }
    }

    /// 視聴者からの ICE candidate を追加（remote description 未設定ならバッファ）。
    func onRemoteIce(sessionId: String, candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
        stateQueue.async {
            guard let session = self.sessions[sessionId] else { return }
            let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            if session.remoteDescriptionSet {
                session.pc.add(ice) { _ in }
            } else {
                session.pendingCandidates.append(ice)
            }
        }
    }

    /// 単一の視聴者が視聴停止。
    func onUnsubscribe(sessionId: String) {
        closeSession(sessionId: sessionId, notify: false)
    }

    /// 視聴者が完全に切断: その control_id の全 PeerConnection を解放。
    func onControlGone(controlId: String) {
        stateQueue.async {
            let gone = self.sessions.values.filter { $0.controlId == controlId }
            for s in gone {
                self.sessions.removeValue(forKey: s.sessionId)
                self.connectedSessions.remove(s.sessionId)
                s.pc.close()
            }
            self.updateFallback()
        }
    }

    /// シグナリング切断: 残った PeerConnection はすべて無効。
    func closeAll() {
        stateQueue.async {
            let all = Array(self.sessions.values)
            self.sessions.removeAll()
            self.connectedSessions.removeAll()
            for s in all {
                s.pc.close()
            }
            self.updateFallback()
        }
    }

    // MARK: - フレーム供給（ExternalDisplayStore のビデオ出力から）

    /// 視聴者が1人以上いる時だけ true。無駄なエンコードを避け発熱を抑えるため、呼び出し側でフレーム
    /// 変換前にチェックする。
    var hasActiveSessions: Bool {
        stateQueue.sync { !sessions.isEmpty }
    }

    /// 実際に WebRTC 接続が確立している視聴者が1人以上いる時だけ true。フォールバック中は false。
    var hasConnectedSessions: Bool {
        stateQueue.sync { !connectedSessions.isEmpty }
    }

    /// WebRTC が確立できず JPEG フォールバックを送るべき間は true。
    /// 視聴者がいるのに [fallbackGraceSeconds] 以内に1つも接続しなければ true、
    /// いずれかが接続すれば（または視聴者が全ていなくなれば）false。
    var isFallbackActive: Bool {
        stateQueue.sync { _isFallbackActive }
    }

    /// カメラの CVPixelBuffer を共有 VideoSource に供給する。
    /// `rotation` は通常 `._0`（AVCaptureConnection の videoRotationAngle で既に回転済みのため）。
    func pushFrame(pixelBuffer: CVPixelBuffer, rotation: RTCVideoRotation, timeStampNs: Int64) {
        // 軽量チェック。frameCapturer 未初期化（視聴者ゼロ）なら無視。
        guard let capturer = frameCapturer, let source = videoSource else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: rotation, timeStampNs: timeStampNs)
        source.capturer(capturer, didCapture: frame)
    }

    // MARK: - 内部処理

    /// stateQueue 上で呼ぶこと。
    private func createAndSendOffer(_ session: Session) {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        session.pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self else { return }
            guard let sdp = sdp else {
                print("WebRTC: createOffer 失敗: \(error?.localizedDescription ?? "unknown")")
                return
            }
            session.pc.setLocalDescription(sdp) { error in
                if let error = error {
                    print("WebRTC: setLocalDescription(offer) 失敗: \(error.localizedDescription)")
                    return
                }
                self.onLocalOffer?(session.controlId, session.sessionId, sdp.sdp)
            }
        }
    }

    /// PeerConnection を閉じてマップから除去。WebRTC コールバックスレッドからも安全に呼べる。
    fileprivate func closeSession(sessionId: String, notify: Bool) {
        stateQueue.async {
            guard let session = self.sessions.removeValue(forKey: sessionId) else { return }
            self.connectedSessions.remove(sessionId)
            self.updateFallback()
            session.pc.close()
            if notify {
                self.onLocalClose?(session.controlId, session.sessionId)
            }
        }
    }

    // MARK: - 接続状態の追跡（フォールバック判定用）

    /// PeerConnection が接続完了。WebRTC コールバックスレッドから安全に呼べる。
    fileprivate func markConnected(sessionId: String) {
        stateQueue.async {
            guard self.sessions[sessionId] != nil else { return }
            self.connectedSessions.insert(sessionId)
            self.updateFallback()
        }
    }

    /// PeerConnection が切断/失敗。セッション自体は残し（視聴者はまだ視聴したい）、
    /// JPEG フォールバックに切り替える。
    fileprivate func markDisconnected(sessionId: String) {
        stateQueue.async {
            self.connectedSessions.remove(sessionId)
            self.updateFallback()
        }
    }

    // MARK: - フォールバック状態機械（すべて stateQueue 上で呼ぶこと）

    private func updateFallback() {
        let shouldFallback = !sessions.isEmpty && connectedSessions.isEmpty
        if !shouldFallback {
            cancelGrace()
            setFallbackActive(false)
        } else if !_isFallbackActive {
            scheduleGraceCheck()
        }
    }

    private func scheduleGraceCheck() {
        guard graceWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.graceWorkItem = nil
            if !self.sessions.isEmpty && self.connectedSessions.isEmpty {
                self.setFallbackActive(true)
            }
        }
        graceWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + Self.fallbackGraceSeconds, execute: work)
    }

    private func cancelGrace() {
        graceWorkItem?.cancel()
        graceWorkItem = nil
    }

    private func setFallbackActive(_ active: Bool) {
        guard _isFallbackActive != active else { return }
        _isFallbackActive = active
    }

    /// 自身で生成した ICE candidate をシグナリングで送る。
    fileprivate func handleLocalIce(controlId: String, sessionId: String, candidate: RTCIceCandidate) {
        onLocalIce?(controlId, sessionId, candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex)
    }
}

// MARK: - セッションごとの PeerConnection デリゲート

/// `(control_id, session_id)` を捕捉する per-session デリゲート（Android の makeObserver 相当）。
/// `RTCPeerConnection` はデリゲートを弱参照するため、`Session` が保持して生存させる。
private final class PeerDelegate: NSObject, RTCPeerConnectionDelegate {
    let controlId: String
    let sessionId: String
    weak var manager: WebRTCManager?

    init(controlId: String, sessionId: String, manager: WebRTCManager) {
        self.controlId = controlId
        self.sessionId = sessionId
        self.manager = manager
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        manager?.handleLocalIce(controlId: controlId, sessionId: sessionId, candidate: candidate)
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // 接続状態を WebRTCManager に伝えてフォールバック要否を更新する。失敗時もセッションは
        // 閉じない（視聴者はまだ視聴したいので、JPEG フォールバックへ切り替える）。
        switch newState {
        case .connected, .completed:
            manager?.markConnected(sessionId: sessionId)
        case .disconnected, .failed, .closed:
            manager?.markDisconnected(sessionId: sessionId)
        default:
            break
        }
    }

    // 以降は未使用だが RTCPeerConnectionDelegate で必須。
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
