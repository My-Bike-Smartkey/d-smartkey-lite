import Foundation
import Combine

@MainActor
class SettingsViewModel: ObservableObject {
    
    private let core: DatBikeCore

    /// §4.4 (P3): intent kết nối cho SettingsView.
    var isManualOnly: Bool { core.isManualOnly }
    var connectionIntent: ConnectionIntent { core.connectionIntent }
    /// Thoát manualOnly + kết nối ngay (nút "Kết nối để dùng xe" trong Settings).
    func connectForRide() { core.connectForRide() }
    let preferences: PreferencesManager
    
    // Outputs cho giao diện Cài đặt
    @Published var rssiThreshold: Double
    @Published var autoUnlockEnabled: Bool
    @Published var autoTurnOnThreshold: Double
    @Published var connectOnlyWhenNear: Bool
    @Published var nearbyModeEnabled: Bool
    @Published var isDebugModeEnabled: Bool
    @Published var notificationsEnabled: Bool

    // Granular notification toggles
    @Published var notifyOnConnected: Bool
    @Published var notifyOnDisconnected: Bool
    @Published var notifyOnStandby: Bool
    @Published var notifyOnAutoTurnOn: Bool
    
    // Battery Notification toggles
    @Published var notifyOnBatteryFull: Bool
    @Published var notifyOnChargeDisconnect: Bool
    @Published var notifyOnBatteryThreshold: Bool
    @Published var batteryLowThreshold: Double
    
    @Published var isConnected: Bool = false
    @Published var isSyncingTime: Bool = false
    @Published var skipProximityToken: Bool
    @Published var redactFrameNumber: Bool
    @Published var isLoggingEnabled: Bool
    @Published var verboseLoggingEnabled: Bool
    
    @Published var bikeInfo = IoTVehicleInfo()
    @Published var logs: [BLELogEntry] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init(core: DatBikeCore, preferences: PreferencesManager) {
        self.core = core
        self.preferences = preferences
        
        self.rssiThreshold = preferences.rssiThreshold
        self.autoUnlockEnabled = preferences.autoUnlockEnabled
        self.autoTurnOnThreshold = preferences.autoTurnOnThreshold
        self.connectOnlyWhenNear = preferences.connectOnlyWhenNear
        self.nearbyModeEnabled = preferences.nearbyModeEnabled
        self.isDebugModeEnabled = preferences.isDebugModeEnabled
        self.notificationsEnabled = preferences.notificationsEnabled
        self.notifyOnConnected    = preferences.notifyOnConnected
        self.notifyOnDisconnected = preferences.notifyOnDisconnected
        self.notifyOnStandby      = preferences.notifyOnStandby
        self.notifyOnAutoTurnOn   = preferences.notifyOnAutoTurnOn
        
        self.notifyOnBatteryFull      = preferences.notifyOnBatteryFull
        self.notifyOnChargeDisconnect = preferences.notifyOnChargeDisconnect
        self.notifyOnBatteryThreshold = preferences.notifyOnBatteryThreshold
        self.batteryLowThreshold      = Double(preferences.batteryLowThreshold)
        self.skipProximityToken        = preferences.skipProximityToken
        self.redactFrameNumber         = preferences.redactFrameNumber
        self.isLoggingEnabled          = preferences.isLoggingEnabled
        self.verboseLoggingEnabled     = preferences.verboseLoggingEnabled
        
        setupBindings()
    }
    
    private func setupBindings() {
        // Đồng bộ 2 chiều: Khi gạt toggle trên Màn hình, nó đẩy thẳng vào Singleton Preferences
        $rssiThreshold
            .dropFirst()
            .sink { [weak self] val in
                guard let self = self else { return }
                self.preferences.rssiThreshold = val
                // Ngưỡng bật xe phải GẦN HƠN (lớn hơn) ngưỡng kết nối
                if self.autoTurnOnThreshold < val {
                    self.autoTurnOnThreshold = val
                }
            }
            .store(in: &cancellables)
            
        $autoUnlockEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.autoUnlockEnabled = val }
            .store(in: &cancellables)
            
        $autoTurnOnThreshold
            .dropFirst()
            .sink { [weak self] val in
                guard let self = self else { return }
                self.preferences.autoTurnOnThreshold = val
                // Ngưỡng kết nối phải XA HƠN (nhỏ hơn) hoặc bằng ngưỡng bật xe
                if val < self.rssiThreshold {
                    self.rssiThreshold = val
                }
            }
            .store(in: &cancellables)
            
        $connectOnlyWhenNear
            .dropFirst()
            .sink { [weak self] val in self?.preferences.connectOnlyWhenNear = val }
            .store(in: &cancellables)
        
        $nearbyModeEnabled
            .dropFirst()
            .sink { [weak self] val in
                guard let self = self else { return }
                self.preferences.nearbyModeEnabled = val
                // ═══ ĐỒNG BỘ State Machine với DatBikeCore ═══
                // Nếu chỉ lưu preference mà không gọi DatBikeCore,
                // state machine vẫn kẹt ở trạng thái cũ (.nearby hoặc .active)
                // → vuốt tắt mở lại vẫn bị ảnh hưởng bởi state cũ.
                if val {
                    self.core.activateNearbyMode()
                } else {
                    self.core.connectFromNearby()
                }
            }
            .store(in: &cancellables)
            
        $isDebugModeEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.isDebugModeEnabled = val }
            .store(in: &cancellables)
            
        $notificationsEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notificationsEnabled = val }
            .store(in: &cancellables)

        $notifyOnConnected
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnConnected = val }
            .store(in: &cancellables)
        
        $notifyOnDisconnected
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnDisconnected = val }
            .store(in: &cancellables)
        
        $notifyOnStandby
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnStandby = val }
            .store(in: &cancellables)
        
        $notifyOnAutoTurnOn
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnAutoTurnOn = val }
            .store(in: &cancellables)
            
        $notifyOnBatteryFull
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnBatteryFull = val }
            .store(in: &cancellables)
            
        $notifyOnChargeDisconnect
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnChargeDisconnect = val }
            .store(in: &cancellables)
            
        $notifyOnBatteryThreshold
            .dropFirst()
            .sink { [weak self] val in self?.preferences.notifyOnBatteryThreshold = val }
            .store(in: &cancellables)
            
        $batteryLowThreshold
            .dropFirst()
            .sink { [weak self] val in self?.preferences.batteryLowThreshold = Int(val) }
            .store(in: &cancellables)
        
        $skipProximityToken
            .dropFirst()
            .sink { [weak self] val in self?.preferences.skipProximityToken = val }
            .store(in: &cancellables)
        
        $redactFrameNumber
            .dropFirst()
            .sink { [weak self] val in self?.preferences.redactFrameNumber = val }
            .store(in: &cancellables)
        
        $isLoggingEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.isLoggingEnabled = val }
            .store(in: &cancellables)
        
        $verboseLoggingEnabled
            .dropFirst()
            .sink { [weak self] val in self?.preferences.verboseLoggingEnabled = val }
            .store(in: &cancellables)
        
        core.$currentVehicleInfo
            .receive(on: DispatchQueue.main)
            .assign(to: \.bikeInfo, on: self)
            .store(in: &cancellables)
        
        core.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = state.isConnected // true cho cả .active và .standby
            }
            .store(in: &cancellables)
    }
    
    func forgetBike() {
        core.forgetBike()
    }
    
    func syncTime() {
        guard let dispatcher = try? core.getDispatcher() else { return }
        Task {
            try? await dispatcher.syncTime()
        }
    }
    
    // Developer Utils
    func deleteAllRecords() {
        // ...
    }
}
