# Hướng Dẫn Triển Khai & Cấu Hình Observability (Giám Sát Hệ Thống)

Tài liệu này hướng dẫn chi tiết cách triển khai ngăn xếp Observability (LGTM/MELT) cho dự án Yas, bao gồm thu thập Metrics (Prometheus), Logs (Loki), và Traces (Tempo), đồng thời tích hợp OpenTelemetry.

## I. Yêu cầu trước khi chạy
- Đảm bảo đã tải và đẩy thư mục `observability` (nằm trong `yas-deploy/infra/observability`) lên VPS.
- **Vị trí đứng:** Khi chạy các lệnh dưới đây, Terminal của bạn phải đang đứng ở thư mục `~/setup/yas-deploy/infra`.

---

## II. Các Bước Cài Đặt (Installation Steps)

### Bước 1: Thêm các Helm Repository cần thiết
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
```

### Bước 2: Chuẩn bị Biến Môi Trường
Trích xuất mật khẩu PostgreSQL và gán biến domain cho Grafana:
```bash
PG_PASS=$(kubectl get secret yasadminuser.postgresql.credentials.postgresql.acid.zalan.do -n postgres -o jsonpath='{.data.password}' | base64 -d)
GRAFANA_DOMAIN="grafana.yas.lethanhcong.site"

echo "Postgres Password: $PG_PASS"
echo "Grafana Domain: $GRAFANA_DOMAIN"
```
*(Chỉ đi tiếp khi lệnh echo in ra được mật khẩu và domain)*

### Bước 3: Cài đặt Loki & Tempo (Lưu trữ Log & Trace)
Triển khai hệ thống lưu trữ backend cho Log và Trace.

**Cài đặt Loki:**
```bash
helm upgrade --install loki grafana/loki \
 --create-namespace --namespace observability \
 -f ./observability/loki.values.yaml \
 --set loki.useTestSchema=true
```

**Cài đặt Tempo:**
```bash
helm upgrade --install tempo grafana/tempo \
 --create-namespace --namespace observability \
 -f ./observability/tempo.values.yaml
```

### Bước 4: Cài đặt Cert-Manager & OpenTelemetry Operator
**1. Cài đặt Cert-Manager:** (Yêu cầu bắt buộc của OTel Operator)
```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.12.0 \
  --set installCRDs=true \
  --set prometheus.enabled=false \
  --set admissionWebhooks.certManager.create=true
```
*(Chạy `kubectl get pods -n cert-manager` để check pod đã ready hết chưa rồi mới đi tiếp)*

**2. Cài đặt OpenTelemetry Operator & Collector:**
```bash
helm upgrade --install opentelemetry-operator open-telemetry/opentelemetry-operator \
 --create-namespace --namespace observability

helm upgrade --install opentelemetry-collector ./observability/opentelemetry \
 --create-namespace --namespace observability
```

### Bước 5: Cài đặt Promtail (Bắt Log gửi về Loki)
Triển khai Promtail lên các node để gom log.
```bash
sysctl -w fs.inotify.max_user_instances=8192
sysctl -w fs.inotify.max_user_watches=524288
echo "fs.inotify.max_user_instances=8192" >> /etc/sysctl.conf
echo "fs.inotify.max_user_watches=524288" >> /etc/sysctl.conf
sysctl -p

kubectl delete pod -l app.kubernetes.io/name=promtail -n observability
```
*(Chạy `kubectl get pods -n observability` để check pod đã ready hết chưa)*
```bash
helm upgrade --install promtail grafana/promtail \
 --create-namespace --namespace observability \
 --values ./observability/promtail.values.yaml
```

### Bước 6: Cài đặt Prometheus + Grafana Core
```bash
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
 --create-namespace --namespace observability \
 -f ./observability/prometheus.values.yaml \
 --set grafana.assertNoLeakedSecrets=false \
 --set grafana.env.GF_DATABASE_PASSWORD="$PG_PASS" \
 --set grafana.ingress.ingressClassName="traefik" \
 --set grafana.ingress.hosts[0]="$GRAFANA_DOMAIN"
```
*(Lưu ý: Sử dụng `grafana.env.GF_DATABASE_PASSWORD` để tránh lỗi parse chuỗi)*

### Bước 7: Cài đặt Grafana Operator & Dashboards
```bash
helm upgrade --install grafana-operator oci://ghcr.io/grafana-operator/helm-charts/grafana-operator \
 --version v5.0.2 \
 --create-namespace --namespace observability

