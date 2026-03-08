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

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var statusTimer: Timer?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var isIntentionalDisconnect = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    // MARK: - 接続管理

    func connect() {
        guard SettingsStore.shared.isConfigured else {
            lastError = "API URL または API Key が設定されていません"
            return
        }
        isIntentionalDisconnect = false
        reconnectAttempts = 0
        isConnecting = true
        registerCamera { [weak self] success in
            guard let self else { return }
            if success {
                self.openWebSocket()
            } else {
                // 登録失敗でもWebSocket接続を試みる（既に登録済みの場合もある）
                self.openWebSocket()
            }
        }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        stopTimers()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false
        isConnecting = false
        isActiveCamera = false
    }

    // MARK: - カメラ登録 (REST)

    private func registerCamera(completion: @escaping (Bool) -> Void) {
        guard let baseURL = SettingsStore.shared.restBaseURL else {
            completion(false)
            return
        }
        let url = baseURL.appendingPathComponent("/api/cameras/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // API Key 認証ヘッダー
        let apiKey = SettingsStore.shared.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "camera_id": SettingsStore.shared.cameraID
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("カメラ登録エラー: \(error.localizedDescription)")
                    self.lastError = "カメラ登録失敗: \(error.localizedDescription)"
                    completion(false)
                    return
                }
                if let httpResponse = response as? HTTPURLResponse,
                   (200...299).contains(httpResponse.statusCode) {
                    print("カメラ登録成功")
                    completion(true)
                } else {
                    print("カメラ登録: 予期しないレスポンス")
                    completion(false)
                }
            }
        }.resume()
    }

    // MARK: - WebSocket

    private func openWebSocket() {
        guard let url = SettingsStore.shared.wsURL else {
            lastError = "WebSocket URL の構築に失敗しました"
            return
        }

        let urlSession = URLSession(configuration: .default)
        self.session = urlSession
        let task = urlSession.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        isConnecting = true
        lastError = "接続中..."
        print("WebSocket 接続試行: \(url)")

        // 接続確認: メッセージ受信を開始し、最初のステータス送信の成功で接続確認
        receiveMessage()
        startPingTimer()

        // ステータス送信を試みて接続を確認する
        let statusPayload = buildStatusPayload()
        if let data = try? JSONSerialization.data(withJSONObject: statusPayload),
           let json = String(data: data, encoding: .utf8) {
            task.send(.string(json)) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error = error {
                        print("WebSocket 接続失敗: \(error.localizedDescription)")
                        self.handleDisconnection()
                        return
                    }
                    self.isConnected = true
                    self.isConnecting = false
                    self.lastError = nil
                    self.reconnectAttempts = 0
                    print("WebSocket 接続確認完了: \(url)")

                    self.startStatusTimer()

                    // 再接続時にタイムラプス状態を同期
                    if CameraManager.shared.isTimeLapseActive {
                        self.sendTimeLapseState()
                    }
                }
            }
        }
    }

    private func receiveMessage() {
        webSocketTask?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage() // 次のメッセージを待機
                case .failure(let error):
                    print("WebSocket 受信エラー: \(error.localizedDescription)")
                    self.handleDisconnection()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            if type == "command" {
                handleCommand(json)
            } else if type == "active_camera_state" {
                handleActiveCameraState(json)
            }

        case .data(let data):
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }
            if type == "command" {
                handleCommand(json)
            } else if type == "active_camera_state" {
                handleActiveCameraState(json)
            }

        @unknown default:
            break
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

        print("コマンド受信: \(command) (request_id: \(requestId))")

        switch command {
        case "recording_start":
            if !CameraManager.shared.isRecording {
                CameraManager.shared.selectedMode = .video
                CameraManager.shared.onRecordingStarted = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, success: true, message: "recording started")
                    CameraManager.shared.onRecordingStarted = nil
                }
                CameraManager.shared.toggleRecording()
            } else {
                sendCommandResult(requestId: requestId, success: true, message: "already recording")
            }

        case "recording_stop":
            if CameraManager.shared.isRecording {
                CameraManager.shared.onRecordingStopped = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, success: true, message: "recording stopped")
                    CameraManager.shared.onRecordingStopped = nil
                }
                CameraManager.shared.toggleRecording()
            } else {
                sendCommandResult(requestId: requestId, success: true, message: "not recording")
            }

        case "take_photo":
            CameraManager.shared.selectedMode = .photo
            CameraManager.shared.onPhotoCaptured = { [weak self] success, message in
                self?.sendCommandResult(requestId: requestId, success: success, message: message ?? "photo captured")
                CameraManager.shared.onPhotoCaptured = nil
            }
            CameraManager.shared.capturePhoto()

        case "timelapse_start":
            let interval = json["interval_sec"] as? TimeInterval ?? 1.0
            if !CameraManager.shared.isTimeLapseActive {
                CameraManager.shared.selectedMode = .timeLapse
                CameraManager.shared.onTimeLapseStarted = { [weak self] in
                    self?.sendCommandResult(requestId: requestId, success: true, message: "timelapse started")
                    CameraManager.shared.onTimeLapseStarted = nil
                }
                CameraManager.shared.startTimeLapse(interval: interval)
            } else {
                sendCommandResult(requestId: requestId, success: true, message: "timelapse already running")
            }

        case "timelapse_stop":
            if CameraManager.shared.isTimeLapseActive {
                CameraManager.shared.onTimeLapseStopped = { [weak self] shotCount in
                    self?.sendCommandResult(requestId: requestId, success: true, message: "timelapse stopped (\(shotCount) shots)")
                    CameraManager.shared.onTimeLapseStopped = nil
                }
                CameraManager.shared.stopTimeLapse()
            } else {
                sendCommandResult(requestId: requestId, success: true, message: "timelapse not running")
            }

        case "timelapse_state_request":
            sendTimeLapseState()
            sendCommandResult(requestId: requestId, success: true, message: "timelapse state sent")

        default:
            sendCommandResult(requestId: requestId, success: false, message: "unknown command: \(command)")
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
            "network": "wifi"
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

    private func sendCommandResult(requestId: String, success: Bool, message: String, photoURL: String? = nil) {
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
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }

        webSocketTask?.send(.string(text)) { error in
            if let error = error {
                print("WebSocket 送信エラー: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - タイマー

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.sendStatus()
            }
        }
    }

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.webSocketTask?.sendPing { error in
                if let error = error {
                    print("Ping エラー: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self?.handleDisconnection()
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

    // MARK: - 再接続

    private func handleDisconnection() {
        isConnected = false
        isConnecting = false
        isActiveCamera = false
        stopTimers()
        webSocketTask = nil

        guard !isIntentionalDisconnect else { return }

        reconnectAttempts += 1

        if reconnectAttempts > maxReconnectAttempts {
            lastError = "接続失敗（\(maxReconnectAttempts)回試行済み）。設定から再接続してください。"
            print("WebSocket 再接続上限到達（\(maxReconnectAttempts)回）")
            return
        }

        lastError = "接続が切断されました。再接続中...（\(reconnectAttempts)/\(maxReconnectAttempts)）"
        isConnecting = true
        print("WebSocket 切断。5秒後に再接続を試みます（\(reconnectAttempts)/\(maxReconnectAttempts)）")

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.openWebSocket()
            }
        }
    }

}
