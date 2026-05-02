# Advanced Scaling Engineering Curriculum

Webアプリケーションを段階的にスケールさせる技術を、実際に手を動かして習得するカリキュラムです。  
単一EC2構成から始め、キャッシュ・レプリカ・シャーディング・非同期処理・マイクロサービス移行まで、  
15ステップで「なぜスケールが必要か」から「どうスケールさせるか」までを体得します。

---

## 技術スタック

| 分類 | 技術 |
|------|------|
| Backend | Go (Echo framework) |
| Database | MySQL 8 on RDS (t3.micro) |
| Cache | Redis on EC2 (t3.micro) |
| Load Balancer | AWS ALB |
| IaC | Terraform |
| Load Testing | k6 |

---

## カリキュラム全体像

| ステップ | テーマ | 習得内容 |
|---------|--------|---------|
| [Step 00](./step00_terraform_base/README.md) | Terraform ベース構築 | VPC / EC2 / SG / Key Pair を Terraform で管理し、Go/Echo API を systemd で起動する |
| [Step 01](./step01_single_node_limit/README.md) | 単一ノードの限界を知る | EC2 1台 + MySQL 1台の性能上限を k6 で計測し、スケールアウトの必要性を体感する |
| [Step 02](./step02_db_index_and_query_tuning/README.md) | DBインデックス・クエリチューニング | EXPLAIN 読解・インデックス設計・N+1 解消・複合インデックスの順序設計 |
| [Step 03](./step03_read_replica/README.md) | Read Replica | MySQL Read Replica 導入、Primary/Replica 切り替え、Replica Lag 監視、Fallback 実装 |
| [Step 04](./step04_redis_cache_aside/README.md) | Redis Cache-Aside | Cache-Aside パターン実装、キャッシュヒット率計測、TTL 設計、Redis 停止時の Fallback |
| [Step 05](./step05_ec2_scale_out_alb/README.md) | EC2 スケールアウト + ALB | ALB 配下の複数 EC2 構成、ヘルスチェック、ラウンドロビン負荷分散 |
| [Step 06](./step06_dns_switch_blue_green/README.md) | Blue/Green デプロイ | Route53 DNS 切り替えによるゼロダウンタイム移行、TTL 短縮と切り戻し手順 |
| [Step 07](./step07_redis_sharding/README.md) | Redis シャーディング | CRC32 ハッシュによるシャーディング実装、Consistent Hashing の理解 |
| [Step 08](./step08_db_sharding_resolver/README.md) | DB シャーディング Resolver | `tenant_id % N` シャード解決、Resolver パターン抽象化、無停止バックフィル手順 |
| [Step 09](./step09_zero_downtime_schema_migration/README.md) | ゼロダウンタイムスキーママイグレーション | Expand → Migrate → Contract の3段階パターン、カラム分割の無停止移行 |
| [Step 10](./step10_strangler_laravel_to_echo/README.md) | Strangler Fig Pattern | Laravel モノリスを停止せず Go/Echo へ段階移行、nginx リバースプロキシによるトラフィック切り替え |
| [Step 11](./step11_async_queue_worker/README.md) | 非同期キューワーカー | Redis Stream を使ったプロデューサー・コンシューマー実装、冪等性設計 |
| [Step 12](./step12_failure_design/README.md) | 障害設計 | Timeout / Retry / Circuit Breaker / Fallback / Degraded Response パターンの実装 |
| [Step 13](./step13_observability_and_capacity_planning/README.md) | 可観測性・キャパシティプランニング | カスタムメトリクス収集、スループット・レイテンシ・エラー率の計測、データに基づくスケール判断 |
| [Step 14](./step14_final_boss_migration_drill/README.md) | 最終ボス — 実務移行演習 | Step 01〜13 の技術を統合し、Laravel モノリスからスケーラブルなマイクロサービス構成へ完走する |

---

## 事前準備

```bash
# 必要なツール
aws --version        # AWS CLI v2
terraform --version  # Terraform >= 1.5
go version           # Go >= 1.21
k6 version           # k6 >= 0.50
docker --version     # Docker (ローカル検証用)
```

AWS アカウントと IAM ユーザー（EC2/RDS/ElastiCache/ALB/Route53 の操作権限）が必要です。

---

## 進め方

1. **Step 00 から順に進める** — 各ステップは前のステップのインフラを前提とします。
2. **各ステップの README を読む** — 目的・構成・手順・確認方法・クリーンアップが記載されています。
3. **k6 負荷テストで効果を数値確認する** — 「速くなった気がする」ではなく数値で体得します。
4. **必ず `terraform destroy` してから次へ進む** — 放置すると課金が発生します。

---

## コスト目安

| リソース | 時間単価 | 備考 |
|---------|---------|------|
| EC2 t3.micro | $0.0116/h | 各ステップで destroy |
| RDS t3.micro | $0.017/h | **使用後すぐに削除すること** |
| ALB | $0.008/h + LCU | Step 05 以降 |
| Redis (EC2) | $0.0116/h | RDS より安価 |

> **カリキュラム全体を順番に実施して都度 destroy した場合、合計 $5 USD 未満を想定しています。**  
> RDS インスタンスを削除し忘れると一晩で $1〜2 の課金が発生します。必ずクリーンアップしてください。

---

## リポジトリ構成

```
.
├── README.md
├── AGENTS.md                          # AI エージェント向けコントリビューションガイド
├── docs/                              # アーキテクチャ概要・コスト試算ドキュメント
├── infra/terraform/modules/           # 共通 Terraform モジュール
├── shared/echo-api/                   # 共通 Go/Echo API ベース
├── step00_terraform_base/
├── step01_single_node_limit/
├── step02_db_index_and_query_tuning/
├── step03_read_replica/
├── step04_redis_cache_aside/
├── step05_ec2_scale_out_alb/
├── step06_dns_switch_blue_green/
├── step07_redis_sharding/
├── step08_db_sharding_resolver/
├── step09_zero_downtime_schema_migration/
├── step10_strangler_laravel_to_echo/
├── step11_async_queue_worker/
├── step12_failure_design/
├── step13_observability_and_capacity_planning/
└── step14_final_boss_migration_drill/
```

各ステップディレクトリの構成:

```
stepXX_<name>/
├── README.md          # 日本語のウォークスルー
├── terraform/         # そのステップの IaC
├── app/               # アプリケーションコード (Go / PHP など)
├── scripts/
│   ├── setup.sh       # 冪等なセットアップスクリプト
│   └── verify.sh      # 動作確認スクリプト (終了コード 0 = 成功)
└── k6/
    └── load_test.js   # k6 負荷テスト
```

---

## セキュリティ上の注意

- AWS クレデンシャル・秘密鍵・`.env` ファイルは **絶対にコミットしない**
- SSH Security Group は自分の IP のみ許可する (`0.0.0.0/0` は禁止)
- RDS は `publicly_accessible = false` で作成する
- 本リポジトリは学習用途であり、実際のユーザーデータは保存しない

---

## コントリビューション

コントリビューションの詳細ルールは [AGENTS.md](./AGENTS.md) を参照してください。

- `main` ブランチへの直接コミットは禁止 — Pull Request 経由でのみマージ
- PR タイトル形式: `[stepXX] 変更内容の短い説明`
- 新しいステップを追加する場合は AGENTS.md の「How to Add a New Step」セクションに従う
