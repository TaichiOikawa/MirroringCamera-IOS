import AVFoundation
import MediaPlayer
import SwiftUI

enum CameraMode: String, CaseIterable {
  case photo = "写真"
  case video = "ビデオ"
  case timeLapse = "タイムラプス"
}

protocol CameraCoordinatorProtocol: AnyObject {
  func toggleRecording()
  func capturePhoto()
  func startTimeLapse(interval: TimeInterval)
  func stopTimeLapse()
  func changeResolution(preset: AVCaptureSession.Preset)
  func changeFPS(fps: Float64)
  func getSupportedResolutions() -> [(AVCaptureSession.Preset, String)]
  func getSupportedFPS() -> [Float64]
  func refreshPreviewOrientation()
}

class CameraManager: ObservableObject {
  static let shared = CameraManager()

  @Published var isRecording = false
  @Published var isTimeLapseActive = false
  @Published var timeLapseCount = 0
  @Published var timeLapseInterval: TimeInterval = 1.0
  @Published var recordingDuration: TimeInterval = 0
  @Published var currentResolution: AVCaptureSession.Preset = .high
  @Published var currentFPS: Float64 = 30.0
  @Published var selectedMode: CameraMode = .video

  // MARK: - デバイス状態
  @Published var batteryLevel: Float = UIDevice.current.batteryLevel
  @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

  weak var coordinator: CameraCoordinatorProtocol?

  // コマンド実行結果コールバック（WebSocketManager から設定）
  var onRecordingStarted: (() -> Void)?
  var onRecordingStopped: (() -> Void)?
  var onPhotoCaptured: ((_ success: Bool, _ message: String?) -> Void)?
  var onTimeLapseStarted: (() -> Void)?
  var onTimeLapseStopped: ((_ shotCount: Int) -> Void)?

  /// タイムラプス開始時刻（サーバー同期用）
  @Published var timeLapseStartedAt: Date?

  /// 音量ボタンシャッター用
  private var volumeObservation: NSKeyValueObservation?
  private var initialVolume: Float = -1
  private var isVolumeShutterReady = false
  private var hiddenVolumeView: MPVolumeView?

  private init() {
    UIDevice.current.isBatteryMonitoringEnabled = true
    batteryLevel = UIDevice.current.batteryLevel
    thermalState = ProcessInfo.processInfo.thermalState

    NotificationCenter.default.addObserver(
      self, selector: #selector(batteryLevelDidChange),
      name: UIDevice.batteryLevelDidChangeNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(thermalStateDidChange),
      name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
  }

  @objc private func batteryLevelDidChange() {
    DispatchQueue.main.async { self.batteryLevel = UIDevice.current.batteryLevel }
  }

  @objc private func thermalStateDidChange() {
    DispatchQueue.main.async { self.thermalState = ProcessInfo.processInfo.thermalState }
  }

  var batteryPercent: Int {
    batteryLevel < 0 ? 0 : Int(batteryLevel * 100)
  }

  var thermalStateLabel: String {
    switch thermalState {
    case .nominal:  return "正常"
    case .fair:     return "やや高温"
    case .serious:  return "高温"
    case .critical: return "危険"
    @unknown default: return "不明"
    }
  }

  var thermalStateColor: Color {
    switch thermalState {
    case .nominal:  return .green
    case .fair:     return .yellow
    case .serious:  return .orange
    case .critical: return .red
    @unknown default: return .gray
    }
  }

  // MARK: - 音量ボタンシャッター

  func setupVolumeShutter() {
    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setActive(true)
    } catch {
      print("AVAudioSession setActive エラー: \(error)")
    }
    initialVolume = audioSession.outputVolume

    // 画面外に MPVolumeView を配置してシステム音量HUDを非表示にする
    let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    volumeView.alpha = 0.01
    if let window = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow }) {
      window.addSubview(volumeView)
    }
    hiddenVolumeView = volumeView

    // 少し遅延させてから監視開始（起動直後のノイズを回避）
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      self?.isVolumeShutterReady = true
    }

    volumeObservation = audioSession.observe(\.outputVolume, options: [.new, .old]) { [weak self] session, change in
      guard let self, self.isVolumeShutterReady else { return }
      guard let newVal = change.newValue, let oldVal = change.oldValue, newVal != oldVal else { return }

      // 音量を元に戻す
      self.setSystemVolume(oldVal)

      DispatchQueue.main.async {
        self.handleVolumeButtonPress()
      }
    }
  }

  /// MPVolumeView 内のスライダーを使ってシステム音量を設定する
  private func setSystemVolume(_ volume: Float) {
    guard let volumeView = hiddenVolumeView else { return }
    // MPVolumeView 内の UISlider を取得して値を設定
    for subview in volumeView.subviews {
      if let slider = subview as? UISlider {
        DispatchQueue.main.async {
          slider.value = volume
        }
        return
      }
    }
  }

  private func handleVolumeButtonPress() {
    switch selectedMode {
    case .photo:
      capturePhoto()
    case .video:
      toggleRecording()
    case .timeLapse:
      if isTimeLapseActive {
        stopTimeLapse()
      } else {
        // タイムラプスはデフォルト間隔で開始
        startTimeLapse(interval: timeLapseInterval)
      }
    }
  }

  func stopVolumeShutter() {
    volumeObservation?.invalidate()
    volumeObservation = nil
    isVolumeShutterReady = false
    hiddenVolumeView?.removeFromSuperview()
    hiddenVolumeView = nil
  }

  var resolutionName: String {
    switch currentResolution {
    case .low: return "低"
    case .medium: return "中"
    case .high: return "高"
    case .hd1280x720: return "720p"
    case .hd1920x1080: return "1080p"
    case .hd4K3840x2160: return "4K"
    default: return "不明"
    }
  }

  var formattedRecordingTime: String {
    let hours = Int(recordingDuration) / 3600
    let minutes = Int(recordingDuration) / 60 % 60
    let seconds = Int(recordingDuration) % 60
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
  }

  func toggleRecording() {
    coordinator?.toggleRecording()
  }

  func capturePhoto() {
    coordinator?.capturePhoto()
  }

  func startTimeLapse(interval: TimeInterval) {
    coordinator?.startTimeLapse(interval: interval)
  }

  func stopTimeLapse() {
    coordinator?.stopTimeLapse()
  }

  func changeResolution(preset: AVCaptureSession.Preset) {
    coordinator?.changeResolution(preset: preset)
  }

  func changeFPS(fps: Float64) {
    coordinator?.changeFPS(fps: fps)
  }

  func getSupportedResolutions() -> [(AVCaptureSession.Preset, String)] {
    return coordinator?.getSupportedResolutions() ?? []
  }

  func getSupportedFPS() -> [Float64] {
    return coordinator?.getSupportedFPS() ?? []
  }
}
