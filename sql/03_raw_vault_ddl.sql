-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Raw Data Vault: 6 хабов, 4 ссылки, 9 сателлитов

---------------------------------------------------------------------------
-- ХАБЫ: хеш бизнес-ключа (PK), бизнес-ключ, load_date, record_source
---------------------------------------------------------------------------
CREATE TABLE raw_vault.hub_client (
    client_hk       bytea       PRIMARY KEY,
    load_date       timestamp   NOT NULL,
    record_source   varchar(50) NOT NULL,
    passport_number varchar(11) NOT NULL UNIQUE
);

CREATE TABLE raw_vault.hub_equipment (
    equipment_hk     bytea       PRIMARY KEY,
    load_date        timestamp   NOT NULL,
    record_source    varchar(50) NOT NULL,
    inventory_number varchar(10) NOT NULL UNIQUE
);

CREATE TABLE raw_vault.hub_tariff (
    tariff_hk     bytea       PRIMARY KEY,
    load_date     timestamp   NOT NULL,
    record_source varchar(50) NOT NULL,
    tariff_code   varchar(10) NOT NULL UNIQUE
);

CREATE TABLE raw_vault.hub_employee (
    employee_hk      bytea       PRIMARY KEY,
    load_date        timestamp   NOT NULL,
    record_source    varchar(50) NOT NULL,
    personnel_number varchar(10) NOT NULL UNIQUE
);

CREATE TABLE raw_vault.hub_rental (
    rental_hk     bytea       PRIMARY KEY,
    load_date     timestamp   NOT NULL,
    record_source varchar(50) NOT NULL,
    rental_number varchar(10) NOT NULL UNIQUE
);

CREATE TABLE raw_vault.hub_payment (
    payment_hk     bytea       PRIMARY KEY,
    load_date      timestamp   NOT NULL,
    record_source  varchar(50) NOT NULL,
    receipt_number varchar(10) NOT NULL UNIQUE
);

---------------------------------------------------------------------------
-- ССЫЛКИ: хеш комбинации ключей (PK), ключи связываемых хабов, метаданные
---------------------------------------------------------------------------
-- Договор проката ↔ клиент
CREATE TABLE raw_vault.lnk_rental_client (
    rental_client_hk bytea       PRIMARY KEY,
    load_date        timestamp   NOT NULL,
    record_source    varchar(50) NOT NULL,
    rental_hk        bytea       NOT NULL REFERENCES raw_vault.hub_rental,
    client_hk        bytea       NOT NULL REFERENCES raw_vault.hub_client
);

-- Договор проката ↔ сотрудник, оформивший выдачу
CREATE TABLE raw_vault.lnk_rental_employee (
    rental_employee_hk bytea       PRIMARY KEY,
    load_date          timestamp   NOT NULL,
    record_source      varchar(50) NOT NULL,
    rental_hk          bytea       NOT NULL REFERENCES raw_vault.hub_rental,
    employee_hk        bytea       NOT NULL REFERENCES raw_vault.hub_employee
);

-- Позиция договора: договор ↔ единица инвентаря ↔ тариф
CREATE TABLE raw_vault.lnk_rental_item (
    rental_item_hk bytea       PRIMARY KEY,
    load_date      timestamp   NOT NULL,
    record_source  varchar(50) NOT NULL,
    rental_hk      bytea       NOT NULL REFERENCES raw_vault.hub_rental,
    equipment_hk   bytea       NOT NULL REFERENCES raw_vault.hub_equipment,
    tariff_hk      bytea       NOT NULL REFERENCES raw_vault.hub_tariff
);

-- Платёж ↔ договор проката
CREATE TABLE raw_vault.lnk_payment_rental (
    payment_rental_hk bytea       PRIMARY KEY,
    load_date         timestamp   NOT NULL,
    record_source     varchar(50) NOT NULL,
    payment_hk        bytea       NOT NULL REFERENCES raw_vault.hub_payment,
    rental_hk         bytea       NOT NULL REFERENCES raw_vault.hub_rental
);

CREATE INDEX ON raw_vault.lnk_rental_client  (client_hk);
CREATE INDEX ON raw_vault.lnk_rental_item    (rental_hk);
CREATE INDEX ON raw_vault.lnk_rental_item    (equipment_hk);
CREATE INDEX ON raw_vault.lnk_payment_rental (rental_hk);

---------------------------------------------------------------------------
-- САТЕЛЛИТЫ: ключ родителя + load_date (PK), hash_diff, описательные атрибуты
---------------------------------------------------------------------------
-- Клиент: персональные и контактные данные (CRM)
CREATE TABLE raw_vault.sat_client_crm (
    client_hk     bytea       NOT NULL REFERENCES raw_vault.hub_client,
    load_date     timestamp   NOT NULL,
    record_source varchar(50) NOT NULL,
    hash_diff     bytea       NOT NULL,
    last_name     varchar(50),
    first_name    varchar(50),
    middle_name   varchar(50),
    birth_date    date,
    phone         varchar(20),
    email         varchar(100),
    registered_at timestamp,
    PRIMARY KEY (client_hk, load_date)
);

