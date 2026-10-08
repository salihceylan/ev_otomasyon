-- ==============================================================================
-- Migration 038: Pano degisimi veri onarimlari (kullanim-4, guvenlik-1), 2026-10-08
-- ==============================================================================
-- IDEMPOTENT: tekrar calistirilabilir (ikinci calistirma hicbir satiri degistirmez). Icinde BEGIN/COMMIT YOKTUR;
-- migration calistiricisi (scripts/migrate.js) dosyayi tek transaction icinde calistirir.
-- psql ile elle calistirilacaksa: psql -1 -v ON_ERROR_STOP=1 -f 038_replace_board_repairs.sql
--
-- Kapsam (yalniz VERI onarimi; sema degismez)
--   1. kullanim-4: pano degisiminde zamanli kurallar eski cihaza bagli kalmisti (device_id = evden ayrilmis eski pano):
--      zamanlayici bu kurallari hic calistirmiyordu. device_replacement_logs (009) kaydiyla eski -> yeni cihaza
--      tasinir. Degisim zincirleri (A -> B -> C) icin en cok 10 tur dongu; etkilenen satir kalmayinca biter.
--      Yalniz: kuralin evi = kaydin evi, eski cihaz artik o evde DEGIL ve yeni cihaz o evde (ya da kendisi de ayni
--      evde degistirilmis ara pano: sonraki tur onu izler). Eslesmeyen kurala DOKUNULMAZ (kodun yeni surumu
--      degisimde ayni transaction'da tasir: device_service.replaceBoard).
--   2. guvenlik-1: evden ayrilmis (pano degisimi / stoga donus) panonun ACIK alarm satirlari kapanmiyordu (gaz
--      bastirmasi kalici, onay imkansiz). Cihazin evi alarmin evinden farkliysa (ya da cihaz evsizse) satir
--      status 'lost' + cleared_by 'detached' olur, onay istegi temizlenir. 033 kisitlari: status CHECK 'lost'u kapsar,
--      cleared_by VARCHAR(16) serbest metindir (CHECK yok): kisit degisikligi GEREKMEZ.
--
-- Bagimlilik (bu dosya DEGISTIRMEZ): 001 (devices), 009 (device_replacement_logs), 011/022 (scheduled_rules),
--   033 (alarms).
-- Rolling deploy: yeni kod da ayni durumu uretmez; eski kod onarilmis satirlari okumaya devam eder.
-- ==============================================================================

-- Satir kilitleri canli trafikte (kopru / zamanlayici UPDATE'leri) uzun beklemesin: 5 sn'de vazgec, yeniden denenir.
SET LOCAL lock_timeout = '5s';

-- 1. kullanim-4: eski cihaza bagli kalmis zamanli kurallar -> degisim kaydindaki yeni cihaz (zincir icin 10 tur)
DO $$
DECLARE
  n integer;
BEGIN
  FOR i IN 1..10 LOOP
    UPDATE scheduled_rules sr
       SET device_id = nd.id, updated_at = NOW()
      FROM devices od
      JOIN device_replacement_logs l ON l.old_device_uuid = od.device_uuid
      JOIN devices nd ON nd.device_uuid = l.new_device_uuid
     WHERE sr.device_id = od.id
       AND l.home_id = sr.home_id
       AND od.home_id IS DISTINCT FROM sr.home_id
       -- hedef evde OLMALI; ya da kendisi de ayni evde degistirilmis bir ara pano olmali (zincirin sonraki turu)
       AND (nd.home_id = sr.home_id
            OR EXISTS (SELECT 1 FROM device_replacement_logs l2
                        WHERE l2.old_device_uuid = nd.device_uuid AND l2.home_id = sr.home_id));
    GET DIAGNOSTICS n = ROW_COUNT;
    EXIT WHEN n = 0;
  END LOOP;
END
$$;

-- 2. guvenlik-1: evden ayrilmis panonun acik alarm satirlari kapanir
UPDATE alarms a
   SET status = 'lost', cleared_at = NOW(), cleared_by = 'detached',
       ack_requested_at = NULL, ack_requested_by = NULL, updated_at = NOW()
  FROM devices d
 WHERE d.id = a.device_id
   AND d.home_id IS DISTINCT FROM a.home_id
   AND a.status NOT IN ('cleared', 'lost');
