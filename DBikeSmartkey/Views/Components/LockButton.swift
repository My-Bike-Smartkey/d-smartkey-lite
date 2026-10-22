// LockButton.swift — Premium animated lock/unlock button

import SwiftUI

struct LockButton: View {
    let lockStatus: IoTLockState
    let isProcessing: Bool
    let action: () -> Void
    
    @State private var isPressed = false
    @State private var pulseScale: CGFloat = 1.0
    @State private var glowOpacity: Double = 0.4
    @State private var rotationAngle: Double = 0
    
    private var mainColor: Color {
        switch lockStatus {
        case .unlocked: return Color(red: 0.2, green: 0.85, blue: 0.5)
        case .locked:   return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .armed:    return Color(red: 1.0, green: 0.3, blue: 0.3)
        case .unknown:  return Color.gray
        }
    }
    
    private var iconName: String {
        switch lockStatus {
        case .unlocked: return "lock.open.fill"
        case .locked:   return "lock.fill"
        case .armed:    return "shield.lefthalf.filled"
        case .unknown:  return "questionmark.circle.fill"
        }
    }
    
    var body: some View {
        Button(action: {
            let impactFeedback = UIImpactFeedbackGenerator(style: .heavy)
            impactFeedback.impactOccurred()
            action()
        }) {
            ZStack {
                // Outer pulse ring
                Circle()
                    .stroke(mainColor.opacity(0.15), lineWidth: 2)
                    .frame(width: 200, height: 200)
                    .scaleEffect(pulseScale)
                
                // Glow circle
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [mainColor.opacity(glowOpacity), .clear],
                            center: .center,
                            startRadius: 40,
                            endRadius: 110
                        )
                    )
                    .frame(width: 220, height: 220)
                
                // Main button background
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                mainColor.opacity(0.3),
                                mainColor.opacity(0.1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        mainColor.opacity(0.8),
                                        mainColor.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3
                            )
                    )
                
                // Inner dark circle
                Circle()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.12))
                    .frame(width: 130, height: 130)
                
                // Icon
                if isProcessing {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: mainColor))
                        .scaleEffect(2.0)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(mainColor)
                        .rotationEffect(.degrees(rotationAngle))
                }
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    withAnimation(.easeInOut(duration: 0.1)) { isPressed = true }
                }
                .onEnded { _ in
                    withAnimation(.easeInOut(duration: 0.15)) { isPressed = false }
                }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
                glowOpacity = 0.6
            }
        }
        .onChange(of: lockStatus) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
                rotationAngle += lockStatus.isLocked ? 15 : -15
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    rotationAngle = 0
                }
            }
        }
        .disabled(isProcessing)
    }
}

// MARK: - Status Label

struct IoTLockStateLabel: View {
    let lockStatus: IoTLockState
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: lockStatus == .armed ? "shield.lefthalf.filled" : (lockStatus.isLocked ? "lock.fill" : "lock.open.fill"))
                .foregroundColor(lockStatus == .armed ? Color(red: 1.0, green: 0.3, blue: 0.3) : (lockStatus.isLocked ? Color(red: 1.0, green: 0.6, blue: 0.2) : Color(red: 0.2, green: 0.85, blue: 0.5)))
                .font(.title2)
            
            if case .armed = lockStatus {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đã bật chống trộm")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text("Nhấn để tắt chống trộm")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else if lockStatus.isLocked {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đã tắt")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text("Nhấn để bật lại xe")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang bật")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text("Nhấn để tắt")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
        )
    }
}
