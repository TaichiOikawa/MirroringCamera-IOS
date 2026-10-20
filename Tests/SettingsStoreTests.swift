import Combine
import XCTest
@testable import MirroringCamera

@MainActor
final class SettingsStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "MirroringCameraTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testMigratesExistingSettingsAndKeepsCameraID() async {
        let defaults = defaults()
        defaults.set("https://old.example", forKey: "apiBaseURL")
        defaults.set("iphone-existing", forKey: "cameraID")
        defaults.set("old-key", forKey: "apiKey")
        defaults.set(0.5, forKey: "previewInterval")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.cameraID, "iphone-existing")
        XCTAssertEqual(settings.apiBaseURL, "https://old.example")
        XCTAssertEqual(settings.apiKey, "old-key")
        XCTAssertEqual(settings.previewInterval, 0.5)
        XCTAssertTrue(settings.isConfigured)
    }

    func testPairingPublishesOnceAndPersistsWholeSet() async {
        let defaults = defaults()
        let settings = SettingsStore(defaults: defaults)
        var publications = 0
        let observer = settings.objectWillChange.sink { publications += 1 }
        settings.applyPairing(PairingCredentials(serverURL: URL(string: "https://new.example/base")!,
                                                cameraID: "new-camera", displayName: nil, apiKey: "new-key"))
        XCTAssertEqual(publications, 1)
        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.cameraID, "new-camera")
        XCTAssertEqual(restored.apiBaseURL, "https://new.example/base")
        XCTAssertEqual(restored.apiKey, "new-key")
        withExtendedLifetime(observer) {}
    }

    func testWebSocketURLPreservesPathAndEscapesCredentials() async throws {
        let settings = SettingsStore(defaults: defaults())
        settings.apiBaseURL = "https://cam.example/base/"
        settings.cameraID = "iphone/a?b"
        settings.apiKey = "a+b&c=d#e"
        let url = try XCTUnwrap(settings.wsURL)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertTrue(url.absoluteString.contains("/base/ws/camera/iphone%2Fa%3Fb"))
        XCTAssertTrue(url.absoluteString.contains("%2B"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a+b&c=d#e")
    }

    func testMissingKeyOrInvalidServerCannotConnect() async {
        let settings = SettingsStore(defaults: defaults())
        settings.apiBaseURL = "cam.local:3001"
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNil(settings.wsURL)
        settings.apiKey = "key"
        XCTAssertEqual(settings.wsURL?.scheme, "ws")
        settings.apiBaseURL = "ftp://cam"
        XCTAssertFalse(settings.isConfigured)
        XCTAssertNil(settings.wsURL)
    }
}
