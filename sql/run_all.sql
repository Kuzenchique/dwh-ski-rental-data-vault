-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Полный сценарий: создание структуры и три пакета загрузки хранилища.
-- Запуск:  createdb ski_rental_dwh
--          psql -d ski_rental_dwh -v ON_ERROR_STOP=1 -f run_all.sql

\echo '=== Создание схем, источников и слоёв хранилища ==='
\i 00_init.sql
\i 01_sources_ddl.sql
\i 02_stage_ddl.sql
\i 03_raw_vault_ddl.sql
\i 04_business_vault_ddl.sql
\i 05_etl.sql
\i 06_marts.sql

\echo '=== Пакет 1: состояние источников на 10.01.2026 ==='
\i 07_batch1_sources_data.sql
CALL etl.run_batch('2026-01-11 03:00');

\echo '=== Пакет 2: изменения источников по 15.02.2026 ==='
\i 08_batch2_sources_changes.sql
CALL etl.run_batch('2026-02-16 03:00');

\echo '=== Пакет 3: изменения источников по 31.03.2026 ==='
\i 09_batch3_sources_changes.sql
CALL etl.run_batch('2026-04-01 03:00');

\echo '=== Проверочные запросы ==='
\i 10_check_queries.sql
