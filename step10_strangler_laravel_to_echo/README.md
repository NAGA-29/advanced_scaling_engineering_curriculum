# STEP 10: Strangler Fig Pattern — Laravel から Go/Echo へ段階移行

## 目的

既存の Laravel モノリスを停止せずに、Go/Echo サービスへ一部機能を切り出す技術を習得する。  
Strangler Fig Pattern（絞め殺しイチジクパターン）とは、古いシステムの横に新システムを育て、  
トラフィックを少しずつ切り替えることでリスクゼロで移行を進める手法である。  
モノリス分解は「横に置いて少しずつ流す」作業であることを体感する。

---

## 構成

### フェーズ 1: Laravel のみ

```
Client
  │
  ▼
[Laravel :8000]
  ├── GET  /heartbeat
  ├── POST /api/legacy/users
  └── POST /api/legacy/orders
```

### フェーズ 2: Nginx ルーティング追加

```
Client
  │
  ▼
[Nginx :80]  ← パスベースルーティング
  ├── /heartbeat  ──────────────────→ [Echo :8080]  (新システム)
  ├── /events     ──────────────────→ [Echo :8080]  (新システム)
  └── /api/legacy, /* ──────────────→ [Laravel :8000]  (旧システム)
```

### フェーズ 3: 完全移行後 (Laravel 削除)

```
Client
  │
  ▼
[Nginx :80]
  │
  ▼
[Echo :8080]
  ├── GET  /heartbeat
  ├── POST /events
  └── POST /api/* (全機能移行済)
```

| コンポーネント | ポート | 役割                    |
|--------------|--------|------------------------|
| Nginx        | 80     | リバースプロキシ・ルーター |
| Laravel      | 8000   | 旧モノリス API           |
| Go/Echo      | 8080   | 新マイクロサービス        |

---

## 成果物

```
step10_strangler_laravel_to_echo/
├── README.md                   # このファイル
├── nginx/
│   └── nginx.conf              # パスベースルーティング設定
├── app/
│   ├── echo_heartbeat.go       # Echo /heartbeat ハンドラ (JWT 認証付き)
│   └── middleware.go           # X-Request-ID 伝播ミドルウェア
├── k6/
│   └── comparison_test.js      # Laravel vs Echo レイテンシ比較テスト
└── scripts/
    └── verify_routing.sh       # ルーティング検証スクリプト
```

---

## 前提条件

- Nginx がインストールされていること (`sudo apt-get install -y nginx`)
- Go 1.22 以上
- PHP 8.x + Composer (Laravel 用)
- k6 がインストールされていること
- ポート 80, 8000, 8080 が開放されていること

---

## 実行手順

### 1. Laravel 起動 (旧システム)

```bash
cd /var/www/laravel
composer install
cp .env.example .env
php artisan key:generate
php artisan migrate --seed
php artisan serve --port=8000 &
```

### 2. Echo 起動 (新システム)

```bash
cd step10_strangler_laravel_to_echo/app
go mod init github.com/advanced-scaling/step10
go get github.com/labstack/echo/v4
go get github.com/golang-jwt/jwt/v5
go get github.com/labstack/echo-jwt/v4
go get github.com/google/uuid
go run *.go
```

別ターミナルで確認:
```bash
curl http://localhost:8080/heartbeat
```

### 3. Nginx 設定適用

```bash
sudo cp nginx/nginx.conf /etc/nginx/nginx.conf
sudo nginx -t
sudo systemctl reload nginx
```

### 4. フェーズ 2: トラフィック分岐開始

```bash
# Nginx 経由でアクセスすると自動的にルーティングされる
curl http://localhost/heartbeat       # → Echo が処理
curl http://localhost/api/legacy/users # → Laravel が処理
```

### 5. フェーズ 3: Laravel 側の /heartbeat を削除

```bash
# Laravel の routes/api.php から /heartbeat を削除
# または Nginx で Laravel へのフォールバックを止める
```

---

## 確認方法

```bash
# ルーティング検証スクリプトを実行
bash scripts/verify_routing.sh

# X-Handled-By ヘッダを確認
curl -v http://localhost/heartbeat 2>&1 | grep -i "x-handled-by"
# → X-Handled-By: echo

curl -v http://localhost/api/legacy/users 2>&1 | grep -i "x-handled-by"
# → X-Handled-By: laravel

# k6 で両バックエンドのレイテンシを比較
k6 run k6/comparison_test.js
```

