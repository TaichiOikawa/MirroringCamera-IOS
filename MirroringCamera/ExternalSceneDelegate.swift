import UIKit

@MainActor
final class ExternalSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    private let store = ExternalDisplayStore.shared

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let externalView = ExternalCameraView()

        let viewController = UIViewController()
        viewController.view = externalView

        let externalWindow = UIWindow(windowScene: windowScene)
        externalWindow.rootViewController = viewController
        externalWindow.makeKeyAndVisible()

        window = externalWindow
        store.isExternalDisplayConnected = true
        store.startMirroring(to: externalView)

        print("外部ディスプレイ接続: カメラ映像を出力中")
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        store.stopMirroring()
        window = nil
        store.isExternalDisplayConnected = false
        print("外部ディスプレイ切断")
    }
}
