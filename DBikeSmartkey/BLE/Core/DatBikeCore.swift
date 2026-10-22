import Foundation
import CoreBluetooth
import Combine
import UIKit
import os.log

/// LỚP BỌC TỐI THƯỢNG (FACADE) - MANAGER MỚI (V2)
class DatBikeCore: NSObject, IoTCoordinatorProtocol, @unchecked Sendable {
    
    /// Singleton — đảm bảo CBCentralManager tồn tại xuyên suốt lifecycle (kể cả background relaunch)
    static let shared = DatBikeCore()
    
    private let stateMachine = BLEStateMachine()
    var connectionState: AnyPublisher<IoTConnectionState, Never> { stateMachine.statePublisher }
    
    @Published private(set) var currentTelemetry = IoTTelemetryData()
    var telemetryData: AnyPublisher<IoTTelemetryData, Never> { $currentTelemetry.eraseToAnyPublisher() }
    
    @Published private(set) var currentLockState: IoTLockState = .unknown(Data())
    var lockState: AnyPublisher<IoTLockState, Never> { $currentLockState.eraseToAnyPublisher() }
    // Main-queue owned. A cached lock state cannot authorize a command in a new BLE session.
    private var lockStateSessionID: UUID?
    
    @Published private(set) var currentVehicleInfo = IoTVehicleInfo()
    
    @Published private(set) var currentBatteryTelemetry: BatteryTelemetry?
    private var previousBatteryTelemetry: BatteryTelemetry?
    
    @Published private(set) var currentRSSI: Int = 0
    /// RSSI đã được làm mịn bằng EMA — giảm nhiễu/jitter (BLE dao động ±5-10dB)
    /// để tránh false-trigger "auto-turn-on" khi RSSI spike mạnh chỉ trong 1-2 mẫu.
    @Published private(set) var smoothedRSSI: Int = 0
    // Main-queue owned provenance for proximity samples; uptime is monotonic.
    private var proximitySamples = ProximitySampleWindow()
    // Main-queue owned reservation, independent of user suspension.
    private var autoCommandReservation: UUID?
    private var autoCommandAttemptedSession: UUID?

    private func hasFreshProximitySample(for context: BLEConnectionContext) -> Bool {
        proximitySamples.isFresh(sessionID: context.sessionID,
                                 now: ProcessInfo.processInfo.systemUptime)
    }

    // ═══ §LOG: CYCLE TRACE — đo mỗi chu kỳ tiếp cận xe theo checkpoint ═══
    // Mục tiêu: từ log tái lập được MỘT lượt lại gần xe: request → didConnect →
    // gatt-ready → auth → active, kèm millisecond mỗi chặng + kết quả (success/
    // fail/disconnected). Grep "[CYCLE]" / "[CKPT" khi phân tích field log.
    // Ownership: ghi từ bleQueue (delegate) lẫn Main (auth Task) — chỉ là Date?
    // read/write đơn giản, chấp nhận nhất thời như các biến đếm khác của core.
    private var cycleRequestedAt: Date?
    private var cycleDidConnectAt: Date?
    private var cycleGattReadyAt: Date?
    /// Vùng RSSI so với autoTurnOnThreshold của mẫu trước đó — log khi đổi band.
    private var lastRSSIBandAboveThreshold: Bool?

    /// Chuỗi trace ngắn gắn vào log: `sid=abc123 t=+456ms`.
    private func traceCtx(_ ctx: BLEConnectionContext?) -> String {
        guard let ctx else { return "sid=nil" }
        let ms = Int(Date().timeIntervalSince(ctx.createdAt) * 1000)
        return "sid=\(ctx.sessionID.uuidString.prefix(6)) t=+\(ms)ms"
    }

