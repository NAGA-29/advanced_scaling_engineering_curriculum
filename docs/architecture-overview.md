# Architecture Overview — Advanced Scaling Engineering Curriculum

このドキュメントでは、カリキュラムの各ステップにおけるシステムアーキテクチャの変遷を示します。
step00（単一EC2）からstep14（完全分散システム）までの進化を ASCII ダイアグラムで表現しています。

---

## 全体の進化サマリー

```
step00  Single EC2 + MySQL on same host
  |
step01  Observe limits: connection pool exhaustion, slow queries
  |
step02  DB index tuning, query optimization (same architecture)
  |
step03  RDS Read Replica — separate read/write paths
  |
step04  Redis Cache Aside — reduce DB read load
  |
step05  ALB + Multiple EC2 — horizontal scaling
  |
step06  Shared session store (Redis) for stateless EC2
  |
step07  RDS parameter tuning + connection pooling (PgBouncer/ProxySQL)
  |
step08  DB Sharding — partition user data across multiple DB nodes
  |
step09  Strangler Fig pattern — migrate legacy endpoints incrementally
  |
step10  Expand-Migrate-Contract — zero downtime schema migration
  |
step11  Blue/Green Deployment with ALB weighted target groups
  |
step12  DNS-based Blue/Green with Route53 weighted routing
  |
step13  Circuit Breaker + health-aware routing
  |
step14  Full distributed system — all patterns combined
```

---

## step00 — Single EC2 with Local MySQL

**目的**: ベースラインを構築する。すべてが1台のサーバーで動作する最もシンプルな構成。

```
Internet
    |
    | HTTP :8080
    v
+-------------------+
|    EC2 t3.micro   |
|                   |
|  [Go App :8080]   |
|                   |
|  [MySQL :3306]    |
|   (local)         |
+-------------------+
         |
     VPC / Public Subnet
         |
     ap-northeast-1
```

**リソース**:
- EC2: t3.micro (1台)
- MySQL: EC2内ローカルインストール
- Security Group: SSH (22), HTTP (8080)

**ボトルネック**: EC2が1台のため、垂直スケールのみ可能。MySQLとAppが同一ホストでリソースを競合する。

---

## step01 — Single Node Limit Observation

**目的**: 単一ノードの限界を k6 で実測し、何が壊れるかを理解する。
アーキテクチャはstep00と同一。ここでは負荷テストで問題を観測する。

```
Internet
    |
    | k6 load test (100 VUs)
    v
+-------------------+
|    EC2 t3.micro   |  <-- CPU 100%, connections exhausted
|                   |
|  [Go App :8080]   |  <-- goroutine leak / timeout
|                   |
|  [MySQL :3306]    |  <-- "too many connections" error
|   (local)         |
+-------------------+

観測される症状:
  - HTTP 500 / connection refused
  - p(95) latency > 5000ms
  - MySQL error: "Too many connections"
```

---

## step02 — DB Index and Query Tuning

**目的**: クエリの最適化とインデックスの追加でDBのボトルネックを解消する。
アーキテクチャはstep00と同一だが、クエリパフォーマンスが大幅改善。

```
Internet
    |
    v
+-------------------+
|    EC2 t3.micro   |
|                   |
|  [Go App :8080]   |
|                   |
|  [MySQL :3306]    |
|   + INDEX on      |
|     users(email)  |
|   + EXPLAIN tuned |
+-------------------+

改善:
  - Full table scan -> Index scan
  - EXPLAIN ANALYZE でボトルネック特定
  - N+1 クエリの解消
```

---

## step03 — RDS Read Replica

**目的**: 読み取りを Read Replica にオフロードし、Write と Read を分離する。

```
Internet
    |
    v
+---------------------------+
|       EC2 t3.micro        |
|                           |
|  [Go App :8080]           |
|    |                      |
|    +-- writes --> [RDS Primary]  <---+
|    |              t3.micro          | (synchronous replication)
|    +-- reads  --> [RDS Replica]  ---+
|                   t3.micro
+---------------------------+

VPC
  Subnet (Public):  EC2
  Subnet (Private): RDS Primary, RDS Replica

Write path:  App --> RDS Primary  (ap-northeast-1a)
Read  path:  App --> RDS Replica  (ap-northeast-1c)
```

