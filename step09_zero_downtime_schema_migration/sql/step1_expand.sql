-- Step 1: Expand — first_name と last_name カラムを追加する
--
-- 安全なALTER:
--   - NULL を許容するカラム追加は MySQL 8.0.12+ でINSTANT DDL
--   - テーブルロックなし（既存データは変更しない）
--   - 既存コード（name カラムを参照するコード）は引き続き動作する
--
-- 実行タイミング:
--   本番サービス稼働中に実行可能
--   実行後: v1（互換）ハンドラーをデプロイする
--
-- 確認:
--   DESCRIBE users;
--   -> first_name VARCHAR(100) NULL, last_name VARCHAR(100) NULL が追加されていること

-- まだ first_name が存在しない場合のみ追加（冪等性のため）
ALTER TABLE users
  ADD COLUMN first_name VARCHAR(100) NULL COMMENT 'Given name (split from name column)' AFTER name,
  ADD COLUMN last_name  VARCHAR(100) NULL COMMENT 'Family name (split from name column)' AFTER first_name,
  ALGORITHM=INSTANT;

-- 追加後の確認クエリ（実行後に手動で確認）
-- DESCRIBE users;
-- SELECT id, name, first_name, last_name FROM users LIMIT 5;
