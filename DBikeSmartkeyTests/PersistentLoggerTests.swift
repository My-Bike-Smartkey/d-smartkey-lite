import XCTest
@testable import D_SmartKey

final class PersistentLoggerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testBaselinePersistsWithDebugDisabledAndImmediateRead() {
        let logger = PersistentLogger(directory: directory)
        logger.isLoggingEnabled = false
        for level in [BLELogEntry.LogLevel.info, .ble, .success, .warning, .error, .verbose] {
            logger.append(BLELogEntry(timestamp: Date(), level: level, message: level.rawValue))
        }
        XCTAssertEqual(logger.loadAllLogs().map(\.level), [.info, .ble, .success, .warning, .error])
    }

    func testReopenKeepsLogsAndMultilineMessages() {
        let logger = PersistentLogger(directory: directory)
        let message = "GATT ready\ncommand\tconfirmed"
        logger.append(BLELogEntry(timestamp: Date(), level: .info, message: message))
        XCTAssertEqual(logger.loadLogs(daysBack: 1).first?.message, message)
        let reopened = PersistentLogger(directory: directory)
        XCTAssertEqual(reopened.loadAllLogs().first?.message, message)
    }

    func testConcurrentEventsAreNotLost() {
        let logger = PersistentLogger(directory: directory)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            logger.append(BLELogEntry(timestamp: Date(), level: .info, message: "event-\(index)"))
        }
        XCTAssertEqual(Set(logger.loadAllLogs().map(\.message)).count, 200)
    }

    func testVerboseRemainsOptInAndClearCompletesBeforeRead() {
        let logger = PersistentLogger(directory: directory)
        logger.minimumLevel = .verbose
        logger.append(BLELogEntry(timestamp: Date(), level: .verbose, message: "RSSI"))
        XCTAssertEqual(logger.loadAllLogs().count, 1)
        logger.clearAll()
        XCTAssertTrue(logger.loadAllLogs().isEmpty)
    }

    func testSharingRedactsIdentifiersAndPreservesProtocolUUIDs() {
        let serial = "TEST00ABC"
        let gatt = "D1DA175E-B1B5-4248-8F36-98C9482B8D24"
        let input = "serial=\(serial) mfg=\(Data(serial.utf8).hexString) MAC=AA:BB:CC:DD:EE:FF char=\(gatt)"
        let result = PersistentLogger.redact(input, identifiers: [serial])
        XCTAssertFalse(result.contains(serial))
        XCTAssertFalse(result.contains(Data(serial.utf8).hexString))
        XCTAssertFalse(result.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertTrue(result.contains(gatt))
        let rawJSON = #"bikeConfigJson raw: {"frame":"FAKEFRAME123","mac":"AA:BB:CC:DD:EE:FF"}"#
        XCTAssertFalse(PersistentLogger.redact(rawJSON, identifiers: []).contains("FAKEFRAME123"))
    }
}
