import Foundation
import Combine

@MainActor
class DashboardViewModel: ObservableObject {
    
    // Dependencies
    private let core: DatBikeCore
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    
    // Outputs cho UI
    @Published var connectionState: IoTConnectionState = .idle
    @Published var telemetry: IoTTelemetryData = IoTTelemetryData()
    @Published var lockState: IoTLockState = .locked
    @Published var isProcessing: Bool = false
    @Published var pairingError: String? = nil
    
    @Published var isFinding: Bool = false
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var rssi: Int = 0
    
    /// Tên quảng bá BLE mới nhất (ví dụ "Ngựa sắt") — hiện trên splash trước khi GATT đọc xong.
    @Published var advertisedBikeName: String?
    
    /// Danh sách xe BLE tìm thấy trong quá trình scan
    @Published var discoveredBikes: [DiscoveredBike] = []
    
    @Published var bikeInfo = IoTVehicleInfo()

    /// LỚP 3: User đang ở trạng thái "Tạm dừng" (đã ngắt BLE, không auto-reconnect).
    @Published var isPaused: Bool = false
    
    // Accessor cho View
    var batteryPercentage: Int { Int(telemetry.soc) }
    var odometer: Float { telemetry.odometerKm }
    var motorTemp: Float { telemetry.motorTemp }
    var isConnected: Bool { connectionState.isConnected }
    var lockStatus: IoTLockState { lockState }
    
