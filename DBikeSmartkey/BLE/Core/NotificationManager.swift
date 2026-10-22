//
//  NotificationManager.swift
//  DBikeSmartkey
//

import Foundation
import UserNotifications

/// Các nhóm thông báo, map 1-1 với identifier và preference keys
enum NotificationCategory: String {
    case connected        = "Connected"
    case disconnected     = "DowngradeToStandby"
    case standby          = "StandbyProximity"
    case autoTurnOn       = "AutoTurnOn"
    case batteryFull      = "BatteryFull"
    case batteryLow       = "BatteryLow"
    case chargeDisconnect = "ChargeDisconnect"
    
    /// Kiểm tra preference của từng loại
    var isEnabled: Bool {
        let prefs = PreferencesManager.shared
        switch self {
        case .connected:    return prefs.notifyOnConnected
        case .disconnected: return prefs.notifyOnDisconnected
        case .standby:      return prefs.notifyOnStandby
        case .autoTurnOn:   return prefs.notifyOnAutoTurnOn
        case .batteryFull:  return prefs.notifyOnBatteryFull
        case .batteryLow:   return prefs.notifyOnBatteryThreshold
        case .chargeDisconnect: return prefs.notifyOnChargeDisconnect
        }
    }
}

class NotificationManager: NSObject, @unchecked Sendable, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    private let lock = NSLock()
    private var lastNotificationTimes: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 10.0 // 10 giây debounce cho tất cả
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    // Bắt buộc thực thi hàm này để hiển thị Notification ngay cả khi App đang mở trên màn hình (Foreground)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
    
    func requestPermission(completion: @escaping () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning, message: "Lỗi xin quyền thông báo: \(error.localizedDescription)"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "Quyền thông báo hệ thống: \(granted ? "Đã cấp" : "Từ chối")"))
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }
    
    func sendNotification(title: String, body: String, identifier: String, sound: UNNotificationSound? = UNNotificationSound.default) {
        // Gate 1: Master toggle tắt → block hết
        if !PreferencesManager.shared.notificationsEnabled {
            return
        }
        
        // Gate 2: Check per-type preference (nếu identifier map được sang category)
        if let category = NotificationCategory(rawValue: identifier), !category.isEnabled {
            return
        }
        
        // Gate 3: Debounce — tránh spam cùng 1 loại thông báo (Thread-Safe với NSLock)
        let now = Date()
        lock.lock()
        if let lastTime = lastNotificationTimes[identifier] {
            if now.timeIntervalSince(lastTime) < debounceInterval {
                lock.unlock()
                return
            }
        }
        lastNotificationTimes[identifier] = now
        lock.unlock()
        
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error, message: "Lỗi Local Notification: \(error.localizedDescription)"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success, message: "Đã push: \(title)"))
            }
        }
    }
}
