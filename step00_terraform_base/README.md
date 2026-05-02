# STEP 00: Terraform で AWS 最小構成をコードで作る

## 目的

インフラをコードで管理する第一歩として、Terraform を使って AWS 上に最小限の構成を構築する。  
手作業でのインフラ構築を排除し、再現性・レビュー可能性・破棄の容易さを実感する。  
後続ステップのベースとなる VPC/EC2/SG/Key Pair を Terraform で定義し、Go/Echo API を systemd で起動するところまでを習得する。

---

## 構成

```
Internet
    │
    ▼
[Internet Gateway]
    │
    ▼
[Public Subnet 10.0.1.0/24]
    │
    ▼
[EC2 t3.micro]
  ├── Go/Echo API (port 8080, systemd: go-echo-api.service)
  └── MySQL 8.0   (port 3306, systemd: mysqld.service)
    │
[Security Group]
  ├── Inbound: 22 (SSH), 80 (HTTP), 8080 (API)
  └── Outbound: all
```

| リソース         | 値                        |
|-----------------|--------------------------|
| VPC CIDR        | 10.0.0.0/16              |
| Public Subnet   | 10.0.1.0/24 (ap-northeast-1a) |
| EC2 Instance    | t3.micro, Amazon Linux 2023 |
| Storage         | gp3 20GB                 |
| MySQL           | 8.0 (EC2 内)              |
| Go API          | Echo フレームワーク、port 8080 |

---

## 成果物

```
step00_terraform_base/
├── README.md          # このファイル
├── main.tf            # Terraform メインリソース定義
├── variables.tf       # 変数定義
├── outputs.tf         # 出力値定義
├── terraform.tfvars.example  # 変数サンプル
├── user_data.sh       # EC2 初期化スクリプト
└── destroy.md         # 削除手順
```

---

## 前提条件

- Terraform v1.5 以上がインストールされていること
- AWS CLI が設定済みであること (`aws configure`)
- AWS アカウントで EC2/VPC/IAM の操作権限があること
- SSH キーペアが作成済み、または Terraform で作成する
- `go` 1.22 以上がローカルにインストールされていること（動作確認用）

```bash
# バージョン確認
terraform version   # >= 1.5.0
aws sts get-caller-identity  # アカウント情報が返ること
```

---

## 実行手順

### 1. ディレクトリへ移動

```bash
cd step00_terraform_base
```

### 2. 変数ファイルを作成

```bash
cp terraform.tfvars.example terraform.tfvars
# エディタで your_ip_address などを編集
vim terraform.tfvars
```

`terraform.tfvars` の編集例:
```hcl
aws_region      = "ap-northeast-1"
project_name    = "scaling-step00"
my_ip_cidr      = "203.0.113.10/32"   # 自分のグローバルIPアドレス
instance_type   = "t3.micro"
key_name        = "scaling-key"
```

### 3. Terraform 初期化

```bash
terraform init
```

出力例:
```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
Terraform has been successfully initialized!
```

### 4. 実行計画を確認

```bash
terraform plan
```

作成されるリソース数を確認する（通常 10〜12 リソース）。

### 5. インフラ構築

```bash
terraform apply
# 確認プロンプトで yes を入力
```

完了後、`Outputs:` セクションに EC2 のパブリック IP が表示される。

### 6. SSH 接続確認

```bash
# outputs.tf で出力される public_ip を使用
EC2_IP=$(terraform output -raw public_ip)
ssh -i ~/.ssh/scaling-key.pem ec2-user@${EC2_IP}
```

### 7. Go API の起動確認

EC2 内で以下を実行（user_data.sh が完了するまで 3〜5 分待つ）:

```bash
# systemd サービスの状態確認
sudo systemctl status go-echo-api

# API ヘルスチェック
curl http://localhost:8080/health

# 外部からアクセス確認（ローカル端末から）
curl http://${EC2_IP}:8080/health
```

期待レスポンス:
```json
{"status": "ok"}
```

### 8. MySQL 接続確認

```bash
# EC2 内から MySQL に接続
mysql -u apiuser -papipassword appdb -e "SHOW TABLES;"
```

---

## 確認方法

### インフラ確認

```bash
# Terraform で管理されているリソース一覧
terraform state list

# 特定リソースの詳細確認
terraform state show aws_instance.api

# EC2 コンソールで確認
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=scaling-step00" \
  --query "Reservations[].Instances[].{ID:InstanceId,IP:PublicIpAddress,State:State.Name}" \
  --output table
```

### API 動作確認