    var hasAuthorizedAccessory: Bool {
        if preferences.savedPeripheralUUID != nil { return true }
        #if !NOASK
        if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
            return ASKManager.shared.hasAuthorizedAccessory
        }
        #endif
        return false
    }
    
    // Signal
    var signalStrength: SignalStrength {
        if rssi >= -60 { return .excellent }
        if rssi >= -75 { return .good }
        if rssi >= -85 { return .fair }
        return .weak
    }
    
    init(core: DatBikeCore, preferences: PreferencesManager) {
        self.core = core
        self.preferences = preferences
        self.isPaused = core.isConnectionPaused // sync trạng thái pause persist qua relaunch
        self.isNearbyNotInUse = (core.connectionIntent == .manualOnlyNearbyNotInUse) // §4.5
        setupBindings()
    }
    
    private func setupBindings() {
        core.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.connectionState = state
                self?.isProcessing = false
                if case .error(let msg) = state {
                    self?.pairingError = msg
                    self?.errorMessage = msg
                    self?.showError = true
                } else {
                    self?.pairingError = nil
                }
            }
            .store(in: &cancellables)
            
        core.telemetryData
            .receive(on: DispatchQueue.main)
            .sink { [weak self] data in
                guard let self else { return }
                self.telemetry = data
                if data.soc > 0 { self.lastDataUpdatedAt = Date() } // §4.4: timestamp dữ liệu stale
            }
            .store(in: &cancellables)

        // §UX: pending connect flag — phân biệt "chờ xe vào tầm sóng" vs "đang kết nối"
        core.$isPendingConnectWaiting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] val in
                self?.isPendingConnect = val
            }
            .store(in: &cancellables)
            
        core.lockState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.lockState = state
                self?.isProcessing = false
            }
            .store(in: &cancellables)
        
        core.$discoveredBikes
            .receive(on: DispatchQueue.main)
            .assign(to: \.discoveredBikes, on: self)
            .store(in: &cancellables)
        
        core.$currentVehicleInfo
            .receive(on: DispatchQueue.main)
            .assign(to: \.bikeInfo, on: self)
            .store(in: &cancellables)
        
        core.$currentRSSI
            .receive(on: DispatchQueue.main)
            .assign(to: \.rssi, on: self)
            .store(in: &cancellables)

        core.$lastAdvertisedName
            .receive(on: DispatchQueue.main)
            .assign(to: \.advertisedBikeName, on: self)
            .store(in: &cancellables)

        // C5 (5.1.0): mirror isPaused/isNearbyNotInUse theo ĐÚNG nguồn sự thật —
        // trước 5.1.0 hai biến này chỉ ghi một lần lúc init, nên các đường đổi
        // intent KHÔNG qua VM này (Settings "Kết nối để dùng xe", deep-link connect,
        // foreground tự thoát nearbyNotInUse) khiến Dashboard hiện badge
        // "Đã tạm dừng" trong khi BLE đang connected thật (UI nói dối trạng thái).
        preferences.$connectionIntent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intent in
                guard let self else { return }
                self.isNearbyNotInUse = (intent == .manualOnlyNearbyNotInUse)
                self.isPaused = intent.isManualOnly
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Tiền Trình Bấm Nút
    
    func initializeHardware() {
        #if NOASK
        // Biến thể Lite: không có AccessorySetupKit — init CB trực tiếp.
        core.initializeBluetoothHardware()
        core.startDiagnosticScanIfReady()
        #else
        if #available(iOS 18.0, *) {
            // iOS 18: Gọi .shared để force initialize ASKManager
            _ = ASKManager.shared
            core.initializeBluetoothHardware()

            // diagnostic scan: iOS 18 CB state sẽ = 4 nếu chưa có ASK device.
            // core vẫn quét nhưng nó sẽ âm thầm chờ ASK.
            core.startDiagnosticScanIfReady()
        } else {
            core.initializeBluetoothHardware()
            core.startDiagnosticScanIfReady()
        }
        #endif
    }
    
    func connectBike() {
        self.pairingError = nil
        self.showError = false

        if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
            #if !NOASK
            // F5: connectBike là auto-connect, không được showPicker.
            // Nếu có xe, session.activated sẽ tự sinh event và gọi core.connect.
            // Nếu chưa có, chờ user bấm "Thêm xe".
            isProcessing = true
            _ = ASKManager.shared
            core.initializeBluetoothHardware()
            // iOS 18: Nếu chưa ASK pair, CB=4. Không ép core.connect() ở đây vì nó sẽ ném lỗi 4.
            // Đợi onSessionActivated của ASKManager tự gọi core.connect().
            // Nhưng nếu đã có savedPeripheralUUID thì có thể gọi để Core tự xử lý.
            if preferences.savedPeripheralUUID != nil {
                core.connect()
            }
            #endif
        } else {
            isProcessing = true
            core.initializeBluetoothHardware()
            core.connect()
        }
    }

    /// Bắt đầu ghép đôi — CHỈ gọi từ user gesture (nút "Thêm xe", alert xác nhận).
    /// Từ 5.3.0 (BLEFeatureFlags.useASK = false): luôn đi đường classic CoreBluetooth —
    /// scan → danh sách xe (discoveredBikes) → user chọn → SMP pair + NFC.
    /// ASK picker không match quảng bá 128-bit của fw 1.11.0 (T1 field test 11/10 fail).
    func startPairing() {
        guard !isProcessing else { return }
        pairingError = nil
        showError = false

        if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
            #if !NOASK
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[UI ACTION] Bấm 'Thêm xe' (startPairing) trên iOS 18 → gọi ASKManager.showPicker()"))

            core.initializeBluetoothHardware()

            ASKManager.shared.onPickerDismissed = { [weak self] error in
                DispatchQueue.main.async {
                    if let err = error as NSError? {
                        // User bấm huỷ picker sẽ ném ASKError.cancelled (không làm gì)
                        // Bất kỳ lỗi nào khác (VD: CBError.unauthorized):
                        let cancelled = err.domain == "ASKManager" && err.code == 0
                        if !cancelled {
                            self?.pairingError = "Lỗi kết nối Bluetooth: \(err.localizedDescription)"
                            self?.showError = true
                        }
                    }
                }
            }
            ASKManager.shared.showPicker()
            #endif
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[UI ACTION] Bấm 'Thêm xe' (startPairing) → quét BLE classic (ASK đã tắt, fw 1.11.0)"))
            isProcessing = true
            core.initializeBluetoothHardware()
            core.connect()
        }
    }

    #if !NOASK
    /// Cancellable cho việc chờ ASK activation (F2) — giữ strong để subscription sống.
    private var askActivationCancellable: AnyCancellable?
    #endif
    
    /// User chọn xe từ danh sách (Fallback cho iOS 15/16)
    func selectBike(_ bikeId: String) {
        isProcessing = true
        core.selectBike(bikeId)
    }
    
    func refreshStatus() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tải lại' (Refresh Status)"))
        isProcessing = true
        core.queryTelemetry()
        // isProcessing sẽ tự tắt khi lockState cập nhật (trong setupBindings)
    }
    
    func forceAuthenticate() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Đánh thức xe' (Force Authenticate)"))
        isProcessing = true
        core.forceAuthenticate()
    }
    
    func submitPairingPin(_ pin: String) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User submitted PIN"))
        core.submitPairingPin(pin)
    }
    
    func forceStandby() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Ngắt kết nối' (Force Standby)"))
        core.forceStandbyOverride()
    }
    
    /// User bấm "Kết nối" khi đang ở nearby → auth ngay
    func connectFromNearby() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối' từ chế độ gần xe"))
        isProcessing = true
        core.connectFromNearby()
    }
    
    /// User bấm "Kết nối lại" khi bị kẹt ở scanning → reset toàn bộ flags + connect mới
    func forceReconnect() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối lại' (Force Reconnect)"))
        isProcessing = true
        core.forceReconnect()
    }
    
    /// User bật chế độ "Đang ở gần"
    func activateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User bật chế độ 'Đang ở gần'"))
        core.activateNearbyMode()
    }
    
    /// User tắt chế độ "Đang ở gần"
    func deactivateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tắt chế độ 'Đang ở gần'"))
        isProcessing = true
        core.deactivateNearbyMode()
    }

    // MARK: - Lớp 3: Tạm dừng / Tiếp tục kết nối

    /// User bấm "Tạm dừng" → ngắt BLE hoàn toàn, chặn auto-reconnect (dẹp code=6).
    func pauseConnection() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tạm dừng' (Pause)"))
        core.pauseConnection()
        isPaused = true
    }

    /// User bấm "Tiếp tục kết nối" → mở lại auto-reconnect.
    func resumeConnection() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tiếp tục' (Resume)"))
        isPaused = false
        isNearbyNotInUse = false
        isProcessing = true
        core.resumeConnection()
    }

    // MARK: - §4 (P3): "Ở gần xe, chưa dùng" / "Kết nối để dùng xe"

    /// Reason manualOnly cho copy UI (card + nút).
    @Published var isNearbyNotInUse: Bool = false

    /// §UX: pending connect (chờ xe vào tầm sóng) — bind từ core.
    @Published private(set) var isPendingConnect = false

    /// Dòng dữ liệu stale cho card manualOnly: "pin 84% · 17:22".
    var staleDataLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if telemetry.soc > 0 {
            return "Dữ liệu mới nhất: pin \(Int(telemetry.soc))% · \(formatter.string(from: lastDataUpdatedAt))"
        }
        return "Dữ liệu mới nhất: chưa có dữ liệu"
    }
    private var lastDataUpdatedAt = Date()

    /// §4.1: Nút "Ở gần xe, chưa dùng" — ngắt BLE một lần, chặn auto-connect.
    func setNearbyNotInUse() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Ở gần xe, chưa dùng'"))
        isNearbyNotInUse = true
        isPaused = true // cùng cơ chế manualOnly (UI cũ render card qua isPaused)
        core.setNearbyNotInUse()
    }

    /// §4.1: Nút chính trên card — thoát manualOnly và kết nối.
    func connectForRide() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Kết nối để dùng xe'"))
        isNearbyNotInUse = false
        isPaused = false
        isProcessing = true
        core.connectForRide()
    }
    
    // MARK: - Gate auth cho lệnh điều khiển (fix 5.3.0)

    /// Chờ phiên auth nâng cấp xong rồi chạy lệnh (timeout 10s → báo lỗi).
    private var controlWaiter: AnyCancellable?

    /// Xe chỉ thực thi lệnh khi có phiên xác thực. Trước 5.3.0 lệnh được ghi
    /// thẳng xuống xe kể cả khi chưa auth (.nearby/.standby) → xe im lặng bỏ
    /// qua (log 19/10 phiên 15:23: "báo kết nối, icon không sáng, không điều
    /// khiển được"). Giờ: đã active → chạy ngay; link mở nhưng chưa auth → TỰ
    /// forceAuthenticate rồi chạy lệnh ("bấm nút = ý định dùng xe"); không link
    /// → báo lỗi rõ ràng thay vì im lặng.
    private func dispatchControl(_ label: String,
                                 autoTurnOn: Bool = false,
                                 _ command: ((IoTCommandService) async throws -> Void)? = nil) {
        guard !isProcessing else { return }

        if case .active = connectionState {
            runControl(label, command)
            return
        }

        switch connectionState {
        case .nearby, .standby:
            isProcessing = true
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CTRL_GATE] \(label): phiên chưa auth (\(connectionState)) → nâng cấp auth rồi thực hiện lệnh"))
            core.forceAuthenticate(turnOn: autoTurnOn)
            waitActiveThenRun(label: label, autoTurnOn: autoTurnOn, command: command)
        case .authenticating:
            // Auth đã đang chạy (FG_OPEN_AUTH...) — chỉ chờ xong rồi chạy lệnh
            isProcessing = true
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CTRL_GATE] \(label): đang auth — chờ xong rồi thực hiện lệnh"))
            waitActiveThenRun(label: label, autoTurnOn: autoTurnOn, command: command)
        default:
            errorMessage = "Chưa kết nối với xe — hãy mở app khi ở gần xe rồi thử lại."
            showError = true
        }
    }

    private func waitActiveThenRun(label: String,
                                   autoTurnOn: Bool,
                                   command: ((IoTCommandService) async throws -> Void)?) {
        controlWaiter = core.connectionState
            .receive(on: DispatchQueue.main)
            .first { state in
                if case .active = state { return true }
                if case .error = state { return true }
                return false
            }
            .sink { [weak self] state in
                guard let self else { return }
                if case .active = state {
                    if autoTurnOn {
                        // Core đã tự bật xe qua shouldTurnOnBikeAfterAuth
                        self.isProcessing = false
                    } else {
                        self.runControl(label, command)
                    }
                } else {
                    self.isProcessing = false
                    self.errorMessage = "Không xác thực được với xe — hãy thử lại."
                    self.showError = true
                }
            }
        // Timeout: auth kẹt quá 10s thì thoát, không khoá nút mãi
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.isProcessing,
                  case .authenticating = self.connectionState else { return }
            self.controlWaiter = nil
            self.isProcessing = false
            self.errorMessage = "Xác thực quá lâu — hãy lại gần xe rồi thử lại."
            self.showError = true
        }
    }

    private func runControl(_ label: String, _ command: ((IoTCommandService) async throws -> Void)?) {
        guard let command else { isProcessing = false; return }
        guard let dispatcher = try? core.getDispatcher() else {
            errorMessage = "Chưa kết nối với xe — hãy mở app khi ở gần xe rồi thử lại."
            showError = true
            isProcessing = false
            return
        }
        isProcessing = true
        Task { @MainActor in
            try? await command(dispatcher)
            self.isProcessing = false
        }
    }

    func lock() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Chống trộm' (Arm Anti-Theft)"))
        core.suspendAutoFeatures()
        dispatchControl("CHỐNG TRỘM") { dispatcher in
            if let state = try? await dispatcher.armAntiTheft() {
                self.lockState = state
            }
        }
    }

    func turnOnBike() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Bật xe' (Turn On Bike)"))
        core.suspendAutoFeatures()
        dispatchControl("BẬT XE", autoTurnOn: true) { dispatcher in
            if let state = try? await dispatcher.turnOnBike() {
                self.lockState = state
            }
        }
    }

    func turnOffBike() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tắt xe' (Turn Off Bike)"))
        core.suspendAutoFeatures()
        dispatchControl("TẮT XE") { dispatcher in
            if let state = try? await dispatcher.turnOffBike() {
                self.lockState = state
            }
        }
    }

    func toggleLock() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped Main V-Hexa Button (Toggle Lock)"))
        core.suspendAutoFeatures()
        let current = lockState
        dispatchControl("TOGGLE LOCK") { dispatcher in
            if let state = try? await dispatcher.toggleLock(currentState: current) {
                self.lockState = state
            }
        }
    }
    
    func findBike() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[UI ACTION] User tapped 'Tìm xe' (Find Bike)"))
        dispatchControl("TÌM XE") { [weak self] dispatcher in
            self?.isFinding = true
            try? await dispatcher.findBike(start: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.isFinding = false }
        }
    }
}
