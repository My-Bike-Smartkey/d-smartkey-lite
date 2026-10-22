import XCTest
import CoreBluetooth
@testable import D_SmartKey

final class BLEAdvertisementDiagnosticsTests: XCTestCase {
    func testAlternatingNameAndServiceRemainSeparateSamples() throws {
        var store = BLEAdvertisementStore()
        let id = UUID(), date = Date()
        store.receive(id: id, cachedName: "Cached bike", data: [CBAdvertisementDataLocalNameKey: "Owner name"], rssi: -65, at: date)
        store.receive(id: id, cachedName: nil, data: [CBAdvertisementDataServiceUUIDsKey: [BLEService.auth]], rssi: -55, at: date.addingTimeInterval(1))
        let record = try XCTUnwrap(store.records[id])
        XCTAssertEqual(record.variants.count, 2)
        XCTAssertTrue(record.variants[0].payload.serviceUUIDs.isEmpty)
        XCTAssertNil(record.variants[1].payload.localName)
        XCTAssertEqual(record.observedServices, [BLEService.auth.uuidString])
        XCTAssertEqual(record.cachedName, "Cached bike")
        XCTAssertEqual(record.count, 2)
        XCTAssertEqual(record.rssi, -55)
    }

    func testRepeatsCountWithoutCreatingNewPayloadVariants() throws {
        var store = BLEAdvertisementStore()
        let id = UUID(), date = Date()
        for i in 0..<5 {
            store.receive(id: id, cachedName: nil, data: [CBAdvertisementDataLocalNameKey: "Bike"], rssi: -60 + i, at: date.addingTimeInterval(Double(i)))
        }
        let record = try XCTUnwrap(store.records[id])
        XCTAssertEqual(record.variants.count, 1)
        XCTAssertEqual(record.variants[0].count, 5)
        XCTAssertEqual(record.lastSeen, date.addingTimeInterval(4))
    }

    func testOverflowSolicitedAndServiceDataAreNotConfused() {
        let payload = BLEAdvertisementPayload([
            CBAdvertisementDataOverflowServiceUUIDsKey: [BLEService.auth],
            CBAdvertisementDataSolicitedServiceUUIDsKey: [BLEService.config],
            CBAdvertisementDataServiceDataKey: [BLEService.main: Data([1, 2])],
            CBAdvertisementDataTxPowerLevelKey: NSNumber(value: -8),
            CBAdvertisementDataIsConnectable: NSNumber(value: true)])
        XCTAssertEqual(payload.advertisedServices, [BLEService.auth.uuidString])
        XCTAssertEqual(payload.solicitedUUIDs, [BLEService.config.uuidString])
        XCTAssertEqual(payload.serviceData[BLEService.main.uuidString], Data([1, 2]))
        XCTAssertEqual(payload.txPower, -8)
        XCTAssertEqual(payload.connectable, true)
    }

    func testExportRedactsIdentityAndBytesButPreservesFilterUUIDs() throws {
        var store = BLEAdvertisementStore()
        let id = UUID()
        let serial = "4SSRTEST1", secret = Data([0xFA, 0xDE, 0x01])
        store.receive(id: id, cachedName: "Private cached name", data: [
            CBAdvertisementDataLocalNameKey: "Private advertised name",
            CBAdvertisementDataServiceUUIDsKey: [BLEService.auth],
            CBAdvertisementDataManufacturerDataKey: Data(serial.utf8),
            CBAdvertisementDataServiceDataKey: [BLEService.main: secret]], rssi: -50, at: Date())
        let record = try XCTUnwrap(store.records[id])
        let redacted = record.report(redacted: true), raw = record.report(redacted: false)
        for value in [id.uuidString, "Private cached name", "Private advertised name", serial, Data(serial.utf8).hexString, secret.hexString] {
            XCTAssertFalse(redacted.contains(value), value)
            XCTAssertTrue(raw.contains(value), value)
        }
        XCTAssertTrue(redacted.contains(BLEService.auth.uuidString))
        XCTAssertTrue(redacted.contains(BLEService.main.uuidString))
        let fromLog = PersistentLogger.redact("[ADV_DEBUG_REPORT]\n" + raw, identifiers: [])
        for value in [id.uuidString, "Private cached name", "Private advertised name", serial, Data(serial.utf8).hexString, secret.hexString] {
            XCTAssertFalse(fromLog.contains(value), value)
        }
        XCTAssertTrue(fromLog.contains(BLEService.auth.uuidString))
        XCTAssertTrue(fromLog.contains(BLEService.main.uuidString))
    }

