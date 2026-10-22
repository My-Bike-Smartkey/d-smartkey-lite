# Chính sách bảo mật — D-SmartKey Lite

Dự án độc lập, không liên kết hoặc được Dat Bike bảo đảm. Chính sách này áp dụng cho mã iOS Lite trong repo; không phải chứng nhận bảo mật của ứng dụng, firmware xe hay hệ thống Bluetooth.

## Phạm vi và sử dụng có trách nhiệm

Chỉ nghiên cứu và thử nghiệm trên ứng dụng của bạn và **xe thuộc sở hữu hợp pháp của chính bạn**. Không truy cập, ghép đôi, lấy khóa/PIN, theo dõi hay gửi lệnh tới xe của người khác. App không xác minh quyền sở hữu; việc thấy một thiết bị BLE không cấp quyền kiểm thử thiết bị đó.

## Báo cáo riêng tư

Gửi mô tả tối thiểu đến [dev@d-smartkey.io](mailto:dev@d-smartkey.io): phiên bản source/build, điều kiện xảy ra, tác động dự kiến và cách tái hiện bằng fake transport nếu có. Không gửi PIN, khóa ký, toàn bộ challenge/response hoặc dữ liệu nhận diện xe thật.

Không đăng chi tiết khai thác, log thô hoặc credential lên issue công khai. Nếu repo có bật GitHub Private Vulnerability Reporting, có thể dùng kênh đó. Không có cam kết về thời gian phản hồi, bản vá hoặc bounty.

## Cơ chế hiện có và giới hạn

- PIN được sinh bằng API ngẫu nhiên hệ thống; implementation hiện chưa kiểm tra lỗi `SecRandomCopyBytes` và có modulo bias. Không tuyên bố generator đã được kiểm toán mật mã.
- PIN production lưu trong Keychain với `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; đường test inject defaults dùng storage riêng. Legacy PIN trong UserDefaults chỉ bị xóa sau khi di trú thành công. Keychain có thể tồn tại sau khi gỡ app; mã có bước dọn khi nhận diện cài mới.
- Reconnect dùng SHA-256 challenge-response theo giao thức mà mã client triển khai. Cách mã hóa liên kết, bonding và quyền ghi characteristic phụ thuộc iOS/firmware. Không suy mức chống tấn công từ việc sử dụng SHA-256.
- Log baseline luôn ghi cục bộ; file gốc chưa ẩn danh, có thể chứa định danh, challenge và hash prefix. Che định danh khi copy/export là tùy chọn và không phải bộ lọc mọi dữ liệu nhạy cảm. Không chia sẻ log thô.
- Không thấy client analytics/backend tự gửi log trong mã app được rà soát. Liên kết hỗ trợ và chia sẻ file là các hành động riêng do người dùng chủ động thực hiện.
- Còn các lỗi đã biết liên quan callback, deep link và auto-command; xem giới hạn tổng quát trong [README](README.md). Không có kiểm toán độc lập hoặc bảo đảm không có lỗ hổng.

Không commit private key, token, profile ký, `.secrets/`, dữ liệu xe thật hay ảnh cá nhân. Việc sửa README/SECURITY không tự sửa logic điều khiển; [LICENSE](LICENSE) quy định miễn trừ bảo đảm trong phạm vi pháp luật cho phép.

## English summary

Only assess your own application and a vehicle you legally own. Report vulnerabilities privately to dev@d-smartkey.io without credentials, raw logs or identifiable vehicle data. Do not publish exploit details in public issues. PIN storage uses the iOS Keychain; raw local logs can still contain sensitive information. Known defects remain open. No security certification, response SLA or bug bounty is promised. This independent project is not affiliated with or warranted by Dat Bike.
