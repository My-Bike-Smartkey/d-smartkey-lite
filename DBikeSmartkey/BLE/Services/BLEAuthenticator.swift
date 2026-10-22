import Foundation
import CoreBluetooth

class BLEAuthenticator: IoTAuthService {
    
    private let context: BLEConnectionContext
    private let pin: String
    private let isKnownDevice: Bool
    
    init(context: BLEConnectionContext, pin: String, isKnownDevice: Bool) {
        self.context = context
        self.pin = pin
        self.isKnownDevice = isKnownDevice
    }
    
    func authenticate() async throws -> Bool {
        let authChar = try context.requireCharacteristic(BLECharacteristic.authChallenge)
        let pinData = Data(pin.utf8)

        if isKnownDevice {
            // ── RECONNECT FLOW (SHA-256 + Counter Verification) ──
            try await authenticateWithSHA(authChar: authChar)
        } else {
            // ── PAIRING FLOW (NFC PIN plain-text) ──
            try await pairWithPIN(authChar: authChar, pinData: pinData)
        }

        // §3.3: sau mỗi chặng await dài — kiểm tra cancellation trước khi đi tiếp.
        try Task.checkCancellation()

        // ── TIME SYNC (44e2bde6) — seconds since midnight UTC+7 ──
        // §3.3: KHÔNG dùng `try?` (nuốt luôn CancellationError → app tưởng auth xong).
        // Lỗi GATT thật được downgrade thành warning; cancellation phải throw lên.
        if let syncChar = try? context.requireCharacteristic(BLECharacteristic.timeSync) {
            let vnTZ = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = vnTZ
            let comps = cal.dateComponents([.hour, .minute, .second], from: Date())
            let secs = (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
            let timeSyncValue = String(secs)
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "Xác thực: Đồng bộ thời gian = \(timeSyncValue) (\(comps.hour ?? 0):\(String(format: "%02d", comps.minute ?? 0)):\(String(format: "%02d", comps.second ?? 0)) VN)"))
            try await performNonCritical("TimeSync") {
                try await context.io.writeValue(Data(timeSyncValue.utf8), to: syncChar, type: .withResponse)
            }
        }

        // ── PROXIMITY TOKEN ──
        if PreferencesManager.shared.skipProximityToken {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[AUTH] Bỏ qua Proximity Token (skipProximityToken=true)"))
        } else if let autoChar = try? context.requireCharacteristic(BLECharacteristic.autoUnlock) {
            let token = UUID().uuidString
            try await performNonCritical("ProximityToken") {
                try await context.io.writeValue(Data(token.utf8), to: autoChar, type: .withResponse)
            }
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[AUTH] Proximity Token đã gửi: \(token.prefix(8))..."))
        }

