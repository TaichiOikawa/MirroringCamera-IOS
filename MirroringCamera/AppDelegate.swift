//
//  AppDelegate.swift
//  MirroringCamera
//

import UIKit

class AppDelegate: UIResponder, UIApplicationDelegate {
    static weak var current: AppDelegate?

    var externalWindow: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Self.current = self
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let isExternalDisplayScene = connectingSceneSession.role == .windowExternalDisplayNonInteractive

        let configuration = UISceneConfiguration(
            name: isExternalDisplayScene ? "External Configuration" : "Default Configuration",
            sessionRole: connectingSceneSession.role
        )

        if isExternalDisplayScene {
            configuration.delegateClass = ExternalSceneDelegate.self
        } else {
            configuration.delegateClass = SceneDelegate.self
        }

        return configuration
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationController.shared.currentOrientation
    }
}
