import AVFoundation
import Photos
import SwiftUI

extension CameraView {
  class Coordinator: NSObject, AVCaptureFileOutputRecordingDelegate, AVCapturePhotoCaptureDelegate,
    CameraCoordinatorProtocol
  {
    var session: AVCaptureSession?
    var movieOutput: AVCaptureMovieFileOutput?
    var photoOutput: AVCapturePhotoOutput?
    var isRecording = false
    weak var cameraUIView: CameraUIView?

    var recordingTimer: Timer?
    var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0

    var currentResolution: AVCaptureSession.Preset = .high
    var currentFPS: Float64 = 30.0

    var isTimeLapseActive = false
    var timeLapseTimer: Timer?
    var timeLapseInterval: TimeInterval = 1.0
    var timeLapseCount = 0

    init(session: AVCaptureSession?) {
      self.session = session
      super.init()
    }

    // MARK: - ヘルパー

    /// セッションから現在のビデオ入力デバイスを安全に取得する
    private var currentVideoInputDevice: AVCaptureDevice? {
      guard let session = session else { return nil }
      return session.inputs
        .compactMap { $0 as? AVCaptureDeviceInput }
        .first { $0.device.hasMediaType(.video) }?
        .device
    }

    func getSupportedResolutions() -> [(AVCaptureSession.Preset, String)] {
      guard let session = session else { return [] }

      let allResolutions: [(AVCaptureSession.Preset, String)] = [
        (.low, "低"),
        (.medium, "中"),
        (.high, "高"),
        (.hd1280x720, "720p"),
        (.hd1920x1080, "1080p"),
        (.hd4K3840x2160, "4K"),
      ]

      return allResolutions.filter { preset, _ in
        session.canSetSessionPreset(preset)
      }
    }

    func getSupportedFPS() -> [Float64] {
      guard let device = currentVideoInputDevice else {
        return []
      }

      let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges

      let commonFPS: [Float64] = [24, 30, 60, 120, 240]

      return commonFPS.filter { fps in
        supportedRanges.contains { range in
          fps >= range.minFrameRate && fps <= range.maxFrameRate
        }
      }
    }

    func toggleRecording() {
      if isRecording {
        stopRecording()
      } else {
        if isTimeLapseActive {
          print("タイムラプス実行中は録画できません")
          DispatchQueue.main.async {
            self.cameraUIView?.showError(message: "タイムラプス実行中は録画できません")
          }
          return
        }
        startRecording()
      }
    }

    func startRecording() {
      guard let movieOutput = movieOutput else {
        print("MovieOutputが設定されていません")
        return
      }

      guard !movieOutput.isRecording else {
        print("既に録画中です")
        return
      }

      let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dateFormatter = DateFormatter()
      dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
      let timestamp = dateFormatter.string(from: Date())
      let outputURL = documentsPath.appendingPathComponent("recording_\(timestamp).mov")

      print("録画開始: \(outputURL)")

      if let connection = movieOutput.connection(with: .video),
        connection.isVideoOrientationSupported
      {
        if let orientation = cameraUIView?.currentVideoOrientation() {
          connection.videoOrientation = orientation
        }
      }

      movieOutput.startRecording(to: outputURL, recordingDelegate: self)
      isRecording = true

      recordingStartTime = Date()
      recordingDuration = 0
      startRecordingTimer()

      DispatchQueue.main.async {
        CameraManager.shared.isRecording = true
        CameraManager.shared.onRecordingStarted?()
      }
    }

    func stopRecording() {
      guard let movieOutput = movieOutput else {
        print("MovieOutputが設定されていません")
        return
      }

      guard movieOutput.isRecording else {
        return
      }

      movieOutput.stopRecording()
      isRecording = false

      stopRecordingTimer()

      DispatchQueue.main.async {
        CameraManager.shared.isRecording = false
        CameraManager.shared.onRecordingStopped?()
      }
    }

    private func startRecordingTimer() {
      recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        guard let self = self, let startTime = self.recordingStartTime else { return }
        self.recordingDuration = Date().timeIntervalSince(startTime)
        DispatchQueue.main.async {
          CameraManager.shared.recordingDuration = self.recordingDuration
        }
      }
    }

