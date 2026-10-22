// BatteryViewModel.swift — ViewModel cho màn hình BMS Analytics

import Foundation
import Combine

@MainActor
class BatteryViewModel: ObservableObject {
    
    private let core: DatBikeCore
    private var cancellables = Set<AnyCancellable>()
    
    // Outputs
    @Published var battery: BatteryTelemetry?
    @Published var isLoading = false
    @Published var lastUpdated: Date?
    @Published var isConnected: Bool = false
    
    init(core: DatBikeCore) {
        self.core = core
        setupBindings()
    }
    
    private func setupBindings() {
        core.$currentBatteryTelemetry
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bat in
                self?.battery = bat
                if bat != nil {
                    self?.lastUpdated = Date()
                    self?.isLoading = false
                }
            }
            .store(in: &cancellables)
        
        core.connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnected = state.isConnected
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Actions
    
    func refresh() {
        isLoading = true
        core.queryBatteryDetail()
        
        // Timeout: tắt loading sau 8s nếu không nhận được data
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.isLoading = false
        }
    }
    
    // MARK: - Computed Display Values
    
    var socPercent: Int { battery?.socPercent ?? 0 }
    var healthPercent: Int { battery?.healthPercent ?? 100 }
    var cycleCount: Int { battery?.cycleCount ?? 0 }
    var powerWatts: Double { battery?.powerWatts ?? 0 }
    var voltage: Double { battery?.voltage ?? 0 }
    var current: Double { battery?.current ?? 0 }
    var chargingState: BatteryChargingState { battery?.chargingState ?? .idle }
    var estimatedRange: Int { battery?.estimatedRangeKm ?? 0 }
    var odometer: Float { core.currentTelemetry.odometerKm }
    
    var avgTemp: Double? { battery?.avgTemp }
    var maxTemp: Double? { battery?.maxTemp }
    var minTemp: Double? { battery?.minTemp }
    var tempDelta: Double? { battery?.tempDelta }
    var ntcTemps: [Double] { battery?.NTCs ?? [] }
    
    // Cell voltages
    var cellVoltages: [Double] { battery?.cells ?? [] }
    var hasCellData: Bool { !cellVoltages.isEmpty }
    var cellCount: Int { cellVoltages.count }
    var avgCellVoltage: Double? {
        guard !cellVoltages.isEmpty else { return nil }
        return cellVoltages.reduce(0, +) / Double(cellVoltages.count)
    }
    var maxCellVoltage: Double? { cellVoltages.max() }
    var minCellVoltage: Double? { cellVoltages.min() }
    var cellVoltageDelta: Double? {
        guard let max = maxCellVoltage, let min = minCellVoltage else { return nil }
        return max - min
    }
    /// Cảnh báo cell imbalance nếu delta > 0.05V (50mV)
    var hasCellImbalance: Bool { (cellVoltageDelta ?? 0) > 0.05 }
    
    // Extra keys discovered (for debugging)
    var extraKeys: [String] { battery?.rawExtraKeys ?? [] }
    
    var hasHighTempWarning: Bool { battery?.hasHighTempWarning ?? false }
    var hasTempImbalanceWarning: Bool { battery?.hasTempImbalanceWarning ?? false }
    var hasAnyWarning: Bool { hasHighTempWarning || hasTempImbalanceWarning }
    
    var lastUpdatedText: String {
        guard let date = lastUpdated else { return "Chưa cập nhật" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Cập nhật: \(formatter.string(from: date))"
    }
}
