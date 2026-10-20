import Foundation
import CoreFoundation

struct PairingPayload: Equatable {
    let serverURL: URL
    let code: String
    let expiresAt: String?

    static func parse(_ text: String) -> PairingPayload? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "camera-pairing",
              let version = root["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let rawURL = root["server_url"] as? String,
              let url = normalizedServerURL(rawURL),
              let rawCode = root["code"] as? String else { return nil }
        let code = rawCode.filter { $0.isLetter || $0.isNumber }.uppercased()
        guard !code.isEmpty else { return nil }
        return PairingPayload(serverURL: url, code: code, expiresAt: root["expires_at"] as? String)
    }

    static func normalizedServerURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let value = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var components = URLComponents(string: value),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = components.scheme?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }
}

struct PairingCredentials: Equatable {
    let serverURL: URL
    let cameraID: String
    let displayName: String?
    let apiKey: String
}

enum PairingError: LocalizedError {
    case invalidResponse
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "サーバーの応答が不正です"
        case .server(let status, let detail):
            switch status {
            case 400: return "カメラIDが不正です"
            case 404: return "このQRコードは無効です。管理画面で再発行してください"
            case 409: return "このQRコードは既に使用済みです。再発行してください"
            case 410: return "QRコードの有効期限が切れています。再発行してください"
            case 429: return "試行回数が多すぎます。しばらく待ってからお試しください"
            default: return detail ?? "接続に失敗しました（HTTP \(status)）"
            }
        }
    }
}

struct PairingClient {
    var session: URLSession = .shared

    func claim(_ payload: PairingPayload, cameraID: String, deviceName: String) async throws -> PairingCredentials {
        let url = payload.serverURL.appendingPathComponent("api/pairing")
            .appendingPathComponent(payload.code).appendingPathComponent("claim")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "camera_id": cameraID, "device_name": deviceName
        ])
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PairingError.invalidResponse }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(response.statusCode) else {
            throw PairingError.server(response.statusCode, root?["detail"] as? String)
        }
        guard let root, let key = root["api_key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let cameraID = root["camera_id"] as? String, !cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let serverURL = PairingPayload.normalizedServerURL(root["server_url"] as? String ?? payload.serverURL.absoluteString)
        else { throw PairingError.invalidResponse }
        return PairingCredentials(serverURL: serverURL, cameraID: cameraID.trimmingCharacters(in: .whitespacesAndNewlines),
                                  displayName: root["display_name"] as? String, apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
