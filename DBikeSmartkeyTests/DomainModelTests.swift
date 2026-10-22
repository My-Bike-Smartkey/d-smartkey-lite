import XCTest
@testable import D_SmartKey

/// P0 — Đặc tả domain models thuần (không phụ thuộc CoreBluetooth runtime).
final class DomainModelTests: XCTestCase {

    // MARK: - IoTLockState.parse

    func test_lockStateParse_knownPayloads() {
        XCTAssertEqual(IoTLockState.parse(from: Data([0x00, 0x00])), .locked)
        XCTAssertEqual(IoTLockState.parse(from: Data([0x30])), .locked)
        XCTAssertEqual(IoTLockState.parse(from: Data([0x02, 0x00])), .unlocked)
        XCTAssertEqual(IoTLockState.parse(from: Data([0x31])), .unlocked)
        XCTAssertEqual(IoTLockState.parse(from: Data([0x07, 0x00])), .armed)
    }

    func test_lockStateParse_unknownPayload() {
        if case .unknown = IoTLockState.parse(from: Data([0xFF, 0xFF])) {
            // đúng
        } else {
            XCTFail("Payload lạ phải là .unknown")
        }
    }

    func test_lockStateIsLocked() {
        XCTAssertTrue(IoTLockState.locked.isLocked)
        XCTAssertTrue(IoTLockState.armed.isLocked)
        XCTAssertFalse(IoTLockState.unlocked.isLocked)
        XCTAssertFalse(IoTLockState.unknown(Data()).isLocked)
    }

    // MARK: - IoTConnectionState

    func test_connectionStateIsConnectedSemantics() {
        // Điều kiện né splash-screen hiện tại — giữ nguyên hành vi này trong refactor
        XCTAssertTrue(IoTConnectionState.active.isConnected)
        XCTAssertTrue(IoTConnectionState.standby.isConnected)
        XCTAssertTrue(IoTConnectionState.nearby.isConnected)
        XCTAssertTrue(IoTConnectionState.authenticating.isConnected)
        XCTAssertFalse(IoTConnectionState.idle.isConnected)
        XCTAssertFalse(IoTConnectionState.scanning.isConnected)
        XCTAssertFalse(IoTConnectionState.connecting.isConnected)
    }

    // MARK: - Data.hexString

    func test_hexString() {
        XCTAssertEqual(Data([0x00, 0x0A, 0xFF]).hexString, "000aff")
    }

    // MARK: - BLEProtocol PIN generator

    func test_generateSecurePIN_structure() {
        let pin = BLEProtocol.generateSecurePIN()
        XCTAssertEqual(pin.count, 12, "PIN ghép đôi phải đúng 12 ký tự")
        XCTAssertTrue(pin.contains { $0.isLowercase })
        XCTAssertTrue(pin.contains { $0.isUppercase })
        XCTAssertTrue(pin.contains { $0.isNumber })
        XCTAssertTrue(pin.contains { "!@#$%^&*()-_=+".contains($0) })
    }

    // Firmware challenge vectors: byte order and exact even→odd transition
    // determine whether a command session is actually authenticated.
    func test_authChallenge_decodesLittleEndianAndHashesKnownVector() throws {
        let challenge = Data([0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(try BLECryptography.counter(from: challenge), 0x12345678)
        XCTAssertEqual(try BLECryptography.solveChallenge(challengeBytes: challenge, pin: "TESTPIN12345"),
            "cef0ffbc1a36c87dd6f7c6cf5b8f4dc6a63535d1363c23441ee8853f2f08c8be")
        XCTAssertThrowsError(try BLECryptography.counter(from: Data([0x78, 0x56, 0x34])))
    }

    func test_authChallenge_rejectsUnrelatedOddCounter() {
        XCTAssertTrue(BLECryptography.confirmsAuthentication(challenge: 100, response: 101))
        XCTAssertFalse(BLECryptography.confirmsAuthentication(challenge: 100, response: 103))
        XCTAssertFalse(BLECryptography.confirmsAuthentication(challenge: 100, response: 100))
        XCTAssertFalse(BLECryptography.confirmsAuthentication(challenge: 101, response: 101))
    }
}
