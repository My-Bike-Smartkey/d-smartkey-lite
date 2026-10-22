// MainView.swift — Tab container

import SwiftUI
import Combine

struct MainView: View {
    @EnvironmentObject var container: AppDIContainer
    @State private var showingSettings = false
    @State private var showingLogs = false
    @State private var showingNFCPrompt = false
    @State private var showingDisclaimer = false
    
    var body: some View {
        Group {
            if container.dashboardViewModel.isConnected {
                DashboardView(viewModel: container.dashboardViewModel)
                    .transition(.opacity)
            } else {
                ConnectingSplashView(
                    dashboardVM: container.dashboardViewModel,
                    settingsVM: container.settingsViewModel,
                    showingSettings: $showingSettings,
                    showingLogs: $showingLogs,
                    showingNFCPrompt: $showingNFCPrompt
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: container.dashboardViewModel.isConnected)
        .preferredColorScheme(.dark)
        .onAppear {
            if !UserDefaults.standard.bool(forKey: "disclaimerAccepted") {
                NotificationManager.shared.requestPermission {
                    showingDisclaimer = true
                }
            } else {
                #if NOASK
                // Lite (foreground-only): BLE khởi động NGAY — không chờ callback
                // quyền notification (lần đầu phải trả lời dialog → chậm mở app).
                // Xin quyền notification song song, không chặn.
                container.dashboardViewModel.initializeHardware()
                if PreferencesManager.shared.savedPin != nil || PreferencesManager.shared.savedPeripheralUUID != nil {
                    container.dashboardViewModel.connectBike()
                }
                NotificationManager.shared.requestPermission { }
                #else
                NotificationManager.shared.requestPermission {
                    container.dashboardViewModel.initializeHardware()
                    // Auto-connect nếu đã pair trước đó
                    if PreferencesManager.shared.savedPin != nil || PreferencesManager.shared.savedPeripheralUUID != nil {
                        container.dashboardViewModel.connectBike()
                    }
                }
                #endif
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: container.settingsViewModel)
        }
        .alert("Miễn trừ trách nhiệm", isPresented: $showingDisclaimer) {
            Button("Tôi đã hiểu và đồng ý") {
                UserDefaults.standard.set(true, forKey: "disclaimerAccepted")
                container.dashboardViewModel.initializeHardware()
                
                // Chỉ tự động connect nếu người dùng đã từng Add xe (có Pin/UUID cũ).
                // Nếu là lần đầu cài app trắng, sẽ đợi người dùng tự bấm nút (+) Thêm Xe
                if PreferencesManager.shared.savedPin != nil || PreferencesManager.shared.savedPeripheralUUID != nil {
                    container.dashboardViewModel.connectBike()
                }
            }
        } message: {
            Text("""
            Ứng dụng này được phát triển bởi bên thứ ba, KHÔNG liên kết với Dat Bike hoặc bất kỳ nhà sản xuất xe nào.

            Chỉ sử dụng trên xe thuộc sở hữu hợp pháp của chính bạn. Ứng dụng không xác minh quyền sở hữu xe.

            • Chỉ thử lệnh khi xe dừng ở nơi an toàn; luôn giữ thẻ/chìa khóa vật lý.
            • Tự đánh giá rủi ro khi cài đặt, sửa mã hoặc điều khiển xe qua Bluetooth.
            • Phần mềm cung cấp theo hiện trạng, không bảo đảm an toàn, bảo mật hay chống trộm.
            • Miễn trừ trách nhiệm trong phạm vi pháp luật cho phép; không loại trừ quyền và trách nhiệm bắt buộc.
            • Không sử dụng ứng dụng cho mục đích trái pháp luật.
            """)
        }
        .alert("Xác nhận ghép đôi", isPresented: $showingNFCPrompt) {
            Button("Hủy", role: .cancel) {
                // Do nothing
            }
            Button("Bắt đầu ghép đôi") {
                // Trì hoãn 0.5s để hộp thoại (Alert) kịp đóng lại hoàn toàn.
                // Tránh lỗi "Application is not in foreground" của AccessorySetupKit trên iOS 18.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    container.dashboardViewModel.startPairing()
                }
            }
        } message: {
            Text("Đảm bảo thẻ NFC đã được đặt sẵn trên mặt đồng hồ xe. Bấm xác nhận để bắt đầu tìm xe và ghép đôi Bluetooth.")
        }
    }
}

// MARK: - Connecting Splash View

struct ConnectingSplashView: View {
    @ObservedObject var dashboardVM: DashboardViewModel
    @ObservedObject var settingsVM: SettingsViewModel
    @Binding var showingSettings: Bool
    @Binding var showingLogs: Bool
    @Binding var showingNFCPrompt: Bool
    
