import SwiftUI

extension UIView {
  func findViewController() -> UIViewController? {
    if let nextResponder = self.next as? UIViewController {
      return nextResponder
    } else if let nextResponder = self.next as? UIView {
      return nextResponder.findViewController()
    }

    let topVC = UIApplication.shared.getTopViewController()
    return topVC
  }
}

extension UIApplication {
  func getTopViewController() -> UIViewController? {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
      let window = windowScene.windows.first
    else {
      return nil
    }

    return getTopViewController(from: window.rootViewController)
  }

  private func getTopViewController(from viewController: UIViewController?) -> UIViewController? {
    if let presented = viewController?.presentedViewController {
      return getTopViewController(from: presented)
    }

    if let navigationController = viewController as? UINavigationController {
      return getTopViewController(from: navigationController.visibleViewController)
    }

    if let tabBarController = viewController as? UITabBarController {
      return getTopViewController(from: tabBarController.selectedViewController)
    }

    return viewController
  }
}
