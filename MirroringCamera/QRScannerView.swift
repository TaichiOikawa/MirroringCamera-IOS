import AVFoundation
import SwiftUI

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPaired: (PairingCredentials) -> Void
    @State private var isClaiming = false
    @State private var errorMessage: String?
    @State private var succeeded: PairingCredentials?
    @State private var claimTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                QRScannerPreview(enabled: !isClaiming && errorMessage == nil && succeeded == nil,
                                 onCode: claim, onError: { errorMessage = $0 })
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    Text("CameraControllerの管理画面に表示された\nQRコードを読み取ってください")
                        .multilineTextAlignment(.center)
                        .padding().background(.black.opacity(0.7)).foregroundStyle(.white)
                    Spacer()
                    RoundedRectangle(cornerRadius: 16).stroke(.white, lineWidth: 3)
                        .frame(width: 240, height: 240).allowsHitTesting(false)
                    Spacer()
                    if isClaiming {
                        ProgressView("接続情報を取得中…").tint(.white).foregroundStyle(.white)
                    } else if let credentials = succeeded {
                        VStack(spacing: 12) {
                            Label("接続情報を保存しました", systemImage: "checkmark.circle.fill")
                            Text(credentials.displayName ?? credentials.cameraID)
                            Button("完了") { dismiss() }.buttonStyle(.borderedProminent)
                        }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let errorMessage {
                        VStack(spacing: 12) {
                            Text(errorMessage).multilineTextAlignment(.center)
                            Button("再読み取り") { self.errorMessage = nil }.buttonStyle(.borderedProminent)
                        }.padding().background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }.padding()
            }
            .navigationTitle("QRコードで接続")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
        .onDisappear { claimTask?.cancel() }
    }

    private func claim(_ text: String) {
        guard !isClaiming, errorMessage == nil, succeeded == nil,
              let payload = PairingPayload.parse(text) else { return }
        isClaiming = true
        let cameraID = SettingsStore.shared.cameraID
        let deviceName = UIDevice.current.name
        claimTask = Task { @MainActor in
            do {
                let credentials = try await PairingClient().claim(payload, cameraID: cameraID, deviceName: deviceName)
                try Task.checkCancellation()
                onPaired(credentials)
                succeeded = credentials
            } catch is CancellationError {
                // Closing the scanner never applies credentials from a late response.
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = (error as? PairingError)?.errorDescription
                    ?? "サーバーに接続できません（\(payload.serverURL.absoluteString)）"
            }
            isClaiming = false
        }
    }
}

private struct QRScannerPreview: UIViewRepresentable {
    let enabled: Bool
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onError: onError) }

    func makeUIView(context: Context) -> ScannerUIView {
        let view = ScannerUIView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: ScannerUIView, context: Context) {
        let retry = enabled && !context.coordinator.enabled
        context.coordinator.enabled = enabled
        if retry { context.coordinator.retryAttach(to: view) }
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: ScannerUIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        var enabled = true {
            didSet { scanner?.setScanningEnabled(enabled) }
        }
        private var scanner: QRFrameScanner?
        private let onCode: (String) -> Void
        private let onError: (String) -> Void

        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
        }

        func retryAttach(to view: ScannerUIView) {
            if scanner == nil { attach(to: view) }
        }

        func attach(to view: ScannerUIView) {
            guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                  CameraManager.shared.captureSession != nil else {
                DispatchQueue.main.async { self.onError("カメラを開始できません。カメラの使用許可を確認し、撮影画面から開き直してください") }
                return
            }
            // Use the existing sample buffers for preview and QR detection. No capture outputs
            // or preview connections are added while the sheet is being presented.
            let layer = view.displayLayer
            let scanner = QRFrameScanner(render: { [weak layer] sampleBuffer in
                guard let layer else { return }
                if layer.status == .failed { layer.flush() }
                if layer.isReadyForMoreMediaData { layer.enqueue(sampleBuffer) }
            }, onCode: onCode)
            scanner.setScanningEnabled(enabled)
            self.scanner = scanner
            ExternalDisplayStore.shared.startQRScanning(scanner)
        }

        func detach() {
            enabled = false
            if let scanner {
                scanner.stop()
                ExternalDisplayStore.shared.stopQRScanning(scanner)
            }
            scanner = nil
        }
    }
}

private final class ScannerUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
