// DBikeSmartkeyApp.swift — App entry point

import SwiftUI


class AppDelegate: NSObject, UIApplicationDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PersistentLogger.shared.markSessionStart()
        let isBackgroundLaunch = launchOptions?[.bluetoothCentrals] != nil
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[APP_LAUNCH] isBackground=\(isBackgroundLaunch) | launchOptions=\(launchOptions?.keys.map(\.rawValue) ?? [])"))
        
        // ═══ CRITICAL: Khởi tạo CBCentralManager NGAY khi app launch ═══
        // Khi iOS relaunch app trong background (State Restoration),
        // CBCentralManager PHẢI được tạo với CÙNG RestoreIdentifierKey
        // để iOS gọi willRestoreState → kết nối lại BLE.
        let preferences = PreferencesManager.shared
        let hasSavedBike = preferences.savedPin != nil || preferences.savedPeripheralUUID != nil
        if UserDefaults.standard.bool(forKey: "disclaimerAccepted") && hasSavedBike {
            DatBikeCore.shared.initializeBluetoothHardware()
        }
        
        return true
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
            message: "[LIFECYCLE] App bị vuốt tắt (Terminated by User/OS). Các tính năng BLE nền có thể bị hạn chế cho đến khi mở lại."))
    }
}

// MARK: - App

@main
struct DBikeSmartkeyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) var scenePhase
    
    @StateObject private var container = AppDIContainer()
    @State private var showingBLEScanner = false
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(container) // Truyền ngang dọc từ gốc
                .onAppear { }
                .onOpenURL { url in
                    handleDeepLink(url)
                }
                .sheet(isPresented: $showingBLEScanner) {
                    NavigationView {
                        BLEAdvertisementDebugView()
                            .toolbar {
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("Đóng") { showingBLEScanner = false }
                                }
                            }
                    }
                    .navigationViewStyle(.stack)
                }
                .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .active:
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[LIFECYCLE] App chuyển sang Foreground Active (Đang mở trên màn hình)"))
                    case .background:
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info, message: "[LIFECYCLE] App ẩn xuống chạy ngầm (Background) - Hệ điều hành có thể tạm dừng App"))
                    case .inactive:
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .verbose, message: "[LIFECYCLE] App vào trạng thái Inactive (Đang chuyển đổi/Mở Control Center)"))
                    @unknown default:
                        break
                    }
                }
        }
    }

    private func handleDeepLink(_ url: URL) {
        guard let scheme = url.scheme, ["mybikesmartkey", "dsmartkey", "dsmartkeylite"].contains(scheme) else { return }
        switch url.host {
        case "debug" where url.path == "/ble-scanner":
            showingBLEScanner = true
        case "lock":      
            container.bleCore.suspendAutoFeatures()
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.toggleLock(currentState: self.container.dashboardViewModel.lockState) }
            }
        case "unlock":    
            container.bleCore.suspendAutoFeatures()
            if let dispatcher = try? container.bleCore.getDispatcher() {
                Task { try? await dispatcher.turnOnBike() }
            }
        case "connect":
            // §4.5 (P3): deep-link connect là hành động CHỦ ĐỘNG của user —
            // nếu đang manualOnly thì THOÁT manualOnly rồi kết nối (quyết định #1).
            if container.bleCore.isManualOnly {
                container.bleCore.connectForRide()
            } else {
                container.bleCore.wakeUpFromStandby()
            }
        case "disconnect": container.dashboardViewModel.forceStandby()
        case "dashboard": break  // app mở bình thường
        default:          break
        }
    }
    
}
