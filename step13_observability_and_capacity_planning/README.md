# STEP 13: 可観測性とキャパシティプランニング

## 目的

スケールを判断するために必要な「観測」を学ぶ。  
何を計測すればよいか、計測結果からどう意思決定するかを習得する。  
**「勘ではなくデータでスケールを判断する」** エンジニアになる。

---

## 構成

```
[Echo API :8080]
  │
  ├── /metrics ──────────────────→ JSON 形式のカスタムメトリクス
  │     ├── cache_hits / cache_misses
  │     ├── request_count (パス別)
  │     └── error_count
  │
  ├── /debug/pprof ──────────────→ Go の pprof (CPU/メモリプロファイル)
  │     ├── /debug/pprof/heap
  │     ├── /debug/pprof/goroutine
  │     └── /debug/pprof/profile?seconds=30
  │
  └── Request Logging Middleware
        └── method, path, status, latency, request_id を構造化ログ出力

[scripts/collect_metrics.sh]
  └── /metrics を 10 秒ごとに CSV に書き込む

[scripts/capacity_calc.sh]
  └── デバイス台数・間隔から必要なリソースを計算する
```

### キャパシティ計算例

```
デバイス台数: 5,000 台
ハートビート間隔: 60 秒に 1 回

定常 req/s = 5,000 / 60 = 83.3 req/s

ピーク倍率: 3 倍 (起動直後に集中)
ピーク req/s = 83.3 × 3 = 250 req/s

DB 接続数の見積もり:
  - 1 リクエスト = 平均 1 DB クエリ
  - DB クエリ時間: 10ms
  - 250 req/s × 0.01s = 2.5 同時接続 (定常)
  - 安全マージン 10 倍 = 25 接続 (最大プールサイズ)

キャッシュヒット率 80% の場合:
  - DB クエリ = 250 × (1 - 0.8) = 50 req/s
  - DB 接続: 50 × 0.01 = 0.5 同時接続 (余裕あり)
```

---

## 観測項目一覧

| カテゴリ        | 項目                     | 正常範囲の目安           | アラート閾値           |
|--------------|--------------------------|------------------------|----------------------|
| CPU          | 使用率                   | < 60%                  | > 80% (5分平均)       |
| Memory       | 使用率                   | < 70%                  | > 85%                |
| Disk         | 使用率                   | < 70%                  | > 85%                |
| Network      | インバウンド/アウトバウンド | 環境依存                | 帯域の 80%            |
| API          | p50 レイテンシ           | < 20ms                 | > 100ms              |
| API          | p99 レイテンシ           | < 100ms                | > 500ms              |
| API          | エラー率                 | < 0.1%                 | > 1%                 |
| DB           | 接続数                   | < 最大接続数の 50%      | > 80%                |
| DB           | スロークエリ数/分          | < 5                    | > 20                 |
| Redis        | メモリ使用率              | < 70%                  | > 85%                |
| Redis        | キャッシュヒット率          | > 80%                  | < 60%                |
| Queue        | キュー長 (pending)        | < 1,000                | > 10,000             |
| Queue        | コンシューマーラグ          | < 処理速度の 10%        | > 60 秒分             |

---

## 成果物

```
step13_observability_and_capacity_planning/
├── README.md
├── app/
│   └── metrics.go              # メトリクスエンドポイント + pprof
├── k6/
│   └── capacity_test.js        # 5000台 heartbeat シミュレーション
└── scripts/
    ├── capacity_calc.sh         # キャパシティ計算スクリプト
    └── collect_metrics.sh       # メトリクス収集スクリプト
```

---

## 前提条件

- Go 1.22 以上
- k6
- redis-cli
- MySQL クライアント (`mysql` コマンド)
- `jq` コマンド (JSON パース用)

---

## 実行手順

### 1. API サーバー起動

```bash
cd step13_observability_and_capacity_planning/app
go mod init github.com/advanced-scaling/step13
go get github.com/labstack/echo/v4
go get github.com/redis/go-redis/v9
go run metrics.go
```

### 2. キャパシティ計算

```bash
# デフォルト: 5000台, 60秒間隔, ピーク3倍
bash scripts/capacity_calc.sh

# カスタム
bash scripts/capacity_calc.sh --devices 10000 --interval-sec 30 --peak-multiplier 5
```

