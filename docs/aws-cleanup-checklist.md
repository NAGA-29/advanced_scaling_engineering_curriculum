# AWS クリーンアップチェックリスト / AWS Cleanup Checklist

各ステップで作成したAWSリソースを確実に削除するためのチェックリストです。
**ステップが終わったら必ずこのチェックリストを実行してください。** 削除漏れは意図しない課金につながります。

> **基本原則**: 各ステップのディレクトリで `terraform destroy` を実行するのが最も確実です。
> ただし、手動で作成したリソースや Terraform の管理外リソースは個別に削除が必要です。

---

## 共通クリーンアップコマンド

どのステップでも最後に以下を実行して「何も残っていないか」を確認してください。

```bash
# 稼働中リソースの全体確認
echo "=== Running EC2 Instances ==="
aws ec2 describe-instances \
  --filter "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceType,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table

echo "=== Active RDS Instances ==="
aws rds describe-db-instances \
  --query "DBInstances[*].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Class:DBInstanceClass}" \
  --output table

echo "=== Active Load Balancers ==="
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[*].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}" \
  --output table

echo "=== NAT Gateways (should be empty) ==="
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].{ID:NatGatewayId,State:State,Subnet:SubnetId}" \
  --output table

echo "=== Elastic IPs ==="
aws ec2 describe-addresses \
  --query "Addresses[*].{IP:PublicIp,AssocID:AssociationId,AllocID:AllocationId}" \
  --output table
```

---

## step00 〜 step02: 単一EC2構成

### 作成されたリソース
- EC2 インスタンス (t3.micro) × 1 — App + MySQL
- セキュリティグループ × 1
- キーペア × 1
- EBS ボリューム × 1 (EC2削除時に自動削除)

### クリーンアップ手順

```bash
# Terraform で作成した場合
cd /path/to/step00_terraform_base/terraform
terraform destroy -auto-approve

# 手動確認
aws ec2 describe-instances \
  --filter "Name=tag:Step,Values=step00" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name}" \
  --output table
```

### 手動削除が必要な場合
```bash
# EC2 インスタンスの削除
aws ec2 terminate-instances --instance-ids i-XXXXXXXXXXXXXXXXX

# セキュリティグループの削除（EC2削除後）
aws ec2 delete-security-group --group-id sg-XXXXXXXXXXXXXXXXX

# キーペアの削除
aws ec2 delete-key-pair --key-name YOUR_KEY_NAME
```

### チェックリスト
- [ ] EC2 インスタンスが terminated 状態になっている
- [ ] セキュリティグループが削除されている
- [ ] キーペアが削除されている（ローカルの .pem ファイルも削除）

---

## step03: RDS Read Replica

### 作成されたリソース
- RDS インスタンス (t3.micro) × 2 (Primary + Read Replica)
- DB Subnet Group × 1
- RDS セキュリティグループ × 1
- VPC / Subnet (新規作成した場合)

### クリーンアップ手順

```bash
cd /path/to/step03_read_replica/terraform
terraform destroy -auto-approve
```

### 手動削除が必要な場合

```bash
# Read Replica を先に削除する（Primaryより先に削除が必要）
aws rds delete-db-instance \
  --db-instance-identifier YOUR_REPLICA_ID \
  --skip-final-snapshot

# Read Replica の削除完了を待つ
aws rds wait db-instance-deleted \
  --db-instance-identifier YOUR_REPLICA_ID

# Primary RDS を削除
aws rds delete-db-instance \
  --db-instance-identifier YOUR_PRIMARY_ID \
  --skip-final-snapshot

# Primary の削除完了を待つ
aws rds wait db-instance-deleted \
  --db-instance-identifier YOUR_PRIMARY_ID

# DB Subnet Group の削除（RDS削除後）
aws rds delete-db-subnet-group \
  --db-subnet-group-name YOUR_SUBNET_GROUP_NAME
```

