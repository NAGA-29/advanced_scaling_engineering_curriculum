# STEP 14: 最終ボス — 実務に近い移行演習

## 目的

ステップ 1〜13 で学んだすべての技術を組み合わせ、  
「Laravel モノリス → スケーラブルなマイクロサービス構成」への移行を  
実際に手を動かして完走する。

本番移行に近い判断と作業を体験し、**自分で移行できる自信**を身につける。

---

## 構成変化

### 初期状態

```
Internet
  │
  ▼
[Laravel :8000]
  │
  └── [MySQL Single]
```

### 最終状態

```
Internet
  │
  ▼
[Route53] ← Blue/Green DNS 切り替え
  │
  ▼
[ALB / Nginx :80]
  │  パスベースルーティング (Strangler Fig)
  ├── /heartbeat, /events → [Echo :8080]
  └── /api/legacy/*       → [Laravel :8000]
         │
         ├── [Redis] ← Cache Aside
         │
         ├── [MySQL Shard0] ← user_id % 2 == 0
         └── [MySQL Shard1] ← user_id % 2 == 1
                     │
              [Queue Worker] ← Redis Stream
```

| コンポーネント     | 初期状態          | 最終状態                              |
|----------------|-----------------|--------------------------------------|
| フロントエンド     | 直接接続          | ALB / Nginx (Blue/Green 対応)         |
| API            | Laravel のみ     | Laravel + Echo (Strangler Fig)        |
| キャッシュ        | なし             | Redis (Cache Aside)                   |
| DB             | MySQL Single     | MySQL Shard0 + Shard1                 |
| 非同期処理       | なし (同期)       | Redis Stream + Worker                 |
| DNS            | 単一 A レコード    | Route53 加重ルーティング (Blue/Green)  |

---

## 成果物

```
step14_final_boss_migration_drill/
├── README.md                     # このファイル
├── report.md                     # 学習者が記入する最終レポートテンプレート
├── k6/
│   └── final_test.js             # 全エンドポイント網羅テスト
└── scripts/
    └── mission_checklist.sh      # 11ミッション チェックリスト
```

---

## 前提条件

- STEP 01〜13 の内容を理解していること
- Go 1.22 以上
- PHP + Composer (Laravel)
- Docker + Docker Compose
- k6
- AWS CLI (Route53/EC2 ミッション用)
- redis-cli, mysql クライアント

---

## 実行手順

```bash
# 1. 全サービス起動確認
docker ps  # MySQL, Redis が起動しているか確認

# 2. ミッションチェックリスト実行
bash scripts/mission_checklist.sh

# 3. k6 最終テスト実行
k6 run k6/final_test.js

# 4. report.md を記入して演習完了
```

---

## 11のミッション

### MISSION 01: 初期状態の確認と計測

```bash
# Laravel 単体の状態で k6 ベースライン計測
k6 run --vus 10 --duration 60s k6/final_test.js

# 結果を report.md の「初期(Laravel only)」行に記入
```

**完了条件**: ベースラインの p50 / p95 / p99 / error% / rps を記録済み

---

### MISSION 02: Redis キャッシュ追加

```bash
# Redis 起動
docker run -d --name redis -p 6379:6379 redis:7-alpine

# Laravel に Cache Aside を実装 (STEP 04 参照)
# または Echo API で Redis キャッシュを有効化

# キャッシュ効果を計測
k6 run k6/final_test.js

# キャッシュヒット率を確認
redis-cli INFO stats | grep keyspace_hits
```

**完了条件**: キャッシュヒット率 > 70%、p99 が改善

---

### MISSION 03: Strangler Fig — Echo 追加

```bash
# Echo API 起動 (STEP 10 参照)
cd step10_strangler_laravel_to_echo/app
go run *.go &

# Nginx 設定でパスベースルーティング
sudo cp step10_strangler_laravel_to_echo/nginx/nginx.conf /etc/nginx/nginx.conf
sudo nginx -t && sudo systemctl reload nginx

# ルーティング確認
bash step10_strangler_laravel_to_echo/scripts/verify_routing.sh
```

**完了条件**: `/heartbeat` が Echo で処理されている (X-Handled-By: echo)

