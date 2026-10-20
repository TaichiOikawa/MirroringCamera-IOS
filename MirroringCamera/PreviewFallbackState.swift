import Foundation

/// Used on the WebRTC queue. A disconnected viewer stays subscribed so JPEG can take over.
struct PreviewFallbackState {
    private(set) var subscribers = Set<String>()
    private(set) var connected = Set<String>()
    private var unavailableSince: [String: TimeInterval] = [:]
    static let graceInterval: TimeInterval = 6

    mutating func subscribe(_ id: String, now: TimeInterval) {
        subscribers.insert(id)
        update(now: now)
    }

    mutating func setConnected(_ isConnected: Bool, id: String, now: TimeInterval) {
        guard subscribers.contains(id) else { return }
        if isConnected { connected.insert(id) } else { connected.remove(id) }
        update(now: now)
    }

    mutating func unsubscribe(_ id: String, now: TimeInterval) {
        subscribers.remove(id)
        connected.remove(id)
        update(now: now)
    }

    mutating func reset() { self = PreviewFallbackState() }

    func isActive(now: TimeInterval) -> Bool {
        unavailableSince.values.contains { now - $0 >= Self.graceInterval }
    }

    var hasLiveViewer: Bool { !connected.isEmpty }

    private mutating func update(now: TimeInterval) {
        let unavailable = subscribers.subtracting(connected)
        unavailableSince = unavailableSince.filter { unavailable.contains($0.key) }
        for id in unavailable where unavailableSince[id] == nil {
            unavailableSince[id] = now
        }
    }
}