### チェックリスト
- [ ] RDS Read Replica が削除されている
- [ ] RDS Primary が削除されている
- [ ] DB Subnet Group が削除されている
- [ ] RDS 用セキュリティグループが削除されている
- [ ] 自動バックアップ（スナップショット）が不要であれば削除

```bash
# RDS スナップショットの確認と削除
aws rds describe-db-snapshots \
  --query "DBSnapshots[*].{ID:DBSnapshotIdentifier,Status:Status,Time:SnapshotCreateTime}" \
  --output table

aws rds delete-db-snapshot --db-snapshot-identifier YOUR_SNAPSHOT_ID
```

---

## step04: Redis on EC2

### 作成されたリソース
- EC2 インスタンス (t3.micro) × 1 — Redis サーバー
- Redis 用セキュリティグループ × 1

### クリーンアップ手順

```bash
cd /path/to/step04_redis_cache_aside/terraform
terraform destroy -auto-approve
```

### 手動削除が必要な場合

```bash
# Redis EC2 の削除
aws ec2 terminate-instances --instance-ids i-XXXXXXXXXXXXXXXXX

# Redis 用セキュリティグループの削除
aws ec2 delete-security-group --group-id sg-XXXXXXXXXXXXXXXXX
```

### チェックリスト
- [ ] Redis EC2 インスタンスが terminated になっている
- [ ] Redis 用セキュリティグループが削除されている

---

## step05 〜 step06: ALB + 複数EC2

### 作成されたリソース
- ALB (Application Load Balancer) × 1
- ALB Listener × 1
- Target Group × 1
- EC2 インスタンス × 2 (App サーバー)
- ALB 用セキュリティグループ × 1

### クリーンアップ手順

```bash
cd /path/to/step05_alb_multi_ec2/terraform
terraform destroy -auto-approve
```

### 手動削除が必要な場合

```bash
# ALB Listener を先に削除
ALB_ARN=$(aws elbv2 describe-load-balancers \
  --names YOUR_ALB_NAME \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text)

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn $ALB_ARN \
  --query "Listeners[0].ListenerArn" \
  --output text)

aws elbv2 delete-listener --listener-arn $LISTENER_ARN

# ALB の削除
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN

# ALB 削除完了を待つ
aws elbv2 wait load-balancers-deleted --load-balancer-arns $ALB_ARN

# Target Group の削除（ALB削除後）
TG_ARN=$(aws elbv2 describe-target-groups \
  --names YOUR_TG_NAME \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

aws elbv2 delete-target-group --target-group-arn $TG_ARN

# EC2 インスタンスの削除
aws ec2 terminate-instances --instance-ids i-XXXXXXXX i-YYYYYYYY

# セキュリティグループの削除（EC2削除後）
aws ec2 delete-security-group --group-id sg-XXXXXXXXXXXXXXXXX
```

### チェックリスト
- [ ] ALB が削除されている
- [ ] ALB Listener が削除されている
- [ ] Target Group が削除されている
- [ ] EC2 インスタンス（複数台）が terminated になっている
- [ ] ALB 用セキュリティグループが削除されている

---

## step07: ProxySQL / Connection Pooling

### 作成されたリソース
- EC2 インスタンス (t3.micro) × 1 — ProxySQL サーバー
- ProxySQL 用セキュリティグループ × 1

### チェックリスト
- [ ] ProxySQL EC2 インスタンスが terminated になっている
- [ ] ProxySQL 用セキュリティグループが削除されている

---

## step08: DB Sharding

### 作成されたリソース
- RDS インスタンス (t3.micro) × 2 (Shard 0 + Shard 1) — 追加分
- DB Subnet Group (新規の場合)

### クリーンアップ手順

