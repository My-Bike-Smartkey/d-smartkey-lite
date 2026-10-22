import Foundation
import Combine
import Security

private enum PairingPINKeychain {
    private static let service = "app.mybike.smartkey.pairing"
    private static let account = "vehicle-pin"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> (String?, OSStatus) {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &item)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = item as? Data,
              let pin = String(data: data, encoding: .utf8) else { return (nil, errSecDecode) }
        return (pin, status)
    }

    static func save(_ pin: String) -> OSStatus {
        let data = Data(pin.utf8)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecDuplicateItem else { return status }
        return SecItemUpdate(query as CFDictionary,
                             [kSecValueData as String: data,
                              kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
    }

    static func delete() -> OSStatus {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }
}

/// §4 (P3) — Ý định kết nối của user. Nguồn sự thật DUY NHẤT cho mọi auto-connect.
/// - `autoConnect`: hành vi mặc định (aggressive reconnect như trước nay).
/// - `manualOnly`: app NGẮT BLE một lần và KHÔNG tự kết nối lại bởi bất kỳ trigger
///   nào (RSSI, foreground, BT toggle, relaunch, ASK, deep link). Chỉ thoát khi
///   user chủ động ("Kết nối để dùng xe" / resume / deep-link explicit).
enum ConnectionIntent: String, CaseIterable {
    case autoConnect
    /// Nút "Tạm dừng" (PAUSE cũ)
    case manualOnlyPausedByUser
    /// Nút "Ở gần xe, chưa dùng" — dẹp loop RSSI standby↔nearby↔code6
    case manualOnlyNearbyNotInUse

    var isManualOnly: Bool { self != .autoConnect }
}

/// Quản lý tập trung mọi tùy chọn hệ thống cài đặt của App.
/// Loại bỏ hoàn toàn sự rải rác của `UserDefaults.standard` trong mã nguồn.
class PreferencesManager {
    static let shared = PreferencesManager()

    /// App Group đọc từ Info.plist (`AppGroupIdentifier`) — mỗi biến thể build khai
    /// giá trị riêng để 2 app (D-SmartKey + D-SmartKey Lite) cài song song không
    /// đọc chung PIN/UUID của nhau.
    static let appGroupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        ?? "group.app.mybike.smartkey"

    var sharedDefaults: UserDefaults {
        // stored khi inject qua init, fallback App Group cho mọi truy cập tĩnh khác
        injectedDefaults ?? UserDefaults(suiteName: Self.appGroupID) ?? UserDefaults.standard
    }
    private let injectedDefaults: UserDefaults?
    private var pairingPINPrecommitted = false

    /// Init nội bộ có thể inject defaults (testability §4.5);
    /// production dùng `PreferencesManager.shared` với App Group suite.
    init(defaults: UserDefaults? = nil) {
        self.injectedDefaults = defaults
        let d = defaults ?? UserDefaults(suiteName: Self.appGroupID) ?? UserDefaults.standard
        // Migrate data from standard UserDefaults to App Group if needed
        if !d.bool(forKey: "hasMigratedToAppGroup") {
            let standard = UserDefaults.standard
            let keys = ["rssiThreshold", "autoUnlockEnabled", "autoTurnOnThreshold", "isDebugModeEnabled", "connectOnlyWhenNear", "notificationsEnabled", "lastPeripheralUUID", "lastTimeSyncDate"]
            for key in keys {
                if let val = standard.object(forKey: key) {
                    d.set(val, forKey: key)
                }
            }
            d.set(true, forKey: "hasMigratedToAppGroup")
        }
        
        let storedRssi = d.double(forKey: "rssiThreshold")
        if storedRssi == 0 || storedRssi == -65.0 || storedRssi == -80.0 {
            self.rssiThreshold = -75.0
            d.set(-75.0, forKey: "rssiThreshold")
        } else {
            self.rssiThreshold = storedRssi
        }
        
        self.autoUnlockEnabled = d.bool(forKey: "autoUnlockEnabled")
        
        let storedAutoTurnOn = d.double(forKey: "autoTurnOnThreshold")
        if storedAutoTurnOn == 0 || storedAutoTurnOn == -70.0 {
            self.autoTurnOnThreshold = -50.0
            d.set(-50.0, forKey: "autoTurnOnThreshold")
        } else {
            self.autoTurnOnThreshold = storedAutoTurnOn
        }
        
        if d.object(forKey: "notificationsEnabled") == nil {
            self.notificationsEnabled = true
            d.set(true, forKey: "notificationsEnabled")
        } else {
            self.notificationsEnabled = d.bool(forKey: "notificationsEnabled")
        }
        
        self.connectOnlyWhenNear = d.bool(forKey: "connectOnlyWhenNear")
        self.nearbyModeEnabled = d.bool(forKey: "nearbyModeEnabled")
        self.isDebugModeEnabled = d.object(forKey: "isDebugModeEnabled") as? Bool ?? false
        
        // ═══ XOÁ KEYCHAIN KHI CÀI LẠI APP (FRESH INSTALL) ═══
        // UserDefaults bị xóa khi gỡ app, nhưng Keychain thì không.
        // Dùng cờ isFirstRun để nhận diện app vừa cài mới hoàn toàn và dọn dẹp Keychain cũ.
        if d.object(forKey: "isFirstRun") == nil && UserDefaults.standard.object(forKey: "isFirstRun") == nil {
            _ = PairingPINKeychain.delete()
            d.set(false, forKey: "isFirstRun")
            UserDefaults.standard.set(false, forKey: "isFirstRun")
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[INIT] Lần chạy đầu tiên (Fresh Install) -> Đã xóa PIN thừa trong Keychain."))
        }
        
        if defaults != nil {
            // Tests can keep their isolated defaults; production secrets use Keychain.
            self.savedPin = d.string(forKey: "savedPin")
        } else if d.bool(forKey: "pairingPINDeletionPending") {
            self.savedPin = nil
            if PairingPINKeychain.delete() == errSecSuccess {
                d.removeObject(forKey: "pairingPINDeletionPending")
            }
            d.removeObject(forKey: "savedPin")
            UserDefaults.standard.removeObject(forKey: "savedPin")
        } else {
            let (storedPIN, status) = PairingPINKeychain.load()
            if status == errSecSuccess {
                self.savedPin = storedPIN
                d.removeObject(forKey: "savedPin")
                UserDefaults.standard.removeObject(forKey: "savedPin")
            } else if status == errSecItemNotFound,
                      let legacyPIN = d.string(forKey: "savedPin") ?? UserDefaults.standard.string(forKey: "savedPin"),
                      PairingPINKeychain.save(legacyPIN) == errSecSuccess {
                self.savedPin = legacyPIN
                d.removeObject(forKey: "savedPin")
                UserDefaults.standard.removeObject(forKey: "savedPin")
            } else {
                // Before first unlock Keychain can be unavailable. Fail closed and
                // retry when protected data becomes available; keep legacy data
                // until migration actually succeeds.
                self.savedPin = nil
            }
        }
        self.savedPeripheralUUID = d.string(forKey: "lastPeripheralUUID")

        // ═══ §4.5 (P3): MIGRATION một chiều isUserPaused → connectionIntent ═══
        if let raw = d.string(forKey: "connectionIntent"),
           let intent = ConnectionIntent(rawValue: raw) {
            self.connectionIntent = intent
        } else if d.object(forKey: "isUserPaused") != nil,
                  d.bool(forKey: "isUserPaused") {
            self.connectionIntent = .manualOnlyPausedByUser
            d.set(ConnectionIntent.manualOnlyPausedByUser.rawValue, forKey: "connectionIntent")
        } else {
            self.connectionIntent = .autoConnect
        }
        
        self.savedBikeName = d.string(forKey: "savedBikeName")
        self.savedBikeSerial = d.string(forKey: "savedBikeSerial")
        self.savedBikeMac = d.string(forKey: "savedBikeMac")
        self.savedBikeModel = d.string(forKey: "savedBikeModel")
        self.savedBikeFirmware = d.string(forKey: "savedBikeFirmware")
        
        // Granular notification preferences — default true
        self.notifyOnConnected    = d.object(forKey: "notifyOnConnected")    as? Bool ?? true
        self.notifyOnDisconnected = d.object(forKey: "notifyOnDisconnected") as? Bool ?? true
        self.notifyOnStandby      = d.object(forKey: "notifyOnStandby")      as? Bool ?? true
        self.notifyOnAutoTurnOn   = d.object(forKey: "notifyOnAutoTurnOn")   as? Bool ?? true
        
        // BMS notification preferences — default true (except threshold which defaults to 20%)
        self.notifyOnBatteryFull      = d.object(forKey: "notifyOnBatteryFull")      as? Bool ?? true
        self.notifyOnBatteryThreshold = d.object(forKey: "notifyOnBatteryThreshold") as? Bool ?? true
        self.notifyOnChargeDisconnect = d.object(forKey: "notifyOnChargeDisconnect") as? Bool ?? true
        self.batteryLowThreshold      = d.integer(forKey: "batteryLowThreshold") > 0 ? d.integer(forKey: "batteryLowThreshold") : 20
        self.skipProximityToken        = d.object(forKey: "skipProximityToken") as? Bool ?? false
        self.redactFrameNumber         = d.object(forKey: "redactFrameNumber") as? Bool ?? true
        
        // Logging toggle — mặc định BẬT
        let loggingEnabled = d.object(forKey: "isLoggingEnabled") as? Bool ?? true
        self.isLoggingEnabled = loggingEnabled
        PersistentLogger.shared.isLoggingEnabled = loggingEnabled
        
        let verboseEnabled = d.object(forKey: "verboseLoggingEnabled") as? Bool ?? false
        self.verboseLoggingEnabled = verboseEnabled
        PersistentLogger.shared.minimumLevel = verboseEnabled ? .verbose : .info
    }

    /// §4 (P3): intent kết nối — thay thế isUserPaused (migration một chiều:
    /// isUserPaused==true ⇒ manualOnlyPausedByUser; giữ key cũ 2 release rồi xóa).
    @Published var connectionIntent: ConnectionIntent {
        didSet { sharedDefaults.set(connectionIntent.rawValue, forKey: "connectionIntent") }
    }

    var isManualOnly: Bool { connectionIntent.isManualOnly }
    
    @Published var rssiThreshold: Double {
        didSet { sharedDefaults.set(rssiThreshold, forKey: "rssiThreshold") }
    }
    
    @Published var autoUnlockEnabled: Bool {
        didSet { sharedDefaults.set(autoUnlockEnabled, forKey: "autoUnlockEnabled") }
    }
    
    @Published var autoTurnOnThreshold: Double {
        didSet { sharedDefaults.set(autoTurnOnThreshold, forKey: "autoTurnOnThreshold") }
    }
    
    @Published var isDebugModeEnabled: Bool {
        didSet { sharedDefaults.set(isDebugModeEnabled, forKey: "isDebugModeEnabled") }
    }
    
    @Published var connectOnlyWhenNear: Bool {
        didSet { sharedDefaults.set(connectOnlyWhenNear, forKey: "connectOnlyWhenNear") }
    }
    
    /// Chế độ "Đang ở gần": phát hiện xe gần nhưng KHÔNG tự auth/bật xe.
    /// Khi user mở app (foreground) mới auth.
    @Published var nearbyModeEnabled: Bool {
        didSet { sharedDefaults.set(nearbyModeEnabled, forKey: "nearbyModeEnabled") }
    }
    
    @Published var notificationsEnabled: Bool {
        didSet { sharedDefaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    
    // MARK: - Granular Notification Preferences
    // Mỗi loại thông báo có thể tắt riêng biệt (mặc định: bật hết)
    
    @Published var notifyOnConnected: Bool {
        didSet { sharedDefaults.set(notifyOnConnected, forKey: "notifyOnConnected") }
    }
    
    @Published var notifyOnDisconnected: Bool {
        didSet { sharedDefaults.set(notifyOnDisconnected, forKey: "notifyOnDisconnected") }
    }
    
    @Published var notifyOnStandby: Bool {
        didSet { sharedDefaults.set(notifyOnStandby, forKey: "notifyOnStandby") }
    }
    
    @Published var notifyOnAutoTurnOn: Bool {
        didSet { sharedDefaults.set(notifyOnAutoTurnOn, forKey: "notifyOnAutoTurnOn") }
    }
    
    // MARK: - Battery/BMS Notification Preferences
    
    @Published var notifyOnBatteryFull: Bool {
        didSet { sharedDefaults.set(notifyOnBatteryFull, forKey: "notifyOnBatteryFull") }
    }
    
    @Published var notifyOnBatteryThreshold: Bool {
        didSet { sharedDefaults.set(notifyOnBatteryThreshold, forKey: "notifyOnBatteryThreshold") }
    }
    
    @Published var notifyOnChargeDisconnect: Bool {
        didSet { sharedDefaults.set(notifyOnChargeDisconnect, forKey: "notifyOnChargeDisconnect") }
    }
    
    @Published var batteryLowThreshold: Int {
        didSet { sharedDefaults.set(batteryLowThreshold, forKey: "batteryLowThreshold") }
    }
    
    /// Bật/tắt ghi log bỏợi PersistentLogger
    @Published var isLoggingEnabled: Bool {
        didSet {
            sharedDefaults.set(isLoggingEnabled, forKey: "isLoggingEnabled")
            PersistentLogger.shared.isLoggingEnabled = isLoggingEnabled
        }
    }
    
    /// Ghi cả log VERBOSE (RSSI, STANDBY_CHECK...) — chỉ bật khi debug sâu
    @Published var verboseLoggingEnabled: Bool {
        didSet {
            sharedDefaults.set(verboseLoggingEnabled, forKey: "verboseLoggingEnabled")
            PersistentLogger.shared.minimumLevel = verboseLoggingEnabled ? .verbose : .info
        }
    }
    
    @Published var skipProximityToken: Bool {
        didSet { sharedDefaults.set(skipProximityToken, forKey: "skipProximityToken") }
    }
    
    /// Ẩn số khung xe trong log khi chia sẻ — bảo vệ quyền riêng tư
    @Published var redactFrameNumber: Bool {
        didSet { sharedDefaults.set(redactFrameNumber, forKey: "redactFrameNumber") }
    }
    
    var savedPin: String? {
        didSet {
            if injectedDefaults != nil {
                sharedDefaults.set(savedPin, forKey: "savedPin")
                return
            }
            if let pin = savedPin {
                if pairingPINPrecommitted {
                    pairingPINPrecommitted = false
                } else {
                    let status = PairingPINKeychain.save(pin)
                    guard status == errSecSuccess else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                            message: "Không lưu được PIN vào Keychain (status=\(status))"))
                        savedPin = oldValue
                        return
                    }
                }
                sharedDefaults.removeObject(forKey: "pairingPINDeletionPending")
                sharedDefaults.removeObject(forKey: "savedPin")
                UserDefaults.standard.removeObject(forKey: "savedPin")
            } else {
                // Persist a tombstone first so an inaccessible Keychain item can
                // never resurrect a pairing after the user removes the bike.
                sharedDefaults.set(true, forKey: "pairingPINDeletionPending")
                let status = PairingPINKeychain.delete()
                if status == errSecSuccess {
                    sharedDefaults.removeObject(forKey: "pairingPINDeletionPending")
                } else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Sẽ xóa PIN Keychain khi dữ liệu bảo vệ sẵn sàng (status=\(status))"))
                }
                sharedDefaults.removeObject(forKey: "savedPin")
                UserDefaults.standard.removeObject(forKey: "savedPin")
            }
        }
    }

    /// Commit to protected storage before publishing enrollment to the app.
    @discardableResult
    func commitPairingPIN(_ pin: String) -> Bool {
        if injectedDefaults != nil {
            savedPin = pin
            return true
        }
        let status = PairingPINKeychain.save(pin)
        guard status == errSecSuccess else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Không lưu được PIN vào Keychain (status=\(status))"))
            return false
        }
        pairingPINPrecommitted = true
        savedPin = pin
        return true
    }

    /// Retry after first device unlock. Returns true only when a paired PIN became available.
    @discardableResult
    func refreshSavedPinFromKeychain() -> Bool {
        guard injectedDefaults == nil else { return false }
        if sharedDefaults.bool(forKey: "pairingPINDeletionPending") {
            if PairingPINKeychain.delete() == errSecSuccess {
                sharedDefaults.removeObject(forKey: "pairingPINDeletionPending")
            }
            return false
        }
        guard savedPin == nil else { return false }
        let (pin, status) = PairingPINKeychain.load()
        if status == errSecSuccess, let pin {
            savedPin = pin
            return savedPin != nil
        }
        if status == errSecItemNotFound,
           let legacyPIN = sharedDefaults.string(forKey: "savedPin") ?? UserDefaults.standard.string(forKey: "savedPin"),
           PairingPINKeychain.save(legacyPIN) == errSecSuccess {
            savedPin = legacyPIN
            return savedPin != nil
        }
        return false
    }
    
    
    @Published var savedPeripheralUUID: String? {
        didSet { sharedDefaults.set(savedPeripheralUUID, forKey: "lastPeripheralUUID") }
    }
    
    @Published var savedBikeName: String? {
        didSet { sharedDefaults.set(savedBikeName, forKey: "savedBikeName") }
    }
    
    @Published var savedBikeSerial: String? {
        didSet { sharedDefaults.set(savedBikeSerial, forKey: "savedBikeSerial") }
    }
    
    @Published var savedBikeMac: String? {
        didSet { sharedDefaults.set(savedBikeMac, forKey: "savedBikeMac") }
    }
    
    @Published var savedBikeModel: String? {
        didSet { sharedDefaults.set(savedBikeModel, forKey: "savedBikeModel") }
    }
    
    @Published var savedBikeFirmware: String? {
        didSet { sharedDefaults.set(savedBikeFirmware, forKey: "savedBikeFirmware") }
    }
    
    /// Ngày cuối cùng đã sync time với xe — dùng để auto sync 1 lần/ngày
    var lastTimeSyncDate: Date? {
        get { sharedDefaults.object(forKey: "lastTimeSyncDate") as? Date }
        set { sharedDefaults.set(newValue, forKey: "lastTimeSyncDate") }
    }
    
    /// Kiểm tra hôm nay đã sync time chưa
    var needsTimeSyncToday: Bool {
        guard let last = lastTimeSyncDate else { return true }
        return !Calendar.current.isDateInToday(last)
    }
}
