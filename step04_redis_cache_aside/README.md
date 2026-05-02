# STEP 04: Redis Cache-Aside パターンで DB の読み負荷を削る

## 目的

Redis を使った Cache-Aside パターンを実装し、MySQL への読み込みリクエストを大幅に削減する。  
DB が返すのと同じデータを Redis にキャッシュすることで、レイテンシを下げつつ  
DB の CPU とコネクション数を節約する。

- Cache-Aside（キャッシュを自分でセットして自分で無効化するパターン）を Go で実装する
- キャッシュヒット率を計測し、DB 負荷との相関を観測する
- TTL 設計（短 TTL vs 長 TTL のトレードオフ）を学ぶ
- Redis が停止した場合に DB へ Fallback する設計を実装する

---

## Cache-Aside パターンとは

```
Read:                              Write:
  1. Redis からキャッシュを取得         1. DB に書き込む
  2. ヒット → そのまま返す             2. Redis のキャッシュを削除 (InvalidateUser)
  3. ミス  → DB から取得               ※ DB 書き込み後に Redis を更新するのではなく
           → Redis にキャッシュ保存         削除することで、stale data の残存を防ぐ
           → クライアントに返す
```

**Cache-Aside の特徴**:
- アプリがキャッシュの生存・失効を制御する（自動更新ではない）
- DB と Redis の間のデータ整合性を明示的に管理する必要がある
- Redis が落ちていても DB へ Fallback できるため可用性が高い

---

## 構成

```
[クライアント / k6]
        │
        ▼
[Go/Echo API]
   │           │
   │ Cache Hit │ Cache Miss
   ▼           ▼
[Redis]     [MySQL]
  TTL=300s     ↓
              キャッシュに保存
              ↓
           [Redis]（次回以降 Hit）
```

| リソース | 値 |
|---------|-----|
| Redis | 7.x, Docker または ElastiCache |
| キャッシュキー | `user:{id}`, `tenant:{tenant_id}:users` |
| TTL | 300 秒（デフォルト） |
| MySQL | 8.0, 読み込みを Fallback 先として使用 |

---

## 成果物

```
step04_redis_cache_aside/
├── README.md
├── app/
│   └── cache_aside.go       # Cache-Aside パターン実装
├── docker-compose.yml       # MySQL + Redis ローカル環境
└── k6/
    └── cache_test.js        # キャッシュヒット率・比較テスト
```

---

## 前提条件

### ローカル Docker 検証の場合

```bash
docker --version         # 20.x 以上
docker compose version   # v2.x 以上
```

### AWS 環境の場合

- STEP 00 の EC2 が起動していること
- ElastiCache Redis または EC2 上の Redis が起動していること
- EC2 → Redis のポート 6379 が Security Group で許可されていること

---

## 実行手順

### ローカル Docker での検証手順

#### 1. Docker Compose で環境を起動

```bash
cd step04_redis_cache_aside
docker compose up -d

# 起動確認
docker compose ps
# mysql と redis が running であること
```

#### 2. Redis の接続確認

```bash
docker exec -it redis redis-cli ping
# PONG が返ること

docker exec -it redis redis-cli info server | grep redis_version
```

#### 3. MySQL にデータを投入

```bash
# STEP 01 の setup.sql を実行（データが未投入の場合）
docker exec -i mysql mysql -u apiuser -papipassword appdb < ../step01_single_node_limit/mysql/setup.sql
```

#### 4. Go アプリのビルドと起動

```bash
cd app
go mod init step04-cache-aside
go get github.com/go-sql-driver/mysql@v1.8.1
go get github.com/redis/go-redis/v9@v9.5.1
go build -o cache_demo .

# アプリを起動
DB_HOST=127.0.0.1 DB_PORT=3306 \
DB_USER=apiuser DB_PASSWORD=apipassword DB_NAME=appdb \
REDIS_ADDR=127.0.0.1:6379 \
./cache_demo
```

#### 5. キャッシュの動作確認