**新規リソース**:
- RDS t3.micro (Primary) — ~$13/月
- RDS t3.micro (Read Replica) — ~$13/月
- DB Subnet Group

**注意**: Read Replica はほぼリアルタイムだが、レプリケーション遅延（Replica Lag）が発生しうる。

---

## step04 — Redis Cache Aside

**目的**: よく読まれるデータを Redis にキャッシュし、DB への読み取り負荷を削減する。

```
Internet
    |
    v
+--------------------------------------------------+
|              EC2 t3.micro (App)                  |
|                                                  |
|  [Go App :8080]                                  |
|       |                                          |
|       +--(1) Cache lookup--> [Redis EC2 :6379]   |
|       |      HIT: return cached data             |
|       |      MISS: fetch from DB, store, return  |
|       |                                          |
|       +--(2) DB read (on miss)--> [RDS Primary]  |
|       |                                          |
|       +--(3) DB write ---------> [RDS Primary]   |
|              (invalidate cache on write)         |
+--------------------------------------------------+

Cache Aside パターン:
  Read:  Check Redis -> (miss) Read DB -> Write Redis -> Return
  Write: Write DB -> Delete Redis key
```

**新規リソース**:
- EC2 t3.micro (Redis) — ~$8/月
- Redis はセルフホスト（ElastiCache は使わない — コスト削減）

---

## step05 — ALB + Multiple EC2 (Horizontal Scaling)

**目的**: Application Load Balancer を追加し、複数の App サーバーに負荷を分散する。

```
Internet
    |
    | HTTPS/HTTP :80/:443
    v
+---------------------------+
|   Application Load        |
|   Balancer (ALB)          |
|   Listener: :80           |
+---------------------------+
       |           |
       |           |
       v           v
+----------+  +----------+
| EC2 App1 |  | EC2 App2 |   (+ App3... horizontally scalable)
| t3.micro |  | t3.micro |
| :8080    |  | :8080    |
+----------+  +----------+
       |           |
       +-----------+
             |
     +----------------+
     |  RDS Primary   |
     |  + Read Replica|
     +----------------+
             |
     +----------------+
     |  Redis Cache   |
     |  (EC2)         |
     +----------------+

ALB Target Group:
  - Health check: GET /health -> 200 OK
  - Algorithm: Round Robin
  - Stickiness: OFF (stateless app)
```

**新規リソース**:
- ALB — ~$16/月
- Target Group
- 追加 EC2 t3.micro — ~$8/月 × 台数

**問題点**: セッションデータが各EC2のメモリにある場合、ロードバランシングでセッションが失われる。
→ step06 で解決。

---

## step06 — Shared Session Store (Stateless EC2)

**目的**: セッションを Redis に移動し、すべての EC2 インスタンスをステートレスにする。

```
Internet
    |
    v
  [ ALB ]
    |
    +----------+-----------+
    |          |           |
  [App1]     [App2]     [App3]
    |          |           |
    +-----------+-----------+
                |
         [Redis :6379]
          Session Store
          Cache Store
                |
         [RDS Primary]
         [RDS Replica]

すべての App インスタンスが同一の Redis からセッションを読み書きする。
どの App にリクエストが届いても同じセッションデータにアクセス可能。
```

---

## step07 — Connection Pooling (ProxySQL / PgBouncer)

**目的**: DB 接続数の爆発を抑えるためコネクションプーラーを導入する。

```
                [ALB]
                  |
        +---------+---------+
        |                   |
      [App1]              [App2]
        |                   |
        +--------+----------+
                 |
          [ProxySQL :6033]    <-- 接続プーラー
          (EC2 t3.micro)
                 |
         +-------+-------+
         |               |
   [RDS Primary]   [RDS Replica]
   (書き込みルート)  (読み取りルート)

ProxySQL によるルーティング:
  SELECT  -> Read Replica
  INSERT/UPDATE/DELETE -> Primary
  接続数の上限管理 (max_connections の超過を防ぐ)
```

