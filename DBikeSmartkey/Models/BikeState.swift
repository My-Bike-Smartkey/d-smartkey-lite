// BikeState.swift — Vehicle state models

import Foundation
import CoreBluetooth

// MARK: - Bike Info

struct BikeInfo: Equatable {
    var name: String = ""
    var serial: String = ""
    var model: String = ""
    var firmware: String = ""
    var deviceToken: String = ""
    
    var isEmpty: Bool {
        name.isEmpty && serial.isEmpty && model.isEmpty
    }
}

// MARK: - Telemetry Data

struct BatteryTelemetry: Decodable, Equatable {
    var voltage: Double?
    var current: Double?
    var soc: BatterySOC?
    var NTCs: [Double]?
    
    /// Dung lượng từng cell pin (mV hoặc V tuỳ firmware)
    /// Firmware Dat Bike thực tế dùng key: "cellVols"
    var cells: [Double]?
    
    // Các thông số bổ sung từ Firmware
    var fet: Double?
    var error: Double?
    var balancing: Double?
    var protections: Double?
    var protection: Double?
    var resistor: Double?
    var discharge: Double?
    var charge: Double?
    
    /// Raw JSON keys chưa decode được (để debug/discover)
    var rawExtraKeys: [String]?
    
    struct BatterySOC: Codable, Equatable {
        var soc: Double?
        var cycles: Double?
    }
    
    enum CodingKeys: String, CodingKey {
        case voltage, current, soc, NTCs
        case cells
        // Các key alias thường gặp 
        case cellVoltages, cellsVoltage, Cells, cell_voltages, volts, cellVols
        // Các key bổ sung
        case fet, error, balancing, protections, protection, resistor, discharge, charge
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        voltage = try container.decodeIfPresent(Double.self, forKey: .voltage)
        current = try container.decodeIfPresent(Double.self, forKey: .current)
        soc = try container.decodeIfPresent(BatterySOC.self, forKey: .soc)
        NTCs = try container.decodeIfPresent([Double].self, forKey: .NTCs)
        
        // Thử decode cell voltages từ nhiều key khác nhau, ưu tiên key thực tế 'cellVols' trước
        if let decoded = try container.decodeIfPresent([Double].self, forKey: .cellVols) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .cells) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .volts) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .cellVoltages) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .cellsVoltage) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .Cells) {
            cells = decoded
        } else if let decoded = try container.decodeIfPresent([Double].self, forKey: .cell_voltages) {
            cells = decoded
        } else {
            cells = nil
        }
        
        // Decode các key bổ sung (dùng try? để tránh crash nếu firmware đổi kiểu dữ liệu thành Int hay String)
        fet = try? container.decodeIfPresent(Double.self, forKey: .fet)
        error = try? container.decodeIfPresent(Double.self, forKey: .error)
        balancing = try? container.decodeIfPresent(Double.self, forKey: .balancing)
        protections = try? container.decodeIfPresent(Double.self, forKey: .protections)
        protection = try? container.decodeIfPresent(Double.self, forKey: .protection)
        resistor = try? container.decodeIfPresent(Double.self, forKey: .resistor)
        discharge = try? container.decodeIfPresent(Double.self, forKey: .discharge)
        charge = try? container.decodeIfPresent(Double.self, forKey: .charge)
        
        // Thu thập tất cả keys đã biết để log (debug discovery)
        let knownKeys: Set<String> = [
            "voltage", "current", "soc", "NTCs",
            "cells", "cellVoltages", "cellsVoltage", "Cells", "cell_voltages", "volts", "cellVols",
            "fet", "error", "balancing", "protections", "protection", "resistor", "discharge", "charge"
        ]
        // Dùng DynamicCodingKeys để tìm keys chưa biết
        if let dynamicContainer = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            let allKeys = dynamicContainer.allKeys.map { $0.stringValue }
            let extra = allKeys.filter { !knownKeys.contains($0) }
            rawExtraKeys = extra.isEmpty ? nil : extra
        }
    }
    
    init() {}
    
    // Equatable: bỏ qua rawExtraKeys
    static func == (lhs: BatteryTelemetry, rhs: BatteryTelemetry) -> Bool {
        lhs.voltage == rhs.voltage && lhs.current == rhs.current
        && lhs.soc == rhs.soc && lhs.NTCs == rhs.NTCs && lhs.cells == rhs.cells
    }
}

