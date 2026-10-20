import Foundation
import UIKit

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private let defaults: UserDefaults

    private enum Keys {
        static let connection = "connectionCredentials"
        static let apiBaseURL = "apiBaseURL"
        static let cameraID = "cameraID"
        static let previewInterval = "previewInterval"
        static let apiKey = "apiKey"
    }

    private struct Connection {
        var apiBaseURL: String
        var cameraID: String
        var apiKey: String
        var dictionary: [String: String] {
            [Keys.apiBaseURL: apiBaseURL, Keys.cameraID: cameraID, Keys.apiKey: apiKey]
        }
    }

    // One publication and one persisted value for a complete set of credentials.
    @Published private var connection: Connection {
        didSet { defaults.set(connection.dictionary, forKey: Keys.connection) }
    }

    var apiBaseURL: String {
        get { connection.apiBaseURL }
        set { connection.apiBaseURL = newValue }
    }
    var cameraID: String {
        get { connection.cameraID }
        set { connection.cameraID = newValue }
    }
    var apiKey: String {
        get { connection.apiKey }
        set { connection.apiKey = newValue }
    }

    @Published var previewInterval: TimeInterval {
        didSet { defaults.set(previewInterval, forKey: Keys.previewInterval) }
    }

    static let previewIntervalOptions: [(TimeInterval, String)] = [
        (0.5, "0.5秒"), (1.0, "1秒"), (1.5, "1.5秒"), (2.0, "2秒")
    ]

    var isConfigured: Bool {
        restBaseURL != nil && !cameraID.isEmpty && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var wsURL: URL? {
        guard let base = restBaseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cameraID.isEmpty else { return nil }
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard let id = cameraID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        components.percentEncodedPath += "/ws/camera/" + id
        components.queryItems = [URLQueryItem(name: "api_key", value: key)]
        // Many servers decode queries as form data; a literal '+' must stay a plus.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    var restBaseURL: URL? { PairingPayload.normalizedServerURL(apiBaseURL) }

    func applyPairing(_ credentials: PairingCredentials) {
        connection = Connection(apiBaseURL: credentials.serverURL.absoluteString,
                                cameraID: credentials.cameraID, apiKey: credentials.apiKey)
    }

    // Injectable defaults allow migration/persistence tests without touching user settings.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Keys.connection) as? [String: String]
        let savedID = saved?[Keys.cameraID] ?? defaults.string(forKey: Keys.cameraID)
        let cameraID: String
        if let savedID, !savedID.isEmpty { cameraID = savedID }
        else {
            let uuid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            cameraID = "iphone-" + String(uuid.prefix(8)).lowercased()
        }
        connection = Connection(apiBaseURL: saved?[Keys.apiBaseURL] ?? defaults.string(forKey: Keys.apiBaseURL) ?? "",
                                cameraID: cameraID,
                                apiKey: saved?[Keys.apiKey] ?? defaults.string(forKey: Keys.apiKey) ?? "")
        previewInterval = defaults.object(forKey: Keys.previewInterval) as? TimeInterval ?? 1
        defaults.set(connection.dictionary, forKey: Keys.connection)
    }
}
