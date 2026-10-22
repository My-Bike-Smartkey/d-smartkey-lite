import Foundation
import CoreBluetooth

/// Đại diện 1:1 cho một chiếc xe vật lý trong môi trường kết nối.
/// Đóng gói CBPeripheral và các hệ thống Input/Output của riêng nó.
class BLEConnectionContext {
    let peripheral: CBPeripheral

    /// §3.5: định danh phiên — io gắn với session này; log truy vết late-response.
    let sessionID: UUID

    /// §LOG: thời điểm tạo context — mốc t=0 cho trace elapsed của phiên.
    let createdAt = Date()

    /// Hàng đợi lệnh ngăn chặn GATT Collision (Bảo đảm không gọi Read/Write đè lên nhau)
    let queue: BLETaskQueue

    /// Động cơ trao đổi Byte ở dạng Async Await
    let io: BLECharacteristicIO

    /// Khóa bảo vệ đa luồng cho bảng tra cứu Characteristic (Thread-Safe Dictionary)
    private let charLock = NSLock()
    private var _discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]
    /// Index phụ theo BLECharKey (prefix-8) — fw 1.11.0 xoay suffix full UUID (E5)
    private var _characteristicsByKey: [BLECharKey: CBCharacteristic] = [:]

    /// Danh mục các nốt (Characteristic) đã được dò tìm thành công
    var discoveredCharacteristics: [CBUUID: CBCharacteristic] {
        charLock.lock()
        defer { charLock.unlock() }
        return _discoveredCharacteristics
    }

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        let sessionID = UUID()
        self.sessionID = sessionID
        self.queue = BLETaskQueue()
        self.io = BLECharacteristicIO(peripheral: peripheral, sessionID: sessionID)
    }
    
    // MARK: - Registry
    
    func register(characteristic: CBCharacteristic) {
        charLock.lock()
        defer { charLock.unlock() }
        _discoveredCharacteristics[characteristic.uuid] = characteristic
        if let key = BLECharKey.key(forUUID: characteristic.uuid) {
            _characteristicsByKey[key] = characteristic
        }
    }

    func requireCharacteristic(_ uuid: CBUUID) throws -> CBCharacteristic {
        charLock.lock()
        defer { charLock.unlock() }
        if let char = _discoveredCharacteristics[uuid] { return char }
        // fw 1.11.0+: full UUID bị xoay suffix → tra theo prefix-8 (BLECharKey)
        if let key = BLECharKey.key(forUUID: uuid), let char = _characteristicsByKey[key] {
            return char
        }
        throw IoTError.characteristicNotFound(uuid.uuidString)
    }
    
    // MARK: - Teardown
    
    /// Dọn dẹp toàn bộ state — phiên bản sync (fire-and-forget) cho các call sites không cần đợi.
    func clearState() {
        charLock.lock()
        _discoveredCharacteristics.removeAll()
        _characteristicsByKey.removeAll()
        charLock.unlock()
        Task {
            await io.cancelAll()
            await queue.cancelAll()
        }
    }

    /// Dọn dẹp toàn bộ state — phiên bản async đảm bảo io/queue đã cancel xong trước khi return.
    func clearStateAsync() async {
        charLock.lock()
        _discoveredCharacteristics.removeAll()
        _characteristicsByKey.removeAll()
        charLock.unlock()
        await io.cancelAll()
        await queue.cancelAll()
    }
}
