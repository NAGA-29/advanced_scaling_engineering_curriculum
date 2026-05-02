# AWS コスト警告 / AWS Cost Warnings

> **⚠️ 重要**: AWSリソースは使い終わったらすぐに削除してください。
> 特にRDSとALBは起動しているだけで課金され続けます。
>
> **⚠️ IMPORTANT**: Delete AWS resources immediately after use.
> RDS and ALB incur charges simply by being in a running state.

---

## カリキュラムで使用するAWSリソースと概算コスト

以下の料金は **ap-northeast-1 (東京リージョン)** の2024年時点の目安です。
実際の料金はAWS料金ページで最新情報を確認してください。

| リソース | 仕様 | 時間単価 | 月額概算 | 備考 |
|---------|------|---------|---------|------|
| EC2 t3.micro | 2 vCPU, 1 GiB RAM | $0.0152/h | ~$11/月 | App サーバー用 |
| EC2 t3.micro | 2 vCPU, 1 GiB RAM | $0.0152/h | ~$11/月 | Redis サーバー用 |
| RDS t3.micro (MySQL) | 2 vCPU, 1 GiB RAM | $0.026/h | ~$19/月 | Primary DB |
| RDS t3.micro (Replica) | 2 vCPU, 1 GiB RAM | $0.026/h | ~$19/月 | Read Replica |
| ALB | - | $0.0243/h | ~$18/月 | ロードバランサー |
| ALB LCU | トラフィック依存 | $0.008/LCU/h | ~$5/月 | 学習用途では低め |
| Route53 Hosted Zone | - | - | $0.50/月 | DNS管理 |
| Route53 クエリ | 100万クエリあたり | $0.40 | ~$0/月 | 学習用途では無視可 |
| EBS gp3 20GB | EC2ルートディスク | - | ~$1.6/月/台 | EC2に付随 |
| RDS ストレージ 20GB | gp2 | - | ~$2.4/月/台 | RDSに付随 |

---

## 🚨 NAT Gateway には絶対に注意してください

**NAT Gateway は最もコストが嵩みやすいリソースです。このカリキュラムでは使用しません。**

| NAT Gateway コスト | 単価 |
|---|---|
| 時間課金 | **$0.062/時間 = 約$45/月** |
| データ処理 | **$0.062/GB** |
| **合計概算** | **$50〜100/月 超えることも** |

**なぜ危険か**: Terraform でプライベートサブネットを作成すると、無意識に NAT Gateway が
作られるケースがあります。このカリキュラムのTerraformコードには NAT Gateway は含まれていませんが、
自分でVPCを変更する際は必ず確認してください。

```bash
# NAT Gateway が作成されていないか確認するコマンド
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" \
  --query "NatGateways[*].{ID:NatGatewayId,State:State,SubnetId:SubnetId}" \
  --output table
```

---

## ステップ別コスト概算

### step00 〜 step02: 単一EC2構成
```
EC2 t3.micro × 1:  $0.0152/h
1時間あたり:        ~$0.015
1日(8時間学習):     ~$0.12
```

### step03: RDS Read Replica 追加
```
EC2 t3.micro × 1:  $0.0152/h
RDS t3.micro × 2:  $0.052/h
1時間あたり:        ~$0.067
1日(8時間学習):     ~$0.54

⚠️ RDS は停止しても課金されます。学習後は必ず削除してください。
```

### step04: Redis on EC2 追加
```
EC2 t3.micro × 2:  $0.030/h  (App + Redis)
RDS t3.micro × 2:  $0.052/h
1時間あたり:        ~$0.082
1日(8時間学習):     ~$0.66
```

### step05 〜 step06: ALB + 複数EC2
```
EC2 t3.micro × 3:  $0.046/h  (App×2 + Redis)
RDS t3.micro × 2:  $0.052/h
ALB:               $0.024/h
1時間あたり:        ~$0.12
1日(8時間学習):     ~$0.97
```

### step11 〜 step14: Blue/Green + Route53
```
EC2 t3.micro × 5:  $0.076/h
RDS t3.micro × 2:  $0.052/h
ALB × 2:           $0.049/h
Route53:           $0.50/月 (固定)
1時間あたり:        ~$0.18
1日(8時間学習):     ~$1.44
```

---

## 💰 コスト削減のヒント

### 1. 学習時間外はEC2を停止する
EC2は**停止（Stop）すると課金が止まります**（EBSストレージのみ継続課金）。
```bash
# EC2の停止（課金停止）
aws ec2 stop-instances --instance-ids i-xxxxxxxxxxxx

# EC2の起動（再開）
aws ec2 start-instances --instance-ids i-xxxxxxxxxxxx
```

### 2. RDSはすぐに削除する
**RDSは「停止」しても7日後に自動再起動します。停止ではなく削除してください。**
```bash
# RDS削除（スナップショット不要の場合）
aws rds delete-db-instance \
  --db-instance-identifier YOUR_DB_ID \
  --skip-final-snapshot
```

### 3. インスタンスタイプは t3.micro を使う
このカリキュラムのすべてのTerraformコードはデフォルトで `t3.micro` を使用します。
`t3.medium` や `t3.large` に変更しないでください（コストが4〜8倍になります）。

### 4. ALBは使い終わったら削除する
ALBは $0.0243/時間 = **約$18/月** かかります。ステップが終わったら terraform destroy を実行してください。

### 5. AWSコストアラートを設定する
```
AWS Console → Billing → Budgets → Create Budget
  - Budget type: Cost budget
  - Amount: $5 USD
  - Alert: 80% ($4) で通知
```

### 6. AWS Free Tier の範囲を把握する
新規AWSアカウントの場合、以下は12ヶ月間無料枠があります：
- EC2 t2.micro: 750時間/月
- RDS t2.micro: 750時間/月
- EBS: 30GB/月

ただし **t3.micro は Free Tier 対象外** です。コスト節約のためには t2.micro を使うか、
Free Tier 期間中のみ使用してください（このカリキュラムは t3.micro を推奨します）。

---

## カリキュラム全体のコスト目安

| シナリオ | 概算コスト |
|---------|-----------|
| 1ステップを1時間で完了・即削除 | $0.05 〜 $0.20 |
| 全14ステップを1日ずつ実施・毎回削除 | $2 〜 $5 |
| RDSを削除し忘れて1週間放置 | $13 〜 $30 追加 |
| NAT Gatewayを誤作成して1ヶ月 | $45 〜 $100 追加 |

**このカリキュラムを注意深く実施すれば、総コストは $5 USD 以下に収まります。**

---

## コスト確認コマンド

```bash
# 現在稼働中のEC2一覧
aws ec2 describe-instances \
  --filter "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

# 現在稼働中のRDS一覧
aws rds describe-db-instances \
  --query "DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass}" \
  --output table

# 現在稼働中のALB一覧
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code}" \
  --output table

# 課金中のNAT Gatewayがないか確認
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query "NatGateways[*].{ID:NatGatewayId,Subnet:SubnetId}" \
  --output table
```
