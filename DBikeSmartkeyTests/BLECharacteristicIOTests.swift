import XCTest
import CoreBluetooth
@testable import D_SmartKey

// MARK: - Fakes (§3.5 testability seam)

final class FakeCharacteristic: BLEWireCharacteristic {
    let uuid: CBUUID
    var value: Data?
    init(uuid: CBUUID, value: Data? = nil) {
        self.uuid = uuid
        self.value = value
    }
}

final class FakeWirePeripheral: BLEWirePeripheral {
    var state: CBPeripheralState = .connected
    private(set) var readCalls: [(uuid: CBUUID, at: Date)] = []
    private(set) var writeCalls: [(uuid: CBUUID, data: Data, at: Date)] = []

    func readValue(for characteristic: any BLEWireCharacteristic) {
        readCalls.append((characteristic.uuid, Date()))
    }

    func writeValue(_ data: Data, for characteristic: any BLEWireCharacteristic, type: CBCharacteristicWriteType) {
        writeCalls.append((characteristic.uuid, data, Date()))
    }
}

// MARK: - Tests

/// §3.5 (P1): BLECharacteristicIO — cooldown sau timeout chống late-response đâm nhầm
/// continuation của request kế tiếp trên cùng UUID.
final class BLECharacteristicIOTests: XCTestCase {

    private func makeIO(timeout: Double) -> (io: BLECharacteristicIO, wire: FakeWirePeripheral) {
        let wire = FakeWirePeripheral()
        let io = BLECharacteristicIO(peripheral: wire, sessionID: UUID(), timeoutSeconds: timeout)
        return (io, wire)
    }

