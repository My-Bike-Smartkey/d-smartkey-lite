# Quyền riêng tư — D-SmartKey Lite

Ngày cập nhật: **2026-10-22**. Phạm vi: mã ứng dụng iOS Lite trong repo, không bao gồm dịch vụ Apple, trình duyệt hay bản fork do người khác sửa đổi. Đây là tài liệu source; việc sửa file không tự cập nhật chính sách đã host hoặc hồ sơ App Store.

## Dữ liệu được xử lý

Ứng dụng kết nối trực tiếp tới xe bằng Bluetooth. Trong mã app được rà soát, không thấy tài khoản người dùng, SDK quảng cáo/analytics hoặc chức năng tự tải telemetry/log lên backend của dự án. Điều đó không có nghĩa thiết bị không lưu dữ liệu nhạy cảm.

| Dữ liệu | Nơi xử lý/lưu | Mục đích |
|---|---|---|
| PIN ghép đôi | Keychain trong production; bộ nhớ khi xác thực | Xác thực phiên BLE |
| Tùy chọn, UUID và metadata xe đã nhớ | UserDefaults/App Group trên thiết bị | Kết nối lại và hiển thị |
| Nhật ký kết nối, lệnh, lỗi, timestamp/RSSI và dữ liệu chẩn đoán | `Documents/ble_logs/` | Chẩn đoán sự cố |
| Dữ liệu pin, trạng thái khóa, telemetry | Bộ nhớ và dữ liệu/log liên quan tùy luồng | Hiển thị và điều khiển |

PIN dùng lớp Keychain `AfterFirstUnlockThisDeviceOnly`. PIN cũ trong UserDefaults có thể còn trong thời gian di trú chưa thành công. Metadata và logs không được mã hóa riêng ở tầng ứng dụng; mức bảo vệ còn phụ thuộc iOS và bảo mật thiết bị.

## Nhật ký và thời gian lưu

Log INFO/BLE/cảnh báo/lỗi vẫn ghi khi tắt chế độ chi tiết. Logger đặt giới hạn 365 ngày và dọn file quá hạn khi khởi tạo; đây không phải dịch vụ xóa theo lịch chính xác. Log gốc có thể chứa định danh xe, dữ liệu quảng bá, challenge hoặc một phần hash xác thực. Tùy chọn che định danh chỉ áp dụng khi copy/export và không bảo đảm ẩn toàn bộ dữ liệu nhạy cảm. Tự kiểm tra nội dung trước khi chia sẻ.

## Khi dữ liệu có thể rời thiết bị

- Bạn chủ động copy/export log, dùng share sheet, gửi email hoặc đăng nội dung hỗ trợ.
- Bạn mở liên kết cộng đồng/hỗ trợ: ứng dụng hoặc website nhận liên kết có chính sách riêng.
- Sao lưu, chẩn đoán hệ điều hành hoặc quản lý thiết bị của Apple phụ thuộc thiết lập của bạn và các dịch vụ tương ứng; không nằm trong cam kết không tải dữ liệu của mã app này.

## Xóa dữ liệu và quyền hệ thống

Có thể xóa log bằng chức năng trong ứng dụng và dùng chức năng quên xe để yêu cầu xóa PIN/metadata ghép đôi. Nếu Keychain tạm không truy cập được, mã lưu dấu xóa chờ và thử lại khi dữ liệu bảo vệ sẵn sàng. Quên xe trong app không có nghĩa khóa bonding trong firmware hoặc hệ điều hành đã bị xóa.

**Không bảo đảm gỡ app sẽ xóa mọi dấu vết**: Keychain có thể tồn tại sau khi gỡ, App Group và bản sao lưu còn phụ thuộc thành viên/cấu hình hệ thống. Mã có bước dọn PIN khi nhận diện cài mới nhưng không xóa các bản sao bạn đã chia sẻ hoặc sao lưu bên ngoài.

App yêu cầu Bluetooth để giao tiếp với xe và có thể xin quyền thông báo trạng thái. Lite không khai báo quyền vị trí, AccessorySetupKit hoặc chế độ nền `bluetooth-central` trong `Info.plist` hiện tại.

## Liên hệ

[dev@d-smartkey.io](mailto:dev@d-smartkey.io). Không gửi PIN, credential hay log thô. Dự án độc lập, không liên kết với Dat Bike; xem [README](README.md), [SECURITY](SECURITY.md) và [LICENSE](LICENSE).
