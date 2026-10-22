// BLEConstants.swift — Dat Bike Quantum S3 BLE Protocol Constants
// Reverse-engineered from btsnoop_hci.log — đồng bộ commit 64623aa

import CoreBluetooth
import Security

// MARK: - Service UUIDs

enum BLEService {
    /// LEGACY (fw ≤1.10.x) — primary scan/advertisement service UUID.
    /// Firmware 1.11.0 KHÔNG còn quảng bá UUID này.
    static let scan          = CBUUID(string: "0000FCF1-0000-1000-8000-00805F9B34FB")

    /// Authentication service (handles 0x00a–0x010) — UUID quảng bá duy nhất trên fw 1.11.0
    static let auth          = CBUUID(string: "10CB0217-FF02-4474-A1EF-6FD88B5BDAEA")

    /// Configuration service (handles 0x011–0x017) — có trong bộ 3 filter scan của app chính chủ
    static let config        = CBUUID(string: "CF6900A7-4520-4A4C-977C-82979E8BACCF")

    /// Main vehicle control service (handles 0x018–0x03e)
    static let main          = CBUUID(string: "D4905F67-8931-4FAA-8C61-86EC7490F3C5")

    /// Extended service (handles 0x03f–0xffff)
    static let ext           = CBUUID(string: "5B6D1069-A0BC-4875-BA5B-FDC94647D918")

    /// MỚI trên firmware 1.11.0 (E4) — service thứ 5, vai trò chưa xác định (cần GATT-DUMP)
    static let fw11Ext       = CBUUID(string: "F7E2C8A1-3D5B-4906-9E1F-8C0A2B4D6E8F")

    /// LEGACY (fw ≤1.10.x) — alternate scan service UUID seen in some advertisements
    static let altScan       = CBUUID(string: "15111100-3023-455B-86CE-615F79EE8ECE")

    /// All services to discover after connection
    static let allServices: [CBUUID] = [auth, config, main, ext, fw11Ext]

    /// Alias cũ dùng ở một số chỗ — trùng với auth
    static let datBikeService = auth

    /// UUIDs cho foreground & background scan, bao gồm tất cả các Service UUIDs
    /// (giữ legacy scan/altScan cho xe chưa update firmware)
    static let scanUUIDs: [CBUUID] = [scan, auth, config, main, ext, fw11Ext, altScan]

    /// Manufacturer data trong adv fw 1.11.0 = ASCII serial 9 byte (vd "4SSR006xx"),
    /// KHÔNG có company-id prefix 2 byte (E2) → không dùng được bluetoothCompanyIdentifier của ASK.
    static func serial(fromManufacturerData data: Data?) -> String? {
        guard let data, (6...16).contains(data.count) else { return nil }
        guard let s = String(data: data, encoding: .utf8),
              s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return s
    }
}

// MARK: - Characteristic UUIDs
enum BLECharacteristic {
    // — Auth Service —
    
    /// Auth challenge/PIN write (handle 0x00c)
    /// Write PIN here to authenticate. First write triggers SMP pairing if not bonded.
    static let authChallenge   = CBUUID(string: "C8EAF27B-9FB7-4BC3-B11A-BF68C97B1B1F")
    
    /// Auth response (handle 0x00e)
    static let authResponse    = CBUUID(string: "C75EBE03-EA2F-4C0E-A720-1E7112A72D81")
    
    /// Auth token (handle 0x010)
    static let authToken       = CBUUID(string: "91E84EB0-DEA0-436F-A157-F21D89443B32")
    
    // — Config Service —
    
    /// Cấu hình và Dashboard (handle 0x013)
    static let dashboardData   = CBUUID(string: "6D2EB205-6F9B-4ECF-BB1B-A5FAD127C66C")
    
    /// Nhật ký Pin / Battery Info (JSON format)
    static let batteryData     = CBUUID(string: "84C7BE0B-7619-45C1-A503-95F4FF8736ED")
    
    /// Bike Config JSON (name, model, frame, firmware, controller, mainPcb data)
    static let bikeConfigJson  = CBUUID(string: "018E6A6F-4BDA-7B07-8586-1298248A8D5C")
    
    // — Main Service —
    
    /// Vehicle status / BIKE_NAME (handle 0x01a) — READ returns device name string
    static let vehicleStatus   = CBUUID(string: "88C30D2C-F80F-43F8-B0CB-FC1E4AE49BE9")
    
    /// STATUS_FLAGS (handle 0x01c) — 0x08 0x00 observed
    static let statusFlags     = CBUUID(string: "5D681587-C268-4BD3-9560-66EC79DBFDC8")
    
    /// Device serial (alternate, handle 0x022)
    static let deviceSerialAlt = CBUUID(string: "041D5A06-E35F-42D3-92C8-0D421186D2F3")
    
