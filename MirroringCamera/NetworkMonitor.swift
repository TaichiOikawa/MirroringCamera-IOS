import Foundation
import Network

final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var currentType = "unknown"

    var networkType: String {
        lock.lock()
        defer { lock.unlock() }
        return currentType
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let type: String
            if path.status != .satisfied { type = "none" }
            else if path.usesInterfaceType(.wifi) { type = "wifi" }
            else if path.usesInterfaceType(.cellular) { type = "cellular" }
            else if path.usesInterfaceType(.wiredEthernet) { type = "ethernet" }
            else { type = "unknown" }
            guard let self else { return }
            self.lock.lock()
            self.currentType = type
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "com.mirroringcamera.network"))
    }
}
