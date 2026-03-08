import Foundation
import UIKit

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let apiBaseURL = "apiBaseURL"
        static let cameraID = "cameraID"
        static let previewInterval = "previewInterval"
        static let apiKey = "apiKey"
    }

    @Published var apiBaseURL: String {
        didSet { defaults.set(apiBaseURL, forKey: Keys.apiBaseURL) }
    }

    @Published var cameraID: String {
        didSet { defaults.set(cameraID, forKey: Keys.cameraID) }
    }

    /// プレビュー送信間隔（秒）
    @Published var previewInterval: TimeInterval {
        didSet { defaults.set(previewInterval, forKey: Keys.previewInterval) }
    }

    /// Camera API Key（認証用）
    @Published var apiKey: String {
        didSet { defaults.set(apiKey, forKey: Keys.apiKey) }
    }

    /// 選択肢として表示する間隔一覧
    static let previewIntervalOptions: [(TimeInterval, String)] = [
        (0.5, "0.5秒"),
        (1.0, "1秒"),
        (1.5, "1.5秒"),
        (2.0, "2秒")
    ]

    var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// WebSocket 接続用 URL
    var wsURL: URL? {
        let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        // http -> ws, https -> wss
        var wsBase = base
        if wsBase.hasPrefix("https://") {
            wsBase = "wss://" + wsBase.dropFirst("https://".count)
        } else if wsBase.hasPrefix("http://") {
            wsBase = "ws://" + wsBase.dropFirst("http://".count)
        } else {
            wsBase = "ws://" + wsBase
        }
        // 末尾スラッシュを除去
        if wsBase.hasSuffix("/") {
            wsBase = String(wsBase.dropLast())
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return URL(string: "\(wsBase)/ws/camera/\(cameraID)?api_key=\(key)")
    }

    /// REST API ベース URL
    var restBaseURL: URL? {
        let base = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        var urlString = base
        if urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }
        // scheme が無ければ http:// を付与
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "http://" + urlString
        }
        return URL(string: urlString)
    }

    private init() {
        self.apiBaseURL = defaults.string(forKey: Keys.apiBaseURL) ?? ""
        self.apiKey = defaults.string(forKey: Keys.apiKey) ?? ""
        self.previewInterval = defaults.object(forKey: Keys.previewInterval) as? TimeInterval ?? 1.0

        if let savedID = defaults.string(forKey: Keys.cameraID), !savedID.isEmpty {
            self.cameraID = savedID
        } else {
            let uuid = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            // 先頭8文字を使って読みやすい ID にする
            let shortID = String(uuid.prefix(8)).lowercased()
            let generatedID = "iphone-\(shortID)"
            self.cameraID = generatedID
            defaults.set(generatedID, forKey: Keys.cameraID)
        }
    }
}
