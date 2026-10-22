import Foundation

/// Thể hiện trạng thái kết nối tổng quát (Hỗ trợ State Machine).
enum IoTConnectionState: Equatable {
    case idle
    case scanning
    case connecting
    case nearby          // NEARBY: Đã kết nối BLE, chưa auth, đang ở gần xe (passive mode)
    case standby         // KẾT NỐI CHỜ: Đã kết nối BLE, chờ lại gần để xác thực
    case pairingRequired // Bổ sung trạng thái chờ xác thực/NFC
    case authenticating
    /// Kết nối thành công, auth hoàn tất, data sẵn sàng.
    case active
    case error(String)
    
    var isConnected: Bool {
        if case .active = self { return true }
        if case .standby = self { return true }
        if case .nearby = self { return true }
        if case .authenticating = self { return true } // Ngăn chặn văng màn hình splash
        return false
    }
    
    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .authenticating, .pairingRequired: return true
        default: return false
        }
    }
    
    var displayText: String {
        switch self {
        case .idle: return "Chưa kết nối (Idle)"
        case .scanning: return "Đang quét tìm xe..."
        case .connecting: return "Hệ thống đang kết nối..."
        case .nearby: return "Đang ở gần xe"
        case .standby: return "Kết nối ngầm (Chờ lại gần)"
        case .pairingRequired: return "Chờ xác thực bảo mật..."
        case .authenticating: return "App đang xác thực..."
        case .active: return "Đã kết nối (Active Session)"
        case .error(let msg): return "Lỗi kết nối: \(msg)"
        }
    }
}

/// Trạng thái khóa của mảng byte 0x36.
enum IoTLockState: Equatable, CustomStringConvertible {
    case locked
    case unlocked
    case armed
    case unknown(Data)
    
    var isLocked: Bool {
        return self == .locked || self == .armed
    }
    
    var description: String {
        switch self {
        case .locked: return "Đã tắt/khoá"
        case .unlocked: return "Đang bật"
        case .armed: return "Chống trộm (Arm)"
        case .unknown: return "Đang tải..."
        }
    }
    
    /// Parse từ raw data đọc từ smartkeyEcho/lockStatus (đồng bộ 64623aa)
    /// 00 00 = LOCKED (xe đang tắt)
    /// 02 00 = UNLOCKED (xe đang bật)
    /// 07 00 = ARMED (chống trộm)
    static func parse(from data: Data) -> IoTLockState {
        if BLELockStatePayload.locked.contains(data) {
            return .locked
        } else if BLELockStatePayload.unlocked.contains(data) {
            return .unlocked
        } else if BLELockStatePayload.armed.contains(data) {
            return .armed
        } else {
            return .unknown(data)
        }
    }
}

/// Dữ liệu đo đạc (Telemetry) an toàn, đã được dịch khối byte.
struct IoTTelemetryData: Equatable {
    var soc: Float = 0        // Battery percentage 0-100%
    var motorTemp: Float = 0
    var controllerTemp: Float = 0
    var odometerKm: Float = 0
    var speedKmh: Float = 0
}

/// Cấu trúc thông tin cơ bản xe trả về
struct IoTVehicleInfo: Equatable {
    var name: String = "Dat Bike"
    var serialNumber: String = ""
    var modelNumber: String = ""
    var firmwareVersion: String = ""
    var deviceToken: String = ""
    
    // Compat accessors cho Views
    var serial: String { serialNumber }
    var model: String { modelNumber }
    var firmware: String { firmwareVersion }
    var isEmpty: Bool { name == "Dat Bike" && serialNumber.isEmpty }
}
