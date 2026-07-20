-- Run once when the timescaledb container first initializes.
--
-- Creates the per-environment databases used by the lab's three Ignition
-- gateways. The "ignition_local_development" database is created by Postgres' own
-- POSTGRES_DB env var (set in docker-compose.yaml), so we only need to
-- create test + production here.
--
-- Note: CREATE DATABASE can't run inside a transaction block (and therefore
-- can't be wrapped in a DO $$ ... $$ block), so these are bare DDL. This
-- script runs once on first volume init, so idempotency isn't critical.

CREATE DATABASE ignition_test;
CREATE DATABASE ignition_production;
