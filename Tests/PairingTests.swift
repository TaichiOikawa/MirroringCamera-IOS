import XCTest
@testable import MirroringCamera

final class PairingTests: XCTestCase {
    private let valid = """
        {"v":1,"type":"camera-pairing","server_url":"http://192.168.1.10:3001/", "code":"k7f3a-9qmx2","expires_at":"2026-08-30T06:00:00Z"}
        """

    func testParsesControllerQR() throws {
        let payload = try XCTUnwrap(PairingPayload.parse(valid))
        XCTAssertEqual(payload.serverURL.absoluteString, "http://192.168.1.10:3001")
        XCTAssertEqual(payload.code, "K7F3A9QMX2")
        XCTAssertEqual(payload.expiresAt, "2026-08-30T06:00:00Z")
    }

    func testRejectsUnrelatedOrMalformedQR() {
        for text in ["", "https://example.com", "[]", "null", "not json",
                     valid.replacingOccurrences(of: "camera-pairing", with: "other"),
                     valid.replacingOccurrences(of: "\"v\":1", with: "\"v\":2"),
                     valid.replacingOccurrences(of: "\"v\":1", with: "\"v\":true"),
                     valid.replacingOccurrences(of: "\"v\":1", with: "\"v\":1.5"),
                     valid.replacingOccurrences(of: "k7f3a-9qmx2", with: "---"),
                     valid.replacingOccurrences(of: "http://192.168.1.10:3001/", with: "file:///tmp/key")] {
            XCTAssertNil(PairingPayload.parse(text), text)
        }
    }

    func testAcceptsFutureFieldsAndMissingExpiration() throws {
        let text = """
        {"v":1,"type":"camera-pairing","server_url":"cam.local:3001/api/", "code":"A B", "future":true}
        """
        let payload = try XCTUnwrap(PairingPayload.parse(text))
        XCTAssertEqual(payload.serverURL.absoluteString, "http://cam.local:3001/api")
        XCTAssertEqual(payload.code, "AB")
        XCTAssertNil(payload.expiresAt)
    }

    func testURLValidation() {
        XCTAssertEqual(PairingPayload.normalizedServerURL(" HTTPS://cam.example/path/// ")?.absoluteString,
                       "https://cam.example/path")
        for url in ["", "  ", "http://", "ftp://cam", "https://user:secret@cam", "https://cam?key=1", "https://cam#x"] {
            XCTAssertNil(PairingPayload.normalizedServerURL(url), url)
        }
    }

    func testClaimSendsDeviceAndUsesReturnedCredentials() async throws {
        let credentials = try await client(status: 200, body: """
          {"camera_id":"camera-new", "api_key":"camera-key", "server_url":"https://new.example/", "display_name":"ステージ"}
          """).claim(try XCTUnwrap(PairingPayload.parse(valid)), cameraID: "iphone-old", deviceName: "iPhone")
        XCTAssertEqual(credentials.cameraID, "camera-new")
        XCTAssertEqual(credentials.apiKey, "camera-key")
        XCTAssertEqual(credentials.serverURL.absoluteString, "https://new.example")
        XCTAssertEqual(credentials.displayName, "ステージ")
    }

    func testClaimKeepsQRURLIfServerOmitsURL() async throws {
        let payload = try XCTUnwrap(PairingPayload.parse(valid))
        let credentials = try await client(status: 200, body: """
          {"camera_id":"camera-new", "api_key":"camera-key"}
          """).claim(payload, cameraID: "iphone-old", deviceName: "iPhone")
        XCTAssertEqual(credentials.serverURL, payload.serverURL)
    }

    func testClaimMapsServerErrors() async throws {
        for status in [400, 404, 409, 410, 429, 500] {
            do {
                _ = try await client(status: status, body: "{\"detail\":\"サーバーエラー\"}")
                    .claim(try XCTUnwrap(PairingPayload.parse(valid)), cameraID: "iphone-old", deviceName: "iPhone")
                XCTFail("HTTP \(status) should fail")
            } catch let error as PairingError {
                XCTAssertEqual(error.errorDescription, PairingError.server(status, "サーバーエラー").errorDescription)
            }
        }
    }

    func testClaimRejectsIncompleteResponses() async throws {
        for body in ["{}", "[]", "invalid", "{\"camera_id\":\"x\",\"api_key\":\" \"}",
                     "{\"camera_id\":\"x\",\"api_key\":\"key\",\"server_url\":\"ftp://cam\"}"] {
            do {
                _ = try await client(status: 200, body: body)
                    .claim(try XCTUnwrap(PairingPayload.parse(valid)), cameraID: "iphone-old", deviceName: "iPhone")
                XCTFail("Incomplete response should fail")
            } catch let error as PairingError {
                XCTAssertEqual(error.errorDescription, PairingError.invalidResponse.errorDescription)
            }
        }
    }

    private func client(status: Int, body: String) -> PairingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PairingURLProtocol.self]
        PairingURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/pairing/K7F3A9QMX2/claim")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    collected.append(buffer, count: count)
                }
                data = collected
            }
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: String]
            XCTAssertEqual(json?["camera_id"], "iphone-old")
            XCTAssertEqual(json?["device_name"], "iPhone")
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        return PairingClient(session: URLSession(configuration: config))
    }
}

private final class PairingURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
