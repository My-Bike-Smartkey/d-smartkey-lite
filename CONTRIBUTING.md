# Đóng góp cho D-SmartKey Lite

Đọc [README](README.md), [SECURITY](SECURITY.md), [quyền riêng tư](PRIVACY.md) và [LICENSE](LICENSE) trước khi đóng góp. Dự án độc lập với Dat Bike; chỉ kiểm thử trên xe thuộc sở hữu hợp pháp của chính bạn, ở nơi an toàn và khi xe dừng.

## Thiết lập

```bash
open DBikeSmartkey.xcodeproj
```

Cấu hình Lite dùng iOS16+, điều kiện `NOASK`. Chọn Apple team và định danh của bạn khi build cho điện thoại. Nếu sửa `project.yml`, chạy `xcodegen generate` và cập nhật project được sinh ra.

## Pull request

- Mô tả vấn đề, thay đổi, cách kiểm chứng và giới hạn còn lại.
- Chạy các test liên quan; báo đúng pass/skip/fail và exit code. Build/test Simulator không chứng minh an toàn trên xe thật.
- Không tự gửi lệnh vật lý trong CI hoặc test tự động. Mọi thử nghiệm xe thật phải do chủ xe chủ động thực hiện.
- Không đưa log thô, PIN, định danh xe thật, dữ liệu tài khoản, QR thanh toán, liên kết mời riêng, private key hoặc profile ký vào PR.
- Dùng dữ liệu giả cho fixture kiểm thử. Giữ README phù hợp với hành vi sản phẩm; không đưa tài liệu nội bộ hoặc báo cáo khai thác chi tiết vào repo public.
- Quyền cấp phép nguồn theo MIT. Người sửa đổi/phân phối tự đánh giá bản dựng và tuyên bố của mình; không nhận là sản phẩm được hãng hoặc tác giả gốc bảo đảm.

Báo cáo lỗi thông thường kèm phiên bản app/iOS/firmware và các bước tái hiện đã bỏ dữ liệu nhạy cảm. Báo cáo lỗ hổng riêng theo [SECURITY.md](SECURITY.md), không đăng chi tiết khai thác công khai.