    /// Device model (alternate, handle 0x028)
    static let deviceModelAlt  = CBUUID(string: "4AAE98E9-90B5-492F-8180-9538FA2C843D")
    
    /// Time sync / session token (handle 0x02e)
    static let timeSync        = CBUUID(string: "44E2BDE6-9CD5-4159-9D43-A3E3F4E9C737")
    
    /// Power command (handle 0x030) — WRITE '1' (0x31) bật, '0' (0x30) tắt xe
    static let unlockCmd       = CBUUID(string: "7F13FE5C-1971-4FEC-97FD-F90E16CF8C28")
    
    /// Auto-unlock / proximity token (handle 0x032)
    static let autoUnlock      = CBUUID(string: "87EFAB0D-9E32-4AB8-8916-ED7CB72D819A")
    
    /// Find bike command (handle 0x034) — WRITE '1' start, '0' stop
    static let findBike        = CBUUID(string: "350D9A82-B3F3-4213-BDDA-6403BE495F53")
    
    /// Smartkey echo / lock command (handle 0x036)
    /// READ: status byte. WRITE '1' (0x31) to lock/arm.
    static let smartkeyEcho    = CBUUID(string: "EEC8FD7F-4709-441A-A838-B9EB3066EDE4")
    
    /// Commit hash string (handle 0x03a)
    static let commitHash      = CBUUID(string: "73D50009-ED01-4BB1-BDC2-E89B725A91DB")
    
    /// Firmware version string (handle 0x02a) — e.g. "1.10.1"
    static let fwVersion       = CBUUID(string: "D1DA175E-7E4B-42DB-9EC5-BDD7E929EB6C")
    
    /// LOCK_STATUS — alias of smartkeyEcho
    static let lockStatus      = CBUUID(string: "EEC8FD7F-4709-441A-A838-B9EB3066EDE4")
    
    /// SMARTKEY_FLAG (r) — 0x01 = SmartKey enabled
    static let smartkeyFlag    = CBUUID(string: "69C79762-C574-46D0-8E8B-D2B8D8B1019A")
    
    /// Service Changed (standard BLE, handle 0x008)
    static let serviceChanged  = CBUUID(string: "2A05")
}

// MARK: - Characteristic Key (prefix resolver)
// Firmware 1.11.0 XOAY suffix full UUID nhưng GIỮ nguyên prefix 8 hex
// (bằng chứng E5: fwVersion D1DA175E-7E4B-… (1.10.x) → D1DA175E-B1B5-… (1.11.0)).
// Match characteristic theo prefix để sống qua mọi lần firmware xoay UUID.
// Full UUID gốc trong BLECharacteristic vẫn dùng làm fallback chính xác cho fw cũ.

enum BLECharKey: String, CaseIterable {
    case authChallenge, authResponse, authToken
    case dashboardData, batteryData, bikeConfigJson
    case vehicleStatus, statusFlags, deviceSerialAlt, deviceModelAlt
    case timeSync, unlockCmd, autoUnlock, findBike, smartkeyEcho
    case commitHash, fwVersion, smartkeyFlag, serviceChanged

    /// Prefix 8 hex đầu UUID — định danh ổn định qua các phiên bản firmware
    var uuidPrefix: String {
        switch self {
        case .authChallenge:  return "C8EAF27B"
        case .authResponse:   return "C75EBE03"
        case .authToken:      return "91E84EB0"
        case .dashboardData:  return "6D2EB205"
        case .batteryData:    return "84C7BE0B"
        case .bikeConfigJson: return "018E6A6F"
        case .vehicleStatus:  return "88C30D2C"
        case .statusFlags:    return "5D681587"
        case .deviceSerialAlt: return "041D5A06"
        case .deviceModelAlt: return "4AAE98E9"
        case .timeSync:       return "44E2BDE6"
        case .unlockCmd:      return "7F13FE5C"
        case .autoUnlock:     return "87EFAB0D"
        case .findBike:       return "350D9A82"
        case .smartkeyEcho:   return "EEC8FD7F"
        case .commitHash:     return "73D50009"
        case .fwVersion:      return "D1DA175E"
        case .smartkeyFlag:   return "69C79762"
        case .serviceChanged: return "2A05"
        }
    }

    /// Tra key từ UUID bất kỳ (full UUID fw cũ HOẶC UUID bị xoay suffix của fw mới)
    static func key(forUUID uuid: CBUUID) -> BLECharKey? {
        let s = uuid.uuidString
        return allCases.first { s.hasPrefix($0.uuidPrefix) }
    }
}

// MARK: - Feature Flags

