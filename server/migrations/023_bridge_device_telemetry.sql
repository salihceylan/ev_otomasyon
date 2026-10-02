-- ==============================================================================
-- Migration 023: MQTT koprusu cihaz telemetrisi (WP-C, denetim 2026-10-01)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR (migrate.js tek transaction).
--
--   * devices.last_ack_id / last_ack_at: cihazin `state.last_id` ile geri yankiladigi SON komut
--     kimligi ve ne zaman ilk goruldugu (CONTRACTS §2.3/§2.4). Komutun cihazca uygulandiginin
--     sunucu tarafi kaydi; kopru yazar, teshis/denetim okur.
--   * (last_seen_at) indeksi: kopru 120 sn sessiz kalan cihazlari cevrimdisi isaretler; tarama
--     yalnizca cevrimici satirlari dolasir.

ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_ack_id VARCHAR(32);
ALTER TABLE devices ADD COLUMN IF NOT EXISTS last_ack_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_devices_online_last_seen ON devices (last_seen_at) WHERE is_online = TRUE;

COMMENT ON COLUMN devices.last_ack_id IS 'Cihazin state.last_id ile yankiladigi son komut kimligi (kopru yazar)';
COMMENT ON COLUMN devices.last_ack_at IS 'last_ack_id degistigi an (ilk gorulme); kalp atislari ilerletmez';