    @State private var pulsePhase: CGFloat = 0
    /// §4.4 (P3): confirm trước khi bật "Ở gần xe, chưa dùng" khi xe đang mở.
    @State private var showingNearbyNotInUseConfirm = false
    
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            // Background — tĩnh, không xoay
            Color(red: 0.05, green: 0.05, blue: 0.08)
                .ignoresSafeArea()
            
            // Header: hidden settings button
            VStack {
                HStack {
                    Spacer()
                    
                    if dashboardVM.connectionState == .active {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.forceStandby()
                        }) {
                            Image(systemName: "wifi.slash")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.vertical)
                        }
                    }
                    
                    // Nút bật/tắt chế độ "Đang ở gần"
                    if dashboardVM.connectionState == .active || dashboardVM.connectionState == .standby {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.activateNearbyMode()
                        }) {
                            Image(systemName: "location.circle")
                                .font(.system(size: 20))
                                .foregroundColor(.blue.opacity(0.6))
                                .padding(.vertical)
                        }
                    } else if case .nearby = dashboardVM.connectionState {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            dashboardVM.deactivateNearbyMode()
                        }) {
                            Image(systemName: "location.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.blue)
                                .padding(.vertical)
                        }
                    }
                    
                    // Nút "Ở gần xe, chưa dùng" (§4.4) — cùng hàng với nút Nearby
                    if !dashboardVM.isPaused,
                       dashboardVM.connectionState == .active || dashboardVM.connectionState == .standby {
                        Button(action: {
                            let generator = UIImpactFeedbackGenerator(style: .medium)
                            generator.impactOccurred()
                            // Xe đang mở/bật → xác nhận để tránh khoá nhầm lúc vừa chạy
                            if !dashboardVM.lockState.isLocked {
                                showingNearbyNotInUseConfirm = true
                            } else {
                                dashboardVM.setNearbyNotInUse()
                            }
                        }) {
                            Image(systemName: "figure.stand")
                                .font(.system(size: 20))
                                .foregroundColor(.cyan.opacity(0.7))
                                .padding(.vertical)
                        }
                        .accessibilityLabel("Ở gần xe, chưa dùng")
                        .confirmationDialog("Xe đang mở khoá",
                            isPresented: $showingNearbyNotInUseConfirm,
                            titleVisibility: .visible) {
                            Button("Vẫn tắt kết nối") {
                                dashboardVM.setNearbyNotInUse()
                            }
                            Button("Huỷ", role: .cancel) {}
                        } message: {
                            Text("Xe sẽ không bị tắt ngay — firmware tự tắt theo idleOff. Bạn sẽ không nhận được cập nhật cho tới khi kết nối lại.")
                        }
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.7))
                            .padding()
                    }
                    .accessibilityLabel("Cài đặt")
                }
                .background(Color(red: 0.05, green: 0.05, blue: 0.08))
                Spacer()
            }
            .zIndex(1)
            
            // Cho phép cuộn khi màn hình thấp hoặc cỡ chữ lớn.
            ScrollView {
            VStack(spacing: 0) {
                Spacer()
                
                // ── RADAR PULSE ──
                ZStack {
                    // Vòng tròn tỏa ra (1 ring duy nhất)
                    Circle()
                        .stroke(stateColor, lineWidth: 2)
                        .frame(width: 180, height: 180)
                        .scaleEffect(pulsePhase == 0 ? 1.0 : 2.5)
                        .opacity(pulsePhase == 0 ? 0.6 : 0.0)
                        .animation(
                            .easeOut(duration: 2.0)
                                .repeatForever(autoreverses: false),
                            value: pulsePhase
                        )
                    
                    // Vòng tròn nền trung tâm
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [stateColor.opacity(0.15), Color.clear],
                                center: .center,
                                startRadius: 30,
                                endRadius: 90
                            )
                        )
                        .frame(width: 180, height: 180)
                    
                    // Viền tròn cố định
                    Circle()
                        .stroke(stateColor.opacity(0.3), lineWidth: 1)
                        .frame(width: 180, height: 180)
                    
                    // Logo icon
                    Image("VHexaLogoWhite")
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90, height: 90)
                        .foregroundColor(stateColor)
                }
                .animation(.easeInOut(duration: 0.5), value: dashboardVM.connectionState)
                
                Spacer().frame(height: 28)
                
                // ── TÊN XE THỰC TẾ ──
                Text(bikeName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                
                Spacer().frame(height: 8)
                
                // ── STAGE TIMELINE (§UX v2: timeline dọc thay pill ngang + hint + đếm giây) ──
                // User feedback: quá nhiều text. Timeline tự nói chuyện: node xong = check
                // xanh, node đang chạy = pulse màu trạng thái, node chờ = mờ. Chỉ node
                // active có 1 dòng hint duy nhất.
                if currentStage != nil {
                    stageTimeline
                        // §UX: khối timeline hẹp (~300pt), căn giữa dưới tên xe —
                        // không dàn full-width khiến node chếch sát lề trái.
                        .frame(maxWidth: 300, alignment: .leading)
                        .padding(.horizontal, 12)
                        .onReceive(dotTimer) { _ in
                            dotCount += 1
                        }
                } else {
                    // ── TRẠNG THÁI NHỎ (các state khác: standby/nearby/idle...) ──
                    Text(statusLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(stateColor.opacity(0.7))
                        .onReceive(dotTimer) { _ in
                            dotCount += 1
                        }
                }
                
                Spacer()
                
                // ── BOTTOM STATUS AREA ──
                VStack(spacing: 16) {
                    // LỚP 3 + §4 (P3): trạng thái manualOnly — ưu tiên trước mọi nhánh khác.
                    // Một cơ chế, hai reason: pausedByUser (PAUSE) | nearbyNotInUse (nút mới).
                    if dashboardVM.isPaused {
                        if dashboardVM.isNearbyNotInUse {
                            // ═══ §4.4-3: CARD "Ở GẦN XE, CHƯA DÙNG" ═══
                            Image(systemName: "bicycle")
                                .font(.system(size: 50))
                                .foregroundColor(.cyan)

                            Text("Đang ở gần xe — kết nối đã tắt")
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)

                            Text(dashboardVM.staleDataLine)
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)

                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                dashboardVM.connectForRide()
                            }) {
                                Text("Kết nối để dùng xe")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.cyan)
                                    .clipShape(Capsule())
                            }
                            .accessibilityLabel("Kết nối để dùng xe")
                        } else {
                            // ═══ PAUSE truyền thống ═══
                            Image(systemName: "pause.circle.fill")
                                .font(.system(size: 50))
                                .foregroundColor(.orange)

                            Text("Đã tạm dừng kết nối")
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)

                            Text("App sẽ không tự kết nối lại với xe. Bấm để tiếp tục.")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)

                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                                dashboardVM.resumeConnection()
                            }) {
                                Text("Tiếp tục kết nối")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.green)
                                    .clipShape(Capsule())
                            }
                        }
                    } else if let err = dashboardVM.pairingError {
                        // Error state
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(.red)
                        
                        Text(err)
                            .font(.subheadline)
                            .foregroundColor(.red.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        if err.contains("cấp quyền") {
                            Button(action: {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }) {
                                Text("Mở Cài Đặt")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                            }
                        } else {
                            Button(action: { dashboardVM.connectBike() }) {
                                Text("Thử lại")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 30)
                                    .padding(.vertical, 12)
                                    .background(Color.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    } else if dashboardVM.connectionState == .pairingRequired {
                        // Ghép đôi lần đầu — xe đã tìm thấy, chờ user xác nhận
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.green)
                        
                        Text("Đã tìm thấy xe! Bấm nút bên dưới để hoàn tất ghép đôi.")
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button(action: {
                            let securePin = BLEProtocol.generateSecurePIN()
                            dashboardVM.submitPairingPin(securePin)
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: "link.badge.plus")
                                    .font(.title2)
                                Text("Xác nhận ghép đôi")
                                    .font(.headline)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [.green, .green.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                            .shadow(color: .green.opacity(0.3), radius: 10, y: 5)
                        }
                    } else if dashboardVM.connectionState == .scanning && !dashboardVM.discoveredBikes.isEmpty {
                        // Bike list found
                        VStack(spacing: 16) {
                            Text("Chọn xe để kết nối")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            ForEach(dashboardVM.discoveredBikes) { bike in
                                Button(action: { dashboardVM.selectBike(bike.id) }) {
                                    HStack(spacing: 14) {
                                        Image(systemName: "bicycle")
                                            .font(.title2)
                                            .foregroundColor(.orange)
                                            .frame(width: 36)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(bike.name)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                            // Ưu tiên serial (fw 1.11.0 quảng bá ASCII) để phân biệt
                                            // xe khi nhiều xe cùng tên mặc định; fallback UUID suffix.
                                            Text(bike.serial.map { "Serial: \($0)" }
                                                 ?? "ID: \(String(bike.id.suffix(8)).uppercased())")
                                                .font(.caption)
                                                .foregroundColor(.orange.opacity(0.7))
                                        }
                                        
                                        Spacer()
                                        
                                        bikeSignalIcon(rssi: bike.rssi)
                                    }
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 14)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(Color.white.opacity(0.06))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                                            )
                                    )
                                }
                            }
                            .padding(.horizontal)
                            
                            HStack(spacing: 8) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                                    .scaleEffect(0.7)
                                Text("Đang quét thêm...")
                                    .font(.caption)
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                        }
                    } else if case .nearby = dashboardVM.connectionState {
                        // ── NEARBY STATE: Hiện thông tin + nút kết nối ──
                        VStack(spacing: 16) {
                            // Thông tin xe cơ bản
                            HStack(spacing: 20) {
                                VStack(spacing: 4) {
                                    Image(systemName: "battery.75percent")
                                        .font(.title2)
                                        .foregroundColor(.green)
                                    Text("\(Int(dashboardVM.telemetry.soc))%")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(spacing: 4) {
                                    Image(systemName: dashboardVM.lockState == .unlocked ? "lock.open.fill" : (dashboardVM.lockState == .armed ? "shield.fill" : "lock.fill"))
                                        .font(.title2)
                                        .foregroundColor(dashboardVM.lockState == .unlocked ? .green : (dashboardVM.lockState == .armed ? .orange : .gray))
                                    Text(dashboardVM.lockState.description)
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                
                                VStack(spacing: 4) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.title2)
                                        .foregroundColor(.cyan)
                                    Text("\(dashboardVM.rssi) dBm")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            .padding(.vertical, 8)
                            
                            // Nút kết nối
                            Button(action: {
                                let generator = UIImpactFeedbackGenerator(style: .heavy)
                                generator.impactOccurred()
                                dashboardVM.connectFromNearby()
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: "bolt.circle.fill")
                                        .font(.title2)
                                    Text("Kết nối ngay")
                                        .font(.headline)
                                }
                                .foregroundColor(.white)
                                .padding(.horizontal, 36)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(
                                        colors: [Color(red: 0.3, green: 0.7, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.9)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .clipShape(Capsule())
                                .shadow(color: Color(red: 0.3, green: 0.7, blue: 1.0).opacity(0.4), radius: 10, y: 5)
                            }
                            
                            Text("Bấm để kết nối & điều khiển")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.4))
                        }
                    } else if !dashboardVM.hasAuthorizedAccessory && PreferencesManager.shared.savedPeripheralUUID == nil {
                        // No bike paired — show add button (user gesture → F2: đường
                        // DUY NHẤT mở ASK picker)
                        Button(action: { dashboardVM.startPairing() }) {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                Text("Thêm xe")
                                    .font(.headline)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(
                                    colors: [.orange, .orange.opacity(0.8)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .clipShape(Capsule())
                            .shadow(color: .orange.opacity(0.3), radius: 10, y: 5)
                        }
                        .disabled(dashboardVM.isProcessing)
                        
                        Text("Hướng dẫn: Quẹt sẵn thẻ NFC lên đồng hồ xe trước khi bấm")
                            .font(.caption)
                            .foregroundColor(.orange.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                     } else if PreferencesManager.shared.savedPin != nil,
                               (dashboardVM.connectionState == .scanning
                                || dashboardVM.connectionState == .connecting
                                || dashboardVM.connectionState == .authenticating) {
                         // ── SCANNING / CONNECTING / AUTHENTICATING: escape hatch ──
                         // CHỈ hiện khi đã từng ghép xe (savedPin != nil).
                         // Ghép lần đầu: chỉ cần timeline chạy là đủ — không cần nút phụ.
                         VStack(spacing: 12) {
                             // ── Nút 1: Kết nối lại (forceReconnect — cancel sạch mọi pending) ──
                             Button(action: {
                                 let generator = UIImpactFeedbackGenerator(style: .heavy)
                                 generator.impactOccurred()
                                 dashboardVM.forceReconnect()
                             }) {
                                 HStack(spacing: 8) {
                                     Image(systemName: "arrow.triangle.2.circlepath")
                                         .font(.system(size: 16, weight: .semibold))
                                     Text("Kết nối lại")
                                         .font(.system(size: 15, weight: .semibold))
                                 }
                                 .foregroundColor(.white.opacity(0.9))
                                 .padding(.horizontal, 28)
                                 .padding(.vertical, 11)
                                 .background(
                                     Capsule()
                                         .fill(Color.white.opacity(0.08))
                                         .overlay(
                                             Capsule()
                                                 .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
                                         )
                                 )
                             }
                             .accessibilityLabel("Kết nối lại")

                             // ── Nút 2: "Ở gần xe, chưa dùng" — ngừng hẳn việc đang quét/kết nối,
                             // vào manualOnly (card cyan + "Kết nối để dùng xe").
                             // Chưa kết nối nên không cần confirm lock-state.
                             Button(action: {
                                 let generator = UIImpactFeedbackGenerator(style: .medium)
                                 generator.impactOccurred()
                                 dashboardVM.setNearbyNotInUse()
                             }) {
                                 HStack(spacing: 8) {
                                     Image(systemName: "figure.stand")
                                         .font(.system(size: 16, weight: .semibold))
                                     Text("Ở gần xe, chưa dùng")
                                         .font(.system(size: 15, weight: .semibold))
                                 }
                                 .foregroundColor(.cyan.opacity(0.9))
                                 .padding(.horizontal, 28)
                                 .padding(.vertical, 11)
                                 .background(
                                     Capsule()
                                         .fill(Color.cyan.opacity(0.08))
                                         .overlay(
                                             Capsule()
                                                 .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                                         )
                                 )
                             }
                             .accessibilityLabel("Ở gần xe, chưa dùng")
                         }
                    } else {
                        // Trạng thái chờ/kết nối -> ẩn (đã hiển thị ở trên)
                    }
                }
                .frame(minHeight: 100)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 64)
            .frame(minHeight: geometry.size.height)
            }
        }
        }
        .onAppear {
            pulsePhase = 1
        }
    }

    @State private var dotCount = 0
    let dotTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // ═══════════════ §UX: STAGE PIPELINE — phân biệt 3 giai đoạn quay lại xe ═══════════════

    private enum ConnectStage: Int, CaseIterable {
        case search = 0, connect = 1, auth = 2, ready = 3

        var label: String {
            switch self {
            case .search: return "Tìm xe"
            case .connect: return "Kết nối"
            case .auth: return "Xác thực"
            case .ready: return "Sẵn sàng"
            }
        }

        var icon: String {
            switch self {
            case .search: return "antenna.radiowaves.left.and.right"
            case .connect: return "link"
            case .auth: return "key.fill"
            case .ready: return "bolt.fill"
            }
        }

        /// Hint ngắn — CHỈ node active hiển thị (1 dòng duy nhất cho cả màn hình).
        func shortHint(isPendingConnect: Bool, isFirstTimePairing: Bool) -> String {
            switch self {
            case .search:
                return isPendingConnect ? "Sẽ tự kết nối khi xe vào tầm sóng" : "Đang quét Bluetooth quanh đây"
            case .connect:
                return isPendingConnect ? "Chờ xe vào tầm sóng" : "Đã thấy xe — đang thiết lập liên kết"
            case .auth:
                return isFirstTimePairing ? "Đã tìm thấy xe — bấm nút phía dưới để ghép đôi" : "Đang xác thực chìa khoá điện tử"
            case .ready:
                return ""
            }
        }
    }

    /// nil khi không trong pipeline (standby/nearby/paused/idle) → dùng statusLabel cũ.
    private var currentStage: ConnectStage? {
        if dashboardVM.isPaused { return nil }
        switch dashboardVM.connectionState {
        case .scanning: return .search
        case .connecting: return .connect
        case .pairingRequired: return .auth  // Ghép lần đầu: chờ user xác nhận
        case .authenticating: return .auth
        default: return nil
        }
    }

    /// true khi đang ghép lần đầu (chưa có savedPin).
    private var isFirstTimePairing: Bool {
        PreferencesManager.shared.savedPin == nil
    }

    // ═══ §UX v2: TIMELINE DỌC — node + connector, text tối thiểu ═══

    private var stageTimeline: some View {
        let idx = currentStage?.rawValue ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(ConnectStage.allCases, id: \.self) { stage in
                let i = stage.rawValue
                let isDone = i < idx
                let isActive = i == idx

                timelineRow(stage: stage, isDone: isDone, isActive: isActive)

                if stage != .ready {
                    timelineConnector(isDone: isDone, isActive: isActive)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: dashboardVM.connectionState)
    }

    private func timelineRow(stage: ConnectStage, isDone: Bool, isActive: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            // ── NODE ──
            ZStack {
                if isActive {
                    // Vòng pulse quanh node đang chạy
                    Circle()
                        .stroke(stateColor.opacity(0.5), lineWidth: 1.5)
                        .frame(width: 34, height: 34)
                        .scaleEffect(dotCount % 2 == 0 ? 1.0 : 1.35)
                        .opacity(dotCount % 2 == 0 ? 0.6 : 0.0)
                        .animation(.easeOut(duration: 1.0), value: dotCount)
                }

                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.green)
                } else {
                    Circle()
                        .fill(isActive ? stateColor.opacity(0.18) : Color.white.opacity(0.04))
                        .frame(width: 34, height: 34)

                    Circle()
                        .stroke(isActive ? stateColor : Color.white.opacity(0.18),
                                lineWidth: isActive ? 2 : 1)
                        .frame(width: 34, height: 34)

                    Image(systemName: stage.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isActive ? stateColor : .white.opacity(0.3))
                }
            }
            .frame(width: 36, height: 36)

            // ── LABEL + hint (chỉ active) ──
            VStack(alignment: .leading, spacing: 3) {
                // §UX: pending connect ⇒ label nói đúng bản chất "Chờ xe"
                let label = (stage == .connect && dashboardVM.isPendingConnect) ? "Chờ xe" : stage.label
                Text(label)
                    .font(.system(size: 14, weight: isActive ? .bold : .regular))
                    .foregroundColor(isActive ? .white : (isDone ? .white.opacity(0.55) : .white.opacity(0.3)))

                if isActive {
                    Text(stage.shortHint(isPendingConnect: dashboardVM.isPendingConnect, isFirstTimePairing: isFirstTimePairing))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
    }

    private func timelineConnector(isDone: Bool, isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(isDone ? Color.green.opacity(0.8)
                 : (isActive ? stateColor.opacity(0.7) : Color.white.opacity(0.12)))
            .frame(width: 2, height: 16)
            .padding(.leading, 17) // căn giữa với node 34pt (36/2 - 1)
    }
    
    private var bikeName: String {
        let infoName = dashboardVM.bikeInfo.name
        // Nếu bikeInfo đã có tên thực (không phải default)
        if !infoName.isEmpty && infoName != "Dat Bike" {
            return infoName
        }
        // Fallback: tên đã lưu từ lần kết nối trước
        if let saved = PreferencesManager.shared.sharedDefaults.string(forKey: "widgetBikeName"),
           !saved.isEmpty && saved != "Dat Bike" {
            return saved
        }
        // Fallback: tên quảng bá BLE (ví dụ "Ngựa sắt") — hiện ngay khi scan thấy xe
        if let advName = dashboardVM.advertisedBikeName, !advName.isEmpty {
            return advName
        }
        return "D-SmartKey"
    }
    
    private var statusLabel: String {
        if dashboardVM.isPaused {
            return dashboardVM.isNearbyNotInUse ? "Ở gần xe, chưa dùng" : "Đã tạm dừng"
        }
        let baseText: String
        switch dashboardVM.connectionState {
        case .scanning:
            // §UX (code-driven): .scanning + pending = didDisconnect đã đặt pending connect,
            // KHÔNG có radio scan nào chạy → đừng nói "Đang tìm xe" sai sự thật
            baseText = dashboardVM.isPendingConnect ? "Đang chờ xe vào tầm sóng" : "Đang tìm xe"
        case .connecting:
            // §UX: pending connect (cache, chờ xe) khác hẳn handshake active (xe đã thấy)
            baseText = dashboardVM.isPendingConnect ? "Đang chờ xe vào tầm sóng" : "Đang kết nối"
        case .authenticating: baseText = "Đang xác thực & Ghép đôi"
        case .standby: baseText = "Kết nối chờ"
        case .nearby: baseText = "Đang ở gần xe"
        default: baseText = "Đang kết nối"
        }
        let dots = String(repeating: ".", count: (dotCount % 3) + 1)
        return baseText + dots
    }
    
    // Dynamic theme color based on connection state
    private var stateColor: Color {
        if dashboardVM.isPaused { return dashboardVM.isNearbyNotInUse ? .cyan : .orange }
        switch dashboardVM.connectionState {
        case .scanning: return .cyan
        case .connecting: return .orange
        case .pairingRequired: return .green  // Ghép lần đầu: đồng bộ màu nút "Xác nhận ghép đôi"
        case .authenticating: return .yellow
        case .standby: return Color(red: 0.2, green: 0.8, blue: 0.4)
        case .nearby: return Color(red: 0.3, green: 0.7, blue: 1.0)
        default: return .orange
        }
    }
    

    private func bikeSignalIcon(rssi: Int) -> some View {
        let (bars, color): (Int, Color) = {
            if rssi >= -60 { return (4, .green) }
            if rssi >= -75 { return (3, .green) }
            if rssi >= -85 { return (2, .yellow) }
            return (1, .red)
        }()
        
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? color : Color.gray.opacity(0.3))
                    .frame(width: 4, height: CGFloat(level * 5))
            }
        }
    }
}