---

### MISSION 04: 非同期キューワーカー追加

```bash
# Redis Stream Consumer Group 作成
redis-cli XGROUP CREATE events workers $ MKSTREAM

# Worker 起動 (STEP 11 参照)
cd step11_async_queue_worker/app/worker
go run main.go &

# POST /events が 202 Accepted で返ることを確認
curl -X POST http://localhost:8080/events \
  -d '{"device_id":"device-001","event_type":"heartbeat"}'
# → 202 Accepted (即座)
```

**完了条件**: POST /events が < 10ms で 202 を返す

---

### MISSION 05: MySQL Read Replica 追加

```bash
# STEP 03 参照: Read Replica の設定
# 書き込み → Primary, 読み取り → Replica

# Laravel で DB_READ_HOST を設定
# または Echo で Read Replica に切り替え
```

**完了条件**: SELECT クエリが Replica に流れている (SHOW PROCESSLIST で確認)

---

### MISSION 06: DB Sharding

```bash
# STEP 08 参照: DB Sharding Resolver の実装
# user_id % 2 で Shard0 / Shard1 に振り分け

# Shard0 用 MySQL 起動
docker run -d --name mysql-shard0 -p 3307:3306 \
  -e MYSQL_ROOT_PASSWORD=password mysql:8.0

# Shard1 用 MySQL 起動
docker run -d --name mysql-shard1 -p 3308:3306 \
  -e MYSQL_ROOT_PASSWORD=password mysql:8.0

# シャードリゾルバーのテスト
curl http://localhost:8080/users/1  # → Shard0 (1 % 2 = 1 → Shard1)
curl http://localhost:8080/users/2  # → Shard0 (2 % 2 = 0 → Shard0)
```

**完了条件**: user_id の偶奇でシャードが切り替わっている

---

### MISSION 07: Circuit Breaker 有効化

```bash
# STEP 12 参照: circuit_breaker.go を組み込み

# テスト: DB を停止して Circuit Breaker の動作確認
bash step12_failure_design/scripts/chaos.sh db-stop

curl http://localhost:8080/circuit-breaker/status
# → state: OPEN

# fallback データが返ることを確認
curl http://localhost:8080/users/1
# → {"degraded": true}
```

**完了条件**: DB 停止後 Circuit Breaker が OPEN になり、fallback を返す

---

### MISSION 08: Blue/Green デプロイ準備

```bash
# STEP 06 参照: DNS Switch Blue/Green
# Blue: 現行環境, Green: 新環境

# Green 環境に全変更を適用した後
# Route53 (または /etc/hosts) で切り替え

# 段階的切り替え: 10% → 50% → 100%
# (加重ルーティング)
```

**完了条件**: Blue/Green の切り替えスクリプトが動作する

---

### MISSION 09: ゼロダウンタイムスキーママイグレーション

```bash
# STEP 09 参照: Zero Downtime Migration
# Expand → Migrate → Contract の 3 フェーズ

# フェーズ1 (Expand): 新カラムを nullable で追加
ALTER TABLE users ADD COLUMN email_verified TINYINT(1) DEFAULT 0;

# フェーズ2: データ移行 (バックグラウンド)
# フェーズ3 (Contract): 旧カラムを削除
```

**完了条件**: マイグレーション中も API がダウンタイムなしで動作

---

### MISSION 10: 観測とキャパシティ確認

```bash
# STEP 13 参照: capacity_calc.sh で現在の構成を評価

bash step13_observability_and_capacity_planning/scripts/capacity_calc.sh \
  --devices 5000 --interval-sec 60 --peak-multiplier 3

# メトリクス収集
bash step13_observability_and_capacity_planning/scripts/collect_metrics.sh &

# pprof で bottleneck 確認
go tool pprof http://localhost:8080/debug/pprof/heap
```

**完了条件**: キャパシティ計算結果を report.md に記録済み

---

### MISSION 11: 最終 k6 テストと比較

```bash
# 最終構成で k6 実行
k6 run k6/final_test.js

# 結果を report.md の「最終構成」行に記入
# 初期状態と比較して改善量を定量化する
```

