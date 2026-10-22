import Foundation

/// Chuẩn hoá toàn bộ các lỗi có thể xảy ra trong hệ thống IoT BLE thành các nhóm rõ ràng.
/// Loại bỏ các định nghĩa lỗi String magic rườm rà.
enum IoTError: Error, LocalizedError, Equatable {
    
    // MARK: - Connection & Access
    case notConnected
    case peripheralNotFound
    case characteristicNotFound(String)
    case accessoryRemovedOrOffline
    
    // MARK: - Authentication
    case authPINMissing
    case shaChallengeFailed
    case staleAuthentication(counter: Int)
    case invalidResponseFormat
    
    // MARK: - Timeout & Hardware
    case commandTimeout
    case hardwareDidNotAcknowledge
    case gattOverload
    
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Không có kết nối tới xe."
        case .peripheralNotFound:
            return "Không tìm thấy thiết bị phần cứng."
        case .characteristicNotFound(let uuid):
            return "Không tìm thấy cổng vật lý (Characteristic): \(uuid)."
        case .accessoryRemovedOrOffline:
            return "Xe đã bị gỡ khỏi hệ thống hoặc mất liên lạc hoàn toàn."
            
        case .authPINMissing:
            return "Không tìm thấy mã PIN xác thực trong Keychain."
        case .shaChallengeFailed:
            return "Sai mã PIN hoặc xác thực SHA-256 bị xe từ chối."
        case .staleAuthentication(let counter):
            return "Cần xác thực lại (Counter chẵn: \(counter)). App có thể bị đóng ngầm."
        case .invalidResponseFormat:
            return "Xe trả về dữ liệu sai định dạng."
            
        case .commandTimeout:
            return "Hết thời gian chờ phản hồi từ xe."
        case .hardwareDidNotAcknowledge:
            return "Xe không phản hồi lại lệnh điều khiển (No ACK)."
        case .gattOverload:
            return "Nghẽn băng thông Bluetooth (GATT). Quá nhiều lệnh gửi ngầm."
        }
    }
}
