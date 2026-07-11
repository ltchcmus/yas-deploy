# Summary

## 1. Cài đặt Môi trường (Docker, K3d, Kubectl, Helm, ArgoCD)
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER && newgrp docker

curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd
```

## 2. Khởi tạo K3d Cluster & Namespace
```bash
k3d cluster create yas \
  --servers 1 --agents 1 \
  -p "80:80@loadbalancer" \
  -p "443:443@loadbalancer" \
  -p "30080-30110:30080-30110@server:0"

sudo ufw allow 30000:32767/tcp
sudo ufw allow 30000:32767/udp

kubectl create ns postgres
kubectl create ns kafka
kubectl create ns redis
kubectl create ns keycloak
kubectl create ns elasticsearch
kubectl create ns dev
kubectl create ns staging
kubectl create ns argocd
```

## 3. Cài đặt Istio Service Mesh
```bash
cd ~
curl -L https://istio.io/downloadIstio | sh -
cd istio-*
export PATH=$PWD/bin:$PATH

istioctl install --set profile=demo -y

kubectl label namespace dev istio-injection=enabled --overwrite
kubectl label namespace staging istio-injection=enabled --overwrite

kubectl apply -f samples/addons
kubectl patch svc kiali -n istio-system -p '{"spec": {"type": "NodePort", "ports": [{"port": 20001, "nodePort": 30105, "name": "http-kiali"}]}}'
```

## 4. Cài đặt Cơ sở dữ liệu (PostgreSQL)
```bash
-----------------
helm repo add postgres-operator-charts https://opensource.zalando.com/postgres-operator/charts/postgres-operator
helm repo update
helm upgrade --install postgres-operator postgres-operator-charts/postgres-operator --namespace postgres

-----------------
cat <<EOF > postgres-cluster.yaml
apiVersion: "acid.zalan.do/v1"
kind: postgresql
metadata:
  name: postgresql
  namespace: postgres
spec:
  teamId: "yas"
  volume:
    size: 5Gi
  numberOfInstances: 1
  users:
    yasadminuser:
      - superuser
      - createdb
  databases:
    cart: yasadminuser
    order: yasadminuser
    payment: yasadminuser
    customer: yasadminuser
    search: yasadminuser
    product: yasadminuser
    keycloak: yasadminuser
    inventory: yasadminuser
    media: yasadminuser
    recommendation: yasadminuser
    tax: yasadminuser
    webhook: yasadminuser
    grafana: yasadminuser
  postgresql:
    version: "16"
    parameters:
      wal_level: logical
      max_connections: "700"
EOF
--------------
kubectl apply -f postgres-cluster.yaml
```

## 5. Cài đặt Kafka (KRaft mode)
```bash
helm repo add strimzi https://strimzi.io/charts/
helm upgrade --install kafka-operator strimzi/strimzi-kafka-operator --namespace kafka

cat <<EOF > kafka-setup.yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: kafka-pool
  namespace: kafka
  labels:
    strimzi.io/cluster: kafka-cluster
spec:
  replicas: 1
  roles: [broker, controller]
  storage: { type: ephemeral }
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: kafka-cluster
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 4.3.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF
kubectl apply -f kafka-setup.yaml
```

## 6. Cài đặt Redis & Elasticsearch
```bash
# Redis
helm repo add bitnami https://charts.bitnami.com/bitnami
helm upgrade --install redis bitnami/redis --namespace redis --set auth.password=redis --set architecture=standalone

# Elasticsearch
helm repo add elastic https://helm.elastic.co
helm upgrade --install elastic-operator elastic/eck-operator --namespace elasticsearch

----------------

cat <<EOF > elasticsearch-cluster.yaml
apiVersion: elasticsearch.k8s.elastic.co/v1
kind: Elasticsearch
metadata:
  name: elasticsearch
  namespace: elasticsearch
spec:
  version: 9.2.3
  nodeSets:
    - name: default
      count: 1
      config:
        node.store.allow_mmap: false
      podTemplate:
        spec:
          containers:
            - name: elasticsearch
              resources:
                requests:
                  memory: 1Gi
                limits:
                  memory: 1Gi
EOF
------------------
kubectl apply -f elasticsearch-cluster.yaml
```

## 7. Cài đặt Debezium Connect & Fix lỗi Elasticsearch
```bash
# Debezium Connect
cat << 'EOF' > setup-debezium.sh
#!/bin/bash
kubectl apply -n kafka -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: debezium-connect
spec:
  replicas: 1
  selector:
    matchLabels: { app: debezium-connect }
  template:
    metadata:
      labels: { app: debezium-connect }
    spec:
      containers:
      - name: debezium
        image: quay.io/debezium/connect:2.7.3.Final
        env:
        - name: BOOTSTRAP_SERVERS
          value: kafka-cluster-kafka-bootstrap.kafka.svc:9092
        - name: GROUP_ID
          value: "connect-cluster"
        - name: CONFIG_STORAGE_TOPIC
          value: "kafka_connect_configs"
        - name: OFFSET_STORAGE_TOPIC
          value: "kafka_connect_offsets"
        - name: STATUS_STORAGE_TOPIC
          value: "kafka_connect_status"
        ports:
        - containerPort: 8083
---
apiVersion: v1
kind: Service
metadata:
  name: debezium-connect-cluster-connect-api
