import XCTest
@testable import D_SmartKey

/// Regression backlog: các mục còn cần nghiệm thu thiết bị thật.
/// Mỗi mục ghi rõ trạng thái: đã fix ở đâu / được phủ bởi unit test nào /
/// còn gì chờ kịch bản thiết bị thật.
final class RegressionBacklogTests: XCTestCase {

    // §3.1 [P0] — didConnect cùng context kẹt .scanning
    func test_didConnect_samePeripheralSession_mustEnterDiscoveringPhase() throws {
        // ✅ Hotfix đã áp trong DatBikeCore.didConnect (nhánh cùng context ép .connecting).
        // Log 13894 didConnect: 26% không được xử lý trong 120s → đã hạ bằng nhánh ép phase.
        throw XCTSkip("Còn kịch bản thiết bị thật §6.2 (1)-(2): xác minh didConnect luôn vào discovering")
    }

    // §3.2 [P2] — discovery error im lặng, watchdog bị hủy sớm
    func test_discoveryError_mustRetryThenAbortWithin30s() throws {
        // ✅ Đã áp P2: startDiscoveryWatchdog 10s + retryDiscoveryOrAbort(≤2 lần),
        //    didDiscoverServices error/empty → retry (không còn return im lặng),
        //    gate đủ 3 characteristic → cancelDiscoveryWatchdog.
        throw XCTSkip("Cần CBPeripheral mock để dựng GATT discovery — kịch bản thiết bị thật §6.2 (3)")
    }

    // §3.3 [P1] — auth bị cancel vẫn publish .active
    func test_cancelledAuthTask_mustNotPublishActiveOrNotify() throws {
        // ✅ Đã áp P1: BLEAuthenticator rethrow CancellationError + performNonCritical,
        //    executeAuthProtocol sessionGate sau mọi await.
        throw XCTSkip("Còn kịch bản thiết bị thật §6.2-7: pairing (2.5s) → forceReconnect giây 1 → không notification")
    }

    // §3.4 [P4] — Active → Nearby → Connect mất dispatcher
    func test_nearbyRoundTrip_mustKeepDispatcherAndPollingAlive() throws {
        // ✅ Đã áp P4: activateNearbyMode KHÔNG còn nil commandDispatcher/pollingEngine —
        //    services sống theo session (connection), chỉ stopPolling khi hạ mode.
        throw XCTSkip("Cần CBPeripheral mock dựng vòng nearby↔standby — xác minh thủ công §6.2 (8)")
    }

    // §3.5 [P1] — callback cũ hoàn tất operation phiên mới
    func test_stalePeripheralCallback_mustNotResumeCurrentSessionIO() throws {
        // ✅ Đã phủ bởi BLECharacteristicIOTests (cooldown + drop late response)
        //    và guard STALE_CALLBACK trong DatBikeCore delegate.
        throw XCTSkip("Chuyển sang: đã phủ unit — BLECharacteristicIOTests.test_lateResponse_dropped_doesNotCorruptNextRequest")
    }

    // §3.6 [P1] — cancelAll phá FIFO mutex khi owner đang chạy
    func test_cancelAllDuringOwnerExecution_mustNotStartNewTaskConcurrently() throws {
        // ✅ Đã phủ bởi BLETaskQueueTests.test_cancelAll_generationIsolation
        throw XCTSkip("Chuyển sang: đã phủ unit — BLETaskQueueTests.test_cancelAll_generationIsolation")
    }

    // §3.7 [P2] — retry bypass manualOnly + retry chồng chéo MIC/PhantomGuard
    func test_scheduledRetry_mustRespectManualOnlyIntent() throws {
        // ✅ Đã áp P2: RetryScheduler (actor) — 5 call site asyncAfter đã migrate,
        //    nhóm cancel chéo, session-bound token, pause/disconnect cancelAll.
        //    Đã phủ unit bởi RetrySchedulerTests (bind-đổi-session giết token, thay thế nhóm).
        throw XCTSkip("Chuyển sang: đã phủ unit — RetrySchedulerTests")
    }

    // §3.8 [P2] — stale disconnect hủy polling/auth phiên mới
    func test_staleDisconnectEvent_mustNotTearDownNewSession() throws {
        // ✅ Đã áp P2: guard ctx.peripheral !== peripheral → log STALE_DISCONNECT + return.
        throw XCTSkip("Cần 2 CBPeripheral mock — kịch bản thiết bị thật §6.2 (9)")
    }