    private func stopRecordingTimer() {
      recordingTimer?.invalidate()
      recordingTimer = nil
      recordingStartTime = nil
      recordingDuration = 0
      DispatchQueue.main.async {
        CameraManager.shared.recordingDuration = 0
      }
    }

    func capturePhoto() {
      // 写真の向きを現在のデバイス向きに合わせる
      if let connection = photoOutput?.connection(with: .video),
         connection.isVideoOrientationSupported {
        if let orientation = cameraUIView?.currentVideoOrientation() {
          connection.videoOrientation = orientation
        }
      }
      let photoSettings = AVCapturePhotoSettings()
      photoOutput?.capturePhoto(with: photoSettings, delegate: self)
    }

    func changeResolution(preset: AVCaptureSession.Preset) {
      guard let session = session else { return }

      session.beginConfiguration()

      if session.canSetSessionPreset(preset) {
        session.sessionPreset = preset
        currentResolution = preset

        DispatchQueue.main.async {
          CameraManager.shared.currentResolution = preset
        }
      } else {
        DispatchQueue.main.async {
          self.cameraUIView?.showError(message: "この解像度はサポートされていません")
        }
      }

      session.commitConfiguration()
    }

    func changeFPS(fps: Float64) {
      guard let device = currentVideoInputDevice else {
        print("ビデオ入力デバイスが見つかりません")
        return
      }

      do {
        try device.lockForConfiguration()

        let supportedRanges = device.activeFormat.videoSupportedFrameRateRanges
        let targetFrameRate = fps

        var isSupported = false
        for range in supportedRanges {
          if targetFrameRate >= range.minFrameRate && targetFrameRate <= range.maxFrameRate {
            isSupported = true
            break
          }
        }

        if isSupported {
          device.activeVideoMinFrameDuration = CMTime(
            value: 1, timescale: CMTimeScale(targetFrameRate))
          device.activeVideoMaxFrameDuration = CMTime(
            value: 1, timescale: CMTimeScale(targetFrameRate))
          currentFPS = targetFrameRate

          DispatchQueue.main.async {
            CameraManager.shared.currentFPS = targetFrameRate
          }
        } else {
          DispatchQueue.main.async {
            self.cameraUIView?.showError(message: "このFPSはサポートされていません")
          }
        }

        device.unlockForConfiguration()
      } catch {
        print("FPS変更エラー: \(error.localizedDescription)")
        DispatchQueue.main.async {
          self.cameraUIView?.showError(message: "FPS変更に失敗しました")
        }
      }
    }

    func updateOutputConnections() {
      if let movieOutput = movieOutput,
        let connection = movieOutput.connection(with: .video)
      {
        if connection.isVideoStabilizationSupported {
          let bestMode = getBestVideoStabilizationMode()
          connection.preferredVideoStabilizationMode = bestMode
        }
      }
    }

    func refreshPreviewOrientation() {
      cameraUIView?.setupPreviewLayerOrientation()
    }

    private func getBestVideoStabilizationMode() -> AVCaptureVideoStabilizationMode {
      guard let device = currentVideoInputDevice else { return .auto }

      let format = device.activeFormat

      if #available(iOS 17.0, *) {
        if format.isVideoStabilizationModeSupported(.previewOptimized) {
          return .previewOptimized
        }
      }

