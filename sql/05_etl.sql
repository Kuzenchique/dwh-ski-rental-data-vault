-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- ETL: источники → stage → Raw Vault → Business Vault
-- Загрузка только добавляет строки (insert-only), данные не агрегируются и не пересчитываются.

---------------------------------------------------------------------------
-- Журнал загрузок
---------------------------------------------------------------------------
CREATE TABLE etl.load_batch (
    batch_id    serial    PRIMARY KEY,
    load_date   timestamp NOT NULL UNIQUE,
    started_at  timestamp NOT NULL DEFAULT clock_timestamp(),
    finished_at timestamp
);

CREATE TABLE etl.load_log (
    batch_id     int         NOT NULL REFERENCES etl.load_batch,
    layer        varchar(20) NOT NULL,
    target_table varchar(60) NOT NULL,
    rows_loaded  bigint      NOT NULL,
    PRIMARY KEY (batch_id, target_table)
);

CREATE OR REPLACE PROCEDURE etl.log(p_batch int, p_layer text, p_table text, p_rows bigint)
LANGUAGE sql AS $$
    INSERT INTO etl.load_log VALUES (p_batch, p_layer, p_table, p_rows);
$$;

---------------------------------------------------------------------------
-- 1. Staging area: полная выгрузка источников + вычисление хешей
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.fill_stage(p_batch int, p_load_date timestamp)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    TRUNCATE stage.crm_client, stage.crm_client_profile, stage.wh_equipment, stage.wh_equipment_state,
             stage.app_employee, stage.app_tariff, stage.app_rental, stage.app_rental_item, stage.app_payment;

    INSERT INTO stage.crm_client
    SELECT c.*, etl.hash_key(c.passport_number),
           etl.hash_diff(c.last_name, c.first_name, c.middle_name, c.birth_date::text,
                         c.phone, c.email, c.registered_at::text),
           p_load_date, 'crm.client'
    FROM src_crm.client c;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.crm_client', n);

    INSERT INTO stage.crm_client_profile
    SELECT p.*, etl.hash_key(p.passport_number),
           etl.hash_diff(p.height_cm::text, p.weight_kg::text, p.boot_size::text, p.skill_level, p.updated_at::text),
           p_load_date, 'crm.client_profile'
    FROM src_crm.client_profile p;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.crm_client_profile', n);

    INSERT INTO stage.wh_equipment
    SELECT e.*, etl.hash_key(e.inventory_number),
           etl.hash_diff(e.equipment_type, e.brand, e.model, e.size, e.season_year::text,
                         e.purchase_price::text, e.purchase_date::text),
           p_load_date, 'warehouse.equipment'
    FROM src_warehouse.equipment e;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.wh_equipment', n);

    INSERT INTO stage.wh_equipment_state
    SELECT s.*, etl.hash_key(s.inventory_number),
           etl.hash_diff(s.condition, s.status, s.last_service_date::text, s.service_note, s.updated_at::text),
           p_load_date, 'warehouse.equipment_state'
    FROM src_warehouse.equipment_state s;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.wh_equipment_state', n);

    INSERT INTO stage.app_employee
    SELECT e.*, etl.hash_key(e.personnel_number),
           etl.hash_diff(e.full_name, e.position, e.hire_date::text),
           p_load_date, 'rental.employee'
    FROM src_rental.employee e;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.app_employee', n);

    INSERT INTO stage.app_tariff
    SELECT t.*, etl.hash_key(t.tariff_code),
           etl.hash_diff(t.tariff_name, t.equipment_type, t.time_unit, t.price::text, t.deposit_amount::text),
           p_load_date, 'rental.tariff'
    FROM src_rental.tariff t;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.app_tariff', n);

    INSERT INTO stage.app_rental
    SELECT r.*,
           etl.hash_key(r.rental_number),
           etl.hash_key(r.client_passport),
           etl.hash_key(r.employee_number),
           etl.hash_key(r.rental_number, r.client_passport),
           etl.hash_key(r.rental_number, r.employee_number),
           etl.hash_diff(r.start_at::text, r.planned_end_at::text, r.actual_end_at::text, r.deposit_type, r.status),
           p_load_date, 'rental.rental'
    FROM src_rental.rental r;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.app_rental', n);

    INSERT INTO stage.app_rental_item
    SELECT i.*,
           etl.hash_key(i.rental_number),
           etl.hash_key(i.inventory_number),
           etl.hash_key(i.tariff_code),
           etl.hash_key(i.rental_number, i.inventory_number, i.tariff_code),
           etl.hash_diff(i.issued_at::text, i.returned_at::text, i.units_charged::text, i.amount::text,
                         i.damage_fee::text, i.return_condition),
           p_load_date, 'rental.rental_item'
    FROM src_rental.rental_item i;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.app_rental_item', n);

    INSERT INTO stage.app_payment
    SELECT p.*,
           etl.hash_key(p.receipt_number),
           etl.hash_key(p.rental_number),
           etl.hash_key(p.receipt_number, p.rental_number),
           etl.hash_diff(p.paid_at::text, p.amount::text, p.payment_method, p.payment_type),
           p_load_date, 'rental.payment'
    FROM src_rental.payment p;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'stage', 'stage.app_payment', n);