```bash
# 1 回目: キャッシュミス（DB から取得）
curl -s http://localhost:8080/users/1
# レスポンスヘッダーに X-Cache: MISS が返ること

# 2 回目: キャッシュヒット（Redis から取得）
curl -s http://localhost:8080/users/1
# レスポンスヘッダーに X-Cache: HIT が返ること

# Redis でキャッシュキーを確認
docker exec redis redis-cli keys "user:*" | head -20
docker exec redis redis-cli ttl user:1
```

#### 6. k6 でキャッシュウォームアップ + 負荷テスト

```bash
cd step04_redis_cache_aside
k6 run k6/cache_test.js
```

---

## 確認方法

### キャッシュヒット率の確認

```bash
# Redis 統計情報
docker exec redis redis-cli info stats | grep -E "keyspace_hits|keyspace_misses"

# ヒット率の計算
# Hit Rate = keyspace_hits / (keyspace_hits + keyspace_misses) * 100
```

### Redis のメモリ使用量確認

```bash
docker exec redis redis-cli info memory | grep -E "used_memory_human|maxmemory_human"

# すべてのキーを確認
docker exec redis redis-cli keys "*" | wc -l

# 特定キーの TTL 確認
docker exec redis redis-cli ttl "user:42"
# -1: TTL なし（永続化）
# -2: キーが存在しない
# 正の整数: 残り秒数
```

### DB との比較（キャッシュなし vs あり）

```bash
# キャッシュをフラッシュしてから計測（キャッシュなしの状態）
docker exec redis redis-cli flushall
k6 run --vus 50 --duration 30s k6/cache_test.js

# キャッシュをウォームアップしてから計測
k6 run k6/cache_test.js
```

---

## キー設計

| パターン | キー例 | TTL | 用途 |
|---------|--------|-----|------|
| ユーザー | `user:{id}` | 300s | ユーザー情報の単一取得 |
| テナント別デバイス | `tenant:{tenant_id}:devices` | 60s | デバイス一覧（更新頻度高め） |
| ハートビート | `heartbeat:{device_id}` | 30s | デバイスの最終アクティブ時刻 |
| テナントユーザー | `tenant:{tenant_id}:users` | 120s | テナント別ユーザー一覧 |

**TTL 設計のポイント**:
- データの更新頻度が高いものは短 TTL
- 読み取り専用・静的なデータは長 TTL
- TTL が 0（永続）は避ける → Redis が OOM になった時に eviction が起きると予測不可能な挙動になる

---

## 壊す手順

### 課題 1: Redis を停止して Fallback を確認する

```bash
# Redis を停止
docker compose stop redis

# アプリが DB に Fallback することを確認
curl -s http://localhost:8080/users/1
# X-Cache: MISS（Redis が落ちているので毎回 DB から取得）
# エラーにならないことを確認

# k6 で負荷テスト（エラーレートが 0% を維持することを確認）
k6 run --vus 50 --duration 30s k6/cache_test.js
```

**期待される変化**:
- `X-Cache: MISS` が続く
- レイテンシが上昇（DB からの取得に戻るため）
- エラーレートは 0% を維持（Fallback 成功）
- アプリログに `[WARN] Redis unavailable, falling back to DB` が出力される

### 課題 2: キャッシュポイズニング（stale data の観察）

```bash
# 1. ユーザーをキャッシュ
curl -s http://localhost:8080/users/1

# 2. DB を直接更新（アプリを通さずにキャッシュを無効化しない）
docker exec mysql mysql -u apiuser -papipassword appdb \
  -e "UPDATE users SET name = 'POISONED' WHERE id = 1;"

# 3. キャッシュからは古いデータが返ることを確認（TTL 切れまで）
curl -s http://localhost:8080/users/1
# name がまだ 'POISONED' になっていないこと → stale data

# 4. キャッシュを手動削除して最新データを取得
docker exec redis redis-cli del "user:1"
curl -s http://localhost:8080/users/1
# name が 'POISONED' に更新されていること
```

### 課題 3: Redis に過剰なデータをキャッシュして OOM を観察する

