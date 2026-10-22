import SwiftUI

struct BLEAdvertisementDebugView: View {
    #if NOASK
    @StateObject private var scanner = BLEAdvertisementScanner()
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""

    private var visibleRecords: [BLEAdvertisementRecord] {
        scanner.records.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.uuidString.localizedCaseInsensitiveContains(query)
                || $0.observedServices.joined(separator: " ").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                Text(scanner.status).accessibilityIdentifier("bleDebugStatus")
                Button(scanner.isRunning ? "Dừng quét" : "Quét 30 giây") {
                    if scanner.isRunning { scanner.stop() } else { scanner.start() }
                }
                .accessibilityIdentifier("bleDebugScan")
                Text("\(scanner.records.count) thiết bị · hiển thị \(visibleRecords.count)")
                    .font(.caption).foregroundColor(.secondary)
                if scanner.store.droppedCallbacks > 0 {
                    Text("Đã đạt giới hạn 200 thiết bị. Một số callback mới chưa được lưu.")
                        .font(.caption).foregroundColor(.orange)
                }
            } footer: {
                Text("Quét CoreBluetooth không lọc UUID. Chỉ thu quảng bá, không kết nối hoặc gửi lệnh xe. Quét dừng khi đóng màn hình hoặc rời app.")
            }
            Section("Thiết bị gần đây") {
                if visibleRecords.isEmpty {
                    Text(scanner.isRunning ? "Đang chờ quảng bá…" : "Chưa có kết quả phù hợp.")
                        .foregroundColor(.secondary)
                }
                ForEach(visibleRecords) { record in
                    NavigationLink {
                        BLEAdvertisementDetailView(scanner: scanner, deviceID: record.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.displayName).font(.headline)
                            Text("\(record.rssiText) · \(record.count) callback")
                                .font(.caption).foregroundColor(.secondary)
                            Text(record.observedServices.isEmpty ? "Chưa thấy service UUID" : record.observedServices.joined(separator: "\n"))
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            Section {
                Text("Tên có thể do chủ xe đặt. Nếu xe đang kết nối với điện thoại khác, xe có thể ngừng quảng bá. iOS trả dữ liệu đã giải mã, có thể gộp quảng bá và scan response; đây không phải HCI capture.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Lọc tên, định danh hoặc service UUID")
        .navigationTitle("Quét quảng bá BLE")
        .navigationBarTitleDisplayMode(.inline)
        // Pause on navigation to detail so the inspected/exported samples stay stable.
        .onChange(of: scenePhase) { if $0 == .background { scanner.stop(reason: "Đã dừng khi rời app.") } }
        .onDisappear { scanner.stop() }
    }
    #else
    @Environment(\.openURL) private var openURL
    @State private var cannotOpenLite = false

    var body: some View {
        Form {
            Section {
                Text("Quét bằng D-SmartKey Lite")
                    .font(.headline)
                Text("Bản full dùng ASK nên iOS giới hạn việc quét thiết bị chưa ghép. Lite dùng CoreBluetooth trực tiếp để xem UUID và dữ liệu quảng bá thực tế.")
                Button("Mở màn hình quét trong Lite") {
                    openURL(URL(string: "dsmartkeylite://debug/ble-scanner")!) { accepted in cannotOpenLite = !accepted }
                }
                Text("Cần cài bản Lite có tính năng Quét quảng bá BLE.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("Quét quảng bá BLE")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Chưa mở được Lite", isPresented: $cannotOpenLite) {
            Button("Đóng", role: .cancel) { }
        } message: { Text("Hãy cài hoặc cập nhật D-SmartKey Lite, sau đó mở Cài đặt → Chế độ nhà phát triển → Quét quảng bá BLE.") }
    }
    #endif
}

private struct BLEAdvertisementDetailView: View {
    @ObservedObject var scanner: BLEAdvertisementScanner
    let deviceID: UUID
    @State private var redactIdentifiers = PreferencesManager.shared.redactFrameNumber
    @State private var saved = false

    var body: some View {
        List {
            if let record = scanner.store.records[deviceID] {
                Section("Tổng hợp thiết bị") {
                    Text(record.displayName).font(.headline)
                    Text("CoreBluetooth ID: \(record.id.uuidString)").font(.caption.monospaced()).textSelection(.enabled)
                    Text("Tên cache: \(record.cachedName ?? "<không có>")")
                    Text("\(record.rssiText) · \(record.count) callback")
                    Text("Service UUID đã thấy qua các mẫu (hợp, không phải một gói):")
                    Text(record.observedServices.isEmpty ? "Chưa thấy service UUID. Không đủ dữ liệu để chọn bộ lọc service." : record.observedServices.joined(separator: "\n"))
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                Section("Báo cáo") {
                    Toggle("Ẩn định danh khi chia sẻ", isOn: $redactIdentifiers)
                    Text("Khi bật: ẩn tên, định danh thiết bị, manufacturer/service data; giữ service UUID. Tắt để xuất đủ dữ liệu bạn đang xem.")
                        .font(.caption).foregroundColor(.secondary)
                    ShareLink(item: record.report(redacted: redactIdentifiers)) {
                        Label("Chia sẻ báo cáo thiết bị này", systemImage: "square.and.arrow.up")
                    }
                    Button("Sao chép báo cáo") {
                        UIPasteboard.general.string = record.report(redacted: redactIdentifiers)
                    }
                    Button(saved ? "Đã lưu vào nhật ký" : "Lưu báo cáo vào nhật ký") {
                        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
                            message: "[ADV_DEBUG_REPORT]\n\(record.report(redacted: redactIdentifiers))"))
                        saved = true
                    }
                }
                ForEach(Array(record.variants.enumerated()), id: \.element.id) { index, variant in
                    Section("Mẫu \(index + 1) · \(variant.count) callback") {
                        Text(variant.payload.report(redacted: false))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Text("Lần cuối: \(variant.lastSeen.formatted(date: .omitted, time: .standard))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Section {
                    Text("Giữ tối đa 12 mẫu dữ liệu khác nhau; đã bỏ \(record.discardedVariants) mẫu cũ. Không suy company identifier từ hai byte đầu manufacturer data; xe có thể dùng ASCII serial.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Chi tiết quảng bá")
        .navigationBarTitleDisplayMode(.inline)
    }
}