END $$;

---------------------------------------------------------------------------
-- 2. Хабы: добавляются только новые бизнес-ключи (из всех stage-таблиц, где ключ встречается)
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.load_hubs(p_batch int)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    INSERT INTO raw_vault.hub_client (client_hk, load_date, record_source, passport_number)
    SELECT DISTINCT ON (hk) hk, ld, rs, bk FROM (
        SELECT client_hk hk, load_date ld, record_source rs, passport_number bk, 1 prio FROM stage.crm_client
        UNION ALL
        SELECT client_hk, load_date, record_source, passport_number, 2 FROM stage.crm_client_profile
        UNION ALL
        SELECT client_hk, load_date, record_source, client_passport, 3 FROM stage.app_rental
    ) s
    WHERE bk IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_client h WHERE h.client_hk = s.hk)
    ORDER BY hk, prio;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_client', n);

    INSERT INTO raw_vault.hub_equipment (equipment_hk, load_date, record_source, inventory_number)
    SELECT DISTINCT ON (hk) hk, ld, rs, bk FROM (
        SELECT equipment_hk hk, load_date ld, record_source rs, inventory_number bk, 1 prio FROM stage.wh_equipment
        UNION ALL
        SELECT equipment_hk, load_date, record_source, inventory_number, 2 FROM stage.wh_equipment_state
        UNION ALL
        SELECT equipment_hk, load_date, record_source, inventory_number, 3 FROM stage.app_rental_item
    ) s
    WHERE bk IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_equipment h WHERE h.equipment_hk = s.hk)
    ORDER BY hk, prio;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_equipment', n);

    INSERT INTO raw_vault.hub_tariff (tariff_hk, load_date, record_source, tariff_code)
    SELECT DISTINCT ON (hk) hk, ld, rs, bk FROM (
        SELECT tariff_hk hk, load_date ld, record_source rs, tariff_code bk, 1 prio FROM stage.app_tariff
        UNION ALL
        SELECT tariff_hk, load_date, record_source, tariff_code, 2 FROM stage.app_rental_item
    ) s
    WHERE bk IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_tariff h WHERE h.tariff_hk = s.hk)
    ORDER BY hk, prio;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_tariff', n);

    INSERT INTO raw_vault.hub_employee (employee_hk, load_date, record_source, personnel_number)
    SELECT DISTINCT ON (hk) hk, ld, rs, bk FROM (
        SELECT employee_hk hk, load_date ld, record_source rs, personnel_number bk, 1 prio FROM stage.app_employee
        UNION ALL
        SELECT employee_hk, load_date, record_source, employee_number, 2 FROM stage.app_rental
    ) s
    WHERE bk IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_employee h WHERE h.employee_hk = s.hk)
    ORDER BY hk, prio;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_employee', n);

    INSERT INTO raw_vault.hub_rental (rental_hk, load_date, record_source, rental_number)
    SELECT DISTINCT ON (hk) hk, ld, rs, bk FROM (
        SELECT rental_hk hk, load_date ld, record_source rs, rental_number bk, 1 prio FROM stage.app_rental
        UNION ALL
        SELECT rental_hk, load_date, record_source, rental_number, 2 FROM stage.app_rental_item
        UNION ALL
        SELECT rental_hk, load_date, record_source, rental_number, 3 FROM stage.app_payment
    ) s
    WHERE bk IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_rental h WHERE h.rental_hk = s.hk)
    ORDER BY hk, prio;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_rental', n);

    INSERT INTO raw_vault.hub_payment (payment_hk, load_date, record_source, receipt_number)
    SELECT DISTINCT ON (payment_hk) payment_hk, load_date, record_source, receipt_number
    FROM stage.app_payment s
    WHERE receipt_number IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM raw_vault.hub_payment h WHERE h.payment_hk = s.payment_hk)
    ORDER BY payment_hk;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'hub_payment', n);
