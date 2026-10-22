import Foundation
import Combine

/// Container Chứa toàn bộ các Service Cấp Cao.
/// Các ViewModel và Màn hình chỉ nhận Dependency từ đây.
@MainActor
class AppDIContainer: ObservableObject {
    
    // Core Services
    let bleCore: DatBikeCore
    let preferences: PreferencesManager
    
    // ViewModels
    lazy var dashboardViewModel: DashboardViewModel = {
        DashboardViewModel(core: bleCore, preferences: preferences)
    }()
    
    lazy var settingsViewModel: SettingsViewModel = {
        SettingsViewModel(core: bleCore, preferences: preferences)
    }()
    
    lazy var batteryViewModel: BatteryViewModel = {
        BatteryViewModel(core: bleCore)
    }()
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        self.bleCore = DatBikeCore.shared
        self.preferences = PreferencesManager.shared
        
        // Forward dashboardViewModel.objectWillChange → container.objectWillChange
        // Để MainView (observe container) re-render khi connectionState thay đổi
        dashboardViewModel.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}