```bash
EC2_IP=$(terraform output -raw public_ip)

# ヘルスチェック
curl -s http://${EC2_IP}:8080/health | jq .

# ユーザー作成
curl -s -X POST http://${EC2_IP}:8080/users \
  -H "Content-Type: application/json" \
  -d '{"name":"test-user","email":"test@example.com","tenant_id":"tenant-001"}' | jq .

# ユーザー取得
curl -s http://${EC2_IP}:8080/users/1 | jq .
```

### systemd ログ確認

```bash
sudo journalctl -u go-echo-api -f --since "10 minutes ago"
sudo journalctl -u mysqld -f --since "10 minutes ago"
```

---

## 壊す手順

### 課題 1: Security Group から 8080 番ポートを閉じる

```bash
# 現在の SG ルールを確認
SG_ID=$(terraform output -raw security_group_id)
aws ec2 describe-security-groups --group-ids ${SG_ID}

# Terraform で 8080 インバウンドルールをコメントアウト
# main.tf の ingress for port 8080 ブロックをコメントアウト
terraform apply
# → "your connection timed out" または Connection refused になること
curl http://${EC2_IP}:8080/health  # タイムアウトを確認
```

### 課題 2: EC2 を手動で停止する

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ec2 stop-instances --instance-ids ${INSTANCE_ID}

# API が応答しないことを確認
curl http://${EC2_IP}:8080/health
# → connection refused

# EC2 を再起動
aws ec2 start-instances --instance-ids ${INSTANCE_ID}
```

### 課題 3: go-echo-api サービスを停止する

```bash
# EC2 内で実行
sudo systemctl stop go-echo-api
curl http://localhost:8080/health  # Connection refused を確認

# プロセス確認
ps aux | grep go-echo-api
```

---

## 復旧手順

### SG ルールを戻す

```bash
# main.tf のコメントアウトを解除して再適用
terraform apply
# → curl が再び 200 を返すことを確認
curl http://${EC2_IP}:8080/health
```

### EC2 を起動する

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ec2 start-instances --instance-ids ${INSTANCE_ID}

# 起動確認（30〜60 秒待つ）
aws ec2 wait instance-running --instance-ids ${INSTANCE_ID}
echo "EC2 is running"

# 新しい IP アドレスを確認（Elastic IP 未使用の場合は変わる）
terraform output public_ip
```

### go-echo-api サービスを再起動する

```bash
# EC2 内で実行
sudo systemctl start go-echo-api
sudo systemctl status go-echo-api
curl http://localhost:8080/health
```

---

## 削除手順

**注意**: 以下の手順を実行すると作成したすべての AWS リソースが削除される。課金が止まる。

```bash
# step00_terraform_base ディレクトリで実行
cd step00_terraform_base

# 削除対象を確認
terraform plan -destroy

# 削除実行
terraform destroy
# 確認プロンプトで yes を入力

# 削除されたことを確認
terraform state list  # 空になること
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=scaling-step00" \
  --query "Reservations[].Instances[].State.Name"
# → [] または "terminated"
```

詳細は [destroy.md](./destroy.md) を参照。

---

## 学び

| 項目 | 学んだこと |
|------|-----------|
| Terraform の冪等性 | `terraform apply` を何度実行しても同じ状態になる |
| State ファイル | `terraform.tfstate` がリソースの現状を記録する。チームでは S3 + DynamoDB で管理する |
| user_data | EC2 初回起動時に一度だけ実行されるシェルスクリプト。インスタンス再起動では実行されない |
| SG の重要性 | ポートを閉じるだけでサービスが届かなくなる。最小権限の原則 |
| systemd | プロセスの自動起動・再起動・ログ管理を担う。`Restart=always` で落ちても自動復旧 |
| 単一障害点 | EC2 1 台 + MySQL 同居は SPOF。次のステップで分離していく |

---

## k6 負荷テスト

### 前提

```bash
# k6 インストール (macOS)
brew install k6

# k6 インストール (Linux)
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6
```

### 簡易負荷テスト

```bash
EC2_IP=$(cd step00_terraform_base && terraform output -raw public_ip)

# 10 VUs で 30 秒間ヘルスチェックエンドポイントを叩く
k6 run --vus 10 --duration 30s - <<'EOF'
import http from 'k6/http';
import { check } from 'k6';

export default function () {
  const res = http.get(`http://${__ENV.EC2_IP}:8080/health`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}
EOF
```

### 期待結果（t3.micro, 1 CPU, 1GB RAM）

| メトリクス | index あり | 備考 |
|-----------|-----------|------|
| p50 latency | < 10ms | ヘルスチェックのみ |
| p95 latency | < 50ms | |
| p99 latency | < 100ms | |
| Error Rate | 0% | SG が正しく開いている場合 |
| RPS | ~500 req/s | t3.micro の上限付近 |

> **NOTE**: このステップでは DB クエリを伴わないヘルスチェックのみ。DB クエリを含む負荷テストは STEP 01 で実施する。

---
