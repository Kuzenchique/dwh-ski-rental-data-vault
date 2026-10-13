-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Витрины данных: виртуальная схема «звезда» и отчётные представления (SQL views)

---------------------------------------------------------------------------
-- ИЗМЕРЕНИЯ (актуальные версии сателлитов)
---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.dim_client AS
SELECT encode(h.client_hk, 'hex')                         AS client_key,
       h.passport_number,
       c.last_name || ' ' || c.first_name || coalesce(' ' || c.middle_name, '') AS full_name,
       c.birth_date,
       CASE WHEN date_part('year', age(DATE '2026-01-01', c.birth_date)) < 25 THEN 'до 25 лет'
            WHEN date_part('year', age(DATE '2026-01-01', c.birth_date)) < 35 THEN '25–34 года'
            WHEN date_part('year', age(DATE '2026-01-01', c.birth_date)) < 45 THEN '35–44 года'
            ELSE '45 лет и старше' END                    AS age_group,
       c.phone, c.email,
       p.height_cm, p.weight_kg, p.boot_size, p.skill_level,
       h.load_date                                        AS first_loaded_at
FROM raw_vault.hub_client h
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_client_crm s
                   WHERE s.client_hk = h.client_hk ORDER BY s.load_date DESC LIMIT 1) c ON true
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_client_profile s
                   WHERE s.client_hk = h.client_hk ORDER BY s.load_date DESC LIMIT 1) p ON true;

CREATE OR REPLACE VIEW mart.dim_equipment AS
SELECT encode(h.equipment_hk, 'hex') AS equipment_key,
       h.inventory_number,
       d.equipment_type, d.brand, d.model, d.size, d.season_year,
       d.purchase_price, d.purchase_date,
       s.condition, s.status, s.last_service_date
FROM raw_vault.hub_equipment h
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_equipment_details x
                   WHERE x.equipment_hk = h.equipment_hk ORDER BY x.load_date DESC LIMIT 1) d ON true
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_equipment_state x
                   WHERE x.equipment_hk = h.equipment_hk ORDER BY x.load_date DESC LIMIT 1) s ON true;

CREATE OR REPLACE VIEW mart.dim_tariff AS
SELECT encode(h.tariff_hk, 'hex') AS tariff_key,
       h.tariff_code, t.tariff_name, t.equipment_type, t.time_unit,
       t.price AS current_price, t.deposit_amount
FROM raw_vault.hub_tariff h
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_tariff x
                   WHERE x.tariff_hk = h.tariff_hk ORDER BY x.load_date DESC LIMIT 1) t ON true;

CREATE OR REPLACE VIEW mart.dim_employee AS
SELECT encode(h.employee_hk, 'hex') AS employee_key,
       h.personnel_number, e.full_name, e.position, e.hire_date
FROM raw_vault.hub_employee h
LEFT JOIN LATERAL (SELECT * FROM raw_vault.sat_employee x
                   WHERE x.employee_hk = h.employee_hk ORDER BY x.load_date DESC LIMIT 1) e ON true;

CREATE OR REPLACE VIEW mart.dim_date AS
SELECT to_char(d, 'YYYYMMDD')::int                 AS date_key,
       d::date                                     AS full_date,
       extract(year FROM d)::int                   AS year,
       extract(month FROM d)::int                  AS month,
       (ARRAY['Январь','Февраль','Март','Апрель','Май','Июнь','Июль','Август',
              'Сентябрь','Октябрь','Ноябрь','Декабрь'])[extract(month FROM d)::int] AS month_name,
       extract(isodow FROM d)::int                 AS day_of_week,
       (ARRAY['Пн','Вт','Ср','Чт','Пт','Сб','Вс'])[extract(isodow FROM d)::int] AS day_name,
       extract(isodow FROM d) >= 6                 AS is_weekend,
       CASE WHEN extract(month FROM d) >= 7
            THEN extract(year FROM d)::int || '/' || (extract(year FROM d)::int + 1)
            ELSE (extract(year FROM d)::int - 1) || '/' || extract(year FROM d)::int END AS season
FROM generate_series(DATE '2025-11-01', DATE '2026-05-31', INTERVAL '1 day') AS d;

