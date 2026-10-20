import AVFoundation
import Combine
import UIKit

@MainActor
final class ExternalDisplayStore: ObservableObject {
    static let shared = ExternalDisplayStore()

    @Published var isExternalDisplayConnected = false

    /// 画面回転ロック状態（CameraUIView と同期）
    var isScreenLocked: Bool {
        get { outputDelegate.isScreenLocked }
        set { outputDelegate.isScreenLocked = newValue }
    }

    private var videoOutput: AVCaptureVideoDataOutput?
    private let outputQueue = DispatchQueue(label: "com.mirroringcamera.externalDisplay")
    private let outputDelegate = VideoOutputDelegate()
    private weak var session: AVCaptureSession?
    private weak var pendingView: ExternalCameraView?
    private var subscriptions = Set<AnyCancellable>()

    private init() {
        SettingsStore.shared.$previewInterval.combineLatest(WebSocketManager.shared.$isConnected)
            .sink { [weak self] interval, connected in
                self?.outputDelegate.configurePreview(enabled: connected, interval: interval)
            }.store(in: &subscriptions)
    }

    /// カメラセッションを設定（CameraView側から呼び出す）
    func setSession(_ session: AVCaptureSession) {
        self.session = session

        // WebSocket プレビュー送信用に常時ビデオ出力を追加
        setupVideoOutput(for: session)

        // 外部ディスプレイが先に接続されていた場合、ミラーリングを開始
        if let view = pendingView {
            pendingView = nil
            startMirroring(to: view)
        }
    }

    /// ビデオ出力を追加（プレビュー送信 + 外部ディスプレイ共用）
    private func setupVideoOutput(for session: AVCaptureSession) {
        // 既に追加済みなら何もしない
        if videoOutput != nil { return }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(outputDelegate, queue: outputQueue)

        session.beginConfiguration()
        if session.canAddOutput(output) {
            session.addOutput(output)
            videoOutput = output
            outputDelegate.videoOutput = output

            if let connection = output.connection(with: .video) {
                Self.applyCurrentOrientation(to: connection)
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }
            }
        }
        session.commitConfiguration()

        // デバイスの回転を監視
        NotificationCenter.default.addObserver(
            outputDelegate,
            selector: #selector(VideoOutputDelegate.orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    /// 外部ディスプレイへのミラーリングを開始
    func startMirroring(to view: ExternalCameraView) {
        guard let session = session else {
            pendingView = view
            return
        }

        // ビデオ出力がまだなければ追加
        setupVideoOutput(for: session)

        outputDelegate.displayLayer = view.displayLayer
    }

    /// 外部ディスプレイへのミラーリングを停止
    func stopMirroring() {
        outputDelegate.displayLayer = nil
        pendingView = nil
    }

    func startQRScanning(_ scanner: QRFrameScanner) {
        outputDelegate.setQRScanner(scanner)
    }

    func stopQRScanning(_ scanner: QRFrameScanner) {
        outputDelegate.removeQRScanner(scanner)
    }

    /// 現在のデバイス向きをコネクションに適用
    static func applyCurrentOrientation(to connection: AVCaptureConnection) {
        let deviceOrientation = UIDevice.current.orientation
        if #available(iOS 17.0, *) {
            let angle: CGFloat
            switch deviceOrientation {
            case .portrait:            angle = 90
            case .portraitUpsideDown:   angle = 270
            case .landscapeLeft:        angle = 0
            case .landscapeRight:       angle = 180
            default:
                // .unknown / .faceUp / .faceDown → UIWindowScene から推定
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first {
                    switch scene.interfaceOrientation {
                    case .portrait:            angle = 90
                    case .portraitUpsideDown:   angle = 270
                    case .landscapeLeft:        angle = 180
                    case .landscapeRight:       angle = 0
                    default:                   angle = 90
                    }
                } else {
                    angle = 90
                }
            }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        } else {
            guard connection.isVideoOrientationSupported else { return }
            switch deviceOrientation {
            case .portrait:            connection.videoOrientation = .portrait
            case .portraitUpsideDown:   connection.videoOrientation = .portraitUpsideDown
            case .landscapeLeft:        connection.videoOrientation = .landscapeRight
            case .landscapeRight:       connection.videoOrientation = .landscapeLeft
            default:
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first {
                    switch scene.interfaceOrientation {
                    case .portrait:            connection.videoOrientation = .portrait
                    case .portraitUpsideDown:   connection.videoOrientation = .portraitUpsideDown
                    case .landscapeLeft:        connection.videoOrientation = .landscapeLeft
                    case .landscapeRight:       connection.videoOrientation = .landscapeRight
                    default:                   connection.videoOrientation = .portrait
                    }
                } else {
                    connection.videoOrientation = .portrait
                }
            }
        }
    }
}