---

## step08 — DB Sharding

**目的**: ユーザーデータを複数のDBノードに分散し、書き込みスループットをスケールする。

```
[ALB]
  |
[App Servers]
  |
[Shard Router (App Layer)]
  |
  +-- user_id % 2 == 0 --> [RDS Shard 0]  (users 0, 2, 4, ...)
  |
  +-- user_id % 2 == 1 --> [RDS Shard 1]  (users 1, 3, 5, ...)

シャーディングキー: user_id
シャード数: 2 (学習用、本番では一般的に 8〜1024)

注意点:
  - クロスシャードJOINは不可
  - シャード間のトランザクションは複雑
  - リシャーディング（再分散）は高コスト
```

---

## step09 — Strangler Fig Pattern

**目的**: 既存のモノリスを壊さずに新機能を新サービスへ段階的に移行する。

```
Internet
    |
    v
  [ALB]
    |
    +-- /api/v2/* ---------> [New Go Service]  (新アーキテクチャ)
    |
    +-- /api/v1/* ---------> [Legacy App]      (既存システム)
    |
    +-- /* (default) ------> [Legacy App]      (フォールバック)

移行フロー:
  1. 新エンドポイントを新サービスに実装
  2. ALBルールで新サービスへトラフィックを切り替え
  3. 旧エンドポイントを段階的に廃止
  4. 最終的にレガシーAppを削除
```

---

## step10 — Expand-Migrate-Contract (Zero Downtime Schema Migration)

**目的**: ダウンタイムなしでDBスキーマを変更する3フェーズ手法を学ぶ。

```
フェーズ1: Expand (拡張)
  既存カラムを残したまま新カラムを追加
  [RDS] ALTER TABLE users ADD COLUMN email_new VARCHAR(255);
  App: 新旧両カラムに書き込む

フェーズ2: Migrate (移行)
  バックグラウンドジョブで既存データを新カラムに移行
  [Migration Job] UPDATE users SET email_new = email WHERE email_new IS NULL;

フェーズ3: Contract (縮小)
  旧カラムを削除、新カラムのみ使用
  App: 新カラムのみ参照
  [RDS] ALTER TABLE users DROP COLUMN email;
  [RDS] ALTER TABLE users RENAME COLUMN email_new TO email;

各フェーズはロールバック可能。ダウンタイムはゼロ。
```

---

## step11 — Blue/Green Deployment with ALB

**目的**: ALB の加重ターゲットグループを使って Blue/Green デプロイを実現する。

```
[ALB Listener :80]
    |
    +-- Weight 100% --> [Target Group: Blue]  (現行バージョン)
    |
    +-- Weight   0% --> [Target Group: Green] (新バージョン)

デプロイ手順:
  1. Green 環境に新バージョンをデプロイ
  2. Green の Health Check 確認
  3. ALB の重みを段階的に変更:
       Blue 100% / Green 0%
     → Blue  90% / Green 10%  (カナリアテスト)
     → Blue  50% / Green 50%
     → Blue   0% / Green 100%
  4. 問題があれば即座に Blue 100% に戻す

[Blue TG]              [Green TG]
  App v1.0               App v1.1
  EC2 × 2                EC2 × 2
```

---

## step12 — DNS-based Blue/Green with Route53

**目的**: Route53 の加重ルーティングで DNS レベルの Blue/Green 切り替えを行う。

```
Internet
    |
    v
[Route53] app.example.com
    |
    +-- Weight 80 --> [ALB Blue]  --> [App v1.0]
    |
    +-- Weight 20 --> [ALB Green] --> [App v1.1]

切り替え完了後:
    +-- Weight  0 --> [ALB Blue]  (削除候補)
    |
    +-- Weight 100 --> [ALB Green] (新バージョン)

DNS TTL の設定:
  - 通常: 300秒
  - 切り替え前: 60秒に変更（ロールバックを速くするため）
  - 切り替え後: 300秒に戻す

注意: DNS TTL の間はクライアントが古いIPにアクセスし続けるケースがある。
```

---

## step13 — Circuit Breaker + Health-Aware Routing

