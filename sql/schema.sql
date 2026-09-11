-- Schema for the IoT telemetry service.
-- Apply with: psql "$DATABASE_URL" -f sql/schema.sql

CREATE TABLE IF NOT EXISTS telemetry_readings (
    id           BIGSERIAL PRIMARY KEY,
    device_id    VARCHAR(128)      NOT NULL,
    recorded_at  TIMESTAMPTZ       NOT NULL,
    temperature  DOUBLE PRECISION  NOT NULL,
    latitude     DOUBLE PRECISION  NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude    DOUBLE PRECISION  NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    ingested_at  TIMESTAMPTZ       NOT NULL DEFAULT now()
);

-- Telemetry is almost always queried "latest readings for device X" or
-- "readings for device X in a time range", so index on that pair.
CREATE INDEX IF NOT EXISTS idx_telemetry_device_time
    ON telemetry_readings (device_id, recorded_at DESC);
