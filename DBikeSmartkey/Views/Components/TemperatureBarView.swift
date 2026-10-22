// TemperatureBarView.swift — NTC per-cell visualization (optimized for many cells)

import SwiftUI

// MARK: - Compact Cell Tile (for grid)

struct CellTile: View {
    let index: Int
    let temperature: Double
    let isHottest: Bool
    let isCoolest: Bool
    
    private var tempColor: Color {
        switch temperature {
        case ..<25:    return Color(red: 0.2, green: 0.7, blue: 1.0)
        case 25..<35:  return Color(red: 0.2, green: 0.85, blue: 0.5)
        case 35..<45:  return Color(red: 1.0, green: 0.75, blue: 0.2)
        case 45..<55:  return Color(red: 1.0, green: 0.4, blue: 0.2)
        default:       return Color(red: 1.0, green: 0.25, blue: 0.25)
        }
    }
    
    private var statusIcon: String {
        switch temperature {
        case ..<25:    return "snowflake"
        case 25..<35:  return "checkmark.circle.fill"
        case 35..<45:  return "thermometer.medium"
        case 45..<55:  return "exclamationmark.triangle.fill"
        default:       return "flame.fill"
        }
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Cell number badge
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(tempColor.opacity(0.15))
                    .frame(width: 24, height: 24)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(tempColor)
            }
            
            // Temperature
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(String(format: "%.1f°", temperature))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    
                    if isHottest {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.red)
                    } else if isCoolest {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.cyan)
                    }
                }
                
                Text("Cell \(index + 1)")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Image(systemName: statusIcon)
                .font(.system(size: 10))
                .foregroundColor(tempColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            temperature > 45 ? Color.red.opacity(0.25) : Color.white.opacity(0.05),
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Expanded Cell Detail Card

struct CellDetailCard: View {
    let index: Int
    let temperature: Double
    let avgTemp: Double?
    let isHottest: Bool
    let isCoolest: Bool
    
    private var tempColor: Color {
        switch temperature {
        case ..<25:    return Color(red: 0.2, green: 0.7, blue: 1.0)
        case 25..<35:  return Color(red: 0.2, green: 0.85, blue: 0.5)
        case 35..<45:  return Color(red: 1.0, green: 0.75, blue: 0.2)
        case 45..<55:  return Color(red: 1.0, green: 0.4, blue: 0.2)
        default:       return Color(red: 1.0, green: 0.25, blue: 0.25)
        }
    }
    
    private var statusLabel: String {
        switch temperature {
        case ..<25:    return "Mát"
        case 25..<35:  return "Bình thường"
        case 35..<45:  return "Ấm"
        case 45..<55:  return "Nóng"
        default:       return "Nguy hiểm"
        }
    }
    
    private var statusIcon: String {
        switch temperature {
        case ..<25:    return "snowflake"
        case 25..<35:  return "checkmark.circle.fill"
        case 35..<45:  return "thermometer.medium"
        case 45..<55:  return "exclamationmark.triangle.fill"
        default:       return "flame.fill"
        }
    }
    
    private var deltaFromAvg: Double? {
        guard let avg = avgTemp else { return nil }
        return temperature - avg
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Cell number
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tempColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Text("\(index + 1)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(tempColor)
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Cell \(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                    
                    if isHottest {
                        Label("Max", systemImage: "arrow.up")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.red)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                    } else if isCoolest {
                        Label("Min", systemImage: "arrow.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.cyan.opacity(0.15)))
                    }
                }
                
                HStack(spacing: 4) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 9))
                        .foregroundColor(tempColor)
                    Text(statusLabel)
                        .font(.system(size: 9))
                        .foregroundColor(tempColor)
                    
                    if let delta = deltaFromAvg {
                        Text(String(format: "(%+.1f°)", delta))
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(abs(delta) > 3 ? .orange : .gray)
                    }
                }
            }
            
            Spacer()
            
            // Temperature
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(String(format: "%.1f", temperature))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("°C")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            temperature > 45 ? Color.red.opacity(0.3) : Color.white.opacity(0.05),
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Temperature Group View (all NTC sensors)

