import AVFoundation
import SwiftUI

struct CameraView: UIViewRepresentable {
  @Binding var isScreenLocked: Bool

  func makeCoordinator() -> Coordinator {
    return Coordinator(session: nil)
  }

  func makeUIView(context: Context) -> CameraUIView {
    let view = CameraUIView()
    view.backgroundColor = .black
    view.coordinator = context.coordinator
    context.coordinator.cameraUIView = view

    // CameraManagerにCoordinatorを設定
    CameraManager.shared.coordinator = context.coordinator

    checkPermissions { [weak view] authorized in
      guard authorized, let view = view else {
        DispatchQueue.main.async {
          view?.showError(message: "カメラまたはマイクの使用許可が必要です")
        }
        return
      }

      DispatchQueue.main.async {
        self.setupCamera(view: view, coordinator: context.coordinator)
      }
    }

    return view
  }

  private func checkPermissions(completion: @escaping (Bool) -> Void) {
    let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    if cameraStatus == .authorized && microphoneStatus == .authorized {
      completion(true)
      return
    }

    if cameraStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { videoGranted in
        if videoGranted {
          if microphoneStatus == .authorized {
            completion(true)
          } else if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
              completion(audioGranted)
            }
          } else {
            completion(false)
          }
        } else {
          completion(false)
        }
      }
    } else if microphoneStatus == .notDetermined {
      AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
        completion(cameraStatus == .authorized && audioGranted)
      }
    } else {
      completion(false)
    }
  }

  private func setupCamera(view: CameraUIView, coordinator: Coordinator) {
    let session = AVCaptureSession()
    session.sessionPreset = .high

    guard
      let videoDevice = AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .back),
      let videoInput = try? AVCaptureDeviceInput(device: videoDevice),
      session.canAddInput(videoInput)
    else {
      print("ビデオデバイスが利用できません")
      view.showError(message: "カメラが利用できません")
      return
    }
    session.addInput(videoInput)

    if let audioDevice = AVCaptureDevice.default(for: .audio),
      let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
      session.canAddInput(audioInput)
    {
      session.addInput(audioInput)
    } else {
      print("オーディオデバイスの追加に失敗しました")
    }

    let movieOutput = AVCaptureMovieFileOutput()
    if session.canAddOutput(movieOutput) {
      session.addOutput(movieOutput)
      coordinator.movieOutput = movieOutput
    }

    let photoOutput = AVCapturePhotoOutput()
    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      coordinator.photoOutput = photoOutput
    }

    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.videoGravity = .resizeAspectFill
    view.layer.addSublayer(previewLayer)
    view.previewLayer = previewLayer

    DispatchQueue.global(qos: .userInitiated).async {
      session.startRunning()

      DispatchQueue.main.async {
        coordinator.updateOutputConnections()
        view.setupPreviewLayerOrientation()
      }
    }

    coordinator.session = session

    // 外部ディスプレイ用にセッションを共有
    Task { @MainActor in
      ExternalDisplayStore.shared.setSession(session)
    }
  }

  func updateUIView(_ uiView: CameraUIView, context: Context) {
    uiView.isScreenLocked = isScreenLocked
    // 外部ディスプレイにもロック状態を同期
    Task { @MainActor in
      ExternalDisplayStore.shared.isScreenLocked = isScreenLocked
    }
  }
}