/// Dynamic CodingKey cho việc discover JSON keys chưa biết
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

// MARK: - Battery Charging State

enum BatteryChargingState: Equatable {
    case charging, discharging, idle
    
    var label: String {
        switch self {
        case .charging: return "Đang sạc"
        case .discharging: return "Đang xả"
        case .idle: return "Chờ"
        }
    }
    
    var icon: String {
        switch self {
        case .charging: return "bolt.fill"
        case .discharging: return "arrow.down.circle.fill"
        case .idle: return "pause.circle.fill"
        }
    }
}

// MARK: - BatteryTelemetry Analytics Extension

extension BatteryTelemetry {
    /// SOC dạng phần trăm (0–100)
    var socPercent: Int {
        guard let s = soc?.soc else { return 0 }
        return min(100, max(0, Int(s * 100)))
    }
    
    /// Tổng số chu kỳ sạc
    var cycleCount: Int {
        Int(soc?.cycles ?? 0)
    }
    
    /// Sức khoẻ pin ước tính từ số chu kỳ
    /// 100% ở 0 cycles, giảm tuyến tính ~20% sau 1000 cycles
    var healthPercent: Int {
        let cycles = soc?.cycles ?? 0
        let health = max(0, 100 - (cycles / 1000.0) * 20)
        return min(100, Int(health))
    }
    
    /// Công suất tiêu thụ (W) = voltage × |current|
    var powerWatts: Double {
        (voltage ?? 0) * abs(current ?? 0)
    }
    
    /// Trạng thái sạc/xả dựa trên dòng điện
    var chargingState: BatteryChargingState {
        guard let c = current else { return .idle }
        if c > 0.5 { return .charging }
        if c < -0.5 { return .discharging }
        return .idle
    }
    
    /// Nhiệt độ trung bình NTC
    var avgTemp: Double? {
        guard let temps = NTCs, !temps.isEmpty else { return nil }
        return temps.reduce(0, +) / Double(temps.count)
    }
    
    /// Nhiệt độ cao nhất
    var maxTemp: Double? {
        NTCs?.max()
    }
    
    /// Nhiệt độ thấp nhất
    var minTemp: Double? {
        NTCs?.min()
    }
    
    /// Chênh lệch nhiệt độ giữa các sensor
    var tempDelta: Double? {
        guard let temps = NTCs, temps.count >= 2,
              let max = temps.max(), let min = temps.min() else { return nil }
        return max - min
    }
    
    /// Cảnh báo nhiệt độ cao (> 45°C)
    var hasHighTempWarning: Bool {
        guard let max = maxTemp else { return false }
        return max > 45.0
    }
    
    /// Cảnh báo chênh lệch nhiệt độ (> 5°C) — possible cell imbalance
    var hasTempImbalanceWarning: Bool {
        guard let delta = tempDelta else { return false }
        return delta > 5.0
    }
    
    /// Ước tính phạm vi (km) dựa trên SOC — max range 100km cho Quantum S3
    var estimatedRangeKm: Int {
        guard let s = soc?.soc else { return 0 }
        return Int(s * 100.0) // 100km max range
    }
}

struct DashboardTelemetry: Equatable {
    var odometerKm: Float = 0
    var speedKmh: Float = 0
    var motorTemp: Float = 0
    var controllerTemp: Float = 0
    
    init() {}
    
    init(from data: Data) {
        guard data.count >= 40 else { return }
        odometerKm = getFloat(from: data, at: 0)
        speedKmh = getFloat(from: data, at: 4)
        motorTemp = getFloat(from: data, at: 20)
        controllerTemp = getFloat(from: data, at: 24)
    }
    
