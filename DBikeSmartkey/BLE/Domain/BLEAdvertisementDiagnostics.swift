import Foundation
import CoreBluetooth

/// One callback's decoded advertisement, not a raw HCI packet. Do not merge names
/// and UUIDs from separate callbacks and imply they appeared together over the air.
struct BLEAdvertisementPayload: Equatable {
    let localName: String?
    let serviceUUIDs: [String]
    let overflowUUIDs: [String]
    let solicitedUUIDs: [String]
    let serviceData: [String: Data]
    let manufacturerData: Data?
    let txPower: Int?
    let connectable: Bool?

    init(_ data: [String: Any]) {
        localName = data[CBAdvertisementDataLocalNameKey] as? String
        serviceUUIDs = Self.uuids(data[CBAdvertisementDataServiceUUIDsKey])
        overflowUUIDs = Self.uuids(data[CBAdvertisementDataOverflowServiceUUIDsKey])
        solicitedUUIDs = Self.uuids(data[CBAdvertisementDataSolicitedServiceUUIDsKey])
        serviceData = Dictionary(uniqueKeysWithValues:
            (data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:])
                .map { ($0.key.uuidString, $0.value) })
        manufacturerData = data[CBAdvertisementDataManufacturerDataKey] as? Data
        txPower = (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue
        connectable = (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
    }

    private static func uuids(_ value: Any?) -> [String] {
        Array(Set((value as? [CBUUID] ?? []).map(\.uuidString))).sorted()
    }

    var advertisedServices: [String] { Array(Set(serviceUUIDs + overflowUUIDs)).sorted() }

    func report(redacted: Bool) -> String {
        var lines = ["advName=\(redacted && localName != nil ? "<ẩn>" : localName?.debugDescription ?? "<không có>")",
                     "services=\(serviceUUIDs.joined(separator: ","))",
                     "overflow=\(overflowUUIDs.joined(separator: ","))",
                     "solicited=\(solicitedUUIDs.joined(separator: ","))",
                     "connectable=\(connectable.map(String.init) ?? "unknown") txPower=\(txPower.map(String.init) ?? "unknown")"]
        if let bytes = manufacturerData {
            lines.append("mfg=\(redacted ? "<ẩn>" : bytes.hexString)")
            if !redacted, let ascii = String(data: bytes, encoding: .ascii) {
                lines.append("mfgASCII=\(ascii.debugDescription)")
            }
        }
        for key in serviceData.keys.sorted() {
            lines.append("serviceData[\(key)]=\(redacted ? "<ẩn>" : serviceData[key]!.hexString)")
        }
        return lines.joined(separator: "\n")
    }
}

struct BLEAdvertisementVariant: Identifiable {
    let id = UUID()
    let payload: BLEAdvertisementPayload
    var count = 1
    var lastSeen: Date
}

struct BLEAdvertisementRecord: Identifiable {
    let id: UUID // CoreBluetooth identifier, not a MAC address.
    var cachedName: String?
    var rssi: Int
    var count = 0
    var lastSeen: Date
    var variants: [BLEAdvertisementVariant] = []
    var observedServices: [String] = []
    var discardedVariants = 0

    var displayName: String {
        variants.filter { $0.payload.localName != nil }.max { $0.lastSeen < $1.lastSeen }?.payload.localName
            ?? cachedName ?? "Thiết bị không tên"
    }

    var rssiRank: Int { (-127..<0).contains(rssi) ? rssi : Int.min }
    var rssiText: String { rssiRank == Int.min ? "RSSI không có" : "\(rssi) dBm" }

    mutating func receive(_ payload: BLEAdvertisementPayload, rssi: Int, at date: Date) {
        self.rssi = rssi
        lastSeen = date
        count += 1
        observedServices = Array(Set(observedServices + payload.advertisedServices)).sorted()
        if let index = variants.firstIndex(where: { $0.payload == payload }) {
            variants[index].count += 1
            variants[index].lastSeen = date
        } else {
            if variants.count == 12 { variants.removeFirst(); discardedVariants += 1 }
            variants.append(BLEAdvertisementVariant(payload: payload, lastSeen: date))
        }
    }

    func report(redacted: Bool) -> String {
        let candidate = observedServices.isEmpty ? "<chưa thấy service UUID>" : observedServices.joined(separator: ",")
        let known = observedServices.filter { seen in BLEService.scanUUIDs.contains(CBUUID(string: seen)) }
        var lines = ["BLE ADV DEBUG — CoreBluetooth / Lite",
                     "device=\(redacted ? "<ẩn>" : id.uuidString)",
                     "cachedName=\(redacted && cachedName != nil ? "<ẩn>" : cachedName?.debugDescription ?? "<không có>")",
                     "RSSI=\(rssi) callbacks=\(count) lastSeen=\(ISO8601DateFormatter().string(from: lastSeen))",
                     "Observed service UUIDs (union, not one packet): \(candidate)",
                     "Known bike services observed: \(known.joined(separator: ","))",
                     "variantsKept=\(variants.count) variantsDiscarded=\(discardedVariants)",
                     "iOS decoded callbacks; advertising/scan response may be combined. No HCI raw bytes.",
                     "Manufacturer bytes are not assumed to contain a Bluetooth company identifier."]
        for (index, variant) in variants.enumerated() {
            lines.append("\nSAMPLE \(index + 1) callbacks=\(variant.count) lastSeen=\(ISO8601DateFormatter().string(from: variant.lastSeen))\n\(variant.payload.report(redacted: redacted))")
        }
        return lines.joined(separator: "\n")
    }
}

struct BLEAdvertisementStore {
    private(set) var records: [UUID: BLEAdvertisementRecord] = [:]
    private(set) var droppedCallbacks = 0

    mutating func receive(id: UUID, cachedName: String?, data: [String: Any], rssi: Int, at date: Date) {
        guard records[id] != nil || records.count < 200 else { droppedCallbacks += 1; return }
        var record = records[id] ?? BLEAdvertisementRecord(id: id, cachedName: cachedName, rssi: rssi, lastSeen: date)
        if let cachedName { record.cachedName = cachedName }
        record.receive(BLEAdvertisementPayload(data), rssi: rssi, at: date)
        records[id] = record
    }
}