**完了条件**: report.md の k6 結果比較表が全行埋まっている

---

## 確認方法

```bash
# ミッションチェックリスト実行
bash scripts/mission_checklist.sh

# 全エンドポイントの疎通確認
bash scripts/mission_checklist.sh --verify-all
```

---

## 壊す手順 (最終確認として全障害シナリオを実行)

```bash
# 1. Redis 停止 → fallback 動作確認
bash step12_failure_design/scripts/chaos.sh redis-stop
k6 run --vus 10 --duration 30s k6/final_test.js
bash step12_failure_design/scripts/chaos.sh redis-start

# 2. MySQL 停止 → Circuit Breaker 動作確認
bash step12_failure_design/scripts/chaos.sh db-stop
k6 run --vus 10 --duration 30s k6/final_test.js
bash step12_failure_design/scripts/chaos.sh db-start

# 3. Worker 停止 → キューに積まれることを確認
pkill -f "go run main.go"
# 50件送信
for i in $(seq 1 50); do
  curl -s -X POST http://localhost:8080/events -d '{"device_id":"d1","event_type":"test"}'
done
redis-cli XLEN events  # → 50以上
go run step11_async_queue_worker/app/worker/main.go &  # Worker 再起動
```

---

## 復旧手順

```bash
# 全サービス一括復旧
bash step12_failure_design/scripts/chaos.sh redis-start
bash step12_failure_design/scripts/chaos.sh db-start
bash step12_failure_design/scripts/chaos.sh tc-clean

# Worker 再起動
cd step11_async_queue_worker/app/worker && go run main.go &
```

---

## 削除手順

```bash
# 全プロセス停止
pkill -f "go run"
pkill -f "php artisan"

# Docker コンテナ削除
docker rm -f redis mysql-shard0 mysql-shard1 step12-mysql step12-redis

# Nginx をデフォルト設定に戻す
sudo cp /etc/nginx/nginx.conf.bak /etc/nginx/nginx.conf
sudo systemctl reload nginx

# ファイル削除
rm -rf step14_final_boss_migration_drill/
```

---

## 最終レポート要件

`report.md` に以下を記入して提出する:

1. 移行手順サマリ表 (11ミッション × 所要時間 / 問題点)
2. 発生した障害とその対応
3. k6 結果比較表 (初期 vs Redis追加後 vs 最終)
4. コスト見積もり (月額)
5. 「本番ならどうするか」 自由記述
6. 学んだこと

---

## 学び

| ポイント                  | 説明                                                           |
|-------------------------|----------------------------------------------------------------|
| 移行は段階的に              | 一気に変えず、1つずつ変えて効果を確認する                          |
| 計測なき移行は失敗する        | 各ステップで k6 を実行し、改善量を数値で確認する                    |
| 障害は設計に組み込む          | 「壊れる前提」で作ると、壊れても大丈夫なシステムになる               |
| ロールバックを先に考える       | 移行前に「戻し方」を決めておく。Nginx 設定を戻すだけで良い設計に     |
| チームで共有できる手順書       | 自分だけが知っている移行手順は「バス係数1」のリスク                 |

**最終ボスの鉄則**: 全体を一度に変えようとしない。「今日はここだけ」を積み重ねる。

---

## k6 負荷テスト

### 実行コマンド

```bash
k6 run k6/final_test.js
```

### 目標メトリクス

| メトリクス                       | 初期 (Laravel) | 最終構成目標   | 説明                           |
|--------------------------------|--------------|-------------|-------------------------------|
| `http_req_duration p50`         | ~50 ms       | < 10 ms     | Redis キャッシュで大幅改善        |
| `http_req_duration p95`         | ~150 ms      | < 30 ms     | 95 パーセンタイル                |
| `http_req_duration p99`         | ~300 ms      | < 100 ms    | 99 パーセンタイル                |
| `http_req_failed`               | < 1%         | < 0.1%      | エラー率                        |
| `http_reqs`                     | ~200 rps     | > 1000 rps  | スループット                     |
| `post_events_latency p99`       | ~500 ms      | < 10 ms     | 非同期化で劇的改善               |
