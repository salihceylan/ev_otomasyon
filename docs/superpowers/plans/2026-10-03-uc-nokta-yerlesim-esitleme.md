# Uç Nokta Yerleşim Eşitleme (WP-L) Uygulama Planı

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bulut `endpoints` satırları (daire kullanıcısının ekranındaki kontroller), panonun `state` mesajında bildirdiği gerçek yerleşimden (tip, panjur çifti, kanal sayısı, ad) otomatik oluşsun ve güncel kalsın.

**Architecture:** Köprü (`mqtt_bridge.js`) canlı `state` COMMIT'inden sonra hata yalıtımlı bir servisi çağırır. Servis (`endpoint_layout_sync.js`) saf plan fonksiyonunu (`utils/endpoint_layout.js`) kullanıp tek transaction'da satırları uzlaştırır. Pano yazılımı ve Flutter değişmez.

**Tech Stack:** Node.js ≥ 20 (`node:test`, `node:assert/strict`), PostgreSQL (pg), mevcut `KeyedWorkQueue`.

**Tasarım belgesi (kuralların tek doğruluk kaynağı):** `docs/superpowers/specs/2026-10-03-uc-nokta-yerlesim-esitleme-design.md`

**Çalışma dizini:** tüm komutlar `server/` içinden. Gerçek PostgreSQL: `postgresql://postgres@127.0.0.1:55432/<db>` (özel örnek; QA yığınının 54329 portuna dokunma).

---

## Dosya yapısı

| Dosya | Durum | Sorumluluk |
|---|---|---|
| `server/src/utils/endpoint_layout.js` | yeni (yazıldı) | Saf çekirdek: yük doğrulama, plan, ad/oda kuralları |
| `server/src/services/endpoint_layout_sync.js` | yeni | Servis: önbellek, kuyruk, transaction, denetim kaydı |
| `server/src/mqtt_bridge.js` | değişir | Kanca: yerleşimi çıkar, canlı state sonrası servisi çağır |
| `server/migrations/031_endpoint_layout_sync.sql` | yeni | `devices.reported_layout`, `devices.reported_layout_at` |
| `server/test/layout/endpoint_layout.test.js` | yeni | Saf çekirdek testleri |
| `server/test/layout/migration_031.test.js` | yeni | Göçün statik testi |
| `server/test/layout/layout_sync.test.js` | yeni | Servis testleri (sahte db) |
| `server/test/layout/layout_bridge.test.js` | yeni | Köprü kancası testleri |
| `server/test/layout/layout_pg.test.js` | yeni | Gerçek PostgreSQL testleri (`EV_PG_TEST_URL` ile açılır) |
| `docs/CONTRACTS.md`, `docs/DEPLOY_RUNBOOK.md`, `server/.env.example` | değişir | Sözleşme §2.4b, §6, §7; göç notu; kapatma anahtarı |

Dokunulmayacaklar: `lib/**`, `android/**`, `ios/**`, pano yazılımı, `tools/qa_stack/**`, `server/src/services/device_service.js`.

---

### Task 1: Saf çekirdeğin testleri

**Files:**
- Test: `server/test/layout/endpoint_layout.test.js` (yeni)
- Modify (yalnız tasarım belgesinden sapma bulunursa): `server/src/utils/endpoint_layout.js`

Beklenen değerler **tasarım belgesi §5'ten** türetilir, koddan değil. Test başarısızsa önce belgeye bak: kod belgeden sapıyorsa kodu düzelt; belge belirsizse raporla.

- [ ] **Step 1: Yardımcıları yaz.** Varsayılan pano yükünü üreten `fwState(overrides)`:

```js
const FW_NAMES = ['Salon Panjur (Yukari)', 'Salon Panjur (Asagi)', 'Oda Panjur (Yukari)', 'Oda Panjur (Asagi)',
  'Salon Aydinlatma', 'Mutfak Aydinlatma', 'Koridor Aydinlatma', 'Balkon Aydinlatma'];
const FW_TYPES = ['shutter_up', 'shutter_down', 'shutter_up', 'shutter_down', 'light', 'light', 'light', 'light'];
function fwState({ names = FW_NAMES, types = FW_TYPES, v = 2, shutters } = {}) {
  const relays = types.map((type, i) => ({ id: i + 1, name: names[i], type, state: false }));
  const pairs = [];
  for (let p = 1; p <= Math.floor(types.length / 2); p += 1) if (types[2 * p - 2] === 'shutter_up') pairs.push(p);
  return { v, uid: 'AHBU-S3-A1B2C3', relays, shutters: shutters || pairs.map((pair) => ({ pair, pos: 0, moving: false, dir: 0, target: 255 })), dis: [] };
}
```

