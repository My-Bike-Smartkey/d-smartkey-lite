import XCTest
@testable import D_SmartKey

/// P0 — Đặc tả hành vi BLETaskQueue hiện tại (characterization tests).
/// Các test này khoanh vùng hành vi ĐÚNG hôm nay để bảo vệ cho refactor P1.
/// Bug đã xác nhận (cancelAll phá mutex khi owner đang chạy) nằm ở
/// RegressionBacklogTests — hiện XCTSkip chờ P1.
final class BLETaskQueueTests: XCTestCase {

    func test_enqueue_executesTasksInFIFOOrder() async throws {
        let queue = BLETaskQueue()
        let recorder = OrderRecorder()
        let started1 = Latch()

        // ═══ Submission-order determinism ═══
        // async let KHÔNG đảm bảo thứ tự GỌI enqueue (child task startup có thể trễ).
        // Nếu task-3 đến trước task-2 trong lúc queue rảnh, [1,3,2] là lỗi TEST chứ
        // không phải lỗi FIFO của queue (queue chỉ thứ tự được các task ĐÃ đến).
        // → Ép: task-1 chắc chắn ĐANG CHẠY; task-2 chắc chắn ĐÃ PARK; rồi mới submit task-3.
        // Bản chất FIFO vẫn được kiểm: task-2 ngủ 150ms, task-3 chỉ 10ms — nếu queue
        // không serialize thì 3 sẽ ghi trước 2.
        async let r1 = queue.enqueue { () -> Int in
            await started1.set()
            try await Task.sleep(nanoseconds: 150_000_000)
            await recorder.record(1)
            return 1
        }
        try await started1.wait()

        async let r2 = queue.enqueue { () -> Int in
            try await Task.sleep(nanoseconds: 150_000_000)
            await recorder.record(2)
            return 2
        }
        // Cho r2 kịp gọi enqueue và park (dư dỗi 50ms vì task-1 còn ngủ ~150ms)
        try await Task.sleep(nanoseconds: 50_000_000)

        async let r3 = queue.enqueue { () -> Int in
            try await Task.sleep(nanoseconds: 10_000_000)
            await recorder.record(3)
            return 3
        }

        _ = try await (r1, r2, r3)
        let order = await recorder.order
        XCTAssertEqual(order, [1, 2, 3], "Queue phải tuần tự hoá GATT operations theo FIFO")
    }

    func test_cancelAll_resumesPendingTasksWithGattOverload_ownerStillCompletes() async throws {
        let queue = BLETaskQueue()
        let gate = Gate()

        let owner = Task { () -> Int in
            try await queue.enqueue { () -> Int in
                await gate.waitForOpen()
                return 1
            }
        }
        // Để owner kịp chiếm slot thực thi
        try await Task.sleep(nanoseconds: 150_000_000)

        let pending = Task { () -> Int in
            try await queue.enqueue { 2 }
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        await queue.cancelAll()

        do {
            _ = try await pending.value
            XCTFail("Pending task phải bị resume với lỗi khi cancelAll")
        } catch {
            XCTAssertEqual(error is IoTError, true, "Lỗi phải thuộc IoTError, thực tế: \(error)")
        }

        await gate.open()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, 1, "Owner đang chạy vẫn phải hoàn tất bình thường")
    }

    // §3.6 — Generation isolation: cancelAll bump generation; owner cũ unwinding
    // không được can thiệp; task của generation mới chạy bình thường.
    func test_cancelAll_generationIsolation() async throws {
        let queue = BLETaskQueue()
        let gate = Gate()

        let owner = Task { () -> Int in
            try await queue.enqueue { () -> Int in
                await gate.waitForOpen()
                return 1
            }
        }
        // Để owner kịp chiếm slot thực thi
        try await Task.sleep(nanoseconds: 150_000_000)

        await queue.cancelAll()
        let genAfter = await queue.generation
        XCTAssertEqual(genAfter, 1, "cancelAll phải bump generation")

        // Task MỚI (generation mới) sau cancelAll phải chạy và hoàn tất —
        // defer của owner cũ tuyệt đối không được chặn hoặc resume nhầm nó.
        let fresh = Task { () -> Int in
            try await queue.enqueue { () -> Int in 42 }
        }
        let freshResult = try await fresh.value
        XCTAssertEqual(freshResult, 42)

        // Owner cũ vẫn hoàn tất; generation không đổi thêm
        await gate.open()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult, 1)
        let genFinal = await queue.generation
        XCTAssertEqual(genFinal, 1, "defer của owner cũ phải là no-op — không đụng generation mới")
    }
}

// MARK: - Helpers

actor OrderRecorder {
    private(set) var order: [Int] = []
    func record(_ i: Int) { order.append(i) }
}

actor Gate {
    private var isOpen = false
    func open() { isOpen = true }
    func waitForOpen() async {
        while !isOpen {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// Latch một lần — báo hiệu task đã bắt đầu chạy (để ép thứ tự submit trong test).
actor Latch {
    private var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if isSet { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
