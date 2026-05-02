# トラブルシューティングガイド / Troubleshooting Guide

このガイドでは、カリキュラムの各ステップで発生しやすい問題と解決方法を説明します。
各セクションは「症状 → 原因 → 解決策」の形式で構成されています。

---

## 目次

1. [SSH接続の問題](#1-ssh接続の問題)
2. [Terraform applyの失敗](#2-terraform-applyの失敗)
3. [MySQL接続エラー](#3-mysql接続エラー)
4. [Redis接続エラー](#4-redis接続エラー)
5. [ALBヘルスチェックの失敗](#5-albヘルスチェックの失敗)
6. [k6テストの失敗](#6-k6テストの失敗)
7. [Goコンパイルエラー](#7-goコンパイルエラー)
8. [Laravelセットアップの問題](#8-laravelセットアップの問題)

---

## 1. SSH接続の問題

### 症状 1-A: `Permission denied (publickey)`

```
ssh: connect to host X.X.X.X port 22: Permission denied (publickey)
```

**原因**:
- 使用している秘密鍵がEC2に登録された公開鍵と一致していない
- `-i` オプションで正しい鍵ファイルを指定していない

**解決策**:
```bash
# 鍵ファイルのパーミッションを確認・修正
chmod 400 ~/.ssh/your-key.pem

# 正しい鍵で接続
ssh -i ~/.ssh/your-key.pem ec2-user@YOUR_EC2_IP

# デバッグモードで接続して詳細を確認
ssh -vvv -i ~/.ssh/your-key.pem ec2-user@YOUR_EC2_IP
```

---

### 症状 1-B: `Connection timed out`

```
ssh: connect to host X.X.X.X port 22: Connection timed out
```

**原因**:
- セキュリティグループのインバウンドルールにSSH(22番)が許可されていない
- セキュリティグループのSSH許可CIDRが自分のIPと異なる
- EC2がプライベートサブネットに配置されており、パブリックIPがない

**解決策**:
```bash
# 自分のIPアドレスを確認
curl -s https://checkip.amazonaws.com

# セキュリティグループのインバウンドルールを確認
aws ec2 describe-security-groups \
  --group-ids sg-XXXXXXXXXXXXXXXXX \
  --query "SecurityGroups[0].IpPermissions" \
  --output json

# Terraformのvariables.tfまたはterraform.tfvars.exampleでssh_cidrを確認し、
# 自分のIPに合わせて修正:
# ssh_cidr = "YOUR.IP.ADDRESS/32"
```

---

### 症状 1-C: `Host key verification failed`

```
REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key verification failed.
```

**原因**:
- EC2インスタンスを再作成したため、同じIPアドレスに異なるホストキーが割り当てられた

**解決策**:
```bash
# known_hostsから古いエントリを削除
ssh-keygen -R YOUR_EC2_IP

# 再接続
ssh -i ~/.ssh/your-key.pem ec2-user@YOUR_EC2_IP
```

---

### 症状 1-D: AWS Session Manager で接続できない

```
An error occurred (TargetNotConnected) when calling the StartSession operation
```

**原因**:
- EC2インスタンスにSSM Agentがインストールされていない、または動作していない
- IAMロールに `AmazonSSMManagedInstanceCore` ポリシーが付与されていない
- EC2からSSMエンドポイントへの通信が許可されていない

**解決策**:
```bash
# EC2にSSH接続できる場合は、SSM Agentの状態を確認
sudo systemctl status amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# IAMロールの確認
aws iam list-attached-role-policies --role-name YOUR_EC2_ROLE_NAME
# AmazonSSMManagedInstanceCore が含まれているか確認
```

---

## 2. Terraform applyの失敗

### 症状 2-A: `Error: creating EC2 Instance: InvalidKeyPair.NotFound`

```
Error: creating EC2 Instance: InvalidKeyPair.NotFound: The key pair 'xxx' does not exist
```

**原因**:
- Terraformが参照しているキーペア名がAWSに存在しない
- リージョンが間違っている

**解決策**:
```bash
# 現在のリージョンのキーペア一覧を確認
aws ec2 describe-key-pairs --query "KeyPairs[*].KeyName" --output text

# terraform.tfvars.example の key_name を正しい値に設定
# またはTerraformでキーペアを作成する
```

---

### 症状 2-B: `Error: creating RDS DB Instance: InvalidParameterValue`

```
Error: creating RDS DB Instance: InvalidParameterValue:
  The parameter DBSubnetGroupName is not in the form of a valid database subnet group name.
```

**原因**:
- DB Subnet Groupが存在しない、または名前が間違っている
- VPCにサブネットが2つ以上ない（RDSには2つのAZにサブネットが必要）

**解決策**:
```bash
# DB Subnet Groupの存在確認
aws rds describe-db-subnet-groups --output table

# VPCのサブネット確認
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-XXXXXXXX" \
  --query "Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}" \
  --output table
```

---

### 症状 2-C: `Error: operation error EC2: AuthFailure`

```
Error: operation error EC2: AuthFailure: AWS was not able to validate the provided access credentials
```

**原因**:
- AWS認証情報が設定されていない
- アクセスキーが期限切れまたは無効
- 環境変数またはAWS CLIプロファイルが設定されていない

**解決策**:
```bash
# 認証情報の確認
aws sts get-caller-identity

# 認証情報の設定
aws configure
# または
export AWS_ACCESS_KEY_ID=YOUR_KEY
export AWS_SECRET_ACCESS_KEY=YOUR_SECRET
export AWS_DEFAULT_REGION=ap-northeast-1
```

---

### 症状 2-D: `Error: Provider configuration not present`

```
Error: Provider configuration not present
```

**原因**:
- `terraform init` を実行していない
- プロバイダープラグインがダウンロードされていない

**解決策**:
```bash
cd your-step/terraform
terraform init
terraform apply
```

---

### 症状 2-E: `Error: the plan was created with 1 pending change(s)`（State の不一致）

```
Error: Saved plan is stale; saved plan references resources that no longer exist.
```

**原因**:
- AWSコンソールやCLIで手動変更を加えた後、Terraformを実行しようとしている
- Terraform stateとAWS実態が一致していない

**解決策**:
```bash
# 現在の状態を更新
terraform refresh

# または強制インポート
terraform import aws_instance.app i-XXXXXXXXXXXXXXXXX

# 最終手段: stateをリセット（慎重に）
terraform state list  # 管理中のリソース確認
```

---

## 3. MySQL接続エラー

### 症状 3-A: `Too many connections`

```
Error 1040: Too many connections
```

**原因**:
- MySQLの `max_connections` 設定を超えている
- アプリケーションのコネクションプールが適切に設定されていない
- 前のリクエストの接続がクローズされていない

**解決策**:
```bash
# MySQLで現在の接続数を確認
mysql -u root -p -e "SHOW STATUS LIKE 'Threads_connected';"
mysql -u root -p -e "SHOW VARIABLES LIKE 'max_connections';"

# 現在の接続を確認
mysql -u root -p -e "SHOW PROCESSLIST;"

# Go アプリの場合、db.go でコネクションプールを確認:
# db.SetMaxOpenConns(25)
# db.SetMaxIdleConns(10)
# db.SetConnMaxLifetime(5 * time.Minute)
```

---

### 症状 3-B: `dial tcp: connection refused` (MySQL)

```
Error: dial tcp 127.0.0.1:3306: connect: connection refused
```

**原因**:
- MySQLサービスが起動していない
- MySQLが別のアドレスでリスニングしている
- DB_DSN環境変数のホスト名・ポートが間違っている

**解決策**:
```bash
# MySQL の動作確認
sudo systemctl status mysql
sudo systemctl start mysql

# MySQL のリスニングアドレス確認
sudo ss -tlnp | grep 3306

# 環境変数の確認
echo $DB_DSN
# 正しい形式: root:password@tcp(127.0.0.1:3306)/dbname?parseTime=true

# RDS の場合はエンドポイントを確認
aws rds describe-db-instances \
  --db-instance-identifier YOUR_DB_ID \
  --query "DBInstances[0].Endpoint"
```

---

### 症状 3-C: `Access denied for user`

```
Error 1045 (28000): Access denied for user 'app'@'10.0.1.5' (using password: YES)
```

**原因**:
- DBユーザーのパスワードが間違っている
- DBユーザーが指定のホストからの接続を許可されていない

**解決策**:
```sql
-- MySQL に root で接続し、ユーザーの確認
SELECT User, Host FROM mysql.user;

-- 必要であればユーザーを再作成
CREATE USER 'app'@'%' IDENTIFIED BY 'password';
GRANT ALL PRIVILEGES ON appdb.* TO 'app'@'%';
FLUSH PRIVILEGES;
```

---

### 症状 3-D: RDS への接続が `connection timed out`

**原因**:
- RDSのセキュリティグループがアプリケーションサーバーのIPを許可していない
- RDSとEC2が異なるVPCにある

**解決策**:
```bash
# RDS セキュリティグループのインバウンドルール確認
aws rds describe-db-instances \
  --db-instance-identifier YOUR_DB_ID \
  --query "DBInstances[0].VpcSecurityGroups"

# EC2のIPアドレスとRDSセキュリティグループのCIDRを比較
# EC2のプライベートIPがRDSのSGで許可されているか確認
```

---

## 4. Redis接続エラー

### 症状 4-A: `dial tcp: connection refused` (Redis)

```
Error: dial tcp 127.0.0.1:6379: connect: connection refused
```

**原因**:
- Redis サービスが起動していない
- Redis が別のアドレスでリスニングしている
- REDIS_ADDR 環境変数のホスト名が間違っている

**解決策**:
```bash
# Redis の動作確認
sudo systemctl status redis
sudo systemctl start redis

# Redis のリスニング確認
sudo ss -tlnp | grep 6379

# Redis への接続テスト
redis-cli -h YOUR_REDIS_IP ping
# 応答: PONG

# 環境変数の確認と修正
export REDIS_ADDR="YOUR_REDIS_IP:6379"
```

---

### 症状 4-B: Redis がリモートから接続できない

```
Error: dial tcp X.X.X.X:6379: connect: connection refused
```

**原因**:
- Redis がデフォルトで `127.0.0.1` のみにバインドされている
- Redis の設定で `bind 127.0.0.1` が指定されている
- セキュリティグループがポート 6379 を許可していない

**解決策**:
```bash
# Redis 設定ファイルを編集
sudo vi /etc/redis/redis.conf
# bind 127.0.0.1 → bind 0.0.0.0  (または特定のプライベートIP)

sudo systemctl restart redis

# セキュリティグループの確認
aws ec2 describe-security-groups \
  --group-ids sg-REDIS_SG_ID \
  --query "SecurityGroups[0].IpPermissions" | grep 6379
```

---

### 症状 4-C: Redis のメモリ不足

```
OOM command not allowed when used memory > 'maxmemory'
```

**原因**:
- Redis の maxmemory 設定を超えている
- t3.micro のメモリ 1GB が Redis の使用量に対して不足

**解決策**:
```bash
# Redis のメモリ使用量確認
redis-cli INFO memory | grep used_memory_human

# Redis 設定でメモリ上限と eviction ポリシーを設定
sudo vi /etc/redis/redis.conf
# maxmemory 512mb
# maxmemory-policy allkeys-lru

sudo systemctl restart redis
```

---

## 5. ALBヘルスチェックの失敗

### 症状 5-A: Target Group のターゲットが `unhealthy`

ALBコンソールで Target のステータスが `unhealthy` と表示される。

**原因**:
- アプリケーションが起動していない
- `/health` エンドポイントが HTTP 200 を返していない
- ヘルスチェックのパスやポートが間違っている
- セキュリティグループがALBからのトラフィックを許可していない

**解決策**:
```bash
# EC2 上でアプリケーションの動作確認
curl http://localhost:8080/health
# 期待: {"status":"ok"}  HTTP 200

# ALB のセキュリティグループからのトラフィックがEC2で許可されているか確認
aws ec2 describe-security-groups \
  --group-ids sg-EC2_SG_ID \
  --query "SecurityGroups[0].IpPermissions"

# ヘルスチェックの設定確認
aws elbv2 describe-target-health \
  --target-group-arn YOUR_TG_ARN

# ターゲットグループのヘルスチェック設定確認
aws elbv2 describe-target-groups \
  --target-group-arns YOUR_TG_ARN \
  --query "TargetGroups[0].{Path:HealthCheckPath,Port:HealthCheckPort,Interval:HealthCheckIntervalSeconds}"
```

---

### 症状 5-B: ALB が `503 Service Unavailable` を返す

```
HTTP 503 Service Temporarily Unavailable
```

**原因**:
- Target Group に登録されたターゲットがすべて `unhealthy`
- Target Group が空（ターゲットが登録されていない）

**解決策**:
```bash
# Target Group へのターゲット登録状態確認
aws elbv2 describe-target-health \
  --target-group-arn YOUR_TG_ARN \
  --query "TargetHealthDescriptions[*].{Target:Target.Id,Health:TargetHealth.State,Reason:TargetHealth.Reason}"

# ターゲットの再登録
aws elbv2 register-targets \
  --target-group-arn YOUR_TG_ARN \
  --targets Id=i-XXXXXXXXXXXXXXXXX,Port=8080
```

---

### 症状 5-C: ALB の DNS 名で接続できない

```
curl: (6) Could not resolve host: your-alb-name.ap-northeast-1.elb.amazonaws.com
```

**原因**:
- ALB がまだプロビジョニング中（`provisioning` 状態）
- DNS キャッシュが古い

**解決策**:
```bash
# ALB の状態確認
aws elbv2 describe-load-balancers \
  --names YOUR_ALB_NAME \
  --query "LoadBalancers[0].State"

# `active` になるまで待つ（数分かかる場合がある）
aws elbv2 wait load-balancer-available \
  --load-balancer-arns YOUR_ALB_ARN

# DNS 解決の確認
nslookup YOUR_ALB_DNS_NAME
dig YOUR_ALB_DNS_NAME
```

---

## 6. k6テストの失敗

### 症状 6-A: `WARN[0000] Request Failed` が多数出る

```
WARN[0001] Request Failed  error="Get \"http://...\": dial tcp: connection refused"
```

**原因**:
- ターゲットURLが間違っている
- アプリケーションが起動していない
- k6 を実行しているマシンからターゲットへの疎通ができていない

**解決策**:
```bash
# ターゲットへの疎通確認
curl http://YOUR_TARGET_URL/health

# k6 のターゲットURL確認
k6 run -e TARGET_URL=http://YOUR_EC2_IP:8080 k6/load_test.js

# k6 のバージョン確認
k6 version
```

---

### 症状 6-B: `thresholds` のチェックが失敗する

```
✗ http_req_duration.............: avg=1234ms min=100ms med=900ms max=9000ms p(90)=3000ms p(95)=5000ms
  ↳  99% — ✓ 4950 / ✗ 50
ERRO[0030] some thresholds have failed
```

**原因**:
- アプリケーションのパフォーマンスが SLO（`p(95)<500ms`）を満たしていない
- DBクエリが遅い（インデックス不足など）
- リソースが不足している（CPU、メモリ、コネクション数）

**解決策**:
```bash
# MySQL のスロークエリログを確認
sudo tail -f /var/log/mysql/slow.log

# MySQL の EXPLAIN で実行計画を確認
EXPLAIN SELECT * FROM users WHERE email = 'test@example.com';

# EC2 の CPU/メモリ使用率確認
top
vmstat 1 5

# コネクション数の確認
mysql -u root -p -e "SHOW STATUS LIKE 'Threads_connected';"
```

---

### 症状 6-C: k6 がインストールされていない

```
bash: k6: command not found
```

**解決策**:
```bash
# macOS
brew install k6

# Ubuntu/Debian
sudo gpg -k
sudo gpg --no-default-keyring \
  --keyring /usr/share/keyrings/k6-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 \
  --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6

# Docker を使う方法
docker run --rm -i grafana/k6 run - < k6/load_test.js
```

---

## 7. Goコンパイルエラー

### 症状 7-A: `cannot find package`

```
cannot find package "github.com/labstack/echo/v4" in any of:
```

**原因**:
- `go mod download` を実行していない
- `go.mod` の依存関係が不足している

**解決策**:
```bash
cd shared/echo-api  # または該当するappディレクトリ

# 依存関係のダウンロード
go mod download
go mod tidy

# ビルドの確認
go build ./...
```

---

### 症状 7-B: `go: command not found`

```
bash: go: command not found
```

**解決策**:
```bash
# Go のインストール確認
which go
go version

# Go のインストール (EC2 上)
wget https://go.dev/dl/go1.22.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.22.0.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin
echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
source ~/.bashrc
```

---

### 症状 7-C: `undefined: slog` (Goのバージョン不足)

```
./main.go:10:2: undefined: slog
```

**原因**:
- `log/slog` は Go 1.21 以降で追加されたパッケージ
- インストールされている Go のバージョンが古い

**解決策**:
```bash
go version
# Go 1.21 以上が必要

# go.mod のバージョン要件確認
cat go.mod | grep "^go "
```

---

### 症状 7-D: データベース接続でのコンパイルエラー

```
./db/db.go:5:2: no required module provides package github.com/go-sql-driver/mysql
```

**解決策**:
```bash
go get github.com/go-sql-driver/mysql
go mod tidy
```

---

## 8. Laravelセットアップの問題

### 症状 8-A: `php artisan: command not found`

**原因**:
- PHP がインストールされていない
- Laravel プロジェクトのルートディレクトリにいない

**解決策**:
```bash
# PHP のインストール確認
php -v

# Laravel プロジェクトのルートにいることを確認
ls artisan  # artisan ファイルが存在するか確認

# Laravel の依存関係インストール
composer install
```

---

### 症状 8-B: `SQLSTATE[HY000] [2002] No such file or directory`

**原因**:
- `.env` の `DB_HOST` が `127.0.0.1` でなく `localhost` になっており、
  Unix ソケット接続を試みている
- MySQL が起動していない

**解決策**:
```bash
# .env の確認と修正
cat .env | grep DB_
# DB_HOST=localhost を DB_HOST=127.0.0.1 に変更

# または .env.example からコピーして設定
cp .env.example .env
php artisan key:generate
# DB接続情報を適切に設定
```

---

### 症状 8-C: `Target class [SomeClass] does not exist`

**原因**:
- `composer dump-autoload` が実行されていない
- キャッシュが古い

**解決策**:
```bash
composer dump-autoload
php artisan config:cache
php artisan route:cache
php artisan view:cache
```

---

### 症状 8-D: マイグレーションが失敗する

```
SQLSTATE[42000]: Syntax error or access violation: 1071 Specified key was too long
```

**原因**:
- MySQL 5.7 以下で utf8mb4 を使用したときに発生
- `AppServiceProvider` でデフォルト文字列長を設定していない

**解決策**:
```php
// app/Providers/AppServiceProvider.php
use Illuminate\Support\Facades\Schema;

public function boot()
{
    Schema::defaultStringLength(191);
}
```

```bash
php artisan migrate:fresh
```

---

## 一般的なデバッグのヒント

### ログの確認方法

```bash
# Go アプリのログ (journald)
sudo journalctl -u your-app.service -f

# Nginx のログ
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/nginx/error.log

# MySQL のエラーログ
sudo tail -f /var/log/mysql/error.log

# Redis のログ
sudo tail -f /var/log/redis/redis-server.log
```

### EC2 インスタンスの基本診断

```bash
# システムリソース確認
top
free -h
df -h

# ネットワーク接続確認
ss -tlnp
netstat -tlnp

# プロセス確認
ps aux | grep -E "go|mysql|redis|nginx"
```

### ALB アクセスログの有効化

```bash
# Terraform で ALB アクセスログを有効化
resource "aws_lb" "main" {
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb"
    enabled = true
  }
}
```