ve tohum satırlarını üreten `seedRows(n = 8)` (`seedDefaults` kullanır; `id: 'ep-' + c`).

- [ ] **Step 2: `extractReportedLayout` testleri** (her biri ayrı `test(...)`):
  - varsayılan yük → `count 8`, `pairs [1,2]`, `relays[4]` = `{id:5,type:'light',name:'Salon Aydinlatma',state:false}`
  - `v: 1`, `v` yok, `relays` dizi değil, `shutters` yok → `null`
  - 41 röle → `null`; 0 röle → `null`
  - yinelenen id, id 0, id N+1, boşluklu id (1,2,4) → `null`
  - bilinmeyen `type` (`'plug'`, `'shutter'`, `7`) → `null`; `state: 1` → `null`
  - yetim panjur: 1 = `shutter_up`, 2 = `light` → `null`; ters: 1 = `shutter_down`, 2 = `shutter_up` → `null`
  - 9 röle, 9. röle `shutter_up` → `null`
  - `shutters[]` tiplerle uyuşmuyor (fazla çift, eksik çift, yinelenen çift) → `null`
  - `pos` geçersizse çift yine sayılır ama `shutterPos`'a girmez
  - ad temizliği: içinde NUL (U+0000) ve sağdan-sola değiştirici (U+202E) ile fazla boşluk bulunan `Mutfak … Spot` → `'Mutfak Spot'` (test içinde bu karakterleri `String.fromCharCode(0)` ve `String.fromCharCode(0x202e)` ile üret; kaynak dosyaya görünmez karakter YAZMA); 150 karakter → 100; `name` yok → `''`
  - imza: ad ya da tip değişince değişir, `state` değişince **değişmez**

- [ ] **Step 3: `planLayoutSync` testleri** (tasarım §5.2–§5.6 tablolarının her satırı):
  1. Tohum satırları + varsayılan pano → `changed false`, `updates []`, `inserts []`, `baseChanged true` (taban ilk kez yazılır)
  2. Aynı girdi + taban = yeni taban → `changed false`, `baseChanged false` (idempotent)
  3. 5-6 panjur (adlar `'Salon (Yukari)'`, `'Salon (Asagi)'`) → iki update: `type 'shutter'`, `shutter_pair_index 3`, `shutter_duration_sec 20`, adlar pano adları, oda `'Salon'`; `ruleRelayChannels [5,6]`
  4. 1-2 lamba (adlar `'Röle 1 Aydınlatma'`, `'Röle 2 Aydınlatma'`) → `type 'light'`, çift/süre `null`, `current_position 0`, oda `'Genel'`; `ruleShutterPairs [1]`
  5. Sınıf değişti ama pano adı fabrika adı (kanal 1-2 lamba, adlar hâlâ `'Salon Panjur (Yukari)'`) → ad `'Röle 1'`, `'Röle 2'`
  6. Röle 7 `impulse` → `type 'impulse'`, ad/oda değişmez, kural listeleri boş
  7. Satır `plug`, pano `light` → değişiklik yok; satır `plug`, pano `impulse` → `impulse`
  8. Yalnız ad: pano 6 = `'Mutfak Spot'`, bulut şablon adı, taban yok → ad `'Mutfak Spot'`, oda `'Mutfak'`
  9. Ad özel, bulut adı kullanıcıya ait (`'Tezgah'`), taban yok → korunur
  10. Taban `'Mutfak Spot'`, pano `'Mutfak Tezgah'`, bulut kullanıcıya ait `'Tezgah'` → `'Mutfak Tezgah'` (son yazan)
  11. Taban = pano = `'Mutfak Spot'`, bulut `'Tezgah'` → korunur
  12. Taban `'Mutfak Spot'`, pano fabrika adına döndü, bulut `'Mutfak Spot'` → `'Mutfak Aydınlatma'`, oda `'Mutfak'`
  13. Oda kullanıcıya ait (`'Teras'`), ad değişti → oda korunur
  14. Ad `'Yatak Odası Lamba'` → oda `'Yatak Odası'`; ad `'Spot 3'` → oda `'Genel'`
  15. 16 röle bildirildi, 8 satır var → 8 insert (ad `'Ek Modül Röle 1'..'8'`, `type 'light'`, oda `'Genel'`)
  16. 8 röle bildirildi, 16 satır var, `confirmShrink false` → `deletes []`, `pendingShrink true`
  17. Aynı, `confirmShrink true` → 8 delete, `deleteAbove 8`, `ruleRelayChannels [9..16]`
  18. Mevcut panjur satırında süre 37 → korunur; `shutter_pair_index null` → çift numarası yazılır
  19. Pano değişimi: taban `null`, satır adları özel, pano fabrika adları → adlar korunur
  20. Yeniden tohumlama: taban = pano (özel adlar), satırlar şablon adları → pano adları yeniden alınır

