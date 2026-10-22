import XCTest
@testable import D_SmartKey

/// §4.5 (P3) — ConnectionIntent + migration một chiều isUserPaused → connectionIntent.
final class ConnectionIntentMigrationTests: XCTestCase {

    private func freshSuite() -> UserDefaults {
        let name = "test.migration.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    func test_intentSemantics() {
        XCTAssertEqual(ConnectionIntent.autoConnect.isManualOnly, false)
        XCTAssertTrue(ConnectionIntent.manualOnlyPausedByUser.isManualOnly)
        XCTAssertTrue(ConnectionIntent.manualOnlyNearbyNotInUse.isManualOnly)
        // Raw roundtrip (đảm bảo key UserDefaults ổn định — KHÔNG đổi tên case)
        XCTAssertEqual(ConnectionIntent(rawValue: "manualOnlyNearbyNotInUse"), .manualOnlyNearbyNotInUse)
        XCTAssertEqual(ConnectionIntent(rawValue: "manualOnlyPausedByUser"), .manualOnlyPausedByUser)
        XCTAssertEqual(ConnectionIntent(rawValue: "autoConnect"), .autoConnect)
    }

    func test_migration_isUserPausedTrue_becomesManualOnlyPausedByUser() {
        let suite = freshSuite()
        suite.set(true, forKey: "isUserPaused")
        let pm = PreferencesManager(defaults: suite)
        XCTAssertEqual(pm.connectionIntent, .manualOnlyPausedByUser)
        XCTAssertEqual(suite.string(forKey: "connectionIntent"), "manualOnlyPausedByUser",
                       "Intent migrated phải được persist ngay")
    }

    func test_migration_isUserPausedFalse_staysAutoConnect() {
        let suite = freshSuite()
        suite.set(false, forKey: "isUserPaused")
        let pm = PreferencesManager(defaults: suite)
        XCTAssertEqual(pm.connectionIntent, .autoConnect)
    }

    func test_noLegacyKey_defaultsToAutoConnect() {
        let suite = freshSuite()
        let pm = PreferencesManager(defaults: suite)
        XCTAssertEqual(pm.connectionIntent, .autoConnect)
        XCTAssertFalse(pm.isManualOnly)
    }

    func test_existingIntent_winsOverLegacyKey() {
        let suite = freshSuite()
        suite.set(true, forKey: "isUserPaused")                       // legacy
        suite.set("manualOnlyNearbyNotInUse", forKey: "connectionIntent") // mới hơn
        let pm = PreferencesManager(defaults: suite)
        XCTAssertEqual(pm.connectionIntent, .manualOnlyNearbyNotInUse,
                       "Intent đã có thì KHÔNG bị legacy key ghi đè")
    }

    func test_setIntent_persists() {
        let suite = freshSuite()
        let pm = PreferencesManager(defaults: suite)
        pm.connectionIntent = .manualOnlyNearbyNotInUse
        // Tạo instance mới cùng suite → đọc lại được (persist thật, không chỉ RAM)
        let pm2 = PreferencesManager(defaults: suite)
        XCTAssertEqual(pm2.connectionIntent, .manualOnlyNearbyNotInUse)
    }
}
