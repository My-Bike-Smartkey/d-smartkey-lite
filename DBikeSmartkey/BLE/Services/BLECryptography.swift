import Foundation
import CryptoKit

/// Lớp nghiệp vụ thuần về Mật mã, hoàn toàn tách biệt khỏi Bluetooth.
/// Có thể dùng Unit Test độc lập.
struct BLECryptography {

    /// Firmware sends the challenge counter as four little-endian bytes.
    /// Decode bytewise so a Data slice never relies on pointer alignment.
    static func counter(from data: Data) throws -> UInt32 {
        guard data.count >= 4 else { throw IoTError.invalidResponseFormat }
        let bytes = Array(data.prefix(4))
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    static func confirmsAuthentication(challenge: UInt32, response: UInt32) -> Bool {
        challenge & 1 == 0 && response == (challenge | 1)
    }
    
    /// Nhận `authChallenge` từ xe (4 bytes tuỳ ý), xử lý công thức và trả lại 64 kí tự hash HexString.
    /// - Parameters:
    ///   - challengeBytes: 4 bytes lấy từ characteristic `0x000C`
    ///   - pin: Chuỗi PIN ghép đôi.
    /// - Returns: Hex String dùng để gửi trả lại xe.
    static func solveChallenge(challengeBytes: Data, pin: String) throws -> String {
        let shiftedValue = try counter(from: challengeBytes) >> 1
        
        // Hợp nhất `shiftedValue` và `PIN`
        let hashInputStr = String(shiftedValue) + pin
        
        guard let inputData = hashInputStr.data(using: .utf8) else {
            throw IoTError.invalidResponseFormat
        }
        
        // Băm SHA-256
        let hash = SHA256.hash(data: inputData)
        
        // Đảo thành Hex
        let hexString = hash.compactMap { String(format: "%02x", $0) }.joined()
        return hexString
    }
}