```bash
# maxmemory を 1MB に制限
docker exec redis redis-cli config set maxmemory 1mb
docker exec redis redis-cli config set maxmemory-policy allkeys-lru

# 大量のキーを生成
k6 run --vus 100 --duration 60s k6/cache_test.js

# eviction 統計を確認
docker exec redis redis-cli info stats | grep evicted_keys
```

---

## 復旧手順

### Redis を再起動する

```bash
docker compose start redis

# 接続確認
docker exec redis redis-cli ping
# PONG

# キャッシュは空になっているので、しばらく使うと自動的にウォームアップされる
# または k6 でウォームアップ
k6 run --vus 10 --duration 30s k6/cache_test.js
```

### stale data を強制的にクリアする

```bash
# 特定キーの削除
docker exec redis redis-cli del "user:1"

# パターンマッチで一括削除（本番環境では注意して使う）
docker exec redis redis-cli keys "user:*" | xargs docker exec -i redis redis-cli del

# 全キャッシュクリア（開発環境のみ）
docker exec redis redis-cli flushall
```

### maxmemory を元に戻す

```bash
docker exec redis redis-cli config set maxmemory 0
docker exec redis redis-cli config set maxmemory-policy noeviction
```

---

## 削除手順

### Docker 環境の削除

```bash
cd step04_redis_cache_aside

# コンテナとボリュームを削除
docker compose down -v

# イメージも削除する場合
docker compose down -v --rmi all

# 確認
docker ps -a | grep -E "mysql|redis"
docker volume ls | grep step04
```

### AWS ElastiCache の削除（使用した場合）

```bash
# クラスターの削除
aws elasticache delete-replication-group \
  --replication-group-id scaling-step04-redis \
  --no-retain-primary-cluster

# 削除完了を待つ
aws elasticache wait replication-group-deleted \
  --replication-group-id scaling-step04-redis
```

---

## 学び

| 項目 | 学んだこと |
|------|-----------|
| Cache-Aside の責務 | アプリが「読む→キャッシュがなければDBから→キャッシュに保存→返す」という責務を持つ |
| Write-Through との違い | Write-Through は書き込み時に同時にキャッシュを更新するが、一貫性は高く書き込みは遅くなる |
| TTL の重要性 | TTL なしは Redis OOM や stale data の原因。用途に応じた TTL 設計が必要 |
| キャッシュ無効化 | 更新時はキャッシュを削除する（更新するのではなく）。これにより stale data の残存を最小化 |
| Fallback 設計 | Redis が落ちても DB から返せるように実装する。Redis を永続 DB として使わないこと |
| ヒット率の監視 | ヒット率が低い場合は TTL が短すぎるかキーが分散しすぎている可能性がある |
| Hot Key 問題 | 特定のキーへのアクセスが集中すると Redis の単一スレッドがボトルネックになる |

---

## k6 負荷テスト

### 実行コマンド

```bash
# キャッシュウォームアップ後のテスト（ヒット率が高い状態）
k6 run k6/cache_test.js

# キャッシュをフラッシュして再テスト（全ミスの状態）
docker exec redis redis-cli flushall
k6 run k6/cache_test.js
```

### 期待結果比較表

テスト構成: 50 VUs, 60 秒, 1,000 ユーザー ID をランダムに取得

| メトリクス | Cache あり（ウォーム後）| Cache なし（全ミス）| 改善 |
|-----------|----------------------|-------------------|------|
| p50 latency | < 2ms | < 5ms | ~2.5x |
| p95 latency | < 5ms | < 20ms | ~4x |
| p99 latency | < 10ms | < 50ms | ~5x |
| Error Rate | < 0.1% | < 0.1% | 同等 |
| RPS | 800〜1500 | 300〜500 | ~3x |
| DB queries/s | 50〜100 (miss only) | 300〜500 | ~5x 削減 |
| Cache Hit Rate | > 90% | 0% | - |

> **NOTE**: ウォームアップ後のヒット率は、ユニーク ID 数（1,000）と VUs（50）×Duration から決まる。  
> 同じ ID に繰り返しアクセスするほどヒット率は上がる。
