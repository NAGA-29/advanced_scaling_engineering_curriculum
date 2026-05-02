-- Step 2: Migrate — 既存データを name から first_name / last_name に変換する
--
-- 重要: このSQLは1回実行するだけではなく、ループで繰り返し実行する。
--       1回の実行で LIMIT 1000 件のみ更新し、全件更新まで繰り返す。
--
-- Bash での繰り返し実行例:
--   while true; do
--     UPDATED=$(mysql -h 127.0.0.1 -u root -proot appdb -e "
--       UPDATE users
--       SET first_name = SUBSTRING_INDEX(name, ' ', 1),
--           last_name  = SUBSTRING_INDEX(name, ' ', -1)
--       WHERE first_name IS NULL
--       LIMIT 1000;
--       SELECT ROW_COUNT();" --silent --skip-column-names | tail -1)
--     echo "Updated: $UPDATED rows"
--     if [ "$UPDATED" -eq 0 ]; then
--       echo "Backfill complete!"
--       break
--     fi
--     sleep 0.1  # 本番環境では少し待機してDBへの負荷を軽減
--   done
--
-- バックフィルの仕組み:
--   - SUBSTRING_INDEX(name, ' ', 1)  : スペース前の部分 -> first_name
--     例: 'Alice Smith' -> 'Alice'
--     例: '山田 太郎'    -> '山田'
--   - SUBSTRING_INDEX(name, ' ', -1) : スペース後の部分 -> last_name
--     例: 'Alice Smith' -> 'Smith'
--     例: '山田 太郎'    -> '太郎'
--   - スペースがない場合: 全体が first_name に、last_name も同じ値になる
--     例: 'Alice' -> first_name='Alice', last_name='Alice'
--
-- 注意: このUPDATEは1000件単位でトランザクションが完結する。
--       より大きいLIMITを使うと長時間トランザクションになりレプリ遅延を引き起こす。

UPDATE users
SET
  first_name = SUBSTRING_INDEX(name, ' ', 1),
  last_name  = SUBSTRING_INDEX(name, ' ', -1)
WHERE first_name IS NULL
LIMIT 1000;

-- 実行後: 残件数確認
-- SELECT COUNT(*) AS remaining FROM users WHERE first_name IS NULL;
