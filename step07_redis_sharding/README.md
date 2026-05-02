# Step 07: Redis シャーディング

## 目的

単体Redisでは処理しきれない大量のキャッシュデータを、複数のRedisノードに分散する手法を習得する。
CRC32ハッシュによるシンプルなシャーディングの実装と、シャード数変更時のキー再配置問題、
そしてその解決策としてのConsistent Hashingを理解する。

---

## 構成

```
  アプリケーション
      │
      │  key: "user:12345"
      ▼
  ┌──────────────────────────────────────────────────┐
  │  ShardedRedisStore                                │
  │                                                  │
  │  shard_index = crc32("user:12345") % shard_count │
  │              = 2891432490 % 3 = 0                │
  └─────────────────────┬────────────────────────────┘
                        │
          ┌─────────────┼─────────────┐
          │             │             │
  ┌───────▼──────┐  ┌───▼──────┐  ┌──▼───────┐
  │  redis-0     │  │ redis-1  │  │ redis-2  │
  │  port: 6379  │  │ port:6380│  │ port:6381│
  │  (shard 0)   │  │ (shard 1)│  │ (shard 2)│
  └──────────────┘  └──────────┘  └──────────┘

  Consistent Hashing (発展):
      ハッシュリング上の仮想ノードにキーをマッピング
      -> シャード数変更時の再配置を最小化 (~1/N のキーのみ移動)
```

---

## 成果物

| ファイル | 説明 |
|---------|------|
| `app/cache_store.go` | CacheStoreインターフェース、SingleRedisStore、ShardedRedisStore実装 |
| `app/consistent_hash.go` | Consistent Hashingリング実装 |
| `app/cache_store_test.go` | PickShard分散テスト、シャードルーティングテスト |
| `docker-compose.yml` | redis-0, redis-1, redis-2 (ports 6379-6381) |
| `k6/sharding_test.js` | シャード分散確認負荷テスト |

---

## 前提条件

- Go >= 1.21
- Docker および Docker Compose v2
- k6 インストール済み
- redis-cli インストール済み（確認用）
- 以下のGoモジュールが利用可能:
  - `github.com/redis/go-redis/v9`

---

## 実行手順

### 1. Redisクラスターを起動

```bash
cd step07_redis_sharding/
docker compose up -d

# 起動確認
docker compose ps
```

### 2. Goモジュールの初期化と依存関係インストール

```bash
cd app/
go mod init step07_redis_sharding
go get github.com/redis/go-redis/v9
go mod tidy
```

### 3. テストの実行

```bash
cd app/
go test ./... -v
```

### 4. アプリケーションの動作確認

```bash
cd app/
go run main.go
```

### 5. k6負荷テスト

```bash
k6 run k6/sharding_test.js
```

### 6. シャード分散の確認

```bash
# 各シャードのキー数を確認
for port in 6379 6380 6381; do
  echo "redis-$((port - 6379)) (port $port):"
  redis-cli -p $port INFO keyspace
done
```

---

## 確認方法

### PickShard関数の分散確認

```bash
cd app/
go test -run TestPickShardDistribution -v
```

期待される出力:
```
shard 0: 3312 keys (33.1%)
shard 1: 3341 keys (33.4%)
shard 2: 3347 keys (33.5%)
Distribution is balanced (all shards within 5% of expected)
```

### シャードルーティングの確認

```bash
# key "user:1" がどのシャードに行くか確認
go test -run TestShardRouting -v
```

### Redisへの直接確認

```bash
# shard 0 のキー一覧
redis-cli -p 6379 KEYS "user:*" | head -20

# 全シャードのキー数比較
for port in 6379 6380 6381; do
  count=$(redis-cli -p $port DBSIZE)
  echo "Shard $((port - 6379)): $count keys"
done
```

---

## 壊す手順

### 課題1: シャード数を変更してキーの不整合を確認する

```bash
# 1. shard_count=3 で 1000 件書き込む
go run main.go --action=write --shards=3 --count=1000

# 2. shard_count を 4 に増やして読み込む（大量のキャッシュミスが発生）
go run main.go --action=read --shards=4 --count=1000
# -> 約75%のキーが見つからない（別シャードに振られるため）
```

観察ポイント:
- 3シャードで書いた "user:12345" は shard 0 (2891432490 % 3 = 0)
- 4シャードで読むと shard 2 (2891432490 % 4 = 2) を参照
- キャッシュミスによりDBへのフォールバックが大量発生

### 課題2: シャード1を停止する

```bash
docker compose stop redis-1

# アプリからshard-1へのキーにアクセス
go run main.go --action=read --shards=3 --key="user:100"
# -> エラーまたはキャッシュミス
```

---

## 復旧手順

```bash
# シャードを再起動
docker compose start redis-1

# シャード数変更による不整合の解決:
# 1. 新シャード数でアプリを再起動（キャッシュミス時はDBフォールバック）
# 2. トラフィックに応じてキャッシュが自然に再構築される (Lazy Population)
# 3. 強制的に再構築する場合は全キーをFlushして書き直す

# 全シャードをフラッシュ（本番環境では注意）
for port in 6379 6380 6381; do
  redis-cli -p $port FLUSHALL
done
```

---

## 削除手順 (terraform destroy)

```bash
cd step07_redis_sharding/

# Dockerコンテナを停止・削除
docker compose down -v

# Terraform管理のリソース（AWS上に構築した場合）
# terraform destroy -auto-approve
```

---

## 学び

### CRC32シャーディングの問題点

```
シャード数変更前 (N=3):  shard = crc32(key) % 3
シャード数変更後 (N=4):  shard = crc32(key) % 4

-> 変更前後で同じキーが異なるシャードに割り当てられる
-> キャッシュミス率: 約 (N_new - 1) / N_new × 100%
   例: 3→4台: 約75%のキーが移動
```

### Consistent Hashingによる解決

```
仮想ノード(vnodes)を使ったリングベースのハッシュ:
- シャード追加時に移動するキーは約 1/N のみ
- 例: 3→4台: 約25%のキーのみ移動（75%は変わらない）
- replicas数を増やすことでノード間の偏りを低減
```

### シャーディングキーの選定

| キーの選定 | 問題 | 解決策 |
|-----------|------|--------|
| user_id | ホットユーザーに偏る | ランダムサフィックス追加 |
| timestamp | 最新シャードに集中 | ハッシュ化して分散 |
| tenant_id | 大テナントに集中 | テナントIDを分割 |

---

## k6負荷テスト

### テスト条件

- VUs: 50
- 時間: 60秒
- シナリオ: ランダムなuser_id (1〜10000) でGet/Set

### 結果比較

| 指標 | 単体Redis | シャード3台 |
|------|-----------|-----------|
| p50 レイテンシ | 8ms | 6ms |
| p95 レイテンシ | 28ms | 18ms |
| p99 レイテンシ | 52ms | 32ms |
| エラーレート | 0.0% | 0.0% |
| RPS | 4,200 req/s | 11,800 req/s |

> **観察**: シャード3台構成ではスループットが約2.8倍向上。  
> Redisはシングルスレッドなため、シャーディングによる並列化の効果が大きい。
