import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var wsManager = WebSocketManager.shared

    @State private var editingURL: String = ""
    @State private var editingAPIKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - サーバー設定
                Section {
                    TextField("URL", text: $editingURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onSubmit {
                            saveSettings()
                        }
                } header: {
                    Text("CameraController API URL")
                } footer: {
                    Text("サーバーのアドレスを入力してください（例: http://192.168.10.5/）")
                }

                // MARK: - API Key
                Section {
                    SecureField("API Key", text: $editingAPIKey)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onSubmit {
                            saveSettings()
                        }
                } header: {
                    Text("Camera API Key")
                } footer: {
                    Text("コントロール画面から発行した Camera API Key を入力してください")
                }

                // MARK: - 接続操作
                Section {
                    HStack {
                        Text("状態")
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(wsManager.isConnected ? Color.green : (wsManager.isConnecting ? Color.orange : Color.red))
                                .frame(width: 10, height: 10)
                            Text(wsManager.isConnected ? "接続中" : (wsManager.isConnecting ? "接続中..." : "未接続"))
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = wsManager.lastError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if wsManager.isConnected {
                        Button(role: .destructive) {
                            wsManager.disconnect()
                        } label: {
                            HStack {
                                Spacer()
                                Text("切断")
                                Spacer()
                            }
                        }
                    } else {
                        Button {
                            saveSettings()
                            wsManager.connect()
                        } label: {
                            HStack {
                                Spacer()
                                Text("接続")
                                Spacer()
                            }
                        }
                        .disabled(
                            editingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || editingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                } header: {
                    Text("接続")
                }

                // MARK: - プレビュー設定
                Section {
                    Picker("送信間隔", selection: $settings.previewInterval) {
                        ForEach(SettingsStore.previewIntervalOptions, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                } header: {
                    Text("プレビュー送信")
                } footer: {
                    Text("サーバーへのプレビュー画像の送信間隔を設定します")
                }

                // MARK: - カメラ情報
                Section {
                    HStack {
                        Text("Camera ID")
                        Spacer()
                        Text(settings.cameraID)
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    HStack {
                        Text("デバイス")
                        Spacer()
                        Text(UIDevice.current.name)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("バッテリー")
                        Spacer()
                        Text(batteryText)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("カメラ情報")
                }

                // MARK: - クレジット
                Section {
                    HStack {
                        Text("Build ID")
                        Spacer()
                        Text(buildDateText)
                            .foregroundColor(.secondary)
                            .font(.system(.body, design: .monospaced))
                    }

                    Button {
                        UIApplication.shared.open(URL(string: "https://github.com/TaichiOikawa/MirroringCamera-IOS")!)
                    } label: {
                        HStack {
                            Text("GitHub")
                            Spacer()
                            Image("GitHubIcon")
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text("MirroringCamera-IOS")
                        }
                    }

                    HStack {
                        Text("")
                        Spacer()
                        Text("© 2026 Taichi Oikawa")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("クレジット")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完了") {
                        saveSettings()
                        dismiss()
                    }
                }
            }
            .onAppear {
                editingURL = settings.apiBaseURL
                editingAPIKey = settings.apiKey
            }
        }
    }

    private func saveSettings() {
        let trimmedURL = editingURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.apiBaseURL != trimmedURL {
            settings.apiBaseURL = trimmedURL
        }
        let trimmedKey = editingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.apiKey != trimmedKey {
            settings.apiKey = trimmedKey
        }
    }

    private var batteryText: String {
        let level = UIDevice.current.batteryLevel
        if level < 0 {
            return "不明"
        }
        return "\(Int(level * 100))%"
    }

    private var buildDateText: String {
    guard let executableURL = Bundle.main.executableURL,
          let attrs = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
          let date = attrs[.modificationDate] as? Date else {
        return "不明"
    }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy.MM.dd-HH.mm.ss"
    return fmt.string(from: date)
}
}