spec:
  selector: { app: debezium-connect }
  ports:
  - port: 8083
    targetPort: 8083
YAML

kubectl wait --for=condition=available deployment/debezium-connect -n kafka --timeout=120s
sleep 80

PG_PASS=$(kubectl get secret yasadminuser.postgresql.credentials.postgresql.acid.zalan.do -n postgres -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -it deployment/debezium-connect -n kafka -- curl -s -X POST -H "Content-Type: application/json" --data '{
  "name": "product-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgresql.postgres",
    "database.port": "5432",
    "database.user": "yasadminuser",
    "database.password": "'"$PG_PASS"'",
    "topic.prefix": "dbproduct",
    "database.dbname": "product",
    "table.include.list": "public.product",
    "column.include.list": "public.product.id,public.product.is_published",
    "schema.include.list": "public",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "false",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "plugin.name": "pgoutput",
    "transforms": "keepTopLevel",
    "transforms.keepTopLevel.type": "org.apache.kafka.connect.transforms.ReplaceField$Value",
    "transforms.keepTopLevel.include": "before,after,op"
  }
}' http://localhost:8083/connectors
EOF

chmod +x setup-debezium.sh
bash setup-debezium.sh

# Fix lỗi mapping Elasticsearch
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n elasticsearch -o jsonpath='{.data.elastic}' | base64 -d)
kubectl exec -it -n elasticsearch elasticsearch-es-default-0 -- curl -s -u "elastic:$ES_PASS" -k -X PUT "https://localhost:9200/product"
kubectl exec -it -n elasticsearch elasticsearch-es-default-0 -- curl -s -u "elastic:$ES_PASS" -k -X PUT "https://localhost:9200/product/_mapping" -H "Content-Type: application/json" -d'
{
  "properties": {
    "brand": { "type": "text", "fielddata": true, "fields": { "keyword": { "type": "keyword", "ignore_above": 256 } } },
    "categories": { "type": "text", "fielddata": true, "fields": { "keyword": { "type": "keyword", "ignore_above": 256 } } },
    "attributes": { "type": "text", "fielddata": true, "fields": { "keyword": { "type": "keyword", "ignore_above": 256 } } },
    "createdOn": { "type": "date" }
  }
}'
```

## 8. Cài đặt Keycloak
```bash
# Cài Operator
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/kubernetes.yml -n keycloak

sleep 60

# Cài Instance
PG_PASS=$(kubectl get secret yasadminuser.postgresql.credentials.postgresql.acid.zalan.do -n postgres -o jsonpath='{.data.password}' | base64 -d)

cat <<EOF > keycloak-instance.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgresql-credentials
  namespace: keycloak
stringData:
  username: yasadminuser
  password: $PG_PASS
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-credentials
  namespace: keycloak
stringData:
  username: admin
  password: admin
---
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  additionalOptions:
    - name: http-relative-path
      value: /auth
  bootstrapAdmin:
    user:
      secret: keycloak-credentials
  db:
    vendor: postgres
    usernameSecret:
      name: postgresql-credentials
      key: username
    passwordSecret:
      name: postgresql-credentials
      key: password
    host: postgresql.postgres
    database: keycloak
    port: 5432
  http:
    httpEnabled: true
    httpPort: 80
  hostname:
    hostname: <DOMAIN trỏ tới keycloak>
    strict: false
  ingress:
    enabled: true
    className: traefik
EOF

kubectl apply -f keycloak-instance.yaml

# Import Realm
kubectl apply -f yas-deploy/setup-realm.yaml (lệnh này phải clone cái yas-deploy-cái yas-deploy này là cái trên github của mọi người chứ không phải cái dùng chung clone cái dùng chung có hư gì thì em chịu á nha)
```

## 9. Cài đặt ArgoCD
```bash
kubectl delete deployment argocd-server -n argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

kubectl patch configmap argocd-cmd-params-cm -n argocd -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd

cat <<EOF > argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
spec:
  rules:
    - host: <DOMAIN trỏ tới argocd>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
kubectl apply -f argocd-ingress.yaml

# Lấy mật khẩu ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

## 10. Kết nối GitOps (ArgoCD Login & Sync)
```bash
# Login CLI
argocd login <domain của mọi người trỏ tới argocd>:80 --username admin --password <MAT_KHAU_O_TREN> --insecure --grpc-web --plaintext

# Add Repo
argocd repo add https://github.com/<USER_GITHUB>/yas-deploy \
  --username <GITHUB_USERNAME> \
  --password <GITHUB_PAT>

# Khai báo App dev
cd ~
mkdir apps
cd apps
git clone https://github.com/<USER_GITHUB>/yas-deploy
cd yas-deploy/argocd-apps
kubectl apply -f dev.yaml
```

**LƯU Ý không dùng giá trị của em: domain, github ... (phải đọc kỹ lệnh để đổi thành giá trị của mọi người)** 

**Chạy phải biết tách lệnh chạy nha, và sau mỗi lần chạy gì đó phải check các pod trong namespace đã được ready+running chưa thì mới chạy cái tiếp theo để an toàn** 

**Cần có domain mới dùng được nha**

**Cần phải tạo sẵn image:latest trên dockerhub mọi người trước (bằng cách sửa code CI trên repo của mọi người để có)**