    private func getFloat(from data: Data, at offset: Int) -> Float {
        guard data.count >= offset + 4 else { return 0 }
        let start = data.startIndex + offset
        let bytes = [UInt8](data[start..<start+4])
        let value = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Float(bitPattern: value)
    }
}

// MARK: - Discovered Bike

struct DiscoveredBike: Identifiable, Equatable {
    var id: String { peripheral.identifier.uuidString }
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
    /// Serial xe parse từ manufacturer data adv (ASCII, vd "4SSR006xx") — fw 1.11.0 (E2)
    var serial: String? = nil

    static func == (lhs: DiscoveredBike, rhs: DiscoveredBike) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Connection State

enum ConnectionState: Equatable {
    case bluetoothOff
    case disconnected
    case scanning
    case connecting
    case sessionVerifying
    case authenticating
    case pairingRequired
    case ready
    case error(String)
    
    var displayText: String {
        switch self {
        case .bluetoothOff:     return "Bluetooth tắt"
        case .disconnected:     return "Đã ngắt kết nối"
        case .scanning:         return "Đang quét..."
        case .connecting:       return "Đang kết nối..."
        case .sessionVerifying: return "Đang khôi phục phiên..."
        case .authenticating:   return "Đang xác thực..."
        case .pairingRequired:  return "Đang xác thực bằng thẻ NFC"
        case .ready:            return "Đã kết nối"
        case .error(let msg):   return "Lỗi: \(msg)"
        }
    }
    
    var isConnected: Bool {
        self == .ready
    }
    
    var isWorking: Bool {
        switch self {
        case .scanning, .connecting, .sessionVerifying, .authenticating, .pairingRequired: return true
        default: return false
        }
    }
    