```bash
# 両シャードを削除
aws rds delete-db-instance \
  --db-instance-identifier YOUR_SHARD0_ID \
  --skip-final-snapshot

aws rds delete-db-instance \
  --db-instance-identifier YOUR_SHARD1_ID \
  --skip-final-snapshot

# 削除完了を待つ
aws rds wait db-instance-deleted --db-instance-identifier YOUR_SHARD0_ID
aws rds wait db-instance-deleted --db-instance-identifier YOUR_SHARD1_ID
```

### チェックリスト
- [ ] RDS Shard 0 が削除されている
- [ ] RDS Shard 1 が削除されている

---

## step11: ALB Blue/Green Deployment

### 作成されたリソース
- Target Group × 2 (Blue + Green)
- EC2 インスタンス × 2 (Green 環境用)

### クリーンアップ手順

```bash
cd /path/to/step11_blue_green_alb/terraform
terraform destroy -auto-approve
```

### 手動削除が必要な場合

```bash
# Blue/Green 両方の Target Group を削除
aws elbv2 delete-target-group --target-group-arn arn:aws:...:targetgroup/blue-tg/...
aws elbv2 delete-target-group --target-group-arn arn:aws:...:targetgroup/green-tg/...

# Green 環境の EC2 を削除
aws ec2 terminate-instances --instance-ids i-GREEN1 i-GREEN2
```

### チェックリスト
- [ ] Blue Target Group が削除されている
- [ ] Green Target Group が削除されている
- [ ] Green 環境 EC2 が terminated になっている

---

## step12: Route53 Blue/Green

### 作成されたリソース
- Route53 Hosted Zone (既存の場合は変更のみ)
- Route53 レコード（Weighted Routing）× 2

### クリーンアップ手順

```bash
# Route53 レコードの削除
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='YOUR_DOMAIN.'].Id" \
  --output text | sed 's|/hostedzone/||')

# レコードセットの一覧確認
aws route53 list-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --query "ResourceRecordSets[?Type=='A']" \
  --output table

# 加重ルーティングレコードの削除（change-batch JSONファイルを用意）
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --change-batch file://delete-records.json
```

### チェックリスト
- [ ] Route53 加重ルーティングレコード（Blue）が削除されている
- [ ] Route53 加重ルーティングレコード（Green）が削除されている
- [ ] Hosted Zone を新規作成した場合は削除されている（$0.50/月の節約）
- [ ] 追加 ALB（Green 用）が削除されている

---

## step14: Full Distributed System

### 全リソース削除順序

**削除は依存関係の逆順で行います。**

```bash
# Step 1: Route53 レコードを削除（トラフィックを止める）
aws route53 change-resource-record-sets ...

# Step 2: ALB Listener を削除
aws elbv2 delete-listener --listener-arn ...

# Step 3: ALB を削除（Blue + Green の両方）
aws elbv2 delete-load-balancer --load-balancer-arn ALB_BLUE_ARN
aws elbv2 delete-load-balancer --load-balancer-arn ALB_GREEN_ARN

# Step 4: EC2 インスタンスを削除（すべて）
aws ec2 terminate-instances --instance-ids \
  i-APP1 i-APP2 i-APP3 i-APP4 i-REDIS i-PROXYSQL

# Step 5: RDS を削除（Replica → Primary の順）
aws rds delete-db-instance --db-instance-identifier replica --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier replica
aws rds delete-db-instance --db-instance-identifier primary --skip-final-snapshot
aws rds delete-db-instance --db-instance-identifier shard0 --skip-final-snapshot
aws rds delete-db-instance --db-instance-identifier shard1 --skip-final-snapshot

# Step 6: Target Groups を削除
aws elbv2 delete-target-group --target-group-arn TG_BLUE_ARN
aws elbv2 delete-target-group --target-group-arn TG_GREEN_ARN

# Step 7: セキュリティグループを削除
aws ec2 delete-security-group --group-id sg-APP
aws ec2 delete-security-group --group-id sg-RDS
aws ec2 delete-security-group --group-id sg-REDIS
aws ec2 delete-security-group --group-id sg-ALB

# Step 8: DB Subnet Group を削除
aws rds delete-db-subnet-group --db-subnet-group-name YOUR_SUBNET_GROUP

# Step 9: VPC を削除（カリキュラム専用VPCを作成した場合）
# サブネット → VPC の順
aws ec2 delete-subnet --subnet-id subnet-XXXXXXXX
aws ec2 delete-vpc --vpc-id vpc-XXXXXXXXXXXXXXXXX
```

