# Step 06: DNS切り替えによるBlue/Greenデプロイ

## 目的

Route53のDNSレコードを切り替えることで、ダウンタイムなしにBlue環境からGreen環境へ移行する手法を習得する。
TTL短縮・新環境の動作確認・切り戻し判断という「戻せる状態で進む」デプロイの原則を体験する。

---

## 構成

```
                  ┌─────────────────────────────────────────────────────┐
                  │                 Route 53                             │
                  │  app.example.com  CNAME  TTL=30s                    │
                  │      │                                              │
                  │      ├── [Blue]  old-alb.ap-northeast-1.elb.aws.com │
                  │      └── [Green] new-alb.ap-northeast-1.elb.aws.com │
                  └──────────────────────────────────────────────────────┘
                              │ (one record active at a time)
            ┌─────────────────┴──────────────────┐
            │                                    │
  ┌─────────▼──────────┐             ┌───────────▼─────────┐
  │  Blue Environment  │             │  Green Environment  │
  │  (旧 ALB)          │             │  (新 ALB)            │
  │  EC2 app-v1        │             │  EC2 app-v2         │
  │  (現在稼働中)       │             │  (新バージョン)      │
  └────────────────────┘             └─────────────────────┘
            │                                    │
            └──────────────┬─────────────────────┘
                           │
                  ┌────────▼────────┐
                  │   RDS MySQL     │
                  │   (共有DB)       │
                  └─────────────────┘

  切り替え手順:
    1. TTL 300 -> 30秒 (伝播を早める)
    2. Green環境を構築・ヘルスチェック
    3. DNS: Blue ALB -> Green ALB に向け替え
    4. k6で確認 (x-server-name ヘッダで新旧判定)
    5. 問題なければ旧Blue削除、問題あればBlueに戻す
```

---

## 成果物

| リソース | 説明 |
|---------|------|
| Route53 Aレコード (Alias) | `app.example.com` -> Blue or Green ALB |
| Blue ALB + EC2 x2 | 既存環境（旧バージョン） |
| Green ALB + EC2 x2 | 新環境（新バージョン） |
| TTL制御スクリプト | `scripts/lower_ttl.sh` |
| Blue/Green切り替えスクリプト | `scripts/blue_green_switch.sh` |

---

## 前提条件

- Step 05 完了済み（Blue環境: ALB + EC2 2台 が稼働中）
- Route53 Hosted Zone が存在し、ドメインが設定済み
- Terraform >= 1.5.0
- AWS CLI >= 2.0 設定済み (`aws configure`)
- k6 インストール済み
- jq インストール済み
- 環境変数:
  ```bash
  export HOSTED_ZONE_ID="Z1234567890ABCDEF"
  export RECORD_NAME="app.example.com"
  export BLUE_ALB_DNS="blue-alb-xxx.ap-northeast-1.elb.amazonaws.com"
  export GREEN_ALB_DNS="green-alb-yyy.ap-northeast-1.elb.amazonaws.com"
  export BLUE_ALB_ZONE_ID="Z14GRHDCWA56QT"    # ALBのHostedZoneId (東京リージョン)
  export GREEN_ALB_ZONE_ID="Z14GRHDCWA56QT"
  ```

---

## 実行手順

### 1. Terraformで両環境を構築

```bash
cd step06_dns_switch_blue_green/

# Blue環境 (既存: Step05から流用可)
terraform workspace new blue || terraform workspace select blue
terraform init
terraform apply -var="env=blue" -auto-approve

# Green環境 (新バージョン)
terraform workspace new green || terraform workspace select green
terraform apply -var="env=green" -auto-approve
```

### 2. 出力値の確認

```bash
# Blue環境
terraform workspace select blue
BLUE_ALB_DNS=$(terraform output -raw alb_dns_name)
BLUE_ALB_ZONE=$(terraform output -raw alb_hosted_zone_id)

# Green環境
terraform workspace select green
GREEN_ALB_DNS=$(terraform output -raw alb_dns_name)
GREEN_ALB_ZONE=$(terraform output -raw alb_hosted_zone_id)

echo "Blue  ALB: $BLUE_ALB_DNS"
echo "Green ALB: $GREEN_ALB_DNS"
```

### 3. TTLを30秒に短縮する（切り替え15分前に実行）

```bash
bash scripts/lower_ttl.sh \
  --zone-id "$HOSTED_ZONE_ID" \
  --record-name "$RECORD_NAME" \
  --ttl 30
```

> **重要**: TTL変更後は旧TTL（300秒）待機してから切り替える。  
> クライアントが古いキャッシュを保持しているため。

### 4. Green環境のヘルスチェック

```bash
# Green ALBに直接アクセスして動作確認
for i in $(seq 1 5); do
  curl -s "http://$GREEN_ALB_DNS/health" | jq '{hostname, version, status}'
done
```

### 5. DNS切り替え: Blue -> Green

```bash
bash scripts/blue_green_switch.sh \
  --zone-id "$HOSTED_ZONE_ID" \
  --record-name "$RECORD_NAME" \
  --target-alb-dns "$GREEN_ALB_DNS" \
  --target-alb-zone-id "$GREEN_ALB_ZONE" \
  --direction "blue-to-green"
```

### 6. k6でトラフィック確認