// ビデオフレームを外部ディスプレイに転送するデリゲート
private class VideoOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var displayLayer: AVSampleBufferDisplayLayer?
    weak var videoOutput: AVCaptureVideoDataOutput?
    var isScreenLocked = false

    /// プレビュー送信用のスロットリング
    private var lastPreviewSentAt: TimeInterval = -.infinity
    private let imageContext = CIContext()
    private let settingsLock = NSLock()
    private var fallbackInterval: TimeInterval = 1
    private var previewEnabled = false
    private var previewGeneration: UInt64 = 0
    private var qrScanner: QRFrameScanner?

    func setQRScanner(_ scanner: QRFrameScanner) {
        settingsLock.lock()
        let previous = qrScanner
        qrScanner = scanner
        settingsLock.unlock()
        previous?.stop()
    }

    func removeQRScanner(_ scanner: QRFrameScanner) {
        settingsLock.lock()
        if qrScanner === scanner { qrScanner = nil }
        settingsLock.unlock()
    }

    func configurePreview(enabled: Bool, interval: TimeInterval) {
        settingsLock.lock()
        previewGeneration &+= 1
        previewEnabled = enabled
        fallbackInterval = interval
        settingsLock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 外部ディスプレイへの表示
        if let layer = displayLayer {
            if layer.status == .failed {
                layer.flush()
            }
            layer.enqueue(sampleBuffer)
        }

        settingsLock.lock()
        let scanner = qrScanner
        settingsLock.unlock()
        scanner?.consume(sampleBuffer)

        WebRTCManager.shared.pushFrame(sampleBuffer)

        settingsLock.lock()
        let enabled = previewEnabled
        let interval = fallbackInterval
        let generation = previewGeneration
        settingsLock.unlock()
        guard enabled, WebRTCManager.shared.isFallbackActive else { return }

        // JPEG covers unavailable viewers even when another viewer is connected.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPreviewSentAt >= interval else { return }
        lastPreviewSentAt = now

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: imageBuffer)
        let scale = min(1, 640 / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = imageContext.createCGImage(scaled, from: scaled.extent),
              let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.3) else { return }
        Task { @MainActor in
            // A connection can recover while the frame is being encoded.
            guard self.isCurrentPreview(generation), WebRTCManager.shared.isFallbackActive else { return }
            WebSocketManager.shared.sendPreview(imageData: jpegData)
        }
    }

    private func isCurrentPreview(_ generation: UInt64) -> Bool {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return previewEnabled && previewGeneration == generation
    }

    @objc func orientationDidChange() {
        // 画面ロック中は外部ディスプレイの向きも変更しない
        if isScreenLocked { return }
        // faceUp/faceDown/unknown は実際の画面向きが変わっていないので無視
        let orientation = UIDevice.current.orientation
        guard orientation == .portrait || orientation == .portraitUpsideDown
           || orientation == .landscapeLeft || orientation == .landscapeRight else { return }
        guard let connection = videoOutput?.connection(with: .video) else { return }
        Task { @MainActor in
            ExternalDisplayStore.applyCurrentOrientation(to: connection)
        }
    }
}
