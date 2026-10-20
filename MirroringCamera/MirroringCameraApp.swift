//
//  MirroringCameraApp.swift
//  MirroringCamera
//

import SwiftUI

@main
struct MirroringCameraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    // Unit tests exercise managers without starting camera/audio hardware or permission dialogs.
    private var isTesting: Bool {
        ProcessInfo.processInfo.environment["MIRRORING_CAMERA_TESTING"] == "1"
    }

    var body: some Scene {
        WindowGroup {
            if isTesting {
                Color.black
            } else {
                ContentView()
                .onAppear {
                    UIDevice.current.isBatteryMonitoringEnabled = true
                    WebSocketManager.shared.onForegroundResume()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !isTesting {
                WebSocketManager.shared.onForegroundResume()
            }
        }
    }
}
