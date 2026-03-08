//
//  OrientationController.swift
//  MirroringCamera
//

import UIKit

class OrientationController {
    private init() {}

    static let shared = OrientationController()

    var currentOrientation: UIInterfaceOrientationMask = .all

    // 画面向き制御のアンロック
    func unlockOrientation() {
        currentOrientation = .all
    }

    // 画面を指定した向きでロック
    func lockOrientation(to orientation: UIInterfaceOrientationMask, onWindow window: UIWindow) {
        print("lockOrientation called with: \(orientation)")
        currentOrientation = orientation

        guard var topController = window.rootViewController else {
            print("Error: rootViewController is nil")
            return
        }

        // 最前面のViewControllerを取得
        while let presentedViewController = topController.presentedViewController {
            topController = presentedViewController
        }

        // 端末の画面の向きをcurrentOrientationの値で更新
        topController.setNeedsUpdateOfSupportedInterfaceOrientations()

        // iOS 16+ : 実際にジオメトリを更新して画面を回す
        if let windowScene = window.windowScene {
            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
            windowScene.requestGeometryUpdate(geometryPreferences) { error in
                print("Geometry update error: \(error.localizedDescription)")
            }
        }
    }    // 現在の向きを取得してロック
    func lockCurrentOrientation(onWindow window: UIWindow) {
        let currentDeviceOrientation = UIDevice.current.orientation
        print("Current device orientation: \(currentDeviceOrientation)")

        let orientation: UIInterfaceOrientationMask

        switch currentDeviceOrientation {
        case .portrait:
            orientation = .portrait
        case .portraitUpsideDown:
            orientation = .portraitUpsideDown
        case .landscapeLeft:
            orientation = .landscapeRight
        case .landscapeRight:
            orientation = .landscapeLeft
        default:
            // .unknown / .faceUp / .faceDown → UIWindowScene から推定
            if let interfaceOrientation = window.windowScene?.interfaceOrientation {
                switch interfaceOrientation {
                case .landscapeLeft:      orientation = .landscapeLeft
                case .landscapeRight:     orientation = .landscapeRight
                case .portraitUpsideDown:  orientation = .portraitUpsideDown
                default:                  orientation = .portrait
                }
            } else {
                orientation = .portrait
            }
        }

        print("Locking to orientation: \(orientation)")
        lockOrientation(to: orientation, onWindow: window)
    }
}