    /// In 1 dòng [CYCLE] tổng kết chu kỳ. Gọi tại: didConnect (không — chỉ các điểm kết).
    private func logCycle(_ outcome: String, via: String = "", extra: String = "") {
        let sid = activeContext.map { String($0.sessionID.uuidString.prefix(6)) }
                ?? (cycleRequestedAt != nil ? "ctx-nil" : "nil")
        func ms(_ a: Date?, _ b: Date?) -> String {
            guard let a, let b else { return "?" }
            return String(Int(b.timeIntervalSince(a) * 1000))
        }
        var parts = ["sid=\(sid)", "outcome=\(outcome)"]
        if !via.isEmpty { parts.append("via=\(via)") }
        if let req = cycleRequestedAt {
            let now = Date()
            parts.append("req→dc=\(ms(req, cycleDidConnectAt))ms")
            parts.append("dc→gatt=\(ms(cycleDidConnectAt, cycleGattReadyAt))ms")
            parts.append("gatt→now=\(ms(cycleGattReadyAt, now))ms")
            parts.append("total=\(ms(req, now))ms")
        }
        if !extra.isEmpty { parts.append(extra) }
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(),
            level: outcome == "success" ? .success : .warning,
            message: "[CYCLE] " + parts.joined(separator: " ")))
    }

    private func resetCycleTrace() {
        cycleRequestedAt = Date()
        cycleDidConnectAt = nil
        cycleGattReadyAt = nil
    }

    // ═══ §FG_HEAL: FOREGROUND SELF-HEAL WATCHDOG ═══
    // Yêu cầu bắt buộc: "mở app đang gần xe → kết nối ngay". Nếu sau 10s foreground
    // mà vẫn chưa đến trạng thái ổn (active/standby/nearby/pairing), TỰ force-reconnect
    // sạch (đường user vẫn phải bấm "Kết nối lại" trước đây). Tối đa 2 lần/phiên app.
    //
    // C1 (5.1.0) — 3 lỗi của bản 5.0.0 đã sửa:
    // 1. NGÂN SÁCH vs TIẾN BỘ: đường connect lành mạnh giờ dài hơn 10s (FG scan 7s ×
    //    tối đa 3 vòng + GATT + auth ≈ 25s). Bản 5.0.0 heal vô điều kiện tại mốc 10s
    //    → chém đúng connect đang chạy tốt. Giờ: heal CHỈ khi snapshot (state, scan
    //    retry, peripheral state, pending, auth) KHÔNG đổi kể từ lúc vũ trang — tức
    //    thực sự kẹt; có tiến bộ thì canh tiếp 10s nữa, không tiêu quota chữa lỗi.
    // 2. `.error` thêm vào danh sách "đã ổn" — BT tắt/x báo lỗi không bị heal churn.
    // 3. Quota 2 lần là quota/phiên app (không reset mỗi foreground như 5.0.0 —
    //    lock/unlock màn hình vài lần = vài chu kỳ teardown); reset khi connect thành công.
    private var foregroundHealAttempts = 0
    private var foregroundHealWorkItem: DispatchWorkItem?

    /// Ảnh chụp "mức tiến bộ" để phân biệt đang TIẾN vs đang KẸT.
    private func healSnapshot() -> String {
        "\(stateMachine.state.displayText)|scan=\(scanRetryCount)|ctx=\(activeContext != nil)|ps=\(activeContext?.peripheral.state.rawValue ?? -1)|pending=\(isPendingConnectWaiting)|auth=\(isAuthenticating)"
    }

    private func beginForegroundHealWatchdog() {
        guard DispatchQueue.getSpecific(key: bleQueueKey) != nil else {
            executeOnBleQueue { [weak self] in self?.beginForegroundHealWatchdog() }
            return
        }
        let snapshot = healSnapshot()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isAppInBackground,
                  !self.preferences.isManualOnly, !self.isUserPaused else { return }
            // Trạng thái "đã ổn" — không can thiệp (C1: cả .error)
            switch self.stateMachine.state {
            case .active, .standby, .nearby, .pairingRequired, .idle, .error:
                return
            default:
                break
            }
            // C1: có tiến bộ kể từ lúc vũ trang → canh tiếp, không heal
            if self.healSnapshot() != snapshot {
                self.beginForegroundHealWatchdog()
                return
            }
            if self.foregroundHealAttempts >= 2 {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[FG_HEAL] Đã tự reconnect \(self.foregroundHealAttempts) lần vẫn chưa kết nối (state=\(self.stateMachine.state.displayText)) → dừng, chờ user"))
                return
            }
            self.foregroundHealAttempts += 1
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[FG_HEAL] 10s foreground không tiến bộ (state=\(self.stateMachine.state.displayText)) → tự force-reconnect lần \(self.foregroundHealAttempts)/2"))
            // C1: chạy trên bleQueue như mọi lifecycle API (bản 5.0.0 gọi thẳng trên main)
            self.executeOnBleQueue { [weak self] in
                self?.performForceReconnect()
                self?.beginForegroundHealWatchdog()
            }
        }
        foregroundHealWorkItem?.cancel()
        foregroundHealWorkItem = work
        bleQueue.asyncAfter(deadline: .now() + 10.0, execute: work)
    }
    
    /// Danh sách xe tìm thấy trong quá trình scan
    @Published private(set) var discoveredBikes: [DiscoveredBike] = []
    
    /// Tên quảng bá BLE mới nhất (advName từ didDiscover) — dùng làm fallback khi
    /// GATT chưa đọc xong hoặc firmware trả tên mặc định. Ví dụ: "Ngựa sắt".
    @Published private(set) var lastAdvertisedName: String?
    
    private var centralManager: CBCentralManager!
    private var activeContext: BLEConnectionContext?
    
    private var commandDispatcher: BLECommandDispatcher?
    private var pollingEngine: BLEPollingEngine?
    private let preferences: PreferencesManager
    private var cancellables = Set<AnyCancellable>()
    private var engineCancellables = Set<AnyCancellable>()
    private var lastLoggedVehicleString: String = ""
    
    var isAuthenticating = false
    private var pendingASKUUID: UUID?

    /// §UX (code-driven): TRUE khi app đang trong PENDING CONNECT — đã gọi
    /// central.connect() cho xe đã biết và iOS đang chờ xe vào tầm sóng
    /// (Apple: request không bao giờ timeout, gần như 0 pin).
    /// FALSE khi: scan thật đang chạy / didConnect (bắt tay active) / fail / disconnect.
    /// UI dùng để phân biệt "Đang chờ xe vào tầm sóng" vs "Đang kết nối" thật.
    @Published private(set) var isPendingConnectWaiting = false
    
    /// Cờ phát hiện Bluetooth đã trải qua poweredOff → poweredOn.
    /// Khi cờ này bật, PHẢI scan mới thay vì dùng cache (tránh MIC failure).
    /// ═══ CHỈ RESET trong didConnect (L1260) — KHÔNG reset sớm trong connect()/startScanWithTimeout() ═══
    /// Lý do: ASK callback đến 30-50ms sau connect(), nếu reset sớm → ASK dùng cache → MIC failure.
    private var btWasPoweredOff: Bool = false
    
    /// Cờ riêng biệt: peripheral stale (disconnect sau State Restoration),
    /// buộc scan mới dù BT không bị power-cycle.
    private var forceFullScan: Bool = false
    
    /// Đếm số lần liên tiếp rơi vào Standby (RSSI quá yếu) mà không auth được.
    /// Dùng để detect "Standby Drain Loop" và chuyển sang pending connect tiết kiệm pin.
    private var consecutiveStandbyCount = 0
    private let maxConsecutiveStandbyBeforePending = 3
    
    /// Đếm số vòng scan khi btWasPoweredOff=true — giới hạn scan loop.
    /// Sau 3 vòng (6 retries) mà không tìm thấy xe → reset flag, fallback pending connect.
    private var btPowerCycleScanRounds = 0
    private let maxBtPowerCycleScanRounds = 3
    
    /// Đếm số lần RSSI liên tục yếu hơn ngưỡng trong quá trình standby polling.
    /// Sau 10 lần liên tục (≈5s ở tần suất poll 0.5s), chủ động disconnect + pending connect
    /// thay vì chờ iOS supervision timeout (~30-60s) gây lãng phí CPU và pin.
    private var weakRssiConsecutiveCount = 0
    private let maxWeakRssiBeforeDisconnect = 10
    /// §3.9 (P4): hysteresis enter — cần 2 mẫu RSSI liên tiếp đạt ngưỡng mới auto-auth.
    private var strongRssiConsecutiveCount = 0
    /// §3.9 (P4): hysteresis exit — chỉ đếm "yếu" khi thấp hơn ngưỡng thêm 5dB.
    private let rssiExitHysteresisDb: Double = 5.0
    
    // Proximity Standby Timer
    private var standbyTimer: Timer?
    private var lastRssiLogTime: Date?
    
    // Scan timeout & retry
    private var scanTimer: DispatchWorkItem?
    private var scanRetryCount = 0
    private let maxScanRetries: Int = {
        #if NOASK
        return 1 // Lite foreground-only: fail nhanh, user tự bấm thử lại
        #else
        return 2
        #endif
    }()
    private var scanTimeoutSeconds: TimeInterval {
        // P1.5 (log-driven): FG 7s — firmware deep-sleep có advertising gap dài,
        // window 2.5s bỏ lỡ khiến user "quay lại mở xe rất lâu". BG giữ 4s (pin).
        return isAppInBackground ? 4.0 : 7.0
    }

    /// Options chuẩn cho mọi central.connect. NOASK bỏ auto-reconnect của hệ thống
    /// (API iOS 17+; Lite không chạy ngầm nên không cần wake-up từ hệ thống).
    private static func connectOptions() -> [String: Any] {
        var opts: [String: Any] = [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
        ]
        #if !NOASK
        opts[CBConnectPeripheralOptionEnableAutoReconnect] = true // F7 (5.2.0)
        #endif
        return opts
    }

    /// Options chuẩn cho CBCentralManager. NOASK bỏ restore identifier —
    /// State Restoration chỉ có nghĩa khi có UIBackgroundModes bluetooth-central.
    private static func centralManagerOptions() -> [String: Any] {
        var opts: [String: Any] = [
            CBCentralManagerOptionShowPowerAlertKey: true
        ]
        #if !NOASK
        opts[CBCentralManagerOptionRestoreIdentifierKey] = "DatBikeCentralManagerRestoreID"
        #endif
        return opts
    }
    
    // Connecting state timeout — phòng trường hợp discoverServices không phản hồi (phantom connection)
    private var connectingTimer: DispatchWorkItem?

    /// F1-RL (5.2.0): lần arm pending-at-failure cuối — rate-limit 10s. Không có
    /// nó, cluster MIC nào cũng thành machine-gun: arm tức thì → xe đang phát sóng
    /// → thử ngay → fail sau ~0.6s → arm lại (log 19/09 10:51:41-43: 4 fail/2s →
    /// burn quota → 2× CB_RECYCLE → bluetoothd .unsupported).
    private var lastFailurePendingArmAt: Date?

    /// F3 (5.2.0): đã từng thấy central .poweredOn trong process này.
    /// Phân biệt BT off THẬT (xảy ra giữa phiên) với transient 4→5 mili-giây mà
    /// iOS 18 + ASK báo ở callback đầu của CBCentralManager mới lúc cold-launch
    /// (log 18-19/09: 5/6 lần "BT power-cycle" là giả → tự ép ladder scan 42s).
    private var hasSeenPoweredOnInThisProcess = false
    
    // Disconnect fallback timer — cancel khi didConnect để tránh double-scan
    private var disconnectFallbackTimer: DispatchWorkItem?
    
    // Auth task reference — cancel khi disconnect để tránh stale state transitions
    private var authTask: Task<Void, Never>?
    private var authAttemptID: UUID?
    
    // MIC failure retry limit — persisted qua UserDefaults để xuyên phiên app relaunch
    private var micRetryCount: Int {
        get { UserDefaults.standard.integer(forKey: "ble_micRetryCount") }
        set { UserDefaults.standard.set(newValue, forKey: "ble_micRetryCount") }
    }
    private let maxMicRetries = 3
    
    /// Timestamp lần MIC failure cuối — dùng kèm micRetryCount để tạo TTL.
    /// Sau 60s không gặp MIC failure → reset counter (tránh "dính" vĩnh viễn).
    private var lastMicFailureTime: Date? {
        get {
            let interval = UserDefaults.standard.double(forKey: "ble_lastMicFailureTime")
            return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "ble_lastMicFailureTime") }
    }
    private let micRetryTTL: TimeInterval = 60 // Reset sau 60s không gặp MIC failure

    // ═══ §CB_RECYCLE: đếm số lần tái tạo CBCentralManager trong phiên ═══
    // Bằng chứng TN 11/09/2026: peripheral zombie .disconnecting chặn MỌI connect
    // dù xe phát sóng RSSI −43 (scan mới vẫn nhận lại đúng object zombie vì CBPeripheral
    // unique theo manager) + MIC failure code 31 rỉ rả (cách nhau >60s nên TTL reset
    // micRetryCount mãi → không bao giờ hết quota → loop vô hạn).
    // Cả hai chỉ thoát được bằng manager mới. Cap tránh thrash.
    private var cbRecycleCount = 0
    private let maxCbRecyclesPerSession = 3
    /// Tổng số MIC/encryption failure trong phiên — KHÔNG TTL reset; chỉ reset khi
    /// didConnect thành công. Bắt vòng lặp rỉ rả chậm (>60s/lần) mà ladder micRetry
    /// không bao giờ chạm được.
    private var micFailureSessionCount = 0
    /// Mốc micFailureSessionCount tại lần CB_RECYCLE gần nhất của đường MIC —
    /// rỉ rả chỉ recycle tiếp khi tích thêm đủ 5 fail MỚI (field log 8: điều kiện
    /// cũ nổ recycle liên tiếp 3 lần/1s, đốt sạch quota).
    private var micFailureCountAtLastRecycle = 0
    /// UUID xe lạ đã cảnh báo RPA trong lượt quét hiện tại — reset mỗi lần scan mới.
    /// Dedupe log: đứng bãi nhiều Dat Bike + allowDupes → mỗi gói adv 2 dòng spam.
    private var rpaWarnedUUIDs = Set<UUID>()

    /// Guard chống connectPeripheral().disconnecting retry loop bị gọi đồng thời từ nhiều luồng
    /// (ví dụ: foreground connect() + didDiscover callback cùng fire một lúc).
    private var disconnectingRetryActive = false
    
    // Guard chống downgradeToStandby chạy trùng lặp
    private var isDowngrading = false
    
    /// Guard chống SESSION_CHECK / tryRestoreActiveSession bị gọi 2 lần (race condition).
    private var isRestoringSession = false

    /// LỚP 3: User chủ động "Tạm dừng" kết nối (nút Pause). Persist qua relaunch.
    /// Khi true: mọi auto-reconnect/pending-connect bị chặn cho tới khi user "Tiếp tục".
    /// Dẹp hoàn toàn code=6 trong thời gian tạm dừng (app không "ôm" GATT).
    /// §4 (P3): isUserPaused giờ là BRIDGE lên ConnectionIntent — mọi gate cũ
    /// (connect(), didDisconnect, retry bodies…) tự động theo intent mới.
    /// true = manualOnly(pausedByUser) — nút "Ở gần xe, chưa dùng" dùng API riêng
    /// setNearbyNotInUse() để giữ đúng reason.
    private var isUserPaused: Bool {
        get { preferences.connectionIntent.isManualOnly }
        set { preferences.connectionIntent = newValue ? .manualOnlyPausedByUser : .autoConnect }
    }

    // ═══ §3.7 (P2): RetryScheduler — CHỦ DUY NHẤT của mọi retry trì hoãn ═══
    // Thay thế các asyncAfter rời (MIC retry, Phantom backoff, disconnecting-retry,
    // standby-drain, fail-connect-retry) từng chạy chồng nhau và bypass PAUSE.
    private lazy var retryScheduler = RetryScheduler(queue: bleQueue)

    /// Session identity = xe đã ghép (app đơn xe). Đổi savedPeripheralUUID (ghép xe
    /// mới / xóa bond) ⇒ session mới ⇒ mọi retry token cũ tự chết.
    private var bikeSessionID: UUID {
        if let saved = preferences.savedPeripheralUUID, let id = UUID(uuidString: saved) {
            return id
        }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }

    private func bindRetryScheduler(reason: String) {
        let sid = bikeSessionID
        retryScheduler.bind(sessionID: sid, reason: reason)
    }
    
    /// Đếm số lần Phantom Guard timeout liên tiếp — dùng cho exponential backoff.
    private var phantomGuardFailCount = 0
    private let maxPhantomGuardBackoffSeconds: TimeInterval = 30.0
    
    // Thời điểm lần cuối chuyển sang .active — chống auth-standby loop
    private var lastActiveTime: Date?
    
    // Background execution state
    private var isAppInBackground = false
    
    // Quản lý CPU nền
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /// Main-queue owned identity; expiration of an older lease cannot end a new one.
    private var backgroundLeaseID: UUID?

    // ═══ QUẢN LÝ ĐỒNG BỘ TUẦN TỰ TRÊN CORE BLE QUEUE (Lỗi thiết kế 2) ═══
    private let bleQueueKey = DispatchSpecificKey<Void>()
    private lazy var bleQueue: DispatchQueue = {
        let bundleId = Bundle.main.bundleIdentifier ?? "app.mybike.smartkey"
        let q = DispatchQueue(label: "\(bundleId).core.ble", qos: .userInitiated)
        q.setSpecific(key: bleQueueKey, value: ())
        return q
    }()

    /// Đảm bảo block được thực thi tuần tự trên bleQueue — không bao giờ xảy ra race condition giữa UI và BLE callbacks.
    private func executeOnBleQueue(_ block: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: bleQueueKey) != nil {
            block()
        } else {
            bleQueue.async(execute: block)
        }
    }
    
    // Cờ kết thúc "Phiên Auto": Bất cứ tương tác thủ công nào (Force Connect, Bật/Tắt xe) sẽ đình chỉ tính năng Auto (bật, tắt, kết nối) cho đến khi Bluetooth mất kết nối vật lý (reset phiên).
    private(set) var isSessionAutoSuspended = false
    private var shouldTurnOnBikeAfterAuth = false
    
    /// Cờ đánh dấu yêu cầu nối lại sau khi ngắt kết nối hoàn tất
    private var isPendingCleanReconnect = false

    // ═══ C2 (5.1.0): CLEAN-RECONNECT DEADLINE ═══
    // isPendingCleanReconnect đợi didDisconnectPeripheral(error==nil) rồi mới connect().
    // Với peripheral zombie .disconnecting (chính trường hợp CB_RECYCLE ra đời để chữa),
    // cancelPeripheralConnection KHÔNG bao giờ sinh didDisconnect → 5.0.0 kẹt chờ vô hạn
    // (foreground chết ≥10s chờ FG_HEAL cứu, background kẹt .scanning vĩnh viễn).
    // Deadline: sau 2.5s không nhận được event → clear cờ, connect() — connectPeripheral
    // sẽ gặp p.state == .disconnecting và đi ladder disconnecting-retry → CB_RECYCLE
    // (đường thoát zombie đã có sẵn).
    private var cleanReconnectDeadlineTimer: DispatchWorkItem?
    private let cleanReconnectDeadlineSeconds: TimeInterval = 2.5

    private func beginCleanReconnectDeadline() {
        cleanReconnectDeadlineTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.executeOnBleQueue { [weak self] in
                guard let self, self.isPendingCleanReconnect else { return }
                guard !self.isUserPaused else {
                    self.isPendingCleanReconnect = false
                    return
                }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[CLEAN_RECONNECT] Hết \(self.cleanReconnectDeadlineSeconds)s chưa nhận didDisconnect (zombie .disconnecting?) → clear cờ, connect() để vào ladder disconnecting-retry/CB_RECYCLE"))
                self.isPendingCleanReconnect = false
                self.connect(userInitiated: true)
            }
        }
        cleanReconnectDeadlineTimer = timer
        bleQueue.asyncAfter(deadline: .now() + cleanReconnectDeadlineSeconds, execute: timer)
    }

    private func cancelCleanReconnectDeadline() {
        cleanReconnectDeadlineTimer?.cancel()
        cleanReconnectDeadlineTimer = nil
    }
    
    func suspendAutoFeatures() {
        self.isSessionAutoSuspended = true
    }
    
    private override init() {
        self.preferences = PreferencesManager.shared
        super.init()
        isAppInBackground = UIApplication.shared.applicationState != .active
        setupLogging()
        setupBatteryMonitoring()
        
        // ═══ KHÔNG gọi initializeBluetoothHardware() ở đây ═══
        // AppDelegate.didFinishLaunchingWithOptions sẽ gọi — đảm bảo hoạt động
        // cả khi iOS relaunch app trong background (State Restoration).
        
        #if !NOASK
        if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
            ASKManager.shared.onAccessorySelected = { [weak self] uuid in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // ═══ GUARD: Nếu đã có saved UUID VÀ CB đang xử lý → bỏ qua ASK callback ═══
                    if self.preferences.savedPeripheralUUID != nil {
                        let cbHandling = self.activeContext?.peripheral.state == .connected
                            || self.activeContext?.peripheral.state == .connecting
                            || self.scanTimer != nil
                            || self.stateMachine.state == .authenticating
                            || self.stateMachine.state == .active
                            || self.stateMachine.state == .nearby
                        if cbHandling {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[ASK_CONNECT] Bỏ qua — CB path đang xử lý (smState=\(self.stateMachine.state.displayText))"))
                            return
                        }
                    }
                    self.initializeBluetoothHardware()
                    self.connect(to: uuid)
                }
            }

            // F4: user gỡ xe khỏi Settings iOS (event .accessoryRemoved của ASK)
            ASKManager.shared.onAccessoryRemoved = { [weak self] uuid in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.preferences.savedPeripheralUUID == uuid.uuidString else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[ASK_REMOVED] UUID không khớp xe đang lưu — bỏ qua"))
                        return
                    }
                    self.handleAccessoryRemovedFromSystem(expectedUUID: uuid)
                }
            }

            // F6-REV (5.2.0): ASK activate (kèm uuid đã ghép) = "xe còn ghép đôi với
            // iOS". KHÔNG phải proximity event — dùng làm trigger lúc app mở: canh
            // pending bằng kết nối foreground có timeout; kích connect lại nếu ladder chết.
            ASKManager.shared.onSessionActivated = { [weak self] accessoryUUIDs in
                DispatchQueue.main.async {
                    self?.handleASKActivated(accessoryUUIDs: accessoryUUIDs)
                }
            }
        }
        #endif // !NOASK — callback AccessorySetupKit
    }

    /// F4: xe đã bị gỡ khỏi hệ thống (Settings iOS / phát hiện stale khi connect).
    /// Dọn toàn bộ pairing phía app + chuyển state lỗi hướng dẫn ghép đôi lại.
    /// KHÔNG tự showPicker — user chủ động bấm "Thêm xe" (chuẩn user-gesture của ASK).
    #if !NOASK
    func handleAccessoryRemovedFromSystem(expectedUUID: UUID? = nil) {
        executeOnBleQueue { [weak self] in
            guard let self else { return }
            if let expectedUUID,
               self.preferences.savedPeripheralUUID != expectedUUID.uuidString { return }
            self.performAccessoryRemovedFromSystem()
        }
    }

    private func performAccessoryRemovedFromSystem() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[ASK_REMOVED] Xe không còn trong hệ thống → dọn pairing phía app"))
        cancelScanTimer()
        centralManager?.stopScan()
        cancelConnectingTimeout()
        cancelDiscoveryWatchdog()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        cancelCleanReconnectDeadline()
        isPendingCleanReconnect = false
        isPendingConnectWaiting = false
        shouldTurnOnBikeAfterAuth = false
        authTask?.cancel()
        authTask = nil
        authAttemptID = nil
        pollingEngine?.stopPolling()
        standbyTimer?.invalidate()
        standbyTimer = nil
        retryScheduler.cancelAll(reason: "accessory removed")
        if let ctx = activeContext, let central = centralManager {
            central.cancelPeripheralConnection(ctx.peripheral)
        }
        preferences.savedPin = nil
        preferences.savedPeripheralUUID = nil
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        stateMachine.transition(to: .error(
            "Xe đã được gỡ khỏi hệ thống Bluetooth của iPhone.\n" +
            "Vui lòng bấm nút 'Thêm xe' để ghép đôi lại."
        ))
    }
    #endif // !NOASK — F4 accessory removed

    #if !NOASK
    /// F6-REV (5.2.0): ASK session activate với accessory khớp xe đã lưu.
    /// Event chỉ đến lúc app chạy/activate (không phải wake nền) — tác động:
    /// • .connecting pending → chuyển sang kết nối foreground có timeout.
    /// • .idle/.error (ladder đã bỏ cuộc) → kích connect lại.
    private func handleASKActivated(accessoryUUIDs: [UUID]) {
        executeOnBleQueue { [weak self] in
            guard let self = self else { return }
            guard !self.isUserPaused else { return }
            guard self.preferences.savedPin != nil,
                  let savedStr = self.preferences.savedPeripheralUUID,
                  let savedUUID = UUID(uuidString: savedStr),
                  accessoryUUIDs.contains(savedUUID) else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[ASK_ACTIVATED] Không khớp xe đã lưu — bỏ qua (paired=\(accessoryUUIDs.count))"))
                return
            }
            if case .connecting = self.stateMachine.state {
                if self.isPendingConnectWaiting && !self.isAppInBackground {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[ASK_ACTIVATED] Pending connect đang chờ khi app mở → chuyển sang kết nối foreground"))
                    self.performConnect(userInitiated: true)
                }
                return
            }
            if case .idle = self.stateMachine.state {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[ASK_ACTIVATED] Xe còn ghép + đang idle → connect()"))
                self.connect()
            } else if case .error = self.stateMachine.state {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[ASK_ACTIVATED] Xe còn ghép + đang error → aggressive connect()"))
                self.connect(userInitiated: true)
            }
            // scanning/authenticating/active/nearby/standby → CB path đang xử lý
        }
    }
    #endif // !NOASK — F6 ASK activated

    private func extendBackgroundExecutionTime() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.extendBackgroundExecutionTime() }
            return
        }
        guard bgTask == .invalid else { return }
        let leaseID = UUID()
        backgroundLeaseID = leaseID
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "DatBikeBLE") { [weak self] in
            guard let self, self.backgroundLeaseID == leaseID else { return }
            self.stopBackgroundExecutionTime()
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[SYSTEM] Background lease expired; iOS determines available runtime."))
        }
        if bgTask == .invalid { backgroundLeaseID = nil }
        // No fixed 20s cutoff: available background runtime is not guaranteed.
    }

    private func stopBackgroundExecutionTime() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.stopBackgroundExecutionTime() }
            return
        }
        let task = bgTask
        bgTask = .invalid
        backgroundLeaseID = nil
        if task != .invalid {
            UIApplication.shared.endBackgroundTask(task)
        }
    }
    
    /// Được gọi bởi UI sau khi user đã đọc và đồng ý Disclaimer
    func initializeBluetoothHardware() {
        guard centralManager == nil else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[INIT] initializeBluetoothHardware() bỏ qua — centralManager đã tồn tại | savedPin=\(preferences.savedPin != nil ? "có" : "nil")"))
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[INIT] Khởi tạo CBCentralManager | savedUUID=\(preferences.savedPeripheralUUID?.prefix(8).description ?? "nil") | savedPin=\(preferences.savedPin != nil ? "có" : "nil") | connectOnlyWhenNear=\(preferences.connectOnlyWhenNear)"))
        self.centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: Self.centralManagerOptions())
        // §FG_HEAL: cold open cũng cần canh 10s (willEnterForeground không fire lần đầu)
        beginForegroundHealWatchdog()
        
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(protectedDataDidBecomeAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        standbyTimer?.invalidate()
    }
    
    private func setupLogging() {
        stateMachine.statePublisher
            .sink { state in
                let entry = BLELogEntry(timestamp: Date(), level: .info, message: "State transitioned to: \(state.displayText)")
                PersistentLogger.shared.append(entry)
            }
            .store(in: &cancellables)
            
        $currentLockState
            .dropFirst()
            .removeDuplicates()
            .sink { _ in
                // Log trang thai xe CHINH THUC chi thuc hien trong readLockStatus() (co raw:)
                // de tranh log trung lap khi set tu nhieu luong khac nhau.
            }
            .store(in: &cancellables)
            
    }
    
    func connect() {
        connect(userInitiated: false)
    }

    /// F4 (5.2.0): userInitiated=true → connect TRỰC TIẾP kèm Phantom Guard
    /// (nút "Kết nối lại" / user mở app) thay vì pending connect không-guard.
    func connect(userInitiated: Bool) {
        executeOnBleQueue { [weak self] in
            self?.performConnect(userInitiated: userInitiated)
        }
    }

    private func performConnect(userInitiated: Bool = false) {
        // LỚP 3: đang tạm dừng → chặn mọi auto-reconnect (scan/retrieve/pending).
        if isUserPaused {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] Bỏ qua — đang tạm dừng (isUserPaused). Gọi resumeConnection() để mở lại."))
            return
        }
        // §3.7: mọi connect() mới gắn scheduler vào session hiện tại
        // (đổi xe ghép ⇒ retry cũ tự chết; cùng xe ⇒ no-op).
        guard !isPendingCleanReconnect else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CLEAN_RECONNECT] Chờ yêu cầu ngắt cũ hoàn tất — bỏ qua connect trùng"))
            return
        }
        bindRetryScheduler(reason: "connect()")
        // §LOG: chu kỳ mới bắt đầu từ đây (điểm request của checkpoint chain)
        resetCycleTrace()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CKPT request] \(traceCtx(activeContext)) | source=connect() | smState=\(stateMachine.state.displayText) | bg=\(isAppInBackground) | forceScan=\(forceFullScan) | pending=\(isPendingConnectWaiting) | intent=\(preferences.connectionIntent.rawValue)"))
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT] Bắt đầu | central=\(centralManager == nil ? "nil" : "có") | activeCtx=\(activeContext == nil ? "nil" : activeContext!.peripheral.identifier.uuidString.prefix(8).description) | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | smState=\(stateMachine.state.displayText) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan) | isAuth=\(isAuthenticating) | isBackground=\(isAppInBackground) | autoSuspended=\(isSessionAutoSuspended)"))
        guard let central = centralManager else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] centralManager==nil → gọi initializeBluetoothHardware()"))
            initializeBluetoothHardware()
            if activeContext == nil {
                stateMachine.transition(to: .scanning)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CONNECT] willRestoreState đã set activeContext → giữ nguyên state (\(stateMachine.state.displayText))"))
            }
            return
        }
        
        // ═══ GUARD: Kiểm tra peripheral.state (không dùng stateMachine.state) ═══
        // Lý do: stateMachine.state có thể bị override về .scanning sau khi willRestoreState
        // đã set chính xác .connecting (do thứ tự bất định của CBCentralManager init).
        // peripheral.state là giá trị vật lý từ iOS — tin cậy hơn.
        if let ctx = activeContext, ctx.peripheral.state == .connecting {
            // A pending CoreBluetooth request is intentionally allowed to wait
            // indefinitely while the bike is out of range. Only an explicit
            // foreground request replaces it with the short guarded attempt.
            guard userInitiated && isPendingConnectWaiting else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "connect() bỏ qua: peripheral đang kết nối/chờ iOS (state=\(ctx.peripheral.state.rawValue), pending=\(isPendingConnectWaiting))"))
                return
            }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] User mở app khi đang pending → hủy yêu cầu chờ cũ, thử kết nối foreground có timeout"))
            retryScheduler.cancelAll(reason: "foreground thay pending connect")
            isPendingCleanReconnect = true
            beginCleanReconnectDeadline()
            central.cancelPeripheralConnection(ctx.peripheral)
            pollingEngine?.stopPolling()
            authTask?.cancel()
            authTask = nil
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            isAuthenticating = false
            isPendingConnectWaiting = false
            stateMachine.transition(to: .scanning)
            return
        } else if let ctx = activeContext, ctx.peripheral.state == .connected {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "connect() bỏ qua: peripheral đã kết nối (userInitiated=\(userInitiated))"))
            return
        }
        
        if userInitiated {
            retryScheduler.cancelAll(reason: "foreground connect nhận quyền xử lý")
            disconnectingRetryActive = false
        }
        let state = central.state
        
        switch state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            stateMachine.transition(to: .scanning)
            return
        case .poweredOff:
            isPendingConnectWaiting = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self = self else { return }
                if self.centralManager.state == .poweredOff {
                    self.stateMachine.transition(to: .error("Bluetooth đang tắt. Xin bật lại."))
                } else if self.centralManager.state == .poweredOn {
                    self.connect()
                }
            }
            return
        case .unauthorized:
            stateMachine.transition(to: .error("Chưa cấp quyền Bluetooth cho ứng dụng."))
            return
        case .unsupported:
            stateMachine.transition(to: .error("Thiết bị không hỗ trợ Bluetooth LE."))
            return
        @unknown default:
            return
        }
        
        // Reset state cho lần scan mới
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
        scanRetryCount = 0
        
        // ═══ GUARD: Scan đang chạy → bỏ qua duplicate call ═══
        // Nguyên nhân MIC failure khi cold-launch:
        // 1. centralManagerDidUpdateState(.poweredOn) sau power-cycle → connect() → startScanWithTimeout() → reset btWasPoweredOff=false
        // 2. appWillEnterForeground / iOS 18 delay init → connect() được gọi lại ngay lập tức
        // 3. Lần gọi thứ 2 thấy btWasPoweredOff=false → dùng cache → MIC failure!
        // Fix: Nếu scan timer đang chạy, KHÔNG cho phép bất kỳ code path nào dùng cache.
        if scanTimer != nil {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CONNECT] Scan timer đang chạy → bỏ qua duplicate call | smState=\(stateMachine.state.displayText)"))
            return
        }
        
        // Đã pair trước đó → thử retrieve (giống 7c3227a tryReconnectKnown)
        if preferences.savedPin != nil,
           let savedUUIDStr = preferences.savedPeripheralUUID,
           let savedUUID = UUID(uuidString: savedUUIDStr) {
            
            // Recovery scan policy is bounded by btPowerCycleScanRounds.
            // Do not infer encryption-cache lifetime from an arbitrary wall-clock TTL.
            // Scanning itself is not evidence that bonding keys were replaced.

            if btWasPoweredOff || forceFullScan {
                let reason = btWasPoweredOff ? "BT power-cycle" : "peripheral stale (State Restoration)"
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "\(reason) → bỏ qua cache, scan mới để tránh MIC failure"))
                // btWasPoweredOff giữ nguyên — sẽ reset trong didConnect (khi connection thành công)
                forceFullScan = false
                startScanWithTimeout(central: central)
                return
            }
            
            // Step 1: retrieveConnectedPeripherals — xe đang kết nối ở tầng iOS?
            let connected = central.retrieveConnectedPeripherals(withServices: BLEService.allServices)
            if let p = connected.first(where: { $0.identifier.uuidString == savedUUIDStr }) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Xe đang kết nối (live session): \(p.name ?? savedUUIDStr.prefix(8).description)"))
                connectPeripheral(p, central: central)
                return
            }
            
            // Step 2: retrievePeripherals — lấy từ iOS cache (giống 2e6ad99)
            // Với State Restoration, iOS duy trì encryption context → an toàn connect
            let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
            if let p = known.first {
                // ═══ GUARD: Peripheral stale (.disconnecting) → KHÔNG dùng cache ═══
                // Sau khi app bị suspend dài (>5 phút), iOS giữ peripheral ở .disconnecting.
                // Connect vào peripheral này sẽ kẹt retry loop vô hạn.
                // Fix: force fresh scan để iOS negotiate kết nối mới hoàn toàn.
                if p.state == .disconnecting {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Peripheral cache đang .disconnecting (stale sau suspend) → force scan mới | state=\(p.state.rawValue)"))
                    forceFullScan = false
                    startScanWithTimeout(central: central)
                    return
                }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Retrieve peripheral từ cache: \(p.name ?? savedUUIDStr.prefix(8).description)"))
                // F4 (5.2.0): user chủ động (nút "Kết nối lại" / mở app) → connect TRỰC
                // TIẾP kèm Phantom Guard 5s, không phải pending không-guard. Log 19/09
                // 07:47: 2/9 lần bấm rơi vào pending im lặng → user tưởng treo, bấm tiếp.
                connectPeripheral(p, central: central, isPendingConnect: !userInitiated)
                return
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Không tìm thấy xe trong cache — fallback sang scan"))
        }
        
        startScanWithTimeout(central: central)
    }
    
    #if !NOASK
    /// Đường connect từ ASK picker (accessory UUID → peripheral).
    func connect(to uuid: UUID) {
        executeOnBleQueue { [weak self] in
            self?.performConnect(to: uuid)
        }
    }

    private func performConnect(to uuid: UUID) {
        resetCycleTrace()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CKPT request] \(traceCtx(activeContext)) | source=ASK | uuid=\(uuid.uuidString.prefix(8)) | smState=\(stateMachine.state.displayText) | bg=\(isAppInBackground) | intent=\(preferences.connectionIntent.rawValue)"))
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[ASK_CONNECT] uuid=\(uuid.uuidString.prefix(8)) | central=\(centralManager == nil ? "nil" : "state=\(centralManager!.state.rawValue)") | btPowerOff=\(btWasPoweredOff)"))

        // ═══ §4.5 (P3): manualOnly ⇒ ASK event KHÔNG tự kết nối ═══
        // (ASK có thể tự fire accessory events lúc khởi động — không phải ý user)
        if preferences.isManualOnly {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[ASK_CONNECT] Bỏ qua vì intent=\(preferences.connectionIntent.rawValue) (manualOnly) — chờ user chủ động"))
            return
        }

        guard let central = centralManager else { return }
        
        let isMainBike = (uuid.uuidString == preferences.savedPeripheralUUID)
        
        if let ctx = activeContext,
           ctx.peripheral.state == .connected || ctx.peripheral.state == .connecting {
            
            if ctx.peripheral.identifier == uuid {
                // Duplicate selection must not disable the in-flight GATT watchdog.
                // ASK authorization does not own our discovery/auth deadlines.
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[ASK_CONNECT] Duplicate UUID ignored; existing watchdog preserved | state=\(ctx.peripheral.state.rawValue) | smState=\(stateMachine.state.displayText)"))
                return
            } else {
                // Đang kết nối xe khác. Nếu xe đang kết nối là xe chính (saved UUID), KHÔNG cho phép thiết bị phụ ngắt ngang.
                if let savedStr = preferences.savedPeripheralUUID, ctx.peripheral.identifier.uuidString == savedStr {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[ASK_CONNECT] Bỏ qua thiết bị phụ (\(uuid.uuidString.prefix(8))) vì đang giữ kết nối ưu tiên với xe chính (\(savedStr.prefix(8)))"))
                    return
                } else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[ASK_CONNECT] Đang kết nối xe khác (\(ctx.peripheral.identifier.uuidString.prefix(8))) → ngắt kết nối để ưu tiên xe mới (\(uuid.uuidString.prefix(8)))"))
                    central.cancelPeripheralConnection(ctx.peripheral)
                    self.activeContext = nil
                    self.cancelConnectingTimeout()
                }
            }
        }
        
        // CHỈ cập nhật savedPeripheralUUID nếu nó đang rỗng, hoặc thiết bị ASK này chính là xe mới người dùng vừa pick.
        // Tránh bị nhiễu do ASK tự động trả về các thiết bị phụ (ESP) lúc khởi động.
        if preferences.savedPeripheralUUID == nil || !isMainBike && activeContext == nil {
            preferences.savedPeripheralUUID = uuid.uuidString
        }
        
        guard central.state == .poweredOn else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[ASK_CONNECT] BT chưa poweredOn (state=\(central.state.rawValue)) → lưu pendingASKUUID"))
            self.pendingASKUUID = uuid
            return
        }
        
        // ═══ GUARD: Nếu BT vừa power-cycle → PHẢI scan mới, không dùng retrieved cache ═══
        // Lý do: iOS giữ encryption keys cũ trong retrieved peripheral nhưng xe đã xóa → MIC failure.
        // (Giống guard tương tự trong connect() không tham số.)
        if btWasPoweredOff || forceFullScan {
            let reason = btWasPoweredOff ? "BT power-cycle" : "peripheral stale"
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK connect: \(reason) → bỏ qua cache, scan mới để tránh encryption failure"))
            // Flags giữ nguyên — sẽ reset trong didConnect
            startScanWithTimeout(central: central)
            return
        }
        
        // ═══ GUARD: Nếu scan đang chạy (do connect() trước đó), KHÔNG dùng cache ═══
        // Race condition: connect() bắt đầu scan → ASK callback đến 30-50ms sau.
        // Nếu dùng cache ở đây, peripheral có thể mang stale encryption keys → MIC failure.
        // Để scan hiện tại hoàn thành và tìm peripheral mới.
        if scanTimer != nil {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[ASK_CONNECT] Scan đang chạy → bỏ qua retrieve cache, chờ scan hoàn thành | smState=\(stateMachine.state.displayText)"))
            return
        }
        
        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        if let p = known.first {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "ASK Retrieve peripheral thành công: \(p.name ?? uuid.uuidString.prefix(8).description)"))
            // Xe vừa được chọn từ ASK picker (đang phát sóng sát bên) → connect chủ động (isPendingConnect: false)
            connectPeripheral(p, central: central, isPendingConnect: false)
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "ASK UUID không tìm thấy trong cache, kích hoạt fallback scan"))
            startScanWithTimeout(central: central)
        }
    }
    #endif // !NOASK — connect(to:) từ ASK picker

    /// Thiết lập context + kết nối peripheral (dùng chung cho retrieve và scan)
    private func connectPeripheral(_ p: CBPeripheral, central: CBCentralManager, isPendingConnect: Bool = false, disconnectRetryCount: Int = 0) {
        cancelScanTimer()
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT_PERIPHERAL] name=\(p.name ?? "nil") | uuid=\(p.identifier.uuidString.prefix(8)) | peripheralState=\(p.state.rawValue) | centralState=\(central.state.rawValue)"))
        
        // ═══ GUARD: Tránh connect khi peripheral đang trong quá trình .disconnecting ═══
        // iOS chưa dọn xong link-layer → connect ngay sẽ gây phantom connection + MIC failure.
        // Chờ 1.5s để iOS hoàn tất ngắt kết nối rồi mới connect lại.
        if p.state == .disconnecting {
            // ─── Guard: Chỉ cho phép 1 retry chain duy nhất chạy tại một thời điểm ───
            // Khi foreground + didDiscover cùng gọi connectPeripheral(), cả 2 đều thấy
            // .disconnecting và khởi chạy retry loop riêng → 2 chain song song gây rối.
            // Fix: nếu retry đã đang chạy (disconnectingRetryActive=true), bỏ qua call mới.
            if disconnectRetryCount == 0 {
                guard !disconnectingRetryActive else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[CONNECT_PERIPHERAL] Bỏ qua — disconnectingRetry đã chạy | uuid=\(p.identifier.uuidString.prefix(8))"))
                    return
                }
                disconnectingRetryActive = true
                // Gọi cancelPeripheralConnection ngay để iOS dọn link-layer nhanh hơn
                // (đặc biệt sau khi app bị suspend dài — peripheral có thể kẹt .disconnecting hàng phút)
                central.cancelPeripheralConnection(p)
            }
            
            // Giảm threshold từ 5 → 3: Sau 3 lần retry (4.5s) mà vẫn .disconnecting là iOS kẹt
            if disconnectRetryCount >= 3 {
                disconnectingRetryActive = false
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                    message: "[CONNECT_PERIPHERAL] Peripheral kẹt ở .disconnecting quá lâu → CB_RECYCLE (scan mới cùng manager vẫn nhận lại object zombie — bằng chứng TN 11/09)"))
                central.cancelPeripheralConnection(p)
                self.recycleCentralManager(reason: "zombie .disconnecting sau \(disconnectRetryCount) retry")
                return
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[CONNECT_PERIPHERAL] Peripheral đang .disconnecting → chờ 1.5s rồi connect lại (retry: \(disconnectRetryCount))"))
            // §3.7: qua RetryScheduler — kiểm tra pause lúc fire, chết khi đổi session
            self.retryScheduler.schedule(label: "disconnecting-retry #\(disconnectRetryCount)", group: "disconnecting-retry", delay: 1.5) { [weak self] in
                guard let self, let central = self.centralManager, central.state == .poweredOn else {
                    self?.disconnectingRetryActive = false
                    return
                }
                guard !self.isUserPaused else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RETRY] disconnecting-retry bị chặn vì đang PAUSE"))
                    self.disconnectingRetryActive = false
                    return
                }
                self.connectPeripheral(p, central: central, isPendingConnect: isPendingConnect, disconnectRetryCount: disconnectRetryCount + 1)
            }
            return
        }
        
        // Đã thoát khỏi .disconnecting (hoặc không bao giờ vào) — reset guard
        disconnectingRetryActive = false
        
        stateMachine.transition(to: .connecting)
        
        let context = BLEConnectionContext(peripheral: p)
        self.activeContext = context
        p.delegate = self
        self.commandDispatcher = BLECommandDispatcher(context: context)
        self.pollingEngine = BLEPollingEngine(context: context)
        self.isAuthenticating = false
        
        isPendingConnectWaiting = isPendingConnect // §UX: false khi connect chủ động sau scan
        // F7 (5.2.0): SYSTEM AUTO-RECONNECT — link rơi (xe tắt máy/idleOff) thì
        // HỆ THỐNG tự re-establish khi xe phát sóng lại (Apple: "the system ...
        // initiate a connection ... automatically when the link drops"), không
        // phụ thuộc timer app — sống qua suspend, không chết vì race như ladder.
        central.connect(p, options: Self.connectOptions())
        
        if !isPendingConnect {
            startConnectingTimeout()
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[PENDING_CONNECT] Giữ yêu cầu chờ của iOS; chỉ thao tác foreground hoặc lỗi CoreBluetooth mới thay thế yêu cầu này"))
        }
    }
    
    /// Bắt đầu quét BLE với timeout
    private func startScanWithTimeout(central: CBCentralManager) {
        guard central === centralManager, central.state == .poweredOn, !isUserPaused else { return }
        if let ctx = activeContext,
           ctx.peripheral.state == .connected || ctx.peripheral.state == .connecting { return }
        guard scanTimer == nil else { return }
        isPendingConnectWaiting = false
        
        // Ghi nhận trạng thái power-cycle cho log, nhưng KHÔNG reset flag ở đây.
        // btWasPoweredOff chỉ reset trong didConnect — đảm bảo mọi code path
        // (connect(), connect(to:), ASK callback) đều thấy flag nếu chưa connect thành công.
        let wasPowerCycle = btWasPoweredOff
        
        // P1.5: FG cho phép duplicates từ round 0 — xe ngủ sâu advertise thưa,
        // duplicate event là tín hiệu sớm nhất biết xe thức. BG giữ strict (pin).
        let allowDupes = !isAppInBackground || scanRetryCount > 0
        rpaWarnedUUIDs.removeAll() // lượt quét mới — cho phép cảnh báo lại mỗi xe lạ 1 lần
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SCAN] Bắt đầu quét | retry=\(scanRetryCount)/\(maxScanRetries) | allowDupes=\(allowDupes) | timeout=\(scanTimeoutSeconds)s | wasPowerCycle=\(wasPowerCycle) | isBackground=\(isAppInBackground) | phantomFails=\(phantomGuardFailCount)"))
        stateMachine.transition(to: .scanning)
        
        // P1.5: FG scan KHÔNG filter service UUID — firmware deep-sleep có thể
        // advertise không kèm service list → filtered scan miss vĩnh viễn
        // (nguyên nhân "quay lại mở xe rất lâu"). didDiscover tự lọc app-side.
        // BG giữ filtered: iOS bắt buộc service UUID để wake app từ background.
        let scanServices: [CBUUID]? = isAppInBackground ? BLEService.scanUUIDs : nil
        central.scanForPeripherals(withServices: scanServices, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowDupes
        ])
        
        // Timer: Hết thời gian quét → kiểm tra kết quả
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard central === self.centralManager, !self.isUserPaused else { return }
            self.scanTimer = nil
            central.stopScan()
            
            // Nếu đã tìm thấy xe → dừng, chờ user chọn
            if !self.discoveredBikes.isEmpty {
                return
            }
            
            // Chưa tìm thấy → retry hoặc báo lỗi
            self.scanRetryCount += 1
            if self.scanRetryCount < self.maxScanRetries {
                self.startScanWithTimeout(central: central)
            } else {
                // Hết quota scan -> Cắm lệnh kết nối chờ (pending connect) của iOS.
                // ═══ GUARD: Nếu đang trong trạng thái power-cycle, KHÔNG dùng cache ═══
                // Dùng cache sau power-cycle sẽ gây encryption failure / MIC failure.
                // Giới hạn số vòng scan để tránh loop vô tận khi xe ở xa.
                if self.btWasPoweredOff {
                    self.btPowerCycleScanRounds += 1
                    if self.btPowerCycleScanRounds >= self.maxBtPowerCycleScanRounds {
                        // Đã scan 3 vòng (6 retries) mà không thấy xe
                        // → reset flag, chuyển sang pending connect tiết kiệm pin
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "Hết hạn quét xe (power-cycle) — đã scan \(self.btPowerCycleScanRounds) vòng mà không tìm thấy xe → reset btWasPoweredOff, chuyển pending connect"))
                        self.btWasPoweredOff = false
                        self.btPowerCycleScanRounds = 0
                        // Fallback sang pending connect
                        if let savedUUIDStr = self.preferences.savedPeripheralUUID,
                           let savedUUID = UUID(uuidString: savedUUIDStr) {
                            let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
                            if let p = known.first {
                                self.connectPeripheral(p, central: central, isPendingConnect: true)
                                return
                            }
                        }
                        // Không tìm thấy trong cache → báo lỗi
                        self.stateMachine.transition(to: .error("Không tìm thấy xe. Hãy kiểm tra xe đã bật chưa."))
                        return
                    }
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Hết hạn quét xe (power-cycle) — vòng \(self.btPowerCycleScanRounds)/\(self.maxBtPowerCycleScanRounds), tiếp tục scan"))
                    self.scanRetryCount = 0
                    self.startScanWithTimeout(central: central)
                    return
                }
                
                if let savedUUIDStr = self.preferences.savedPeripheralUUID,
                   let savedUUID = UUID(uuidString: savedUUIDStr) {
                    let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
                    if let p = known.first {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "Hết hạn quét xe — chuyển sang bám sóng nền (pending connect)"))
                        self.connectPeripheral(p, central: central, isPendingConnect: true)
                        return
                    }
                }
                
                self.stateMachine.transition(to: .error("Không tìm thấy xe. Hãy kiểm tra xe đã bật chưa."))
            }
        }
        self.scanTimer = timer
        bleQueue.asyncAfter(deadline: .now() + scanTimeoutSeconds, execute: timer)
    }
    
    private func cancelScanTimer() {
        scanTimer?.cancel()
        scanTimer = nil
    }

    /// Timeout guard cho trạng thái .connecting trong State Restoration
    /// Nếu 5.0s mà không chuyển sang .standby/.active → là kết nối phantom, hủy và reconnect
    private func startConnectingTimeout() {
        cancelConnectingTimeout()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[PHANTOM_GUARD] Bắt đầu connecting timeout 5.0s | peripheral=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | failCount=\(phantomGuardFailCount)"))
        let context = activeContext
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.activeContext === context else { return }
            guard case .connecting = self.stateMachine.state else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                    message: "[PHANTOM_GUARD] Timeout fire nhưng state=\(self.stateMachine.state.displayText) → bỏ qua"))
                return
            }
            
            // B5 FIX: Exponential backoff — chờ lâu dần mỗi lần thất bại liên tiếp
            self.phantomGuardFailCount += 1
            let backoffDelay = min(Double(self.phantomGuardFailCount) * 2.0, self.maxPhantomGuardBackoffSeconds)
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[PHANTOM_GUARD] Timeout 5.0s! | uuid=\(self.activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(self.activeContext?.peripheral.state.rawValue ?? -1) | failCount=\(self.phantomGuardFailCount) | backoffDelay=\(backoffDelay)s"))
            self.logCycle("fail", extra: "stage=phantom-timeout peripheralState=\(self.activeContext?.peripheral.state.rawValue ?? -1) failCount=\(self.phantomGuardFailCount)")
            
            if let ctx = self.activeContext, let central = self.centralManager {
                central.cancelPeripheralConnection(ctx.peripheral)
            }
            self.activeContext = nil
            self.commandDispatcher = nil
            self.pollingEngine = nil
            self.isAuthenticating = false
            self.forceFullScan = true
            self.isPendingConnectWaiting = false
            self.stateMachine.transition(to: .scanning)
            
            if backoffDelay > 0 {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[PHANTOM_GUARD] Backoff \(backoffDelay)s trước khi scan lại (lần thất bại thứ \(self.phantomGuardFailCount))"))
                // §3.7: PhantomGuard NHẬN QUYỀN retry → void mọi chuỗi retry khác;
                // backoff qua RetryScheduler (pause-safe, session-scoped).
                self.retryScheduler.cancelGroups(["mic-retry", "fail-connect-retry", "standby-drain", "disconnecting-retry"], reason: "PhantomGuard nhận quyền retry")
                self.retryScheduler.schedule(label: "phantom-backoff #\(self.phantomGuardFailCount)", group: "phantom-guard", delay: backoffDelay) { [weak self] in
                    self?.connect()
                }
            } else {
                self.connect()
            }
        }
        self.connectingTimer = timer
        bleQueue.asyncAfter(deadline: .now() + 5.0, execute: timer)
    }
    
    private func cancelConnectingTimeout() {
        connectingTimer?.cancel()
        connectingTimer = nil
    }

    // ═══════════════════════════════════════════════════════════════════
    // §3.2 (P2) — DISCOVERY WATCHDOG + retry
    // didConnect → discoverServices → didDiscoverServices → didDiscoverCharacteristics.
    // Trước đây: (a) không watchdog nào chạy sau didConnect → xe im lặng = kẹt
    // .connecting vĩnh viễn; (b) didDiscoverServices error bị nuốt im lặng.
    // Giờ: watchdog 10s; error → retry discovery (tối đa 2) → abort với lỗi rõ ràng.
    // Watchdog chỉ cancel khi ĐỦ 3 characteristic bắt buộc (gate trong
    // didDiscoverCharacteristicsFor).
    // ═══════════════════════════════════════════════════════════════════

    private var discoveryWatchdog: DispatchWorkItem?
    /// Số lần retry discovery cho connection attempt hiện tại (reset trong didConnect).
    private var discoveryRetryCount = 0
    private let maxDiscoveryRetries = 2
    private let discoveryWatchdogSeconds: Double = 10.0

    private func startDiscoveryWatchdog() {
        cancelDiscoveryWatchdog()
        let context = activeContext
        let timer = DispatchWorkItem { [weak self] in
            guard let self = self, self.activeContext === context else { return }
            guard case .connecting = self.stateMachine.state else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                    message: "[DISCOVERY_WATCHDOG] fire nhưng state=\(self.stateMachine.state.displayText) → bỏ qua"))
                return
            }
            guard let ctx = self.activeContext, ctx.peripheral.state == .connected else { return }

            let have = ctx.discoveredCharacteristics.count
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[DISCOVERY_WATCHDOG] \(self.discoveryWatchdogSeconds)s mà chưa đủ characteristic bắt buộc (đã có \(have)) → retry/abort"))
            self.retryDiscoveryOrAbort(peripheral: ctx.peripheral,
                                       reason: "watchdog \(Int(self.discoveryWatchdogSeconds))s: thiếu characteristic (có \(have))")
        }
        discoveryWatchdog = timer
        bleQueue.asyncAfter(deadline: .now() + discoveryWatchdogSeconds, execute: timer)
    }

    private func cancelDiscoveryWatchdog() {
        discoveryWatchdog?.cancel()
        discoveryWatchdog = nil
    }

    /// Retry discovery trên cùng link; hết quota → abort với thông báo rõ ràng.
    private func retryDiscoveryOrAbort(peripheral: CBPeripheral, reason: String) {
        discoveryRetryCount += 1
        if discoveryRetryCount <= maxDiscoveryRetries {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[DISCOVERY_RETRY] \(reason) — thử lại lần \(discoveryRetryCount)/\(maxDiscoveryRetries)"))
            peripheral.discoverServices(BLEService.allServices)
            startDiscoveryWatchdog()
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "[DISCOVERY_ABORT] \(reason) — đã retry \(maxDiscoveryRetries) lần → hủy kết nối"))
            logCycle("fail", extra: "stage=gatt reason=\"\(reason)\"")
            cancelDiscoveryWatchdog()
            centralManager?.cancelPeripheralConnection(peripheral)
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            isAuthenticating = false
            stateMachine.transition(to: .error(
                "Xe phản hồi không đầy đủ (\(reason)).\nHãy kiểm tra xe còn bật, sau đó thử kết nối lại."
            ))
        }
    }
    
    /// User chọn xe từ danh sách → kết nối
    func selectBike(_ bikeId: String) {
        executeOnBleQueue { [weak self] in
            self?.performSelectBike(bikeId)
        }
    }

    private func performSelectBike(_ bikeId: String) {
        guard let bike = discoveredBikes.first(where: { $0.id == bikeId }),
              let central = centralManager else { return }
        
        cancelScanTimer()
        central.stopScan()
        
        // Cleanup context cũ để tránh orphan BLETaskQueue/BLECharacteristicIO
        pollingEngine?.stopPolling()
        if let oldCtx = activeContext {
            central.cancelPeripheralConnection(oldCtx.peripheral)
            oldCtx.clearState()
        }
        
        // Tái sử dụng connectPeripheral chuẩn: đầy đủ context, delegate, phantom guard watchdog, options
        connectPeripheral(bike.peripheral, central: central, isPendingConnect: false)
    }
    
    func disconnect() {
        executeOnBleQueue { [weak self] in
            self?.performDisconnect()
        }
    }

    func forgetBike() {
        executeOnBleQueue { [weak self] in
            guard let self else { return }
            // Đã tắt ASK: Không remove accessory qua ASKManager
            self.performDisconnect()
            self.preferences.savedPin = nil
            self.preferences.savedPeripheralUUID = nil
            self.preferences.savedBikeName = nil
            self.preferences.savedBikeSerial = nil
            self.preferences.savedBikeMac = nil
            self.preferences.savedBikeModel = nil
            self.preferences.savedBikeFirmware = nil
        }
    }

    private func performDisconnect() {
        isPendingConnectWaiting = false
        shouldTurnOnBikeAfterAuth = false
        isPendingCleanReconnect = false // C2 (5.1.0): user chủ động disconnect — bỏ luôn ý định nối lại
        cancelCleanReconnectDeadline()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DISCONNECT] Gọi disconnect() | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | authTask=\(authTask != nil ? "đang chạy" : "nil") | isAuth=\(isAuthenticating)"))
        cancelScanTimer()
        cancelConnectingTimeout()
        cancelDiscoveryWatchdog() // §3.2
        retryScheduler.cancelAll(reason: "disconnect()") // §3.7
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        centralManager?.stopScan()
        stateMachine.transition(to: .idle)
        pollingEngine?.stopPolling()
        authTask?.cancel()
        authTask = nil
        authAttemptID = nil
        if let ctx = activeContext {
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        standbyTimer?.invalidate()
        standbyTimer = nil
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
    }

    /// Public read cho ViewModel/UI biết đang tạm dừng hay không.
    var isConnectionPaused: Bool { isUserPaused }

    /// LỚP 3: User chủ động Tạm dừng — ngắt BLE hoàn toàn, KHÔNG auto-reconnect
    /// (kể cả khi app relaunch). isUserPaused chặn mọi pending-connect/connect()
    /// nên không còn code=6 trong thời gian tạm dừng. Gọi resumeConnection() để mở lại.
    func pauseConnection() {
        executeOnBleQueue { [weak self] in
            self?.performPauseConnection()
        }
    }

    private func performPauseConnection() {
        guard !isUserPaused else { return }
        isUserPaused = true
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[PAUSE] User tạm dừng kết nối — ngắt BLE, chặn auto-reconnect"))
        // §3.7: PAUSE giết toàn bộ retry đã lập lịch (không còn retry "bypass" pause)
        retryScheduler.cancelAll(reason: "pauseConnection")
        // disconnect() ngắt hẳn + .idle; isUserPaused=true đã chặn mọi pending/connect().
        disconnect()
    }

    /// LỚP 3: User Tiếp tục sau khi tạm dừng.
    func resumeConnection() {
        executeOnBleQueue { [weak self] in
            self?.performResumeConnection()
        }
    }

    private func performResumeConnection() {
        guard isUserPaused else { return }
        isUserPaused = false
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RESUME] User tiếp tục kết nối"))
        connect()
    }

    // ═══════════════════════════════════════════════════════════════════
    // §4 (P3) — INTENT APIS: nút "Ở gần xe, chưa dùng" + "Kết nối để dùng xe"
    // Cả hai dùng chung cơ chế manualOnly (quyết định #2 của chủ sở hữu);
    // khác nhau ở reason → copy UI +analytics.
    // ═══════════════════════════════════════════════════════════════════

    /// Intent hiện tại (ViewModel đọc để render card manualOnly).
    var connectionIntent: ConnectionIntent { preferences.connectionIntent }
    var isManualOnly: Bool { preferences.connectionIntent.isManualOnly }

    /// §4.1: Nút "Ở gần xe, chưa dùng" — ngắt BLE MỘT LẦN, vào manualOnly(nearbyNotInUse).
    /// KHÔNG auto-connect bởi RSSI/foreground/BT-toggle/relaunch/ASK/deep-link.
    /// An toàn: không gửi powerOff/arm — xe tự tắt theo idleOff của firmware.
    func setNearbyNotInUse() {
        executeOnBleQueue { [weak self] in
            self?.performSetNearbyNotInUse()
        }
    }

    private func performSetNearbyNotInUse() {
        isPendingConnectWaiting = false
        preferences.connectionIntent = .manualOnlyNearbyNotInUse
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[NEARBY_NOT_IN_USE] User chọn 'Ở gần xe, chưa dùng' — ngắt BLE một lần, chặn toàn bộ auto-connect"))
        retryScheduler.cancelAll(reason: "setNearbyNotInUse")
        disconnect()
    }

    /// §4.1: "Kết nối để dùng xe" (nút chính trên card) và deep-link connect —
    /// hành động CHỦ ĐỘNG của user ⇒ thoát manualOnly và kết nối (quyết định #1).
    func connectForRide() {
        executeOnBleQueue { [weak self] in
            self?.performConnectForRide()
        }
    }

    private func performConnectForRide() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CONNECT_FOR_RIDE] User yêu cầu dùng xe — thoát manualOnly (intent cũ: \(preferences.connectionIntent.rawValue))"))
        preferences.connectionIntent = .autoConnect
        connect(userInitiated: true)
    }

    /// Reset TOÀN BỘ trạng thái BLE (flags, timers, context) rồi connect từ đầu.
    /// Giải quyết mọi trường hợp kẹt: scan loop, stale flags, phantom connections.
    func forceReconnect() {
        executeOnBleQueue { [weak self] in
            self?.performForceReconnect()
        }
    }

    private func performForceReconnect() {
        retryScheduler.cancelAll(reason: "force reconnect nhận quyền xử lý")
        cancelCleanReconnectDeadline()
        isPendingCleanReconnect = false
        cancelDiscoveryWatchdog()
        authAttemptID = nil
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[FORCE_RECONNECT] User yêu cầu kết nối lại | smState=\(stateMachine.state.displayText) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan) | micRetry=\(micRetryCount) | scanRetry=\(scanRetryCount)"))

        // §4.5 (P3): nút này là hành động CHỦ ĐỘNG của user → thoát manualOnly
        if preferences.isManualOnly {
            preferences.connectionIntent = .autoConnect
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[FORCE_RECONNECT] Thoát manualOnly theo yêu cầu user"))
        }
        // C3 (5.1.0): hành động chủ động của user = ngân sách CB_RECYCLE mới —
        // không kế thừa quota cũ của chuỗi tự chữa trước đó (5.0.0 chỉ reset khi
        // auth thành công → user bấm reconnect vẫn bị "dừng tự chữa" thừa kế)
        cbRecycleCount = 0
        // LOG (5.1.0): đóng [CYCLE] tại đây — teardown này chấm dứt chu kỳ đang
        // chạy nhưng 5.0.0 không log dòng kết → grep [CYCLE] bị thiếu lượt,
        // phân tích outcome/tổng thời gian theo docs sai lệch.
        logCycle("fail", via: "force-reconnect", extra: "stage=\(stateMachine.state.displayText)")

        // 1. Hủy mọi kết nối/scan đang chạy
        cancelScanTimer()
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        centralManager?.stopScan()
        authTask?.cancel()
        authTask = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        pollingEngine?.stopPolling()
        
        // 2. Cancel peripheral connection nếu có
        let hadContext = (activeContext != nil)
        if let ctx = activeContext {
            isPendingCleanReconnect = true
            // C2 (5.1.0): không chờ didDisconnect vô hạn — zombie .disconnecting
            // không bao giờ sinh event này
            beginCleanReconnectDeadline()
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        
        // 3. Reset TẤT CẢ flags về trạng thái sạch (NGOẠI TRỪ micRetryCount để giữ ngữ cảnh khôi phục)
        isPendingConnectWaiting = false
        btWasPoweredOff = false
        // F4 (5.2.0): vừa gặp MIC/encryption failure (≤60s) → GIỮ forceFullScan.
        // Đường cache chính là đường đang fail (log 19/09 07:47: user bấm 5 lần,
        // 3 MIC liền từ retrievePeripherals). Giữ flag → connect() đi scan mới.
        if Date().timeIntervalSince(lastMicFailureTime ?? .distantPast) > micRetryTTL {
            forceFullScan = false
        }
        btPowerCycleScanRounds = 0
        scanRetryCount = 0
        consecutiveStandbyCount = 0
        weakRssiConsecutiveCount = 0
        phantomGuardFailCount = 0
        isAuthenticating = false
        isRestoringSession = false
        isSessionAutoSuspended = false
        isDowngrading = false
        disconnectingRetryActive = false
        
        // 4. Chuyển về scanning rồi chờ connect mới
        stateMachine.transition(to: .scanning)
        DispatchQueue.main.async {
            self.discoveredBikes = []
        }
        
        // 5. Nếu không có activeContext, gọi connect ngay.
        // Nếu có, chờ didDisconnectPeripheral gọi connect để đảm bảo "ngắt xong mới nối".
        if !hadContext {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[FORCE_RECONNECT] Bắt đầu kết nối mới (clean state)"))
            // F4 (5.2.0): user bấm → connect trực tiếp có Phantom Guard, không pending
            self.connect(userInitiated: true)
        }
    }
    
    // ═══ §CB_RECYCLE: tái tạo CBCentralManager ═══
    // Hai bẫy chết CHỈ thoát được bằng đường này:
    // 1) Zombie .disconnecting: CBPeripheral được CoreBluetooth unique theo
    //    (manager, UUID) — manager cũ trả mãi đúng object kẹt .disconnecting,
    //    mọi connect() bị chặn vĩnh viễn dù xe đang phát sóng sát bên.
    //    Manager mới = bộ peripheral object mới = thoát zombie.
    // 2) MIC failure (code 31) lặp lại: bỏ các peripheral/context của manager cũ
    //    để thử phục hồi. CoreBluetooth không cung cấp API xóa encryption cache;
    //    manager mới không bảo đảm sửa được lỗi khóa/firmware của peer.
    // Giữ nguyên restore ID để nền tảng state-restoration không bị đứt.
    private func recycleCentralManager(reason: String) {
        guard cbRecycleCount < maxCbRecyclesPerSession else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "[CB_RECYCLE] Hết ngân sách \(cbRecycleCount)/\(maxCbRecyclesPerSession) → foreground báo lỗi, background giữ pending connect"))
            // C3 (5.1.0): "dừng tự chữa" của 5.0.0 = mất luôn pending connect wake-up —
            // đúng thứ khiến 4.9.1 "lúc nào lại gần xe cũng nối được (chậm mà chắc)".
            // Hết quota recycle thì về hành vi 4.9.1: cờ sạch + pending connect nền.
            btWasPoweredOff = false
            forceFullScan = false
            btPowerCycleScanRounds = 0
            retryScheduler.cancelAll(reason: "recovery budget exhausted")
            cancelCleanReconnectDeadline()
            isPendingCleanReconnect = false
            cancelDiscoveryWatchdog()
            cancelConnectingTimeout()
            cancelScanTimer()
            centralManager?.stopScan()
            if let ctx = activeContext { centralManager?.cancelPeripheralConnection(ctx.peripheral) }
            activeContext = nil
            commandDispatcher = nil
            pollingEngine?.stopPolling()
            pollingEngine = nil
            isAuthenticating = false
            authTask?.cancel()
            authTask = nil
            authAttemptID = nil
            if !isAppInBackground {
                isPendingConnectWaiting = false
                stateMachine.transition(to: .error("Không thể thiết lập kết nối Bluetooth với xe. Hãy thử kết nối lại sau vài giây."))
            } else if centralManager?.state == .poweredOn {
                stateMachine.transition(to: .scanning)
                connect()
            }
            return
        }
        cancelCleanReconnectDeadline()
        isPendingCleanReconnect = false
        cancelDiscoveryWatchdog()
        authAttemptID = nil
        cbRecycleCount += 1
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[CB_RECYCLE] Tái tạo CBCentralManager lần \(cbRecycleCount)/\(maxCbRecyclesPerSession) | lý do=\(reason) | smState=\(stateMachine.state.displayText)"))
        // LOG (5.1.0): đóng [CYCLE] cho chu kỳ đang chạy trước khi context bị dỡ —
        // cùng lý do như force-reconnect: teardown phải có dòng kết [CYCLE].
        if cycleRequestedAt != nil {
            logCycle("fail", via: "cb-recycle", extra: "stage=\(stateMachine.state.displayText)")
        }

        // 1. Hủy mọi đường đang chạy
        cancelScanTimer()
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        standbyTimer?.invalidate()
        standbyTimer = nil
        authTask?.cancel()
        authTask = nil
        pollingEngine?.stopPolling()
        centralManager?.stopScan()
        self.retryScheduler.cancelGroups(
            ["phantom-guard", "standby-drain", "disconnecting-retry", "mic-retry"],
            reason: "CB_RECYCLE nhận quyền xử lý"
        )

        // 2. Đưa peripheral (kể cả zombie) về nil
        if let ctx = activeContext {
            centralManager?.cancelPeripheralConnection(ctx.peripheral)
        }
        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil

        // 3. Reset flags về trạng thái "connect mới hoàn toàn"
        isPendingConnectWaiting = false
        btWasPoweredOff = false
        forceFullScan = true
        disconnectingRetryActive = false
        isAuthenticating = false
        isRestoringSession = false
        scanRetryCount = 0

        // 4. Manager mới cùng restore ID — .poweredOn callback sẽ đi luồng chuẩn
        //    (forceFullScan=true + activeContext=nil → scan mới + peripheral object sạch)
        stateMachine.transition(to: .scanning)
        centralManager = nil
        centralManager = CBCentralManager(delegate: self, queue: bleQueue, options: Self.centralManagerOptions())
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CB_RECYCLE] Manager mới đã tạo — chờ .poweredOn để scan sạch"))
    }

    func forceAuthenticate(turnOn: Bool = false) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[FORCE_AUTH] turnOn=\(turnOn) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext != nil) | savedPin=\(preferences.savedPin != nil ? "có" : "nil")"))
        self.isSessionAutoSuspended = true
        if turnOn {
            self.shouldTurnOnBikeAfterAuth = true
        }

        // .standby (chờ ngưỡng RSSI) và .nearby (đang ở gần, chưa auth) đều có
        // link BLE + characteristic sẵn sàng → auth được ngay (fix 5.3.0: user
        // bấm lệnh điều khiển từ .nearby phải nâng cấp lên phiên auth).
        if stateMachine.state == .standby || stateMachine.state == .nearby {
            standbyTimer?.invalidate()
            standbyTimer = nil
            isAuthenticating = true
            if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                self.executeAuthProtocol(ctx: ctx, pin: pin)
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[FORCE_AUTH] Không thể auth: ctx=\(activeContext != nil) pin=\(preferences.savedPin != nil)"))
            }
        }
    }
    
    func wakeUpFromStandby() {
        self.isSessionAutoSuspended = true
        if stateMachine.state == .standby || stateMachine.state == .nearby {
            forceAuthenticate(turnOn: true)
        } else {
            shouldTurnOnBikeAfterAuth = true
            connect()
        }
    }
    
    func getDispatcher() throws -> IoTCommandService {
        guard let d = commandDispatcher else { throw IoTError.notConnected }
        return d
    }
    
    /// C4 (5.1.0): chống chồng batch telemetry — polling mỗi 10s fire một Task
    /// không await; link yếu một batch có thể chiếm queue >10s → batch chồng batch
    /// → backlog vô hạn trong BLETaskQueue (FIFO) → lệnh khóa/mở của user xếp sau
    /// ("ấn nút không ăn" của 5.0.0). Batch ĐỊNH KỲ skip nếu batch trước chưa xong;
    /// lượt gọi chủ động (foreground/auth/user) luôn chạy.
    private var isTelemetryBatchInFlight = false

    /// Đọc telemetry + lock state từ xe
    /// - Parameter includeLockState: `false` cho chu kỳ polling — BLEPollingEngine
    ///   đã đọc smartkeyEcho và parse lock state tại callback (C4: trước 5.1.0 echo
    ///   bị đọc 2 lần/chu kỳ vì cả polling lẫn batch đều read UUID này).
    func queryTelemetry(includeLockState: Bool = true) {
        guard let ctx = activeContext else { return }
        if !includeLockState, isTelemetryBatchInFlight {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                message: "[TELEMETRY] Batch trước chưa xong → skip chu kỳ định kỳ này (chống nghẽn hàng GATT)"))
            return
        }
        isTelemetryBatchInFlight = true
        Task {
            defer { isTelemetryBatchInFlight = false }
            do {
                // Đọc Dashboard Telemetry (timeout 3s — telemetry là dữ liệu phụ,
                // không đáng chiếm hàng GATT 8s khi link yếu)
                if let dashChar = try? ctx.requireCharacteristic(BLECharacteristic.dashboardData) {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: dashChar, timeoutSeconds: 3)
                    }

                    if data.count >= 40 {
                        let tele = DashboardTelemetry(from: data)
                        DispatchQueue.main.async {
                            guard self.activeContext === ctx else { return }
                            self.currentTelemetry.motorTemp = tele.motorTemp
                            self.currentTelemetry.controllerTemp = tele.controllerTemp
                            self.currentTelemetry.odometerKm = tele.odometerKm
                            self.currentTelemetry.speedKmh = tele.speedKmh
                        }
                    } else if data.count >= 13 {
                        let tele = BLETelemetryParser.parseTelemetry(from: data)
                        DispatchQueue.main.async {
                            guard self.activeContext === ctx else { return }
                            self.currentTelemetry.motorTemp = tele.motorTemp
                            self.currentTelemetry.controllerTemp = tele.controllerTemp
                            self.currentTelemetry.odometerKm = tele.odometerKm
                            self.currentTelemetry.speedKmh = tele.speedKmh
                        }
                    }
                }
                
                // Đọc Battery SOC (JSON) — cũng cập nhật BMS detail
                await readBatteryJSON(ctx: ctx, timeoutSeconds: 3)

                // Đọc Lock State (smartkeyEcho) — chỉ khi caller CHƯA có echo data sẵn
                if includeLockState,
                   let echoChar = try? ctx.requireCharacteristic(BLECharacteristic.smartkeyEcho) {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: echoChar, timeoutSeconds: 3)
                    }
                    let status = IoTLockState.parse(from: data)
                    DispatchQueue.main.async {
                        guard self.activeContext === ctx else { return }
                        self.lockStateSessionID = ctx.sessionID
                        self.currentLockState = status
                    }
                }
            } catch {
                PersistentLogger.shared.append(BLELogEntry(
                    timestamp: Date(), level: .warning,
                    message: "Query telemetry lỗi: \(error.localizedDescription)"
                ))
            }
        }
    }
    
    /// Đọc chi tiết BMS — gọi được độc lập từ BatteryViewModel
    func queryBatteryDetail() {
        guard let ctx = activeContext else { return }
        Task {
            await readBatteryJSON(ctx: ctx)
        }
    }
    
    /// Logic chung đọc Battery JSON từ BLE characteristic (C4: timeout per-call)
    private func readBatteryJSON(ctx: BLEConnectionContext, timeoutSeconds perCallTimeout: Double? = nil) async {
        do {
            guard let batChar = try? ctx.requireCharacteristic(BLECharacteristic.batteryData) else { return }
            let data = try await ctx.queue.enqueue {
                try await ctx.io.readValue(from: batChar, timeoutSeconds: perCallTimeout)
            }
            if let json = String(bytes: data, encoding: .utf8) {
                // Parse JSON
                if let jsonData = json.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(BatteryTelemetry.self, from: jsonData) {
                    if let socValue = decoded.soc?.soc {
                        let percent = Int(socValue * 100)
                        DispatchQueue.main.async {
                            guard self.activeContext === ctx else { return }
                            self.currentTelemetry.soc = Float(percent)
                        }
                    }
                    
                    
                    // Log extra keys chưa decode được (giúp discover thêm data)
                    if let extra = decoded.rawExtraKeys, !extra.isEmpty {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "BMS JSON keys chưa decode: \(extra.joined(separator: ", ")) — cần bổ sung model!"))
                    }
                    
                    DispatchQueue.main.async {
                        guard self.activeContext === ctx else { return }
                        self.currentBatteryTelemetry = decoded
                    }
                }
            }
        } catch {
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .warning,
                message: "Đọc BMS lỗi: \(error.localizedDescription)"
            ))
        }
    }
    
    // MARK: - Auto Unlock Wiring
    private func setupAutoUnlock(engine: BLEPollingEngine) {
        engineCancellables.removeAll()
        guard let pollingContext = activeContext else { return }

        // Định kỳ cập nhật toàn diện Telemetry (Pin SOC, Odo, Nhiệt độ Motor) mỗi 10s trong phiên active
        // C4 (5.1.0): lock state parse từ echo data polling vừa đọc xong — batch
        // telemetry không đọc lại UUID này (4→2 GATT reads/chu kỳ, hết nghẽn hàng).
        engine.onPeriodicTelemetryPoll = { [weak self] echoData in
            guard let self, self.activeContext === pollingContext else { return }
            let status = IoTLockState.parse(from: echoData)
            DispatchQueue.main.async {
                guard self.activeContext === pollingContext else { return }
                self.lockStateSessionID = pollingContext.sessionID
                self.currentLockState = status
            }
            self.queryTelemetry(includeLockState: false)
        }
        
        // didReadRSSI is the single input to the EMA. Do not subscribe back to
        // engine.currentRSSI: its initial 0 is not a measurement, and forwarding
        // each delegate sample through it would smooth the same sample twice.

        // ═══ LUỒNG A: Auto-bật xe khi lại gần ═══
        // Dùng smoothedRSSI (EMA) thay vì raw RSSI để tránh false-trigger do spike nhiễu
        // (BLE jitter ±5-10dB). Chỉ unlock khi thật sự đủ gần ổn định.
        $smoothedRSSI
            .combineLatest($currentLockState, preferences.$autoUnlockEnabled, preferences.$autoTurnOnThreshold)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (rssi, lockState, isAutoUnlockOn, threshold) in
                // Yêu cầu: Tính năng này chỉ cho phép dùng khi sử dụng ngưỡng kết nối (connectOnlyWhenNear = true)
                guard let self = self, isAutoUnlockOn, self.preferences.connectOnlyWhenNear else { return }
                guard !self.isSessionAutoSuspended,
                      !self.preferences.isManualOnly,
                      self.stateMachine.state == .active,
                      (-127 ... -1).contains(rssi) else { return }

                // Yêu cầu: Tính năng này chỉ hoạt động khi thoả ngưỡng
                if Double(rssi) >= threshold, lockState == .locked {
                    guard let context = self.activeContext,
                          self.lockStateSessionID == context.sessionID,
                          self.hasFreshProximitySample(for: context),
                          self.autoCommandReservation == nil,
                          self.autoCommandAttemptedSession != context.sessionID,
                          let dispatcher = self.commandDispatcher else { return }
                    let reservation = UUID()
                    self.autoCommandReservation = reservation
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer {
                            if self.autoCommandReservation == reservation {
                                self.autoCommandReservation = nil
                            }
                        }
                        guard self.activeContext === context,
                              self.lockStateSessionID == context.sessionID,
                              !self.isSessionAutoSuspended,
                              !self.preferences.isManualOnly,
                              self.preferences.autoUnlockEnabled,
                              self.preferences.connectOnlyWhenNear,
                              self.hasFreshProximitySample(for: context),
                              Double(self.smoothedRSSI) >= self.preferences.autoTurnOnThreshold,
                              self.currentLockState == .locked,
                              self.stateMachine.state == .active else { return }
                        // Once a write may have reached the bike, do not blindly
                        // replay it after an ambiguous timeout in this session.
                        self.autoCommandAttemptedSession = context.sessionID
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[CKPT auto-cmd] \(self.traceCtx(context)) | action=turnOnBike | smoothed=\(self.smoothedRSSI) | threshold=\(Int(self.preferences.autoTurnOnThreshold)) | lockState=\(lockState)"))
                        do {
                            let confirmedState = try await dispatcher.turnOnBike()
                            guard self.activeContext === context,
                                  !self.preferences.isManualOnly,
                                  confirmedState == .unlocked else { return }
                            NotificationManager.shared.sendNotification(
                                title: "Trạng thái xe",
                                body: "Đã xác nhận xe bật khi lại gần",
                                identifier: "AutoTurnOn"
                            )
                        } catch {
                            // C7 (5.1.0): phân biệt lỗi "chắc chắn CHƯA tới xe" (notConnected,
                            // gattOverload flush khỏi queue TRƯỚC khi ghi) → trả lại lượt thử
                            // cho session này. commandTimeout vẫn giữ cờ một-lần/session vì
                            // write có thể đã tới xe — chống replay mù (nguyên tắc §5.1.0 giữ nguyên).
                            var allowRetryThisSession = false
                            if let ioError = error as? IoTError {
                                switch ioError {
                                case .notConnected, .gattOverload: allowRetryThisSession = true
                                default: break
                                }
                            }
                            if allowRetryThisSession, self.autoCommandAttemptedSession == context.sessionID {
                                self.autoCommandAttemptedSession = nil
                            }
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "[AUTO_TURN_ON] Chưa xác nhận bật xe: \(error.localizedDescription)\(allowRetryThisSession ? " (lệnh chưa tới xe → cho thử lại session này)" : "")"))
                        }
                    }
                }
            }
            .store(in: &engineCancellables)

        // ═══ LUỒNG B (auto-downgrade khi RSSI yếu) ĐÃ BỎ ═══
        // Lý do: RSSI BLE không ổn định (jitter ±5-10dB), dùng nó làm trigger disconnect
        // GATT gây vòng lặp: active → (RSSI spike yếu) → standby/nearby → giữ GATT →
        // xe idleOff → code=6 → reconnect → lặp ~5s/lần (2.354 lần code=6 trong log 3 tháng).
        // Giờ app GIỮ .active đến khi xe tự tắt (idleOff); khi đó code=6 → iOS pending
        // connect (xử lý ở didDisconnectPeripheral) tự wake app khi user lại gần.
        // standby/nearby vẫn dùng được khi USER chủ động (forceStandbyOverride / activateNearbyMode).
    }

    /// Cập nhật currentRSSI + smoothedRSSI (EMA) tại mọi điểm đọc RSSI.
    /// Tập trung 2 nguồn: engine poll (active) và didReadRSSI (standby/nearby).
    private func updateRSSI(_ value: Int) {
        guard let context = activeContext,
              let filtered = proximitySamples.record(value, sessionID: context.sessionID,
                  now: ProcessInfo.processInfo.systemUptime) else { return }
        currentRSSI = value
        smoothedRSSI = filtered
        // §LOG: chỉ log khi EMA đổi band so với autoTurnOnThreshold — không flood
        // mỗi 2s. Đây là khoảnh khắc quyết định auto-bật: giá trị này + freshness
        // là input của gate trong setupAutoUnlock.
        let above = Double(filtered) >= preferences.autoTurnOnThreshold
        if let prevBand = lastRSSIBandAboveThreshold, prevBand != above {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CKPT rssi-cross] \(traceCtx(context)) | dir=\(above ? "enter" : "exit") | smoothed=\(filtered) | raw=\(value) | threshold=\(Int(preferences.autoTurnOnThreshold)) | fresh=\(hasFreshProximitySample(for: context))"))
        }
        lastRSSIBandAboveThreshold = above
    }
    
    // MARK: - Battery Monitoring Wiring
    private func setupBatteryMonitoring() {
        $currentBatteryTelemetry
            .dropFirst() // Bỏ qua giá trị nil khởi tạo
            .sink { [weak self] current in
                guard let self = self, let current = current else { return }
                guard let previous = self.previousBatteryTelemetry else {
                    self.previousBatteryTelemetry = current
                    return
                }
                
                // 1. Cảnh báo sạc đầy
                if self.preferences.notifyOnBatteryFull {
                    if previous.socPercent < 100 && current.socPercent == 100 {
                        NotificationManager.shared.sendNotification(
                            title: "Pin đã đầy",
                            body: "Xe Datbike của bạn đã sạc đầy 100%.",
                            identifier: NotificationCategory.batteryFull.rawValue
                        )
                    }
                }
                
                // 2. Cảnh báo pin chạm ngưỡng
                if self.preferences.notifyOnBatteryThreshold {
                    let threshold = self.preferences.batteryLowThreshold
                    if previous.socPercent > threshold && current.socPercent <= threshold {
                        NotificationManager.shared.sendNotification(
                            title: "Pin yếu",
                            body: "Dung lượng pin xe đã giảm xuống \(current.socPercent)%. Vui lòng sạc xe sớm.",
                            identifier: NotificationCategory.batteryLow.rawValue
                        )
                    }
                }
                
                // 3. Báo động mất sạc (Chuyển trạng thái từ Đang sạc sang trạng thái khác khi xe đang tắt)
                if self.preferences.notifyOnChargeDisconnect {
                    if previous.chargingState == .charging && current.chargingState != .charging {
                        if self.currentLockState == .locked || self.currentLockState == .armed {
                            NotificationManager.shared.sendNotification(
                                title: "Cảnh báo ngắt sạc!",
                                body: "Nguồn sạc của xe đã bị ngắt bất ngờ trong khi xe đang tắt.",
                                identifier: NotificationCategory.chargeDisconnect.rawValue
                            )
                        }
                    }
                }
                
                self.previousBatteryTelemetry = current
            }
            .store(in: &cancellables)
    }
    
    func forceStandbyOverride() {
        guard stateMachine.state == .active else { return }
        isSessionAutoSuspended = true
        downgradeToStandby(force: true)
    }
    
    /// Khi user đang ở .nearby và bấm "Kết nối" → auth ngay
    func connectFromNearby() {
        guard case .nearby = stateMachine.state,
              let ctx = activeContext,
              ctx.peripheral.state == .connected,
              let pin = preferences.savedPin else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[NEARBY→AUTH] Không thể auth — state=\(stateMachine.state.displayText) | peripheral=\(activeContext?.peripheral.state.rawValue ?? -1)"))
            // Fallback: connect lại từ đầu
            connect()
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY→AUTH] User bấm kết nối → auth ngay"))
        standbyTimer?.invalidate()
        standbyTimer = nil
        isAuthenticating = true
        executeAuthProtocol(ctx: ctx, pin: pin)
    }
    
    /// Chuyển từ active/standby → nearby (user bật chế độ gần xe)
    func activateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY] User kích hoạt chế độ 'Đang ở gần' từ state=\(stateMachine.state.displayText)"))
        preferences.nearbyModeEnabled = true
        
        // Nếu đang active → hạ xuống nearby (giữ BLE, bỏ polling)
        if stateMachine.state == .active || stateMachine.state == .standby {
            // §3.4 (P4): services sống theo SESSION, không theo mode —
            // KHÔNG nil dispatcher/engine khi chỉ hạ mode; session vẫn connected.
            // Bug cũ: nil ở đây → quay lại standby/auth mà dispatcher mất → UI chết.
            pollingEngine?.stopPolling()
            isSessionAutoSuspended = false
            isAuthenticating = false
            stateMachine.transition(to: .nearby)
            
            // Poll RSSI nhẹ
            if let ctx = activeContext {
                standbyTimer?.invalidate()
                standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak ctx] _ in
                    ctx?.peripheral.readRSSI()
                }
            }
        }
    }
    
    /// Tắt chế độ gần xe → auth ngay nếu có kết nối
    func deactivateNearbyMode() {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[NEARBY] User tắt chế độ 'Đang ở gần' → auth ngay nếu có BLE"))
        preferences.nearbyModeEnabled = false
        connectFromNearby()
    }
    
    private func downgradeToStandby(force: Bool = false) {
        guard !isDowngrading else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DOWNGRADE] Bỏ qua — isDowngrading=true (chống chồng chéo)"))
            return
        }
        
        let activeDuration = lastActiveTime.map { Date().timeIntervalSince($0) }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DOWNGRADE] force=\(force) | smState=\(stateMachine.state.displayText) | RSSI=\(currentRSSI) | threshold=\(preferences.rssiThreshold) | activeDuration=\(String(format: "%.1f", activeDuration ?? -1))s | isBackground=\(isAppInBackground) | autoSuspended=\(isSessionAutoSuspended)"))
        
        if !force {
            guard let lastActive = self.lastActiveTime,
                  Date().timeIntervalSince(lastActive) > 5.0 else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[DOWNGRADE] Bỏ qua — cooldown 5s chưa hết (\(String(format: "%.1f", activeDuration ?? 0))s)"))
                return
            }
        }
        
        isDowngrading = true
        defer { isDowngrading = false }
        
        pollingEngine?.stopPolling()
        isAuthenticating = false
        
        NotificationManager.shared.sendNotification(
            title: "Trạng thái kết nối",
            body: "Đang chờ kết nối lại với xe",
            identifier: "DowngradeToStandby"
        )
        
        if isAppInBackground {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[DOWNGRADE/BG] Background path → pending connect | peripheral=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1)"))
            if let ctx = activeContext, let central = centralManager {
                let peripheral = ctx.peripheral
                central.cancelPeripheralConnection(peripheral)
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
                stateMachine.transition(to: .scanning)
                isPendingConnectWaiting = true // §UX: pending connect — chờ xe vào tầm sóng
                central.connect(peripheral, options: Self.connectOptions())
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[DOWNGRADE/BG] Không có activeContext → fallback connect()"))
                connect()
            }
            return
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Hạ kết nối về Standby (Xoá phiên xác thực nội bộ)..."))
            
        if let ctx = activeContext {
            // Huỷ phiên xác thực bằng cách ghi rác
            let authenticator = BLEAuthenticator(context: ctx, pin: preferences.savedPin ?? "", isKnownDevice: true)
            Task {
                try? await authenticator.invalidateSession()
            }
            
            stateMachine.transition(to: .standby)
            DispatchQueue.main.async {
                self.standbyTimer?.invalidate()
                self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak ctx] _ in
                    ctx?.peripheral.readRSSI()
                }
            }
        } else {
            connect()
        }
    }
}