-- Клиент: антропометрия и уровень катания (CRM, меняется чаще контактов)
CREATE TABLE raw_vault.sat_client_profile (
    client_hk     bytea        NOT NULL REFERENCES raw_vault.hub_client,
    load_date     timestamp    NOT NULL,
    record_source varchar(50)  NOT NULL,
    hash_diff     bytea        NOT NULL,
    height_cm     smallint,
    weight_kg     smallint,
    boot_size     numeric(3,1),
    skill_level   varchar(20),
    updated_at    timestamp,
    PRIMARY KEY (client_hk, load_date)
);

-- Инвентарь: паспортные данные изделия (склад, практически не меняются)
CREATE TABLE raw_vault.sat_equipment_details (
    equipment_hk   bytea         NOT NULL REFERENCES raw_vault.hub_equipment,
    load_date      timestamp     NOT NULL,
    record_source  varchar(50)   NOT NULL,
    hash_diff      bytea         NOT NULL,
    equipment_type varchar(40),
    brand          varchar(30),
    model          varchar(40),
    size           varchar(10),
    season_year    smallint,
    purchase_price numeric(10,2),
    purchase_date  date,
    PRIMARY KEY (equipment_hk, load_date)
);

-- Инвентарь: техническое состояние и статус (сервисная мастерская, меняется часто)
CREATE TABLE raw_vault.sat_equipment_state (
    equipment_hk      bytea        NOT NULL REFERENCES raw_vault.hub_equipment,
    load_date         timestamp    NOT NULL,
    record_source     varchar(50)  NOT NULL,
    hash_diff         bytea        NOT NULL,
    condition         varchar(30),
    status            varchar(20),
    last_service_date date,
    service_note      varchar(100),
    updated_at        timestamp,
    PRIMARY KEY (equipment_hk, load_date)
);

-- Тариф: наименование и цена (история изменения цен)
CREATE TABLE raw_vault.sat_tariff (
    tariff_hk      bytea         NOT NULL REFERENCES raw_vault.hub_tariff,
    load_date      timestamp     NOT NULL,
    record_source  varchar(50)   NOT NULL,
    hash_diff      bytea         NOT NULL,
    tariff_name    varchar(60),
    equipment_type varchar(40),
    time_unit      varchar(10),
    price          numeric(10,2),
    deposit_amount numeric(10,2),
    PRIMARY KEY (tariff_hk, load_date)
);

-- Сотрудник
CREATE TABLE raw_vault.sat_employee (
    employee_hk   bytea        NOT NULL REFERENCES raw_vault.hub_employee,
    load_date     timestamp    NOT NULL,
    record_source varchar(50)  NOT NULL,
    hash_diff     bytea        NOT NULL,
    full_name     varchar(100),
    position      varchar(50),
    hire_date     date,
    PRIMARY KEY (employee_hk, load_date)
);

-- Договор проката: сроки, залог, статус
CREATE TABLE raw_vault.sat_rental (
    rental_hk      bytea       NOT NULL REFERENCES raw_vault.hub_rental,
    load_date      timestamp   NOT NULL,
    record_source  varchar(50) NOT NULL,
    hash_diff      bytea       NOT NULL,
    start_at       timestamp,
    planned_end_at timestamp,
    actual_end_at  timestamp,
    deposit_type   varchar(20),
    status         varchar(10),
    PRIMARY KEY (rental_hk, load_date)
);

-- Позиция договора (сателлит ссылки): выдача, возврат, начисления
CREATE TABLE raw_vault.sat_rental_item (
    rental_item_hk   bytea         NOT NULL REFERENCES raw_vault.lnk_rental_item,
    load_date        timestamp     NOT NULL,
    record_source    varchar(50)   NOT NULL,
    hash_diff        bytea         NOT NULL,
    issued_at        timestamp,
    returned_at      timestamp,
    units_charged    smallint,
    amount           numeric(10,2),
    damage_fee       numeric(10,2),
    return_condition varchar(40),
    PRIMARY KEY (rental_item_hk, load_date)
);

-- Платёж
CREATE TABLE raw_vault.sat_payment (
    payment_hk     bytea         NOT NULL REFERENCES raw_vault.hub_payment,
    load_date      timestamp     NOT NULL,
    record_source  varchar(50)   NOT NULL,
    hash_diff      bytea         NOT NULL,
    paid_at        timestamp,
    amount         numeric(10,2),
    payment_method varchar(20),
    payment_type   varchar(40),
    PRIMARY KEY (payment_hk, load_date)
);
