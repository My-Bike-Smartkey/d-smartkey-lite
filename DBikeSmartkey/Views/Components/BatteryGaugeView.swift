// BatteryGaugeView.swift — Premium circular gauge for SOC & Health display

import SwiftUI

struct BatteryGaugeView: View {
    let value: Int          // 0–100
    let label: String       // e.g. "SOC" or "Sức khoẻ"
    let unit: String        // e.g. "%" or "km"
    var size: CGFloat = 160
    var lineWidth: CGFloat = 14
    var showGlow: Bool = true
    
    @State private var animatedValue: Double = 0
    @State private var glowOpacity: Double = 0.3
    
    private var progress: Double {
        min(1.0, max(0, Double(value) / 100.0))
    }
    
    private var gaugeColor: Color {
        switch value {
        case 0..<20:   return Color(red: 1.0, green: 0.25, blue: 0.25)
        case 20..<40:  return Color(red: 1.0, green: 0.5, blue: 0.2)
        case 40..<60:  return Color(red: 1.0, green: 0.75, blue: 0.2)
        case 60..<80:  return Color(red: 0.4, green: 0.85, blue: 0.4)
        default:       return Color(red: 0.2, green: 0.85, blue: 0.5)
        }
    }
    
    private var gradientColors: [Color] {
        switch value {
        case 0..<20:   return [Color(red: 1.0, green: 0.2, blue: 0.2), Color(red: 0.9, green: 0.3, blue: 0.15)]
        case 20..<40:  return [Color(red: 1.0, green: 0.4, blue: 0.15), Color(red: 1.0, green: 0.6, blue: 0.2)]
        case 40..<60:  return [Color(red: 1.0, green: 0.7, blue: 0.15), Color(red: 0.9, green: 0.85, blue: 0.3)]
        case 60..<80:  return [Color(red: 0.3, green: 0.8, blue: 0.4), Color(red: 0.5, green: 0.9, blue: 0.4)]
        default:       return [Color(red: 0.15, green: 0.75, blue: 0.45), Color(red: 0.2, green: 0.9, blue: 0.6)]
        }
    }
    
    var body: some View {
        ZStack {
            // Glow effect
            if showGlow {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [gaugeColor.opacity(glowOpacity * 0.3), .clear],
                            center: .center,
                            startRadius: size * 0.2,
                            endRadius: size * 0.6
                        )
                    )
                    .frame(width: size * 1.3, height: size * 1.3)
            }
            
            // Background track
            Circle()
                .stroke(Color.white.opacity(0.06), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .frame(width: size, height: size)
            
            // Progress arc
            Circle()
                .trim(from: 0, to: animatedValue)
                .stroke(
                    AngularGradient(
                        colors: gradientColors + [gradientColors[0].opacity(0.6)],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
            
            // Inner dark circle
            Circle()
                .fill(Color(red: 0.06, green: 0.06, blue: 0.1))
                .frame(width: size - lineWidth * 2 - 8, height: size - lineWidth * 2 - 8)
            
            // Center content
            VStack(spacing: 2) {
                Text("\(value)")
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text(unit)
                    .font(.system(size: size * 0.08, weight: .medium))
                    .foregroundColor(.gray)
                
                Text(label)
                    .font(.system(size: size * 0.07, weight: .medium))
                    .foregroundColor(gaugeColor.opacity(0.8))
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2)) {
                animatedValue = progress
            }
            if showGlow {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    glowOpacity = 0.6
                }
            }
        }
        .onChange(of: value) { newValue in
            withAnimation(.easeInOut(duration: 0.6)) {
                animatedValue = Double(newValue) / 100.0
            }
        }
    }
}

// MARK: - Mini Gauge (for inline display in cards)

struct MiniGaugeView: View {
    let value: Int
    let label: String
    let icon: String
    var size: CGFloat = 56
    
    private var gaugeColor: Color {
        switch value {
        case 0..<30:   return .red
        case 30..<60:  return .orange
        case 60..<80:  return .yellow
        default:       return .green
        }
    }
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 4)
                    .frame(width: size, height: size)
                
                Circle()
                    .trim(from: 0, to: Double(value) / 100.0)
                    .stroke(gaugeColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(-90))
                
                Image(systemName: icon)
                    .font(.system(size: size * 0.3))
                    .foregroundColor(gaugeColor)
            }
            
            Text(label)
                .font(.caption2)
                .foregroundColor(.gray)
            
            Text("\(value)%")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}