---

## 壊す手順

### シナリオ 1: Echo を停止してフォールバックを確認

```bash
# Echo プロセスを停止
pkill -f "go run"

# /heartbeat へのリクエストが 502 になることを確認
curl -v http://localhost/heartbeat
# → 502 Bad Gateway (Echo が落ちているため)

# Nginx のフォールバック設定なし → ユーザーへの影響あり
```

### シナリオ 2: ルーティング設定ミス

```bash
# nginx.conf の location ブロック順序を間違える
# /heartbeat が Laravel に流れてしまう場合を再現
sudo vi /etc/nginx/nginx.conf
# location / { proxy_pass http://laravel; } を先に書く
sudo nginx -s reload
curl http://localhost/heartbeat
# → Laravel が処理してしまう (X-Handled-By: laravel)
```

### シナリオ 3: JWT シークレット不一致

```bash
# Echo の JWT_SECRET を変更して認証失敗を再現
JWT_SECRET=wrong_secret go run app/*.go &
curl -H "Authorization: Bearer $(cat test_token.txt)" http://localhost/heartbeat
# → 401 Unauthorized
```

---

## 復旧手順

### Echo 復旧

```bash
cd app && go run *.go &
# または systemd 管理の場合
sudo systemctl start echo-api
```

### Nginx 設定修正

```bash
sudo cp nginx/nginx.conf /etc/nginx/nginx.conf
sudo nginx -t && sudo systemctl reload nginx
```

### JWT 設定修正

```bash
export JWT_SECRET=correct_secret
go run app/*.go &
```

---

## 削除手順

```bash
# プロセス停止
pkill -f "go run"
pkill -f "php artisan serve"

# Nginx をデフォルト設定に戻す
sudo cp /etc/nginx/nginx.conf.orig /etc/nginx/nginx.conf
sudo systemctl reload nginx

# ファイル削除
rm -rf step10_strangler_laravel_to_echo/
```

---

## 学び

| ポイント                    | 説明                                                              |
|---------------------------|------------------------------------------------------------------|
| Strangler Fig Pattern      | 旧システムを止めずに新システムを横に建てる移行戦略                   |
| パスベースルーティング        | Nginx の `location` ブロックで API パスごとに転送先を変える          |
| X-Request-ID 伝播          | 旧システム・新システム間でリクエスト追跡 ID を引き継ぐ               |
| 段階的な移行                 | 一気に切り替えず、パスごとに少しずつ Echo へ移す                    |
| ロールバックの容易さ          | Nginx 設定を元に戻すだけで旧システムに完全切り戻し可能               |
| JWT 認証の互換性             | 旧システムと同じトークンフォーマットを Echo でも処理できるようにする  |

**モノリス分解の鉄則**: 一度に全部移すのではなく、「横に置いて少しずつ流す」ことでリスクを最小化する。

---

## k6 負荷テスト

### 実行コマンド

```bash
k6 run k6/comparison_test.js
```

### 目標メトリクス

| メトリクス              | Laravel (目標) | Echo (目標)   | 説明                         |
|------------------------|--------------|-------------|------------------------------|
| `http_req_duration p50` | < 50 ms      | < 10 ms     | 中央値レイテンシ               |
| `http_req_duration p95` | < 150 ms     | < 30 ms     | 95 パーセンタイル              |
| `http_req_duration p99` | < 300 ms     | < 50 ms     | 99 パーセンタイル              |
| `http_req_failed`       | < 1%         | < 0.1%      | エラー率                      |
| `http_reqs`             | ~200 req/s   | ~1000 req/s | スループット                  |
| `laravel_latency`       | 記録          | -           | Laravel レイテンシカスタム指標 |
| `echo_latency`          | -            | 記録         | Echo レイテンシカスタム指標    |

### 期待される結果

Go/Echo は Laravel の約 5-10 倍のスループットを達成し、p99 レイテンシが大幅に改善される。
移行完了後に k6 結果を比較することで、移行の効果を定量的に証明できる。