helm upgrade --install grafana ./observability/grafana \
 --create-namespace --namespace observability \
 --set hostname="$GRAFANA_DOMAIN" \
 --set grafana.username="admin" \
 --set grafana.password="admin" \
 --set postgresql.username="yasadminuser" \
 --set postgresql.password="$PG_PASS"
```
Sau khi các Pod ở `observability` Ready hết, truy cập `http://grafana.yas.lethanhcong.site` (admin/admin).

---

## III. Các Lỗi Thường Gặp & Cách Khắc Phục (Troubleshooting)

Trong quá trình thiết lập Hệ thống Tracing và Logging, nếu gặp hiện tượng không thể link từ Log sang Trace hoặc Tempo báo `Not Found`, hãy đối chiếu với danh sách các lỗi kinh điển sau:

### 1. Lỗi Cấu hình Tempo Metrics Generator
- **Triệu chứng:** Lỗi khi khởi chạy pod Tempo hoặc cấu hình `remoteWriteUrl` không được chấp nhận.
- **Khắc phục:** File `tempo.values.yaml` bắt buộc phải có cấu trúc `metricsGenerator.config.storage.path` và `remote_write` bên trong block `config`.

### 2. Không xuất hiện nút "Tempo" trong giao diện Log của Grafana
- **Triệu chứng:** Log hiển thị `trace_id` nhưng không bấm sang Tempo được.
- **Khắc phục:** Trong `loki-datasource.yaml`, mục `derivedFields` cần phải được bổ sung cờ `internalLink: true` (đối với Grafana Operator v5) thì Grafana mới nhận dạng đó là liên kết cục bộ giữa các datasource.

### 3. Thiếu OTel Agent Init Container ở Java Backend
- **Triệu chứng:** Không có dòng chữ `trace_id=` trong log của Loki khi gọi API.
- **Khắc phục:** Phải sử dụng "Init Container Pattern" trong `deployment.yaml` của Backend (Spring Boot) để tự động tải `otel-javaagent.jar` về thư mục dùng chung, và inject biến `JAVA_TOOL_OPTIONS: "-javaagent:/otel/otel-javaagent.jar"` vào môi trường Java.

### 4. OTel Collector dùng sai giao thức Exporter (HTTP vs gRPC)
- **Triệu chứng:** Tempo báo `failed to get trace... Status: Not Found`. OTel Collector báo cảnh báo `otlphttp alias is deprecated`.
- **Khắc phục:** OTel Collector (phiên bản >0.154) ưu tiên giao thức gRPC. Sửa file `opentelemetry/values.yaml` để exporter sang Tempo dùng `otlp` (thay vì `otlphttp`) và trỏ vào port `4317` của Tempo.

### 5. Java Agent bị Envoy/Istio chặn vì sai giao thức (502 Bad Gateway)
- **Triệu chứng:** OTel Collector không nhận được bất kỳ trace nào (`otelcol_receiver_accepted_spans` rỗng). Bắn lệnh `curl` thử thì bị báo `502 Bad Gateway`.
- **Nguyên nhân:** Java Agent mặc định dùng HTTP (`http/protobuf`), nhưng gửi thẳng vào port `4317` (port gRPC) của Collector, dẫn đến bị Istio Sidecar từ chối thẳng thừng.
- **Khắc phục:** Ép Java Agent dùng gRPC bằng cách thêm biến môi trường vào Backend deployment: `OTEL_EXPORTER_OTLP_PROTOCOL="grpc"`.

### 6. Không thấy Log cho các API GET
- **Triệu chứng:** Test các API GET thì Trace lên Tempo thành công, nhưng không tìm thấy log trên Loki (không nhấp sang trace được).
- **Nguyên nhân:** Mặc định Spring Boot không in log đối với các Web request thông thường để tiết kiệm dung lượng.
- **Khắc phục:** Để theo dõi phục vụ test/demo, bật logging web traffic bằng cách thêm vào `values.yaml` của project (phần `applicationConfig`):
  ```yaml
  logging:
    level:
      org.springframework.web: DEBUG
  ```

---
*Tài liệu này được tổng hợp và tối ưu dựa trên quá trình triển khai thực tế của dự án Yas.*