### step14 チェックリスト
- [ ] Route53 レコードがすべて削除されている
- [ ] ALB (Blue) が削除されている
- [ ] ALB (Green) が削除されている
- [ ] Target Group (Blue) が削除されている
- [ ] Target Group (Green) が削除されている
- [ ] EC2 App サーバー × 4 が terminated になっている
- [ ] EC2 Redis サーバーが terminated になっている
- [ ] EC2 ProxySQL サーバーが terminated になっている
- [ ] RDS Primary が削除されている
- [ ] RDS Read Replica が削除されている
- [ ] RDS Shard 0 が削除されている
- [ ] RDS Shard 1 が削除されている
- [ ] セキュリティグループがすべて削除されている
- [ ] DB Subnet Group が削除されている
- [ ] Elastic IP が解放されている

---

## 最終確認コマンド（全ステップ共通）

すべてのステップ完了後、以下を実行してリソースが残っていないことを確認します。

```bash
#!/bin/bash
# final-check.sh — リソース残存チェック

REGION=${AWS_REGION:-ap-northeast-1}
echo "Checking region: $REGION"
echo "========================================"

echo ""
echo "[EC2] Running or Stopped Instances:"
aws ec2 describe-instances \
  --region $REGION \
  --filter "Name=instance-state-name,Values=running,stopped,stopping" \
  --query "Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,Type:InstanceType}" \
  --output table

echo ""
echo "[RDS] Active DB Instances:"
aws rds describe-db-instances \
  --region $REGION \
  --query "DBInstances[?DBInstanceStatus!='deleted'].{ID:DBInstanceIdentifier,Status:DBInstanceStatus}" \
  --output table

echo ""
echo "[ALB] Active Load Balancers:"
aws elbv2 describe-load-balancers \
  --region $REGION \
  --query "LoadBalancers[?State.Code!='deleted'].{Name:LoadBalancerName,State:State.Code}" \
  --output table

echo ""
echo "[NAT] NAT Gateways (should be empty!):"
aws ec2 describe-nat-gateways \
  --region $REGION \
  --filter "Name=state,Values=available,pending" \
  --query "NatGateways[*].{ID:NatGatewayId,State:State}" \
  --output table

echo ""
echo "[EIP] Unassociated Elastic IPs:"
aws ec2 describe-addresses \
  --region $REGION \
  --query "Addresses[?AssociationId==null].{IP:PublicIp,AllocID:AllocationId}" \
  --output table

echo ""
echo "[Route53] Hosted Zones:"
aws route53 list-hosted-zones \
  --query "HostedZones[*].{Name:Name,ID:Id,Records:ResourceRecordSetCount}" \
  --output table

echo ""
echo "========================================"
echo "If any resources appear above, they may be incurring charges."
echo "Run terraform destroy in each step directory, or delete manually."
```

---

## Terraform Destroy のベストプラクティス

```bash
# 各ステップのディレクトリで実行
cd stepXX_<name>/terraform

# プランで何が削除されるか確認
terraform plan -destroy

# 削除実行
terraform destroy -auto-approve

# 削除後の確認
terraform show  # 空であることを確認
```

> **注意**: `terraform destroy` で削除できないリソースがある場合は、
> AWSコンソールまたはAWS CLIで手動削除してください。
> よくある原因: セキュリティグループが他のリソースから参照されている、
> S3バケットにオブジェクトが残っている、など。
