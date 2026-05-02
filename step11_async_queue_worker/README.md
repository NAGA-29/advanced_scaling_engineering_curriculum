# STEP 11: 非同期キューワーカー — Redis Stream で同期処理を非同期化

## 目的

同期処理を非同期化することで、API の応答速度を上げ、バックエンド障害への耐障害性を高める技術を習得する。

Redis Stream を使ったプロデューサー・コンシューマーパターンを実装し、  
冪等性 (Idempotency) の重要性を理解する。  
**「API は受け付けるだけ、実際の処理はワーカーに任せる」** という設計を体感する。

---

## 構成

### 同期処理 (改善前)

```
Client
  │
  ▼
[Echo API :8080]
  │  POST /events
  ▼
[MySQL]  ← ここが遅いと API が遅くなる
  │      ← MySQL が落ちると API も 500 エラー
  ▼
レスポンス (200 OK) — DB 書き込み完了まで待つ (100-500ms)
```

### 非同期処理 (改善後)

```
Client
  │
  ▼
[Echo API :8080]
  │  POST /events  → 202 Accepted を即座に返す (< 5ms)
  ▼
[Redis Stream "events"]  ← キューにためる
  │
  ▼
[Worker]  ← 独立プロセスが非同期で処理
  │  Consumer Group "workers"
  ▼
[MySQL]   ← DB 障害があってもリトライ可能
```

### コンポーネント構成

```
step11_async_queue_worker/
  app/
    queue/
      redis_stream.go   ← Queue インターフェース + Redis実装
    worker/
      main.go           ← ワーカープロセス (XREADGROUP + XACK)
    api/
      events_handler.go ← Echo ハンドラ (XADD のみ)
  docker-compose.yml    ← MySQL + Redis
  k6/
    async_test.js       ← 非同期 API 負荷テスト
  scripts/
    monitor_queue.sh    ← キュー深さ監視スクリプト
```

| コンポーネント    | 役割                                        |
|----------------|---------------------------------------------|
| Echo API        | イベント受付 → Redis Stream へ Publish のみ   |
| Redis Stream    | 永続キュー (XADD/XREADGROUP/XACK)            |
| Worker          | Stream を Subscribe → DB 書き込み             |
| MySQL           | イベント永続化先                              |

---

## 成果物

```
step11_async_queue_worker/
├── README.md
├── docker-compose.yml
├── app/
│   ├── queue/
│   │   └── redis_stream.go      # Queue インターフェース + Redis Stream 実装
│   ├── worker/
│   │   └── main.go              # ワーカープロセス本体
│   └── api/
│       └── events_handler.go    # Echo ハンドラ (POST /events)
├── k6/
│   └── async_test.js            # 非同期 API 負荷テスト
└── scripts/
    └── monitor_queue.sh         # キュー深さ・Consumer Lag 監視
```

---

## 前提条件

- Go 1.22 以上
- Docker + Docker Compose
- k6 がインストールされていること
- redis-cli がインストールされていること

---

## 実行手順

### 1. MySQL + Redis 起動

```bash
cd step11_async_queue_worker
docker compose up -d
# 起動確認
docker compose ps
```

### 2. Redis Stream Consumer Group 作成

```bash
# "events" ストリームと "workers" グループを作成
redis-cli XGROUP CREATE events workers $ MKSTREAM
# 確認
redis-cli XINFO GROUPS events
```

### 3. Worker 起動

```bash
cd app/worker
go mod init github.com/advanced-scaling/step11-worker
go get github.com/redis/go-redis/v9
go get github.com/go-sql-driver/mysql
go run main.go
```

### 4. API サーバー起動

```bash
cd app/api
go mod init github.com/advanced-scaling/step11-api
go get github.com/labstack/echo/v4
go get github.com/redis/go-redis/v9
go run events_handler.go
```

### 5. イベント送信テスト

```bash
# 単発テスト
curl -X POST http://localhost:8080/events \
  -H "Content-Type: application/json" \
  -d '{"device_id":"device-001","event_type":"heartbeat","payload":"{\"battery\":85}"}'
# → 202 Accepted が即座に返る

# キューに溜まっているか確認
redis-cli XLEN events
```

---

## 確認方法

### キュー深さとコンシューマーラグの確認

```bash
# キュー深さ
redis-cli XLEN events

# 未処理 (pending) メッセージ数
redis-cli XPENDING events workers - + 10

# コンシューマー情報
redis-cli XINFO CONSUMERS events workers

# 監視スクリプト実行 (10秒間隔で表示)
bash scripts/monitor_queue.sh
```

### DB への書き込み確認

```bash
docker exec -it step11-mysql mysql -uroot -ppassword appdb \
  -e "SELECT id, device_id, event_type, created_at FROM events ORDER BY created_at DESC LIMIT 10;"
```

### k6 負荷テスト

```bash
k6 run k6/async_test.js
# 202 Accepted がほぼ瞬時に返ることを確認
```

