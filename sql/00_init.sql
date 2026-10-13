-- Лабораторная работа «Хранилище данных Data Vault», вариант 15
-- Система учёта проката на лыжной базе
-- Создание схем. Выполняется в БД ski_rental_dwh (CREATE DATABASE ski_rental_dwh ENCODING 'UTF8';)

DROP SCHEMA IF EXISTS mart, business_vault, raw_vault, stage, etl,
                      src_rental, src_crm, src_warehouse CASCADE;

-- Операционные системы-источники (эмулируются отдельными схемами)
CREATE SCHEMA src_rental;     -- основная система проката (касса, договоры, тарифы, сотрудники)
CREATE SCHEMA src_crm;        -- CRM: клиенты и их антропометрия
CREATE SCHEMA src_warehouse;  -- склад и сервисная мастерская: инвентарь и его состояние

-- Слои хранилища
CREATE SCHEMA stage;          -- Staging area
CREATE SCHEMA raw_vault;      -- Raw Data Vault: хабы, ссылки, сателлиты
CREATE SCHEMA business_vault; -- Business Vault: расчётные сателлиты, PIT-таблицы
CREATE SCHEMA mart;           -- витрины данных (представления)
CREATE SCHEMA etl;            -- процедуры загрузки и журнал загрузок