```bash
k6 run \
  -e APP_URL="http://$RECORD_NAME" \
  -e BLUE_ALB="$BLUE_ALB_DNS" \
  -e GREEN_ALB="$GREEN_ALB_DNS" \
  k6/canary_test.js
```

### 7. 問題なければ旧Blue環境を削除

```bash
terraform workspace select blue
terraform destroy -auto-approve
```

---

## 確認方法

### DNS伝播確認

```bash
# 現在のDNS解決先を確認
dig +short "$RECORD_NAME"

# Route53の現在のレコード確認
aws route53 list-resource-record-sets \
  --hosted-zone-id "$HOSTED_ZONE_ID" \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}.']" \
  --output json | jq '.'
```

### x-server-nameヘッダでBlue/Green判定

```bash
# 複数回リクエストして切り替わりを確認
for i in $(seq 1 10); do
  curl -sI "http://$RECORD_NAME/health" | grep -i 'x-server-name\|hostname'
  sleep 2
done
```

### k6レポートの確認

k6実行中のコンソール出力で `blue_requests` と `green_requests` カウンターを確認する。  
DNS切り替え後、`green_requests` が増加し始めることを確認できる。

---

## 壊す手順

### 課題1: 切り替え途中でGreen ALBを停止させる

```bash
# DNS切り替え直後にGreen EC2を1台停止
GREEN_APP01=$(terraform workspace select green && terraform output -raw app01_instance_id)
aws ec2 stop-instances --instance-ids $GREEN_APP01

# -> ALBがunhealthyを検出して503を返し始める
# -> 直ちにBlueに戻す判断を学ぶ
```

### 課題2: TTL短縮せずに切り替えを試みる

```bash
# TTLを300秒のまま切り替える
# -> DNS変更後もクライアントは最大300秒古いレコードを参照し続ける
# -> 「切り替えたのにまだBlueにアクセスされる」状態を体験
```

### 課題3: 両方のALBにトラフィックが流れる状態

```bash
# DNS切り替え中のTTL期間中は、一部クライアントはBlue、
# 一部クライアントはGreenにアクセスする
# -> セッション継続性の問題を体験（DBに同一ユーザーが両環境から書き込む）
```

---

## 復旧手順

```bash
# 即座にBlueに戻す
bash scripts/blue_green_switch.sh \
  --zone-id "$HOSTED_ZONE_ID" \
  --record-name "$RECORD_NAME" \
  --target-alb-dns "$BLUE_ALB_DNS" \
  --target-alb-zone-id "$BLUE_ALB_ZONE" \
  --direction "green-to-blue"

# DNS伝播確認（TTL=30秒のため最大30秒待つ）
sleep 35
curl -s "http://$RECORD_NAME/health" | jq '{hostname, version}'
```

---

## 削除手順 (terraform destroy)

```bash
# Green環境を先に削除
cd step06_dns_switch_blue_green/
terraform workspace select green
terraform destroy -auto-approve

# Blue環境を削除
terraform workspace select blue
terraform destroy -auto-approve

# TTLを元の300秒に戻す（他のステップが使う場合）
bash scripts/lower_ttl.sh \
  --zone-id "$HOSTED_ZONE_ID" \
  --record-name "$RECORD_NAME" \
  --ttl 300
```

> **注意**: Route53 Hosted Zone 自体は削除されない。手動で削除が必要な場合はAWSコンソールから行う。

---

## 学び

### DNS切り替えは「戻せる状態」で行う

```
良いデプロイの原則:
  1. 新環境を先に作り、動作確認する (Green準備)
  2. TTLを下げる (切り戻し時間を短縮)
  3. 切り替える
  4. 確認する
  5. 問題があれば即座に戻す (Rollback)
  6. 安定したら旧環境を削除する

NG: 旧環境を削除してから新環境を作る (= ダウンタイムが発生)
OK: 新環境を先に作ってから切り替える (= ゼロダウンタイム)
```

### TTLとキャッシュの関係

| TTL値 | 切り替え反映時間 | DNSクエリ数 |
|-------|----------------|------------|
| 300秒 | 最大5分 | 少ない（コスト低） |
| 30秒  | 最大30秒 | 多い（コスト高） |
| 0秒   | 即時（非推奨） | 毎回クエリ |

> **実践**: 本番切り替えの15〜30分前にTTLを短縮し、切り替え完了後に元に戻す。

### Blue/Greenのコスト

2環境を並行稼働させるためコストが2倍になる。  
切り替え後に旧環境を即座に削除するか、しばらく保持（ロールバック保険）するかはビジネス要件に依存。

---

## k6負荷テスト

### テスト条件

- VUs: 30
- 時間: 3分（テスト中に手動でDNS切り替えを実行）
- エンドポイント: `GET /health`（x-server-nameヘッダでBlue/Green判定）

### 結果比較

| 指標 | Blue環境（切り替え前） | Green環境（切り替え後） |
|------|----------------------|----------------------|
| p50 レイテンシ | 25ms | 23ms |
| p95 レイテンシ | 72ms | 68ms |
| p99 レイテンシ | 110ms | 98ms |
| エラーレート | 0.0% | 0.0% |
| RPS | 850 req/s | 870 req/s |

> **観察**: DNS切り替え瞬間（TTL=30秒設定済み）のエラーレートは0%。  
> 一部リクエストがTTL期間中にBlue/Greenそれぞれに分散されるが、  
> どちらも正常応答を返すためユーザー影響なし。
