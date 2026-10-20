import AVFoundation
import ImageIO
import XCTest
@testable import MirroringCamera

final class QRFrameScannerTests: XCTestCase {
    private let payload = """
        {"v":1,"type":"camera-pairing","server_url":"https://cam.example","code":"ABCDE12345"}
        """

    func testVisionDecodesControllerQRFromSharedFrame() throws {
        let sample = try makeQRFrame()
        XCTAssertTrue(try QRFrameScanner.decodeQR(sample).contains(payload))
    }

    @MainActor
    func testDecodeRunsOffMainThreadAndReturnsCodeOnMainThread() async throws {
        let found = expectation(description: "Decoded camera QR")
        var rendered = false
        let scanner = QRFrameScanner(render: { _ in rendered = true }, decode: { _ in
            XCTAssertFalse(Thread.isMainThread)
            return ["https://unrelated.example", self.payload]
        }, onCode: { code in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(code, self.payload)
            found.fulfill()
        })
        defer { scanner.stop() }
        scanner.consume(try makeQRFrame())
        XCTAssertTrue(rendered)
        await fulfillment(of: [found], timeout: 3)
    }

    @MainActor
    func testSlowDecodeDoesNotBlockPreviewOrQueueMoreFrames() async throws {
        let started = expectation(description: "One decode")
        started.assertForOverFulfill = true
        let released = expectation(description: "Decode released")
        let gate = DispatchSemaphore(value: 0)
        var renderCount = 0
        let scanner = QRFrameScanner(render: { _ in renderCount += 1 }, decode: { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            released.fulfill()
            return []
        }, onCode: { _ in XCTFail("No QR was decoded") })
        defer { scanner.stop(); gate.signal() }
        let sample = try makeQRFrame()
        scanner.consume(sample)
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        for _ in 0..<10 { scanner.consume(sample) }
        XCTAssertEqual(renderCount, 11)
        gate.signal()
        await fulfillment(of: [released], timeout: 2)
    }

    @MainActor
    func testClosingScannerDropsPendingDecodeAndStopsPreview() async throws {
        let started = expectation(description: "Decode started")
        let released = expectation(description: "Decode released")
        let unwanted = expectation(description: "No late result")
        unwanted.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        var renderCount = 0
        let scanner = QRFrameScanner(render: { _ in renderCount += 1 }, decode: { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            released.fulfill()
            return [self.payload]
        }, onCode: { _ in unwanted.fulfill() })
        defer { gate.signal() }
        let sample = try makeQRFrame()
        scanner.consume(sample)
        await fulfillment(of: [started], timeout: 2)
        scanner.stop()
        scanner.consume(sample)
        XCTAssertEqual(renderCount, 1)
        gate.signal()
        await fulfillment(of: [released], timeout: 2)
        await fulfillment(of: [unwanted], timeout: 0.1)
    }

    @MainActor
    func testPauseKeepsPreviewLiveAndInvalidatesOldDecodeAfterRetry() async throws {
        let started = expectation(description: "Decode started")
        let released = expectation(description: "Decode released")
        let unwanted = expectation(description: "Old result ignored after retry")
        unwanted.isInverted = true
        let gate = DispatchSemaphore(value: 0)
        var renderCount = 0
        let scanner = QRFrameScanner(render: { _ in renderCount += 1 }, decode: { _ in
            started.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            released.fulfill()
            return [self.payload]
        }, onCode: { _ in unwanted.fulfill() })
        defer { scanner.stop(); gate.signal() }
        let sample = try makeQRFrame()
        scanner.consume(sample)
        await fulfillment(of: [started], timeout: 2)
        scanner.setScanningEnabled(false)
        scanner.consume(sample)
        XCTAssertEqual(renderCount, 2)
        scanner.setScanningEnabled(true)
        gate.signal()
        await fulfillment(of: [released], timeout: 2)
        await fulfillment(of: [unwanted], timeout: 0.1)
    }

    private func makeQRFrame() throws -> CMSampleBuffer {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: QRFrameScannerTests.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "PairingQR", withExtension: "png"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                                  formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                        formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