    // §3.9 [P4] — nearby tự auth theo 1 mẫu RSSI, bỏ qua intent
    func test_nearbyMode_mustNotAutoAuthOnSingleRssiSpike() throws {
        // ✅ Đã áp P4: strongRssiConsecutiveCount ≥ 2 mới auth (standby + nearby),
        //    dải hysteresis ±5dB không đếm drain, manualOnly chặn cả 2 nhánh.
        throw XCTSkip("Cần CBPeripheral mock bơm RSSI — xác minh thủ công §6.2 (10)")
    }

    // §3.10 [P4] — relaunch/storm-restore bỏ qua ý định user
    func test_coldInitWithManualOnly_mustNotAdoptRestoredSession() throws {
        // ✅ Đã áp P4: willRestoreState guard manualOnly → cancel + .idle;
        //    connect() guard intent chặn mọi auto-connect sau cold-init.
        throw XCTSkip("Cần simulator kill/relaunch — kịch bản thiết bị thật §6.2 (11)")
    }

    // ═══ CODE_REVIEW_2026-10-19.md — đợt generation guards (I2–I4) ═══

    // I2 [P1] — callback discovery của peripheral cũ tác động context mới
    func test_staleDiscoveryCallback_mustNotMutateNewContext() throws {
        // ✅ Đã áp I2 trong DatBikeCore: didModifyServices / didDiscoverServices /
        //    didDiscoverCharacteristicsFor đều guard `peripheral === activeContext.peripheral`
        //    rồi log [STALE_CALLBACK] + return — khớp idiom read/write/RSSI đã có.
        throw XCTSkip("Cần 2 CBPeripheral mock bơm discovery callback xen kẽ — kịch bản thiết bị thật")
    }

    // I3 [P1] — Service Changed tái dùng context nhưng không restart phase
    func test_serviceChanged_mustTeardownAndReenterConnecting() throws {
        // ✅ Đã áp I3 trong DatBikeCore.didModifyServices: teardown (stopPolling, cancel
        //    authTask/watchdog/timers, reset flags), tạo context mới (generation mới), bridge
        //    .active → .scanning → .connecting rồi startDiscoveryWatchdog + discoverServices.
        //    Cơ chế bridge được khóa bởi
        //    BLEStateMachineTests.test_transition_activeToConnecting_viaScanningBridge_reachesConnecting.
        throw XCTSkip("Cần CBPeripheral mock phát didModifyServices lúc .active — kịch bản thiết bị thật")
    }

    // I4 [P1] — session restore không kiểm tra context/intent sau await
    func test_sessionRestore_mustRejectResultIfSessionChangedDuringAwait() throws {
        // ✅ Đã áp I4 trong DatBikeCore.tryRestoreActiveSession: closure sau await thêm gate
        //    `self.activeContext === ctx` TRƯỚC khi kiểm tra peripheral.state (khớp
        //    executeAuthProtocol.sessionGate); nhánh stale KHÔNG đụng isRestoringSession vì
        //    cờ đó đã thuộc generation mới.
        throw XCTSkip("Cần CBPeripheral mock reconnect sang context mới giữa lúc đọc — kịch bản thiết bị thật")
    }

    // I7 [P2] — arm anti-theft: lệnh khi xe đang BẬT là no-op, confirm nhận nhầm locked
    func test_armAntiTheft_mustPowerOffFirstAndConfirmOnlyOnArmed() throws {
        // ✅ Đã áp trong BLECommandDispatcher.armAntiTheft (field log 8, 19/10 21:18):
        //    (1) đọc trạng thái trước — đang .unlocked thì turnOffBike() rồi mới ghi arm;
        //    (2) poll confirm CHỈ nhận .armed (0700); kết thúc ở .locked trả trạng thái
        //    thật kèm warning "chưa chứng minh chống trộm" thay vì success giả.
        throw XCTSkip("BLEConnectionContext cần CBPeripheral thật — kịch bản thiết bị thật (fw 1.11.0)")
    }

    // Field log 8 — MIC rỉ rả nổ CB_RECYCLE liên tiếp 3 lần/1s, đốt sạch quota
    func test_micDribbleRecycle_mustRequireFiveNewFailuresBetweenRecycles() throws {
        // ✅ Đã áp trong DatBikeCore.didFailToConnect: thêm micFailureCountAtLastRecycle,
        //    rỉ rả chỉ recycle khi tích đủ 5 fail MỚI kể từ lần recycle trước (cả nhánh
        //    hết-quota lẫn nhánh rỉ rả đều cập nhật mốc). Đồng thời sửa cluster-detect
        //    dùng previousFailureTime (trước đây so với chính timestamp vừa ghi đè →
        //    progressive backoff là dead code, delay luôn 2s).
        throw XCTSkip("Đường didFailToConnect cần CBCentralManager/CBPeripheral thật — kịch bản thiết bị thật")
    }
}