END $$;

---------------------------------------------------------------------------
-- 3. Ссылки: добавляются только новые комбинации ключей
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.load_links(p_batch int)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    INSERT INTO raw_vault.lnk_rental_client (rental_client_hk, load_date, record_source, rental_hk, client_hk)
    SELECT DISTINCT ON (rental_client_hk) rental_client_hk, load_date, record_source, rental_hk, client_hk
    FROM stage.app_rental s
    WHERE NOT EXISTS (SELECT 1 FROM raw_vault.lnk_rental_client l WHERE l.rental_client_hk = s.rental_client_hk)
    ORDER BY rental_client_hk;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'lnk_rental_client', n);

    INSERT INTO raw_vault.lnk_rental_employee (rental_employee_hk, load_date, record_source, rental_hk, employee_hk)
    SELECT DISTINCT ON (rental_employee_hk) rental_employee_hk, load_date, record_source, rental_hk, employee_hk
    FROM stage.app_rental s
    WHERE NOT EXISTS (SELECT 1 FROM raw_vault.lnk_rental_employee l WHERE l.rental_employee_hk = s.rental_employee_hk)
    ORDER BY rental_employee_hk;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'lnk_rental_employee', n);

    INSERT INTO raw_vault.lnk_rental_item (rental_item_hk, load_date, record_source, rental_hk, equipment_hk, tariff_hk)
    SELECT DISTINCT ON (rental_item_hk) rental_item_hk, load_date, record_source, rental_hk, equipment_hk, tariff_hk
    FROM stage.app_rental_item s
    WHERE NOT EXISTS (SELECT 1 FROM raw_vault.lnk_rental_item l WHERE l.rental_item_hk = s.rental_item_hk)
    ORDER BY rental_item_hk;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'lnk_rental_item', n);

    INSERT INTO raw_vault.lnk_payment_rental (payment_rental_hk, load_date, record_source, payment_hk, rental_hk)
    SELECT DISTINCT ON (payment_rental_hk) payment_rental_hk, load_date, record_source, payment_hk, rental_hk
    FROM stage.app_payment s
    WHERE NOT EXISTS (SELECT 1 FROM raw_vault.lnk_payment_rental l WHERE l.payment_rental_hk = s.payment_rental_hk)
    ORDER BY payment_rental_hk;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'lnk_payment_rental', n);
END $$;

