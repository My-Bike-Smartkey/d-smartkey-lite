import XCTest
import SwiftUI
@testable import D_SmartKey

/// Render UI thật với dữ liệu giả; không khởi tạo Bluetooth hoặc gửi lệnh xe.
/// Ảnh đính kèm xcresult phục vụ kiểm tra trực quan, không thay thế test chạm/cuộn.
@MainActor
final class LayoutSnapshotTests: XCTestCase {
    func testPortraitWidthsAndAccessibilityText() throws {
        let container = AppDIContainer()
        _ = container.settingsViewModel
        _ = container.batteryViewModel
        // Drain Combine's initial delivery before supplying synthetic screen data.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let vm = container.dashboardViewModel
        vm.connectionState = .active
        vm.lockState = .locked
        vm.bikeInfo.name = "Ngựa sắt — tên xe dài để kiểm tra bố cục"
        vm.telemetry.soc = 85
        vm.telemetry.motorTemp = 35
        vm.telemetry.odometerKm = 12345
        let batteryJSON = #"{"voltage":72.4,"current":1.2,"soc":{"soc":0.85,"cycles":123},"NTCs":[30,31],"cellVols":[3.65,3.66,3.64,3.65]}"#
        container.batteryViewModel.battery = try JSONDecoder().decode(BatteryTelemetry.self, from: Data(batteryJSON.utf8))
        let sizes: [(String, CGSize, DynamicTypeSize)] = [
            ("320", CGSize(width: 320, height: 568), .large),
            ("375", CGSize(width: 375, height: 667), .large),
            ("390", CGSize(width: 390, height: 844), .large),
            ("440", CGSize(width: 440, height: 956), .large),
            ("375-AX", CGSize(width: 375, height: 667), .accessibility3),
            ("320-AX5", CGSize(width: 320, height: 568), .accessibility5)
        ]
        for (name, size, typeSize) in sizes {
            try snapshot("dashboard-\(name)", view: DashboardView(viewModel: vm), container: container, size: size, typeSize: typeSize)
            vm.connectionState = .pairingRequired
            try snapshot("pairing-\(name)", view: ConnectingSplashView(dashboardVM: vm, settingsVM: container.settingsViewModel,
                showingSettings: .constant(false), showingLogs: .constant(false), showingNFCPrompt: .constant(false)),
                container: container, size: size, typeSize: typeSize)
            vm.connectionState = .active
            try snapshot("settings-\(name)", view: SettingsView(viewModel: container.settingsViewModel), container: container, size: size, typeSize: typeSize)
            try snapshot("battery-\(name)", view: BatteryAnalyticsView(viewModel: container.batteryViewModel), container: container, size: size, typeSize: typeSize)
            try snapshot("logs-\(name)", view: LogView(logs: [BLELogEntry(timestamp: Date(), level: .warning,
                message: "[CYCLE] sid=demo outcome=fail stage=auth — nhật ký dài để kiểm tra xuống dòng trên màn hình nhỏ")]),
                container: container, size: size, typeSize: typeSize)
            try snapshot("ble-debug-\(name)", view: BLEAdvertisementDebugView(),
                container: container, size: size, typeSize: typeSize)
        }
    }

    private func snapshot<V: View>(_ name: String, view: V, container: AppDIContainer,
                                    size: CGSize, typeSize: DynamicTypeSize) throws {
        let host = UIHostingController(rootView: view.environmentObject(container)
            .environment(\.dynamicTypeSize, typeSize).preferredColorScheme(.dark))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let scrollViews = descendants(of: host.view).compactMap { $0 as? UIScrollView }
        for scroll in scrollViews where scroll.bounds.width > 0 {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1,
                "\(name): vertical content must not overflow horizontally")
        }
        try saveImage(name, host: host, size: size)
        if let scroll = scrollViews.first(where: { $0.contentSize.height > $0.bounds.height + 1 }) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
            host.view.layoutIfNeeded()
            try saveImage(name + "-bottom", host: host, size: size)
        }
        window.isHidden = true
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func saveImage(_ name: String, host: UIViewController, size: CGSize) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mybike-layout-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        print("LAYOUT_SNAPSHOT \(directory.path)/\(name).png")
        XCTAssertEqual(image.size, size)
    }
}