      if #available(iOS 26.0, *) {
        if format.isVideoStabilizationModeSupported(.lowLatency) {
          return .lowLatency
        }
      }

      if format.isVideoStabilizationModeSupported(.cinematicExtended) {
        return .cinematicExtended
      }

      if format.isVideoStabilizationModeSupported(.cinematic) {
        return .cinematic
      }

      if format.isVideoStabilizationModeSupported(.standard) {
        return .standard
      }

      if format.isVideoStabilizationModeSupported(.auto) {
        return .auto
      }

      return .off
    }

    func fileOutput(
      _ output: AVCaptureFileOutput,
      didFinishRecordingTo outputFileURL: URL,
      from connections: [AVCaptureConnection],
      error: Error?
    ) {
      if let error = error {
        print("録画中にエラーが発生しました: \(error.localizedDescription)")
        DispatchQueue.main.async {
          self.cameraUIView?.showError(message: "録画に失敗しました: \(error.localizedDescription)")
        }
      } else {
        saveVideoToPhotoLibrary(url: outputFileURL)
      }
    }

    func photoOutput(
      _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?
    ) {
      if let error = error {
        print("写真撮影エラー: \(error.localizedDescription)")
        DispatchQueue.main.async {
          CameraManager.shared.onPhotoCaptured?(false, error.localizedDescription)
        }
        return
      }

      guard let photoData = photo.fileDataRepresentation() else {
        print("写真データの取得に失敗しました")
        DispatchQueue.main.async {
          CameraManager.shared.onPhotoCaptured?(false, "写真データの取得に失敗")
        }
        return
      }

      savePhotoToPhotoLibrary(data: photoData)
      DispatchQueue.main.async {
        CameraManager.shared.onPhotoCaptured?(true, nil)
      }
    }

    private func saveVideoToPhotoLibrary(url: URL) {
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
      }) { success, error in
        if let error = error {
          print("動画保存エラー: \(error.localizedDescription)")
        } else if success {
          print("動画をフォトライブラリに保存しました")
          // 一時ファイルを削除
          try? FileManager.default.removeItem(at: url)
        }
      }
    }

    private func savePhotoToPhotoLibrary(data: Data) {
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        request.addResource(with: .photo, data: data, options: nil)
      }) { success, error in
        if let error = error {
          print("写真保存エラー: \(error.localizedDescription)")
        } else if success {
          print("写真をフォトライブラリに保存しました")
        }
      }
    }

    func startTimeLapse(interval: TimeInterval) {
      guard !isTimeLapseActive else { return }

      if isRecording {
        print("録画中はタイムラプスを開始できません")
        DispatchQueue.main.async {
          self.cameraUIView?.showError(message: "録画中はタイムラプスを開始できません")
        }
        return
      }

      timeLapseInterval = interval
      isTimeLapseActive = true
      timeLapseCount = 0

      timeLapseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
        self?.captureTimeLapsePhoto()
      }

      print("タイムラプス開始: \(interval)秒間隔")

      DispatchQueue.main.async {
        CameraManager.shared.isTimeLapseActive = true
        CameraManager.shared.timeLapseCount = 0
        CameraManager.shared.timeLapseInterval = interval
        CameraManager.shared.timeLapseStartedAt = Date()
        CameraManager.shared.onTimeLapseStarted?()
        WebSocketManager.shared.sendTimeLapseStarted(interval: interval)
      }
    }

    func stopTimeLapse() {
      guard isTimeLapseActive else { return }

      timeLapseTimer?.invalidate()
      timeLapseTimer = nil
      isTimeLapseActive = false

      let finalCount = timeLapseCount
      print("タイムラプス終了: \(finalCount)枚撮影")

      timeLapseCount = 0

      DispatchQueue.main.async {
        CameraManager.shared.isTimeLapseActive = false
        CameraManager.shared.timeLapseCount = 0
        CameraManager.shared.timeLapseStartedAt = nil
        CameraManager.shared.onTimeLapseStopped?(finalCount)
        WebSocketManager.shared.sendTimeLapseStopped(shotCount: finalCount)
      }
    }

    private func captureTimeLapsePhoto() {
      guard let photoOutput = photoOutput else { return }

      let settings = AVCapturePhotoSettings()
      photoOutput.capturePhoto(with: settings, delegate: self)
      timeLapseCount += 1

      print("タイムラプス写真撮影: \(timeLapseCount)枚目")

      let currentCount = timeLapseCount
      DispatchQueue.main.async {
        CameraManager.shared.timeLapseCount = currentCount
        WebSocketManager.shared.sendTimeLapseProgress(shotCount: currentCount)
      }
    }
  }
}
