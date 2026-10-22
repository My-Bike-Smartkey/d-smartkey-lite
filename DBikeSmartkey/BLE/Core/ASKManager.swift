import Foundation
import CoreBluetooth
import Combine
import UIKit
#if canImport(AccessorySetupKit)
import AccessorySetupKit
#endif

// Biến thể NOASK (iOS 16, foreground-only) không dùng AccessorySetupKit —
// cả file bị loại khỏi build; Info.plist cũng không có key NSAccessorySetup*.
#if !NOASK

/// ASK validates descriptors with a fatal trap, not a recoverable completion error.
/// Keep Bluetooth discovery service-based: a name alone is not a valid descriptor.
@available(iOS 18.0, *)
enum ASKDiscoveryConfiguration {
    enum ValidationError: Error, Equatable {
        case bluetoothNotDeclared
        case emptyDescriptors
        case missingServiceUUID
        case undeclaredServiceUUID(String)
        case undeclaredName(String)
    }

    static func makeDescriptors() -> [ASDiscoveryDescriptor] {
        // Current firmware advertises auth/config/main; FCF1 supports older firmware.
        // Do not constrain discovery by the owner-assigned name of the bike.
        [BLEService.auth, BLEService.config, BLEService.main, BLEService.scan].map { service in
            let descriptor = ASDiscoveryDescriptor()
            descriptor.bluetoothServiceUUID = service
            return descriptor
        }
    }

    static func validate(_ descriptors: [ASDiscoveryDescriptor], info: [String: Any]) throws {
        guard (info["NSAccessorySetupKitSupports"] as? [String])?.contains("Bluetooth") == true else {
            throw ValidationError.bluetoothNotDeclared
        }
        guard !descriptors.isEmpty else { throw ValidationError.emptyDescriptors }
        let declaredServices = (info["NSAccessorySetupBluetoothServices"] as? [String] ?? [])
            .map { CBUUID(string: $0) }
        let declaredNames = info["NSAccessorySetupBluetoothNames"] as? [String] ?? []
        for descriptor in descriptors {
            // This app uses service-based descriptors, never name-only/company-only filters.
            guard let service = descriptor.bluetoothServiceUUID else {
                throw ValidationError.missingServiceUUID
            }
            guard declaredServices.contains(service) else {
                throw ValidationError.undeclaredServiceUUID(service.uuidString)
            }
            if let name = descriptor.bluetoothNameSubstring, !declaredNames.contains(name) {
                throw ValidationError.undeclaredName(name)
            }
        }
    }
}

/// ASKManager — cầu nối AccessorySetupKit (iOS 18+), theo chuẩn Apple
/// "Discovering and configuring accessories"
/// (developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories).
///
/// Bản chất ASK: cửa MỘT LẦN lúc ghép đôi (scoped Bluetooth permission) —
/// KHÔNG phát event proximity/kết nối. Reconnect khi lại gần xe là việc của
/// CoreBluetooth (pending connect + bluetooth-central + state restoration).
///
/// Các quy tắc Apple đã khắc phục so với bản cũ:
///  F1  UUID dịch vụ trong advertisement là bộ lọc chính. Không bắt buộc tên
///      "Dat Bike"/"QT_": firmware có thể quảng bá tên xe đã được đổi.
///      Mọi giá trị descriptor phải nằm trong Info.plist (NSAccessorySetupBluetooth*).
///  F2  `session.accessories` chỉ đáng tin SAU event `.activated` → track
///      isActivated. showPicker() chỉ được gọi từ user gesture (startPairing),
///      không bao giờ tự mở (cold-launch / error path).
///  F3  showPicker completion có thể trả nil ngay khi picker VỪA HIỆN.
///      Chỉ `.pickerDidDismiss` xác nhận picker đã đóng; callback lỗi trình bày
///      xử lý riêng để không mở lại picker trong lúc iOS còn chuyển cảnh.
///  F4  `.accessoryRemoved` → onAccessoryRemoved(uuid) để core dọn pairing cũ
///      (user gỡ xe trong Settings iOS).
///  F5  `.accessoryChanged` (đổi tên/thông tin) tách khỏi `.accessoryAdded` —
///      KHÔNG trigger connect. Lưu ý (log 18-19/09): sự kiện này thực tế chỉ đến
///      ~10-30ms sau `.activated` (snapshot lúc activate), không phải proximity
///      event nền. Tín hiệu dùng được là `.activated` + accessories chứa uuid xe
///      → xem `onSessionActivated` (F6-REV 5.2.0).
@available(iOS 18.0, *)
final class ASKManager: NSObject {
    static let shared = ASKManager()