---------------------------------------------------------------------------
-- 4. Сателлиты: новая версия добавляется, только если hash_diff отличается
--    от последней загруженной версии (или версии ещё нет)
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.load_satellites(p_batch int)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    INSERT INTO raw_vault.sat_client_crm
    SELECT s.client_hk, s.load_date, s.record_source, s.hash_diff, s.last_name, s.first_name, s.middle_name,
           s.birth_date, s.phone, s.email, s.registered_at
    FROM stage.crm_client s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_client_crm t
                       WHERE t.client_hk = s.client_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_client_crm', n);

    INSERT INTO raw_vault.sat_client_profile
    SELECT s.client_hk, s.load_date, s.record_source, s.hash_diff, s.height_cm, s.weight_kg, s.boot_size,
           s.skill_level, s.updated_at
    FROM stage.crm_client_profile s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_client_profile t
                       WHERE t.client_hk = s.client_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_client_profile', n);

    INSERT INTO raw_vault.sat_equipment_details
    SELECT s.equipment_hk, s.load_date, s.record_source, s.hash_diff, s.equipment_type, s.brand, s.model,
           s.size, s.season_year, s.purchase_price, s.purchase_date
    FROM stage.wh_equipment s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_equipment_details t
                       WHERE t.equipment_hk = s.equipment_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_equipment_details', n);

    INSERT INTO raw_vault.sat_equipment_state
    SELECT s.equipment_hk, s.load_date, s.record_source, s.hash_diff, s.condition, s.status,
           s.last_service_date, s.service_note, s.updated_at
    FROM stage.wh_equipment_state s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_equipment_state t
                       WHERE t.equipment_hk = s.equipment_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_equipment_state', n);

    INSERT INTO raw_vault.sat_tariff
    SELECT s.tariff_hk, s.load_date, s.record_source, s.hash_diff, s.tariff_name, s.equipment_type,
           s.time_unit, s.price, s.deposit_amount
    FROM stage.app_tariff s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_tariff t
                       WHERE t.tariff_hk = s.tariff_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_tariff', n);

    INSERT INTO raw_vault.sat_employee
    SELECT s.employee_hk, s.load_date, s.record_source, s.hash_diff, s.full_name, s.position, s.hire_date
    FROM stage.app_employee s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_employee t
                       WHERE t.employee_hk = s.employee_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_employee', n);

    INSERT INTO raw_vault.sat_rental
    SELECT s.rental_hk, s.load_date, s.record_source, s.hash_diff, s.start_at, s.planned_end_at,
           s.actual_end_at, s.deposit_type, s.status
    FROM stage.app_rental s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_rental t
                       WHERE t.rental_hk = s.rental_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_rental', n);

    INSERT INTO raw_vault.sat_rental_item
    SELECT s.rental_item_hk, s.load_date, s.record_source, s.hash_diff, s.issued_at, s.returned_at,
           s.units_charged, s.amount, s.damage_fee, s.return_condition
    FROM stage.app_rental_item s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_rental_item t
                       WHERE t.rental_item_hk = s.rental_item_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_rental_item', n);

    INSERT INTO raw_vault.sat_payment
    SELECT s.payment_hk, s.load_date, s.record_source, s.hash_diff, s.paid_at, s.amount,
           s.payment_method, s.payment_type
    FROM stage.app_payment s
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM raw_vault.sat_payment t
                       WHERE t.payment_hk = s.payment_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM s.hash_diff;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'raw_vault', 'sat_payment', n);
END $$;

