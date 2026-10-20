import AVFoundation
import Foundation
import Vision

/// Shares the existing camera output. Opening/closing the scanner never reconfigures the session.
final class QRFrameScanner {
    typealias Decoder = (CMSampleBuffer) throws -> [String]
    private let queue = DispatchQueue(label: "com.mirroringcamera.qr", qos: .userInitiated)
    private let lock = NSLock()
    private let render: (CMSampleBuffer) -> Void
    private let decode: Decoder
    private let onCode: (String) -> Void
    private var stopped = false
    private var scanningEnabled = true
    private var inFlight = false
    private var generation: UInt64 = 0
    private var lastScanAt: TimeInterval = -.infinity

    init(render: @escaping (CMSampleBuffer) -> Void, decode: @escaping Decoder = QRFrameScanner.decodeQR,
         onCode: @escaping (String) -> Void) {
        self.render = render
        self.decode = decode
        self.onCode = onCode
    }

    func setScanningEnabled(_ enabled: Bool) {
        lock.lock()
        if scanningEnabled != enabled {
            scanningEnabled = enabled
            generation &+= 1
            lastScanAt = -.infinity
        }
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        generation &+= 1
        lock.unlock()
    }

    func consume(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        let shouldScan = scanningEnabled && !inFlight && now - lastScanAt >= 0.2
        let currentGeneration = generation
        if shouldScan { inFlight = true; lastScanAt = now }
        lock.unlock()

        // Preview stays live while claiming or displaying an error.
        render(sampleBuffer)
        guard shouldScan else { return }
        queue.async {
            defer {
                self.lock.lock()
                self.inFlight = false
                self.lock.unlock()
            }
            guard self.isCurrent(currentGeneration),
                  let values = try? self.decode(sampleBuffer),
                  let value = values.first(where: { PairingPayload.parse($0) != nil }) else { return }
            DispatchQueue.main.async {
                guard self.isCurrent(currentGeneration) else { return }
                self.onCode(value)
            }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && scanningEnabled && generation == value
    }

    static func decodeQR(_ sampleBuffer: CMSampleBuffer) throws -> [String] {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return [] }
        let request = VNDetectBarcodesRequest()
        #if targetEnvironment(simulator)
        // Use the non-ML barcode detector on Simulator; device builds keep the current detector.
        request.revision = VNDetectBarcodesRequestRevision1
        #endif
        request.symbologies = [.qr]
        // The shared video connection already rotates the pixels into display orientation.
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
        return request.results?.compactMap(\.payloadStringValue) ?? []
    }
}
