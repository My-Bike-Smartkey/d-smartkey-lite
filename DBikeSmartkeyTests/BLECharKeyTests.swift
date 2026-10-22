import XCTest
import CoreBluetooth
@testable import D_SmartKey

/// BLECharKey prefix resolver — fw 1.11.0 xoay suffix full UUID nhưng giữ prefix 8 hex (E5).
final class BLECharKeyTests: XCTestCase {

    // MARK: - Prefix ổn định qua firmware rotation

    func testFullUUIDLegacyFirmwareResolvesToKey() {
        // fw ≤1.10.x — full UUID gốc trong BLEConstants
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.fwVersion), .fwVersion)
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.authChallenge), .authChallenge)
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.timeSync), .timeSync)
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.autoUnlock), .autoUnlock)
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.smartkeyEcho), .smartkeyEcho)
        XCTAssertEqual(BLECharKey.key(forUUID: BLECharacteristic.unlockCmd), .unlockCmd)
    }

    func testRotatedUUIDFirmware1110ResolvesToSameKey() {
        // fw 1.11.0 — suffix đã xoay, prefix giữ nguyên (bằng chứng runtime E5)
        XCTAssertEqual(BLECharKey.key(forUUID: CBUUID(string: "D1DA175E-B1B5-4248-8F36-98C9482B8D24")), .fwVersion)
        // Sinh UUID xoay giả cho mọi key — prefix phải resolve đúng
        for key in BLECharKey.allCases where key != .serviceChanged {
            let rotated = CBUUID(string: "\(key.uuidPrefix)-DEAD-BEEF-1234-567890ABCDEF")
            XCTAssertEqual(BLECharKey.key(forUUID: rotated), key,
                           "prefix \(key.uuidPrefix) phải resolve đúng sau khi fw xoay suffix")
        }
    }

    func testServiceChanged16Bit() {
        XCTAssertEqual(BLECharKey.key(forUUID: CBUUID(string: "2A05")), .serviceChanged)
    }

    // MARK: - UUID lạ → nil (không đoán bừa)

    func testUnknownUUIDReturnsNil() {
        XCTAssertNil(BLECharKey.key(forUUID: CBUUID(string: "F7E2C8A1-3D5B-4906-9E1F-8C0A2B4D6E8F")), "UUID service mới không phải characteristic đã biết")
        XCTAssertNil(BLECharKey.key(forUUID: CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")))
        XCTAssertNil(BLECharKey.key(forUUID: CBUUID(string: "180D")))
    }

    // MARK: - Tính toàn vẹn bảng prefix

    func testPrefixesUnique() {
        let prefixes = BLECharKey.allCases.map { $0.uuidPrefix }
        XCTAssertEqual(prefixes.count, Set(prefixes).count, "2 characteristic không được chung prefix")
    }

    // MARK: - Service fw 1.11.0

    func testFirmware1110ServiceKnown() {
        XCTAssertEqual(BLEService.fw11Ext.uuidString, "F7E2C8A1-3D5B-4906-9E1F-8C0A2B4D6E8F")
        XCTAssertTrue(BLEService.allServices.contains(BLEService.fw11Ext), "phải discover service mới sau connect")
        XCTAssertTrue(BLEService.scanUUIDs.contains(BLEService.fw11Ext))
    }

    // MARK: - Serial từ manufacturer data

    func testManufacturerSerialParsing() {
        // E2: mfg data 9 byte ASCII serial (đổi sang serial giả để không lộ serial xe thật)
        let data = Data([0x34, 0x53, 0x53, 0x52, 0x30, 0x30, 0x41, 0x42, 0x43])
        XCTAssertEqual(BLEService.serial(fromManufacturerData: data), "4SSR00ABC")
    }

    func testManufacturerSerialRejectsGarbage() {
        XCTAssertNil(BLEService.serial(fromManufacturerData: nil))
        XCTAssertNil(BLEService.serial(fromManufacturerData: Data([0x00])))                    // quá ngắn
        XCTAssertNil(BLEService.serial(fromManufacturerData: Data(repeating: 0xFF, count: 9))) // không phải ASCII
    }
}