### 3. メトリクス収集開始

```bash
# バックグラウンドで収集開始 (10秒ごとにCSV書き込み)
bash scripts/collect_metrics.sh &

# 確認
tail -f /tmp/metrics_$(date +%Y%m%d).csv
```

### 4. k6 負荷テスト

```bash
# 5000台デバイスの heartbeat シミュレーション
k6 run k6/capacity_test.js
```

### 5. pprof でプロファイル取得

```bash
# CPU プロファイル (30秒)
go tool pprof http://localhost:8080/debug/pprof/profile?seconds=30

# ヒーププロファイル
go tool pprof http://localhost:8080/debug/pprof/heap

# goroutine 一覧
curl http://localhost:8080/debug/pprof/goroutine?debug=1
```

---

## 確認方法

```bash
# メトリクス確認
curl http://localhost:8080/metrics | jq .

# キャッシュヒット率計算
curl http://localhost:8080/metrics | jq '
  .cache_hits / (.cache_hits + .cache_misses) * 100 | 
  "Cache hit rate: \(.)%"
'

# pprof Web UI (別ターミナルで)
go tool pprof -http=:6060 http://localhost:8080/debug/pprof/heap
```

---

## 壊す手順

### キャッシュヒット率を下げる

```bash
# Redis を停止するとヒット率が 0% になる
docker stop step13-redis

# メトリクスで確認
curl http://localhost:8080/metrics | jq '.cache_hit_rate'
# → 0 (全リクエストが DB に流れる)
```

### goroutine リーク確認

```bash
# goroutine 数をベースラインで記録
curl http://localhost:8080/debug/pprof/goroutine?debug=2 | head -5

# 高負荷後に再確認
k6 run --vus 100 --duration 60s k6/capacity_test.js
curl http://localhost:8080/debug/pprof/goroutine?debug=2 | head -5
# goroutine 数が増え続ける場合はリーク
```

---

## 復旧手順

```bash
# Redis 復旧
docker start step13-redis

# メトリクスカウンターリセット (API 再起動)
pkill -f "go run" && go run app/metrics.go &
```

---

## 削除手順

```bash
pkill -f "go run"
rm -f /tmp/metrics_*.csv
rm -rf step13_observability_and_capacity_planning/
```

---

## 学び

| ポイント                  | 説明                                                                    |
|-------------------------|------------------------------------------------------------------------|
| 観測なきスケールは賭け       | 「遅い気がする」ではなく p99=500ms という数値で判断する                    |
| pprof                   | Go の標準ツール。CPU ホットスポット・メモリリーク・goroutine リークを発見できる |
| キャッシュヒット率           | 80% 以下なら DB 負荷増大のサイン。TTL 調整かデータ量見直しが必要            |
| キャパシティ計算             | 台数 ÷ 間隔 = req/s を先に計算してから設計する。後から慌てない              |
| メトリクスの基準線            | 正常時の数値を知らないとアラートの閾値が決められない。平常時から記録する       |
| CSV 収集 → グラフ化         | Grafana/Datadog がなくてもローカルで傾向を見ることができる                   |

**観測の鉄則**: 計測できないものはコントロールできない。まず計測する。

---

## k6 負荷テスト

### 実行コマンド

```bash
k6 run k6/capacity_test.js
```

### 目標メトリクス

| メトリクス                       | 目標値       | 説明                                          |
|--------------------------------|-------------|----------------------------------------------|
| `http_req_duration p50`         | < 20 ms     | heartbeat は軽い処理のはず                     |
| `http_req_duration p95`         | < 50 ms     | 95 パーセンタイル                               |
| `http_req_duration p99`         | < 100 ms    | 99 パーセンタイル                               |
| `http_req_failed`               | < 0.1%      | エラー率                                       |
| `http_reqs`                     | ~83 req/s   | 5000台 / 60秒 = 83 req/s が定常状態            |
| `cache_hit_rate`                | > 80%       | Redis キャッシュが効いているか                   |
| `steady_state_rps`              | 83.3        | 計算値と実測値が一致するか確認                   |
