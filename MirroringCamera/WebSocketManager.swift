import AVFoundation
import Foundation
import UIKit

@MainActor
final class WebSocketManager: ObservableObject {
    static let shared = WebSocketManager()

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var lastError: String?
    @Published var isActiveCamera = false

    private let settings: SettingsStore
    private let registrationSession: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var registrationTask: URLSessionDataTask?
    private var statusTimer: Timer?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var isIntentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var connectionGeneration: UInt64 = 0

    init(settings: SettingsStore = .shared, registrationSession: URLSession = .shared) {
        self.settings = settings
        self.registrationSession = registrationSession
        UIDevice.current.isBatteryMonitoringEnabled = true
        _ = NetworkMonitor.shared
    }

    func connect() {
        guard !isConnected, !isConnecting else { return }
        guard settings.isConfigured, settings.wsURL != nil else {
            lastError = "有効なAPI URLとAPI Keyを設定してください"
            return
        }
        stopTimers()
        connectionGeneration &+= 1
        let generation = connectionGeneration
        isIntentionalDisconnect = false
        reconnectAttempts = 0
        isConnecting = true
        lastError = nil
        registerCamera(generation: generation)
    }

    func disconnect() {
        isIntentionalDisconnect = true
        connectionGeneration &+= 1
        stopTimers()
        releaseConnection()
        isConnected = false
        isConnecting = false
        isActiveCamera = false
        lastError = nil
    }

    func onForegroundResume() {
        guard !isIntentionalDisconnect, settings.isConfigured,
              !isConnected, !isConnecting else { return }
        connect()
    }

    private func releaseConnection() {
        registrationTask?.cancel()
        registrationTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        WebRTCManager.shared.closeAll()
    }

    private func registerCamera(generation: UInt64) {
        guard let baseURL = settings.restBaseURL else {
            isConnecting = false
            lastError = "API URLが不正です"
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/cameras/register"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["camera_id": settings.cameraID])
        registrationTask = registrationSession.dataTask(with: request) { [weak self] _, _, _ in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation, !self.isIntentionalDisconnect else { return }
                self.registrationTask = nil
                // Already registered cameras can still connect if registration fails.
                self.openWebSocket(expectedGeneration: generation)
            }
        }
        registrationTask?.resume()
    }

    private func openWebSocket(expectedGeneration: UInt64) {
        guard connectionGeneration == expectedGeneration, !isIntentionalDisconnect else { return }
        guard let url = settings.wsURL else {
            isConnecting = false
            lastError = "WebSocket URLの構築に失敗しました"
            return
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let urlSession = URLSession(configuration: .default)
        session = urlSession
        let task = urlSession.webSocketTask(with: url)
        webSocketTask = task
        isConnecting = true
        WebRTCManager.shared.configureSignaling { [weak self] payload in
            // Preserve offer/ICE ordering when hopping to the signaling socket.
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.sendJSON(payload)
            }
        }
        task.resume()
        receiveMessage(task: task, generation: generation)
        startPingTimer(task: task, generation: generation)
        guard let data = try? JSONSerialization.data(withJSONObject: buildStatusPayload()),
              let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { [weak self] error in
            Task { @MainActor in
                guard let self, self.isCurrent(task, generation: generation) else { return }
                if let error {
                    self.handleDisconnection(generation: generation, error: error)
                    return
                }
                self.markConnected(generation: generation)
            }
        }
    }

    private func markConnected(generation: UInt64) {
        guard connectionGeneration == generation, !isConnected else { return }
        isConnected = true
        isConnecting = false
        lastError = nil
        reconnectAttempts = 0
        startStatusTimer(generation: generation)
        if CameraManager.shared.isTimeLapseActive { sendTimeLapseState() }
    }

    private func isCurrent(_ task: URLSessionWebSocketTask, generation: UInt64) -> Bool {
        connectionGeneration == generation && webSocketTask === task && !isIntentionalDisconnect
    }

