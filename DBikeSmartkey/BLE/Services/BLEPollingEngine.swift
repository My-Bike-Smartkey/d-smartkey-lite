import Foundation
import CoreBluetooth
import Combine

/// Vòng lặp Timers chuyên trách để đọc thông số liên tục (RSSI, Telemetry, Echo)
/// khi xe đang trong trạng thái kết nối.
class BLEPollingEngine {
    
    private let context: BLEConnectionContext
    
    private var pollingTask: Task<Void, Never>?
    
    /// Callback cập nhật toàn diện thông số xe định kỳ (Pin SOC, ODO, Nhiệt độ motor).
    /// C4 (5.1.0): nhận luôn echo data vừa đọc — core parse lock state từ data này
    /// thay vì đọc lại smartkeyEcho lần nữa (trước 5.1.0 echo bị đọc 2 lần/chu kỳ,
    /// cộng thêm 3 read telemetry = 4 GATT reads mỗi 10s cho cùng thông tin).
    var onPeriodicTelemetryPoll: ((Data) -> Void)?
    
    // Publishers
    @Published private(set) var currentRSSI: Double = 0.0
    
    init(context: BLEConnectionContext) {
        self.context = context
    }
    
    func startPolling() {
        stopPolling()
        
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            
            // Chạy 2 vòng lặp bất đồng bộ song song cho RSSI và Keep-Alive / Telemetry
            await withTaskGroup(of: Void.self) { group in
                
                // Vòng lặp 1: RSSI Polling (Mỗi 1s)
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        self?.context.peripheral.readRSSI() // Lệnh này không qua CharacteristicIO nên không cần Enqueue
                        do {
                            // Sleep 1s (Swift 6 chuẩn)
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        } catch { break }
                    }
                }
                
                // Vòng lặp 2: Keep-Alive & Periodic Telemetry (Mỗi 10s)
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(nanoseconds: 10_000_000_000) // Sleep 10s
                            guard let self = self else { break }
                            
                            // 1. ĐẨY VÀO QUEUE ĐỂ ĐẢM BẢO KHÔNG XUNG ĐỘT (GATT COLLISION)
                            let echoData = try await self.context.queue.enqueue {
                                let echoChar = try self.context.requireCharacteristic(BLECharacteristic.smartkeyEcho)
                                return try await self.context.io.readValue(from: echoChar)
                            }
                            
                            // 2. Kích hoạt cập nhật Telemetry định kỳ (Pin SOC, Odo, Nhiệt độ motor)
                            self.onPeriodicTelemetryPoll?(echoData)
                        } catch {
                            // Bỏ qua lỗi huỷ hoặc kẹt BLE
                            if error is CancellationError { break }
                        }
                    }
                }
            }
        }
    }
    
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
    
    // Được Delegate CBPeripheralDelegate gọi lại (CoreBluetooth queue).
    // P5: @Published phải mutate trên main — hop main để tránh runtime warning
    // và race với SwiftUI subscriber.
    func didReadRSSI(value: Double) {
        DispatchQueue.main.async { self.currentRSSI = value }
    }
}