extension DatBikeCore: CBCentralManagerDelegate {
    
    #if !NOASK
    /// State Restoration: iOS khôi phục peripheral khi app bị kill + relaunch
    /// (chỉ có nghĩa với biến thể có UIBackgroundModes bluetooth-central)
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripheralCount = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RESTORE] willRestoreState | peripheralCount=\(peripheralCount) | centralState=\(central.state.rawValue)"))
        // LỚP 3: đang tạm dừng → ngắt peripheral iOS restore, KHÔNG thiết lập lại phiên.
        if isUserPaused {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[RESTORE] isUserPaused → ngắt peripheral được restore, giữ idle"))
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
                peripherals.forEach { central.cancelPeripheralConnection($0) }
            }
            return
        }
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            guard let savedUUID = preferences.savedPeripheralUUID.flatMap(UUID.init(uuidString:)),
                  let restored = peripherals.first(where: { $0.identifier == savedUUID }) else {
                peripherals.forEach { central.cancelPeripheralConnection($0) }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[RESTORE] Không có peripheral khớp xe đã lưu → hủy restore lạ"))
                return
            }
            peripherals.filter { $0 !== restored }.forEach { central.cancelPeripheralConnection($0) }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[RESTORE] Peripheral: name=\(restored.name ?? "nil") | uuid=\(restored.identifier.uuidString.prefix(8)) | state=\(restored.state.rawValue) | services=\(restored.services?.count ?? 0)"))
            
            // ═══ ADOPT cả .connected LẪN .connecting ═══
            // .connecting chính là pending connect do iOS quản lý — cơ chế đánh thức
            // app khi xe vào tầm sóng sau khi hệ thống jettison app (memory pressure).
            // Cancel nó = tự tay phá регистра wake-up → "lại gần xe lúc được lúc không".
            // Nếu link keys mismatch, didFailToConnect MIC handler sẽ dọn.
            if restored.state == .connected || restored.state == .connecting {
                // §3.10 (P4): cold-init với manualOnly → KHÔNG tự động nối lại phiên.
                if preferences.isManualOnly {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RESTORE] iOS restore peripheral (state=\(restored.state.rawValue)) nhưng intent=\(preferences.connectionIntent.rawValue) → nhắt connection, về idle"))
                    central.cancelPeripheralConnection(restored)
                    stateMachine.transition(to: .idle)
                } else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "Adopt peripheral restore (state=\(restored.state.rawValue)): \(restored.name ?? "unknown") — giữ pending connect của hệ thống"))
                    restored.delegate = self
                    let ctx = BLEConnectionContext(peripheral: restored)
                    activeContext = ctx
                    commandDispatcher = BLECommandDispatcher(context: ctx)
                    pollingEngine = BLEPollingEngine(context: ctx)
                    isPendingConnectWaiting = restored.state == .connecting
                    stateMachine.transition(to: .connecting)
                }
            } else {
                // .disconnected: không còn pending connect nào để adopt.
                // KHÔNG set forceFullScan — để connect() retrieve + đăng ký lại
                // pending connect (cơ chế wake-up chuẩn của iOS).
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Peripheral restore ở state=\(restored.state.rawValue) → connect() sẽ đăng ký lại pending connect"))
            }
        }
    }
    #endif // !NOASK — State Restoration

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[CB_STATE] centralManagerDidUpdateState=\(central.state.rawValue) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | btPowerOff=\(btWasPoweredOff) | pendingASK=\(pendingASKUUID?.uuidString.prefix(8).description ?? "nil") | savedPin=\(preferences.savedPin != nil)"))
        switch central.state {
        case .poweredOn:
            hasSeenPoweredOnInThisProcess = true // F3 (5.2.0): đã thấy ON trong process
            // ═══ PHÁT HIỆN power-cycle: nếu BT vừa tắt → xóa sạch context cũ ═══
            if btWasPoweredOff {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "BT poweredOn sau power-cycle → xóa context cũ, chuẩn bị scan mới"))
                // Hủy kết nối cũ nếu có — buộc iOS xóa encryption cache
                if let ctx = activeContext {
                    central.cancelPeripheralConnection(ctx.peripheral)
                }
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
                isAuthenticating = false
                // btWasPoweredOff vẫn giữ = true để connect() biết phải scan
                connect() // Bắt buộc kết nối lại sau power-cycle để tránh kẹt trạng thái
                return
            }
            
            // ═══ Kiểm tra activeContext từ willRestoreState (dùng peripheral.state, KHÔNG dùng stateMachine.state) ═══
            // stateMachine.state có thể bị override về .scanning bởi connect() nếu willRestoreState chạy
            // synchronously bên trong CBCentralManager constructor và connect() chưa biết.
            // peripheral.state là sự thật vật lý từ iOS — đáng tin hơn stateMachine.
            // Pending connect restore: hệ thống đang theo dõi yêu cầu connect.
            // Đừng connect() lại — churn context vô nghĩa; didConnect sẽ tự fire.
            if let ctx = activeContext, ctx.peripheral.state == .connecting {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CB_STATE] Context đang .connecting (pending connect của iOS) → giữ nguyên, chờ didConnect"))
                if case .connecting = stateMachine.state {} else {
                    stateMachine.transition(to: .connecting)
                }
                return
            }

            if let ctx = activeContext, ctx.peripheral.state == .connected {
                if case .connecting = stateMachine.state {} else {
                    stateMachine.transition(to: .connecting)
                }
                
                // ASK-AWARE: Tận dụng cached GATT nếu có
                if let cachedServices = ctx.peripheral.services, !cachedServices.isEmpty {
                    var missingChars = false
                    for service in cachedServices {
                        if let chars = service.characteristics, !chars.isEmpty {
                            for char in chars { ctx.register(characteristic: char) }
                        } else {
                            missingChars = true
                            ctx.peripheral.discoverCharacteristics(nil, for: service)
                        }
                    }
                    
                    if missingChars {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RESTORE] Có cached services nhưng thiếu chars → đang discover chars..."))
                        startConnectingTimeout()
                    } else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RESTORE] GATT cached đầy đủ (services + chars) → skip discover"))
                        tryRestoreActiveSession(ctx: ctx)
                    }
                } else {
                    // Không có cache → discover từ đầu
                    ctx.peripheral.discoverServices(BLEService.allServices)
                    startConnectingTimeout()
                }
                return
            }
            
            #if !NOASK
            if let uuid = pendingASKUUID {
                pendingASKUUID = nil
                connect(to: uuid)
                return
            }
            #endif
            
            // Xử lý thông minh: Cứ có sóng lại, chưa ổn định và đã từng pair -> reconnect cưỡng chế
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CB_ROUTE] isConnected=\(stateMachine.state.isConnected) | pin=\(preferences.savedPin != nil) | uuid=\(preferences.savedPeripheralUUID?.prefix(8).description ?? "nil") | smState=\(stateMachine.state.displayText)"))
            if !stateMachine.state.isConnected && preferences.savedPin != nil && preferences.savedPeripheralUUID != nil {
                connect()
            } else if stateMachine.state == .scanning {
                connect()
            } else if preferences.savedPeripheralUUID == nil {
                // ── DIAGNOSTIC SCAN: chưa ghép xe hoặc accessory bị gỡ → quét nền để ghi log ──
                // didDiscover sẽ fire cho mọi thiết bị BLE, log [SCAN] hiện trong Cài đặt > Log.
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[DIAG] Không có xe ghép đôi (UUID=nil, pin=\(preferences.savedPin != nil ? "có" : "nil")) — bắt đầu quét BLE chẩn đoán (10s)"))
                stateMachine.transition(to: .scanning)
                central.scanForPeripherals(withServices: nil, options: [
                    CBCentralManagerScanOptionAllowDuplicatesKey: false
                ])
                // Tự dừng sau 10s để tiết kiệm pin
                bleQueue.asyncAfter(deadline: .now() + 10) { [weak self, central] in
                    guard let self, central === self.centralManager, self.preferences.savedPeripheralUUID == nil else { return }
                    self.centralManager?.stopScan()
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[DIAG] Kết thúc quét BLE chẩn đoán"))
                }
            }
        case .poweredOff:
            if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
                // Trên iOS 18 dùng ASK, .poweredOff là trạng thái bình thường nếu hệ thống chưa thấy xe.
                // Ta chỉ việc đứng yên, đừng báo lỗi, ASKManager.onSessionActivated sẽ lo việc kết nối!
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "iOS 18 ASK: central = .poweredOff → Chờ ASKManager đánh thức, không báo lỗi."))
                return
            }
            isPendingConnectWaiting = false
            // ═══ F3 (5.2.0): phân biệt BT off THẬT với transient 4→5 lúc cold-launch ═══
            // iOS 18 + ASK hay báo .poweredOff mili-giây ở callback đầu của CBCentralManager
            // mới (log 18-19/09: 5/6 lần "BT power-cycle" là giả → app tự ép mình vào
            // ladder scan ~42s + skip cache ở MỌI cold launch dù xe sẵn sàng).
            if hasSeenPoweredOnInThisProcess {
                // Off XẢY RA GIỮA PHIÊN (đã thấy ON trước đó) → power-cycle thật
                btWasPoweredOff = true
                if stateMachine.state != .idle {
                    cancelScanTimer()
                    // Delay 3.0s tránh lỗi ảo khi iOS đang khởi động lại Bluetooth daemon
                    bleQueue.asyncAfter(deadline: .now() + 3.0) { [weak self, central] in
                        guard let self = self, central === self.centralManager else { return }
                        if self.centralManager.state == .poweredOff && self.stateMachine.state != .idle {
                            self.stateMachine.transition(to: .error("Bluetooth đang bị tắt. Hãy bật Bluetooth."))
                        } else if self.centralManager.state == .poweredOn && self.stateMachine.state == .scanning {
                            self.connect()
                        }
                    }
                }
            } else {
                // Cold-launch: chờ 1.5s xác nhận — KHÔNG phá scan/connect đang chạy.
                // Transient sẽ tự chuyển .poweredOn sau vài ms và luồng cũ tiếp tục.
                bleQueue.asyncAfter(deadline: .now() + 1.5) { [weak self, central] in
                    guard let self = self, central === self.centralManager else { return }
                    guard central.state == .poweredOff else { return } // transient — bỏ qua
                    // Off thật ngay sau cold launch → đánh dấu cho lần poweredOn kế tiếp
                    self.btWasPoweredOff = true
                    if self.stateMachine.state != .idle {
                        self.stateMachine.transition(to: .error("Bluetooth đang bị tắt. Hãy bật Bluetooth."))
                    }
                }
            }
        case .unauthorized:
            if BLEFeatureFlags.useASK, #available(iOS 18.0, *) {
                // Tương tự, .unauthorized cũng có thể là do ASK chưa kích hoạt
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "iOS 18 ASK: central = .unauthorized → Chờ ASKManager."))
                return
            }
            isPendingConnectWaiting = false
            if stateMachine.state != .idle {
                stateMachine.transition(to: .error("Ứng dụng chưa được cấp quyền Bluetooth."))
            }
        case .unsupported:
            isPendingConnectWaiting = false
            // ═══ F8 (5.2.0): .unsupported SAU khi đã từng .poweredOn = glitch ═══
            // bluetoothd trả state=2 cho manager vừa tái tạo (log 19/09 10:52:03
            // và 12:11:03: CB_RECYCLE xong dính .unsupported → app báo "không hỗ
            // trợ Bluetooth" và CHẾT FROZEN 3.5 GIỜ). iPhone thật không thể mất
            // capability BLE giữa chừng → tái tạo manager sau 2.5s, không error.
            if hasSeenPoweredOnInThisProcess {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[CB_STATE] .unsupported sau khi đã .poweredOn (glitch bluetoothd sau recycle) → tái tạo manager sau 2.5s thay vì báo lỗi chết"))
                stateMachine.transition(to: .scanning)
                bleQueue.asyncAfter(deadline: .now() + 2.5) { [weak self, central] in
                    guard let self, central === self.centralManager else { return }
                    guard self.centralManager?.state == .unsupported || self.centralManager?.state == .resetting else { return }
                    self.recycleCentralManager(reason: ".unsupported glitch sau khi đã poweredOn")
                }
                return
            }
            if stateMachine.state != .idle {
                stateMachine.transition(to: .error("Thiết bị không hỗ trợ Bluetooth."))
            }
        default:
            break
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // Ưu tiên tên từ luồng quảng bá (advName) vì peripheral.name thường bị iOS cache rất lâu (thậm chí là sau khi xe đã đổi tên)
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let deviceName = advName ?? peripheral.name ?? "Dat Bike"
        
        // Cache tên quảng bá mới nhất để UI hiển thị ngay (trước khi GATT đọc xong)
        if let advName, !advName.isEmpty {
            DispatchQueue.main.async {
                self.lastAdvertisedName = advName
            }
        }

        let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber
        let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let overflowSvcs = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
        
        // ── LOG CHI TIẾT QUÉT BLE (xem trong Cài đặt > Log) ──
        var sd = "[SCAN] \(deviceName) | uuid=\(peripheral.identifier.uuidString.prefix(8))"
        sd += " | RSSI=\(RSSI.intValue)dBm | conn=\(connectable ?? true)"
        sd += " | advName=\(advName ?? "nil") | pName=\(peripheral.name ?? "nil")"
        sd += " | svc=[\(advServices.map { $0.uuidString.prefix(8) }.joined(separator: ","))]"
        if !overflowSvcs.isEmpty { sd += " | overflow=[\(overflowSvcs.map { $0.uuidString.prefix(8) }.joined(separator: ","))]" }
        if let txPower { sd += " | tx=\(txPower)dBm" }
        if let mfgData { sd += " | mfg=\(mfgData.hexString.prefix(40))" }
        if let serviceData, !serviceData.isEmpty {
            sd += " | svcData=[\(serviceData.map { "\($0.key.uuidString.prefix(8)):\($0.value.hexString.prefix(16))" }.joined(separator: ","))]"
        }
        sd += " | sm=\(stateMachine.state.displayText) | bg=\(isAppInBackground)"
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: sd))
        
        // ═══ GUARD: Đã đang trong quá trình kết nối → bỏ qua callback trùng ═══
        // Phòng trường hợp 2 xe DatBike gần nhau gửi 2 callback liên tiếp vào queue CoreBluetooth
        // → connectPeripheral() bị gọi 2 lần → activeContext bị ghi đè → cả 2 kết nối fail
        if activeContext != nil, case .connecting = stateMachine.state {
            return
        }
        
        // Đã pair trước đó (có savedPin) → auto-connect luôn, không cần chọn
        if preferences.savedPin != nil {
            if isAppInBackground && preferences.connectOnlyWhenNear {
                // Background + chế độ "Chỉ kết nối khi gần" BẬT:
                // Bỏ qua sóng yếu để tránh kết nối từ xa → timer standby bị iOS đóng băng → không bao giờ xác thực được.
                // KHÔNG áp dụng khi connectOnlyWhenNear=false: auth đi theo fast path (không timer),
                // nên an toàn kết nối bất kể khoảng cách.
                if Double(RSSI.intValue) < preferences.rssiThreshold {
                    return
                }
            }
            
            // ═══ UUID FILTER: Khi có 2 xe DatBike gần nhau, chỉ kết nối xe đã ghép đôi ═══
            // Nếu UUID khớp → connect ngay
            if let savedUUIDStr = preferences.savedPeripheralUUID {
                if peripheral.identifier.uuidString == savedUUIDStr {
                    cancelScanTimer()
                    central.stopScan()
                    connectPeripheral(peripheral, central: central)
                    return
                } else {
                    // ═══ RPA DETECTION LOG ═══
                    // Nếu quét ra Dat Bike nhưng UUID khác với UUID đã lưu, rất có thể là do MAC quay vòng (RPA).
                    // Dedupe 1 lần/UUID/lượt quét: field log 8 (bãi xe ~15 Dat Bike,
                    // allowDupes=true) spam 521 warning lặp lại trong 4 giây.
                    if !rpaWarnedUUIDs.contains(peripheral.identifier) {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "[RPA-DETECTED] Phát hiện xe nhưng UUID khác (Cũ: \(savedUUIDStr.prefix(8)) | Mới: \(peripheral.identifier.uuidString.prefix(8))). Đây có thể là MAC quay vòng hoặc xe của người khác. iOS sẽ không tự ghép vào Pending Connect!"))
                    }
                }
            }

            // UUID không khớp → tiếp tục scan (chờ đúng xe)
            // Nếu không có savedPeripheralUUID (user cũ chưa có), dùng xe đầu tiên tìm thấy
            if preferences.savedPeripheralUUID == nil {
                cancelScanTimer()
                central.stopScan()
                connectPeripheral(peripheral, central: central)
                return
            }

            // Có savedUUID nhưng xe này không phải → bỏ qua (log 1 lần/UUID/lượt quét)
            if !rpaWarnedUUIDs.contains(peripheral.identifier) {
                rpaWarnedUUIDs.insert(peripheral.identifier)
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Tìm thấy xe DatBike khác (\(peripheral.identifier.uuidString.prefix(8))) — bỏ qua, đang chờ đúng xe"))
            }
            return
        }
        
        // Chưa pair → gom vào danh sách cho user chọn.
        // P1.5: vì FG scan giờ unfiltered, phải lọc nhiễu: chỉ nhận thiết bị
        // mang tên kiểu Dat Bike hoặc advertise đúng service UUID của xe.
        // (advServices đã khai báo ở khối log phía trên)
        let looksLikeBike = deviceName.lowercased().contains("dat")
            || deviceName.lowercased().contains("weaver")
            || deviceName.lowercased().contains("quantum")
            || !Set(advServices.map { $0.uuidString }).isDisjoint(with: Set(BLEService.scanUUIDs.map { $0.uuidString }))
            
        // Đã cập nhật scanUUIDs trong BLEConstants để chứa đủ các UUID chuẩn
        if !looksLikeBike {
            // Log chi tiết thiết bị bị loại bỏ để phân tích tại sao xe không hiện lên
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                message: "[DISCOVER-FILTERED] Bỏ qua thiết bị: name=\(deviceName) | uuid=\(peripheral.identifier.uuidString.prefix(8)) | services=\(advServices.map { $0.uuidString }.joined(separator: ","))"))
            return 
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[DISCOVER-NEW-BIKE] Đã nhận diện xe ghép mới: name=\(deviceName) | uuid=\(peripheral.identifier.uuidString.prefix(8)) | RSSI=\(RSSI.intValue) | services=\(advServices.map { $0.uuidString }.joined(separator: ",")) | serial=\(BLEService.serial(fromManufacturerData: mfgData) ?? "nil")"))

        let bike = DiscoveredBike(
            peripheral: peripheral,
            name: deviceName,
            rssi: RSSI.intValue,
            serial: BLEService.serial(fromManufacturerData: mfgData)
        )
        
        DispatchQueue.main.async {
            if let idx = self.discoveredBikes.firstIndex(where: { $0.id == bike.id }) {
                self.discoveredBikes[idx] = bike
            } else {
                self.discoveredBikes.append(bike)
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let currentCentral = centralManager, central !== currentCentral {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // A late callback from a cancelled request must not revive an explicitly
        // disconnected/unpaired bike or replace the session for another bike.
        if isUserPaused || (activeContext == nil && !isPendingConnectWaiting) {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        if let current = activeContext, current.peripheral !== peripheral {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        isPendingConnectWaiting = false // §UX: đã kết nối thật — hết chờ
        cycleDidConnectAt = Date()
        cycleGattReadyAt = nil // stamp của phiên trước — giữ lại sẽ cho dc→gatt ÂM
        // khi pending connect hoàn thành muộn không qua [CKPT request] mới (field log 8, 19:50)
        lastRSSIBandAboveThreshold = nil // phiên mới — chưa có band để so
        let reqToDc = cycleRequestedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
            message: "[CKPT did-connect] sid=\(activeContext?.sessionID.uuidString.prefix(6) ?? "new") | req→dc=\(reqToDc.map { String($0) } ?? "?")ms | bg=\(isAppInBackground)"))
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
            message: "[DID_CONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(peripheral.state.rawValue) | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext == nil ? "nil" : "có") | ctxMatch=\(activeContext?.peripheral === peripheral) | isBackground=\(isAppInBackground)"))
        btWasPoweredOff = false  // ═══ ĐÂY LÀ NƠI DUY NHẤT RESET btWasPoweredOff ═══
        forceFullScan = false
        micRetryCount = 0
        btPowerCycleScanRounds = 0  // Reset scan loop counter khi connect thành công
        consecutiveStandbyCount = 0  // Reset standby drain counter khi connect thành công
        isPendingCleanReconnect = false // C2 (5.1.0): đã nối được rồi — bỏ ý định clean-reconnect
        cancelCleanReconnectDeadline()
        
        // ═══ CANCEL TIMERS: tránh double-scan từ fallback timer hoặc phantom timeout ═══
        cancelConnectingTimeout()
        disconnectFallbackTimer?.cancel()
        disconnectFallbackTimer = nil
        // ═══ F9 (5.2.0): đã NỐI THẬT → mọi retry/scan cũ của chuỗi fail trước đó
        // vô nghĩa. Bằng chứng log 19/09 15:37: MIC failure #1 hẹn retry scan +2s,
        // pending của F1 nối TRƯỚC (15:37:20.783), auth xong 15:37:21.5 — timer
        // fire 15:37:22.1 kéo app ra khỏi Active Session về .scanning dù link vẫn
        // sống ("thành công xong lại về màn hình kết nối"). bindRetryScheduler
        // không hủy cùng-xe nên phải hủy tay. Tương tự 15:58:09: scanTimer hết hạn
        // sau didConnect arm pending trùng.
        cancelScanTimer()
        retryScheduler.cancelAll(reason: "didConnect — phiên mới đã sống")
        
        // Every physical link is a new logical session, even if CoreBluetooth
        // reconnects the same CBPeripheral. Old GATT tasks and command decisions
        // must not carry over to this link.
        activeContext?.clearState()
        let ctx = BLEConnectionContext(peripheral: peripheral)
        activeContext = ctx
        peripheral.delegate = self
        commandDispatcher = BLECommandDispatcher(context: ctx)
        pollingEngine = BLEPollingEngine(context: ctx)
        isAuthenticating = false
        stateMachine.transition(to: .connecting)
        DispatchQueue.main.async {
            guard self.activeContext === ctx else { return }
            self.lockStateSessionID = nil
            self.currentLockState = .unknown(Data())
        }
        
        // Xin iOS cấp cho 30s CPU để xử lý Auto-turn-on và các tác vụ khác khi app lỡ bị rơi vào trạng thái ngủ đông
        extendBackgroundExecutionTime()

        // §3.2: mỗi didConnect là một discovering attempt mới
        discoveryRetryCount = 0
        bindRetryScheduler(reason: "didConnect")

        // §3.2: watchdog PHẢI chạy trong suốt quá trình GATT discovery —
        // trước đây không có watchdog nào sau didConnect → xe im lặng = kẹt .connecting vĩnh viễn.
        startDiscoveryWatchdog()

        peripheral.discoverServices(BLEService.allServices)
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if let currentCentral = centralManager, central !== currentCentral { return }
        if let ctx = activeContext, ctx.peripheral !== peripheral { return }
        if activeContext == nil && !isPendingConnectWaiting { return }
        if peripheral.state == .connected { return }
        isPendingConnectWaiting = false // §UX: pending đã fail
        cancelConnectingTimeout()
        cancelDiscoveryWatchdog()
        cancelScanTimer()
        central.stopScan()
        let errorMsg = error?.localizedDescription ?? "unknown"
        let nsError = error as NSError?
        PersistentLogger.shared.append(BLELogEntry(
            timestamp: Date(), level: .error,
            message: "[DID_FAIL_CONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | error=\(errorMsg) | code=\(nsError?.code ?? -1) | domain=\(nsError?.domain ?? "nil") | micRetry=\(micRetryCount)/\(maxMicRetries) | scanRetry=\(scanRetryCount)/\(maxScanRetries)"
        ))
        logCycle("fail", extra: "stage=connect code=\(nsError?.code ?? -1) error=\"\(errorMsg)\"")

        // LỚP 3: đang tạm dừng → không retry/reconnect.
        if isUserPaused {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_FAIL_CONNECT] isUserPaused → không retry, giữ idle"))
            stateMachine.transition(to: .idle)
            return
        }

        activeContext = nil
        commandDispatcher = nil
        pollingEngine = nil
        isAuthenticating = false
        standbyTimer?.invalidate()
        standbyTimer = nil

        // MIC failure hoặc "Failed to encrypt" = encryption cache lệch
        let isMICFailure = errorMsg.contains("MIC failure")
            || (error as NSError?)?.code == 31
        let isEncryptionFailure = errorMsg.contains("Failed to encrypt")
        // Connection timeout (code 6) cũng có thể do stale encryption
        let isConnectionTimeout = errorMsg.contains("timed out") || (error as NSError?)?.code == 6
        
        // Error 14: Peer removed pairing
        if let cbError = error as? CBError, cbError.code == .peerRemovedPairingInformation {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Xe đã xóa bonding (code 14). Đang tự động gỡ iOS Bluetooth bằng ASKManager và yêu cầu ghép đôi lại..."))
            
            // Đã tắt ASK: Không remove accessory qua ASKManager
            
            preferences.savedPin = nil
            preferences.savedPeripheralUUID = nil
            micRetryCount = 0
            btWasPoweredOff = true
            forceFullScan = true
            
            if #available(iOS 18.0, *) {
                // F6: KHÔNG auto-showPicker (phải xuất phát từ user gesture —
                // chuẩn ASK + có thể fail khi app background). Chuyển state lỗi
                // hướng dẫn; nút "Thêm xe" sẽ hiện vì đã clear UUID ở trên.
                stateMachine.transition(to: .error(
                    "Xe đã xóa bonding (code 14).\n" +
                    "App đã tự động dọn bonding cũ trong hệ thống.\n" +
                    "Vui lòng bấm nút 'Thêm xe' để ghép đôi lại."
                ))
            } else {
                stateMachine.transition(to: .error(
                    "Đã phát hiện thiết bị khác chiếm kết nối xe.\n" +
                    "Bạn dùng phiên bản iOS cũ nên App không thể tự động gỡ lỗi. Vui lòng:\n" +
                    "1. Vào Cài đặt → Bluetooth → chọn chữ (i) cạnh xe Ngựa sắt → Quên thiết bị này\n" +
                    "2. Quay lại App để kết nối."
                ))
            }
            return
        }
        
        if isMICFailure || isEncryptionFailure || isConnectionTimeout {
            // Giữ timestamp lần fail TRƯỚC — dùng cho cluster-detect ở dưới.
            // (Bug cũ: so với lastMicFailureTime SAU khi đã ghi đè = luôn "cluster",
            // progressive backoff thành dead code — field log 8, phiên 07:43 20/10.)
            let previousFailureTime = lastMicFailureTime
            // TTL: Reset counter nếu lần MIC failure cuối đã quá 60s
            if let lastTime = previousFailureTime, Date().timeIntervalSince(lastTime) > micRetryTTL {
                micRetryCount = 0
            }
            lastMicFailureTime = Date()
            micRetryCount += 1
            let failureType = isMICFailure ? "MIC failure" : isEncryptionFailure ? "Encryption failure" : "Connection timeout"

            // §CB_RECYCLE: đếm rỉ rả — KHÔNG TTL. Bằng chứng TN 11/09: các lần MIC
            // cách nhau >60s khiến micRetryCount bị TTL reset về 0 mãi mãi →
            // không bao giờ chạm maxMicRetries → loop vô hạn cả buổi sáng.
            // Mỗi 5 fail MỚI kể từ lần recycle trước → recycle manager. (Field log 8,
            // 07:43 20/10: điều kiện cũ `>= 5` nổ recycle cho MỌI fail từ lần 5 →
            // 3 CB_RECYCLE trong 1 giây, đốt sạch quota maxCbRecyclesPerSession.)
            if isMICFailure || isEncryptionFailure {
                micFailureSessionCount += 1
                if micFailureSessionCount - micFailureCountAtLastRecycle >= 5 {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                        message: "\(failureType) rỉ rả \(micFailureSessionCount) lần/phiên (ladder micRetry bị TTL reset) → CB_RECYCLE"))
                    micRetryCount = 0
                    micFailureCountAtLastRecycle = micFailureSessionCount
                    recycleCentralManager(reason: "\(failureType) rỉ rả \(micFailureSessionCount) lần/phiên")
                    return
                }
            }

            // Giới hạn số lần retry MIC failure để tránh loop vô hạn
            let recycleAfter = (isMICFailure || isEncryptionFailure) ? 2 : maxMicRetries + 1
            if micRetryCount >= recycleAfter {
                PersistentLogger.shared.append(BLELogEntry(
                    timestamp: Date(), level: .error,
                    message: "\(failureType) liên tiếp \(micRetryCount) lần → CB_RECYCLE, thử phục hồi link BLE"
                ))
                micRetryCount = 0
                micFailureCountAtLastRecycle = micFailureSessionCount
                recycleCentralManager(reason: "\(failureType) hết quota \(maxMicRetries) lượt")
                return
            }

            // Progressive backoff: 1s → 2s → 3s → 4s → 5s
            // F5 (5.2.0): cluster delay 5s → 2s. Log 18-19/09 cho thấy MIC là cửa sổ
            // tạm sau biến cố link-churn: thử lại sau 2.5-18s là thành công (18/09
            // 17:19:56 fail → 17:20:14 success cùng đường). Chờ 5s chỉ kéo dài đau.
            let delay: Double
            if let lastTime = previousFailureTime, Date().timeIntervalSince(lastTime) < 10 {
                delay = 2.0  // MIC cluster detected
            } else {
                delay = Double(micRetryCount) * 1.0
            }
            PersistentLogger.shared.append(BLELogEntry(
                timestamp: Date(), level: .warning,
                message: "\(failureType) (lần \(micRetryCount)/\(maxMicRetries)) → delay \(String(format: "%.0f", delay))s rồi scan mới"
            ))
            btWasPoweredOff = true
            forceFullScan = true
            pendingASKUUID = nil
            scanRetryCount = 0
            // F1: Nền cần một yêu cầu do iOS sở hữu để đánh thức khi xe trở lại.
            // Không chạy đồng thời pending connect và scan/retry cùng xe.
            // In the background, keep exactly one system-owned connection/scan
            // request so iOS can wake the app when the paired bike returns.
            // Do not arm pending and launch a second scan/retry chain: didDiscover
            // ignores bikes while the state machine is already connecting.
            var didArmBackgroundPending = false
            if isAppInBackground,
               let savedUUIDStr = preferences.savedPeripheralUUID,
               let savedUUID = UUID(uuidString: savedUUIDStr),
               central.state == .poweredOn,
               activeContext == nil {
                // Rate-limit 10s so a MIC cluster cannot create a rapid connect loop.
                let recentlyArmed = lastFailurePendingArmAt.map { Date().timeIntervalSince($0) < 10 } ?? false
                if recentlyArmed {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[F1] Pending vừa được arm <10s — dùng filtered background scan cho \(failureType)"))
                } else {
                    let known = central.retrievePeripherals(withIdentifiers: [savedUUID])
                    if let p = known.first, p.state == .disconnected {
                        lastFailurePendingArmAt = Date()
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[F1] Arm pending connect nền cho \(failureType) — giữ wake-up qua suspend"))
                        connectPeripheral(p, central: central, isPendingConnect: true)
                        didArmBackgroundPending = true
                    }
                }
            }
            if didArmBackgroundPending {
                stopBackgroundExecutionTime()
                return
            }
            if isAppInBackground, let central = centralManager, central.state == .poweredOn {
                startScanWithTimeout(central: central)
                return
            }
            stateMachine.transition(to: .scanning)
            if let central = self.centralManager, central.state == .poweredOn {
                // §3.7: MIC handler NHẬN QUYỀN retry → void PhantomGuard/standby-drain;
                // delay qua RetryScheduler — pause-safe, chết khi đổi session.
                self.retryScheduler.cancelGroups(["phantom-guard", "standby-drain", "disconnecting-retry"], reason: "\(failureType) nhận quyền retry")
                self.retryScheduler.schedule(label: "\(failureType) #\(self.micRetryCount)", group: "mic-retry", delay: delay) { [weak self] in
                    guard let self, self.centralManager?.state == .poweredOn else { return }
                    guard !self.isUserPaused else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[RETRY] \(failureType) retry bị chặn vì đang PAUSE"))
                        return
                    }
                    self.startScanWithTimeout(central: central)
                }
            }
        } else if scanRetryCount < maxScanRetries {
            scanRetryCount += 1
            // §3.7: qua RetryScheduler
            self.retryScheduler.schedule(label: "fail-connect-scan-retry #\(self.scanRetryCount)", group: "fail-connect-retry", delay: 0.5) { [weak self] in
                guard let self, let central = self.centralManager, central.state == .poweredOn else { return }
                guard !self.isUserPaused else { return }
                self.startScanWithTimeout(central: central)
            }
        } else {
            // Hết quota retry scan → pending connect thay vì chết cứng
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Hết quota retry — chuyển sang pending connect nền"))
            stateMachine.transition(to: .scanning)
            isPendingConnectWaiting = true // §UX: pending connect
            central.connect(peripheral, options: Self.connectOptions())
        }
    }
    
    /// F7 (5.2.0): xử lý disconnect qua `handleDisconnect` — dùng chung cho delegate
    /// iOS 17+ (có `isReconnecting`, bắt buộc khi bật AutoReconnect) và delegate
    /// iOS 5+ 3 tham số (biến thể NOASK / iOS 16). Khi hệ thống đang TỰ nối lại
    /// (isReconnecting=true): KHÔNG teardown, KHÔNG fallback timer (5s timer cũ
    /// gọi cancelPeripheralConnection = giết reconnect của hệ thống), chỉ dọn
    /// session cũ + canh watchdog như pending connect.
    private func handleDisconnect(_ central: CBCentralManager, peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        if let currentCentral = centralManager, central !== currentCentral { return }
        let errorMsg = error?.localizedDescription ?? "none"
        let nsError = error as NSError?
        // §LOG: dur = link sống bao lâu (tính từ didConnect của cycle).
        // Lưu ý F7-REV: `timestamp` của delegate là thời điểm DISCONNECT (bằng
        // chứng log 19/09: mọi giá trị "now - timestamp" = 3-9ms dù link sống
        // hàng phút) — chỉ log thêm để đối chiếu, không dùng làm duration.
        let linkDur = cycleDidConnectAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let dtMs = Int((CFAbsoluteTimeGetCurrent() - timestamp) * 1000)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[DID_DISCONNECT] name=\(peripheral.name ?? "nil") | uuid=\(peripheral.identifier.uuidString.prefix(8)) | error=\(errorMsg) | code=\(nsError?.code ?? 0) | smState=\(stateMachine.state.displayText) | isBackground=\(isAppInBackground) | wasConnected=\(stateMachine.state.isConnected) | autoSuspended=\(isSessionAutoSuspended) | isReconnecting=\(isReconnecting) | linkDur=\(linkDur.map { String($0) } ?? "?")ms | dt=\(dtMs)ms"))

        // ═══ §3.8 (P2): STALE DISCONNECT GUARD ═══
        // Event đến từ peripheral KHÔNG phải session hiện tại (didDisconnect trễ của
        // liên kết cũ) → tuyệt đối không được dọn polling/auth/state của phiên MỚI.
        // Chỉ log rồi thoát. (activeContext == nil vẫn xử lý bình thường — luồng
        // user disconnect() đã chủ động nil ctx trước khi cancel connection.)
        if let ctx = activeContext, ctx.peripheral !== peripheral {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_DISCONNECT] Event của peripheral cũ \(peripheral.identifier.uuidString.prefix(8)) ≠ session hiện tại \(ctx.peripheral.identifier.uuidString.prefix(8)) — bỏ qua, KHÔNG teardown phiên mới"))
            return
        }
        if let connectedAt = cycleDidConnectAt,
           timestamp < connectedAt.timeIntervalSinceReferenceDate {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[STALE_DISCONNECT] Sự kiện của link trước đến sau didConnect mới → bỏ qua"))
            return
        }
        if activeContext == nil, !isPendingConnectWaiting, !isPendingCleanReconnect {
            // An explicit disconnect/forget already released this link. A late
            // callback cannot revive it, regardless of its error code.
            if isReconnecting { central.cancelPeripheralConnection(peripheral) }
            return
        }
        // §LOG: kết chu kỳ bởi mất link (chỉ sau khi qua stale guard — event cũ
        // của peripheral khác không được tính vào cycle của phiên hiện tại)
        logCycle("disconnected", extra: "stage=\(stateMachine.state.displayText) code=\(nsError?.code ?? 0) isReconnecting=\(isReconnecting) linkDur=\(linkDur.map { String($0) } ?? "?")ms")

        // ═══ F7 (5.2.0): HỆ THỐNG đang tự nối lại (auto-reconnect) ═══
        // Link rơi bất ngờ (xe tắt máy/idleOff/mất sóng) — bluetoothd đã có sẵn
        // reconnect đang chờ xe phát sóng lại. App KHÔNG phải làm gì thêm:
        // • KHÔNG cancelPeripheralConnection (giết reconnect hệ thống)
        // • KHÔNG arm pending riêng (trùng lặp)
        // • KHÔNG fallback timer 5s (nó cancel peripheral!)
        // Chỉ dọn session cũ (polling/auth/standby), giữ context cho didConnect.
        // A MIC failure or removed bond must go through pairing recovery even
        // when iOS says it is reconnecting.
        let bondFailure = (error as? CBError)?.code == .peerRemovedPairingInformation
            || errorMsg.contains("MIC failure") || (nsError?.code ?? 0) == 31
        if isReconnecting && bondFailure {
            central.cancelPeripheralConnection(peripheral)
        }
        if isReconnecting && !bondFailure {
            // F7-REV: didDisconnect của lệnh CANCEL CHỦ ĐỘNG (watchdog F2 /
            // force-reconnect) — iOS có thể vẫn báo isReconnecting=true trên
            // manager mới. Đưa về flow clean-reconnect chuẩn, không nuốt.
            if isPendingCleanReconnect {
                isPendingCleanReconnect = false
                cancelCleanReconnectDeadline()
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CLEAN_RECONNECT] didDisconnect (isReconnecting=true) sau cancel chủ động → connect() ngay"))
                pollingEngine?.stopPolling()
                isAuthenticating = false
                standbyTimer?.invalidate()
                standbyTimer = nil
                authTask?.cancel()
                authTask = nil
                cancelDiscoveryWatchdog()
                cancelConnectingTimeout()
                stateMachine.transition(to: .scanning)
                self.connect(userInitiated: true)
                return
            }
            // LỚP 3: user đang tạm dừng → hẳn reconnect của hệ thống, về idle
            if isUserPaused {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[AUTORECONNECT] isUserPaused → cancel reconnect hệ thống, giữ idle"))
                central.cancelPeripheralConnection(peripheral)
                pollingEngine?.stopPolling()
                standbyTimer?.invalidate()
                standbyTimer = nil
                authTask?.cancel()
                authTask = nil
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
                isPendingConnectWaiting = false
                stateMachine.transition(to: .idle)
                return
            }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[AUTORECONNECT] Hệ thống đang tự nối lại (code=\(nsError?.code ?? 0)) → giữ context, dọn session cũ, chờ didConnect từ hệ thống"))
            pollingEngine?.stopPolling()
            isAuthenticating = false
            isSessionAutoSuspended = false
            standbyTimer?.invalidate()
            standbyTimer = nil
            authTask?.cancel()
            authTask = nil
            cancelDiscoveryWatchdog()
            cancelConnectingTimeout()
            isPendingConnectWaiting = true // §UX: "Đang chờ lại gần xe"
            // BLEStateMachine chặn trực tiếp .active → .connecting (guard chống
            // reset phiên) → nhấc qua .scanning trước rồi mới vào .connecting
            if case .active = stateMachine.state {
                stateMachine.transition(to: .scanning)
            }
            stateMachine.transition(to: .connecting)
            if isAppInBackground { stopBackgroundExecutionTime() } // hệ thống sở hữu reconnect — cho app suspend
            return
        }

        // LỚP 3: đang tạm dừng → KHÔNG pending-connect. Chặn gốc rễ loop code=6.
        if isUserPaused {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_DISCONNECT] isUserPaused → không reconnect, giữ idle"))
            pollingEngine?.stopPolling()
            standbyTimer?.invalidate()
            standbyTimer = nil
            authTask?.cancel()
            authTask = nil
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            stateMachine.transition(to: .idle)
            return
        }


        // ═══ KHÔNG gọi stopBackgroundExecutionTime() ở đây ═══
        // BG task phải sống đến khi pending reconnect hoàn tất.
        // Nếu end ở đây → iOS suspend ngay → didConnect không fire → kẹt .scanning.
        // Sẽ end BG task ở cuối hàm, hoặc khi didConnect fire.
        
        pollingEngine?.stopPolling()
        isAuthenticating = false
        isSessionAutoSuspended = false
        standbyTimer?.invalidate()
        standbyTimer = nil
        authTask?.cancel()
        authTask = nil
        cancelDiscoveryWatchdog() // §3.2: link đã rớt — watchdog discovery vô nghĩa
        
        guard let error = error else {
            if isPendingCleanReconnect {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CLEAN_RECONNECT] Đã ngắt kết nối xong → thực hiện kết nối mới (force scan)"))
                isPendingCleanReconnect = false
                cancelCleanReconnectDeadline()
                connect(userInitiated: true)
                return
            }
            
            // User-initiated disconnect (hoặc lệnh reset nội bộ)
            // Lệnh cancelPeripheralConnection có thể trả về didDisconnect mất đến > 1s.
            // Nếu state đang tiến hành scan/connect mới, sự kiện này là "dội lại" từ quá khứ → KHÔNG NGẮT KẾT NỐI MỚI.
            if stateMachine.state == .idle {
                disconnect()
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Bỏ qua sự kiện ngắt kết nối không lỗi vì đang trong luồng mới (\(stateMachine.state.displayText))"))
                
                // ═══ FIX: AUTO-CONNECT SAU KHI RỜI XE THỜI GIAN NGẮN ═══
                // Nếu app đang ở BG và đã chuyển sang scanning (phát lệnh pending connect),
                // PHẢI end bg task để app suspend ngay.
                // Nếu không, bg task cũ chạy tiếp. Khi user quay lại nhanh (trong vòng 30s),
                // didConnect fire nhưng dùng thời gian CÒN LẠI của bg task cũ.
                // bg task cũ expire giữa chừng → iOS suspend app → kẹt auth.
                if isAppInBackground && stateMachine.state == .scanning && scanTimer == nil {
                    stopBackgroundExecutionTime()
                }
            }
            return
        }
        
        // C2 (5.1.0): didDisconnect kèm error (code 6/31 rất thường gặp) cũng phải clear
        // cờ clean-reconnect — 5.0.0 chỉ clear ở nhánh error==nil nên để lại cờ stale,
        // lần disconnect sạch kế tiếp tự connect() ngoài ý muốn của user.
        if isPendingCleanReconnect {
            isPendingCleanReconnect = false
            cancelCleanReconnectDeadline()
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[CLEAN_RECONNECT] didDisconnect kèm error (code=\(nsError?.code ?? 0)) → clear cờ (handler lỗi bên dưới tự lo reconnect)"))
        }

        // MIC failure từ didDisconnect (iOS có thể fire ở đây thay vì didFailToConnect)
        let isMICFailure = errorMsg.contains("MIC failure") || (nsError?.code ?? 0) == 31
        if isMICFailure {
            // Delegate lên cùng handler
            centralManager(central, didFailToConnect: peripheral, error: error)
            return
        }
        
        // Error 14: Peer removed pairing — xe đã xóa bond, cần ghép lại
        // C9 (5.1.0): CHỈ tin nhánh check chuẩn CBError — mệnh đề fallback
        // `(nsError?.code ?? 0) == 14` khớp mọi NSError domain có code 14, một
        // error lạ sẽ khiến app TỰ GỠ bond iOS (removeAccessory) và bắt user
        // ghép đôi lại oan. Nhánh didFailToConnect vốn đã chỉ dùng check chuẩn.
        let isCode14 = (error as? CBError)?.code == .peerRemovedPairingInformation
        if isCode14 {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Xe đã xóa bonding (code 14). Đang tự động gỡ iOS Bluetooth bằng ASKManager và yêu cầu ghép đôi lại..."))
            // Đã tắt ASK: Không remove accessory qua ASKManager
            preferences.savedPin = nil
            preferences.savedPeripheralUUID = nil
            activeContext = nil
            commandDispatcher = nil
            pollingEngine = nil
            isPendingConnectWaiting = false
            micRetryCount = 0
            btWasPoweredOff = true
            forceFullScan = true
            stateMachine.transition(to: .error(
                "Xe đã xóa kết nối BLE (code 14).\n" +
                "App đã tự động dọn bonding cũ trong hệ thống.\n" +
                "Vui lòng bấm nút 'Thêm xe' để ghép đôi lại."
            ))
            return
        }
        
        // ═══ Connection timeout (code 6) → invalidate encryption cache ═══
        // Sau disconnect bất ngờ (code 6), iOS có thể giữ stale encryption keys.
        // Dùng forceFullScan thay vì btWasPoweredOff để tránh scan loop vô tận.
        // forceFullScan: buộc scan mới (tránh MIC failure) nhưng KHÔNG kích hoạt
        //   infinite scan guard trong startScanWithTimeout() → an toàn hơn.
        // btWasPoweredOff: CHỈ dùng khi centralManagerDidUpdateState(.poweredOff) thật sự.
        let isConnectionTimeout = (nsError?.code ?? 0) == 6
        if isConnectionTimeout {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_DISCONNECT] Connection timeout (code=6) → invalidate encryption cache (forceFullScan=true)"))
            forceFullScan = true
        }
        
        // Disconnect thông thường → pending reconnect
        let wasConnected = stateMachine.state.isConnected || stateMachine.state == .standby
        stateMachine.transition(to: .scanning)
        
        if wasConnected && preferences.connectOnlyWhenNear {
            NotificationManager.shared.sendNotification(
                title: "Trạng thái kết nối",
                body: "Đang chờ kết nối lại với xe",
                identifier: "DowngradeToStandby"
            )
        }
        
        central.connect(peripheral, options: Self.connectOptions())
        isPendingConnectWaiting = true
        
        // ═══ BG + timeout + wasConnected: chỉ pending connect, bỏ fallback timer ═══
        // Khi app ở background + Active Session bị code=6, reconnect loop là vô nghĩa.
        // iOS pending connect sẽ tự fire khi xe quay lại gần.
        if isAppInBackground && isConnectionTimeout && wasConnected {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DID_DISCONNECT] BG + timeout + wasConnected → chỉ pending connect, bắt buộc suspend app (end bg task)"))
            // ═══ FIX: AUTO-CONNECT SAU KHI RỜI XE THỜI GIAN NGẮN ═══
            // Bắt buộc stop bgTask để app suspend. 
            // Nếu không, bgTask cũ tiếp tục sống. Nếu xe lại gần trong vòng 30s, didConnect fire
            // nhưng chỉ dùng thời gian CÒN LẠI của bgTask cũ → expire giữa chừng → fail auth.
            // Khi suspend, OS vẫn theo dõi pending connect và sẽ wake app dậy + cấp trọn vẹn 30s mới.
            stopBackgroundExecutionTime()
            return
        }
        
        // Fallback: connect() sau 5s nếu pending connect của iOS không phản hồi
        // ═══ QUAN TRỌNG: Phải hủy pending connect TRƯỚC khi gọi connect() (scan mới) ═══
        // Lý do: gọi connect() trong khi central.connect() đang pending → iOS có cả
        // scan VÀ pending connect active → xung đột → connection không bao giờ hoàn thành.
        disconnectFallbackTimer?.cancel()
        let fallbackTimer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .scanning = self.stateMachine.state {
                // Hủy pending connect trước
                self.centralManager?.cancelPeripheralConnection(peripheral)
                // Sau đó mới bắt đầu scan/retrieve mới
                self.connect()
            }
        }
        disconnectFallbackTimer = fallbackTimer
        bleQueue.asyncAfter(deadline: .now() + 5, execute: fallbackTimer)
        
        // End BG task SAU KHI đã setup fallback
        // didConnect hoặc fallback timer sẽ gọi extendBackgroundExecutionTime() khi cần
        if isAppInBackground { stopBackgroundExecutionTime() }
    }

    #if NOASK
    /// iOS 16: delegate 3 tham số (bản isReconnecting là iOS 17+). Không có
    /// auto-reconnect hệ thống ở NOASK → isReconnecting luôn false.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        handleDisconnect(central, peripheral: peripheral, timestamp: CFAbsoluteTimeGetCurrent(), isReconnecting: false, error: error)
    }
    #else
    /// iOS 17+ (5.2.0): bản đầy đủ — CoreBluetooth gọi phương thức này thay cho
    /// bản (error:) khi cả hai tồn tại.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        handleDisconnect(central, peripheral: peripheral, timestamp: timestamp, isReconnecting: isReconnecting, error: error)
    }
    #endif
}