    private func receiveMessage(task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isCurrent(task, generation: generation) else { return }
                switch result {
                case .success(let message):
                    self.markConnected(generation: generation)
                    self.handleMessage(message)
                    self.receiveMessage(task: task, generation: generation)
                case .failure(let error):
                    self.handleDisconnection(generation: generation, error: error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): guard let value = text.data(using: .utf8) else { return }; data = value
        case .data(let value): data = value
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "command": handleCommand(json)
        case "active_camera_state": handleActiveCameraState(json)
        case "rtc_subscribe":
            guard let controlID = json["control_id"] as? String, let sessionID = json["session_id"] as? String else { return }
            WebRTCManager.shared.subscribe(controlID: controlID, sessionID: sessionID)
        case "rtc_answer":
            guard let sessionID = json["session_id"] as? String, let sdp = json["sdp"] as? String else { return }
            WebRTCManager.shared.answer(sessionID: sessionID, sdp: sdp)
        case "rtc_ice":
            guard let sessionID = json["session_id"] as? String, let candidate = json["candidate"] as? [String: Any],
                  let sdp = candidate["candidate"] as? String else { return }
            let index = candidate["sdpMLineIndex"] as? Int ?? 0
            guard let lineIndex = Int32(exactly: index), lineIndex >= 0 else { return }
            WebRTCManager.shared.ice(sessionID: sessionID, candidate: sdp, sdpMid: candidate["sdpMid"] as? String,
                                     sdpMLineIndex: lineIndex)
        case "rtc_unsubscribe":
            guard let id = json["session_id"] as? String else { return }
            WebRTCManager.shared.unsubscribe(sessionID: id)
        case "rtc_control_gone":
            guard let id = json["control_id"] as? String else { return }
            WebRTCManager.shared.controlGone(controlID: id)
        default: break
        }
    }

    // MARK: - コマンド処理

    private func handleActiveCameraState(_ json: [String: Any]) {
        let isActive = json["is_active"] as? Bool ?? false
        isActiveCamera = isActive
        let activeCameraId = json["active_camera_id"] as? String ?? "none"
        let atemConnected = json["atem_connected"] as? Bool ?? false
        print("アクティブ状態受信: is_active=\(isActive), active_camera_id=\(activeCameraId), atem_connected=\(atemConnected)")
    }