- [ ] **Step 4: Yardımcı fonksiyon testleri:** `foldName('Salon Panjur (Yukari)') === foldName('Salon Panjur Yukarı')`; `foldName('IŞIK') === 'isik'`; `deriveRoom` (`'Yatak Odası Panjur (Yukari)'` → `'Yatak Odası'`, `'Oda Panjur Aşağı'` → `'Oda'`, `'Odak Lamba'` → `null`, `''` → `null`); `seedDefaults(1..9)`; `parseBase` (nesne, dizge, bozuk → `null`).

- [ ] **Step 5: Tohum tutarlılığı testi:** `seedDefaults(1..9).name` değerlerinin her biri `server/src/services/device_service.js` kaynak metninde geçmeli (iki şablonun ayrışmasını yakalar). Pano tarafı için: `firmwareDefaultName(1..8)` değerleri `ev_otomasyon_servis_yazilimi/waveshare_s3_demo/src/ConfigManager.cpp` metninde geçmeli.

- [ ] **Step 6: Çalıştır.**

Run: `node --test test/layout/endpoint_layout.test.js`
Expected: tüm testler geçer. Geçmeyen test varsa: belge mi kod mu haklı, karar ver; kodu düzelttiysen gerekçeyi rapora yaz.

- [ ] **Step 7: Mutasyon denetimi (en az 3):** çekirdekte bir kuralı kasıtlı boz (ör. `isCloudAutoName` her zaman `true`), ilgili testin KIRMIZI olduğunu gör, geri al. Rapora yaz.

---

### Task 2: Göç 031

**Files:**
- Create: `server/migrations/031_endpoint_layout_sync.sql`
- Test: `server/test/layout/migration_031.test.js`
- Modify (gerekirse): şema sözleşmesi/listesi tutan test ve betikler (`server/scripts/lib/sql_contract.js`, `server/test/bridge/schema_contract.test.js`, `server/test/devices/sql_schema_lint.test.js`, `server/test/bridge/infra_static.test.js`, `server/test/bridge/migrate.test.js`): yalnız yeni göç yüzünden kırılıyorsa.

