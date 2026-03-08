//
//  MirroringCameraApp.swift
//  MirroringCamera
//

import SwiftUI

@main
struct MirroringCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    if SettingsStore.shared.isConfigured {
                        WebSocketManager.shared.connect()
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active,
               SettingsStore.shared.isConfigured,
               !WebSocketManager.shared.isConnected {
                WebSocketManager.shared.connect()
            }
        }
    }
}
