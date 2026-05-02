-- Step 3: Contract — 旧 name カラムを削除する
--
-- 実行前の必須チェックリスト:
--   [ ] アプリの全インスタンスが v2 ハンドラーに切り替わっていること
--   [ ] name カラムを参照するクエリが一切ないこと（コードレビュー済み）
--   [ ] バックフィルが100%完了していること（first_name IS NULL の件数が 0）
--   [ ] Read Replica の遅延がないこと
--
-- 安全確認クエリ（実行前に必ず確認すること）:
--   SELECT COUNT(*) FROM users WHERE first_name IS NULL;
--   -- -> 0 でなければ Contract を実行しない
--
--   SELECT COUNT(*) FROM users WHERE last_name IS NULL;
--   -- -> 0 でなければ Contract を実行しない
--
-- MySQL 8.0 での DROP COLUMN:
--   - 小〜中規模テーブルでは比較的高速（データコピーが発生）
--   - 大規模テーブル（1億行超）では gh-ost や pt-osc の使用を検討
--   - ALGORITHM=INPLACE を使うとオンラインDDLになるが、テーブルの再構築は伴う
--
-- ロールバック手段:
--   name カラムを削除した後に戻す場合は以下を実行:
--     ALTER TABLE users
--       ADD COLUMN name VARCHAR(255) GENERATED ALWAYS AS
--         (CONCAT(first_name, ' ', last_name)) STORED;
--   ただし元の生データには戻らない（Generated Columnになる）ことに注意。

-- 実行前の最終確認
SELECT
  COUNT(*) AS total_rows,
  SUM(CASE WHEN first_name IS NULL THEN 1 ELSE 0 END) AS not_migrated_first,
  SUM(CASE WHEN last_name  IS NULL THEN 1 ELSE 0 END) AS not_migrated_last
FROM users;
-- not_migrated_first = 0 AND not_migrated_last = 0 であることを確認してから以下を実行

-- Phase 3: DROP COLUMN
ALTER TABLE users
  DROP COLUMN name;

-- 実行後の確認クエリ
-- DESCRIBE users;
-- -> name カラムが消えていること
-- -> first_name, last_name カラムが存在すること

-- NOT NULL 制約を追加（全データがバックフィル済みの場合）
-- ALTER TABLE users
--   MODIFY COLUMN first_name VARCHAR(100) NOT NULL,
--   MODIFY COLUMN last_name  VARCHAR(100) NOT NULL;