    func testDeviceAndVariantCapsRetainObservedUUIDHistory() throws {
        var store = BLEAdvertisementStore()
        let id = UUID(), date = Date()
        store.receive(id: id, cachedName: nil, data: [CBAdvertisementDataServiceUUIDsKey: [BLEService.auth]], rssi: -50, at: date)
        for i in 0..<15 {
            store.receive(id: id, cachedName: nil, data: [CBAdvertisementDataLocalNameKey: "Bike \(i)"], rssi: -60, at: date.addingTimeInterval(Double(i+1)))
        }
        let record = try XCTUnwrap(store.records[id])
        XCTAssertEqual(record.variants.count, 12)
        XCTAssertEqual(record.discardedVariants, 4)
        XCTAssertEqual(record.observedServices, [BLEService.auth.uuidString])
        for _ in 0..<210 { store.receive(id: UUID(), cachedName: nil, data: [:], rssi: -70, at: date) }
        XCTAssertEqual(store.records.count, 200)
        XCTAssertEqual(store.droppedCallbacks, 11)
    }

    func testLatestObservedNameAndUnavailableRSSI() throws {
        var store = BLEAdvertisementStore()
        let id = UUID(), date = Date()
        for (i, name) in ["First", "Second", "First"].enumerated() {
            store.receive(id: id, cachedName: nil, data: [CBAdvertisementDataLocalNameKey: name], rssi: 127, at: date.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(store.records[id]?.displayName, "First")
        XCTAssertEqual(store.records[id]?.rssiRank, Int.min)
    }
}

@MainActor
final class BLEAdvertisementScannerTests: XCTestCase {
    func testStartStopAndLateCallbacks() throws {
        let transport = FakeAdvertisementScanTransport()
        let scanner = BLEAdvertisementScanner(transport: transport)
        scanner.start(); scanner.start()
        XCTAssertEqual(transport.starts, 1)
        transport.onEvent?(.state(.poweredOn))
        let id = UUID()
        transport.onEvent?(.discovered(id, "Cached", [CBAdvertisementDataServiceUUIDsKey: [BLEService.auth]], -60, Date()))
        XCTAssertEqual(scanner.records.count, 1)
        scanner.stop()
        transport.onEvent?(.discovered(UUID(), nil, [:], -50, Date()))
        transport.onEvent?(.state(.poweredOn))
        XCTAssertFalse(scanner.isRunning)
        XCTAssertEqual(scanner.records.count, 1)
        XCTAssertEqual(transport.stops, 1)
    }

    func testDeniedPermissionStopsAndRetryStartsCleanSession() {
        let transport = FakeAdvertisementScanTransport()
        let scanner = BLEAdvertisementScanner(transport: transport)
        scanner.start()
        transport.onEvent?(.state(.unauthorized))
        XCTAssertFalse(scanner.isRunning)
        XCTAssertTrue(scanner.status.contains("quyền Bluetooth"))
        scanner.start()
        transport.onEvent?(.state(.poweredOn))
        XCTAssertTrue(scanner.isRunning)
        XCTAssertTrue(scanner.records.isEmpty)
        scanner.stop()
    }

    func testTimeoutStopsOnlyItsOwnScan() async throws {
        let transport = FakeAdvertisementScanTransport()
        let scanner = BLEAdvertisementScanner(transport: transport, duration: 0.3)
        scanner.start(); scanner.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        scanner.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(scanner.isRunning)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(scanner.isRunning)
        XCTAssertEqual(transport.stops, 2)
    }
}

private final class FakeAdvertisementScanTransport: BLEAdvertisementScanTransport {
    var onEvent: ((BLEAdvertisementScanEvent) -> Void)?
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}
