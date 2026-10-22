// SettingsView.swift — Settings, device info, auto-unlock config, and debug log

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var container: AppDIContainer
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showConnectionGuide = false
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Cài đặt ứng dụng")) {
                    NavigationLink(destination: MyBikeSettingsView(viewModel: viewModel).environmentObject(container)) {
                        HStack {
                            Image(systemName: "bicycle")
                                .foregroundColor(.cyan)
                                .frame(minWidth: 24)
                            Text("Xe của tôi")
                        }
                    }
                    
                    NavigationLink(destination: ConnectionSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.green)
                                .frame(minWidth: 24)
                            Text("Kết nối")
                        }
                    }
                    
                    NavigationLink(destination: NotificationSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "bell.badge.fill")
                                .foregroundColor(.orange)
                                .frame(minWidth: 24)
                            Text("Thông báo")
                        }
                    }
                    
                    NavigationLink(destination: DeveloperSettingsView(viewModel: viewModel)) {
                        HStack {
                            Image(systemName: "hammer.fill")
                                .foregroundColor(.purple)
                                .frame(minWidth: 24)
                            Text("Chế độ nhà phát triển")
                        }
                    }
                }
                
                
                Section(header: Text("Hỗ trợ"), footer: VStack(alignment: .leading, spacing: 4) {
                    Text("D-SmartKey v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    Text("Dự án độc lập, không liên kết với Dat Bike.")
                }) {
                    Button(action: {
                        showConnectionGuide = true
                    }) {
                        HStack {
                            Image(systemName: "book.pages.fill")
                                .foregroundColor(.blue)
                                .frame(minWidth: 24)
                            Text("Nguyên lý kết nối & Trạng thái")
                                .foregroundColor(.primary)
                        }
                    }
                    
                    Link(destination: URL(string: "mailto:dev@d-smartkey.io")!) {
                        HStack {
                            Image(systemName: "envelope.fill")
                                .foregroundColor(Color(red: 0.15, green: 0.68, blue: 0.93))
                                .frame(minWidth: 24)
                            Text("Liên hệ D-SmartKey")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    

                }
            }
            .navigationTitle("Cài đặt")
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showConnectionGuide) {
            ConnectionGuideView()
        }
    }
}

// MARK: - Connection Guide View
struct ConnectionGuideView: View {
    @Environment(\.presentationMode) var presentationMode
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("Hiểu về kết nối D-SmartKey")
                            .font(.title2).bold()
                            .foregroundColor(.white)
                        
                        guideSection(
                            icon: "magnifyingglass", iconColor: .blue,
                            title: "1. Đang tìm xe",
                            content: "Điện thoại đang liên tục quét các sóng Bluetooth Low Energy (BLE) xung quanh để phát hiện xe Dat Bike của bạn. Trạng thái này thường mất từ 1-3 giây mỗi khi mở app."
                        )
                        
                        guideSection(
                            icon: "point.3.connected.trianglepath.dotted", iconColor: .orange,
                            title: "2. Đang kết nối & Xác thực",
                            content: "Ứng dụng đã tìm thấy sóng của xe và tiến hành thiết lập liên kết an toàn."
                        )
                        
                        guideSection(
                            icon: "sensor.tag.radiowaves.forward", iconColor: .green,
                            title: "3. Ngưỡng tự động kết nối",
                            content: "Mặc định, khi xe phát hiện bạn trong phạm vi phát sóng đủ lớn của 'Ngưỡng kết nối', biểu tượng Bluetooth trên mặt đồng hồ xe sẽ sáng nháp báo hiệu sự kết nối vật lý đã sẵn sàng. Bạn càng kéo thanh này về phía 'Xa' (như -80), xe sẽ bắt sóng bạn càng sớm."
                        )
                        
