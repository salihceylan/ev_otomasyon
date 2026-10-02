-- ==============================================================================
-- Migration 026: Cihaz kalp atisi yazma yolu - last_seen_at indeksini kaldir (WP-C, C11)
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir. Icinde BEGIN/COMMIT YOKTUR (migrate.js tek transaction).
--
-- Neden: 023'un kismi indeksi `idx_devices_online_last_seen ON devices (last_seen_at) WHERE is_online`
-- indeksli bir sutunu (last_seen_at) cihazin HER canli state mesajinda gunceller (kalp atisi 30 sn'de bir,
-- degisiklikte ~0.4 sn; CONTRACTS §3b). PostgreSQL indeksli sutun degisince HOT guncellemeyi
-- KULLANAMAZ: her yazma devices'in TUM indekslerine (pkey, mac, uuid, home, claimed_by, ...) yeni girdi
-- ekler, olu satir ve indeks sismesi uretir.
--
-- Olcum (yerel PostgreSQL 18.4, 600 cihaz x 16 kanal, 4 es zamanli isci, kopru state hatti):
--   indeksli : devices guncellemelerinin  0 / 1493'u HOT, olu satir 1493
--   indeksiz : devices guncellemelerinin 2106 / 2232'si HOT (%94), olu satir 154
--   throughput ayni sinirda (~1.2-1.4 bin mesaj/sn).
-- Indeksin tek kazanci cevrimdisi supurucusunun (30 sn'de bir) taramasiydi; 50.000 cihazli tabloda
-- ardisik tarama ~18 ms surer (EXPLAIN ANALYZE), yani indeks gereksiz.

DROP INDEX IF EXISTS idx_devices_online_last_seen;