    private func handleCommand(_ json: [String: Any]) {
        guard let command = json["command"] as? String,
              let requestId = json["request_id"] as? String else { return }

        let commandGeneration = connectionGeneration

        print("コマンド受信: \(command) (request_id: \(requestId))")

        switch command {
        case "recording_start":
            if !CameraManager.shared.isRecording {
                CameraManager.shared.selectedMode = .video
                CameraManager.shared.onRecordingStarted = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "recording started")
                    CameraManager.shared.onRecordingStarted = nil
                }
                CameraManager.shared.toggleRecording()
            } else {
                sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "already recording")
            }

        case "recording_stop":
            if CameraManager.shared.isRecording {
                CameraManager.shared.onRecordingStopped = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "recording stopped")
                    CameraManager.shared.onRecordingStopped = nil
                }
                CameraManager.shared.toggleRecording()
            } else {
                sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "not recording")
            }

        case "take_photo":
            CameraManager.shared.selectedMode = .photo
            CameraManager.shared.onPhotoCaptured = { [weak self] success, message in
                self?.sendCommandResult(requestId: requestId, generation: commandGeneration, success: success, message: message ?? "photo captured")
                CameraManager.shared.onPhotoCaptured = nil
            }
            CameraManager.shared.capturePhoto()

        case "timelapse_start":
            let interval = json["interval_sec"] as? TimeInterval ?? 1.0
            if !CameraManager.shared.isTimeLapseActive {
                CameraManager.shared.selectedMode = .timeLapse
                CameraManager.shared.onTimeLapseStarted = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "timelapse started")
                    CameraManager.shared.onTimeLapseStarted = nil
                }
                CameraManager.shared.startTimeLapse(interval: interval)
            } else {
                sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "timelapse already running")
            }

        case "timelapse_stop":
            if CameraManager.shared.isTimeLapseActive {
                CameraManager.shared.onTimeLapseStopped = { [weak self] shotCount in
                    self?.sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "timelapse stopped (\(shotCount) shots)")
                    CameraManager.shared.onTimeLapseStopped = nil
                }
                CameraManager.shared.stopTimeLapse()
            } else {
                sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "timelapse not running")
            }

        case "timelapse_state_request":
            sendTimeLapseState()
            sendCommandResult(requestId: requestId, generation: commandGeneration, success: true, message: "timelapse state sent")

        default:
            sendCommandResult(requestId: requestId, generation: commandGeneration, success: false, message: "unknown command: \(command)")
        }
    }

    // MARK: - 送信

    func sendStatus() {
        guard isConnected else { return }
        sendJSON(buildStatusPayload())
    }

    private func buildStatusPayload() -> [String: Any] {
        return [
            "type": "status",
            "is_recording": CameraManager.shared.isRecording,
            "battery_level": UIDevice.current.batteryLevel,
            "temperature_thermal_state": thermalStateString(ProcessInfo.processInfo.thermalState),
            "platform": "ios",
            "device_model": UIDevice.current.model,
            "network": NetworkMonitor.shared.networkType
        ]
    }

    private func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "nominal"
        }
    }

    func sendPreview(imageData: Data) {
        guard isConnected else { return }

        let base64 = imageData.base64EncodedString()
        let preview: [String: Any] = [
            "type": "preview",
            "image_base64": base64
        ]

        sendJSON(preview)
    }

    // MARK: - タイムラプスイベント送信

    func sendTimeLapseStarted(interval: TimeInterval) {
        guard isConnected else { return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let event: [String: Any] = [
            "type": "timelapse_started",
            "interval_sec": interval,
            "started_at": formatter.string(from: Date())
        ]
        sendJSON(event)
    }

    func sendTimeLapseProgress(shotCount: Int) {
        guard isConnected else { return }
        let event: [String: Any] = [
            "type": "timelapse_progress",
            "shot_count": shotCount
        ]
        sendJSON(event)
    }

    func sendTimeLapseStopped(shotCount: Int) {
        guard isConnected else { return }
        let event: [String: Any] = [
            "type": "timelapse_stopped",
            "shot_count": shotCount
        ]
        sendJSON(event)
    }

    func sendTimeLapseState() {
        guard isConnected else { return }
        let manager = CameraManager.shared
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let event: [String: Any] = [
            "type": "timelapse_state",
            "is_running": manager.isTimeLapseActive,
            "interval_sec": manager.timeLapseInterval,
            "shot_count": manager.timeLapseCount,
            "started_at": manager.timeLapseStartedAt.map { formatter.string(from: $0) } ?? ""
        ]
        sendJSON(event)
    }

    private func sendCommandResult(requestId: String, generation: UInt64, success: Bool, message: String, photoURL: String? = nil) {
        guard connectionGeneration == generation else { return }
        var result: [String: Any] = [
            "type": "command_result",
            "request_id": requestId,
            "success": success,
            "message": message
        ]
        if let photoURL = photoURL {
            result["photo_url"] = photoURL
        }

        sendJSON(result)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard isConnected, let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        let generation = connectionGeneration
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.isCurrent(task, generation: generation) else { return }
                self.handleDisconnection(generation: generation, error: error)
            }
        }
    }

    private func startStatusTimer(generation: UInt64) {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connectionGeneration == generation else { return }
                self.sendStatus()
            }
        }
    }

    private func startPingTimer(task: URLSessionWebSocketTask, generation: UInt64) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrent(task, generation: generation) else { return }
                task.sendPing { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor in
                        self?.handleDisconnection(generation: generation, error: error)
                    }
                }
            }
        }
    }

    private func stopTimers() {
        statusTimer?.invalidate()
        statusTimer = nil
        pingTimer?.invalidate()
        pingTimer = nil
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func handleDisconnection(generation: UInt64, error: Error) {
        guard connectionGeneration == generation, !isIntentionalDisconnect else { return }
        // Invalidate every pending callback before closing this socket.
        connectionGeneration &+= 1
        isConnected = false
        isConnecting = false
        isActiveCamera = false
        stopTimers()
        releaseConnection()
        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnectAttempts else {
            lastError = "接続失敗（\(maxReconnectAttempts)回試行済み）。設定から再接続してください。"
            return
        }
        lastError = "接続が切断されました。再接続中…（\(reconnectAttempts)/\(maxReconnectAttempts)）"
        isConnecting = true
        let nextGeneration = connectionGeneration
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.openWebSocket(expectedGeneration: nextGeneration)
            }
        }
    }
}
