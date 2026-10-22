#if !NOASK
import XCTest
import AccessorySetupKit
import CoreBluetooth
@testable import D_SmartKey

final class ASKDiscoveryConfigurationTests: XCTestCase {
    func testBuild16NameOnlyFiltersAreRejectedBeforeSystemPicker() throws {
        for name in ["Ngựa sắt", "Dat Bike", "QT_"] {
            let descriptor = ASDiscoveryDescriptor()
            descriptor.bluetoothNameSubstring = name
            XCTAssertThrowsError(try ASKDiscoveryConfiguration.validate([descriptor], info: appInfo)) {
                XCTAssertEqual($0 as? ASKDiscoveryConfiguration.ValidationError, .missingServiceUUID)
            }
        }
    }

    func testProductionFiltersMatchShippedPlistWithoutRequiringBikeName() throws {
        let descriptors = ASKDiscoveryConfiguration.makeDescriptors()
        try ASKDiscoveryConfiguration.validate(descriptors, info: appInfo)
        let services = Set(try descriptors.map { try XCTUnwrap($0.bluetoothServiceUUID).uuidString })
        let declared = try XCTUnwrap(appInfo["NSAccessorySetupBluetoothServices"] as? [String])
        XCTAssertEqual(services, Set(declared.map { CBUUID(string: $0).uuidString }))
        for descriptor in descriptors { XCTAssertNil(descriptor.bluetoothNameSubstring) }
    }

    func testUndeclaredServiceFailsEvenWhenNameIsDeclared() throws {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothNameSubstring = "Ngựa sắt"
        descriptor.bluetoothServiceUUID = CBUUID(string: "1234")
        XCTAssertThrowsError(try ASKDiscoveryConfiguration.validate([descriptor], info: appInfo)) {
            XCTAssertEqual($0 as? ASKDiscoveryConfiguration.ValidationError, .undeclaredServiceUUID("1234"))
        }
    }

    func testShortLegacyServiceDeclarationMatchesExpandedUUID() throws {
        var info = appInfo
        var services = try XCTUnwrap(info["NSAccessorySetupBluetoothServices"] as? [String])
        services = services.map { CBUUID(string: $0) == CBUUID(string: "FCF1") ? "FCF1" : $0 }
        XCTAssertTrue(services.contains("FCF1"))
        info["NSAccessorySetupBluetoothServices"] = services
        try ASKDiscoveryConfiguration.validate(ASKDiscoveryConfiguration.makeDescriptors(), info: info)
    }

    func testMissingBluetoothCapabilityIsRejected() {
        var info = appInfo
        info.removeValue(forKey: "NSAccessorySetupKitSupports")
        XCTAssertThrowsError(try ASKDiscoveryConfiguration.validate(ASKDiscoveryConfiguration.makeDescriptors(), info: info)) {
            XCTAssertEqual($0 as? ASKDiscoveryConfiguration.ValidationError, .bluetoothNotDeclared)
        }
    }

    func testUndeclaredNameIsRejectedIfNameFilterIsAdded() {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = CBUUID(string: "FCF1")
        descriptor.bluetoothNameSubstring = "Undeclared bike name"
        XCTAssertThrowsError(try ASKDiscoveryConfiguration.validate([descriptor], info: appInfo)) {
            XCTAssertEqual($0 as? ASKDiscoveryConfiguration.ValidationError, .undeclaredName("Undeclared bike name"))
        }
    }

    func testEmptyFiltersAreRejected() {
        XCTAssertThrowsError(try ASKDiscoveryConfiguration.validate([], info: appInfo)) {
            XCTAssertEqual($0 as? ASKDiscoveryConfiguration.ValidationError, .emptyDescriptors)
        }
    }

    private var appInfo: [String: Any] { Bundle.main.infoDictionary ?? [:] }
}
#endif