extension DatBikeCore: CBPeripheralDelegate {
    
    /// Xử lý khi xe thay đổi GATT table (Service Changed) — teardown phiên cũ +
    /// discover lại như một generation mới.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // I2: chỉ xử lý Service Changed của peripheral HIỆN HÀNH. Callback của link cũ
        // (sau khi đổi xe/link) không được xóa registry hay churn phiên mới.
        guard let oldCtx = activeContext, peripheral === oldCtx.peripheral else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_CALLBACK] didModifyServices của peripheral cũ — drop"))
            return
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "GATT table thay đổi (Service Changed) — teardown phiên + discover lại từ đầu..."))

        // I3: Service Changed = GATT table dựng lại; cache vừa xóa không còn giá trị.
        // Nếu chỉ clearState + discover mà KHÔNG restart phase thì: (a) authTask/polling/
        // command của generation cũ vẫn chạy trên registry rỗng; (b) state kẹt .active nên
        // gate auth trong didDiscoverCharacteristicsFor (chỉ chạy ở .connecting) không bao
        // giờ fire → UI "active" mà không điều khiển được. Phải teardown rồi vào lại
        // .connecting như một discovery attempt mới.
        pollingEngine?.stopPolling()
        authTask?.cancel()
        authTask = nil
        cancelDiscoveryWatchdog()
        cancelConnectingTimeout()
        standbyTimer?.invalidate()
        standbyTimer = nil
        isAuthenticating = false
        isRestoringSession = false
        isSessionAutoSuspended = false

        // Generation mới: context mới (sessionID/queue/io mới) → mọi task/queue còn sót của
        // generation trước không thể tác động phiên mới (các guard activeContext === ctx và
        // lockStateSessionID sẽ loại chúng).
        oldCtx.clearState()
        let ctx = BLEConnectionContext(peripheral: peripheral)
        activeContext = ctx
        peripheral.delegate = self
        commandDispatcher = BLECommandDispatcher(context: ctx)
        pollingEngine = BLEPollingEngine(context: ctx)

        DispatchQueue.main.async {
            guard self.activeContext === ctx else { return }
            self.lockStateSessionID = nil
            self.currentLockState = .unknown(Data())
        }

        // BLEStateMachine chặn trực tiếp .active → .connecting (guard chống reset phiên)
        // → nhấc qua .scanning trước rồi mới vào .connecting (cùng idiom auto-reconnect).
        if case .active = stateMachine.state {
            stateMachine.transition(to: .scanning)
        }
        stateMachine.transition(to: .connecting)

        discoveryRetryCount = 0
        startDiscoveryWatchdog()
        peripheral.discoverServices(BLEService.allServices)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // I2: bỏ qua discovery callback của peripheral cũ — không để nó retry/abort
        // discovery của generation hiện hành.
        guard activeContext?.peripheral === peripheral else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_CALLBACK] didDiscoverServices của peripheral cũ — drop"))
            return
        }
        let serviceCount = peripheral.services?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[GATT] didDiscoverServices | count=\(serviceCount) | error=\(error?.localizedDescription ?? "none") | peripheral=\(peripheral.identifier.uuidString.prefix(8))"))
        // §3.2: error KHÔNG còn bị nuốt im lặng — retry rồi abort
        if let error = error {
            retryDiscoveryOrAbort(peripheral: peripheral, reason: "didDiscoverServices error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            retryDiscoveryOrAbort(peripheral: peripheral, reason: "didDiscoverServices trả 0 service")
            return
        }
        for service in services {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[GATT]   Service: \(service.uuid.uuidString.prefix(8))"))
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let charCount = service.characteristics?.count ?? 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[GATT] didDiscoverCharacteristics | service=\(service.uuid.uuidString.prefix(8)) | charCount=\(charCount) | error=\(error?.localizedDescription ?? "none")"))
        guard let chars = service.characteristics, let ctx = activeContext else { return }
        // I2: callback của link cũ không được ghi vào registry của context mới.
        guard peripheral === ctx.peripheral else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_CALLBACK] didDiscoverCharacteristicsFor của peripheral cũ — drop"))
            return
        }
        for char in chars {
            ctx.register(characteristic: char)
            // [GATT-DUMP] fw 1.11.0 xoay suffix UUID char (E5) — dump bảng GATT thật để
            // cập nhật prefix table + xác định vai trò service mới F7E2C8A1 (E4).
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[GATT-DUMP] svc=\(service.uuid.uuidString.prefix(8)) | char=\(char.uuid.uuidString) | props=\(char.properties.shortString) | key=\(BLECharKey.key(forUUID: char.uuid)?.rawValue ?? "-")"))
        }
        
        // Kích hoạt auth CHỈ KHI ĐỦ cả 3 characteristic cần thiết (có thể nằm ở nhiều service khác nhau)
        // Lưu ý: stateMachine.state == .connecting đảm bảo chỉ kích hoạt 1 lần duy nhất (vì sau đó sẽ chuyển sang .standby hoặc .pairingRequired)
        if !isAuthenticating, stateMachine.state == .connecting,
           (try? ctx.requireCharacteristic(BLECharacteristic.authChallenge)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.timeSync)) != nil,
           (try? ctx.requireCharacteristic(BLECharacteristic.autoUnlock)) != nil {

            // §3.2: đủ characteristic bắt buộc → watchdog discovery hoàn thành nhiệm vụ
            cancelDiscoveryWatchdog()
            discoveryRetryCount = 0
            // §LOG: checkpoint gatt-ready — đo dc→gatt bằng timestamps của cycle
            if cycleGattReadyAt == nil {
                cycleGattReadyAt = Date()
                let dcToGatt = cycleDidConnectAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[CKPT gatt-ready] \(traceCtx(ctx)) | dc→gatt=\(dcToGatt.map { String($0) } ?? "?")ms | chars=\(ctx.discoveredCharacteristics.count)"))
            }

            cancelConnectingTimeout()
            if let savedPin = PreferencesManager.shared.savedPin, !savedPin.isEmpty {
                tryRestoreActiveSession(ctx: ctx)
            } else {
                isAuthenticating = true
                stateMachine.transition(to: .pairingRequired)
            }
        }
    }
    
    private func tryRestoreActiveSession(ctx: BLEConnectionContext) {
        guard let pin = preferences.savedPin, !pin.isEmpty else {
            stateMachine.transition(to: .pairingRequired)
            return
        }
        
        // B1 FIX: Guard chống SESSION_CHECK race condition
        // didDiscoverCharacteristics có thể fire 2 lần khi iOS GATT stack retry
        guard !isRestoringSession else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[SESSION_CHECK] Bỏ qua duplicate trigger (isRestoringSession=true) | uuid=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
            return
        }
        isRestoringSession = true
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SESSION_CHECK] Bắt đầu kiểm tra phiên | uuid=\(ctx.peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(ctx.peripheral.state.rawValue)"))
        
        Task {
            let isActive = await BLEAuthenticator.isSessionActive(context: ctx)
            
            DispatchQueue.main.async {
                // I4: sau await phải gate như executeAuthProtocol.sessionGate — không chỉ
                // kiểm tra link còn connected mà còn phải ĐÚNG session hiện hành. Cùng
                // CBPeripheral có thể đã reconnect sang context khác (generation mới) trong
                // lúc đọc; kết quả cũ không được transition .active / chiếm pollingEngine của
                // phiên mới. KHÔNG đụng isRestoringSession ở nhánh này — nó đã thuộc về
                // generation mới.
                guard self.activeContext === ctx else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[SESSION_CHECK] STALE — session đã đổi trong lúc đọc → bỏ qua kết quả restore"))
                    return
                }
                // GUARD: Bắt buộc kiểm tra state trước khi thay đổi StateMachine.
                // Nếu rớt mạng trong lúc đọc BLE, didDisconnect đã xử lý state rồi.
                guard ctx.peripheral.state == .connected else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[SESSION_CHECK] Bỏ qua vì xe đã mất kết nối trong quá trình đọc (state=\(ctx.peripheral.state.rawValue))"))
                    self.isRestoringSession = false
                    return
                }
                
                if isActive {
                    // Counter LẺ → phiên auth vẫn sống → restore .active TRỰC TIẾP
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                        message: "[RESTORE] Phiên auth vẫn active (counter lẻ) → skip auth, vào .active trực tiếp"))
                    self.logCycle("success", via: "session-restore")
                    
                    self.isRestoringSession = false
                    self.isAuthenticating = false
                    
                    // Lấy dữ liệu khởi tạo ngay lập tức vì ta đã bỏ qua standby phase
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RESTORE] Fetching initial data (Lock, Device Info, Telemetry)..."))
                    self.readLockStatus()
                    self.readDeviceInfo()
                    self.queryTelemetry()
                    
                    if let engine = self.pollingEngine {
                        engine.startPolling()
                        self.setupAutoUnlock(engine: engine)
                    }
                    self.lastActiveTime = Date()
                    self.stateMachine.transition(to: .active)
                    self.extendBackgroundExecutionTime()
                    
                    // User requirement: 1 ngày chỉ sync time 1 lần, skip proximity token
                    if self.preferences.needsTimeSyncToday {
                        Task {
                            if let syncChar = try? ctx.requireCharacteristic(BLECharacteristic.timeSync) {
                                let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
                                var cal = Calendar(identifier: .gregorian)
                                cal.timeZone = vnTZ
                                let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
                                let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
                                let timeSyncValue = String(secs)
                                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                    message: "[RESTORE] Syncing time (1 lần/ngày) = \(timeSyncValue)"))
                                try? await ctx.io.writeValue(Data(timeSyncValue.utf8), to: syncChar, type: .withResponse)
                                DispatchQueue.main.async {
                                    self.preferences.lastTimeSyncDate = Date()
                                }
                            }
                        }
                    }
                } else {
                    // Counter CHẴN → cần auth lại
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[RESTORE] Phiên auth đã hết (counter chẵn) → vào standby + auth lại"))
                    self.isRestoringSession = false
                    
                    // ═══ NEARBY MODE (chỉ Background): Giữ BLE connection, KHÔNG auth ═══
                    // Foreground KHÔNG còn đỗ .nearby nữa (fix 5.3.0): theo thiết kế ghi
                    // tại PreferencesManager.nearbyModeEnabled — "Khi user mở app
                    // (foreground) mới auth" — và FG_OPEN_GUARANTEE (5.0.0): mở app =
                    // ý định dùng xe → auth ngay qua startStandbyProximityChecks.
                    // Log 19/10 (phiên 15:23): FG đỗ .nearby + user bấm "Bật xe" →
                    // ghi lệnh khi chưa auth → xe im lặng bỏ qua ("báo kết nối mà
                    // không điều khiển được").
                    if self.preferences.nearbyModeEnabled, self.isAppInBackground {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[NEARBY] Background → giữ BLE, không auth | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
                        self.stateMachine.transition(to: .nearby)
                        self.isAuthenticating = false
                        // Đọc data cơ bản (không cần auth)
                        self.readLockStatus()
                        self.readDeviceInfo()
                        self.queryTelemetry()
                        // Poll RSSI nhẹ (5s thay vì 0.5s) để detect đi xa
                        DispatchQueue.main.async {
                            self.standbyTimer?.invalidate()
                            self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak ctx] _ in
                                ctx?.peripheral.readRSSI()
                            }
                        }
                        return
                    }
                    
                    // ═══ STANDBY DRAIN LOOP DETECTION + EXPONENTIAL BACKOFF ═══
                    // Khi connectOnlyWhenNear=true và xe ở xa, app rơi vào vòng lặp:
                    // Connect → Standby → RSSI poll → BG Task Expired → Disconnect → Reconnect → ...
                    // Mỗi chu kỳ tốn ~15-40s CPU + 1 GATT discovery + BG task time.
                    //
                    // Chiến lược:
                    // - Lần 1-2: cho phép standby bình thường (có thể user đang đi tới xe)
                    // - Lần 3+: chuyển sang pending connect VỚI exponential backoff:
                    //   Delay = min(2^(N-3) * 5s, 120s) → 5s, 10s, 20s, 40s, 80s, 120s, 120s...
                    if self.preferences.connectOnlyWhenNear {
                        self.consecutiveStandbyCount += 1
                        let drainThreshold = self.isAppInBackground ? 2 : self.maxConsecutiveStandbyBeforePending
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[STANDBY_DRAIN] count=\(self.consecutiveStandbyCount)/\(drainThreshold) | bg=\(self.isAppInBackground)"))
                        
                        if self.consecutiveStandbyCount >= drainThreshold {
                            // Exponential backoff: 5s, 10s, 20s, 40s, 80s, 120s max
                            let exponent = self.consecutiveStandbyCount - self.maxConsecutiveStandbyBeforePending
                            let backoffDelay = min(pow(2.0, Double(exponent)) * 5.0, 120.0)
                            
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "[STANDBY_DRAIN] Đã standby \(self.consecutiveStandbyCount) lần liên tiếp → pending connect + backoff \(String(format: "%.0f", backoffDelay))s"))
                            
                            // Disconnect + pending connect sau backoff delay
                            let peripheral = ctx.peripheral
                            if let central = self.centralManager {
                                central.cancelPeripheralConnection(peripheral)
                                self.activeContext = nil
                                self.commandDispatcher = nil
                                self.pollingEngine = nil
                                self.stateMachine.transition(to: .scanning)
                                
                                // Delay trước khi pending connect — tránh reconnect liên tục khi xe ở xa
                                // §3.7: qua RetryScheduler (nhóm standby-drain — 1 chuỗi duy nhất)
                                self.retryScheduler.schedule(label: "standby-drain backoff", group: "standby-drain", delay: backoffDelay) { [weak self] in
                                    guard let self, let central = self.centralManager, central.state == .poweredOn else { return }
                                    guard !self.isUserPaused else { return }
                                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                        message: "[STANDBY_DRAIN] Backoff \(String(format: "%.0f", backoffDelay))s hết → pending connect"))
                                    self.connectPeripheral(peripheral, central: central, isPendingConnect: true)
                                }
                            }
                            return
                        }
                    }
                    
                    self.startStandbyProximityChecks(ctx: ctx, pin: pin)
                }
            }
        }
    }
    
    private func startStandbyProximityChecks(ctx: BLEConnectionContext, pin: String) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
            message: "[STANDBY_CHECK] Bắt đầu | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | connectOnlyWhenNear=\(preferences.connectOnlyWhenNear) | rssiThreshold=\(preferences.rssiThreshold) | autoUnlock=\(preferences.autoUnlockEnabled) | shouldTurnOn=\(shouldTurnOnBikeAfterAuth) | autoSuspended=\(isSessionAutoSuspended)"))
        stateMachine.transition(to: .standby)
        isAuthenticating = false
        isSessionAutoSuspended = false
        weakRssiConsecutiveCount = 0  // Reset RSSI counter cho chu kỳ standby mới
        
        // Bỏ qua chờ khoảng cách nếu user chủ động bấm Đánh Thức (deep link/widget intent)
        if self.shouldTurnOnBikeAfterAuth {
            self.forceAuthenticate(turnOn: true)
            return
        }
        
        // ═══ FG-OPEN GUARANTEE: mở app = ý định dùng xe ═══
        // Foreground (user đang cầm máy, nhìn vào app) → KHÔNG chờ ngưỡng RSSI,
        // auth NGAY. Gate RSSI chỉ còn ý nghĩa ở background (đi ngang qua xe).
        // Đây là điều kiện "mở app gần xe là kết nối ngay, bắt buộc": sau khi link
        // + GATT lên (≤ vài giây), auth chạy thẳng không qua standby-wait.
        if !isAppInBackground && !preferences.isManualOnly {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[FG_OPEN_AUTH] Foreground mở app → auth ngay, bỏ qua chờ ngưỡng RSSI (rssiThreshold=\(preferences.rssiThreshold))"))
            isAuthenticating = true
            executeAuthProtocol(ctx: ctx, pin: pin)
            return
        }
        
        // ═══ FAST PATH: Nếu không dùng chế độ "Chỉ kết nối khi gần" ═══
        // Không cần poll RSSI → auth ngay, không qua standby waiting.
        if !preferences.connectOnlyWhenNear {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "connectOnlyWhenNear=false → bỏ qua standby, auth ngay"))
            isAuthenticating = true
            executeAuthProtocol(ctx: ctx, pin: pin)
            return
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                message: "Chế độ 'Chỉ kết nối khi gần' ĐANG BẬT. RssiThreshold = \(preferences.rssiThreshold)"))
        }
        
        NotificationManager.shared.sendNotification(
            title: "Trạng thái kết nối",
            body: "Phát hiện di chuyển gần xe, kết nối ở trạng thái chờ",
            identifier: "StandbyProximity"
        )
        
        // Vẫn đọc dữ liệu qua BLE (không cần chờ Authentication Protocol)
        self.readLockStatus()
        self.readDeviceInfo()
        self.queryTelemetry()
        
        DispatchQueue.main.async {
            self.standbyTimer?.invalidate()
            
            // ═══ INSTANT RSSI CHECK ═══
            // Đọc RSSI ngay lập tức (không chờ tick đầu tiên của timer).
            // Nếu người dùng đang đứng gần xe, auth sẽ trigger ngay thay vì sau 0.5s.
            ctx.peripheral.readRSSI()
            
            // Poll RSSI mỗi 0.5s để phát hiện ngưỡng gần xe nhanh hơn ~50% so với 1s cũ
            self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak ctx] _ in
                ctx?.peripheral.readRSSI()
            }
        }
    }
    
    func submitPairingPin(_ pin: String) {
        executeOnBleQueue { [weak self] in
            guard let self,
                  self.stateMachine.state == .pairingRequired,
                  let ctx = self.activeContext,
                  ctx.peripheral.state == .connected else { return }
            // The PIN belongs to this pending pairing attempt until the bike
            // confirms authentication. Never treat a failed attempt as enrolled.
            self.executeAuthProtocol(ctx: ctx, pin: pin, isKnownDevice: false)
        }
    }
    
    private func executeAuthProtocol(ctx: BLEConnectionContext, pin: String, isKnownDevice: Bool = true) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[AUTH] Bắt đầu | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | isKnown=\(isKnownDevice) | pinLen=\(pin.count) | smState=\(stateMachine.state.displayText) | prevAuthTask=\(authTask != nil ? "có (cancel)" : "nil")"))
        let authenticator = BLEAuthenticator(context: ctx, pin: pin, isKnownDevice: isKnownDevice)
        let attemptID = UUID()
        
        authTask?.cancel()
        authAttemptID = attemptID
        authTask = Task {
            // ═══ §3.3 (P1): Cổng toàn vẹn phiên ═══
            // Sau MỌI await phải kiểm tra: (1) task bị cancel, (2) session đã đổi
            // (activeContext không còn là ctx), (3) link còn connected. Không đạt ⇒
            // thoát im lặng — TUYỆT ĐỐI không publish .active / notification ảo.
            func sessionGate(_ stage: String) -> Bool {
                if Task.isCancelled {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[AUTH][GATE:\(stage)] Task bị cancel → dừng, không publish .active"))
                    return false
                }
                guard self.activeContext === ctx else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[AUTH][GATE:\(stage)] STALE — session đã đổi (ctx cũ \(ctx.peripheral.identifier.uuidString.prefix(8))) → bỏ qua kết quả"))
                    return false
                }
                guard self.authAttemptID == attemptID else { return false }
                guard ctx.peripheral.state == .connected else {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[AUTH][GATE:\(stage)] Link đã rớt (state=\(ctx.peripheral.state.rawValue)) → bỏ qua kết quả"))
                    return false
                }
                return true
            }

            do {
                stateMachine.transition(to: .authenticating)
                _ = try await authenticator.authenticate()
                guard sessionGate("post-auth") else { return }

                if !isKnownDevice {
                    // Persist both credentials before the UI's NFC settling delay:
                    // an app termination during that delay must not lose the bike's PIN.
                    try await self.commitPairingIfCurrent(ctx: ctx, pin: pin, attemptID: attemptID)
                    guard sessionGate("post-pairing-commit") else { return }
                }

                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[AUTH] Thành công ✅ | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(ctx.peripheral.state.rawValue)"))
                self.logCycle("success", via: "auth")

                if let engine = self.pollingEngine {
                    engine.startPolling()
                    self.setupAutoUnlock(engine: engine)
                }

                // Session auto state đã được quản lý bởi isSessionAutoSuspended

                self.lastActiveTime = Date() // Ghi nhận thời điểm active để cooldown downgrade

                // Trì hoãn 2.5s đối với lần đầu ghép đôi (isKnownDevice = false)
                // Đảm bảo người dùng không rút thẻ NFC ra quá sớm khi thấy màn hình chuyển sang Dashboard
                // dẫn đến việc xác thực ở firmware xe bị ngắt ngang.
                // §3.3: `try await` — nếu task bị cancel trong lúc chờ, KHÔNG vào .active.
                if !isKnownDevice {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[AUTH] Lần đầu ghép đôi -> Delay 2.5s trước khi vào Dashboard để giữ thẻ NFC"))
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    guard sessionGate("post-pairing-delay") else { return }
                }

                stateMachine.transition(to: .active)
                self.micRetryCount = 0 // Reset MIC retry counter khi kết nối thành công
                self.micFailureSessionCount = 0 // §CB_RECYCLE: rỉ rả reset khi connect OK
                self.micFailureCountAtLastRecycle = 0
                self.cbRecycleCount = 0 // §CB_RECYCLE: cho phép recycle ở các sự cố sau
                self.phantomGuardFailCount = 0 // Reset phantom guard để tránh backoff dài không cần thiết
                // C1 (5.1.0): connect thành công → FG_HEAL có lại full quota cho sự cố sau
                // (quota là theo phiên app, chỉ reset ở đây chứ không phải mỗi foreground)
                self.foregroundHealAttempts = 0
                NotificationManager.shared.sendNotification(
                    title: "Trạng thái kết nối",
                    body: "Đã kết nối thành công",
                    identifier: "Connected"
                )

                // Lưu UUID để lần sau dùng retrievePeripherals (tránh MIC failure)
                // §3.3: dùng ctx đã capture — không phải activeContext tại thời điểm chạy.
                self.preferences.savedPeripheralUUID = ctx.peripheral.identifier.uuidString

                // Post-auth: đọc lock status + device info + telemetry
                self.readLockStatus()
                self.readDeviceInfo()
                self.queryTelemetry()

                if self.shouldTurnOnBikeAfterAuth {
                    self.shouldTurnOnBikeAfterAuth = false
                    if let dispatcher = self.commandDispatcher {
                        Task { try? await dispatcher.turnOnBike() }
                    }
                }

                // Auto sync time 1 lần/ngày
                if self.preferences.needsTimeSyncToday, let dispatcher = self.commandDispatcher {
                    Task {
                        do {
                            try await dispatcher.syncTime()
                            self.preferences.lastTimeSyncDate = Date()
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                                message: "Auto time sync hàng ngày ✅"))
                        } catch {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                                message: "Auto time sync thất bại: \(error.localizedDescription)"))
                        }
                    }
                }
            } catch IoTError.shaChallengeFailed {
                guard sessionGate("sha-failure") else { return }
                self.failAuthentication(ctx: ctx,
                    message: "Xác thực thất bại. Thử lại hoặc tắt/bật Bluetooth.")
            } catch {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                    message: "[AUTH] Lỗi khác: \(error.localizedDescription) | isCancelled=\(Task.isCancelled) | peripheral=\(ctx.peripheral.identifier.uuidString.prefix(8))"))
                guard sessionGate("auth-failure") else { return }
                self.failAuthentication(ctx: ctx,
                    message: "Lỗi xác thực: \(error.localizedDescription)")
            }
        }
    }

    private func commitPairingIfCurrent(ctx: BLEConnectionContext, pin: String, attemptID: UUID) async throws {
        let committed = await withCheckedContinuation { continuation in
            executeOnBleQueue { [weak self] in
                guard let self,
                      self.activeContext === ctx,
                      self.authAttemptID == attemptID,
                      self.stateMachine.state == .authenticating,
                      ctx.peripheral.state == .connected else {
                    continuation.resume(returning: false)
                    return
                }
                guard self.preferences.commitPairingPIN(pin) else {
                    continuation.resume(returning: false)
                    return
                }
                self.preferences.savedPeripheralUUID = ctx.peripheral.identifier.uuidString
                continuation.resume(returning: true)
            }
        }
        guard committed else {
            throw NSError(domain: "SmartKey.Keychain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Không lưu được khóa ghép đôi an toàn trên iPhone."])
        }
    }

    private func failAuthentication(ctx: BLEConnectionContext, message: String) {
        executeOnBleQueue { [weak self] in
            guard let self, self.activeContext === ctx,
                  ctx.peripheral.state == .connected else { return }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "[AUTH] Lỗi phiên \(ctx.sessionID.uuidString.prefix(8)) → ngắt kết nối"))
            self.performDisconnect()
            self.stateMachine.transition(to: .error(message))
        }
    }
    
    // MARK: - Post-Auth Data Reads
    
    /// Public — gọi từ ViewModel sau khi bật/tắt xe để cập nhật dashboard
    func refreshLockState() {
        readLockStatus()
    }
    
    private func readLockStatus() {
        guard let ctx = activeContext else { return }
        Task {
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.smartkeyEcho) {
                do {
                    let data = try await ctx.queue.enqueue {
                        try await ctx.io.readValue(from: char)
                    }
                    let status = IoTLockState.parse(from: data)
                    DispatchQueue.main.async {
                        guard self.activeContext === ctx else { return }
                        self.lockStateSessionID = ctx.sessionID
                        self.currentLockState = status
                    }
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "Trang thái xe: \(status.description) (raw: \(data.hexString))"))
                } catch {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "Đọc lock status lỗi: \(error.localizedDescription)"))
                }
            }
        }
    }
    
    private func readDeviceInfo() {
        guard let ctx = activeContext else { return }
        Task {
            var name = ""
            var serial = ""
            var model = ""
            var fw = ""
            var hardwareMac = ""
            
            // Device name (vehicleStatus)
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.vehicleStatus),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                name = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Serial
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.deviceSerialAlt),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                serial = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Model
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.deviceModelAlt),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                model = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Firmware version
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.fwVersion),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let str = String(data: data, encoding: .utf8) {
                fw = str.trimmingCharacters(in: .controlCharacters)
            }
            
            // Bike Config JSON — chứa địa chỉ MAC phần cứng thực, số khung, tên xe v.v.
            // Đây là MAC thực (ví dụ: "C8:EA:F2:XX:YY:ZZ")
            // iOS CoreBluetooth KHÔNG cho phép đọc MAC trực tiếp, nên phải lấy từ GATT characteristic.
            if let char = try? ctx.requireCharacteristic(BLECharacteristic.bikeConfigJson),
               let data = try? await ctx.queue.enqueue(task: { try await ctx.io.readValue(from: char) }),
               let jsonStr = String(data: data, encoding: .utf8) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[DEVICE_INFO] bikeConfigJson raw: \(jsonStr.prefix(300))"))
                
                // Parse JSON linh hoạt — firmware có thể dùng nhiều key khác nhau cho MAC
                if let jsonData = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    // Tìm MAC address từ các key phổ biến
                    let macKeys = ["mac", "MAC", "macAddress", "mac_address", "ble_mac", "bleMac", "address"]
                    for key in macKeys {
                        if let mac = dict[key] as? String, !mac.isEmpty {
                            hardwareMac = mac.trimmingCharacters(in: .whitespacesAndNewlines)
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                                message: "[DEVICE_INFO] Tìm thấy MAC phần cứng: \(hardwareMac) (key=\(key))"))
                            break
                        }
                    }
                    
                    // Fallback: lấy serial/frame từ JSON nếu GATT characteristic trước đó trả về rỗng
                    if serial.isEmpty {
                        let serialKeys = ["serial", "serialNumber", "serial_number", "frame", "frameNumber", "frame_number"]
                        for key in serialKeys {
                            if let val = dict[key] as? String, !val.isEmpty {
                                serial = val.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig[key] as? String, !val.isEmpty {
                                serial = val.trimmingCharacters(in: .whitespacesAndNewlines)
                                break
                            }
                        }
                    }
                    if model.isEmpty {
                        // Tìm "model" ở root (cũ) hoặc trong "bikeConfig" (mới)
                        if let val = dict["model"] as? String, !val.isEmpty {
                            model = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig["model"] as? String, !val.isEmpty {
                            model = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if name.isEmpty || name == "Dat Bike" {
                        if let val = dict["name"] as? String, !val.isEmpty, val != "Dat Bike" {
                            name = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let bikeConfig = dict["bikeConfig"] as? [String: Any], let val = bikeConfig["name"] as? String, !val.isEmpty, val != "Dat Bike" {
                            name = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if fw.isEmpty {
                        // Parse "firmware" object trong JSON
                        if let fwObj = dict["firmware"] as? [String: Any], let ver = fwObj["version"] as? String, !ver.isEmpty {
                            fw = ver.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else if let val = dict["firmware"] as? String, !val.isEmpty {
                            fw = val.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            
            let vehicleString = "Xe: \(name) / \(model) / \(serial) / FW: \(fw) / MAC: \(hardwareMac.isEmpty ? "N/A" : hardwareMac)"
            if vehicleString != self.lastLoggedVehicleString {
                self.lastLoggedVehicleString = vehicleString
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: vehicleString))
            }
            
            // Ưu tiên: name > model > peripheral.name (để ưu tiên tên riêng người dùng đặt như 'Ngựa sắt')
            let displayName: String = {
                if !name.isEmpty && name != "Dat Bike" { return name }
                if !model.isEmpty { return model }
                // Fallback: tên quảng bá BLE (ví dụ "Ngựa sắt") > peripheral.name (iOS cache)
                if let advName = self.lastAdvertisedName, !advName.isEmpty { return advName }
                return ctx.peripheral.name ?? "Dat Bike"
            }()
            
            // Lưu tên hiển thị của xe (dùng cho lần mở app sau khi chưa kịp kết nối)
            self.preferences.sharedDefaults.set(displayName, forKey: "widgetBikeName")
            
            // ═══ SMART SAVE: Chỉ ghi đè nếu dữ liệu mới KHÔNG rỗng ═══
            // Tránh trường hợp lần đầu ghép nối bị lỗi read → ghi đè cache offline bằng chuỗi rỗng.
            // Lần kết nối sau query thành công → dữ liệu sẽ được lưu bổ sung.
            if !displayName.isEmpty && displayName != "Dat Bike" {
                self.preferences.savedBikeName = displayName
            } else if self.preferences.savedBikeName == nil {
                // Lần đầu chưa có gì → lưu tạm "Dat Bike"
                self.preferences.savedBikeName = displayName
            }
            
            if !serial.isEmpty {
                self.preferences.savedBikeSerial = serial
            }
            
            if !model.isEmpty {
                self.preferences.savedBikeModel = model
            }
            
            if !fw.isEmpty {
                self.preferences.savedBikeFirmware = fw
            }
            
            // MAC phần cứng: ưu tiên giá trị thực từ bikeConfigJson, fallback về CoreBluetooth UUID
            if !hardwareMac.isEmpty {
                self.preferences.savedBikeMac = hardwareMac
            } else if self.preferences.savedBikeMac == nil {
                // Chưa có MAC nào → lưu tạm UUID của CoreBluetooth (để ít nhất có thể nhận dạng)
                self.preferences.savedBikeMac = ctx.peripheral.identifier.uuidString
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[DEVICE_INFO] Không tìm thấy MAC phần cứng trong bikeConfigJson — lưu tạm CoreBluetooth UUID"))
            }
            
            DispatchQueue.main.async {
                self.currentVehicleInfo = IoTVehicleInfo(
                    name: displayName,
                    serialNumber: serial,
                    modelNumber: model,
                    firmwareVersion: fw
                )
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // §3.5 (lớp 1): chỉ forward response về cho session HIỆN TẠI —
        // Task chạy trễ có thể bơm response của peripheral cũ vào io của session mới.
        guard let ctx = activeContext, peripheral === ctx.peripheral else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_CALLBACK] didUpdateValueFor \(characteristic.uuid) của peripheral cũ — drop"))
            return
        }
        Task { await ctx.io.didReceiveReadResponse(for: characteristic, error: error) }

        if error == nil, BLECharKey.key(forUUID: characteristic.uuid) == .smartkeyEcho {
            if let data = characteristic.value {
                let status = IoTLockState.parse(from: data)
                if case .unknown = status {
                    // Ignore unknown transitions to avoid overriding state with noise
                } else {
                    DispatchQueue.main.async {
                        guard self.activeContext === ctx else { return }
                        // Notify BLE push: chi log khi status thuc su thay doi
                        if self.currentLockState != status {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[BLE Notify] Trang thai xe thay doi: \(status.description)"))
                        }
                        self.currentLockState = status
                        self.lockStateSessionID = ctx.sessionID
                    }
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // §3.5 (lớp 1): như trên — không bơm response cũ vào io session mới.
        if let ctx = activeContext, peripheral === ctx.peripheral {
            Task { await ctx.io.didReceiveWriteResponse(for: characteristic, error: error) }
        } else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[STALE_CALLBACK] didWriteValueFor \(characteristic.uuid) của peripheral cũ — drop"))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, let ctx = activeContext,
              ctx.peripheral === peripheral else { return }
        let rssiValue = RSSI.intValue
        // Reject unavailable/invalid samples (including CoreBluetooth's 127).
        guard (-127 ... -1).contains(rssiValue) else { return }

        DispatchQueue.main.async {
            guard self.activeContext === ctx else { return }
            self.updateRSSI(rssiValue)
            
            if self.stateMachine.state == .standby {
                // §4.5 (P3): manualOnly ⇒ tuyệt đối không auto-auth từ RSSI
                if self.preferences.isManualOnly { return }

                let threshold = self.preferences.connectOnlyWhenNear ? self.preferences.rssiThreshold : -70.0

                // Rate limit log: chỉ in mỗi 2 giây
                let now = Date()
                if self.lastRssiLogTime == nil || now.timeIntervalSince(self.lastRssiLogTime!) >= 2.0 {
                    self.lastRssiLogTime = now
                    PersistentLogger.shared.append(BLELogEntry(timestamp: now, level: .verbose,
                        message: "[RSSI] Standby chờ gần: RSSI=\(rssiValue) / Ngưỡng=\(threshold) | weakCount=\(self.weakRssiConsecutiveCount) | strongCount=\(self.strongRssiConsecutiveCount)"))
                }

                // Chỉ auto-authenticate khi vào vùng VÀ không bị đình chỉ trong phiên
                // §3.9 (P4): hysteresis enter — 2 mẫu liên tiếp ≥ ngưỡng (dẹp fluke 1 mẫu)
                if Double(rssiValue) >= threshold {
                    if self.isSessionAutoSuspended {
                        return
                    }

                    self.strongRssiConsecutiveCount += 1
                    guard self.strongRssiConsecutiveCount >= 2 else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                            message: "[RSSI][HYST] Mẫu mạnh đầu tiên (\(rssiValue)) — chờ mẫu thứ 2 xác nhận"))
                        return
                    }

                    // Reset tất cả drain counters — RSSI đạt ngưỡng, auth sẽ thành công
                    self.consecutiveStandbyCount = 0
                    self.weakRssiConsecutiveCount = 0
                    self.strongRssiConsecutiveCount = 0

                    self.standbyTimer?.invalidate()
                    self.standbyTimer = nil
                    self.isAuthenticating = true
                    if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                        self.executeAuthProtocol(ctx: ctx, pin: pin)
                    }
                } else if Double(rssiValue) >= threshold - self.rssiExitHysteresisDb {
                    // §3.9 (P4): dải hysteresis quanh ngưỡng — không mạnh đủ auth,
                    // cũng không yếu đủ drain → reset cả hai counter, tránh dao động
                    self.strongRssiConsecutiveCount = 0
                    self.weakRssiConsecutiveCount = 0
                } else {
                    // ═══ PROACTIVE STANDBY DRAIN: RSSI consistently weak ═══
                    self.weakRssiConsecutiveCount += 1
                    
                    if self.weakRssiConsecutiveCount >= self.maxWeakRssiBeforeDisconnect {
                        // ═══ FOREGROUND + connectOnlyWhenNear: Chuyển sang .nearby thay vì disconnect ═══
                        // Trường hợp: xe ngoài sân, người trong nhà — sóng yếu mạnh liên tục
                        // nhưng user chưa có nhu cầu sử dụng xe. Disconnect sẽ gây loop reconnect
                        // liên tục tốn pin. Thay vào đó, giữ kết nối nhẹ (poll RSSI 5s) ở .nearby.
                        if !self.isAppInBackground && self.preferences.connectOnlyWhenNear && !self.isSessionAutoSuspended {
                            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                                message: "[STANDBY_DRAIN] Foreground + RSSI yếu liên tục → chuyển .nearby (poll chậm) thay vì disconnect"))
                            self.weakRssiConsecutiveCount = 0
                            self.standbyTimer?.invalidate()
                            self.stateMachine.transition(to: .nearby)
                            self.isAuthenticating = false
                            // Poll RSSI chậm 5s — đủ để detect user quay lại gần xe
                            self.standbyTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
                                self?.activeContext?.peripheral.readRSSI()
                            }
                            return
                        }
                        
                        self.consecutiveStandbyCount += 1
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                            message: "[STANDBY_DRAIN] RSSI yếu liên tục → giao pending reconnect cho CoreBluetooth, không chờ timer trong app"))
                        
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.weakRssiConsecutiveCount = 0
                        
                        if let ctx = self.activeContext, let central = self.centralManager {
                            let peripheral = ctx.peripheral
                            central.cancelPeripheralConnection(peripheral)
                            self.activeContext = nil
                            self.commandDispatcher = nil
                            self.pollingEngine = nil
                            self.stateMachine.transition(to: .scanning)
                            self.isPendingConnectWaiting = true // §UX: pending connect
                            
                            // Submit before relinquishing runtime. An app timer is not
                            // a wake-up mechanism after iOS suspends the process.
                            central.connect(peripheral, options: Self.connectOptions())
                        }
                    }
                }
            } else if case .nearby = self.stateMachine.state {
                // ═══ NEARBY: RSSI poll nhẹ ═══
                // §4.5 (P3): manualOnly ⇒ không auto-auth từ RSSI
                if self.preferences.isManualOnly { return }

                let threshold = self.preferences.rssiThreshold

                // RSSI trở lại mạnh → chuyển về standby để auto-auth
                // §3.9 (P4): hysteresis enter — 2 mẫu liên tiếp, không còn single-sample
                if Double(rssiValue) >= threshold && !self.isSessionAutoSuspended {
                    self.strongRssiConsecutiveCount += 1
                    guard self.strongRssiConsecutiveCount >= 2 else {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose,
                            message: "[NEARBY][HYST] Mẫu mạnh đầu tiên (\(rssiValue)) — chờ mẫu thứ 2 xác nhận"))
                        return
                    }
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[NEARBY] RSSI=\(rssiValue) đạt ngưỡng \(threshold) ×2 mẫu → chuyển về standby để auth"))
                    self.weakRssiConsecutiveCount = 0
                    self.strongRssiConsecutiveCount = 0
                    if let ctx = self.activeContext, let pin = self.preferences.savedPin {
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.isAuthenticating = true
                        self.executeAuthProtocol(ctx: ctx, pin: pin)
                    }
                    return
                }
                
                // Disconnect khi quá xa
                if rssiValue < -95 {
                    self.weakRssiConsecutiveCount += 1
                    if self.weakRssiConsecutiveCount >= 5 { // 5 × 5s = 25s liên tục xa
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[NEARBY] RSSI=\(rssiValue) quá yếu liên tục → disconnect + pending connect"))
                        self.standbyTimer?.invalidate()
                        self.standbyTimer = nil
                        self.weakRssiConsecutiveCount = 0
                        if let ctx = self.activeContext, let central = self.centralManager {
                            let peripheral = ctx.peripheral
                            central.cancelPeripheralConnection(peripheral)
                            self.activeContext = nil
                            self.commandDispatcher = nil
                            self.pollingEngine = nil
                            self.stateMachine.transition(to: .scanning)
                            self.isPendingConnectWaiting = true // §UX: pending connect
                            central.connect(peripheral, options: Self.connectOptions())
                        }
                    }
                } else {
                    self.weakRssiConsecutiveCount = 0
                    self.strongRssiConsecutiveCount = 0 // §3.9: yếu → chuỗi mạnh đứt
                }
            } else {
                self.pollingEngine?.didReadRSSI(value: RSSI.doubleValue)
            }
        }
    }
    
    @objc private func appDidEnterBackground() {
        executeOnBleQueue { [weak self] in self?.handleAppBackground() }
    }

    private func handleAppBackground() {
        isAppInBackground = true
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[LIFECYCLE] App → Background | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | isAuth=\(isAuthenticating) | autoSuspended=\(isSessionAutoSuspended)"))
        extendBackgroundExecutionTime()
    }
    
    @objc private func appWillEnterForeground() {
        executeOnBleQueue { [weak self] in self?.handleAppForeground() }
    }

    private func handleAppForeground() {
        isAppInBackground = false
        _ = preferences.refreshSavedPinFromKeychain()
        // §FG_HEAL: mở lại app → reset quota + bắt đầu canh 10s
        beginForegroundHealWatchdog()
        // End BG task khi về foreground — tránh leak (81 leaked tasks/28 ngày).
        // BLE callbacks chạy trên queue riêng (core.ble), không bị race với main queue.
        stopBackgroundExecutionTime()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[LIFECYCLE] App → Foreground | smState=\(stateMachine.state.displayText) | activeCtx=\(activeContext?.peripheral.identifier.uuidString.prefix(8).description ?? "nil") | peripheralState=\(activeContext?.peripheral.state.rawValue ?? -1) | btPowerOff=\(btWasPoweredOff) | forceScan=\(forceFullScan)"))
        
        // A physical BLE link held in nearby/standby still needs an authenticated
        // session when the user opens the app. Explicit pause remains respected.
        if stateMachine.state == .nearby || stateMachine.state == .standby,
           let ctx = activeContext, ctx.peripheral.state == .connected {
            guard !preferences.isManualOnly else { return }
            guard !isAuthenticating else { return }
            guard let pin = preferences.savedPin else {
                stateMachine.transition(to: .pairingRequired)
                return
            }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[FG_OPEN_AUTH] Mở app với link nearby/standby → xác thực phiên đang giữ"))
            standbyTimer?.invalidate()
            standbyTimer = nil
            startStandbyProximityChecks(ctx: ctx, pin: pin)
            return
        }

        if case .connecting = stateMachine.state, isPendingConnectWaiting {
            executeOnBleQueue { [weak self] in
                self?.performConnect(userInitiated: true)
            }
            return
        }
        
        if stateMachine.state == .scanning {
            // ═══ C5 (5.1.0): "Ở gần xe, chưa dùng" chỉ chặn auto-connect của NỀN ═══
            // (background wake, RSSI, ASK) — user CHỦ ĐỘNG mở app = muốn dùng xe
            // → thoát intent này và đi aggressive reconnect (FG-OPEN GUARANTEE áp
            // dụng lại). Chỉ "Tạm dừng" (pausedByUser) là giữ nguyên chặn.
            if preferences.connectionIntent == .manualOnlyNearbyNotInUse {
                preferences.connectionIntent = .autoConnect
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Foreground với intent=manualOnlyNearbyNotInUse → user mở app chủ động, thoát intent + aggressive reconnect"))
            }
            // ═══ §4.5 (P3): manualOnly ⇒ foreground KHÔNG auto-reconnect ═══
            if preferences.isManualOnly {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Foreground nhưng intent=\(preferences.connectionIntent.rawValue) → KHÔNG aggressive reconnect (chờ user bấm 'Kết nối để dùng xe')"))
                return
            }
            if isPendingConnectWaiting, activeContext == nil,
               let central = centralManager,
               let savedUUID = preferences.savedPeripheralUUID.flatMap(UUID.init(uuidString:)),
               let pending = central.retrievePeripherals(withIdentifiers: [savedUUID]).first,
               pending.state == .connecting {
                // Legacy direct pending-connect paths have no context owner.
                // Cancel that request and wait for its callback before retrying.
                isPendingCleanReconnect = true
                beginCleanReconnectDeadline()
                isPendingConnectWaiting = false
                central.cancelPeripheralConnection(pending)
                return
            }
            // ═══ AGGRESSIVE FOREGROUND RECONNECT ═══
            // User mở app = "tôi muốn kết nối NGAY". Hủy mọi pending stale:
            // - scanTimer đang chạy (nếu có) → clear để connect() không bị guard
            // - fallback timer đang chạy → clear
            // - pending connect cũ → cancel rồi connect mới
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[LIFECYCLE] Đang scanning → aggressive reconnect (clear stale + fresh connect)"))
            
            // Clear scan timer để connect() không bị block bởi guard "scanTimer != nil"
            scanTimer?.cancel()
            scanTimer = nil
            centralManager?.stopScan()
            
            // Clear fallback timer cũ
            disconnectFallbackTimer?.cancel()
            disconnectFallbackTimer = nil
            
            // ═══ FG-OPEN GUARANTEE: KHÔNG cancel link đang thương lượng ═══
            // peripheral .connecting = hệ thống ĐANG hoàn tất link (pending connect
            // sau force-quit/suspend). Cancel ở đây = tự tay giết kết nối sắp xong
            // → "mở app lúc được lúc không". Chỉ cancel peripheral thực sự stale
            // (.disconnected/.disconnecting).
            let hadContext = (activeContext != nil)
            if let ctx = activeContext, let central = centralManager,
               ctx.peripheral.state == .disconnected || ctx.peripheral.state == .disconnecting {
                isPendingCleanReconnect = true
                beginCleanReconnectDeadline() // C2 (5.1.0): zombie .disconnecting không sinh didDisconnect
                central.cancelPeripheralConnection(ctx.peripheral)
                activeContext = nil
                commandDispatcher = nil
                pollingEngine = nil
            } else if let ctx = activeContext, ctx.peripheral.state == .connecting {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Foreground: peripheral đang .connecting (link đang lên) → GIỮ, không cancel"))
            }
            
            if !hadContext || !isPendingCleanReconnect {
                // F4 (5.2.0): user mở app = muốn nối NGAY → connect trực tiếp có guard
                connect(userInitiated: true)
            }
        } else if stateMachine.state == .connecting, let timer = connectingTimer {
            // ═══ GUARD: Chỉ hủy nếu peripheral THỰC SỰ stale (không phải cold launch ASK) ═══
            // Cold launch với ASK: peripheral.state == .connected (connection hợp lệ)
            // → KHÔNG hủy, để GATT discovery tiếp tục bình thường.
            // Background phantom: peripheral.state != .connected (stale)
            // → Hủy và scan mới.
            if let ctx = self.activeContext, ctx.peripheral.state == .connected {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Đang connecting nhưng peripheral.state==connected → giữ nguyên (cold launch / ASK)"))
                // Chỉ cancel timer phantom, không hủy connection
                timer.cancel()
                self.connectingTimer = nil
            } else if let ctx = self.activeContext, ctx.peripheral.state == .connecting {
                // ═══ FG-OPEN GUARANTEE: link đang thương lượng → GIỮ NGUYÊN ═══
                // Watchdog (connectingTimer) tiếp tục chạy — nếu là phantom nó sẽ tự
                // teardown sau 5s. Không cancel link thật đang lên.
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "[LIFECYCLE] Đang connecting + peripheral .connecting (link đang lên) → GIỮ, watchdog tiếp tục canh"))
            } else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[LIFECYCLE] Đang connecting + peripheral stale → force timeout + scan mới"))
                timer.cancel()
                self.connectingTimer = nil
                
                if let ctx = self.activeContext, let central = self.centralManager {
                    central.cancelPeripheralConnection(ctx.peripheral)
                }
                self.activeContext = nil
                self.commandDispatcher = nil
                self.pollingEngine = nil
                self.isAuthenticating = false
                self.forceFullScan = true
                self.connect(userInitiated: true) // F4 (5.2.0): user đang chờ — có guard
            }
        }
    }

    @objc private func protectedDataDidBecomeAvailable() {
        guard preferences.refreshSavedPinFromKeychain(), !isUserPaused else { return }
        executeOnBleQueue { [weak self] in
            guard let self, let pin = self.preferences.savedPin else { return }
            if case .pairingRequired = self.stateMachine.state,
               let ctx = self.activeContext,
               ctx.peripheral.state == .connected {
                self.executeAuthProtocol(ctx: ctx, pin: pin)
            } else {
                self.performConnect()
            }
        }
    }
}