    // MARK: - Trạng thái (F2)

    /// Đã nhận `.activated` từ hệ thống. `accessories` / `hasAuthorizedAccessory`
    /// chỉ đáng tin khi cờ này true. Reset khi session bị invalidate.
    @Published private(set) var isActivated = false

    // MARK: - Callbacks

    /// User vừa chọn xe trong picker (uuid = bluetoothIdentifier cho CoreBluetooth).
    var onAccessorySelected: ((UUID) -> Void)?

    /// F4: accessory bị gỡ khỏi hệ thống (Settings iOS) với UUID khớp.
    var onAccessoryRemoved: ((UUID) -> Void)?

    /// F3: picker đã đóng — chọn xong hoặc cancel. Fire đúng 1 lần/lần mở.
    var onPickerDismissed: ((Error?) -> Void)?

    /// F6-REV (5.2.0): session vừa `.activated` — kèm bluetoothIdentifier của các
    /// accessory ĐÃ GHÉP (danh sách ghép đôi, KHÔNG phải "đang trong tầm sóng").
    /// Core dùng làm trigger lúc app mở: chuyển pending connect sang lượt
    /// foreground có timeout hoặc kích kết nối nếu ladder đã bỏ cuộc.
    var onSessionActivated: (([UUID]) -> Void)?

    private var session: ASAccessorySession?
    private var pendingRemovalUUIDs = Set<UUID>()
    private var pickerRequestID: UUID?
    private var pickerWasPresented = false
    private var pickerCompletionError: Error?
    private var pickerRequestStartedAt: Date?
    private var lastPickerDidDismissAt: Date?
    private var lastAppDidBecomeActiveAt: Date?
    private let pickerForegroundSettleDelay: TimeInterval = 0.8
    private let pickerReadinessTimeout: TimeInterval = 3

    /// Đúng khi session đã activate VÀ có ít nhất 1 accessory đã authorize.
    /// Trước `.activated` luôn false — caller phải chờ `isActivated` (F2).
    var hasAuthorizedAccessory: Bool {
        guard isActivated else { return false }
        #if canImport(AccessorySetupKit)
        return !(session?.accessories.isEmpty ?? true)
        #else
        return false
        #endif
    }

    // MARK: - Vòng đời