    func test_read_success_resumesWithData() async throws {
        let (io, wire) = makeIO(timeout: 2)
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF01"))

        let reader = Task { try await io.readValue(from: char) }
        // Đợi request đến peripheral
        try await waitForCondition { !wire.readCalls.isEmpty }

        char.value = Data([0x01, 0x02, 0x03, 0x04])
        await io.didReceiveReadResponse(for: char, error: nil)

        let data = try await reader.value
        XCTAssertEqual(data, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func test_notConnected_throwsImmediately() async throws {
        let (io, wire) = makeIO(timeout: 2)
        wire.state = .disconnected
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF01"))
        do {
            _ = try await io.readValue(from: char)
            XCTFail("Phải throw notConnected")
        } catch let e as IoTError {
            if case .notConnected = e {} else { XCTFail("Sai lỗi: \(e)") }
        }
    }

    func test_timeout_setsCooldown_nextRequestHeldBack() async throws {
        let (io, wire) = makeIO(timeout: 0.15)
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF02"))

        // Request 1: không bao giờ có response → timeout
        do {
            _ = try await io.readValue(from: char)
            XCTFail("Phải timeout")
        } catch let e as IoTError {
            guard case .commandTimeout = e else { return XCTFail("Sai lỗi: \(e)") }
        }
        XCTAssertEqual(wire.readCalls.count, 1, "Request đầu phải đã tới peripheral")

        // Request 2 NGAY sau timeout: phải bị cooldown giữ lại ~500ms
        // (cửa sổ late-response của request 1).
        let second = Task { try await io.readValue(from: char) }

        // Sau 250ms (chưa hết cooldown 500ms): request 2 CHƯA được tới peripheral
        try await Task.sleep(nanoseconds: 250_000_000)
        let visibleEarly = wire.readCalls.count
        XCTAssertLessThanOrEqual(visibleEarly, 1, "Cooldown phải giữ request 2 — không được đụng peripheral trước 500ms (thấy \(visibleEarly))")

        // Trả lời request 2 để task hoàn tất
        try await waitForCondition { wire.readCalls.count >= 2 }
        char.value = Data([0xAA])
        await io.didReceiveReadResponse(for: char, error: nil)
        _ = try await second.value
        XCTAssertEqual(wire.readCalls.count, 2)
    }

    func test_lateResponse_dropped_doesNotCorruptNextRequest() async throws {
        let (io, wire) = makeIO(timeout: 0.15)
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF03"))

        // Request 1 timeout (không response)
        do { _ = try await io.readValue(from: char) }
        catch { /* commandTimeout expected */ }

        // Late response của request 1 đến khi không ai chờ → phải bị DROP
        char.value = Data([0xDE, 0xAD])
        await io.didReceiveReadResponse(for: char, error: nil)

        // Request 2 (sau cooldown) phải nhận CHÍNH response của nó, không bị đâm nhầm
        let second = Task { try await io.readValue(from: char) }
        try await waitForCondition { wire.readCalls.count >= 2 }
        char.value = Data([0x99])
        await io.didReceiveReadResponse(for: char, error: nil)
        let data = try await second.value
        XCTAssertEqual(data, Data([0x99]), "Request 2 phải nhận data mới — late-response cũ đã bị drop")
    }

    func test_writeTimeout_setsCooldown() async throws {
        let (io, wire) = makeIO(timeout: 0.15)
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF04"))

        do {
            _ = try await io.writeValue(Data([0x01]), to: char, type: .withResponse)
            XCTFail("Phải timeout")
        } catch { /* expected */ }

        // Write thứ 2 phải chờ cooldown → chưa tới peripheral sau 200ms
        let second = Task { try await io.writeValue(Data([0x02]), to: char, type: .withResponse) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let visibleEarly = wire.writeCalls.count
        XCTAssertLessThanOrEqual(visibleEarly, 1, "Write 2 phải bị cooldown giữ")

        try await waitForCondition { wire.writeCalls.count >= 2 }
        await io.didReceiveWriteResponse(for: char, error: nil)
        _ = try await second.value
    }

    // C6 (5.1.0): request chồng nhau (kỷ luật 1-outstanding bị phá) → continuation
    // cũ bị huỷ bằng gattOverload, KHÔNG PHẢI CancellationError — CancellationError
    // dành cho user/task cancel chủ động; ném nhầm sẽ khiến BLEAuthenticator.
    // performNonCritical abort cả phiên auth oan.
    func test_overlapRead_resumeOldWithGattOverload_notCancellationError() async throws {
        let (io, wire) = makeIO(timeout: 2)
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF05"))

        // Request 1 treo (không response)
        let first = Task { try await io.readValue(from: char) }
        try await waitForCondition { !wire.readCalls.isEmpty }

        // Request 2 cùng UUID → đè continuation của request 1
        let second = Task { try await io.readValue(from: char) }
        try await waitForCondition { wire.readCalls.count >= 2 }

        // Request 1 phải fail bằng gattOverload (error GATT), không phải CancellationError
        do {
            _ = try await first.value
            XCTFail("Request 1 phải throw khi bị đè lệnh")
        } catch let e as IoTError {
            guard case .gattOverload = e else { return XCTFail("Phải là gattOverload, nhận: \(e)") }
        } catch is CancellationError {
            XCTFail("5.1.0: không được ném CancellationError ở path đè lệnh (auth abort oan)")
        }

        // Request 2 vẫn hoàn tất bình thường với response của chính nó
        char.value = Data([0x42])
        await io.didReceiveReadResponse(for: char, error: nil)
        let data = try await second.value
        XCTAssertEqual(data, Data([0x42]))
    }

    // C4 (5.1.0): caller hạ timeout per-call (telemetry định kỳ 3s thay vì 8s mặc định)
    // → phải timeout theo giá trị per-call, không theo default của instance.
    func test_perCallTimeout_overridesInstanceDefault() async throws {
        let (io, wire) = makeIO(timeout: 5) // default dài — nếu per-call không ăn, test sẽ treo ~5s
        let char = FakeCharacteristic(uuid: CBUUID(string: "FF06"))

        let started = Date()
        do {
            _ = try await io.readValue(from: char, timeoutSeconds: 0.15)
            XCTFail("Phải timeout theo per-call timeout")
        } catch let e as IoTError {
            guard case .commandTimeout = e else { return XCTFail("Sai lỗi: \(e)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0,
                          "Timeout phải theo per-call (0.15s), không phải default (5s)")
        XCTAssertEqual(wire.readCalls.count, 1)
    }

    // MARK: - Helpers

    private func waitForCondition(_ condition: @escaping () async -> Bool,
                                  timeout: TimeInterval = 3,
                                  pollMs: UInt64 = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
        XCTFail("waitForCondition timeout")
    }
}