enum BLEFeatureFlags {
    /// AccessorySetupKit (iOS 18+). TẮT từ 5.3.0 — điều khiển bởi BIẾN THỂ BUILD:
    /// define `NOASK` trong SWIFT_ACTIVE_COMPILATION_CONDITIONS → false (release/noask,
    /// main); không define → true (release/ask). Công tắc thật sự nằm ở Info.plist
    /// (3 key NSAccessorySetup*): không có key thì iOS không sandbox CBCentralManager.
    ///
    /// Field test 11/10 (log TN): fw 1.11.0 của xe chỉ còn quảng bá service UUID 128-bit
    /// (10CB0217) — ASK picker KHÔNG match dù descriptor đã khai đủ auth/config/main/scan
    /// (picker hiện 2 lần, chờ 21s + 8s, không thấy xe). Ngoài ra adopt ASK khoá
    /// CBCentralManager ở .poweredOff (state=4) vĩnh viễn khi chưa có accessory →
    /// đường scan classic cũng chết. App chính chủ của hãng KHÔNG dùng ASK (CoreBluetooth
    /// thuần) và thấy xe bình thường → classic là đường duy nhất hoạt động với fw 1.11.0.
    /// Khi bật lại (release/ask): cần khôi phục NSAccessorySetup* trong Info.plist +
    /// kiểm chứng ASK match được UUID 128-bit trên iOS hiện hành.
    static let useASK: Bool = {
        #if NOASK
        return false
        #else
        return true
        #endif
    }()
}

// MARK: - CBCharacteristicProperties helpers

extension CBCharacteristicProperties {
    /// Chuỗi ngắn grep-được cho [GATT-DUMP]: r / w / wnr / n / i
    var shortString: String {
        var parts: [String] = []
        if contains(.read) { parts.append("r") }
        if contains(.write) { parts.append("w") }
        if contains(.writeWithoutResponse) { parts.append("wnr") }
        if contains(.notify) { parts.append("n") }
        if contains(.indicate) { parts.append("i") }
        return parts.joined(separator: ",")
    }
}

// MARK: - Commands

enum BLECommand {
    /// Power OFF / Tắt xe: WRITE 0x30 → unlockCmd
    static let powerOff: Data  = Data([0x30])
    
    /// Power ON / Bật xe: WRITE 0x31 → unlockCmd
    static let powerOn: Data   = Data([0x31])
    
    /// Lock/Arm: WRITE 0x31 → smartkeyEcho
    static let lock: Data      = Data([0x31])
    
    /// Find bike start: WRITE '1' → findBike
    static let findStart: Data = Data([0x31])
    
    /// Find bike stop: WRITE '0' → findBike
    static let findStop: Data  = Data([0x30])
}

// MARK: - Payloads

enum BLELockStatePayload {
    /// Payloads representing LOCKED state (0x00, 0x0000, 0x30, etc.)
    static let locked: [Data]   = [Data(), Data([0x00]), Data([0x00, 0x00]), Data([0x30]), Data([0x30, 0x00])]
    
    /// Payloads representing UNLOCKED state (0x02, 0x0200, 0x31, etc.)
    static let unlocked: [Data] = [Data([0x02]), Data([0x02, 0x00]), Data([0x31]), Data([0x31, 0x00])]
    
    /// Payloads representing ARMED state (0x07, 0x0700)
    static let armed: [Data]    = [Data([0x07]), Data([0x07, 0x00])]
}

// MARK: - Protocol Constants

enum BLEProtocol {
    /// Sinh PIN ngẫu nhiên 12 ký tự (chữ thường, chữ hoa, số, ký tự đặc biệt)
    /// Dùng SecRandomCopyBytes cho entropy cấp mật mã
    static func generateSecurePIN() -> String {
        let lowercase = Array("abcdefghijklmnopqrstuvwxyz")
        let uppercase = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let digits    = Array("0123456789")
        let special   = Array("!@#$%^&*()-_=+")
        let allChars  = lowercase + uppercase + digits + special
        
        func secureRandom(_ bound: Int) -> Int {
            var randomBytes = [UInt8](repeating: 0, count: 1)
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &randomBytes)
            return Int(randomBytes[0]) % bound
        }
        
        // Đảm bảo mỗi loại ít nhất 1 ký tự
        var pin: [Character] = [
            lowercase[secureRandom(lowercase.count)],
            uppercase[secureRandom(uppercase.count)],
            digits[secureRandom(digits.count)],
            special[secureRandom(special.count)]
        ]
        
        // 8 ký tự còn lại từ tất cả
        for _ in 0..<8 {
            pin.append(allChars[secureRandom(allChars.count)])
        }
        
        // Shuffle dùng Fisher-Yates với secure random
        for i in stride(from: pin.count - 1, through: 1, by: -1) {
            let j = secureRandom(i + 1)
            pin.swapAt(i, j)
        }
        
        return String(pin)
    }
    
    static let deviceNamePrefix = "Dat Bike"
    static let deviceNameAltPrefix = "QT_"
    static let rssiThreshold: Int = -65
    static let rssiReadInterval: TimeInterval = 2.0
    static let authConfirmDelay: TimeInterval = 0.12
    static let authSessionDelay: TimeInterval = 0.5
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
