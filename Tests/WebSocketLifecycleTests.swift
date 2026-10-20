import Combine
import XCTest
@testable import MirroringCamera

@MainActor
final class WebSocketLifecycleTests: XCTestCase {
    func testDisconnectInvalidatesPendingRegistration() async throws {
        let started = expectation(description: "Registration started")
        let socket = makeSocket { started.fulfill() }
        socket.connect()
        await fulfillment(of: [started], timeout: 2)
        socket.disconnect()
        var reopened = false
        let observer = socket.$isConnecting.dropFirst().sink { if $0 { reopened = true } }
        // URLSession delivers the canceled registration's completion asynchronously.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(socket.isConnecting)
        XCTAssertFalse(socket.isConnected)
        XCTAssertFalse(reopened)
        withExtendedLifetime(observer) {}
    }

    func testDuplicateConnectDoesNotStartAnotherRegistration() async throws {
        let started = expectation(description: "Only one registration")
        started.assertForOverFulfill = true
        let socket = makeSocket { started.fulfill() }
        defer { socket.disconnect() }
        socket.connect()
        socket.connect()
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(socket.isConnecting)
    }

    func testForegroundDoesNotOverrideManualDisconnect() async throws {
        let unexpected = expectation(description: "No registration after manual disconnect")
        unexpected.isInverted = true
        let socket = makeSocket { unexpected.fulfill() }
        socket.disconnect()
        socket.onForegroundResume()
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertFalse(socket.isConnecting)
    }

    private func makeSocket(onStart: @escaping () -> Void) -> WebSocketManager {
        let name = "MirroringSocketTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.apiBaseURL = "https://cam.invalid"
        settings.apiKey = "test-key"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PendingRegistrationProtocol.self]
        PendingRegistrationProtocol.onStart = onStart
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return WebSocketManager(settings: settings, registrationSession: session)
    }
}

private final class PendingRegistrationProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() {}
}