    override private init() {
        super.init()
        if UIApplication.shared.applicationState == .active {
            lastAppDidBecomeActiveAt = Date()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        #if canImport(AccessorySetupKit)
        let s = ASAccessorySession()
        s.activate(on: .main) { [weak self] event in
            self?.handleSessionEvent(event)
        }
        session = s
        #endif
    }

    // MARK: - Picker (F1 + F2)

    @objc private func appDidBecomeActive(_ notification: Notification) {
        lastAppDidBecomeActiveAt = Date()
    }

    /// CHỈ gọi từ user gesture (nút "Thêm xe", xác nhận ghép đôi...).
    /// Mọi giá trị descriptor phải được khai báo trong Info.plist — Apple
    /// crash app nếu match giá trị chưa khai báo.
    func showPicker() {
        #if canImport(AccessorySetupKit)
        guard pickerRequestID == nil else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK picker đang mở/chờ đóng — bỏ qua lần bấm lặp"))
            return
        }
        let requestID = UUID()
        pickerRequestID = requestID
        pickerRequestStartedAt = Date()
        pickerWasPresented = false
        pickerCompletionError = nil
        presentPickerWhenReady(requestID: requestID)
        #else
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "AccessorySetupKit không được hỗ trợ trên thiết bị này"))
        onPickerDismissed?(nil)
        #endif
    }

    #if canImport(AccessorySetupKit)
    private func presentPickerWhenReady(requestID: UUID) {
        guard pickerRequestID == requestID else { return }
        let now = Date()
        let appState = UIApplication.shared.applicationState
        if appState == .background {
            finishPickerRequest(error: NSError(domain: "ASKManager", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Ứng dụng đang chạy nền. Hãy mở ứng dụng rồi thử thêm xe lại."
            ]))
            return
        }
        if lastAppDidBecomeActiveAt == nil && appState == .active {
            lastAppDidBecomeActiveAt = now
        }
        let foregroundSettled = lastAppDidBecomeActiveAt.map {
            now.timeIntervalSince($0) >= pickerForegroundSettleDelay
        } ?? false
        let previousPickerSettled = lastPickerDidDismissAt.map {
            now.timeIntervalSince($0) >= pickerForegroundSettleDelay
        } ?? true
        if !isActivated || appState != .active || !foregroundSettled || !previousPickerSettled {
            if now.timeIntervalSince(pickerRequestStartedAt ?? now) >= pickerReadinessTimeout {
                PersistentLogger.shared.append(BLELogEntry(timestamp: now, level: .warning,
                    message: "ASK picker chưa sẵn sàng sau \(pickerReadinessTimeout)s | activated=\(isActivated) | appState=\(appState.rawValue)"))
                finishPickerRequest(error: NSError(domain: "ASKManager", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Hệ thống chưa sẵn sàng tìm xe. Hãy thử lại sau khi ứng dụng hiện rõ trên màn hình."
                ]))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentPickerWhenReady(requestID: requestID)
            }
            return
        }

        // Build 16 crashed in _validateDiscoveryDescriptor on iPadOS 27.0.1:
        // the three name-only filters lacked a Bluetooth service/company identifier.
        // Validate our service filters and their plist declarations before entering ASK;
        // the framework's fatal trap cannot be caught with Swift do/catch.
        let descriptors = ASKDiscoveryConfiguration.makeDescriptors()
        do {
            try ASKDiscoveryConfiguration.validate(descriptors, info: Bundle.main.infoDictionary ?? [:])
        } catch {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "ASKManager: cấu hình discovery không hợp lệ | \(error)"))
            finishPickerRequest(error: NSError(domain: "ASKManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Cấu hình tìm xe không hợp lệ. Vui lòng cập nhật ứng dụng."
            ]))
            return
        }
        guard let bikeImage = UIImage(named: "PickerBike") ?? UIImage(systemName: "motorcycle.fill") else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "ASKManager: không tạo được picker items (thiếu ảnh/asset)"))
            finishPickerRequest(error: NSError(domain: "ASKManager", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Không thể mở màn hình tìm xe."
            ]))
            return
        }
        let items = descriptors.map {
            ASPickerDisplayItem(name: "Xe máy điện DAT BIKE QUANTUM",
                                productImage: bikeImage, descriptor: $0)
        }

        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "ASKManager: Kích hoạt System Picker | filters=4 UUID-only(auth,config,main,scan-legacy) | appState=\(appState.rawValue)"))

        session?.showPicker(for: items) { [weak self] error in
            DispatchQueue.main.async {
                self?.handlePickerCompletion(requestID: requestID, error: error)
            }
        }
    }

    private func handlePickerCompletion(requestID: UUID, error: Error?) {
        guard pickerRequestID == requestID else { return }
        if let error {
            let nsError = error as NSError
            pickerCompletionError = error
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK showPicker lỗi | domain=\(nsError.domain) code=\(nsError.code) | presented=\(pickerWasPresented) | appState=\(UIApplication.shared.applicationState.rawValue)"))
            // Nếu picker đã hiện, chờ pickerDidDismiss trước khi mở nút Thêm xe.
            if !pickerWasPresented { finishPickerRequest(error: error) }
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK showPicker completion thành công; chờ pickerDidDismiss"))
        }
    }

    private func finishPickerRequest(error: Error?) {
        guard pickerRequestID != nil else { return }
        pickerRequestID = nil
        pickerRequestStartedAt = nil
        pickerWasPresented = false
        pickerCompletionError = nil
        onPickerDismissed?(error)
    }
    #endif

    // MARK: - Gỡ accessory

    func removeAccessory(withUUID uuidString: String) {
        #if canImport(AccessorySetupKit)
        guard let targetUUID = UUID(uuidString: uuidString) else { return }
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.removeAccessory(withUUID: uuidString)
            }
            return
        }
        guard isActivated else {
            pendingRemovalUUIDs.insert(targetUUID)
            return
        }
        let accessories = session?.accessories ?? []
        for accessory in accessories where accessory.bluetoothIdentifier == targetUUID {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASKManager: Yêu cầu xóa (Unpair) phụ kiện \(uuidString) khỏi iOS"))
            Task {
                // Bridge async của ObjC completion API
                do {
                    try await session?.removeAccessory(accessory)
                } catch {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "ASK removeAccessory lỗi: \(error.localizedDescription)"))
                }
            }
        }
        #endif
    }

    // MARK: - Events (F3 + F4 + F5)

    #if canImport(AccessorySetupKit)
    private func handleSessionEvent(_ event: ASAccessoryEvent) {
        switch event.eventType {
        case .activated:
            isActivated = true
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: Session Activated (accessories=\(session?.accessories.count ?? 0))"))
            // F6-REV (5.2.0): báo danh sách uuid đã ghép cho core xử lý lúc app mở
            let pairedUUIDs = (session?.accessories ?? []).compactMap { $0.bluetoothIdentifier }
            onSessionActivated?(pairedUUIDs)
            let removals = pendingRemovalUUIDs
            pendingRemovalUUIDs.removeAll()
            removals.forEach { removeAccessory(withUUID: $0.uuidString) }

        case .accessoryAdded:
            if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "ASK Event: accessoryAdded (UUID: \(uuid.uuidString.prefix(8)))"))
                onAccessorySelected?(uuid)
            }

        case .accessoryChanged:
            // F5: chỉ đổi tên/thông tin của accessory ĐÃ ghép — không connect lại.
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: accessoryChanged (đổi tên/thông tin — bỏ qua, không connect)"))

        case .accessoryRemoved:
            // F4: user gỡ xe trong Settings iOS → core dọn pairing nếu khớp.
            if let accessory = event.accessory, let uuid = accessory.bluetoothIdentifier {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "ASK Event: accessoryRemoved (UUID: \(uuid.uuidString.prefix(8)))"))
                onAccessoryRemoved?(uuid)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "ASK Event: accessoryRemoved (không kèm UUID — bỏ qua)"))
            }

        case .pickerDidPresent:
            if pickerRequestID != nil { pickerWasPresented = true }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: pickerDidPresent"))

        case .pickerDidDismiss:
            lastPickerDidDismissAt = Date()
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: pickerDidDismiss"))
            finishPickerRequest(error: pickerCompletionError ?? event.error)

        case .pickerSetupFailed:
            pickerCompletionError = event.error ?? NSError(domain: "ASKManager", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Hệ thống không thể hoàn tất ghép đôi phụ kiện."
            ])
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK Event: pickerSetupFailed | error=\(event.error?.localizedDescription ?? "không rõ")"))

        case .pickerSetupPairing:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: pickerSetupPairing"))

        case .unknown, .accessoryDiscovered, .pickerSetupBridging, .pickerSetupRename:
            break

        case .invalidated:
            isActivated = false
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "ASK Event: Session Invalidated"))

        case .migrationComplete:
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Event: migrationComplete"))

        @unknown default:
            break
        }
    }
    #endif
}

#endif // !NOASK