    var systemImage: String {
        switch self {
        case .bluetoothOff:     return "antenna.radiowaves.left.and.right.slash"
        case .disconnected:     return "antenna.radiowaves.left.and.right.slash"
        case .scanning:         return "antenna.radiowaves.left.and.right"
        case .connecting:       return "bolt.horizontal.circle"
        case .sessionVerifying: return "arrow.2.squarepath"
        case .authenticating:   return "lock.shield"
        case .pairingRequired:  return "sensor.tag.radiowaves.forward"
        case .ready:            return "checkmark.circle.fill"
        case .error:            return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Log Entry

struct BLELogEntry: Identifiable, Codable {
    var id = UUID()
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    /// Thứ tự ưu tiên: error > warning > success > info > verbose
    /// - verbose: Chi tiết kỹ thuật (RSSI mỗi 2s, STANDBY_CHECK...) — chỉ ghi khi Verbose Logging BẬT
    /// - info: Sự kiện quan trọng (state transition, connect, auth)
    /// - success: Thành công rõ ràng (auth OK, connect OK)
    /// - warning: Cảnh báo cần chú ý (timeout, retry, disconnect)
    /// - error: Lỗi nghiêm trọng cần điều tra
    enum LogLevel: String, Codable, Comparable {
        case verbose = "[VERBOSE]"
        case info    = "[INFO]"
        case success = "[SUCCESS]"
        case warning = "[WARNING]"
        case error   = "[ERROR]"
        case ble     = "[BLE]"
        
        private var order: Int {
            switch self {
            case .verbose: return 0
            case .info:    return 1
            case .ble:     return 1
            case .success: return 2
            case .warning: return 3
            case .error:   return 4
            }
        }
        static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.order < rhs.order }
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Persistent Logger

final class PersistentLogger {
    
    static let shared = PersistentLogger()
    
    private let logDir: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "\(Bundle.main.bundleIdentifier ?? "app.mybike.smartkey").persistentlogger", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let settingsLock = NSLock()
    private let sessionMarker = "────────── Phiên mới ──────────"
    private let maxKeepDays = 365
    
    // Current day's file handle
    private var currentHandle: FileHandle?
    private var currentDate: String?
    
    // MARK: - Logging Control
    
    /// Chỉ điều khiển log chi tiết; sự kiện INFO/BLE/SUCCESS/WARNING/ERROR luôn lưu.
    private var detailedLoggingEnabled = true
    var isLoggingEnabled: Bool {
        get { settingsLock.withLock { detailedLoggingEnabled } }
        set { settingsLock.withLock { detailedLoggingEnabled = newValue } }
    }
    
    /// Mức log tối thiểu được ghi. Mặc định .info (bỏ qua .verbose).
    private var configuredMinimumLevel: BLELogEntry.LogLevel = .info
    var minimumLevel: BLELogEntry.LogLevel {
        get { settingsLock.withLock { configuredMinimumLevel } }
        set { settingsLock.withLock { configuredMinimumLevel = newValue } }
    }
    
    init(directory: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logDir = directory ?? docs.appendingPathComponent("ble_logs", isDirectory: true)
        queue.setSpecific(key: queueKey, value: ())
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Create log directory
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        
        // Cleanup old files on init
        queue.async { [weak self] in
            self?.cleanupOldFiles()
        }
    }
    
    // MARK: - Write
    
    func append(_ entry: BLELogEntry) {
        // Cả ASK và Lite luôn giữ timeline kết nối/lệnh/lỗi, kể cả khi tắt debug.
        let includeVerbose = settingsLock.withLock {
            detailedLoggingEnabled && configuredMinimumLevel <= .verbose
        }
        guard entry.level != .verbose || includeVerbose else { return }
        
        queue.async { [weak self] in
            guard let self else { return }
            let ts = Int64(entry.timestamp.timeIntervalSince1970 * 1000)
            let escaped = entry.message
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\t", with: "\\t")
            let line = "\(ts)\t\(entry.level.rawValue)\t\(escaped)\n"
            
            guard let data = line.data(using: .utf8) else { return }
            
            do {
                let handle = try self.getHandle()
                handle.seekToEndOfFile()
                handle.write(data)
            } catch {
                #if DEBUG
                print("[PersistentLogger] Write error: \(error)")
                #endif
            }
        }
    }
    
    func markSessionStart() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let entry = BLELogEntry(timestamp: Date(), level: .info,
            message: "\(sessionMarker) | app=\(bundle.bundleIdentifier ?? "unknown") | version=\(version)(\(build)) | os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        append(entry)
    }

    /// Các thao tác đọc/xuất phải thấy mọi entry đã nhận trước đó.
    private func drainPendingWrites() {
        if DispatchQueue.getSpecific(key: queueKey) == nil { queue.sync {} }
    }
    
    // MARK: - Read
    
    /// Load logs from the last N days (inclusive of today). Oldest → newest.
    func loadLogs(daysBack: Int = 7) -> [BLELogEntry] {
        drainPendingWrites()
        var entries: [BLELogEntry] = []
        let files = getRecentFiles(daysBack: daysBack)
        for file in files {
            entries.append(contentsOf: parseLogFile(file))
        }
        return entries
    }
    
    /// Load ALL logs from storage.
    func loadAllLogs() -> [BLELogEntry] {
        var entries: [BLELogEntry] = []
        for file in getLogFiles() {
            entries.append(contentsOf: parseLogFile(file))
        }
        return entries
    }
    
    /// Get total size of all log files in bytes.
    func totalSizeBytes() -> Int64 {
        getLogFiles().reduce(0) { sum, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return sum + size
        }
    }
    
    /// Get sorted list of all log files (oldest first).
    func getLogFiles() -> [URL] {
        drainPendingWrites()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    
    /// Export all logs as a single text string for sharing.
    /// - Parameter redactFrameNumber: Nếu true, thay thế số khung xe bằng ***REDACTED***
    func exportAllAsText(redactFrameNumber: Bool = false) -> String {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        var sb = ""
        for file in getLogFiles() {
            for entry in parseLogFile(file) {
                let message = textForSharing(entry.message, redactIdentifiers: redactFrameNumber)
                sb += "\(timeFmt.string(from: entry.timestamp)) \(entry.level.rawValue) \(message)\n"
            }
        }
        return sb
    }

    func textForSharing(_ message: String, redactIdentifiers: Bool) -> String {
        guard redactIdentifiers else { return message }
        let preferences = PreferencesManager.shared
        return Self.redact(message, identifiers: [preferences.savedBikeSerial,
            preferences.savedBikeMac, preferences.savedPeripheralUUID].compactMap { $0 })
    }

    /// Chỉ che định danh xe; giữ nguyên service/characteristic UUID để chẩn đoán GATT.
    static func redact(_ message: String, identifiers: [String]) -> String {
        var result = message
        if result.contains("BLE ADV DEBUG — CoreBluetooth / Lite") {
            // A raw debug report may have been saved before the user enabled
            // redaction in the log exporter. Preserve UUID keys, hide their bytes.
            result = result.replacingOccurrences(
                of: #"(?m)^(device|cachedName|advName|mfgASCII|mfg|serviceData\[[^\]\r\n]+\])=.*$"#,
                with: "$1=***REDACTED***", options: .regularExpression)
        }
        for identifier in identifiers where !identifier.isEmpty {
            for value in [identifier, Data(identifier.utf8).hexString] {
                result = result.replacingOccurrences(of: value, with: "***REDACTED***", options: .caseInsensitive)
            }
        }
        for pattern in [
            #"(?i)\bmfg=(?:[0-9a-f]{2})+"#,
            #"(?i)\bserial=[a-z0-9]{6,16}\b"#,
            #"(?i)(?:[0-9a-f]{2}:){5}[0-9a-f]{2}"#,
            #"(?i)"(?:frame|frameNumber|frame_number|serial|serialNumber|serial_number|mac|macAddress|mac_address|ble_mac|bleMac)"\s*:\s*"[^"]*""#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "***REDACTED***", options: .regularExpression)
        }
        return result
    }
    
    // MARK: - Delete
    
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closeHandle()
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: self.logDir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
    
    // MARK: - Internal
    
    private func getHandle() throws -> FileHandle {
        let today = dateFormatter.string(from: Date())
        if today != currentDate || currentHandle == nil {
            closeHandle()
            currentDate = today
            let fileURL = logDir.appendingPathComponent("ble_\(today).log")
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }
            currentHandle = try FileHandle(forWritingTo: fileURL)
        }
        return currentHandle!
    }
    
    private func closeHandle() {
        try? currentHandle?.close()
        currentHandle = nil
    }
    
    private func getRecentFiles(daysBack: Int) -> [URL] {
        // DateFormatter của writer chỉ được sử dụng trên queue; reader dùng bản riêng.
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        var dates: [String] = []
        var date = Date()
        for _ in 0..<daysBack {
            dates.append(dateFormatter.string(from: date))
            date = cal.date(byAdding: .day, value: -1, to: date) ?? date
        }
        
        let fm = FileManager.default
        return dates.reversed().compactMap { dateStr in
            let url = logDir.appendingPathComponent("ble_\(dateStr).log")
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }
    
    private func parseLogFile(_ url: URL) -> [BLELogEntry] {
        var entries: [BLELogEntry] = []
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return entries }
        
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3,
                  let tsMs = Int64(parts[0]) else { continue }
            
            let levelStr = parts[1]
            let level: BLELogEntry.LogLevel
            switch levelStr {
            case "[VERBOSE]": level = .verbose
            case "[INFO]":    level = .info
            case "[SUCCESS]": level = .success
            case "[WARNING]": level = .warning
            case "[ERROR]":   level = .error
            case "[BLE]":     level = .ble
            default:          continue
            }
            
            let message = parts.dropFirst(2).joined(separator: "\t")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            
            let timestamp = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
            entries.append(BLELogEntry(timestamp: timestamp, level: level, message: message))
        }
        return entries
    }
    
    private func cleanupOldFiles() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -maxKeepDays, to: Date()) else { return }
        let cutoffStr = dateFormatter.string(from: cutoff)
        
        for file in getLogFiles() {
            let dateStr = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "ble_", with: "")
            if dateStr < cutoffStr {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
