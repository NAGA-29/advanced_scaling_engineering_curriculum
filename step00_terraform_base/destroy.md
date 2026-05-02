# STEP 00: 削除手順 (destroy.md)

## 概要

このドキュメントでは STEP 00 で作成した AWS リソースをすべて削除する手順を説明する。  
誤課金防止のため、演習終了後は必ず実行すること。

---

## 削除対象リソース

| リソース種別 | リソース名/説明 |
|-------------|----------------|
| EC2 Instance | `scaling-step00-api` (t3.micro) |
| Security Group | `scaling-step00-sg` |
| Key Pair | `scaling-step00-key` |
| Public Subnet | `scaling-step00-public-1a` |
| Internet Gateway | `scaling-step00-igw` |
| Route Table | `scaling-step00-public-rt` |
| VPC | `scaling-step00-vpc` |
| EIP (オプション) | EC2 に紐付けた Elastic IP |

---

## 事前確認

```bash
# 現在の Terraform State を確認
cd step00_terraform_base
terraform state list
```

期待出力例:
```
aws_instance.api
aws_internet_gateway.igw
aws_key_pair.deployer
aws_route.public_internet_access
aws_route_table.public
aws_route_table_association.public
aws_security_group.api_sg
aws_subnet.public
aws_vpc.main
```

---

## 削除手順

### ステップ 1: Terraform destroy で削除

```bash
cd step00_terraform_base

# 削除予定を確認（実際には削除しない）
terraform plan -destroy

# 削除実行
terraform destroy
```

プロンプトが表示される:
```
Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value:
```

`yes` と入力して Enter を押す。

---

### ステップ 2: 削除完了の確認

```bash
# State が空になっていることを確認
terraform state list
# 出力なし = 全リソース削除済み

# EC2 インスタンスが terminated になっていることを確認
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=scaling-step00" \
  --query "Reservations[].Instances[].{ID:InstanceId,State:State.Name}" \
  --output table
```

期待出力:
```
---------------------------------
|      DescribeInstances        |
+--------------------+----------+
|         ID         |  State   |
+--------------------+----------+
|  i-0123456789abcdef|terminated|
+--------------------+----------+
```

---

### ステップ 3: VPC が削除されていることを確認

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=scaling-step00" \
  --query "Vpcs[].{VpcId:VpcId,State:State}" \
  --output table
# 出力なし = 削除済み
```

---

### ステップ 4: Key Pair の削除確認

```bash
aws ec2 describe-key-pairs \
  --filters "Name=tag:Project,Values=scaling-step00" \
  --query "KeyPairs[].KeyName" \
  --output table
# 出力なし = 削除済み

# ローカルの秘密鍵も削除（不要な場合）
rm -f ~/.ssh/scaling-key.pem
```

---

## 手動削除が必要なケース

Terraform destroy が失敗した場合や State が壊れた場合は、AWS コンソールまたは CLI で手動削除する。

### 手動削除の順序

依存関係があるため、以下の順番で削除する：

1. **EC2 インスタンスを終了**
   ```bash
   INSTANCE_ID=$(aws ec2 describe-instances \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "Reservations[0].Instances[0].InstanceId" \
     --output text)
   aws ec2 terminate-instances --instance-ids ${INSTANCE_ID}
   aws ec2 wait instance-terminated --instance-ids ${INSTANCE_ID}
   ```

2. **Elastic IP の解放（使用している場合）**
   ```bash
   ALLOC_ID=$(aws ec2 describe-addresses \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "Addresses[0].AllocationId" \
     --output text)
   aws ec2 release-address --allocation-id ${ALLOC_ID}
   ```

3. **Security Group の削除**
   ```bash
   SG_ID=$(aws ec2 describe-security-groups \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "SecurityGroups[0].GroupId" \
     --output text)
   aws ec2 delete-security-group --group-id ${SG_ID}
   ```

4. **サブネットの削除**
   ```bash
   SUBNET_ID=$(aws ec2 describe-subnets \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "Subnets[0].SubnetId" \
     --output text)
   aws ec2 delete-subnet --subnet-id ${SUBNET_ID}
   ```

5. **Internet Gateway のデタッチと削除**
   ```bash
   IGW_ID=$(aws ec2 describe-internet-gateways \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "InternetGateways[0].InternetGatewayId" \
     --output text)
   VPC_ID=$(aws ec2 describe-vpcs \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "Vpcs[0].VpcId" \
     --output text)
   aws ec2 detach-internet-gateway --internet-gateway-id ${IGW_ID} --vpc-id ${VPC_ID}
   aws ec2 delete-internet-gateway --internet-gateway-id ${IGW_ID}
   ```

6. **Route Table の削除（メインルートテーブル以外）**
   ```bash
   RT_ID=$(aws ec2 describe-route-tables \
     --filters "Name=tag:Project,Values=scaling-step00" \
     --query "RouteTables[0].RouteTableId" \
     --output text)
   aws ec2 delete-route-table --route-table-id ${RT_ID}
   ```

7. **VPC の削除**
   ```bash
   aws ec2 delete-vpc --vpc-id ${VPC_ID}
   ```

8. **Key Pair の削除**
   ```bash
   aws ec2 delete-key-pair --key-name scaling-step00-key
   ```

---

## 削除後のコスト確認

削除後は AWS Cost Explorer または Billing Dashboard で課金が止まっていることを確認する。

- EC2 t3.micro: 停止後は課金なし（EBS は別途）
- EBS gp3 20GB: `terraform destroy` で削除される
- Elastic IP: 未アタッチ状態でも課金される → 必ず解放する

```bash
# 残存リソースの簡易確認
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].{ID:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table
```

---

## Terraform State のクリーンアップ

```bash
# tfstate ファイルと .terraform ディレクトリを削除（State が不要になった場合）
rm -f terraform.tfstate terraform.tfstate.backup
rm -rf .terraform .terraform.lock.hcl

# tfvars は機密情報を含む場合があるので注意して削除
rm -f terraform.tfvars
```

> **注意**: `terraform.tfstate` を削除すると Terraform はリソースを管理できなくなる。  
> 本番環境では絶対に行わないこと。