**目的**: 障害を検知して自動的にトラフィックを遮断・迂回する Circuit Breaker パターンを実装する。

```
[App Server]
    |
    v
[Circuit Breaker (App Layer)]
  State: CLOSED / OPEN / HALF-OPEN
    |
    +-- CLOSED:    正常時 → DBやキャッシュに通常アクセス
    |
    +-- OPEN:      障害検知後 → 即座にエラーを返す (fast fail)
    |              (デフォルトレスポンスやキャッシュデータを返す)
    |
    +-- HALF-OPEN: 一定時間後 → 1リクエストを試行
                   成功 → CLOSED に戻る
                   失敗 → OPEN に戻る

ALB レベルの Health Check:
  /health endpoint:
    DB接続 OK かつ Redis接続 OK → 200
    いずれか NG → 503
    ALB が503を検知 → Target Group から除外
```

---

## step14 — Full Distributed System

**目的**: 全パターンを統合した、本番に近い完全分散システム。

```
                        Internet
                           |
                     [Route53]
                    Weighted Routing
                    /             \
              [ALB Blue]       [ALB Green]
                  |                 |
         +--------+--------+   +--------+--------+
         |                 |   |                 |
      [App1-Blue]   [App2-Blue] [App1-Green] [App2-Green]
      Go + Circuit Breaker + Cache Aside

         |                 |
         +-----------------+
                   |
         +---------+---------+
         |                   |
   [ProxySQL]           [Redis Cluster]
   Connection Pool       Cache + Session
         |
   +-----+------+
   |             |
[RDS Primary] [RDS Replica]
(Write)         (Read)
   |
[RDS Shard 0] [RDS Shard 1]
(user_id even) (user_id odd)

凡例:
  --> 同期通信
  --> 非同期 / キャッシュ参照
  RDS: すべて t3.micro, Single-AZ
  EC2: すべて t3.micro
```

**step14 の全コンポーネント**:

| コンポーネント | 役割 | リソース |
|---|---|---|
| Route53 | DNS加重ルーティング Blue/Green | Route53 Hosted Zone |
| ALB (Blue/Green) | L7ロードバランシング | ALB × 2 |
| App Server | API処理、Circuit Breaker | EC2 t3.micro × 4 |
| Redis | Cache Aside + Session Store | EC2 t3.micro × 1 |
| ProxySQL | DB接続プーリング + R/Wルーティング | EC2 t3.micro × 1 |
| RDS Primary | 書き込みDB | RDS t3.micro × 1 |
| RDS Replica | 読み取りDB | RDS t3.micro × 1 |
| RDS Shard | シャーディングDB | RDS t3.micro × 2 |

---

## アーキテクチャ進化の比較表

| Step | 主な変更点 | 解決する問題 | 新規リソース |
|------|-----------|-------------|-------------|
| step00 | 単一EC2 + ローカルMySQL | ベースライン構築 | EC2×1 |
| step01 | 負荷テスト観測 | 限界点の把握 | なし |
| step02 | DBインデックス + クエリ最適化 | スロークエリ | なし |
| step03 | RDS Read Replica | 読み取りボトルネック | RDS×2 |
| step04 | Redis Cache Aside | DB読み取り過多 | EC2(Redis)×1 |
| step05 | ALB + 複数EC2 | 単一SPOFと垂直限界 | ALB, EC2×1 |
| step06 | Redis Session Store | ステートフルEC2問題 | なし(Redis再利用) |
| step07 | ProxySQL接続プーリング | 接続数爆発 | EC2(Proxy)×1 |
| step08 | DBシャーディング | 書き込みスループット | RDS×1(shard) |
| step09 | Strangler Fig移行 | レガシー移行 | なし |
| step10 | Expand-Migrate-Contract | ゼロダウンタイム移行 | なし |
| step11 | ALB Blue/Green | デプロイリスク削減 | TG×1 |
| step12 | Route53 加重ルーティング | DNS Blue/Green | ALB×1 |
| step13 | Circuit Breaker | 障害の連鎖防止 | なし |
| step14 | 全パターン統合 | 本番級可用性 | 全リソース |
