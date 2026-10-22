import Foundation
import CoreBluetooth

// MARK: - Testability Seam (§3.5)
// CBPeripheral/CBCharacteristic không có public initializer — không thể unit-test
// CoreBluetooth thật. Hai protocol này tách bề mặt tối thiểu mà IO cần; CB conform
// tự động, test dùng fake.

protocol BLEWireCharacteristic: AnyObject {
    var uuid: CBUUID { get }
    var value: Data? { get }
}
extension CBCharacteristic: BLEWireCharacteristic {}

protocol BLEWirePeripheral: AnyObject {
    var state: CBPeripheralState { get }
    func readValue(for characteristic: any BLEWireCharacteristic)
    func writeValue(_ data: Data, for characteristic: any BLEWireCharacteristic, type: CBCharacteristicWriteType)
}
extension CBPeripheral: BLEWirePeripheral {
    func readValue(for characteristic: any BLEWireCharacteristic) {
        // Luồng thật luôn là cặp CBPeripheral+CBCharacteristic — downcast an toàn.
        readValue(for: characteristic as! CBCharacteristic)
    }
    func writeValue(_ data: Data, for characteristic: any BLEWireCharacteristic, type: CBCharacteristicWriteType) {
        writeValue(data, for: characteristic as! CBCharacteristic, type: type)
    }
}