---------------------------------------------------------------------------
-- ФАКТ: позиция договора проката (зерно — одна единица инвентаря в договоре)
---------------------------------------------------------------------------
CREATE OR REPLACE VIEW mart.fact_rental_item AS
SELECT hr.rental_number,
       encode(l.rental_item_hk, 'hex')           AS rental_item_key,
       encode(rc.client_hk, 'hex')               AS client_key,
       encode(l.equipment_hk, 'hex')             AS equipment_key,
       encode(l.tariff_hk, 'hex')                AS tariff_key,
       encode(re.employee_hk, 'hex')             AS employee_key,
       to_char(si.issued_at, 'YYYYMMDD')::int    AS date_key,
       si.issued_at, si.returned_at,
       round(extract(epoch FROM si.returned_at - si.issued_at) / 3600, 2) AS hours_in_rent,
       si.units_charged,
       si.amount,
       si.damage_fee,
       round(si.amount / nullif(si.units_charged, 0), 2) AS unit_price,
       si.return_condition
FROM raw_vault.lnk_rental_item l
JOIN raw_vault.hub_rental hr ON hr.rental_hk = l.rental_hk
JOIN raw_vault.lnk_rental_client   rc ON rc.rental_hk = l.rental_hk
JOIN raw_vault.lnk_rental_employee re ON re.rental_hk = l.rental_hk
JOIN LATERAL (SELECT * FROM raw_vault.sat_rental_item s
              WHERE s.rental_item_hk = l.rental_item_hk ORDER BY s.load_date DESC LIMIT 1) si ON true;

---------------------------------------------------------------------------
-- ОТЧЁТНЫЕ ВИТРИНЫ
---------------------------------------------------------------------------
-- Выручка по месяцам и типам инвентаря
CREATE OR REPLACE VIEW mart.rep_revenue_by_month AS
SELECT d.year, d.month, d.month_name, e.equipment_type,
       count(DISTINCT f.rental_number) AS rentals,
       count(*)                        AS items,
       sum(f.amount)                   AS rental_revenue,
       sum(f.damage_fee)               AS damage_revenue
FROM mart.fact_rental_item f
JOIN mart.dim_date d      USING (date_key)
JOIN mart.dim_equipment e USING (equipment_key)
WHERE f.returned_at IS NOT NULL
GROUP BY d.year, d.month, d.month_name, e.equipment_type;

-- Эффективность единиц инвентаря: загрузка и окупаемость
CREATE OR REPLACE VIEW mart.rep_equipment_efficiency AS
SELECT e.inventory_number, e.equipment_type, e.brand || ' ' || e.model AS model, e.size,
       e.status, e.condition, e.purchase_price,
       count(f.rental_item_key)                    AS times_rented,
       coalesce(sum(f.hours_in_rent), 0)           AS hours_in_rent,
       coalesce(sum(f.amount), 0)                  AS revenue,
       round(100 * coalesce(sum(f.amount), 0) / e.purchase_price, 1) AS payback_pct
FROM mart.dim_equipment e
LEFT JOIN mart.fact_rental_item f ON f.equipment_key = e.equipment_key AND f.returned_at IS NOT NULL
GROUP BY e.inventory_number, e.equipment_type, e.brand, e.model, e.size, e.status, e.condition, e.purchase_price;

-- Клиенты: частота визитов и выручка
CREATE OR REPLACE VIEW mart.rep_client_activity AS
SELECT c.full_name, c.phone, c.skill_level, c.age_group,
       count(DISTINCT f.rental_number)          AS rentals,
       sum(f.amount) + sum(f.damage_fee)        AS total_spent,
       round((sum(f.amount) + sum(f.damage_fee)) / count(DISTINCT f.rental_number), 0) AS avg_check,
       max(f.issued_at)::date                   AS last_visit
FROM mart.fact_rental_item f
JOIN mart.dim_client c USING (client_key)
WHERE f.returned_at IS NOT NULL
GROUP BY c.full_name, c.phone, c.skill_level, c.age_group;