        try Task.checkCancellation()
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
            message: "Xác thực: Phiên làm việc sẵn sàng ✅"))
        return true
    }

    /// §3.3: Bước không chặn (timeSync / token / confirm) — lỗi GATT chỉ là warning,
    /// nhưng CancellationError PHẢI ném tiếp để caller dừng hẳn (không publish .active ảo).
    private func performNonCritical(_ op: String, _ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch is CancellationError {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[AUTH] \(op) bị cancel → dừng xác thực (không coi là thành công)"))
            throw CancellationError()
        } catch {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[AUTH] \(op) thất bại (không chặn xác thực): \(error.localizedDescription)"))
        }
    }
    
    // MARK: - SHA-256 Reconnect Flow
    
    private func authenticateWithSHA(authChar: CBCharacteristic) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA] Bắt đầu | peripheral=\(context.peripheral.identifier.uuidString.prefix(8)) | peripheralState=\(context.peripheral.state.rawValue)"))
        
        // 1. Read challenge (counter)
        let challengeData = try await context.queue.enqueue {
            try await self.context.io.readValue(from: authChar)
        }
        guard challengeData.count >= 4 else {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "[SHA] Challenge data quá ngắn: \(challengeData.count) bytes (cần >=4) | raw=\(challengeData.hexString)"))
            throw IoTError.invalidResponseFormat
        }
        
        let currentCounter = try BLECryptography.counter(from: challengeData)
        let isEven = currentCounter % 2 == 0
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA] Challenge nhận được | counter=\(currentCounter) | isEven=\(isEven) | rawHex=\(challengeData.hexString) | dataLen=\(challengeData.count)"))

        // Per the bike protocol, an odd counter already denotes an authenticated
        // session. Writing another hash would mutate a valid session unnecessarily.
        if !isEven { return }
        
        // 2. SHA-256(counter >> 1 + PIN)
        let hashHexStr = try BLECryptography.solveChallenge(challengeBytes: challengeData, pin: pin)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA] Hash tính xong | hashPrefix=\(hashHexStr.prefix(16))... | hashLen=\(hashHexStr.count)"))
        
        // 3. Write hash
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA] Ghi hash vào authChallenge..."))
        try await context.queue.enqueue {
            try await self.context.io.writeValue(Data(hashHexStr.utf8), to: authChar, type: .withResponse)
        }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA] Hash đã ghi thành công. Bắt đầu verify counter..."))
        
        // 4. Verify counter chuyển sang LẺ — retry với delay tăng dần
        // Rule: counter CHẴN = chờ xác thực, counter LẺ = đã xác thực
        // Thành công = counter chuyển từ chẵn → lẻ
        let retryDelays: [UInt64] = [200, 400, 700, 1200]
        var authVerified = false
        var latestVerifiedCounter: UInt32? = nil
        
        for (attempt, delayMs) in retryDelays.enumerated() {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            
            let verifyData = try await context.queue.enqueue {
                try await self.context.io.readValue(from: authChar)
            }
            guard verifyData.count >= 4 else {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "Xác thực vòng \(attempt+1): Phản hồi lỗi, đang nhận lại..."))
                continue
            }
            
            let newCounter = try BLECryptography.counter(from: verifyData)
            latestVerifiedCounter = newCounter
            
            let isOdd = newCounter % 2 != 0
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[SHA] Verify vòng \(attempt+1)/\(retryDelays.count) | counter=\(newCounter) | isOdd=\(isOdd) | prevCounter=\(currentCounter) | delta=\(Int(newCounter) - Int(currentCounter)) | delay=\(delayMs)ms"))
            
            if BLECryptography.confirmsAuthentication(challenge: currentCounter, response: newCounter) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[SHA] Counter chuyển lẻ → auth thành công ✅ | counter=\(newCounter)"))
                authVerified = true
                break
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "Xác thực vòng \(attempt+1): Vẫn đang mở luồng mã hóa..."))
        }
        
        if !authVerified {
            if let latestCounter = latestVerifiedCounter {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "[SHA] Auth chưa verified | latestCounter=\(latestCounter) | currentCounter=\(currentCounter) | isEven=\(latestCounter % 2 == 0) | jumped=\(latestCounter != currentCounter)"))
                if latestCounter != currentCounter && latestCounter % 2 == 0 {
                    PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                        message: "[SHA] Counter nhảy sang chẵn mới (\(currentCounter)→\(latestCounter)) → retry vòng 2"))
                    try await retrySHAWithNewCounter(authChar: authChar, newCounter: latestCounter)
                    return
                }
            }
            
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "[SHA] Auth thất bại hoàn toàn | currentCounter=\(currentCounter) | latestCounter=\(latestVerifiedCounter ?? 0)"))
            throw IoTError.shaChallengeFailed
        }
    }
    
    /// Retry SHA auth 1 lần khi counter nhảy sang chẵn mới (xe từ chối hash trước đó)
    private func retrySHAWithNewCounter(authChar: CBCharacteristic, newCounter: UInt32) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA_RETRY] Vòng 2 | newCounter=\(newCounter) | peripheral=\(context.peripheral.identifier.uuidString.prefix(8))"))
        
        var counterLE = newCounter.littleEndian
        let challengeData = Data(bytes: &counterLE, count: 4)
        
        let hashHexStr = try BLECryptography.solveChallenge(challengeBytes: challengeData, pin: pin)
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[SHA_RETRY] Hash vòng 2 | hashPrefix=\(hashHexStr.prefix(16))..."))
        
        try await context.queue.enqueue {
            try await self.context.io.writeValue(Data(hashHexStr.utf8), to: authChar, type: .withResponse)
        }
        
        // Verify counter chuyển lẻ
        let retryDelays: [UInt64] = [300, 600, 1000, 1500]
        for (attempt, delayMs) in retryDelays.enumerated() {
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            
            let verifyData = try await context.queue.enqueue {
                try await self.context.io.readValue(from: authChar)
            }
            guard verifyData.count >= 4 else { continue }
            
            let counter = try BLECryptography.counter(from: verifyData)
            let isOdd = counter % 2 != 0
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[SHA_RETRY] Verify vòng \(attempt+1) | counter=\(counter) | isOdd=\(isOdd) | delay=\(delayMs)ms"))
            
            if BLECryptography.confirmsAuthentication(challenge: newCounter, response: counter) {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "[SHA_RETRY] Vòng 2 thành công ✅ | counter=\(counter)"))
                return
            }
        }
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
            message: "Xác thực lại: Từ chối phiên kết nối — yêu cầu thẻ vật lý NFC."))
        throw IoTError.shaChallengeFailed
    }
    
    // MARK: - NFC Pairing Flow
    
    private func pairWithPIN(authChar: CBCharacteristic, pinData: Data) async throws {
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Xác thực: Chế độ thẻ từ — đưa thẻ vật lý lại gần đồng hồ..."))
        
        // Retry PIN write: mỗi 2s × 10 lần (tổng 20s timeout)
        var isPaired = false
        for i in 1...10 {
            do {
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                    message: "Xác thực: Liên kết thẻ... (\(i)/10)"))
                try await context.queue.enqueue {
                    try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
                }
                isPaired = true
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .success,
                    message: "Xác thực: Mã hóa thiết bị hoàn tất!"))
                break
            } catch is CancellationError {
                // §3.3: task bị cancel → dừng ngay, không retry tiếp
                PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                    message: "Xác thực: Bị cancel lúc liên kết thẻ (\(i)/10) → dừng"))
                throw CancellationError()
            } catch {
                if i < 10 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
        }

        if !isPaired {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .error,
                message: "Xác thực: Hết thời gian giao tiếp vật lý thiết bị"))
            throw IoTError.shaChallengeFailed
        }

        // PIN confirm lần 1 + lần 2 (§3.3: cancellation-aware, lỗi GATT chỉ warning)
        try await performNonCritical("PINConfirm#1") {
            try await context.queue.enqueue {
                try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        try await performNonCritical("PINConfirm#2") {
            try await context.queue.enqueue {
                try await self.context.io.writeValue(pinData, to: authChar, type: .withResponse)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    
    /// Huỷ xác thực (De-authenticate) bằng cách gửi mã SHA sai cho xe.
    /// Giúp ngắt bảo mật nhưng không ngắt kết nối vật lý.
    func invalidateSession() async throws {
        let authChar = try context.requireCharacteristic(BLECharacteristic.authChallenge)
        
        let challengeData = try await context.queue.enqueue {
            try await self.context.io.readValue(from: authChar)
        }
        
        guard challengeData.count >= 4 else { return }
        
        // Tạo một hash rác dài 64 ký tự (giả mạo hash SHA256)
        let garbageHash = String(repeating: "F", count: 64)
        
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "Xác thực: Chấm dứt phiên điều khiển mã hóa từ xa..."))
            
        try await context.queue.enqueue {
            try await self.context.io.writeValue(Data(garbageHash.utf8), to: authChar, type: .withResponse)
        }
    }
    // MARK: - ASK Session Check
    
    /// Kiểm tra phiên auth còn sống không bằng cách đọc counter
    /// Counter LẺ = authenticated, Counter CHẴN = cần auth lại
    static func isSessionActive(context: BLEConnectionContext) async -> Bool {
        guard let authChar = try? context.requireCharacteristic(BLECharacteristic.authChallenge) else {
            return false
        }
        do {
            let data = try await context.queue.enqueue {
                try await context.io.readValue(from: authChar)
            }
            guard data.count >= 4 else { return false }
            let counter = try BLECryptography.counter(from: data)
            let isOdd = counter % 2 != 0
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                message: "[SESSION_CHECK] counter=\(counter) | isOdd=\(isOdd) → \(isOdd ? "ACTIVE ✅" : "INACTIVE")"))
            return isOdd
        } catch {
            PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .warning,
                message: "[SESSION_CHECK] Read failed: \(error.localizedDescription) → assume inactive"))
            return false
        }
    }
}
