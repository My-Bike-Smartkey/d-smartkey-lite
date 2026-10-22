import XCTest
@testable import D_SmartKey

/// Retry callbacks may use a dedicated serial queue; assertions read under a lock.
final class RetryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set() {
        lock.lock()
        defer { lock.unlock() }
        stored = true
    }
}

/// §3.7 (P2) — RetryScheduler: chủ duy nhất của retry;
/// token chết khi đổi session; nhóm đảm bảo 1 chủ retry; cancelAll khi pause.
final class RetrySchedulerTests: XCTestCase {

    func test_scheduledRetry_firesAfterDelay() async throws {
        let scheduler = RetryScheduler()
        let fired = RetryFlag()
        scheduler.schedule(label: "test", group: "g1", delay: 0.1) { fired.set() }
        try await assertEventually { fired.isSet }
    }

    func test_bindNewSession_killsPendingRetries() async throws {
        let scheduler = RetryScheduler()
        scheduler.bind(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, reason: "test-a")
        let fired = RetryFlag()
        scheduler.schedule(label: "mic-retry", group: "mic-retry", delay: 0.15) { fired.set() }
        // Đổi session TRƯỚC khi retry fire
        scheduler.bind(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, reason: "test-b")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fired.isSet, "Token của session cũ phải chết — body không được chạy")
        let pending = scheduler.pendingCount()
        XCTAssertEqual(pending, 0, "Entry cũ phải bị dọn")
    }

    func test_sameGroup_newSchedule_replacesOld() async throws {
        let scheduler = RetryScheduler()
        let first = RetryFlag()
        let second = RetryFlag()
        scheduler.schedule(label: "retry-1", group: "mic", delay: 0.2) { first.set() }
        scheduler.schedule(label: "retry-2", group: "mic", delay: 0.05) { second.set() }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(first.isSet, "Entry cũ cùng nhóm phải bị thay thế (1 chủ retry/nhóm)")
        XCTAssertTrue(second.isSet)
    }

    func test_cancelAll_preventsFire() async throws {
        let scheduler = RetryScheduler()
        let fired = RetryFlag()
        scheduler.schedule(label: "r", group: "g", delay: 0.15) { fired.set() }
        scheduler.cancelAll(reason: "pause test")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertFalse(fired.isSet, "cancelAll (pause) phải ngăn body chạy")
    }

    func test_manualReconnect_cancelsAlreadyEnqueuedMICRetry() {
        let queue = DispatchQueue(label: "test.reconnect")
        let scheduler = RetryScheduler(queue: queue)
        let staleScan = RetryFlag()
        let freshConnect = RetryFlag()
        let drained = expectation(description: "owner queue drained")
        queue.suspend()
        scheduler.schedule(label: "old MIC scan", group: "mic-retry", delay: 0) { staleScan.set() }
        scheduler.cancelAll(reason: "manual reconnect")
        scheduler.schedule(label: "fresh connection", group: "connect", delay: 0) { freshConnect.set() }
        queue.async { drained.fulfill() }
        queue.resume()
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(staleScan.isSet)
        XCTAssertTrue(freshConnect.isSet)
        XCTAssertEqual(scheduler.pendingCount(), 0)
    }

    func test_didConnect_cancelsEveryOldRecoveryGroup() {
        let queue = DispatchQueue(label: "test.didConnect")
        let scheduler = RetryScheduler(queue: queue)
        let stale = RetryFlag()
        let drained = expectation(description: "owner queue drained")
        queue.suspend()
        for group in ["mic-retry", "phantom-guard", "standby-drain", "disconnecting-retry", "fail-connect-retry"] {
            scheduler.schedule(label: group, group: group, delay: 0) { stale.set() }
        }
        scheduler.cancelAll(reason: "didConnect")
        queue.async { drained.fulfill() }
        queue.resume()
        wait(for: [drained], timeout: 2)
        XCTAssertFalse(stale.isSet, "A recovered link must not be torn down by an old retry")
        XCTAssertEqual(scheduler.pendingCount(), 0)
    }

    func test_replacementSuppressesOldEnqueuedWork_andRunsOnOwnerQueue() {
        let queue = DispatchQueue(label: "test.owner")
        let key = DispatchSpecificKey<Int>()
        queue.setSpecific(key: key, value: 42)
        let scheduler = RetryScheduler(queue: queue)
        let stale = RetryFlag()
        let done = expectation(description: "replacement ran on owner")
        queue.suspend()
        scheduler.schedule(label: "old", group: "mic", delay: 0) { stale.set() }
        scheduler.schedule(label: "new", group: "mic", delay: 0) {
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), 42)
            XCTAssertEqual(scheduler.pendingCount(), 0, "Consume before executing; no phantom pending retry")
            done.fulfill()
        }
        queue.resume()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(stale.isSet)
    }

    func test_newSessionSuppressesAlreadyEnqueuedRetry_evenWithSameGroup() {
        let queue = DispatchQueue(label: "test.session")
        let scheduler = RetryScheduler(queue: queue)
        let stale = RetryFlag()
        let done = expectation(description: "new bike retry")
        queue.suspend()
        scheduler.bind(sessionID: UUID(), reason: "bike A")
        scheduler.schedule(label: "old bike", group: "mic", delay: 0) { stale.set() }
        scheduler.bind(sessionID: UUID(), reason: "bike B")
        scheduler.schedule(label: "new bike", group: "mic", delay: 0) { done.fulfill() }
        queue.resume()
        wait(for: [done], timeout: 2)
        XCTAssertFalse(stale.isSet)
    }

    func test_invalidDelayRejected_withoutReplacingValidRetry() {
        let queue = DispatchQueue(label: "test.delay")
        let scheduler = RetryScheduler(queue: queue)
        let done = expectation(description: "valid retry kept")
        queue.suspend()
        XCTAssertTrue(scheduler.schedule(label: "valid", group: "mic", delay: 0) { done.fulfill() })
        for delay in [-1.0, .infinity, .nan] {
            XCTAssertFalse(scheduler.schedule(label: "invalid", group: "mic", delay: delay) { XCTFail("Invalid delay executed") })
        }
        queue.resume()
        wait(for: [done], timeout: 2)
    }

    // MARK: - Helpers

    private func assertEventually(_ condition: @escaping () -> Bool,
                                  timeout: TimeInterval = 2,
                                  message: String = "Điều kiện không đạt trong timeout") async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message)
    }
}
