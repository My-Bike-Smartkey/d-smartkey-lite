import Combine
import Foundation

/// Value-type proximity filter. Caller owns isolation; time is injected for tests.
struct ProximitySampleWindow {
    private var session: UUID?
    private var timestamp: TimeInterval?
    private var count = 0
    private(set) var smoothed = 0
    let maximumAge: TimeInterval = 3

    mutating func record(_ value: Int, sessionID: UUID, now: TimeInterval) -> Int? {
        guard (-127 ... -1).contains(value), now.isFinite else { return nil }
        let gap = timestamp.map { now - $0 }
        let reset = session != sessionID || gap == nil || gap! < 0 || gap! > maximumAge
        if reset { count = 0 }
        session = sessionID
        timestamp = now
        count = min(count + 1, 2)
        smoothed = reset ? value : Int(Double(smoothed) * 0.7 + Double(value) * 0.3)
        return smoothed
    }

    func isFresh(sessionID: UUID, now: TimeInterval) -> Bool {
        guard session == sessionID, count >= 2, let timestamp else { return false }
        let age = now - timestamp
        return age >= 0 && age <= maximumAge
    }
}

/// Synchronous state storage with ordered publication. This protects only the
/// state machine, not the coordinator's context, timers or session lifecycle.
final class BLEStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var storedState: IoTConnectionState = .idle
    private let subject = CurrentValueSubject<IoTConnectionState, Never>(.idle)
    private let publicationQueue = DispatchQueue(label: "app.mybike.smartkey.state-publication")

    var state: IoTConnectionState {
        lock.lock()
        defer { lock.unlock() }
        return storedState
    }

    // Avoid unsynchronized lazy initialization when subscribers arrive concurrently.
    var statePublisher: AnyPublisher<IoTConnectionState, Never> {
        subject.removeDuplicates()
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    func transition(to newState: IoTConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        if case (.active, .connecting) = (storedState, newState) { return }
        guard storedState != newState else { return }
        storedState = newState
        // Enqueue under the state lock to preserve transition order, but execute
        // sends elsewhere: subscribers must never be invoked under this lock.
        publicationQueue.async { [self] in subject.send(newState) }
    }
}
