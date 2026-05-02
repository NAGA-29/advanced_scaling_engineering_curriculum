# STEP 12: 障害設計 — 壊れる前提でシステムを作る

## 目的

本番システムは必ず障害が発生する。  
障害を「例外」ではなく「前提」として設計し、  
timeout / retry / circuit breaker / fallback / degraded response の各パターンを実装して体感する。

**「落ちないシステムを作る」のではなく「落ちても大丈夫なシステムを作る」** という思想を習得する。

---

## 構成

```
Client
  │
  ▼
[Echo API :8080]
  │
  ├── context.WithTimeout ──→ タイムアウト制御 (DBが遅くても5秒で諦める)
  │
  ├── Retry (指数バックオフ) ──→ 一時的エラーは自動リトライ
  │
  ├── CircuitBreaker ──────→ 連続失敗でリクエストを遮断 (DB を守る)
  │     ├── CLOSED  (正常)
  │     ├── OPEN    (遮断中: 直近N回失敗)
  │     └── HALF-OPEN (回復テスト中)
  │
  ├── Fallback ─────────────→ DBが死んでもキャッシュから古いデータを返す
  │
  └── Degraded Response ───→ 部分的なデータと "degraded":true を返す
```

### Circuit Breaker の状態遷移

```
                  N回連続失敗
  [CLOSED] ──────────────────────→ [OPEN]
  (正常動作)                       (全リクエスト拒否)
      ↑                               │
      │  テスト成功                   │ timeout 経過
      │                               ↓
      └────────────────────── [HALF-OPEN]
                               (1リクエストだけ通す)
```

### 障害シナリオ一覧

| 障害対象    | ユーザー影響                | 検知方法                     | 復旧手順                         |
|-----------|---------------------------|-----------------------------|---------------------------------|
| MySQL 停止 | データ取得不可              | ヘルスチェック 503, エラーログ | `docker compose start mysql`    |
| MySQL 遅延 | API タイムアウト (p99 急増) | p99 アラート, slow query log | クエリ最適化, 接続プール調整       |
| Redis 停止 | キャッシュなし (直接 DB)    | cache miss rate 100%        | `docker compose start redis`    |
| EC2 停止   | そのノードへの接続失敗       | ALB ヘルスチェック失敗        | Auto Scaling が新インスタンス起動 |
| 高負荷     | レイテンシ増加, OOM         | CPU/メモリアラート            | スケールアウト, Circuit Breaker  |

---

## 成果物

```
step12_failure_design/
├── README.md
├── app/
│   ├── circuit_breaker.go     # Circuit Breaker 実装
│   └── resilient_handler.go   # 全レジリエンスパターンを示すハンドラ
├── k6/
│   └── resilience_test.js     # カオス実行中の負荷テスト
└── scripts/
    └── chaos.sh               # カオスエンジニアリングスクリプト
```

---

## 前提条件

- Go 1.22 以上
- Docker + Docker Compose (MySQL / Redis)
- k6
- `tc` コマンド (Linux Traffic Control — `iproute2` パッケージ)
- AWS CLI (EC2 停止シナリオのみ)

---

## 実行手順

### 1. 依存サービス起動

```bash
# step11 の docker-compose を流用するか、単独で起動
docker run -d --name step12-mysql \
  -e MYSQL_ROOT_PASSWORD=password \
  -e MYSQL_DATABASE=appdb \
  -p 3306:3306 mysql:8.0

docker run -d --name step12-redis \
  -p 6379:6379 redis:7-alpine
```

### 2. API サーバー起動

```bash
cd step12_failure_design/app
go mod init github.com/advanced-scaling/step12
go get github.com/labstack/echo/v4
go get github.com/go-sql-driver/mysql
go get github.com/redis/go-redis/v9
go run *.go
```

### 3. 正常動作確認

```bash
curl http://localhost:8080/users/1
# → {"id":1, "name":"...", "degraded": false}
```

