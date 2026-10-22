import Foundation
import CoreBluetooth
import Combine

enum BLEAdvertisementScanEvent {
    case state(CBManagerState)
    case discovered(UUID, String?, [String: Any], Int, Date)
}

protocol BLEAdvertisementScanTransport: AnyObject {
    var onEvent: ((BLEAdvertisementScanEvent) -> Void)? { get set }
    func start()
    func stop()
}

/// Same classic CoreBluetooth path as Lite: nil service filter, duplicate callbacks.
/// Dedicated central has no restore identifier and never connects, pairs or writes.
/// All entry points and delegate callbacks use the main queue.
final class LiteAdvertisementScanTransport: NSObject, BLEAdvertisementScanTransport, CBCentralManagerDelegate {
    var onEvent: ((BLEAdvertisementScanEvent) -> Void)?
    private var central: CBCentralManager?
    private var requested = false

    func start() {
        #if NOASK
        requested = true
        if let central { centralManagerDidUpdateState(central) }
        else { central = CBCentralManager(delegate: self, queue: .main,
                                         options: [CBCentralManagerOptionShowPowerAlertKey: false]) }
        #else
        // An ASK-adopting binary cannot become an unrestricted scanner at runtime.
        onEvent?(.state(.unsupported))
        #endif
    }

    func stop() { requested = false; central?.stopScan() }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard requested else { return }
        onEvent?(.state(central.state))
        if requested && central.state == .poweredOn {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard requested else { return }
        onEvent?(.discovered(peripheral.identifier, peripheral.name, advertisementData, RSSI.intValue, Date()))
    }

    deinit { central?.stopScan() }
}

final class BLEAdvertisementScanner: ObservableObject {
    @Published private(set) var store = BLEAdvertisementStore()
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Bấm Quét để thu dữ liệu quảng bá trong 30 giây."
    private let transport: BLEAdvertisementScanTransport
    private let duration: TimeInterval
    private var deadline: DispatchWorkItem?
    private var requestID: UUID?

    init(transport: BLEAdvertisementScanTransport = LiteAdvertisementScanTransport(), duration: TimeInterval = 30) {
        self.transport = transport
        self.duration = duration
        transport.onEvent = { [weak self] event in self?.receive(event) }
    }

    var records: [BLEAdvertisementRecord] {
        store.records.values.sorted { $0.rssiRank == $1.rssiRank ? $0.id.uuidString < $1.id.uuidString : $0.rssiRank > $1.rssiRank }
    }

    func start() {
        guard !isRunning else { return }
        store = BLEAdvertisementStore()
        isRunning = true
        status = "Đang chờ Bluetooth…"
        let id = UUID()
        requestID = id
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == id else { return }
            self.stop(reason: "Đã quét xong.")
        }
        deadline = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
        log("Bắt đầu quét quảng bá, không lọc service UUID")
        transport.start()
    }

    func stop(reason: String = "Đã dừng quét.") {
        guard isRunning else { return }
        isRunning = false
        requestID = nil
        deadline?.cancel(); deadline = nil
        transport.stop()
        status = reason
        log("\(reason) devices=\(store.records.count) droppedCallbacks=\(store.droppedCallbacks)")
    }

    private func receive(_ event: BLEAdvertisementScanEvent) {
        guard isRunning else { return }
        switch event {
        case .state(.poweredOn): status = "Đang quét tất cả thiết bị BLE xung quanh…"
        case .state(.unauthorized): stop(reason: "Chưa có quyền Bluetooth. Hãy cho phép trong Cài đặt iOS.")
        case .state(.poweredOff): stop(reason: "Bluetooth đang tắt. Hãy bật Bluetooth rồi quét lại.")
        case .state(.unsupported): stop(reason: "Thiết bị hoặc bản app này không hỗ trợ quét CoreBluetooth trực tiếp.")
        case .state(.resetting), .state(.unknown): status = "Đang chờ Bluetooth sẵn sàng…"
        case .state: stop(reason: "Bluetooth không sẵn sàng. Hãy thử quét lại.")
        case let .discovered(id, name, data, rssi, date):
            store.receive(id: id, cachedName: name, data: data, rssi: rssi, at: date)
        }
    }

    private func log(_ message: String) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[ADV_DEBUG] \(message)"))
    }

    deinit { deadline?.cancel(); transport.stop() }
}