---

## 壊す手順

### シナリオ 1: Worker を停止してキューに積む

```bash
# Worker を停止
pkill -f "go run main.go"

# API にリクエストを送り続ける (キューに積まれる)
for i in $(seq 1 50); do
  curl -s -X POST http://localhost:8080/events \
    -H "Content-Type: application/json" \
    -d "{\"device_id\":\"device-${i}\",\"event_type\":\"test\"}" &
done
wait

# キューが積まれていることを確認
redis-cli XLEN events
# → 50 以上の数が表示される (API は全て 202 で返った)

# Worker を再起動すると未処理イベントが一気に処理される
go run app/worker/main.go
redis-cli XLEN events
# → 減っていく
```

### シナリオ 2: MySQL を停止して耐障害性を確認

```bash
# MySQL を停止
docker compose stop mysql

# API にリクエスト送信 → 202 Accepted が返る (API は死なない)
curl -X POST http://localhost:8080/events \
  -d '{"device_id":"test","event_type":"heartbeat"}'

# Worker は DB エラーでリトライ (最大3回)
# キューに pending メッセージが溜まる
redis-cli XPENDING events workers - + 10

# MySQL 復旧後に自動的に処理される
docker compose start mysql
```

### シナリオ 3: 同じイベント ID を2回送信 (冪等性テスト)

```bash
# 同じ event_id を持つリクエストを2回送信
EVENT_ID="idempotent-test-$(date +%s)"
curl -X POST http://localhost:8080/events \
  -H "X-Idempotency-Key: ${EVENT_ID}" \
  -d '{"device_id":"device-001","event_type":"heartbeat"}'

curl -X POST http://localhost:8080/events \
  -H "X-Idempotency-Key: ${EVENT_ID}" \
  -d '{"device_id":"device-001","event_type":"heartbeat"}'

# DB に1件しか入っていないことを確認 (冪等性が機能している)
docker exec step11-mysql mysql -uroot -ppassword appdb \
  -e "SELECT COUNT(*) FROM events WHERE idempotency_key = '${EVENT_ID}';"
# → 1
```

---

## 復旧手順

### Worker 復旧

```bash
cd app/worker && go run main.go &
# Pending メッセージの再処理を確認
redis-cli XPENDING events workers - + 10
```

### MySQL 復旧

```bash
docker compose start mysql
# Worker が自動的にリトライして積み残しを処理する
```

### Redis 復旧 (Stream データ消失時)

```bash
docker compose start redis
# Consumer Group が消えている場合は再作成
redis-cli XGROUP CREATE events workers $ MKSTREAM
```

---

## 削除手順

```bash
# プロセス停止
pkill -f "go run"

# Docker コンテナ削除
docker compose down -v

# ファイル削除
rm -rf step11_async_queue_worker/
```

---

## 学び

| ポイント               | 説明                                                                |
|-----------------------|---------------------------------------------------------------------|
| 非同期化の効果          | API は受け付けるだけなので p99 レイテンシが劇的に改善 (500ms → 5ms) |
| Redis Stream          | XADD でパブリッシュ、XREADGROUP で排他的消費、XACK で完了確認        |
| Consumer Group        | 複数 Worker で同じストリームを分担処理、スケールアウト対応            |
| 冪等性 (Idempotency)   | 同じメッセージが2回処理されてもDBの状態が変わらない設計              |
| 耐障害性               | API は DB 障害に無関係。Worker がリトライするため失われない           |
| Pending メッセージ     | ACK されていないメッセージは XPENDING で確認可能、再処理できる        |
| Graceful Shutdown     | SIGINT で処理中のメッセージを完了してから終了する                    |

**非同期化の鉄則**: 「受け付ける速度」と「処理する速度」を分離することで、片方の遅延が全体に波及しない。

---

## k6 負荷テスト

### 実行コマンド

```bash
k6 run k6/async_test.js
```

### 目標メトリクス

| メトリクス                   | 目標値      | 説明                                    |
|-----------------------------|------------|----------------------------------------|
| `http_req_duration p50`      | < 5 ms     | 非同期なので超高速であるべき              |
| `http_req_duration p95`      | < 20 ms    | 95 パーセンタイル                        |
| `http_req_duration p99`      | < 50 ms    | 99 パーセンタイル                        |
| `http_req_failed`            | < 0.1%     | 202 以外はエラーとしてカウント            |
| `http_reqs`                  | > 500 rps  | スループット (同期 DB 書き込みより大幅向上) |
| `accepted_events`            | 全リクエスト | カスタム: 202 Accepted を受けた数         |
| `queue_depth_at_peak`        | 記録        | カスタム: ピーク時のキュー深さ            |

### 期待される結果

- API は DB 書き込みを待たないため、p99 が同期処理の約 1/100 になる
- Worker が追いつかない場合はキューに積まれ、API は影響を受けない
- MySQL 停止中も API は 202 を返し続ける (Worker だけが詰まる)
