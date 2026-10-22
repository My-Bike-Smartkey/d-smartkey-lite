// BatteryAnalyticsView.swift — Premium BMS Analytics screen

import SwiftUI

struct BatteryAnalyticsView: View {
    @ObservedObject var viewModel: BatteryViewModel
    @Environment(\.dismiss) private var dismiss
    
    @State private var showHealthInfo = false
    @State private var showCellInfo = false
    
    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.08),
                    Color(red: 0.05, green: 0.05, blue: 0.12),
                    Color(red: 0.04, green: 0.04, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header
                    headerView
                    
                    if viewModel.battery != nil {
                        // Section 1: Battery overview hero
                        batteryHeroCard
                        
                        // Section 2: Power & Lifecycle
                        powerLifecycleCard
                        
                        // Section 3: Temperature (NTC sensors)
                        TemperatureGroupView(
                            temperatures: viewModel.ntcTemps,
                            avgTemp: viewModel.avgTemp,
                            maxTemp: viewModel.maxTemp,
                            tempDelta: viewModel.tempDelta,
                            hasHighTempWarning: viewModel.hasHighTempWarning,
                            hasTempImbalanceWarning: viewModel.hasTempImbalanceWarning
                        )
                        .padding(.horizontal)
                        
                        // Section 4: Cell Voltages (per-cell)
                        if viewModel.hasCellData {
                            cellVoltageGridCard
                        }
                        
                        // Section 5: Raw technical data
                        technicalDataCard
                        
                        // Debug: Unknown JSON keys
                        if !viewModel.extraKeys.isEmpty {
                            extraKeysDebugCard
                        }
                    } else {
                        // No data state
                        noDataView
                    }
                    
                    Spacer(minLength: 40)
                }
                .padding(.top, 8)
            }
        }
        .onAppear {
            viewModel.refresh()
        }
        .alert("Sức khoẻ Pin", isPresented: $showHealthInfo) {
            Button("Đã hiểu", role: .cancel) { }
        } message: {
            Text("Mạch BMS không cung cấp trực tiếp tuổi thọ pin. Nó được app tính toán theo đặc tính vật lý: dung lượng giảm tuyến tính khoảng 20% sau mỗi 1000 chu kỳ sạc-xả.")
        }
        .alert("Điện áp Cell Pin", isPresented: $showCellInfo) {
            Button("Đã hiểu", role: .cancel) { }
        } message: {
            Text("Cấu trúc pin gồm nhiều cell ghép nối tiếp (VD: 23S). BMS sẽ tắt nguồn xe nếu có dù chỉ 1 cell sụt xuống ngưỡng điện áp thấp để bảo vệ cháy nổ.\n\nĐộ lệch (Δ) giữa cell cao nhất và thấp nhất càng nhỏ chứng tỏ pin cấu trúc càng đồng đều và khoẻ mạnh.")
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Phân tích Pin")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                Text("BMS Analytics")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(viewModel.lastUpdatedText)
                    .font(.caption2.monospaced())
                    .foregroundColor(.gray.opacity(0.6))
            }
            
            Spacer()
            
            // Refresh button
            Button(action: { viewModel.refresh() }) {
                ZStack {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.cyan)
                        .padding(10)
                        .background(Circle().fill(Color.cyan.opacity(0.1)))
                        .rotationEffect(.degrees(viewModel.isLoading ? 360 : 0))
                        .animation(
                            viewModel.isLoading
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: viewModel.isLoading
                        )
                }
            }
            .disabled(viewModel.isLoading)
            
        }
        .padding(.horizontal)
    }
    
    // MARK: - Battery Hero Card
    
    private var batteryHeroCard: some View {
        VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                batteryHeroContent(layout: AnyLayout(HStackLayout(spacing: 16)))
                    .fixedSize(horizontal: true, vertical: false)
                batteryHeroContent(layout: AnyLayout(VStackLayout(spacing: 16)))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }

    private func batteryHeroContent(layout: AnyLayout) -> some View {
            layout {
                // SOC Gauge
                BatteryGaugeView(
                    value: viewModel.socPercent,
                    label: "Dung lượng",
                    unit: "%",
                    size: 140,
                    lineWidth: 12
                )
                
                // Stats column
                VStack(alignment: .leading, spacing: 12) {
                    // Charging state
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.chargingState.icon)
                            .font(.system(size: 14))
                            .foregroundColor(chargingColor)
                        Text(viewModel.chargingState.label)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(chargingColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().fill(chargingColor.opacity(0.12))
                    )
                    
                    // Voltage
                    statRow(icon: "bolt.circle.fill", label: "Điện áp",
                            value: String(format: "%.1f V", viewModel.voltage),
                            color: .yellow)
                    
                    // Current
                    statRow(icon: "arrow.left.arrow.right.circle.fill", label: "Dòng điện",
                            value: String(format: "%.2f A", viewModel.current),
                            color: .cyan)
                }
            }
    }
    
    // MARK: - Power & Lifecycle Card
    
    private var powerLifecycleCard: some View {
        VStack(spacing: 16) {
            // Section header
            HStack {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.pink)
                Text("Sức khoẻ & Vòng đời")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Button(action: { showHealthInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                Spacer()
            }
            
            HStack(spacing: 20) {
                // Health gauge
                MiniGaugeView(
                    value: viewModel.healthPercent,
                    label: "Sức khoẻ",
                    icon: "heart.fill",
                    size: 52
                )
                
                Spacer()
                
                // Cycle count
                VStack(spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(viewModel.cycleCount)")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("/ 1000")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Text("Chu kỳ sạc")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    // Cycle progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.06))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(cycleBarColor)
                                .frame(width: geo.size.width * cycleProgress)
                        }
                    }
                    .frame(height: 6)
                    .frame(maxWidth: 100)
                }
                
                Spacer()
                
                // Power consumption
                VStack(spacing: 6) {
                    Text(String(format: "%.0f", viewModel.powerWatts))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("Watt")
                        .font(.caption2)
                        .foregroundColor(.gray)
                    
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.yellow)
                        .padding(6)
                        .background(Circle().fill(Color.yellow.opacity(0.12)))
                }
            }
            
            // Health warning if low
            if viewModel.healthPercent < 70 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Sức khoẻ pin dưới 70% — nên cân nhắc thay pin")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
    
    // MARK: - Technical Data Card
    
    private var technicalDataCard: some View {
        VStack(spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "cpu")
                    .font(.system(size: 14))
                    .foregroundColor(.cyan)
                Text("Dữ liệu kỹ thuật")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
            }
            
            VStack(spacing: 0) {
                techRow(label: "Điện áp (V)", value: String(format: "%.2f", viewModel.voltage))
                Divider().background(Color.white.opacity(0.06))
                techRow(label: "Dòng điện (A)", value: String(format: "%.3f", viewModel.current))
                Divider().background(Color.white.opacity(0.06))
                techRow(label: "SOC (raw)", value: viewModel.battery?.soc?.soc.map { String(format: "%.4f", $0) } ?? "—")
                Divider().background(Color.white.opacity(0.06))
                techRow(label: "Chu kỳ (raw)", value: viewModel.battery?.soc?.cycles.map { String(format: "%.1f", $0) } ?? "—")
                Divider().background(Color.white.opacity(0.06))
                techRow(label: "Công suất (W)", value: String(format: "%.1f", viewModel.powerWatts))
                
                if !viewModel.ntcTemps.isEmpty {
                    Divider().background(Color.white.opacity(0.06))
                    techRow(label: "NTC sensors", value: viewModel.ntcTemps.map { String(format: "%.1f°C", $0) }.joined(separator: ", "))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.02))
            )
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
    
    // MARK: - No Data View
    
    private var noDataView: some View {
        VStack(spacing: 20) {
            Image(systemName: "battery.0")
                .font(.system(size: 48))
                .foregroundColor(.gray.opacity(0.4))
            
            Text(viewModel.isConnected ? "Đang đọc dữ liệu BMS..." : "Chưa kết nối xe")
                .font(.headline)
                .foregroundColor(.gray)
            
            Text(viewModel.isConnected
                 ? "Vui lòng đợi vài giây để nhận dữ liệu từ xe."
                 : "Kết nối xe để xem thông tin pin chi tiết.")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.6))
                .multilineTextAlignment(.center)
            
            if viewModel.isLoading {
                ProgressView()
                    .tint(.cyan)
                    .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Cell Voltage Grid
    
    private var cellVoltageGridCard: some View {
        let gridColumns = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]
        let voltages = viewModel.cellVoltages
        let maxV = voltages.max() ?? 0
        let minV = voltages.min() ?? 0
        
        return VStack(spacing: 14) {
            // Section header
            HStack {
                Image(systemName: "battery.100")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                Text("Điện áp Cell Pin")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Button(action: { showCellInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                Text("\(viewModel.cellCount)S")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
            }
            
            // Summary stats
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                cellStatPill(label: "TB", value: viewModel.avgCellVoltage, color: .cyan)
                cellStatPill(label: "Max", value: viewModel.maxCellVoltage, color: .green)
                cellStatPill(label: "Min", value: viewModel.minCellVoltage, color: .orange)
                cellStatPill(label: "Δ", value: viewModel.cellVoltageDelta,
                             color: viewModel.hasCellImbalance ? .red : .gray)
            }
            
            // Cell voltage grid (3 columns)
            LazyVGrid(columns: gridColumns, spacing: 6) {
                ForEach(Array(voltages.enumerated()), id: \.offset) { index, voltage in
                    cellVoltageTile(index: index, voltage: voltage,
                                   isMax: voltage == maxV && voltages.count > 1,
                                   isMin: voltage == minV && voltages.count > 1)
                }
            }
            
            // Cell imbalance warning
            if viewModel.hasCellImbalance {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("Chênh lệch điện áp cell > 50mV — cần cân bằng cell")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.9))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            viewModel.hasCellImbalance
                            ? Color.orange.opacity(0.3) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
        )
        .padding(.horizontal)
    }
    
    private func cellVoltageTile(index: Int, voltage: Double, isMax: Bool, isMin: Bool) -> some View {
        let color = cellVoltageColor(voltage)
        return HStack(spacing: 4) {
            Text("\(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(color.opacity(0.7))
                .frame(width: 16)
            
            Text(String(format: "%.3f", voltage))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            
            if isMax {
                Image(systemName: "arrow.up")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.green)
            } else if isMin {
                Image(systemName: "arrow.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(color.opacity(0.12), lineWidth: 1)
                )
        )
    }
    
    private func cellVoltageColor(_ v: Double) -> Color {
        // Li-ion cell: 2.5V (empty) → 4.2V (full)
        switch v {
        case ..<3.0:   return .red
        case 3.0..<3.3: return .orange
        case 3.3..<3.6: return .yellow
        case 3.6..<3.9: return .green
        default:        return Color(red: 0.2, green: 0.85, blue: 0.5)
        }
    }
    
    private func cellStatPill(label: String, value: Double?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.map { String(format: "%.3fV", $0) } ?? "—")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
        )
    }
    
    // MARK: - Extra Keys Debug Card
    
    private var extraKeysDebugCard: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "ant.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.purple)
                Text("JSON Keys chưa decode")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Spacer()
            }
            
            Text(viewModel.extraKeys.joined(separator: ", "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.purple.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("Firmware trả về các key này nhưng app chưa xử lý. Bổ sung vào BatteryTelemetry model.")
                .font(.caption2)
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.purple.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
    
    // MARK: - Helper Views
    
    private func statRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(color)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }
    
    private func techRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: - Computed
    
    private var chargingColor: Color {
        switch viewModel.chargingState {
        case .charging: return .green
        case .discharging: return .orange
        case .idle: return .gray
        }
    }
    
    private var cycleProgress: CGFloat {
        min(1.0, CGFloat(viewModel.cycleCount) / 1000.0)
    }
    
    private var cycleBarColor: Color {
        switch viewModel.cycleCount {
        case 0..<300:  return .green
        case 300..<600: return .yellow
        case 600..<800: return .orange
        default:        return .red
        }
    }
}