                        guideSection(
                            icon: "bolt.fill", iconColor: .yellow,
                            title: "4. Ngưỡng tự động bật xe",
                            content: "Nếu bạn đã bật tính năng này, sau khi kết nối, hệ thống sẽ tiếp tục đợi. Chỉ khi bạn tiến lại đủ gần chạm trúng vào 'Ngưỡng bật xe' (như -60), ứng dụng mới xuất lệnh đánh thức và BẬT HỆ THỐNG ĐIỆN của xe hoàn toàn."
                        )
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Mẹo thiết lập")
                                .font(.headline).foregroundColor(.white)
                            Text("• Luôn giữ Ngưỡng bật xe ĐẬM (Gần) hơn Ngưỡng kết nối để tránh việc xe tự bật sáng khi bạn chỉ đang lướt ngang qua sân nhà.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .padding()
                    .padding(.top, 10)
                }
            }
            .navigationTitle("Trợ giúp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func guideSection(icon: String, iconColor: Color, title: String, content: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(iconColor)
                .frame(minWidth: 32)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(content)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .lineSpacing(2)
            }
        }
    }
}


struct MyBikeSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showBatteryAnalytics = false
    @State private var showForgetConfirm = false
    @EnvironmentObject var container: AppDIContainer
    
    var body: some View {
        Form {
            let hasSavedBike = PreferencesManager.shared.savedBikeSerial != nil && PreferencesManager.shared.savedBikeSerial?.isEmpty == false
            let isConnectedWithInfo = viewModel.isConnected && !viewModel.bikeInfo.isEmpty
            
            if isConnectedWithInfo || hasSavedBike {
                Section(header: Text("Thông tin cơ bản")) {
                    HStack {
                        Image(systemName: "bicycle")
                            .foregroundColor(.cyan)
                            .frame(minWidth: 24)
                        Text("Tên")
                        Spacer()
                        Text(isConnectedWithInfo ? viewModel.bikeInfo.name : (PreferencesManager.shared.savedBikeName ?? "Dat Bike"))
                            .foregroundColor(.gray)
                    }
                    
                    // Model — hiển thị từ BLE hoặc cache offline
                    let modelStr = isConnectedWithInfo ? viewModel.bikeInfo.model : (PreferencesManager.shared.savedBikeModel ?? "")
                    if !modelStr.isEmpty {
                        HStack {
                            Image(systemName: "cpu")
                                .foregroundColor(.cyan)
                                .frame(minWidth: 24)
                            Text("Model")
                            Spacer()
                            Text(modelStr)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    HStack {
                        Image(systemName: "number")
                            .foregroundColor(.cyan)
                            .frame(minWidth: 24)
                        Text("Số khung")
                        Spacer()
                        Text(isConnectedWithInfo ? viewModel.bikeInfo.serial : (PreferencesManager.shared.savedBikeSerial ?? ""))
                            .foregroundColor(.gray)
                    }
                    
                    // Firmware — hiển thị từ BLE hoặc cache offline
                    let fwStr = isConnectedWithInfo ? viewModel.bikeInfo.firmware : (PreferencesManager.shared.savedBikeFirmware ?? "")
                    if !fwStr.isEmpty {
                        HStack {
                            Image(systemName: "gearshape.fill")
                                .foregroundColor(.cyan)
                                .frame(minWidth: 24)
                            Text("Firmware")
                            Spacer()
                            Text(fwStr)
                                .foregroundColor(.gray)
                        }
                    }
                    
                    // MAC Address — hiển thị luôn nếu có (quan trọng cho ESP32 SmartKey)
                    if let macStr = PreferencesManager.shared.savedBikeMac, !macStr.isEmpty {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.cyan)
                                .frame(minWidth: 24)
                            Text("MAC")
                            Spacer()
                            Text(macStr)
                                .foregroundColor(.gray)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = macStr
                            } label: {
                                Label("Sao chép MAC", systemImage: "doc.on.doc")
                            }
                        }
                    }
                    
                    if isConnectedWithInfo && !viewModel.bikeInfo.deviceToken.isEmpty {
                        HStack {
                            Image(systemName: "key")
                                .foregroundColor(.cyan)
                                .frame(minWidth: 24)
                            Text("Token")
                            Spacer()
                            Text(String(viewModel.bikeInfo.deviceToken.prefix(16)) + "…")
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                    }
                    
                    if !viewModel.isConnected {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .frame(minWidth: 24)
                            Text("Trạng thái")
                            Spacer()
                            Text("Chưa kết nối")
                                .foregroundColor(.orange)
                        }
                    }
                }
                
                Section(header: Text("Quản lý")) {
                    if viewModel.isConnected {
                        Button {
                            showBatteryAnalytics = true
                        } label: {
                            HStack {
                                Image(systemName: "battery.100.bolt")
                                    .foregroundColor(.green)
                                    .frame(minWidth: 24)
                                Text("Phân tích Pin (BMS)")
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                    
                    Button {
                        viewModel.syncTime()
                    } label: {
                        HStack {
                            Image(systemName: "clock.fill")
                                .foregroundColor(.blue)
                                .frame(minWidth: 24)
                            Text(viewModel.isSyncingTime ? "Đang đồng bộ..." : "Đồng bộ giờ xe")
                                .foregroundColor(viewModel.isConnected ? .primary : .gray)
                            Spacer()
                            if viewModel.isSyncingTime {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!viewModel.isConnected || viewModel.isSyncingTime)
                }
                
                Section {
                    Button(role: .destructive) {
                        showForgetConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                                .frame(minWidth: 24)
                            Text("Bỏ liên kết xe")
                        }
                    }
                }
            } else {
                Text("Chưa có thông tin xe.")
                    .foregroundColor(.gray)
            }
        }
        .navigationTitle("Xe của tôi")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showBatteryAnalytics) {
            BatteryAnalyticsView(viewModel: container.batteryViewModel)
        }
        .alert("Bỏ liên kết xe", isPresented: $showForgetConfirm) {
            Button("Quên", role: .destructive) {
                viewModel.forgetBike()
            }
            Button("Hủy", role: .cancel) {}
        } message: {
            Text("Xóa kết nối App với xe. Bạn có muốn tiếp tục?")
        }
    }
}


struct ConnectionSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        Form {
            // ═══ §4.4 (P3): Trạng thái ý định kết nối + lối thoát manualOnly ═══
            Section(header: Text("Ý định kết nối"),
                    footer: Text("Khi đang ở chế độ thủ công (Tạm dừng / Ở gần xe, chưa dùng), app không tự kết nối lại bởi bất kỳ điều gì — kể cả mở app hay bật lại Bluetooth.")) {
                HStack {
                    Image(systemName: viewModel.isManualOnly ? "pause.circle.fill" : "bolt.badge.checkmark")
                        .foregroundColor(viewModel.isManualOnly ? .orange : .green)
                        .frame(minWidth: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.isManualOnly ? "Đang ở chế độ thủ công" : "Tự động kết nối")
                        Text(viewModel.isManualOnly
                             ? (viewModel.connectionIntent == .manualOnlyNearbyNotInUse
                                ? "Ở gần xe, chưa dùng — chờ bạn yêu cầu"
                                : "Đã tạm dừng — chờ bạn yêu cầu")
                             : "App sẽ tự kết nối khi ở gần xe")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
                if viewModel.isManualOnly {
                    Button {
                        viewModel.connectForRide()
                    } label: {
                        Text("Kết nối để dùng xe")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Kết nối để dùng xe")
                } else {
                    // §4.4 (P3): chỉ dẫn đúng cách ngừng hẳn auto-connect —
                    // công tắc "Chỉ kết nối khi ở gần" bên dưới KHÔ phải on/off của auto-connect.
                    Label {
                        Text("Muốn ngừng hẳn tự động kết nối? Dùng nút \"Ở gần xe, chưa dùng\" (icon người đứng) trên màn hình chính.")
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "figure.stand")
                            .foregroundColor(.cyan)
                    }
                }
            }

            Section(header: Text("Chế độ gần xe"),
                    footer: Text("Khi bật, app chỉ phát hiện xe gần mà KHÔNG tự kết nối hay bật xe. Mở app khi muốn sử dụng. Tiết kiệm pin.")) {
                Toggle(isOn: $viewModel.nearbyModeEnabled) {
                    HStack {
                        Image(systemName: "location.circle.fill")
                            .foregroundColor(.blue)
                            .frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chỉ phát hiện gần xe")
                            Text("Không tự kết nối, tiết kiệm pin")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.blue)
            }
            
            // §UX-fix: nhãn cũ "Ngưỡng tự động kết nối" gây hiểu nhầm là on/off của
            // auto-connect — thực chất là chọn CHẾ ĐỘ (gần xe vs mọi lúc). Đổi tên rõ nghĩa.
            Section(header: Text("Cách thức tự động kết nối"),
                    footer: Text("Bật: app chờ ở trạng thái standby và chỉ xác thực khi bạn ở gần xe theo ngưỡng dưới đây. Tắt: app tự kết nối và xác thực ngay bất kể khoảng cách. Tự bật xe chỉ hoạt động khi bật chế độ này.")) {
                Toggle(isOn: $viewModel.connectOnlyWhenNear) {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward")
                            .foregroundColor(.green)
                            .frame(minWidth: 24)
                        Text("Chỉ kết nối khi ở gần xe")
                    }
                }
                .tint(.green)
                .disabled(viewModel.nearbyModeEnabled)
                
                if viewModel.connectOnlyWhenNear && !viewModel.nearbyModeEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Độ nhạy: ")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("\(Int(viewModel.rssiThreshold)) dBm")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(viewModel.rssiThreshold >= -65 ? "Gần" : (viewModel.rssiThreshold >= -75 ? "Vừa" : "Xa"))
                                .font(.caption2)
                                .foregroundColor(viewModel.rssiThreshold >= -65 ? .green : (viewModel.rssiThreshold >= -75 ? .orange : .red))
                        }
                        Slider(value: $viewModel.rssiThreshold, in: -95...(-50), step: 1.0)
                            .tint(.green)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section(header: Text("Tự động bật xe"), footer: Text("Khi đã kết nối, nếu đạt ngưỡng này và xe đang tắt thì tự động bật lên. Chỉ hoạt động khi \"Chỉ kết nối khi ở gần xe\" đang bật.")) {
                Toggle(isOn: $viewModel.autoUnlockEnabled) {
                    HStack {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.orange)
                            .frame(minWidth: 24)
                        Text("Ngưỡng tự động bật xe")
                    }
                }
                .tint(.orange)
                .disabled(viewModel.nearbyModeEnabled)
                
                if viewModel.autoUnlockEnabled && !viewModel.nearbyModeEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Độ nhạy: ")
                                .font(.caption)
                                .foregroundColor(.gray)
                            Text("\(Int(viewModel.autoTurnOnThreshold)) dBm")
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(viewModel.autoTurnOnThreshold >= -60 ? "Gần" : (viewModel.autoTurnOnThreshold >= -70 ? "Vừa" : "Xa"))
                                .font(.caption2)
                                .foregroundColor(viewModel.autoTurnOnThreshold >= -60 ? .green : (viewModel.autoTurnOnThreshold >= -70 ? .orange : .red))
                        }
                        Slider(value: $viewModel.autoTurnOnThreshold, in: -90...(-40), step: 1.0)
                            .tint(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Kết nối")
        .navigationBarTitleDisplayMode(.inline)
    }
}


struct DeveloperSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showLogs = false
    
    var body: some View {
        Form {
            Section(header: Text("Chẩn đoán BLE")) {
                NavigationLink(destination: BLEAdvertisementDebugView()) {
                    Label("Quét quảng bá BLE", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
            Section(header: Text("Nhật ký hệ thống")) {
                Button {
                    showLogs = true
                } label: {
                    HStack {
                        Image(systemName: "list.bullet.rectangle.portrait")
                            .foregroundColor(.blue)
                            .frame(minWidth: 24)
                        Text("Xem nhật ký đầy đủ (Full Logs)")
                            .foregroundColor(.primary)
                    }
                }
                
                Toggle(isOn: $viewModel.isLoggingEnabled) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                            .foregroundColor(.purple)
                            .frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cho phép log chi tiết")
                            Text("Nhật ký kết nối, lệnh và lỗi luôn được lưu. Công tắc này chỉ cho phép ghi thêm chi tiết debug.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.purple)
                
                Toggle(isOn: $viewModel.verboseLoggingEnabled) {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.indigo)
                            .frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Log chi tiết (Verbose)")
                            Text("Ghi thêm RSSI mỗi 2s, STANDBY_CHECK... Chỉ bật khi cần debug sâu.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.indigo)
                .disabled(!viewModel.isLoggingEnabled)
            }
            
            Section(header: Text("Bảo mật log"), footer: Text("Ẩn số khung, serial, MAC và manufacturer data khi sao chép hoặc chia sẻ log. Mặc định BẬT.")) {
                Toggle(isOn: $viewModel.redactFrameNumber) {
                    HStack {
                        Image(systemName: "eye.slash.fill")
                            .foregroundColor(.mint)
                            .frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ẩn định danh xe trong log")
                            Text("Bảo vệ quyền riêng tư khi gửi log cho nhà phát triển.")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                }
                .tint(.mint)
            }
            
            Section(header: Text("Nâng cao"), footer: Text("Không gửi token lân cận khi xác thực (dùng khi test ASK)")) {
                Toggle(isOn: $viewModel.skipProximityToken) {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundColor(.orange)
                            .frame(minWidth: 24)
                        Text("Bỏ qua Proximity Token")
                    }
                }
                .tint(.orange)
            }
        }
        .navigationTitle("Nhà phát triển")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) {
            LogView(logs: PersistentLogger.shared.loadLogs(daysBack: 1))
        }
    }
}


struct NotificationSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    
    var body: some View {
        Form {
            Section(header: Text("Chung"), footer: Text("Bật/tắt toàn bộ thông báo của app")) {
                Toggle(isOn: $viewModel.notificationsEnabled) {
                    HStack {
                        Image(systemName: "bell.badge.fill")
                            .foregroundColor(.orange)
                            .frame(minWidth: 24)
                        Text("Thông báo hệ thống")
                    }
                }
                .tint(.orange)
            }
            
            if viewModel.notificationsEnabled {
                Section(header: Text("Loại thông báo")) {
                    notificationSubToggle(
                        icon: "checkmark.circle.fill", iconColor: .green,
                        title: "Kết nối thành công", subtitle: "Khi xác thực BLE hoàn tất",
                        binding: $viewModel.notifyOnConnected
                    )
                    notificationSubToggle(
                        icon: "figure.walk", iconColor: .cyan,
                        title: "Gần xe — Kết nối chờ", subtitle: "Khi phát hiện di chuyển gần xe",
                        binding: $viewModel.notifyOnStandby
                    )
                    notificationSubToggle(
                        icon: "arrow.uturn.backward.circle.fill", iconColor: .yellow,
                        title: "Ra xa xe — Chuyển chờ", subtitle: "Khi phát hiện di chuyển ra xa",
                        binding: $viewModel.notifyOnDisconnected
                    )
                    notificationSubToggle(
                        icon: "bolt.fill", iconColor: .orange,
                        title: "Tự động bật xe", subtitle: "Khi Auto Turn-On được kích hoạt",
                        binding: $viewModel.notifyOnAutoTurnOn
                    )
                    notificationSubToggle(
                        icon: "battery.100.bolt", iconColor: .green,
                        title: "Sạc đầy pin", subtitle: "Khi pin đạt 100%",
                        binding: $viewModel.notifyOnBatteryFull
                    )
                    notificationSubToggle(
                        icon: "bolt.slash.fill", iconColor: .red,
                        title: "Ngắt sạc bất ngờ", subtitle: "Báo động khi mất sạc lúc xe tắt",
                        binding: $viewModel.notifyOnChargeDisconnect
                    )
                    notificationSubToggle(
                        icon: "battery.25", iconColor: .orange,
                        title: "Cảnh báo pin yếu", subtitle: "Khi pin giảm xuống dưới ngưỡng",
                        binding: $viewModel.notifyOnBatteryThreshold
                    )
                    
                    if viewModel.notifyOnBatteryThreshold {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Ngưỡng cảnh báo: ")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                                Text("\(Int(viewModel.batteryLowThreshold))%")
                                    .font(.system(.caption, design: .monospaced))
                                Spacer()
                            }
                            Slider(value: $viewModel.batteryLowThreshold, in: 5...50, step: 1.0)
                                .tint(.orange)
                        }
                        .padding(.vertical, 4)
                        .animation(.easeInOut, value: viewModel.notifyOnBatteryThreshold)
                    }
                }
            }
        }
        .navigationTitle("Thông báo")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func notificationSubToggle(icon: String, iconColor: Color, title: String, subtitle: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
        }
        .tint(iconColor)
    }
}

// MARK: - Log View

struct LogView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State var logs: [BLELogEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false
    @State private var showShareSheet = false
    @State private var shareURL: URL? = nil
    
    init(logs: [BLELogEntry]) {
        self._logs = State(initialValue: logs)
    }
    
    /// Hiển thị toàn bộ nhật ký theo yêu cầu
    private var filteredLogs: [BLELogEntry] {
        return logs
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(red: 0.04, green: 0.04, blue: 0.08)
                    .ignoresSafeArea()
                
                if filteredLogs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("Chưa có log")
                            .foregroundColor(.gray)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredLogs.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    (dynamicTypeSize.isAccessibilitySize
                                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                                        : AnyLayout(HStackLayout(spacing: 6))) {
                                    Text(dynamicTypeSize.isAccessibilitySize
                                        ? entry.formattedTime.replacingOccurrences(of: ".", with: "\n.")
                                        : entry.formattedTime)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.gray)
                                        .fixedSize(horizontal: false, vertical: true)
                                    
                                    Text(entry.level.rawValue)
                                        .font(.caption)
                                    }
                                    
                                    Text(entry.message)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.85))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 3)
                                .contextMenu {
                                    Button {
                                        UIPasteboard.general.string = PersistentLogger.shared.textForSharing(
                                            "[\(entry.formattedTime)] \(entry.level.rawValue) \(entry.message)",
                                            redactIdentifiers: PreferencesManager.shared.redactFrameNumber)
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        var fullString = filteredLogs.reversed().map { "[\($0.formattedTime)] \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
                        fullString = PersistentLogger.shared.textForSharing(fullString,
                            redactIdentifiers: PreferencesManager.shared.redactFrameNumber)
                        UIPasteboard.general.string = fullString
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    
                    Button {
                        let redact = PreferencesManager.shared.redactFrameNumber
                        let text = PersistentLogger.shared.exportAllAsText(redactFrameNumber: redact)
                        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("datbike_ble_logs.txt")
                        try? text.write(to: tempFile, atomically: true, encoding: .utf8)
                        shareURL = tempFile
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    
                    Button("Đóng") { dismiss() }
                        .foregroundColor(.blue)
                }
            }
            .alert("Xóa toàn bộ Log?", isPresented: $showClearConfirm) {
                Button("Xóa", role: .destructive) {
                    PersistentLogger.shared.clearAll()
                    logs.removeAll()
                }
                Button("Hủy", role: .cancel) {}
            } message: {
                Text("Hành động này sẽ xóa vĩnh viễn toàn bộ lịch sử kết nối lưu trên máy.")
            }
            .background(
                ActivityViewPresenter(isPresented: $showShareSheet, activityItems: [shareURL].compactMap { $0 })
            )
        }
        .navigationViewStyle(.stack)
        .preferredColorScheme(.dark)
    }
}

struct ActivityViewPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var activityItems: [Any]
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let isActivityShown = uiViewController.presentedViewController is UIActivityViewController
        
        if isPresented && !isActivityShown {
            let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            controller.completionWithItemsHandler = { _, _, _, _ in
                self.isPresented = false
            }
            
            if let popover = controller.popoverPresentationController {
                popover.sourceView = uiViewController.view
                popover.sourceRect = CGRect(x: uiViewController.view.bounds.midX, y: uiViewController.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            
            uiViewController.present(controller, animated: true)
        }
    }
}

// MARK: - Live Time Text
struct LiveTimeText: View {
    @State private var currentTime = Date()
    
    var body: some View {
        Text(currentVNTimeString(currentTime))
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.gray)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { input in
                currentTime = input
            }
    }
    
    private func currentVNTimeString(_ date: Date) -> String {
        let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let formatter = DateFormatter()
        formatter.timeZone = vnTZ
        formatter.dateFormat = "HH:mm:ss (dd/MM/yyyy)"
        return formatter.string(from: date)
    }
}
