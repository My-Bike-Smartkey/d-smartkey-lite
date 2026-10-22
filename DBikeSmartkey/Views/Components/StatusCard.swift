// StatusCard.swift — Connection and bike status card component

import SwiftUI

struct StatusCard: View {
    let connectionState: IoTConnectionState
    let rssi: Int
    let signalStrength: SignalStrength
    let bikeInfo: IoTVehicleInfo
    let batteryPercentage: Int
    let odometer: Float
    
    var body: some View {
        VStack(spacing: 0) {
            // Connection status header
            HStack(alignment: .center, spacing: 6) {
                Text(connectionState.displayText)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor)
                
                Spacer()
                
                if connectionState.isConnected {
                    SignalIndicator(strength: signalStrength, rssi: rssi)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            if connectionState.isConnected && !bikeInfo.isEmpty {
                Divider()
                    .background(Color.white.opacity(0.1))
                
                HStack(spacing: 8) {
                    InfoPill(icon: "number", text: bikeInfo.serial.isEmpty ? "—" : String(bikeInfo.serial.suffix(5)))
                    
                    if batteryPercentage > 0 {
                        InfoPill(icon: "battery.100", text: "\(batteryPercentage)%")
                    }
                    if odometer > 0 {
                        InfoPill(icon: "road.lanes", text: String(format: "%.0f km", odometer))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(statusColor.opacity(0.2), lineWidth: 1)
                )
        )
    }
    
    private var statusColor: Color {
        switch connectionState {
        case .active:            return .green
        case .scanning,
             .connecting,
             .authenticating:   return .orange
        case .error:            return .red
        default:                return .gray
        }
    }
}

// MARK: - Info Pill

struct InfoPill: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(text)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Action Card

struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let isActive: Bool
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.impactOccurred()
            action()
        }) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(color.opacity(isActive ? 0.25 : 0.1))
                        .frame(width: 48, height: 48)
                    
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(isActive ? color : color.opacity(0.7))
                }
                
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isActive ? color.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.96 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in withAnimation(.easeInOut(duration: 0.08)) { isPressed = true } }
                .onEnded { _ in withAnimation(.easeInOut(duration: 0.1)) { isPressed = false } }
        )
    }
}
