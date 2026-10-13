-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Staging area: таблицы повторяют структуру источников, но без ограничений
-- (NOT NULL, PK, FK, CHECK), чтобы принимать даже неполные данные.
-- Дополнительно содержат хеши бизнес-ключей, hash_diff, время загрузки и источник.

---------------------------------------------------------------------------
-- Хеш-функции (MD5 → bytea, 16 байт)
---------------------------------------------------------------------------
-- Хеш бизнес-ключа: значения нормализуются (trim + upper), разделитель «||»
CREATE OR REPLACE FUNCTION etl.hash_key(VARIADIC parts text[])
RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
    SELECT decode(md5(array_to_string(
             ARRAY(SELECT coalesce(upper(trim(p)), '') FROM unnest(parts) AS p), '||')), 'hex')
$$;

-- Хеш описательных атрибутов (hash diff): регистр значим, NULL кодируется явно
CREATE OR REPLACE FUNCTION etl.hash_diff(VARIADIC parts text[])
RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
    SELECT decode(md5(array_to_string(
             ARRAY(SELECT coalesce(trim(p), '^') FROM unnest(parts) AS p), '||')), 'hex')
$$;

---------------------------------------------------------------------------
-- CRM
---------------------------------------------------------------------------
CREATE TABLE stage.crm_client (
    passport_number text, last_name text, first_name text, middle_name text,
    birth_date date, phone text, email text, registered_at timestamp,
    client_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.crm_client_profile (
    passport_number text, height_cm smallint, weight_kg smallint, boot_size numeric(3,1),
    skill_level text, updated_at timestamp,
    client_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

---------------------------------------------------------------------------
-- Склад и сервис
---------------------------------------------------------------------------
CREATE TABLE stage.wh_equipment (
    inventory_number text, equipment_type text, brand text, model text, size text,
    season_year smallint, purchase_price numeric(10,2), purchase_date date,
    equipment_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.wh_equipment_state (
    inventory_number text, condition text, status text, last_service_date date,
    service_note text, updated_at timestamp,
    equipment_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

---------------------------------------------------------------------------
-- Основная система проката
---------------------------------------------------------------------------
CREATE TABLE stage.app_employee (
    personnel_number text, full_name text, position text, hire_date date,
    employee_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.app_tariff (
    tariff_code text, tariff_name text, equipment_type text, time_unit text,
    price numeric(10,2), deposit_amount numeric(10,2),
    tariff_hk bytea, hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.app_rental (
    rental_number text, client_passport text, employee_number text,
    start_at timestamp, planned_end_at timestamp, actual_end_at timestamp,
    deposit_type text, status text,
    rental_hk bytea, client_hk bytea, employee_hk bytea,
    rental_client_hk bytea, rental_employee_hk bytea,
    hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.app_rental_item (
    rental_number text, inventory_number text, tariff_code text,
    issued_at timestamp, returned_at timestamp, units_charged smallint,
    amount numeric(10,2), damage_fee numeric(10,2), return_condition text,
    rental_hk bytea, equipment_hk bytea, tariff_hk bytea, rental_item_hk bytea,
    hash_diff bytea, load_date timestamp, record_source text
);

CREATE TABLE stage.app_payment (
    receipt_number text, rental_number text, paid_at timestamp, amount numeric(10,2),
    payment_method text, payment_type text,
    payment_hk bytea, rental_hk bytea, payment_rental_hk bytea,
    hash_diff bytea, load_date timestamp, record_source text
);
