-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Проверочные и демонстрационные запросы

\pset null '—'

\echo '--- 1. Журнал загрузок: количество добавленных строк по пакетам'
SELECT l.layer, l.target_table,
       sum(rows_loaded) FILTER (WHERE batch_id = 1) AS batch_1,
       sum(rows_loaded) FILTER (WHERE batch_id = 2) AS batch_2,
       sum(rows_loaded) FILTER (WHERE batch_id = 3) AS batch_3,
       sum(rows_loaded)                             AS total
FROM etl.load_log l
WHERE l.layer <> 'stage'
GROUP BY l.layer, l.target_table
ORDER BY l.layer DESC, l.target_table;

\echo '--- 2. Пример содержимого хаба клиентов'
SELECT encode(client_hk, 'hex') AS client_hk, load_date, record_source, passport_number
FROM raw_vault.hub_client ORDER BY load_date, passport_number LIMIT 5;

\echo '--- 3. Пример содержимого ссылки «позиция договора»'
SELECT encode(l.rental_item_hk, 'hex') AS rental_item_hk, hr.rental_number, he.inventory_number, ht.tariff_code, l.load_date
FROM raw_vault.lnk_rental_item l
JOIN raw_vault.hub_rental hr USING (rental_hk)
JOIN raw_vault.hub_equipment he USING (equipment_hk)
JOIN raw_vault.hub_tariff ht USING (tariff_hk)
ORDER BY hr.rental_number LIMIT 5;

\echo '--- 4. История контактных данных клиентов (несколько версий в сателлите)'
SELECT h.passport_number, s.last_name || ' ' || s.first_name AS client, s.phone, s.email, s.load_date,
       encode(s.hash_diff, 'hex') AS hash_diff
FROM raw_vault.sat_client_crm s
JOIN raw_vault.hub_client h USING (client_hk)
WHERE s.client_hk IN (SELECT client_hk FROM raw_vault.sat_client_crm GROUP BY 1 HAVING count(*) > 1)
ORDER BY h.passport_number, s.load_date;

\echo '--- 5. История цен тарифов'
SELECT * FROM mart.rep_tariff_price_history
WHERE tariff_code IN (SELECT tariff_code FROM mart.rep_tariff_price_history GROUP BY 1 HAVING count(*) > 1)
ORDER BY tariff_code, valid_from;

\echo '--- 6. Жизненный цикл договора: открыт в пакете 1, закрыт в пакете 2'
SELECT h.rental_number, s.load_date, s.status, s.start_at, s.planned_end_at, s.actual_end_at
FROM raw_vault.sat_rental s
JOIN raw_vault.hub_rental h USING (rental_hk)
WHERE s.rental_hk IN (SELECT rental_hk FROM raw_vault.sat_rental GROUP BY 1 HAVING count(*) > 1)
ORDER BY h.rental_number, s.load_date
LIMIT 6;

\echo '--- 7. Business Vault: расчётный сателлит договора (последние версии)'
SELECT h.rental_number, c.items_count, c.duration_hours, c.charged_amount, c.damage_amount,
       c.paid_amount, c.balance, c.is_closed, c.is_overdue
FROM raw_vault.hub_rental h
JOIN LATERAL (SELECT * FROM business_vault.sat_rental_calc x
              WHERE x.rental_hk = h.rental_hk ORDER BY x.load_date DESC LIMIT 1) c ON true
WHERE c.damage_amount > 0 OR NOT c.is_closed
ORDER BY h.rental_number DESC
LIMIT 8;

\echo '--- 8. Сверка: суммы в витрине совпадают с источником'
SELECT 'Начислено за прокат' AS metric,
       (SELECT sum(amount) FROM src_rental.rental_item)        AS source,
       (SELECT sum(amount) FROM mart.fact_rental_item)         AS mart
UNION ALL
SELECT 'Возмещение ущерба',
       (SELECT sum(damage_fee) FROM src_rental.rental_item),
       (SELECT sum(damage_fee) FROM mart.fact_rental_item)
UNION ALL
SELECT 'Оплачено по чекам',
       (SELECT sum(amount) FROM src_rental.payment),
       (SELECT sum(amount) FROM mart.rep_payments)
UNION ALL
SELECT 'Количество позиций договоров',
       (SELECT count(*) FROM src_rental.rental_item),
       (SELECT count(*) FROM mart.fact_rental_item);

\echo '--- 9. Витрина: выручка по месяцам и типам инвентаря'
SELECT year, month_name,
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Горные лыжи')           AS "Горные лыжи",
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Горнолыжные ботинки')   AS "ГЛ ботинки",
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Сноуборд')              AS "Сноуборд",
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Ботинки для сноуборда') AS "Сноуб. ботинки",
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Беговые лыжи')          AS "Беговые лыжи",
       sum(rental_revenue) FILTER (WHERE equipment_type = 'Шлем')                  AS "Шлемы",
       sum(rental_revenue)                                                          AS "Итого"
FROM mart.rep_revenue_by_month
GROUP BY year, month, month_name
ORDER BY year, month;

\echo '--- 10. Витрина: самые доходные и наименее окупаемые единицы инвентаря'
(SELECT * FROM mart.rep_equipment_efficiency ORDER BY payback_pct DESC LIMIT 5)
UNION ALL
(SELECT * FROM mart.rep_equipment_efficiency WHERE status <> 'списан' ORDER BY payback_pct LIMIT 5);

\echo '--- 11. Витрина: окупаемость по типам инвентаря'
SELECT equipment_type, count(*) AS items, sum(times_rented) AS rentals,
       round(avg(hours_in_rent), 1) AS avg_hours, sum(revenue) AS revenue,
       sum(purchase_price) AS purchase_cost,
       round(100 * sum(revenue) / sum(purchase_price), 1) AS payback_pct
FROM mart.rep_equipment_efficiency
GROUP BY equipment_type ORDER BY payback_pct DESC;

\echo '--- 12. Витрина: самые активные клиенты'
SELECT * FROM mart.rep_client_activity ORDER BY total_spent DESC LIMIT 10;

\echo '--- 13. Витрина: открытые договоры и просрочки'
SELECT * FROM mart.rep_open_rentals ORDER BY start_at;

\echo '--- 14. Витрина: показатели сотрудников'
SELECT * FROM mart.rep_employee_kpi ORDER BY revenue DESC;

\echo '--- 15. Витрина: спрос по дням недели'
SELECT * FROM mart.rep_weekday_demand ORDER BY day_of_week;

\echo '--- 16. Витрина: состояние парка инвентаря на даты снимков (PIT)'
SELECT snapshot_date,
       sum(items) FILTER (WHERE status = 'на складе') AS "на складе",
       sum(items) FILTER (WHERE status = 'в прокате') AS "в прокате",
       sum(items) FILTER (WHERE status = 'в ремонте') AS "в ремонте",
       sum(items) FILTER (WHERE status = 'списан')    AS "списан",
       sum(items)                                     AS "всего"
FROM mart.rep_equipment_status_snapshot
GROUP BY snapshot_date ORDER BY snapshot_date;

\echo '--- 17. Витрина: платежи по видам и способам оплаты'
SELECT * FROM mart.rep_payments ORDER BY payment_type, amount DESC;
