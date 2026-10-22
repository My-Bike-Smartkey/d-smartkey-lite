import XCTest
@testable import D_SmartKey

/// Fixtures giả trong test bundle được chạy trực tiếp với codec Swift thật.
final class ProtocolVectorTests: XCTestCase {
    private func vectors() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "protocol-vectors", withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func data(_ hex: String) -> Data {
        let characters = Array(hex)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...$0+1]), radix: 16)!
        })
    }

    func testSharedAuthenticationVectorsIncludingUnsignedCounter() throws {
        for item in try XCTUnwrap(vectors()["auth"] as? [[String: Any]]) {
            let challenge = data(item["challenge_hex"] as! String)
            let counter = UInt32((item["counter"] as! NSNumber).uint64Value)
            XCTAssertEqual(try BLECryptography.counter(from: challenge), counter)
            XCTAssertEqual(try BLECryptography.solveChallenge(challengeBytes: challenge, pin: item["pin"] as! String), item["response_ascii"] as? String)
            XCTAssertTrue(BLECryptography.confirmsAuthentication(challenge: counter,
                response: UInt32((item["confirmed_counter"] as! NSNumber).uint64Value)))
            XCTAssertFalse(BLECryptography.confirmsAuthentication(challenge: counter,
                response: UInt32((item["rejected_counter"] as! NSNumber).uint64Value)))
        }
    }

    func testSharedLockPayloadsAndCommandBytes() throws {
        let all = try vectors()
        for item in all["lock_states"] as! [[String: String]] {
            let status = IoTLockState.parse(from: data(item["hex"]!))
            switch item["state"]! {
            case "locked": XCTAssertEqual(status, .locked)
            case "unlocked": XCTAssertEqual(status, .unlocked)
            case "armed": XCTAssertEqual(status, .armed)
            default: if case .unknown = status {} else { XCTFail("Unknown payload must remain unknown") }
            }
        }
        let commands = ["power_on": BLECommand.powerOn, "power_off": BLECommand.powerOff,
                        "arm": BLECommand.lock, "find_start": BLECommand.findStart, "find_stop": BLECommand.findStop]
        for item in all["commands"] as! [[String: Any]] {
            XCTAssertEqual(commands[item["command"] as! String], data(item["hex"] as! String))
        }
    }

    func testSharedTelemetryVectorsAndNonzeroDataIndices() throws {
        for item in try XCTUnwrap(vectors()["dashboard"] as? [[String: Any]]) {
            let payload = data(item["hex"] as! String)
            // Data slices can have a nonzero startIndex; decode offsets from payload start.
            let sliced = (Data([0xAA]) + payload).dropFirst()
            for bytes in [payload, sliced] {
                let telemetry: (Float, Float, Float)
                if item["format"] as! String == "float32_le_40" {
                    let value = DashboardTelemetry(from: bytes)
                    telemetry = (value.odometerKm, value.motorTemp, value.controllerTemp)
                    XCTAssertEqual(value.speedKmh, (item["speed_kmh"] as! NSNumber).floatValue)
                } else {
                    let value = BLETelemetryParser.parseTelemetry(from: bytes)
                    telemetry = (value.odometerKm, value.motorTemp, value.controllerTemp)
                }
                XCTAssertEqual(telemetry.0, (item["odometer_km"] as! NSNumber).floatValue)
                XCTAssertEqual(telemetry.1, (item["motor_temp_c"] as! NSNumber).floatValue)
                XCTAssertEqual(telemetry.2, (item["controller_temp_c"] as! NSNumber).floatValue)
            }
        }
    }
}
