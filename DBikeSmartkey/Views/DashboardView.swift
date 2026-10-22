// DashboardView.swift — Premium remastered main dashboard with sophisticated design

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var container: AppDIContainer
    @ObservedObject var viewModel: DashboardViewModel
    @State private var showingSettings = false
    @State private var isRefreshing = false
    @State private var pulseAnimation = false
    @State private var showExitConfirm = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var controlHeight: CGFloat = 76
    
    // Dynamic accent colors based on lock state
    private var accentColor: Color {
        viewModel.lockStatus.isLocked ? Color(red: 0.937, green: 0.267, blue: 0.267) : Color(red: 0.0, green: 0.898, blue: 1.0)
    }
    
    private var accentGlow: Color {
        viewModel.lockStatus.isLocked ? Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.5) : Color(red: 0.0, green: 0.898, blue: 1.0).opacity(0.5)
    }
    
    private var statusText: String {
        if viewModel.connectionState == .standby {
            return "Kết nối chờ (Chờ gần)"
        }
        if viewModel.connectionState == .authenticating {
            return "Đang xác thực bảo mật..."
        }
        switch viewModel.lockStatus {
        case .armed:
            return "Xe đã bật chống trộm"
        case .locked:
            return "Xe đang tắt"
        case .unlocked:
            return "Xe đang bật"  
        case .unknown:
            return "Đang tải..."
        }
    }
    
    private var actionText: String {
        if viewModel.connectionState == .standby {
            return "Chạm để đánh thức xe"
        }
        if viewModel.connectionState == .authenticating {
            return "Vui lòng đợi..."
        }
        switch viewModel.lockStatus {
        case .armed:
            return "Chạm để tắt chống trộm"
        case .locked:
            return "Chạm để mở khóa"
        case .unlocked:
            return "Chạm để khóa xe"
        case .unknown:
            return "Vui lòng đợi..."
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // --- PREMIUM BACKGROUND WITH MESH GRADIENT ---
                backgroundView
                
                VStack(spacing: 0) {
                    // --- HEADER ---
                    headerView(availableWidth: geometry.size.width)
                        .padding(.top, geometry.safeAreaInsets.top)
                        .padding(.horizontal, 24)
                    
                    // --- MAIN CONTENT ---
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 32) {
                            // --- MAIN CENTER ACTION (V-Hexa Logo with glowing rings) ---
                            mainActionView
                                .padding(.top, 20)
                            
                            // --- QUICK STATS WIDGET ---
                            quickStatsView
                                .padding(.horizontal, 24)
                            
                            // --- BENTO GRID CONTROLS ---
                            bentoControlsView
                                .padding(.horizontal, 24)
                        }
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 40)
                    }
                }
            }
            .ignoresSafeArea(.all, edges: .all)
        }
        .alert("Lỗi", isPresented: $viewModel.showError) {
            Button("OK") {}
        } message: {
            Text(viewModel.errorMessage)
        }
        .alert("Thoát ứng dụng", isPresented: $showExitConfirm) {
            Button("Hủy", role: .cancel) { }
            Button("Thoát", role: .destructive) {
                // P5: bỏ private API NSXPCConnection.suspend (rủi ro App Store reject).
                // Chỉ exit(0) — hệ thống tự về home screen.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    exit(0)
                }
            }
        } message: {
            Text("Bạn có chắc chắn muốn ngắt kết nối và đóng hoàn toàn ứng dụng không?")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: container.settingsViewModel)
        }
    }
    
    // MARK: - Background with Mesh Gradient Effect
    
    private var backgroundView: some View {
        ZStack {
            // Base dark background
            Color(red: 0.02, green: 0.02, blue: 0.02)
                .ignoresSafeArea()
            
            // Grid pattern overlay (subtle)
            GridPattern()
                .opacity(0.05)
            
            // Dynamic accent glow from top
            RadialGradient(
                colors: [accentGlow, .clear],
                center: .top,
                startRadius: 50,
                endRadius: 400
            )
            .opacity(0.2)
            .animation(.easeInOut(duration: 1.0), value: accentColor)
        }
    }
    
    // MARK: - Header
    
    private func headerView(availableWidth: CGFloat) -> some View {
        let stacked = availableWidth < 440 || dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 8) {
                Text("D-Smartkey")
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .foregroundColor(.gray)
                    .textCase(.uppercase)
                
                HStack(spacing: 0) {
                    Text(viewModel.bikeInfo.name.isEmpty ? "Ngựa sắt" : viewModel.bikeInfo.name)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                (dynamicTypeSize.isAccessibilitySize || availableWidth < 360
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 8))) {
                    // Connection status badge
                    ConnectionStatusBadge(isConnected: viewModel.isConnected, isStandby: viewModel.connectionState == .standby)

                    // LỚP 3 + §4 (P3): badge manualOnly — 2 reason cùng cơ chế
                    if viewModel.isPaused {
                        if viewModel.isNearbyNotInUse {
                            Text("Ở gần xe, chưa dùng")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.cyan)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.cyan.opacity(0.15)))
                        } else {
                            Text("Đã tạm dừng")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                    }

                    // Signal strength indicator
                    if viewModel.isConnected {
                        SignalStrengthBadge(
                            signalStrength: viewModel.signalStrength,
                            rssi: viewModel.rssi
                        )
                    }
                }
            }
            
            .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                // LỚP 3 + §4 (P3): Tạm dừng / Tiếp tục — khi nearbyNotInUse thì nút này
                // cũng thoát manualOnly (một cơ chế, quyết định #2).
                Button(action: {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    if viewModel.isPaused {
                        viewModel.isNearbyNotInUse ? viewModel.connectForRide() : viewModel.resumeConnection()
                    } else {
                        viewModel.pauseConnection()
                    }
                }) {
                    Image(systemName: viewModel.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(viewModel.isPaused ? .green : .gray)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(viewModel.isPaused ? "Tiếp tục kết nối" : "Tạm dừng kết nối")

                // Disconnect/Standby Button
                if viewModel.connectionState == .active {
                    Button(action: {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        viewModel.forceStandby()
                    }) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                            .frame(width: 44, height: 44)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.05))
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Settings button
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.gray)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.05))
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Cài đặt")
            }
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Main Center Action (V-Hexa with glowing rings)
    
    private var mainActionView: some View {
        VStack(spacing: 0) {
            ZStack {
                // Outer radar ring
                Circle()
                    .stroke(accentColor.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [8, 8]))
                    .frame(width: 300, height: 300)
                    .rotationEffect(.degrees(viewModel.lockStatus.isLocked ? 0 : 180))
                    .animation(.linear(duration: viewModel.lockStatus.isLocked ? 40 : 20).repeatForever(autoreverses: false), value: viewModel.lockStatus.isLocked)
                
                // Inner background ring
                Circle()
                    .fill(Color.white.opacity(0.01))
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
                    .frame(width: 264, height: 264)
                    .blur(radius: 1)
                
                // Main center button
                Button(action: {
                    let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
                    impactFeedback.impactOccurred()
                    if viewModel.connectionState == .standby {
                        viewModel.forceAuthenticate()
                    } else {
                        viewModel.toggleLock()
                    }
                }) {
                    ZStack {
                        // Glow background
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [accentGlow, .clear],
                                    center: .center,
                                    startRadius: 0,
                                    endRadius: 90
                                )
                            )
                            .frame(width: 144, height: 144)
                        
                        // Button background
                        RoundedRectangle(cornerRadius: 60)
                            .fill(viewModel.lockStatus.isLocked ? 
                                  Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.1) :
                                    Color(red: 0.0, green: 0.898, blue: 1.0).opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 60)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .frame(width: 120, height: 120)
                        
                        // V-Hexa Logo
                        if viewModel.isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                                .scaleEffect(2.0)
                        } else {
                            Image("VHexaLogoWhite")
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 56, height: 56)
                                .foregroundColor(accentColor)
                                .shadow(color: accentColor.opacity(0.5), radius: 8)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .scaleEffect(pulseAnimation ? 1.02 : 1.0)
                .disabled(viewModel.isProcessing)
            }
            .frame(width: 300, height: 300)
            
            // Action label with status + action
            VStack(spacing: 4) {
                Text(statusText)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(actionText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.top, 32)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulseAnimation = true
            }
        }
    }
    
    // MARK: - Quick Stats Widget
    
    private var quickStatsView: some View {
        HStack(spacing: 0) {
            // Battery
            QuickStatItem(
                icon: "battery.100percent",
                value: "\(viewModel.batteryPercentage)%",
                label: "PIN",
                color: .green,
                showsDivider: true
            )
            
            // QuickStatItem cho Nhiệt độ motor
            QuickStatItem(
                icon: "thermometer.sun.fill",
                value: viewModel.motorTemp > 0 ? String(format: "%.0f°", viewModel.motorTemp) : "—",
                label: "NHIỆT ĐỘ MOTOR",
                color: .orange,
                showsDivider: true
            )
            
            // Odometer
            QuickStatItem(
                icon: "number.square.fill",
                value: viewModel.odometer > 0 ? String(format: "%.0f", viewModel.odometer) : "—",
                label: "ODO",
                color: .gray,
                showsDivider: false
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
    
    // MARK: - Bento Grid Controls
    
    private var bentoControlsView: some View {
        GeometryReader { geometry in
            let screenWidth = geometry.size.width
            let buttonHeight = controlHeight
            let spacing: CGFloat = 12 // Spacing between buttons in same row
            let rowSpacing: CGFloat = 30 // Increased spacing between rows
            
            // Calculate widths for 4-column grid: 2+1+1 columns
            let totalSpacing = spacing * 2 // 2 gaps in top row
            let availableWidth = screenWidth - totalSpacing
            let accessible = dynamicTypeSize.isAccessibilitySize
            let smallButtonWidth = accessible ? screenWidth : availableWidth / 4
            let bigButtonWidth = accessible ? screenWidth : smallButtonWidth * 2
            let rowLayout = accessible
                ? AnyLayout(VStackLayout(spacing: spacing))
                : AnyLayout(HStackLayout(spacing: spacing))
            
            VStack(spacing: rowSpacing) {
                // Top row: Chống trộm (2 cols) + Tìm (1 col) + Tải lại (1 col)
                rowLayout {
                    // Chống trộm - 2 columns wide
                    BentoControlCard(
                        icon: "shield.lefthalf.filled",
                        title: "Chống trộm",
                        subtitle: nil,
                        color: .red,
                        colSpan: 2,
                        isSquare: false,
                        isActive: viewModel.lockStatus == .armed && viewModel.connectionState != .standby,
                        isDisabled: viewModel.connectionState == .standby,
                        action: { viewModel.lock() }
                    )
                    .frame(width: bigButtonWidth, height: buttonHeight)
                    
                    // Tìm xe - 1 column square
                    BentoControlCard(
                        icon: "speaker.wave.2.fill", 
                        title: "Tìm",
                        subtitle: nil,
                        color: Color(red: 0.4, green: 0.6, blue: 1.0),
                        colSpan: 1,
                        isSquare: true,
                        isActive: viewModel.isFinding && viewModel.connectionState != .standby,
                        isDisabled: viewModel.connectionState == .standby,
                        action: { viewModel.findBike() }
                    )
                    .frame(width: smallButtonWidth, height: buttonHeight)
                    
                    // Tải lại - 1 column square
                    BentoControlCard(
                        icon: "arrow.clockwise",
                        title: "Tải lại", 
                        subtitle: nil,
                        color: Color(red: 0.6, green: 0.4, blue: 1.0),
                        colSpan: 1,
                        isSquare: true,
                        isActive: false,
                        isDisabled: isRefreshing || viewModel.connectionState == .standby,
                        isRotating: isRefreshing,
                        action: {
                            isRefreshing = true
                            viewModel.refreshStatus()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                isRefreshing = false
                            }
                        }
                    )
                    .frame(width: smallButtonWidth, height: buttonHeight)
                }
                
                // Bottom row: Bật xe (2 cols) + Tắt xe (2 cols)
                rowLayout {
                    // Bật xe - 2 columns wide
                    BentoControlCard(
                        icon: "bolt.fill",
                        title: "Bật xe",
                        subtitle: "Power ON", 
                        color: Color(red: 0.0, green: 0.898, blue: 1.0),
                        colSpan: 2,
                        isSquare: false,
                        isActive: viewModel.lockStatus == .locked && viewModel.connectionState != .standby,     // KHI TẮT -> NỔI BẬT NÚT BẬT LÊN
                        isDisabled: viewModel.lockStatus == .unlocked || viewModel.connectionState == .standby, // Disable khi xe ĐÃ BẬT hoặc CHỜ KẾT NỐI
                        action: { viewModel.turnOnBike() }
                    )
                    .frame(width: bigButtonWidth, height: buttonHeight)
                    
                    // Tắt xe - 2 columns wide
                    BentoControlCard(
                        icon: "power",
                        title: "Tắt xe",
                        subtitle: "Power OFF",
                        color: .red,
                        colSpan: 2,
                        isSquare: false,
                        isActive: viewModel.lockStatus == .unlocked && viewModel.connectionState != .standby, // KHI BẬT -> NỔI BẬT NÚT TẮT LÊN
                        isDisabled: viewModel.lockStatus == .locked || viewModel.connectionState == .standby, // Disable khi xe ĐÃ TẮT hoặc CHỜ KẾT NỐI
                        action: { viewModel.turnOffBike() }
                    )
                    .frame(width: bigButtonWidth, height: buttonHeight)
                }
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? controlHeight * 5 + 66 : controlHeight * 2 + 30)
    }
    
    // MARK: - Supporting Components
    
    // Grid Pattern for background
    struct GridPattern: View {
        var body: some View {
            Canvas { context, size in
                let gridSize: CGFloat = 24
                
                for x in stride(from: 0, through: size.width, by: gridSize) {
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                        },
                        with: .color(Color.white.opacity(0.05)),
                        lineWidth: 1
                    )
                }
                
                for y in stride(from: 0, through: size.height, by: gridSize) {
                    context.stroke(
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                        },
                        with: .color(Color.white.opacity(0.05)),
                        lineWidth: 1
                    )
                }
            }
        }
    }
    
    // Connection Status Badge
    struct ConnectionStatusBadge: View {
        let isConnected: Bool
        let isStandby: Bool
        
        var body: some View {
            let badgeColor: Color = isConnected ? (isStandby ? .orange : .green) : .red
            let badgeText: String = isConnected ? (isStandby ? "Chờ lại gần..." : "Đã kết nối") : "Chưa kết nối"
            
            HStack(spacing: 6) {
                Circle()
                    .fill(badgeColor)
                    .frame(width: 6, height: 6)
                    .overlay(
                        Circle()
                            .fill(badgeColor)
                            .frame(width: 6, height: 6)
                            .scaleEffect(isConnected ? 2 : 1)
                            .opacity(isConnected ? 0 : 1)
                            .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: isConnected)
                    )
                
                Text(badgeText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
            )
        }
    }
    
    // Signal Strength Badge
    struct SignalStrengthBadge: View {
        let signalStrength: SignalStrength
        let rssi: Int
        
        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                
                // Signal bars
                HStack(spacing: 1) {
                    ForEach(1...4, id: \.self) { bar in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(bar <= signalStrength.rawValue ? Color.blue : Color.white.opacity(0.2))
                            .frame(width: 3, height: CGFloat(bar * 2 + 2))
                    }
                }
                
                Text("\(rssi) dBm")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.blue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.blue.opacity(0.1))
                    .overlay(
                        Capsule()
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
    
    // Quick Stat Item
    struct QuickStatItem: View {
        let icon: String
        let value: String
        let label: String
        let color: Color
        let showsDivider: Bool
        
        var body: some View {
            HStack {
                VStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundColor(color)
                    
                    Text(value)
                        .font(.system(size: 20, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                }
                .frame(maxWidth: .infinity)
                
                if showsDivider {
                    Divider()
                        .background(Color.white.opacity(0.05))
                        .frame(height: 60)
                }
            }
        }
    }
    
    // Bento Control Card
    struct BentoControlCard: View {
        let icon: String
        let title: String
        let subtitle: String?
        let color: Color
        let colSpan: Int
        let isSquare: Bool
        let isActive: Bool
        let isDisabled: Bool
        var isRotating: Bool = false
        let action: () -> Void
        
        @State private var isPressed = false
        
        var body: some View {
            Button(action: {
                if !isDisabled {
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                    action()
                }
            }) {
                VStack(spacing: isSquare ? 3 : 8) {
                    // Icon - centered for all button types
                    Image(systemName: icon)
                        .font(.system(size: isSquare ? 16 : 20, weight: .medium))
                        .foregroundColor(isActive ? .white : (isDisabled ? .gray.opacity(0.5) : color))
                        .rotationEffect(.degrees(isRotating ? 360 : 0))
                        .animation(isRotating ? .linear(duration: 1.0).repeatForever(autoreverses: false) : .default, value: isRotating)
                    
                    if !isSquare {
                        VStack(alignment: .center, spacing: 1) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(isActive ? .white : (isDisabled ? .gray.opacity(0.6) : .white))
                                .multilineTextAlignment(.center)
                            
                            if let subtitle = subtitle {
                                Text(subtitle)
                                    .font(.caption2.weight(.medium))
                                    .foregroundColor(isActive ? Color.white.opacity(0.8) : (isDisabled ? Color.gray.opacity(0.5) : Color.gray))
                                    .multilineTextAlignment(.center)
                            }
                        }
                    } else {
                        Text(title)
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(isActive ? .white : (isDisabled ? .gray.opacity(0.6) : .white))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    
                    if isSquare {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(isSquare ? 8 : 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isActive ? color : Color.white.opacity(isDisabled ? 0.06 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isActive ? Color.clear : Color.white.opacity(isDisabled ? 0.08 : 0.05), lineWidth: 1)
                        )
                )
                .scaleEffect(isPressed ? 0.96 : 1.0)
                .disabled(isDisabled)
            }
            .buttonStyle(PlainButtonStyle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isDisabled {
                            withAnimation(.easeInOut(duration: 0.08)) { isPressed = true }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeInOut(duration: 0.1)) { isPressed = false }
                    }
            )
        }
    }
    
    
}
