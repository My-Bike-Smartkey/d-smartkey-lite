import Foundation

/// Bộ xử lý dịch mã nhị phân Bluetooth thành Dữ liệu người dùng (SoC, Nhiệt độ, Odo).
struct BLETelemetryParser {
    
    static func parseLockState(from data: Data) -> IoTLockState {
        return IoTLockState.parse(from: data)
    }
    
    static func parseTelemetry(from data: Data) -> IoTTelemetryData {
        var result = IoTTelemetryData()
        guard data.count >= 13 else { return result }
        
        // 1. Phân tích Motor Temp (Index 5)
        let bytes = Array(data.prefix(13))
        let motorTempByte = bytes[5]
        result.motorTemp = Float(motorTempByte)
        
        // 2. Phân tích Odometer (Index 7, 8, 9, 10 - Little Endian)
        let odoMeters = UInt32(bytes[7]) | (UInt32(bytes[8]) << 8)
            | (UInt32(bytes[9]) << 16) | (UInt32(bytes[10]) << 24)
        result.odometerKm = Float(odoMeters) / 1000.0
        
        // 3. Phân tích Controller Temp (Index 12)
        let controllerTempByte = bytes[12]
        result.controllerTemp = Float(controllerTempByte)
        
        return result
    }
    
    static func parseBattery(from data: Data) -> Float {
        guard data.count >= 6 else { return 0 }
        let socByte = data[5]
        return Float(socByte) / 100.0 // Giả sử quy đổi 0-1
    }
}
