// SignalIndicator.swift — RSSI signal strength visualization

import SwiftUI

enum SignalStrength: Int {
    case weak = 1
    case fair = 2
    case good = 3
    case excellent = 4
    
    var color: Color {
        switch self {
        case .weak: return .red
        case .fair: return .orange
        case .good: return .green
        case .excellent: return .green
        }
    }
    
    var label: String {
        switch self {
        case .weak: return "Yếu"
        case .fair: return "Tạm"
        case .good: return "Tốt"
        case .excellent: return "Rất tốt"
        }
    }
}

struct SignalIndicator: View {
    let strength: SignalStrength
    let rssi: Int
    
    var body: some View {
        HStack(spacing: 3) {
            // Signal bars
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= strength.rawValue ? strength.color : Color.white.opacity(0.15))
                    .frame(width: 3, height: CGFloat(bar * 4 + 4))
            }
            
            // RSSI value
            Text("\(rssi)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
                .padding(.leading, 2)
        }
        .frame(height: 24)
    }
}

// MARK: - Large Signal View (for settings/debug)

struct LargeSignalView: View {
    let strength: SignalStrength
    let rssi: Int
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(1...4, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar <= strength.rawValue ? strength.color : Color.white.opacity(0.1))
                        .frame(width: 8, height: CGFloat(bar * 8 + 6))
                }
            }
            .frame(height: 40)
            
            Text("\(rssi) dBm")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(strength.color)
            
            Text(strength.label)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}
