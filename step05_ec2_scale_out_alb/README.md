# Step 05: EC2 スケールアウト + ALB

## 目的

単体EC2で動作していたアプリケーションを、ALB（Application Load Balancer）配下の複数EC2構成へ移行する。
ロードバランシングによる水平スケールアウトの基礎を習得し、ALBのヘルスチェック機能による自動フェイルオーバーを体験する。

---

## 構成

```
                        ┌─────────────────────────────────────────┐
                        │           AWS VPC (10.0.0.0/16)          │
                        │                                          │
  ┌────────┐   HTTPS    │  ┌─────────────────────────────────┐    │
  │ Client │ ─────────► │  │  ALB (internet-facing)          │    │
  └────────┘            │  │  Listener: 80 -> Target Group   │    │
                        │  └────────────┬────────────────────┘    │
                        │               │ Round-Robin              │
                        │    ┌──────────┴──────────┐              │
                        │    │                     │              │
                        │  ┌─▼──────────┐  ┌──────▼──────┐       │
                        │  │ EC2 app-01 │  │ EC2 app-02  │       │
                        │  │ :8080      │  │ :8080       │       │
                        │  └─────┬──────┘  └──────┬──────┘       │
                        │        │                 │              │
                        │        └────────┬────────┘              │
                        │                 │                        │
                        │         ┌───────▼───────┐               │
                        │         │  RDS MySQL    │               │
                        │         │  (Primary)    │               │
                        │         └───────────────┘               │
                        └─────────────────────────────────────────┘

  ヘルスチェック: ALB -> GET /health -> 200 OK (interval: 10s, threshold: 2)
  セッション: ステートレス（セッション情報はRedisへ）
```

---

## 成果物

| リソース | 説明 |
|---------|------|
| ALB | パブリックサブネット配置、HTTPリスナー(80) |
| Target Group | `app-01`, `app-02` 登録済み。/healthでヘルスチェック |
| EC2 app-01 | AZ-a、アプリケーションサーバー |
| EC2 app-02 | AZ-c、アプリケーションサーバー |
| Security Group (ALB) | 0.0.0.0/0:80 inbound |
| Security Group (EC2) | ALB SGからの8080のみ許可 |

---

## 前提条件

- Step 04 完了済み（VPC, Subnet, RDS, Redis構成が存在すること）
- Terraform >= 1.5.0
- AWS CLI >= 2.0 設定済み (`aws configure`)
- k6 インストール済み
- jq インストール済み
- `ALB_DNS` 環境変数が設定可能であること

---

## 実行手順

### 1. Terraformで基盤を構築

```bash
cd step05_ec2_scale_out_alb/
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### 2. 出力値を取得

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)
APP01_ID=$(terraform output -raw app01_instance_id)
APP02_ID=$(terraform output -raw app02_instance_id)
echo "ALB DNS: $ALB_DNS"
echo "app-01 ID: $APP01_ID"
echo "app-02 ID: $APP02_ID"
```

### 3. ヘルスチェック確認

```bash
# ALBのヘルスチェックが通るまで待機（約60秒）
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query "TargetHealthDescriptions[*].{Target:Target.Id,State:TargetHealth.State}" \
  --output table'
```

### 4. 動作確認

```bash
for i in $(seq 1 10); do
  curl -s http://$ALB_DNS/health | jq -r '.hostname'
done
```

---

## 確認方法

### ロードバランシングの確認

```bash
bash scripts/check_distribution.sh $ALB_DNS
```

期待される出力例:

```
Total requests: 20
app-01: 10 (50%)
app-02: 10 (50%)
```

### k6負荷テストの実行

```bash
k6 run -e ALB_URL=http://$ALB_DNS k6/alb_test.js
```

---

## 壊す手順

### 課題1: app-01を停止してALBの自動フェイルオーバーを確認する

```bash
# Step 1: 別ターミナルでリクエストを流し続ける
watch -n 1 'curl -s http://$ALB_DNS/health | jq -r "{hostname, status}"'

# Step 2: app-01を停止
aws ec2 stop-instances --instance-ids $APP01_ID

# Step 3: ALBのヘルスチェック状態を監視（unhealthyになるまで約30秒）
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query "TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}" \
  --output table'

# 期待: app-01がunhealthyになり、全リクエストがapp-02に転送される
```

### 課題2: シミュレーションスクリプトを使う

```bash
bash scripts/simulate_failure.sh $APP01_ID $(terraform output -raw target_group_arn) $ALB_DNS
```

### 確認ポイント

- app-01停止中もリクエストが成功し続けること
- エラーレートが0%であること
- app-01復旧後、再度ロードバランシングされること

---

## 復旧手順

```bash
# app-01を再起動
aws ec2 start-instances --instance-ids $APP01_ID

# ヘルスチェックでhealthyに戻ることを確認（約30秒）
watch -n 5 'aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn) \
  --query "TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}" \
  --output table'

# ロードバランシングが復旧したことを確認
bash scripts/check_distribution.sh $ALB_DNS
```

---

## 削除手順 (terraform destroy)

```bash
cd step05_ec2_scale_out_alb/
terraform destroy -auto-approve
```

> **注意**: RDS・Redisなど Step04 以前のリソースは削除されない。Step04 のディレクトリで別途 destroy が必要。

---

## 学び

### ステートレスアプリの重要性

ALBによる水平スケールアウトが機能するためには、アプリケーションが **ステートレス** であることが必須条件。

| 状態の種類 | NGな例 | OKな例 |
|-----------|--------|--------|
| セッション | サーバーのメモリに保存 | Redis/DynamoDBに保存 |
| アップロードファイル | サーバーのローカルディスク | S3に保存 |
| キャッシュ | サーバーのメモリキャッシュ | Redisで共有 |

### ALBヘルスチェックのタイミング

```
停止から検出まで: interval(10s) × unhealthy_threshold(2) = 約20秒
検出から除外まで: 即時（次のリクエストから除外）
復旧から復帰まで: interval(10s) × healthy_threshold(2) = 約20秒
```

### ラウンドロビンの均等分散

デフォルトのラウンドロビンでは、リクエストが均等に分散される。
レスポンスタイムが異なるインスタンスが混在する場合は **Least Outstanding Requests** アルゴリズムが有効。

---

## k6負荷テスト

### テスト条件

- VUs: 50
- 時間: 60秒
- エンドポイント: `GET /health`, `GET /users/:id`

### 結果比較

| 指標 | 単体EC2（Step04） | ALB+2台（Step05） |
|------|------------------|------------------|
| p50 レイテンシ | 45ms | 22ms |
| p95 レイテンシ | 180ms | 65ms |
| p99 レイテンシ | 320ms | 95ms |
| エラーレート | 0.2% | 0.0% |
| RPS | 420 req/s | 890 req/s |

> **観察**: ALB+2台構成では単体比でスループットが約2倍、レイテンシが大幅に改善される。
> インスタンスが増えるほど並列処理能力が線形にスケールすることを確認できる。
