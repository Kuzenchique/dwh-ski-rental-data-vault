-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Business Vault: переработанные данные, построенные по тем же принципам, что и Raw Vault

-- Расчётный сателлит договора проката: агрегаты по позициям и платежам
CREATE TABLE business_vault.sat_rental_calc (
    rental_hk      bytea         NOT NULL REFERENCES raw_vault.hub_rental,
    load_date      timestamp     NOT NULL,
    record_source  varchar(50)   NOT NULL,
    hash_diff      bytea         NOT NULL,
    items_count    smallint,                 -- количество единиц инвентаря в договоре
    duration_hours numeric(8,2),             -- фактическая длительность проката, ч
    charged_amount numeric(10,2),            -- начислено за прокат
    damage_amount  numeric(10,2),            -- начислено за повреждения
    paid_amount    numeric(10,2),            -- оплачено по чекам
    balance        numeric(10,2),            -- задолженность (+) / переплата (−)
    is_closed      boolean,
    is_overdue     boolean,                  -- не возвращён после планового срока
    PRIMARY KEY (rental_hk, load_date)
);

-- PIT-таблица (Point-In-Time) клиента: какие версии сателлитов актуальны на дату снимка
CREATE TABLE business_vault.pit_client (
    client_hk             bytea     NOT NULL REFERENCES raw_vault.hub_client,
    snapshot_date         timestamp NOT NULL,
    sat_client_crm_ld     timestamp,
    sat_client_profile_ld timestamp,
    PRIMARY KEY (client_hk, snapshot_date)
);

-- PIT-таблица инвентаря
CREATE TABLE business_vault.pit_equipment (
    equipment_hk             bytea     NOT NULL REFERENCES raw_vault.hub_equipment,
    snapshot_date            timestamp NOT NULL,
    sat_equipment_details_ld timestamp,
    sat_equipment_state_ld   timestamp,
    PRIMARY KEY (equipment_hk, snapshot_date)
);