struct TemperatureGroupView: View {
    let temperatures: [Double]
    let avgTemp: Double?
    let maxTemp: Double?
    let tempDelta: Double?
    let hasHighTempWarning: Bool
    let hasTempImbalanceWarning: Bool
    
    @State private var showAllCells = false
    
    private let gridColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]
    
    private var hottestIdx: Int? {
        temperatures.enumerated().max(by: { $0.element < $1.element })?.offset
    }
    
    private var coolestIdx: Int? {
        temperatures.enumerated().min(by: { $0.element < $1.element })?.offset
    }
    
    var body: some View {
        VStack(spacing: 14) {
            // Section header
            HStack {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text("Chi tiết Cell Pin")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Spacer()
                
                if !temperatures.isEmpty {
                    Text("\(temperatures.count) cells")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                
                if hasHighTempWarning || hasTempImbalanceWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            
            if temperatures.isEmpty {
                HStack {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .foregroundColor(.gray)
                    Text("Không có dữ liệu cảm biến NTC")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 12)
            } else {
                // Summary stats
                HStack(spacing: 8) {
                    tempStatPill(label: "TB", value: avgTemp, color: .cyan)
                    tempStatPill(label: "Max", value: maxTemp, color: .orange)
                    tempStatPill(label: "Δ", value: tempDelta,
                                 color: hasTempImbalanceWarning ? .red : .gray)
                }
                
                // Toggle: Compact grid vs Expanded list
                if temperatures.count > 4 {
                    Button(action: { withAnimation(.easeInOut(duration: 0.25)) { showAllCells.toggle() } }) {
                        HStack(spacing: 4) {
                            Image(systemName: showAllCells ? "list.bullet" : "square.grid.2x2")
                                .font(.system(size: 10))
                            Text(showAllCells ? "Xem chi tiết" : "Xem dạng lưới")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.cyan.opacity(0.1)))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                
                if showAllCells || temperatures.count <= 4 {
                    // Expanded: individual cards (scrollable)
                    ForEach(Array(temperatures.enumerated()), id: \.offset) { index, temp in
                        CellDetailCard(
                            index: index,
                            temperature: temp,
                            avgTemp: avgTemp,
                            isHottest: index == hottestIdx && temperatures.count > 1,
                            isCoolest: index == coolestIdx && temperatures.count > 1
                        )
                    }
                } else {
                    // Compact: 2-column grid (default for many cells)
                    LazyVGrid(columns: gridColumns, spacing: 6) {
                        ForEach(Array(temperatures.enumerated()), id: \.offset) { index, temp in
                            CellTile(
                                index: index,
                                temperature: temp,
                                isHottest: index == hottestIdx && temperatures.count > 1,
                                isCoolest: index == coolestIdx && temperatures.count > 1
                            )
                        }
                    }
                }
                
                // Warnings
                if hasHighTempWarning {
                    warningBanner(
                        icon: "flame.fill",
                        text: "Nhiệt độ cao bất thường (> 45°C)",
                        color: .red
                    )
                }
                
                if hasTempImbalanceWarning {
                    warningBanner(
                        icon: "exclamationmark.triangle.fill",
                        text: "Chênh lệch nhiệt độ lớn (Δ > 5°C) — mất cân bằng cell",
                        color: .orange
                    )
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            (hasHighTempWarning || hasTempImbalanceWarning)
                            ? Color.red.opacity(0.3) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
        )
    }
    
    private func tempStatPill(label: String, value: Double?, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value.map { String(format: "%.1f°", $0) } ?? "—")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
        )
    }
    
    private func warningBanner(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(color)
            Text(text)
                .font(.caption2)
                .foregroundColor(color.opacity(0.9))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