// MARK: - LIVE ACTIVITY SUPPORT

import ActivityKit


extension DatBikeCore {
    public func forceStopScan() {
        print("[BLE] Force stop scan on DatBikeCore")
        self.centralManager.stopScan()
    }
    
    /// Bắt đầu quét BLE chẩn đoán (10s) nếu BT đã poweredOn và chưa có xe ghép đôi.
    /// Gọi từ ViewModel sau initializeHardware() khi centralManagerDidUpdateState có thể đã fire rồi.
    func startDiagnosticScanIfReady() {
        executeOnBleQueue {
            let cmState = self.centralManager?.state.rawValue ?? -1
            let uuid = self.preferences.savedPeripheralUUID
            let isScanning = self.centralManager?.isScanning ?? false
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DIAG_CHECK] cmState=\(cmState) | uuid=\(uuid?.prefix(8).description ?? "nil") | isScanning=\(isScanning)"))
            
            guard let central = self.centralManager else { return }
            guard self.preferences.savedPeripheralUUID == nil else { return }
            guard !central.isScanning else { return }
            
            // iOS 18 + ASK: CBCentralManager.state có thể MÃI ở .poweredOff (state=4)
            // khi chưa hoàn tất ASK pairing. Bỏ qua check .poweredOn, scan trực tiếp.
            // Nếu BT thực sự off thì scanForPeripherals không trả kết quả (không crash).
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[DIAG] Bắt đầu quét BLE chẩn đoán (10s) — cmState=\(central.state.rawValue) | pin=\(self.preferences.savedPin != nil ? "có" : "nil")"))
            self.stateMachine.transition(to: .scanning)
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ])
            // Tự dừng sau 10s
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.preferences.savedPeripheralUUID == nil else { return }
                self.executeOnBleQueue {
                    self.centralManager?.stopScan()
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                        message: "[DIAG] Kết thúc quét BLE chẩn đoán"))
                }
            }
        }
    }
}
