import AVFoundation
import SwiftUI

class CameraUIView: UIView {
  var previewLayer: AVCaptureVideoPreviewLayer?
  var coordinator: CameraView.Coordinator?
  var isScreenLocked: Bool = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupOrientationObserver()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupOrientationObserver()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func setupOrientationObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(orientationDidChange),
      name: UIDevice.orientationDidChangeNotification,
      object: nil
    )
  }

  @objc private func orientationDidChange() {
    updatePreviewLayerOrientation()
  }

  private func updatePreviewLayerOrientation() {
    guard !isScreenLocked else { return }
    guard let connection = previewLayer?.connection,
          connection.isVideoOrientationSupported else { return }
    connection.videoOrientation = currentVideoOrientation()
  }

  /// デバイスの向きから videoOrientation を決定する。
  /// UIDevice.current.orientation は .unknown を返すことがあるため、
  /// フォールバックとして UIWindowScene の interfaceOrientation を使う。
  func currentVideoOrientation() -> AVCaptureVideoOrientation {
    let deviceOrientation = UIDevice.current.orientation
    switch deviceOrientation {
    case .portrait:           return .portrait
    case .portraitUpsideDown: return .portraitUpsideDown
    case .landscapeLeft:      return .landscapeRight
    case .landscapeRight:     return .landscapeLeft
    default:
      // .unknown / .faceUp / .faceDown の場合、UIWindowScene から取得
      if let scene = self.window?.windowScene ?? UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene }).first {
        switch scene.interfaceOrientation {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:      return .landscapeLeft
        case .landscapeRight:     return .landscapeRight
        default:                  return .portrait
        }
      }
      return .portrait
    }
  }

  func setupPreviewLayerOrientation() {
    updatePreviewLayerOrientation()
  }

  func showError(message: String) {
    let alert = UIAlertController(title: "エラー", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))

    if let viewController = self.findViewController() {
      viewController.present(alert, animated: true)
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    previewLayer?.frame = bounds
    updatePreviewLayerOrientation()
  }
}
