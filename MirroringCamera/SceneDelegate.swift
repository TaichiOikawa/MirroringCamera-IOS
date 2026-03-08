//
//  SceneDelegate.swift
//  MirroringCamera
//

import UIKit
import SwiftUI

class SceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // SwiftUI の WindowGroup がウインドウを作成するので、既存のものを参照するだけ
        if let existingWindow = windowScene.windows.first {
            self.window = existingWindow
        }

        print("SceneDelegate window set: \(self.window != nil)")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // WindowGroup によるウインドウ作成後に参照を取得
        if window == nil, let windowScene = scene as? UIWindowScene {
            self.window = windowScene.windows.first
        }
    }
}