/// Cỗ máy I/O Độc lập. Không chứa logic xe, chỉ giải quyết nghiệp vụ:
/// "Tôi cần gửi mảng Byte này tới Characteristic này, hãy cho tôi Continuation để chờ ACK".
///
/// §3.5 (P1) — Chống late-response đâm nhầm request mới:
/// 1. `sessionID` gắn với phiên — mọi drop log đều kèm session để truy vết.
/// 2. Timeout trên một UUID ⇒ UUID đó vào **cooldown 500ms**: request mới trên cùng
///    UUID phải đợi hết cooldown mới được cấp phát, đóng cửa sổ late-response cũ
///    đâm vào continuation mới (giới hạn CoreBluetooth: không có request-id per ATT).
/// 3. Response đến khi không ai chờ ⇒ log rõ ràng + drop (trước đây im lặng).
actor BLECharacteristicIO {

    private let peripheral: any BLEWirePeripheral
    private let sessionID: UUID

    enum Op {
        case read, write
    }

    /// Thời gian một UUID bị "khóa" sau khi request trên nó timeout (giây).
    static let cooldownSeconds: Double = 0.5

    private var cooldowns: [Op: [CBUUID: Date]] = [:]

    /// Timeout cho một thao tác I/O (injectable để test).
    private let timeoutSeconds: Double

    // Nơi cất giữ các luồng đang chờ Callbacks từ Delegate.
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    init(peripheral: any BLEWirePeripheral, sessionID: UUID = UUID(), timeoutSeconds: Double = 8) {
        self.peripheral = peripheral
        self.sessionID = sessionID
        self.timeoutSeconds = timeoutSeconds
    }

    // MARK: - Core I/O

    /// C4 (5.1.0): cho phép caller giảm timeout per-call (telemetry định kỳ dùng 3s
    /// thay vì 8s mặc định — tránh một batch telemetry nghẽn hàng GATT tới ~34s
    /// khi link yếu, làm lệnh khóa/mở của user xếp sau).
    func readValue(from characteristic: any BLEWireCharacteristic, timeoutSeconds perCallTimeout: Double? = nil) async throws -> Data {
        if peripheral.state != .connected { throw IoTError.notConnected }
        try await respectCooldown(.read, uuid: characteristic.uuid)

        do {
            return try await withTimeout(seconds: perCallTimeout ?? timeoutSeconds) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if let old = self.readContinuations[characteristic.uuid] {
                            // §3.5: request chồng nhau nghĩa là kỷ luật 1-outstanding bị phá —
                            // cooldown vì response của request cũ có thể về trễ.
                            self.setCooldown(.read, uuid: characteristic.uuid)
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                                message: "[BLE_IO][\(self.sessionID.uuidString.prefix(8))] Đè lệnh Read cho \(characteristic.uuid) — huỷ luồng cũ + cooldown \(Int(Self.cooldownSeconds * 1000))ms"))
                            // C6 (5.1.0): ném gattOverload thay vì CancellationError —
                            // CancellationError dành riêng cho user/task cancel chủ động;
                            // ném nhầm sẽ khiến BLEAuthenticator.performNonCritical abort
                            // cả phiên auth oan (4.9.1 nuốt hết, không có đường fail này).
                            old.resume(throwing: IoTError.gattOverload)
                        }
                        self.readContinuations[characteristic.uuid] = continuation
                        self.peripheral.readValue(for: characteristic)
                    }
                } onCancel: {
                    Task { [weak self] in await self?.cancelRead(for: characteristic.uuid) }
                }
            }
        } catch let error as IoTError {
            if case .commandTimeout = error {
                // Request bỏ hoang — response có thể về muộn bất cứ lúc nào: khóa UUID.
                setCooldown(.read, uuid: characteristic.uuid)
            }
            throw error
        }
    }

    func writeValue(_ data: Data, to characteristic: any BLEWireCharacteristic, type: CBCharacteristicWriteType = .withResponse, timeoutSeconds perCallTimeout: Double? = nil) async throws {
        if peripheral.state != .connected { throw IoTError.notConnected }

        if type == .withResponse {
            try await respectCooldown(.write, uuid: characteristic.uuid)

            do {
                try await withTimeout(seconds: perCallTimeout ?? timeoutSeconds) {
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            if let old = self.writeContinuations[characteristic.uuid] {
                                self.setCooldown(.write, uuid: characteristic.uuid)
                                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                                    message: "[BLE_IO][\(self.sessionID.uuidString.prefix(8))] Đè lệnh Write cho \(characteristic.uuid) — huỷ luồng cũ + cooldown"))
                                // C6 (5.1.0): xem giải thích ở nhánh Read ở trên.
                                old.resume(throwing: IoTError.gattOverload)
                            }
                            self.writeContinuations[characteristic.uuid] = continuation
                            self.peripheral.writeValue(data, for: characteristic, type: type)
                        }
                    } onCancel: {
                        Task { [weak self] in await self?.cancelWrite(for: characteristic.uuid) }
                    }
                }
            } catch let error as IoTError {
                if case .commandTimeout = error {
                    setCooldown(.write, uuid: characteristic.uuid)
                }
                throw error
            }
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    // MARK: - Cooldown (§3.5)

    private func respectCooldown(_ op: Op, uuid: CBUUID) async throws {
        guard let until = cooldowns[op]?[uuid] else { return }
        let wait = Date().distance(to: until)
        guard wait > 0 else { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[BLE_IO][\(sessionID.uuidString.prefix(8))] \(op == .read ? "read" : "write") \(uuid) chờ cooldown \(String(format: "%.0f", wait * 1000))ms (chống late-response)"))
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    private func setCooldown(_ op: Op, uuid: CBUUID) {
        cooldowns[op, default: [:]][uuid] = Date().addingTimeInterval(Self.cooldownSeconds)
    }

    // MARK: - Timeout Helper

    /// Timeout wrapper: throw IoTError.commandTimeout nếu operation không hoàn thành trong `seconds` giây.
    private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw IoTError.commandTimeout
            }
            // Lấy kết quả task nào xong trước, hủy task còn lại
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw IoTError.commandTimeout }
            return result
        }
    }

    // MARK: - Cancellation Lifecycle
    func cancelRead(for targetUUID: CBUUID) {
        guard let continuation = readContinuations.removeValue(forKey: targetUUID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    func cancelWrite(for targetUUID: CBUUID) {
        guard let continuation = writeContinuations.removeValue(forKey: targetUUID) else { return }
        continuation.resume(throwing: CancellationError())
    }

    // MARK: - Delegate Bơm ngược (Feedbacks)

    /// Nhận tín hiệu từ CBPeripheralDelegate truyền vào (để resume async).
    func didReceiveReadResponse(for characteristic: any BLEWireCharacteristic, error: Error?) {
        guard let continuation = readContinuations.removeValue(forKey: characteristic.uuid) else {
            // §3.5: response trễ không có người chờ — DROP có log (trước đây im lặng).
            if error == nil {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[BLE_IO][\(sessionID.uuidString.prefix(8))] Read response TRỄ cho \(characteristic.uuid) — không ai chờ, bỏ qua (anti late-response)"))
            }
            return
        }

        if let error = error {
            continuation.resume(throwing: error)
        } else if let value = characteristic.value {
            continuation.resume(returning: value)
        } else {
            continuation.resume(throwing: IoTError.invalidResponseFormat)
        }
    }

    func didReceiveWriteResponse(for characteristic: any BLEWireCharacteristic, error: Error?) {
        guard let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) else {
            if error == nil {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[BLE_IO][\(sessionID.uuidString.prefix(8))] Write response TRỄ cho \(characteristic.uuid) — không ai chờ, bỏ qua (anti late-response)"))
            }
            return
        }

        if let error = error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: ())
        }
    }

    func cancelAll() {
        for (_, cont) in readContinuations { cont.resume(throwing: IoTError.notConnected) }
        for (_, cont) in writeContinuations { cont.resume(throwing: IoTError.notConnected) }
        readContinuations.removeAll()
        writeContinuations.removeAll()
    }
}