---------------------------------------------------------------------------
-- 5. Business Vault: расчётный сателлит договора и PIT-таблицы
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.load_business_vault(p_batch int, p_load_date timestamp)
LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    INSERT INTO business_vault.sat_rental_calc
    WITH r AS (            -- актуальная версия договора
        SELECT DISTINCT ON (rental_hk) rental_hk, start_at, planned_end_at, actual_end_at, status
        FROM raw_vault.sat_rental WHERE load_date <= p_load_date
        ORDER BY rental_hk, load_date DESC
    ), i AS (              -- актуальные версии позиций договора
        SELECT l.rental_hk, count(*) items_count,
               coalesce(sum(s.amount), 0) charged, coalesce(sum(s.damage_fee), 0) damage
        FROM raw_vault.lnk_rental_item l
        JOIN LATERAL (SELECT amount, damage_fee FROM raw_vault.sat_rental_item t
                      WHERE t.rental_item_hk = l.rental_item_hk AND t.load_date <= p_load_date
                      ORDER BY t.load_date DESC LIMIT 1) s ON true
        GROUP BY l.rental_hk
    ), p AS (              -- оплаты по договору
        SELECT l.rental_hk, sum(s.amount) paid
        FROM raw_vault.lnk_payment_rental l
        JOIN LATERAL (SELECT amount FROM raw_vault.sat_payment t
                      WHERE t.payment_hk = l.payment_hk AND t.load_date <= p_load_date
                      ORDER BY t.load_date DESC LIMIT 1) s ON true
        GROUP BY l.rental_hk
    ), calc AS (
        SELECT r.rental_hk,
               i.items_count::smallint AS items_count,
               round(extract(epoch FROM coalesce(r.actual_end_at, p_load_date) - r.start_at) / 3600, 2) AS duration_hours,
               i.charged AS charged_amount,
               i.damage  AS damage_amount,
               coalesce(p.paid, 0) AS paid_amount,
               CASE WHEN r.status = 'закрыт' THEN i.charged + i.damage - coalesce(p.paid, 0) END AS balance,
               r.status = 'закрыт' AS is_closed,
               r.status = 'открыт' AND r.planned_end_at < p_load_date AS is_overdue
        FROM r JOIN i USING (rental_hk) LEFT JOIN p USING (rental_hk)
    )
    SELECT c.rental_hk, p_load_date, 'bv.rental_calc',
           etl.hash_diff(c.items_count::text, c.duration_hours::text, c.charged_amount::text, c.damage_amount::text,
                         c.paid_amount::text, c.balance::text, c.is_closed::text, c.is_overdue::text),
           c.items_count, c.duration_hours, c.charged_amount, c.damage_amount, c.paid_amount, c.balance,
           c.is_closed, c.is_overdue
    FROM calc c
    LEFT JOIN LATERAL (SELECT t.hash_diff FROM business_vault.sat_rental_calc t
                       WHERE t.rental_hk = c.rental_hk ORDER BY t.load_date DESC LIMIT 1) cur ON true
    WHERE cur.hash_diff IS DISTINCT FROM
          etl.hash_diff(c.items_count::text, c.duration_hours::text, c.charged_amount::text, c.damage_amount::text,
                        c.paid_amount::text, c.balance::text, c.is_closed::text, c.is_overdue::text);
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'business_vault', 'sat_rental_calc', n);

    INSERT INTO business_vault.pit_client
    SELECT h.client_hk, p_load_date,
           (SELECT max(load_date) FROM raw_vault.sat_client_crm s     WHERE s.client_hk = h.client_hk AND s.load_date <= p_load_date),
           (SELECT max(load_date) FROM raw_vault.sat_client_profile s WHERE s.client_hk = h.client_hk AND s.load_date <= p_load_date)
    FROM raw_vault.hub_client h
    WHERE h.load_date <= p_load_date;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'business_vault', 'pit_client', n);

    INSERT INTO business_vault.pit_equipment
    SELECT h.equipment_hk, p_load_date,
           (SELECT max(load_date) FROM raw_vault.sat_equipment_details s WHERE s.equipment_hk = h.equipment_hk AND s.load_date <= p_load_date),
           (SELECT max(load_date) FROM raw_vault.sat_equipment_state s   WHERE s.equipment_hk = h.equipment_hk AND s.load_date <= p_load_date)
    FROM raw_vault.hub_equipment h
    WHERE h.load_date <= p_load_date;
    GET DIAGNOSTICS n = ROW_COUNT; CALL etl.log(p_batch, 'business_vault', 'pit_equipment', n);
END $$;

---------------------------------------------------------------------------
-- Полный цикл загрузки одного пакета
---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE etl.run_batch(p_load_date timestamp)
LANGUAGE plpgsql AS $$
DECLARE b int;
BEGIN
    INSERT INTO etl.load_batch (load_date) VALUES (p_load_date) RETURNING batch_id INTO b;
    CALL etl.fill_stage(b, p_load_date);
    CALL etl.load_hubs(b);
    CALL etl.load_links(b);
    CALL etl.load_satellites(b);
    CALL etl.load_business_vault(b, p_load_date);
    UPDATE etl.load_batch SET finished_at = clock_timestamp() WHERE batch_id = b;
END $$;