### 4. カオス実行 + 負荷テスト

```bash
# ターミナル1: 負荷テスト
k6 run k6/resilience_test.js

# ターミナル2: カオス注入
bash scripts/chaos.sh db-slow     # DB を遅くする
sleep 30
bash scripts/chaos.sh db-stop     # DB を止める
sleep 30
bash scripts/chaos.sh db-start    # DB を復旧
```

---

## 確認方法

```bash
# Circuit Breaker の状態確認
curl http://localhost:8080/circuit-breaker/status

# Degraded response の確認
curl http://localhost:8080/users/1
# DB 障害中: {"id":1,"name":"cached-user","degraded":true}

# k6 で error rate と recovery time を確認
k6 run k6/resilience_test.js
```

---

## 壊す手順

### シナリオ 1: MySQL を完全停止

```bash
bash scripts/chaos.sh db-stop

# Circuit Breaker が OPEN になるまでリクエスト
for i in $(seq 1 10); do
  curl -w " HTTP:%{http_code}\n" http://localhost:8080/users/1
done
# 最初の数回は 503 (DB エラー)
# Circuit Breaker OPEN 後は fallback データが返る (200 degraded)
```

### シナリオ 2: MySQL に 500ms 遅延を追加

```bash
bash scripts/chaos.sh db-slow

# タイムアウト (5秒) より遅ければ 503
# リトライで成功することもある
curl -v http://localhost:8080/users/1
```

### シナリオ 3: Redis 停止

```bash
bash scripts/chaos.sh redis-stop

# fallback が機能するか確認
curl http://localhost:8080/users/1
# → DB から直接取得 (degraded=false の場合もある)
```

---

## 復旧手順

```bash
# MySQL 復旧
bash scripts/chaos.sh db-start

# Redis 復旧
bash scripts/chaos.sh redis-start

# tc の遅延ルール削除
bash scripts/chaos.sh tc-clean

# Circuit Breaker は timeout 後に自動的に HALF-OPEN → CLOSED に遷移
```

---

## 削除手順

```bash
pkill -f "go run"
docker rm -f step12-mysql step12-redis
rm -rf step12_failure_design/
```

---

## 学び

| パターン              | 目的                                                      | 実装箇所                |
|---------------------|----------------------------------------------------------|------------------------|
| Timeout             | 遅い依存サービスが全体をブロックするのを防ぐ                 | `context.WithTimeout`  |
| Retry               | 一時的な障害 (ネットワーク瞬断など) を自動回復               | 指数バックオフ           |
| Circuit Breaker     | 連続失敗時に依存サービスへの呼び出しを遮断し、回復を待つ       | `CircuitBreaker.Call`  |
| Fallback            | 依存サービス障害時に代替データ (キャッシュなど) を返す          | Redis キャッシュ        |
| Degraded Response   | 完全なデータが取れなくても部分的な情報を返してユーザーを助ける  | `degraded: true` フィールド |

**障害設計の鉄則**: 「この依存サービスが死んだら何を返すか」を事前に決めておく。

---

## k6 負荷テスト

### 実行コマンド

```bash
k6 run k6/resilience_test.js
```

### 目標メトリクス

| メトリクス                    | 正常時目標    | 障害中目標       | 説明                                      |
|-----------------------------|-------------|-----------------|------------------------------------------|
| `http_req_duration p50`      | < 20 ms     | < 100 ms        | Circuit Breaker が fallback を返すので速い |
| `http_req_duration p95`      | < 50 ms     | < 500 ms        | 95 パーセンタイル                          |
| `http_req_failed`            | < 0.1%      | < 5%            | CB + fallback でエラーを最小化             |
| `degraded_responses`         | 0           | > 0             | カオス中は degraded が増える               |
| `circuit_open_count`         | 0           | > 0             | CB OPEN の回数                            |
| `recovery_time`              | -           | < 30s           | 障害注入から正常復旧までの時間              |
