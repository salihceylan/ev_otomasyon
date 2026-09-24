CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS mqtt_users (
    username VARCHAR(100) PRIMARY KEY,
    password_hash VARCHAR(100) NOT NULL,
    is_superuser BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO mqtt_users (username, password_hash, is_superuser)
VALUES 
    ('backend_service', encode(digest('GudeBackend2026!MqttSec', 'sha256'), 'hex'), true),
    ('home_101', encode(digest('PassHome101!Sec', 'sha256'), 'hex'), false),
    ('home_102', encode(digest('PassHome102!Sec', 'sha256'), 'hex'), false)
ON CONFLICT (username) DO UPDATE 
SET password_hash = EXCLUDED.password_hash,
    is_superuser = EXCLUDED.is_superuser;