- [ ] **Step 1: Göçü yaz** (030'un başlık biçimiyle; `BEGIN/COMMIT` YOK):

```sql
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout_at TIMESTAMPTZ;

COMMENT ON COLUMN devices.reported_layout IS 'Panonun en son UYGULANAN yerlesim bildirimi (WP-L): {"v":1,"relays":[{"id","type","name"}]}; NULL = bu panoyla hic esitlenmedi';
COMMENT ON COLUMN devices.reported_layout_at IS 'reported_layout son yazilma zamani';
```

- [ ] **Step 2: Statik test** (`test/peace/peace_migration.test.js` desenini izle): dosya adı tek, `BEGIN`/`COMMIT` içermez, iki `ADD COLUMN IF NOT EXISTS` vardır, `endpoints`/`homes` tablosuna dokunmaz, sıralamada 030'dan sonra gelir.

- [ ] **Step 3: Gerçek PostgreSQL'de uygula ve idempotency'yi kanıtla.**

Run (PowerShell):
```
$env:DATABASE_URL='postgresql://postgres@127.0.0.1:55432/evy_mig'; $env:MIGRATE_CONFIRM='evy_mig'; node scripts/migrate.js
node scripts/migrate.js --status
```
Expected: 001..031 uygulanır; ikinci çalıştırmada bekleyen yok. Ardından 031 dosyasının SQL'ini aynı veritabanında doğrudan ikinci kez çalıştır (pg ile) → hata yok.

- [ ] **Step 4: Bağımlı testleri çalıştır.**

Run: `node --test test/layout/migration_031.test.js test/bridge/migrate.test.js test/bridge/schema_contract.test.js test/bridge/infra_static.test.js test/devices/migrations.test.js test/devices/sql_schema_lint.test.js test/service_panel/migrations.test.js test/peace/peace_migration.test.js`
Expected: hepsi geçer. Yeni göç yüzünden kırılan liste/sözleşme varsa güncelle (yalnız 031'i ekleyerek).

---

### Task 3: Servis `endpoint_layout_sync.js`

**Files:**
- Create: `server/src/services/endpoint_layout_sync.js`
- Test: `server/test/layout/layout_sync.test.js`

Şablon: `server/src/services/device_reconciler.js` (kurucu bağımlılıkları, `_log`, `stats`, `stop`, `whenIdle`, GC) ve testleri `server/test/bridge/reconcile.test.js`.

- [ ] **Step 1: Sabitler ve SQL** (dışa aktarılır; testler eşitlikle eşler):

```js
const RECHECK_MS = 5 * 60 * 1000;      // ayni imza icin kilitsiz dogrulama araligi (cihaz basina)
const MIN_RUN_INTERVAL_MS = 5 * 1000;  // cihaz basina iki calisma arasi en az sure
const SHRINK_CONFIRM_MS = 20 * 1000;   // kuculme ancak bu kadar sonra ikinci kez gorulunce silinir
const CACHE_IDLE_MS = 60 * 60 * 1000;  // bu kadar gorulmeyen cihaz kaydi bellekten atilir
const GC_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_HOMES = 2;
const MAX_PENDING = 20000;
const AUDIT_EVENT = 'endpoint_layout_synced';

const SQL = Object.freeze({
  device: 'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout FROM devices d WHERE d.id = $1',
  deviceLocked: 'SELECT d.id, d.home_id, d.device_uuid, d.reported_layout FROM devices d WHERE d.id = $1 FOR UPDATE',
  rows:
    'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
    'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index',
  rowsLocked:
    'SELECT e.id, e.channel_index, e.name, e.type, e.room, e.shutter_pair_index, e.shutter_duration_sec ' +
    'FROM endpoints e WHERE e.device_id = $1 ORDER BY e.channel_index FOR UPDATE',
  insertRow:
    'INSERT INTO endpoints (home_id, device_id, channel_index, name, type, room, shutter_pair_index, ' +
    'shutter_duration_sec, current_state, current_position) ' +
    'VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) ON CONFLICT (device_id, channel_index) DO NOTHING',
  updateRow:
    'UPDATE endpoints SET name = $3, type = $4, room = $5, shutter_pair_index = $6, shutter_duration_sec = $7, ' +
    'current_position = COALESCE($8::int, current_position), updated_at = CURRENT_TIMESTAMP ' +
    'WHERE id = $1 AND device_id = $2',
  deleteAbove: 'DELETE FROM endpoints WHERE device_id = $1 AND channel_index > $2',
  disableRules:
    'UPDATE scheduled_rules SET enabled = FALSE ' +
    'WHERE home_id = $1 AND (device_id IS NULL OR device_id = $2) AND enabled = TRUE ' +
    "AND ((channel_type = 'relay' AND channel = ANY($3::int[])) OR (channel_type = 'shutter' AND channel = ANY($4::int[]))) " +
    'RETURNING id',
  saveBase: 'UPDATE devices SET reported_layout = $2::jsonb, reported_layout_at = CURRENT_TIMESTAMP WHERE id = $1',
  audit:
    'INSERT INTO device_audit_logs (event, device_uuid, home_id, actor_user_id, actor_role, ip_address, details) ' +
    "VALUES ($1, $2, $3, NULL, 'device', NULL, $4::jsonb)",
});
```

`updateRow` parametreleri: satırın mevcut değerleri üzerine `set` bindirilerek TAM değerler verilir; `$8` yalnız `set.current_position` varsa sayı, yoksa `null`.

- [ ] **Step 2: Davranış** (her madde için önce test yaz, kırmızı gör, sonra uygula):
  1. `onLiveState({topicId, homeId, deviceId, layout})`: durmuşsa / `layout` yoksa / `deviceId` yoksa hiçbir şey yapmaz. ASLA hata fırlatmaz.
  2. Önbellek kaydı `{ sig, homeId, checkedAt, lastRunAt, pendingShrink }`. `sig` aynı, `homeId` aynı, `pendingShrink` false ve `now - checkedAt < RECHECK_MS` ise → sorgu YOK.
  3. `now - lastRunAt < MIN_RUN_INTERVAL_MS` ise → atlanır (sayaç `rateLimited`); sonraki mesaj yeniden dener.
  4. Aksi halde ev anahtarlı kuyruğa (`coalesce: true`) iş atılır.
  5. İş: kilitsiz `SQL.device` + `SQL.rows`. Cihaz yok ya da `home_id` farklı → önbellek kaydı silinir, `skipped`. `parseBase(reported_layout)` → `planLayoutSync(...)` (`confirmShrink` = küçülme onayı, aşağıda).
  6. `plan.changed` false ve `plan.baseChanged` false → yazma yok (`noop`).
  7. Aksi halde `db.withTransaction`: `SQL.deviceLocked` → `SQL.rowsLocked` → plan YENİDEN hesaplanır (kilitli taze veriyle) → `deleteAbove` (varsa) → `updateRow`'lar → `insertRow`'lar → kural listeleri boş değilse `disableRules` → `baseChanged` ise `saveBase` → `plan.changed` ise `audit` (ayrıntı: `{relays, inserted, retyped, renamed, reroomed, deleted, rules_disabled: [id...]}`; AD İÇERMEZ).
  8. Küçülme onayı: `plan.pendingShrink` ilk görüldüğünde `{count, since}` kaydedilir ve satır silinmez; aynı `count` en az `SHRINK_CONFIRM_MS` sonra yeniden görülürse `confirmShrink = true`. Bildirilen sayı satırları kapsayınca kayıt silinir. `pendingShrink` sürerken önbellek "tamam" sayılmaz (sonraki mesaj yeniden girer).
  9. Hata: yakalanır, `errors` sayacı artar, tek satır uyarı (10 dk'da bir), önbellek güncellenmez (sonraki mesaj yeniden dener; `MIN_RUN_INTERVAL_MS` yine geçerli).
  10. Günlük: `[LAYOUT] cihaz=<8 hane> ev=<8 hane> eklendi=1 tip=2 ad=2 oda=1 silindi=0 kural=1` (ad, konu kimliği, uid YAZILMAZ).
  11. `stats()`: `{ devices, checks, applied, noops, skipped, rateLimited, errors, inserted, retyped, renamed, deleted, rulesDisabled, queue }`.
  12. `invalidate(deviceId)`, `stop()` (kuyruk temizlenir, sonraki çağrılar yok sayılır), `whenIdle(ms)`, `syncNow(evt)` (test/operatör: önbellek ve hız sınırını atlayıp işi kuyrukta çalıştırır, sonucu döndürür).
  13. Bellek: `CACHE_IDLE_MS` boyunca görülmeyen kayıtlar `GC_INTERVAL_MS`'te bir temizlenir (zamanlayıcı yok; `onLiveState` içinde).

- [ ] **Step 3: Testler** (`makeFakeDb` deseni `test/bridge/reconcile.test.js`'ten): yukarıdaki 13 maddenin her biri + transaction içinde SQL sırası + ikinci çağrıda sıfır sorgu + `withTransaction` hata fırlatınca `onLiveState`'in fırlatmaması.

Run: `node --test test/layout/layout_sync.test.js`
Expected: hepsi geçer.

---

### Task 4: Köprü kancası

**Files:**
- Modify: `server/src/mqtt_bridge.js` (kurucu, `handleIncomingMessage`, `_processState`, `getStatus`, `end`, üretim tekili)
- Test: `server/test/layout/layout_bridge.test.js`

- [ ] **Step 1: Kurucu.** `opts.layoutSyncer` (hazır örnek, test) ya da `opts.layoutSync === true` (tembel oluşturma). Varsayılan KAPALI (mevcut testlerin `new MqttBridge({...})` örnekleri ek sorgu üretmez).

- [ ] **Step 2: Tembel oluşturma** `_getLayoutSync()` (`_getReconciler()` deseni). Ortam değişkeni `ENDPOINT_LAYOUT_SYNC` değeri `off` / `0` / `false` (büyük-küçük harf duyarsız) ise oluşturulmaz. Yüklenemezse köprü etkilenmez (`_warnOnce`).

- [ ] **Step 3: `handleIncomingMessage`.** `validateStatePayload` başarılı olduktan sonra, eşitleme etkinse `const layout = extractReportedLayout(obj)` hesaplanır ve `_processState(parsed.topicId, check.value, retain, layout)` çağrılır (kuyruk birleştirmesi en yeni kapanışı kullanır).

- [ ] **Step 4: `_processState(topicId, v, retain, layout = null)`.** Uzlaştırıcı bildiriminden hemen sonra, yalnız `!retain && layout` ise ve cihaz çözüldüyse:

```js
this._notifyLayoutSync({ topicId, homeId: device.home_id, deviceId: device.device_id, layout });
```

`_notifyLayoutSync` try/catch ile sarılıdır (`_warnOnce('layout-notify', ...)`). DİKKAT: `_processState` içinde `if (!deviceUpdate && !childLockReconcile && !relayUpdate && !shutterUpdate) return;` erken dönüşü vardır; canlı state'te `deviceUpdate` her zaman dolu olduğundan kanca atlanmaz, bunu testle kanıtla.

- [ ] **Step 5: `getStatus()`** → `status.layout_sync = stats()`; **`end()`** → servis `stop()` (enjekte edilmediyse örnek atılır).

- [ ] **Step 6: Üretim tekili:** `new MqttBridge({ reconcile: true, layoutSync: true })`. Dosya başındaki açıklama bloğuna 3-4 satırlık "YERLESIM ESITLEME" maddesi ekle; `relays[].type metindir (kopru kullanmaz)` cümlesini güncelle.

- [ ] **Step 7: Testler:**
  - canlı state + geçerli yerleşim → `onLiveState` bir kez, doğru `homeId`/`deviceId`/`layout.count` ile
  - retained state → çağrılmaz
  - yerleşimsiz/bozuk yük (tip yok, yetim çift) → çağrılmaz, ama durum güncellemesi yine yapılır
  - bilinmeyen `uid` → çağrılmaz
  - `layoutSyncer.onLiveState` hata fırlatır → köprü sayaçları/DB güncellemesi etkilenmez
  - eşitleme kapalı (`layoutSync` yok) → ana yolun sorgu sayısı ve metinleri öncekiyle aynı
  - `ENDPOINT_LAYOUT_SYNC=off` → servis oluşturulmaz
  - `getStatus().layout_sync` var; `end()` sonrası `stop` çağrılmış
  - gerçek pano yükü örneği (`test/bridge/bridge_firmware_contract.test.js`'teki sabit) `extractReportedLayout`'tan geçer

Run: `node --test test/layout/layout_bridge.test.js test/bridge/bridge_messages.test.js test/bridge/bridge_payload.test.js test/bridge/bridge_firmware_contract.test.js test/bridge/reconcile.test.js test/bridge/bridge_integration.test.js`
Expected: hepsi geçer (mevcut köprü testleri DEĞİŞMEDEN).

---

### Task 5: Gerçek PostgreSQL testleri

**Files:**
- Test: `server/test/layout/layout_pg.test.js` (desen: `server/test/bridge/reconcile_pg.test.js`; `EV_PG_TEST_URL` yoksa ATLANIR)

Önkoşul: `evy_pg` veritabanına 031 uygulanmış olmalı:
```
$env:DATABASE_URL='postgresql://postgres@127.0.0.1:55432/evy_pg'; $env:MIGRATE_CONFIRM='evy_pg'; node scripts/migrate.js
```

- [ ] **Step 1: Fikstür:** her test kendi ev + cihaz + tohum satırlarını açar (tohum için `device_service` içindeki şablonla aynı değerler: `seedDefaults`), sonunda siler.

- [ ] **Step 2: Testler** (servis `createEndpointLayoutSync({ db })` + `syncNow`):
  1. Varsayılan pano → satırlar değişmez, `devices.reported_layout` yazılır, denetim kaydı YOK
  2. 5-6 panjur → iki satır `shutter`, çift 3, süre 20; kimlikler (`id`) aynı kalır; denetim kaydı 1 satır
  3. İkinci kez aynı bildirim → sıfır yazma (`updated_at` değişmez)
  4. 1-2 lamba → çift/süre `NULL`, konum 0
  5. Zamanlı kural: kanal 5'e `relay/on` kuralı + çift 1'e `shutter/open` kuralı; 5-6 panjur + 1-2 lamba bildirimi → ikisi de `enabled = FALSE`; başka kanala yazılmış kural etkilenmez
  6. Ek modül: 16 röle → 8 yeni satır; sonra 8 röle → ilk bildirimde silinmez, onaydan sonra silinir
  7. Ad kuralları (taban ile): pano adı özel → alınır; `PUT` benzeri kullanıcı adı (`UPDATE endpoints SET name`) → sonraki aynı bildirimde korunur; pano adı değişince pano adı kazanır
  8. Yarış: kilitsiz okumadan sonra, transaction'dan önce başka bağlantı satır adını değiştirir → sonuç kilitli veriye göre hesaplanır (kullanıcı adı ezilmez)
  9. Cihaz başka eve taşınmış (`home_id` farklı) → hiçbir şey yazılmaz
  10. `endpoints` CHECK/UNIQUE ihlali yok: 40 röle (20 panjur çifti) bildirimi uygulanır
  11. Köprü uçtan uca: `MqttBridge({ db, layoutSync: true })` + `handleIncomingMessage('ev/<t>/state', yük, {retain:false})` → satırlar eşitlenir; `{retain:true}` → eşitlenmez

Run (PowerShell): `$env:EV_PG_TEST_URL='postgresql://postgres@127.0.0.1:55432/evy_pg'; node --test test/layout/layout_pg.test.js`
Expected: hepsi geçer, atlanan yok.

---

### Task 6: Belgeler

**Files:**
- Modify: `docs/CONTRACTS.md` (yeni `### 2.4b Yerleşim eşitleme (pano → bulut uç noktaları)`; §6'ya `ENDPOINT_LAYOUT_SYNC`; §7'ye WP-L satırı; §2.4'teki "köprü kullanmaz" ifadesi güncellenir), `docs/DEPLOY_RUNBOOK.md` (031 notu, yalnız göç listesi/adımı varsa), `server/.env.example` (`# ENDPOINT_LAYOUT_SYNC=off` açıklamalı satır)

- [ ] **Step 1:** Yalnız KODDA var olanı yaz; her iddia için dosya:satır doğrula. Mevcut bölüm numaralarını değiştirme. Tasarım belgesi §5 kurallarını özetle, ayrıntı için tasarım belgesine bağ ver.
- [ ] **Step 2:** `node --test test/peace/peace_integration.test.js test/bridge/infra_static.test.js` (belge/örnek dosya denetimleri) → geçer.

---

### Task 7: İnceleme, düzeltme, kapı

- [ ] **Step 1: Üç bağımsız inceleme** (doğruluk/veri güvenliği; eşzamanlılık/kötüye kullanım; tasarım uyumu/test kalitesi). Her bulgu: dosya:satır + somut başarısızlık senaryosu.
- [ ] **Step 2: Düzeltme:** doğrulanan bulgular için önce kırmızı test, sonra düzeltme.
- [ ] **Step 3: Kapı:**

Run:
```
npm test
npm run lint:syntax
$env:EV_PG_TEST_URL='postgresql://postgres@127.0.0.1:55432/evy_gate'   # 001..031 uygulanmış temiz veritabanı
npm test
```
Expected: 0 kırık; PG'siz koşuda yalnız PG testleri atlanır; PG'li koşuda `layout_pg` dahil hepsi geçer.
