import XCTest
@testable import D_SmartKey

final class BLEStateMachineTests: XCTestCase {
    func test_proximity_requiresTwoSamplesAndExpires() {
        var samples = ProximitySampleWindow()
        let session = UUID()
        XCTAssertEqual(samples.record(-60, sessionID: session, now: 10), -60)
        XCTAssertFalse(samples.isFresh(sessionID: session, now: 10))
        XCTAssertEqual(samples.record(-50, sessionID: session, now: 11), -57)
        XCTAssertTrue(samples.isFresh(sessionID: session, now: 14))
        XCTAssertFalse(samples.isFresh(sessionID: session, now: 14.01))
        XCTAssertFalse(samples.isFresh(sessionID: session, now: 9))
    }

    func test_proximity_rejectsInvalidSamplesAndResetsAcrossSessions() {
        var samples = ProximitySampleWindow()
        let first = UUID(), second = UUID()
        XCTAssertNil(samples.record(0, sessionID: first, now: 0))
        XCTAssertNil(samples.record(127, sessionID: first, now: 0))
        _ = samples.record(-40, sessionID: first, now: 1)
        _ = samples.record(-40, sessionID: first, now: 2)
        XCTAssertFalse(samples.isFresh(sessionID: second, now: 2))
        XCTAssertEqual(samples.record(-90, sessionID: second, now: 3), -90)
        XCTAssertFalse(samples.isFresh(sessionID: second, now: 3))
        _ = samples.record(-90, sessionID: second, now: 4)
        XCTAssertEqual(samples.record(-60, sessionID: second, now: 10), -60)
        XCTAssertFalse(samples.isFresh(sessionID: second, now: 10))
    }

    func test_transition_updatesSynchronousState() {
        let sm = BLEStateMachine()
        sm.transition(to: .scanning)
        XCTAssertEqual(sm.state, .scanning)
        sm.transition(to: .authenticating)
        XCTAssertEqual(sm.state, .authenticating)
    }

    func test_transition_activeToConnecting_isBlocked() {
        let sm = BLEStateMachine()
        sm.transition(to: .active)
        sm.transition(to: .connecting)
        XCTAssertEqual(sm.state, .active)
    }

    // I3: Service Changed khi đang .active phải re-enter được .connecting để chạy lại
    // discovery gate. Vì .active → .connecting bị chặn trực tiếp, fix dùng bridge qua
    // .scanning (cùng idiom auto-reconnect). Khóa cơ chế này lại để fix I3 không gãy
    // thầm lặng nếu guard state machine đổi.
    func test_transition_activeToConnecting_viaScanningBridge_reachesConnecting() {
        let sm = BLEStateMachine()
        sm.transition(to: .active)
        if case .active = sm.state {
            sm.transition(to: .scanning)
        }
        sm.transition(to: .connecting)
        XCTAssertEqual(sm.state, .connecting)
    }

    func test_publisher_preservesOrderAndSuppressesDuplicates() {
        let sm = BLEStateMachine()
        let done = expectation(description: "final state delivered")
        var received: [IoTConnectionState] = []
        let subscription = sm.statePublisher.sink { state in
            XCTAssertTrue(Thread.isMainThread)
            received.append(state)
            if state == .active { done.fulfill() }
        }
        sm.transition(to: .scanning)
        sm.transition(to: .scanning)
        sm.transition(to: .connecting)
        sm.transition(to: .authenticating)
        sm.transition(to: .active)
        wait(for: [done], timeout: 3)
        subscription.cancel()
        XCTAssertEqual(received, [.idle, .scanning, .connecting, .authenticating, .active])
    }

    func test_concurrentTransitions_doNotPublishAfterFinalBarrier() {
        let sm = BLEStateMachine()
        let done = expectation(description: "all transitions published")
        var received: [IoTConnectionState] = []
        let subscription = sm.statePublisher.sink { state in
            received.append(state)
            if received.count == 1002 { done.fulfill() }
        }
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            sm.transition(to: .error("concurrent-\(index)"))
        }
        sm.transition(to: .standby)
        XCTAssertEqual(sm.state, .standby)
        wait(for: [done], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(received.count, 1002)
        XCTAssertEqual(received.last, sm.state)
    }
}
