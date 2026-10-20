import Foundation

/// Serial-queue policy: tolerate short outages and never overlap SDP negotiations.
struct WebRTCRecoveryState {
    static let retryInterval: TimeInterval = 10
    private var retryAt: TimeInterval?

    mutating func awaitConnection(now: TimeInterval) {
        if retryAt == nil { retryAt = now + Self.retryInterval }
    }

    mutating func connected() { retryAt = nil }

    mutating func shouldRestart(now: TimeInterval, signalingStable: Bool) -> Bool {
        guard signalingStable, let retryAt, now >= retryAt else { return false }
        self.retryAt = now + Self.retryInterval
        return true
    }
}
