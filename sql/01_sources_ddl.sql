-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Структура операционных систем-источников

---------------------------------------------------------------------------
-- CRM
---------------------------------------------------------------------------
CREATE TABLE src_crm.client (
    passport_number varchar(11)  PRIMARY KEY,          -- серия и номер паспорта
    last_name       varchar(50)  NOT NULL,
    first_name      varchar(50)  NOT NULL,
    middle_name     varchar(50),
    birth_date      date         NOT NULL,
    phone           varchar(20)  NOT NULL,
    email           varchar(100),
    registered_at   timestamp    NOT NULL
);

CREATE TABLE src_crm.client_profile (
    passport_number varchar(11)  PRIMARY KEY REFERENCES src_crm.client,
    height_cm       smallint     NOT NULL,
    weight_kg       smallint     NOT NULL,
    boot_size       numeric(3,1) NOT NULL,
    skill_level     varchar(20)  NOT NULL CHECK (skill_level IN ('новичок','средний','продвинутый','эксперт')),
    updated_at      timestamp    NOT NULL
);

---------------------------------------------------------------------------
-- Склад и сервисная мастерская
---------------------------------------------------------------------------
CREATE TABLE src_warehouse.equipment (
    inventory_number varchar(10)   PRIMARY KEY,        -- инвентарный номер (маркировка на изделии)
    equipment_type   varchar(40)   NOT NULL,
    brand            varchar(30)   NOT NULL,
    model            varchar(40)   NOT NULL,
    size             varchar(10)   NOT NULL,           -- ростовка, размер ботинка или шлема
    season_year      smallint      NOT NULL,
    purchase_price   numeric(10,2) NOT NULL,
    purchase_date    date          NOT NULL
);

CREATE TABLE src_warehouse.equipment_state (
    inventory_number  varchar(10)  PRIMARY KEY REFERENCES src_warehouse.equipment,
    condition         varchar(30)  NOT NULL,
    status            varchar(20)  NOT NULL CHECK (status IN ('на складе','в прокате','в ремонте','списан')),
    last_service_date date,
    service_note      varchar(100),
    updated_at        timestamp    NOT NULL
);

---------------------------------------------------------------------------
-- Основная система проката
---------------------------------------------------------------------------
CREATE TABLE src_rental.employee (
    personnel_number varchar(10)  PRIMARY KEY,         -- табельный номер
    full_name        varchar(100) NOT NULL,
    position         varchar(50)  NOT NULL,
    hire_date        date         NOT NULL
);

CREATE TABLE src_rental.tariff (
    tariff_code    varchar(10)   PRIMARY KEY,
    tariff_name    varchar(60)   NOT NULL,
    equipment_type varchar(40)   NOT NULL,
    time_unit      varchar(10)   NOT NULL CHECK (time_unit IN ('час','сутки')),
    price          numeric(10,2) NOT NULL,             -- текущая цена за единицу времени
    deposit_amount numeric(10,2) NOT NULL
);

CREATE TABLE src_rental.rental (
    rental_number   varchar(10) PRIMARY KEY,           -- номер договора проката
    client_passport varchar(11) NOT NULL,              -- ключ клиента из CRM
    employee_number varchar(10) NOT NULL REFERENCES src_rental.employee,
    start_at        timestamp   NOT NULL,
    planned_end_at  timestamp   NOT NULL,
    actual_end_at   timestamp,
    deposit_type    varchar(20) NOT NULL,
    status          varchar(10) NOT NULL CHECK (status IN ('открыт','закрыт'))
);

CREATE TABLE src_rental.rental_item (
    rental_number    varchar(10) REFERENCES src_rental.rental,
    inventory_number varchar(10),                      -- ключ инвентаря из складской системы
    tariff_code      varchar(10) NOT NULL REFERENCES src_rental.tariff,
    issued_at        timestamp   NOT NULL,
    returned_at      timestamp,
    units_charged    smallint,
    amount           numeric(10,2),
    damage_fee       numeric(10,2),
    return_condition varchar(40),
    PRIMARY KEY (rental_number, inventory_number)
);

CREATE TABLE src_rental.payment (
    receipt_number varchar(10)   PRIMARY KEY,          -- номер кассового чека
    rental_number  varchar(10)   NOT NULL REFERENCES src_rental.rental,
    paid_at        timestamp     NOT NULL,
    amount         numeric(10,2) NOT NULL,
    payment_method varchar(20)   NOT NULL,
    payment_type   varchar(40)   NOT NULL
);