-- Открытые договоры и просрочки на дату последней загрузки (из Business Vault)
CREATE OR REPLACE VIEW mart.rep_open_rentals AS
SELECT h.rental_number, c.full_name, c.phone,
       r.start_at, r.planned_end_at,
       string_agg(e.inventory_number, ', ' ORDER BY e.inventory_number) AS equipment,
       bv.paid_amount AS prepaid,
       bv.is_overdue,
       CASE WHEN bv.is_overdue
            THEN round(extract(epoch FROM bv.load_date - r.planned_end_at) / 3600, 1) END AS overdue_hours
FROM raw_vault.hub_rental h
JOIN LATERAL (SELECT * FROM business_vault.sat_rental_calc x
              WHERE x.rental_hk = h.rental_hk ORDER BY x.load_date DESC LIMIT 1) bv ON true
JOIN LATERAL (SELECT * FROM raw_vault.sat_rental x
              WHERE x.rental_hk = h.rental_hk ORDER BY x.load_date DESC LIMIT 1) r ON true
JOIN raw_vault.lnk_rental_client rc ON rc.rental_hk = h.rental_hk
JOIN mart.dim_client c ON c.client_key = encode(rc.client_hk, 'hex')
JOIN raw_vault.lnk_rental_item li ON li.rental_hk = h.rental_hk
JOIN raw_vault.hub_equipment e ON e.equipment_hk = li.equipment_hk
WHERE NOT bv.is_closed
GROUP BY h.rental_number, c.full_name, c.phone, r.start_at, r.planned_end_at, bv.paid_amount, bv.is_overdue,
         bv.load_date;

-- Показатели сотрудников проката
CREATE OR REPLACE VIEW mart.rep_employee_kpi AS
SELECT emp.personnel_number, emp.full_name, emp.position,
       count(DISTINCT f.rental_number)              AS rentals,
       count(*)                                     AS items_issued,
       sum(f.amount)                                AS revenue,
       round(sum(f.amount) / count(DISTINCT f.rental_number), 0) AS avg_rental_amount
FROM mart.fact_rental_item f
JOIN mart.dim_employee emp USING (employee_key)
WHERE f.returned_at IS NOT NULL
GROUP BY emp.personnel_number, emp.full_name, emp.position;

-- Спрос по дням недели
CREATE OR REPLACE VIEW mart.rep_weekday_demand AS
SELECT d.day_of_week, d.day_name,
       count(DISTINCT d.full_date)                        AS days_with_rentals,
       count(DISTINCT f.rental_number)                    AS rentals,
       round(count(DISTINCT f.rental_number)::numeric / count(DISTINCT d.full_date), 1) AS avg_rentals_per_day,
       sum(f.amount)                                      AS revenue
FROM mart.fact_rental_item f
JOIN mart.dim_date d USING (date_key)
GROUP BY d.day_of_week, d.day_name;

-- История цен тарифов (из сателлита: каждая версия с периодом действия в хранилище)
CREATE OR REPLACE VIEW mart.rep_tariff_price_history AS
SELECT h.tariff_code, s.tariff_name, s.time_unit, s.price,
       s.load_date AS valid_from,
       lead(s.load_date) OVER (PARTITION BY s.tariff_hk ORDER BY s.load_date) AS valid_to
FROM raw_vault.sat_tariff s
JOIN raw_vault.hub_tariff h USING (tariff_hk);

-- Состояние парка инвентаря на дату каждого снимка (через PIT-таблицу)
CREATE OR REPLACE VIEW mart.rep_equipment_status_snapshot AS
SELECT p.snapshot_date::date AS snapshot_date, s.status, count(*) AS items
FROM business_vault.pit_equipment p
JOIN raw_vault.sat_equipment_state s
  ON s.equipment_hk = p.equipment_hk AND s.load_date = p.sat_equipment_state_ld
GROUP BY p.snapshot_date, s.status;

-- Способы оплаты
CREATE OR REPLACE VIEW mart.rep_payments AS
SELECT s.payment_type, s.payment_method, count(*) AS receipts, sum(s.amount) AS amount
FROM raw_vault.hub_payment h
JOIN LATERAL (SELECT * FROM raw_vault.sat_payment x
              WHERE x.payment_hk = h.payment_hk ORDER BY x.load_date DESC LIMIT 1) s ON true
GROUP BY s.payment_type, s.payment_method;
