# Akış denetimi düzeltmeleri — kararlar, gerçekleşme ve kalan işler

> Tarih: 2026-10-04 · Taban: `daffee9` · Kapsam: sunucu (`server/`), Flutter (`lib/`), firmware + QA simülatörü + fabrika aracı testleri (`ev_otomasyon_servis_yazilimi/`, `tools/qa_stack/`), belgeler.
> Durum: beş ekip ayrı klonda çalıştı, her biri YEREL commit attı (push yok). Birleştirme (entegrasyon), canlı dağıtım, gerçek pano / gerçek telefon denemesi YAPILMADI. Bu belgedeki iddialar ekip raporlarından değil, her klonda `git diff daffee9..HEAD` ve test günlükleriyle doğrulandı; rapor ile kod çeliştiğinde kod esas alındı (§5).
> Sözleşme değişiklikleri: `docs/CONTRACTS.md` (bu commit). Dağıtım: `docs/DEPLOY_RUNBOOK.md` (bu commit).

## 1. Denetim özeti

Üç kullanıcı akışı uçtan uca (istemci ↔ sunucu ↔ firmware) denetlendi; her bulgu bağımsız bir doğrulayıcıdan geçti ve doğrulayıcı ayrıca "kaçırılan" maddeler ekledi.

| Akış | Bulgu | CONFIRMED | PARTIAL | REFUTED | Kaçırılan | Önem |
|---|:-:|:-:|:-:|:-:|:-:|---|
| Servis sorumlusunun iş akışı (`SERVIS-*`) | 7 | 7 | 0 | 0 | 3 (K1–K3) | high 1 (01), medium 1 (02), low 5 |
| Daire kullanıcısının kullanım akışı (`DAIRE-*`) | 5 | 4 | 1 (05) | 0 | 3 (K1–K3) | medium 1 (01), low 4 |
| Üyelik sistemi akışı (`UYELIK-*`) | 11 | 11 | 0 | 0 | 2 (K1–K2) | medium 4 (01–04), low 7 |
| **Toplam** | **23** | **22** | **1** | **0** | **8** | 31 madde |

Sonuç (31 madde): **23** kodla düzeltildi, **3** belgeyle kapatıldı (UYELIK-06, UYELIK-11, DAIRE-04'ün sözleşme kısmı), **2** kontrol listesi sahibine iletildi (SERVIS-05, SERVIS-K3), **2** bilinçli kabul edildi (UYELIK-09, DAIRE-K2; belge notu), **1** bilinçli ertelendi (DAIRE-05; belge notu). Hiçbir düzeltme gerçek pano, canlı sunucu ya da gerçek telefonda denenmedi.

## 2. Ekipler, commit'ler ve test sonuçları

| Ekip | Kapsam | Klon / dal | Commit | Değişiklik | Test (günlükten doğrulandı) |
|---|---|---|---|---|---|
| S1 | Sunucu, cihaz tarafı | `fx-s1` / `akis-fx-s1` | `5b8afda` | 22 dosya, +1982/-89; migration `032` | PG'siz `npm test`: 2004 test, 1879 geçti, 0 kırık, 125 atlandı. PG'li: 6 tam koşunun 3'ü temiz (2004 / 2003 / 0 / 1); diğer 3'ünde dosya düzeyinde Windows süreç çökmesi (`0xC0000409`, alt test hatası yok; taban koşuda da var, dosyalar tek başına geçiyor) |
| S2 | Sunucu, üyelik | `fx-s2` / `akis-fx-s2` | `cd135a8` | 18 dosya, +1786/-148; migration yok | PG'siz 2010 / 1885 / 0 / 125; PG'li 2010 / 2009 / 0 / 1 |
| C1 | Flutter: servis sihirbazı + daire panosu | `fx-c1` / `akis-fx-c1` | `3dcf32f` | 15 dosya, +1069/-34 | `flutter test` +4100 ~485, 0 kırık (taban 4063 + 37 yeni); `flutter analyze` 0 (ekip raporu) |
| C2 | Flutter: üyelik | `fx-c2` / `akis-fx-c2` | `f1e9f33` | 25 dosya, +1618/-66 | `flutter test` +4118 ~485, 0 kırık (taban 4063 + 55 yeni); `flutter analyze` 0 (ekip raporu) |
| F1 | Firmware + QA simülatörü + v1.1.2 | `fx-f1` / `akis-fx-f1` | `9ef99ba` | 26 dosya, +799/-64 (2 ikili) | `tools/qa_stack` `npm test` 430/430 (taban 414); fabrika aracı unittest 358 OK (taban 355); PlatformIO iki temiz derleme, 0 uyarı, aynı SHA-256; `pio test -e native` çalışmadı (gcc yok); firmware Unity testleri MSVC ile 179/179 (ekip raporu) |
| Belge | Bu commit | `evy` / `akis-denetim` | — | `docs/CONTRACTS.md`, `docs/DEPLOY_RUNBOOK.md`, bu belge | — |

Ekipler yalnız kendi dosyalarına yazdı; kaynak dosyalarda ekipler arası çakışma yok (S1 ↔ S2 ve C1 ↔ C2 dosya kümeleri ayrık). Migration numarası `032` yalnız S1'de kullanıldı. **Beşinin birlikte koşusu yapılmadı** (§7).

## 3. Kararlar ve gerçekleşme

### 3.1 Karar haritası

| Karar | Bulgu | Ekip | Durum |
|---|---|---|---|
| D1 | SERVIS-01, K1, K2 (sunucu) | S1 | düzeltildi |
| D2 | DAIRE-01 (sunucu) | S1 | düzeltildi |
| D3 | DAIRE-03, K3 (sunucu) | S1 | düzeltildi |
| D4 | UYELIK-02 (sunucu) | S2 | düzeltildi |
| D5 | UYELIK-03 (sunucu) | S2 | düzeltildi |
| D6 | UYELIK-04 (sunucu) | S2 | düzeltildi |
| D7 | UYELIK-07 (sunucu) | S2 | düzeltildi (kalan: üye listesi, §6) |
| D8 | UYELIK-08 (sunucu) | S2 | düzeltildi |
| D9 | UYELIK-10 | S2 | düzeltildi |
| D10 | UYELIK-K1 | S2 | düzeltildi |
| D11 \* | UYELIK-06 (belge) | Belge | CONTRACTS §1.1 |
| D12 \* | UYELIK-11 (belge) | Belge | CONTRACTS §1.2 |
| D13 | SERVIS-01 (istemci) | C1 | düzeltildi |
| D14 | SERVIS-02 | C1 | düzeltildi |
| D15 | SERVIS-07 | C1 | düzeltildi |
| D16 | DAIRE-02, DAIRE-K1 | C1 | düzeltildi |
| D17 | DAIRE-03 (istemci) | C1 | düzeltildi |
| D18 | DAIRE-01 (istemci doğrulaması) | C1 | değişiklik gerekmedi (karakterizasyon testi) |
| D19 | UYELIK-01 | C2 | düzeltildi |
| D20 | UYELIK-02 (istemci savunması) | C2 | düzeltildi |
| D21 | UYELIK-03 (istemci) | C2 | düzeltildi (istemci engellemiyordu; bilgi iletisi eklendi) |
| D22 | UYELIK-04 (istemci) | C2 | düzeltildi |
| D23 | UYELIK-05 | C2 | düzeltildi |
| D24 | UYELIK-07 (istemci) | C2 | düzeltildi |
| D25 | UYELIK-08 (istemci) | C2 | düzeltildi |
| D26 | UYELIK-K2 | C2 | düzeltildi |
| D27 | SERVIS-03 | F1 | düzeltildi (donanımda doğrulanmadı) |
| D28 | SERVIS-04 | F1 | düzeltildi (donanımda doğrulanmadı) |
| D29 | SERVIS-06 | F1 | düzeltildi (donanımda doğrulanmadı) |
| — | UYELIK-09 | — | bilinçli kabul: kod değişmedi, CONTRACTS §1.1b notu |
| — | DAIRE-04 | Belge | CONTRACTS §1.5b; kontrol listesi 23.2 iletildi (§9) |
| — | DAIRE-05 | — | bilinçli ertelendi: CONTRACTS §2.4 notu |
| — | DAIRE-K2 | — | bilinçli kabul: CONTRACTS §2.3 notu |
| — | SERVIS-05, SERVIS-K3 | — | kontrol listesi sahibine iletildi (§9) |

\* D11 ve D12 numaraları ekip istemlerinde tanımlanmadı (S2 istemi "UYELIK-06/11 belge işi" dedi); bu belge numara boşluğunu bu iki belge kararıyla doldurdu.

Ortak not: bütün testler birim / widget / sahte köprü / gerçek PostgreSQL (yerel `55432`) / QA simülatörü düzeyindedir. "Kırmızı kanıt" her ekip raporunda vardır: yeni testler düzeltmeden önce beklenen nedenle düştü, sonra geçti.

### 3.2 Servis sorumlusunun iş akışı

**SERVIS-01 [high] — Acil sıfırlama çevrimdışı panoda: yeni yerel anahtar panoya hiçbir yoldan yazılamıyor, "Panoyu şimdi bağla" 6. adımda tıkanıyor.** (K1: köprü kopukken çevrimiçi pano "çevrimdışı" sayılıyor; K2: REASSIGNED'da eski cihaz MQTT kimliği silindiği için sonradan iletim de imkânsız.)

- Karar D1 (sunucu): bekleyen yerel anahtar. Pano ŞU AN iletilebilir değilse (`is_online` değil ya da köprü bağlı değil) `devices.local_key_enc` ve envanter anahtarı DEĞİŞMEZ, yeni anahtar `devices.local_key_pending_enc`'de bekler; iletilebiliyorsa bugünkü yol + yayın başarısızsa telafi. Uzlaştırıcı canlı panoya `sys set_local_key` yayınlar, PUBACK sonrası CAS takas + envanter + denetim. Yanıt `pending` iken `local_key` dönmez. `reissueLabel` bekleyeni temizler; claim ve pano değişimi dokunmaz.
- Karar D13 (istemci): `pending` bilgi notu; uygulanamaz "panoya yerinde yazılmalıdır" yönergesi kaldırılır; eski sunucu yanıtındaki anahtar için seri konsol (`RESETKEY` + `FACTORYINIT`) yönergesi.
- Gerçekleşen (S1): `server/migrations/032_local_key_pending.sql` (iki kolon, COMMENT, tetikleyici `trg_devices_pending_key_superseded`); `device_service.js` `emergencyReset` (plan `publish` | `pending` | `direct`, `_holdLocalKeyAfterFailedPublish` telafisi, `_requestReconcile`, yanıt kuralları: `local_key` yalnız `skipped` | `failed`); `device_reconciler.js` (`local_key` turu: canlılık `is_online` + `last_seen_at` ≤ 120 sn, tek evde tek pano, 5/10/20 sn, CAS `local_key_enc = local_key_pending_enc … WHERE local_key_pending_enc = $2`, envanter, `device_audit_logs` `local_key_rotated`; `rearm`); `mqtt_bridge.js` (`requestReconcile`, uzlaştırıcıya `publishSys`); `inventory_service.js` (yalnız açıklama).
- Gerçekleşen (C1): `lib/models/api_models.dart` (`localKeyPending`, `needsManualLocalKey = localKey != null && !localKeyPending`), `panel/emergency_reset_card.dart` (`keyPendingNote`, `manualKeyHint`), `pages/family/transfer_ownership_dialog.dart`.
- Test: S1 `test/devices/emergency_reset_pending.test.js` (6), `test/bridge/local_key_reconcile.test.js` (11), `test/devices/local_key_pending_pg.test.js` (6, PG; tetikleyici kaldırılınca 3/6 düşer), `test/devices/migration_032.test.js` (8), `emergency_reset.test.js` (yeni sözleşmeye uyarlandı). C1 `test/ui/fx_c1_emergency_reset_card_test.dart`, `fx_c1_transfer_emergency_test.dart`, `f_emergency_reset_test.dart` (güncellendi).
- Durum: **düzeltildi**. Kararla farklar: (a) `reissueLabel` temizliği açık SQL yerine `032` tetikleyicisiyle (gerekçe: `test/service_panel` sahte işleyicisi ve yazma sayısı testleri başka ekibin; açık SQL onları kırıyordu). (b) Karardaki değer listesi `published | pending | skipped` idi; kod `failed`'ı da korur (yayın + telafi başarısız; `local_key` bir kez döner).

**SERVIS-K1** — D1 içinde: plan "pano çevrimiçi VE köprü bağlı" koşuluyla seçilir; köprü kopukken `pending`. REST bekleyen yazınca `requestReconcile` → `rearm`: pano köprünün kısa kopukluğu boyunca bağlı kaldıysa da sonraki canlı state yeni dönem sayılır. Test: `emergency_reset_pending` "SERVIS-K1 …", `local_key_reconcile` "rearm …". **Düzeltildi.**

**SERVIS-K2** — D1 içinde: REASSIGNED'da eski cihaz kimliğinin silinmesi bilinçli korundu; çıkmaz yine de kalktı: panonun gerçek anahtarı sunucuda geçerli kaldığı için sihirbaz LAN'dan yeni `device_credential`'ı yazar, pano yeni kimlikle bağlanınca bekleyen anahtar iletilir. Stoğa dönüşte aynı akış sonraki claim + kurulumla işler. Test: `emergency_reset_pending` "pano CEVRIMDISI (devir)", PG uçtan uca. **Düzeltildi**; CONTRACTS §1.5b'ye yazıldı.

**SERVIS-02 [medium] — PIN (geçici servis) oturumunda "Yeni Kurulum" zaten çevrimiçi panonun bulut kimliğini yeniden üretiyor.**

- Karar D14: bekleyen kimlik yoksa ve pano sunucuya göre çevrimiçiyse kip ne olursa olsun kimlik yeniden üretilmez; yalnız açık "Kimliği Yeniden Yaz" zorlar.
- Gerçekleşen (C1): `logic/cloud_logic.dart` (`canReuseOnline` kaldırıldı; koşul `!force && pendingCredential == null && current.online`), `service_setup_controller.dart`.
- Test: `test/ui/fx_c1_pin_cloud_reuse_test.dart` (4; PIN oturumu + "Yeni Kurulum" 1→2→5→6 widget testi: `reissueDeviceMqttCredential` çağrılmaz).
- Durum: **düzeltildi** (CONTRACTS §3d). Risk: §6.

**SERVIS-03 [low] — Wi-Fi yedek provizyonda NVS yazma hatası `400 invalid_key` dönüyor; araç yanlış çözüm öneriyor.**

- Karar D27: `factory/init` ve `rekey`'de biçim geçip NVS'e yazılamazsa `503 {"error":"storage"}`; biçim hataları `400` kalır; fabrika aracı değişmez.
- Gerçekleşen (F1): `src/WebPortal.cpp` (`handleApiFactoryInit` `provisionIfEmpty` sonucuna göre; `handleApiRekey` `500 storage_error` → `503 storage`), `src/WebPortalPage.h` (`ERR_TEXT.storage`, mevcut metin); QA simülatörü `sim/fw/config_manager.js`, `sim/local_api.js`, `sim/device_sim.js` (`/__sim/hw-fail` `nvs_fail_keys`).
- Test: `tools/qa_stack/test/sim_http.test.js` (SERVIS-03), `fw_config_manager.test.js`, `fw_web_page.test.js`; fabrika aracı ↔ simülatör uçtan uca (commit dışı betik): `ProvisionError` `storage` + "Hafızayı Sil (Erase Flash)" ipucu.
- Durum: **düzeltildi, donanımda doğrulanmadı.** `POST /api/config`, `wifi/disconnect`, `rs485/baud`, `system/reset` NVS hatasında hâlâ `500 storage_error` (karar kapsamı dışı; §8).

**SERVIS-04 [low] — HTTP `factory/init` denetimi kilit dışında (TOCTOU): seri `FACTORYINIT` ile yarışta yazılan anahtar ezilebiliyor.**

- Karar D28: atomik `ConfigManager::provisionIfEmpty` (tek kilit altında boşluk denetimi + önce `ap_pass` sonra `local_key` + yarım kalırsa geri alma); seri ve HTTP yolu ortak; `main.cpp` yorumu düzeltilir.
- Gerçekleşen (F1): `src/ConfigManager.h/.cpp` (`ProvisionResult`, `provisionIfEmpty`, `restoreApPass`), `src/main.cpp` (`FACTORYINIT` → `provisionIfEmpty` + `factoryInitReply`; seri çıktılar aynen), `src/WebPortal.cpp`.
- Test: `sim_http.test.js` TOCTOU testi (gövde ayrıştırılırken seri yazarsa `403 already_provisioned`, anahtar ezilmez), `fw_config_manager.test.js` (`provisionIfEmpty` × 5), `ev_otomasyon_servis_yazilimi/tests/test_serial_provision.py` (`test_every_factoryinit_reply_in_the_firmware_is_known_to_the_tool`); gerçek `ConfigManager.cpp`'nin MSVC derlemesiyle yarış testi (commit dışı; eski HTTP sırasıyla 4 denetim düştü, yenisiyle 53/53).
- Durum: **düzeltildi, donanımda doğrulanmadı.** Kapsam genişlemesi: `local_key` yazılamazsa `ap_pass` da önceki değerine döner; HTTP yazım sırası seri yolla aynı oldu; aralık dışı `ap_pass` artık hiçbir şey yazmadan `400`.

**SERVIS-05 [low] — Kontrol listesi 4.5/4.8 "Beni hatırla"yı ve güncel imaj yolunu yansıtmıyor.** Kod değişikliği yok; kontrol listesi başka oturumundur: **iletildi** (§9). Hedef imaj yolu artık v1.1.2.

**SERVIS-06 [low] — `RESETKEY` seri çıktısı "yalnizca /api/factory/init" diyor.**

- Karar D29: metin "Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init). AP gerekirse: AP ON"; aracın aradığı "Yerel anahtar SILINDI|SILINEMEDI" aynen kalır.
- Gerçekleşen (F1): `src/main.cpp` (metin + yorum), `tests/serial_fakes.py`, `tests/test_serial_provision.py` (`FirmwareSerialOutputContractTests`: satır kaynaktan okunur, aracın ayrıştırıcısıyla ve sahte firmware ile karşılaştırılır).
- Durum: **düzeltildi, donanımda doğrulanmadı** (CONTRACTS §3/§3c).

**SERVIS-07 [low] — Kalıcı servis personeline acil sıfırlama kartı kısıtı söylemiyor (sunucu yalnız 72 saatlik servis üyeliği olan evde izin veriyor).**

- Karar D15: süper olmayan personele kapsam notu; `403`'te aynı yönlendirme.
- Gerçekleşen (C1): `emergency_reset_card.dart` (`staffScopeNote`; `403`'te `reset_forbidden_hint`, not ekranda tek kez), `transfer_ownership_dialog.dart` (konsol / çekmece diyaloğu aynı).
- Test: `fx_c1_emergency_reset_card_test.dart` (personel notu, süperde yok, `403` tek kez, 360×800 + 1,5× yazı taşmasız), `fx_c1_transfer_emergency_test.dart`.
- Durum: **düzeltildi** (karar kapsamı: not + `403` yönlendirmesi; UID ile ön kontrol yapılmadı).

**SERVIS-K3** — Kontrol listesinin 62. ve 866. satırları da v1.1.0 yazıyor: **iletildi** (§9; hedef v1.1.2).

**F1 ek işleri:** `FW_VERSION` 1.1.1 → 1.1.2 (`WiFiManager.h`); `firmware_releases/v1.1.2/` paketi (`firmware_combined_0x0.bin` SHA-256 `994104634c443b0c2d2d585c7cdd47da44c5d5e9395b900e965bdd564fbd9a42`, `app_0x10000_v1.1.2.bin` `a37ea24d5a8e99a7f03a385119616202a72bfde95be3ee2161ffdb4aa72574cd`, `SHA256SUMS.txt` doğrulandı, `SURUM_NOTLARI.md` "DONANIMDA DOĞRULANMADI" bandıyla); `version_info.json` → 1.1.2; 0x0000–0xFFFF bölgesi v1.1.1 ile bayt bayt aynı; `tools/qa_stack/lib/fwcheck.js` özetleri satır sonundan bağımsız ve `npm test` içinde zorunlu (onaysız süreç değişikliği, §6).

### 3.3 Daire kullanıcısının kullanım akışı

**DAIRE-01 [medium] — Hızlı Senaryolar ham `all_lights_off` gönderiyor: bulutta priz (`plug`) işaretli çıkışlar da kapanıyor; "Hepsini Kapat" ise prizleri koruyor.**

- Karar D2 (sunucu): `sendCommand`'da group `all_lights_off` / `all_off` için evde priz varsa close-all kuralıyla yalnız açık ışıklar `{relay:N, state:false, id}`; priz yoksa davranış aynı; ortak mantık `peace_service`'ten paylaşılır.
- Karar D18 (istemci): değişiklik gerekip gerekmediğini doğrula.
- Gerçekleşen (S1): `peace_service.js` (`homeHasPlug`, `loadLive`, `loadConflicts`, `publishAll` ortak adımlar; `closeLightsKeepingPlugs`), `device_service.js` (`sendCommand`; yanıt `command_id` = ilk komut | null, `command_ids`, gerekirse `no_change`, `skipped_count`).
- Gerçekleşen (C1): üretim kodu değişmedi; toplu komutun iyimser hedefi yok (`group:*`), açık lamba sayacı yalnız `light` sayar (`automation_state.dart` `cmdAll` delivery modu, `command_pipeline.dart`, `api_models.dart` `command_id` null güvenli).
- Test: S1 `test/devices/group_lights_off.test.js` (7), `commands.test.js` (17, değişmeden geçti), `peace_service.test.js` (dosya boyu sınırı 600 → 640). C1 `test/ui/fx_c1_scenario_plug_test.dart` (karakterizasyon; mutasyonla anlamlılığı gösterildi).
- Durum: **düzeltildi.** Kararla fark: priz denetimi cihaz değil EV düzeyinde (`SELECT EXISTS … endpoints WHERE home_id = $1 AND type = 'plug'`); kararın üst kümesi, close-all ile aynı kural; tek panolu evde sonuç birebir aynı. Uygulamada priz işaretleme ekranı yoktur (`PUT …/endpoints/:id` `{type:'plug'}` ile; CONTRACTS §1.5).

**DAIRE-02 [low] — Huzur bandı pano çevrimdışıyken bayat veriyle kesin "N lamba açık kaldı." diyor; "Hepsini Kapat" 409 ile düşüyor.** Karar D16: pano kesin çevrimdışıyken band gizlenir. Gerçekleşen (C1): `lib/ui/dashboard/peace_banner.dart` (seçiciye `deviceKnownOffline`). Test: `test/ui/fx_c1_offline_dashboard_test.dart` (bulut çevrimdışı, `emitPresence` geçişi, durum bilinmiyorken band kalır, doğrudan kip). **Düzeltildi.**

**DAIRE-K1** — Durum şeridindeki ışık hapı çevrimdışıyken kesin değer gösteriyor. Karar D16. Gerçekleşen (C1): `lib/ui/dashboard/status_pills.dart` (`hasData: !deviceKnownOffline(s) && …`: yalnız sistem hapı kalır). Test: aynı dosya. **Düzeltildi.** Aynı kök `home_hero.dart`'taki "Açık lamba" sayacında ve ev silüetinde sürüyor (karar kapsamı dışı, §8).

**DAIRE-03 [low] — Panjur süresi `PUT`'unda firmware hareket halinde `set_runtime`'ı reddediyor, sunucu yine `delivered:true` dönüp DB'yi yazıyor.**

- Karar D3 (sunucu): köprüde `expectAck(topicId, commandId, timeoutMs)`; yayından önce kurulur; yalnız canlı state `last_id` onaydır; süre yolunda 4000 ms bekleme; onay yoksa `409 CONFLICT` "Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin." ve DB değişmez.
- Karar D17 (istemci): bu `409` sunucu mesajıyla gösterilir, yerleşim çakışmasının "yenile + tek yineleme" mantığıyla karışmaz.
- Gerçekleşen (S1): `mqtt_bridge.js` (`expectAck`, `cancelAck`, `pendingAcks`, `_settleAcks`; üst sınır 1000 bekleyici → yayından önce `503`, tek bekleme ≤ 30 sn; `end()` hepsini `false` yapar), `endpoint_service.js` (`RUNTIME_ACK_TIMEOUT_MS = 4000`, yayın hatasında `cancelAck` + `502`). Gerçekleşen (C1): `logic/shutter_logic.dart` (`_isNotApplied`: mesaj "uygulamadı" / "uygulanmadı"; `_notAppliedProblem`: başlık "Süre panoda uygulanmadı", yenileme ve yineleme yok).
- Test: S1 `test/bridge/ack_wait.test.js` (8), `test/devices/endpoint_runtime_ack.test.js` (5), `endpoints_pg.test.js` ((c) senaryosu yeni anlamla), sahte köprüler `test/devices/_ack_bridge.js`. C1 `test/ui/fx_c1_shutter_not_applied_test.dart` (6; yerleşim çakışmasının regresyon kilidi dahil).
- Durum: **düzeltildi.** Risk: ayrım mesaj metnine bağlı (§6).

**DAIRE-K3** — `set_runtime` yayınlandıktan sonra tip değişirse `409` dönülüyor ama komut panoya gitmiş oluyordu. D3 ile kapandı: kilit altındaki "Kanal tipi değişti" `409`'u artık yalnız pano komutu ONAYLADIKTAN sonra yerleşim değiştiyse oluşur; reddedilen komut "uygulamadı" olarak bildirilir. **Düzeltildi.**

**DAIRE-04 [low] — "İki panolu daire" (kontrol listesi 23.2) ve "çok panolu ev" kuralları, hiçbir API yolunun aynı eve ikinci pano eklememesiyle çelişiyor.** Karar: belge. CONTRACTS §1.5b'ye "Bir dairede tek pano" maddesi eklendi (bu commit): çok panolu kurallar savunma amaçlıdır; çok pano gerçekten istenirse önce cihaz kimliği pano başına (`d_{t}_{uid}`) ayrılmalı ve claim'e "mevcut eve ekle" tasarlanmalıdır. Kontrol listesi 23.2: **iletildi** (§9).

**DAIRE-05 [PARTIAL, low] — Panjur için "bilinmeyen konum" durumu yok: hareket sırasında / 8 sn içinde enerji kesilirse NVS'teki eski konum kesin "%N" görünüyor.** **Bilinçli ertelendi.** Gerekçe: doğrulayıcıya göre belgelenmiş bir gerekliliğe aykırılık değil, süreyle hesaplanan (sensörsüz) panjurun doğal sınırı; ilk tam `up` / `down` hedefsiz tam süre + taşma çalıştığı için konumu uca oturtup kendiliğinden düzeltir (`ShutterFsm.h` `NO_TARGET`); düzeltme yeni bir `state` alanı (`pos_known`), yeni firmware imajı ve Flutter kart değişikliği ister, kullanıcı etkisi (yanlış yüzde, bir `pos` komutunun yanlış referanstan hesaplanması) bu maliyete göre düşük. Yapılan: CONTRACTS §2.4'e sınır notu (planlı yeniden başlatmada konum zorla yazılır; ani kesintide 8 sn penceresi).

**DAIRE-K2 [low] — "Evden Çıkıyorum" / "İyi Geceler" `all_shutters_down` gönderiyor: zaten kapalı panjur motorları da tam süre yeniden çalışıyor (close-all bunu bilerek kullanmıyor).** **Bilinçli kabul.** Gerekçe: hedefsiz tam hareket panjuru uca oturtur ve süre tabanlı konum sapmasını (DAIRE-05) düzeltir; bu iki senaryonun "her şeyi kapat" niyetine uygundur. Sunucunun close-all'u bildirim eylemidir ve yalnız açık panjurları konuma göre indirir; iki yolun farkı CONTRACTS §2.3'e yazıldı. Senaryoları close-all'a bağlamak uca oturtma etkisini kaldırırdı. Sahada motor/röle aşınması ya da gürültü şikâyeti olursa senaryo konuma göre gönderime çevrilebilir (§6).

### 3.4 Üyelik sistemi akışı

**UYELIK-01 [medium] — SMS kod penceresinde "Tekrar Kod İste" başarısız olunca kod alanı kayboluyor, geçerli kod girilemiyor.** Karar D19. Gerçekleşen (C2): `lib/ui/pages/auth/phone_otp_dialog.dart` (yeniden gönderim istekten önce `_isCodeSent=false` yapmaz; `_codeError` yalnız kod hatalarında alanı kırmızı çizer; `429`'da `resend_after` geri sayılır). Sunucu tarafı UYELIK-K1 ile tamamlandı (eski kod `503`'te de geçerli kalır). Test: `test/ui/fx_c2_phone_otp_resend_test.dart`, `test/social_and_otp_auth_test.dart` (15, yeşil). **Düzeltildi.**

**UYELIK-02 [medium] — Logout-all / parola değişimi / sıfırlama diğer cihazın uygulama MQTT kimliğini iptal etmiyor; canlı ev durumu 12 saate kadar izlenebiliyor.**

- Karar D4 (sunucu): toplu oturum iptali kullanıcının TÜM `kind='app'` MQTT kimliklerini aynı transaction'da siler, COMMIT sonrası kick (en iyi çaba); `admin_user_service`'teki desen paylaşılan yardımcıya taşınır.
- Karar D20 (istemci): CONNACK kimlik reddinde bayat kimlik atılır, bir kez REST'ten taze kimlik; REST `401`'de oturum-sonu akışı.
- Gerçekleşen (S2): `auth_service.js` (`revokeAllUserSessions` tek transaction + MQTT, `revokeUserMqttCredentials`, `kickMqttUsernames` en çok 5 sn bekler / asla fırlatmaz, `setMqttCredentialService` / `getMqttCredentialService`, `setPassword` `revokedMqtt` toplayıcısı; sosyal bağlamadaki ön-hesap savunması da bu yardımcıyı kullanır), `mqtt_credential_service.js` (`revokeAllUserAccess`), `admin_user_service.js` (`revokeUserMqttEverywhere` / `kickAll` kaldırıldı; rol değişimi ve parola ataması da MQTT iptal eder), `account_deletion_service.js` (aynı yardımcı).
- Gerçekleşen (C2): `lib/services/ev_mqtt_service.dart` (kimlik reddinde beklemesiz tek taze kimlik hakkı `rejectRetryUsed`, başarılı bağlantıda yenilenir), `lib/services/automation_state.dart` (`_credentialRotation`: parola değişimi / sıfırlama / tüm cihazlardan çıkış sürerken MQTT kimlik isteği yanıta kadar bekler; aksi halde atılan bağlantı eski belirteçle kimlik ister ve parolayı değiştiren cihazın oturumu yanlışlıkla kapanırdı).
- Test: S2 `test/auth/uyelik_oturum_mqtt.test.js` (11; EMQX erişilemez / kick takılır → yanıt bozulmaz), `admin.test.js` (uyarlandı + yeni), `uyelik_pg.test.js` (PG logout-all, change-password; mutasyonla zaman aşımı yarışının anlamı gösterildi). C2 `test/services/fx_c2_mqtt_credential_rotation_test.dart` (sahte aracı + gerçek `EvMqttService`).
- Durum: **düzeltildi** (CONTRACTS §1.2, §2.2).

**UYELIK-03 [medium] — Hesap silme: üyesiz ve panosuz boş dairenin tek sahibi de `409 SOLE_OWNER` ile engelleniyor; ev sahibi için daire silme ucu yok.**

- Karar D5 (sunucu): SOLE_OWNER yalnız başka üyesi ya da cihazı olan evde; boş tek-sahipli evler aynı transaction'da yönetici kalıcı silme sırasıyla silinir; yanıta `released_homes`.
- Karar D21 (istemci): istemci önceden engelliyorsa hizala; başarıda `released_homes > 0` ise bilgi.
- Gerçekleşen (S2): `account_deletion_service.js` (`_releaseEmptyHome`: `revokeHomeAccess({includeDevice:true})`, `revokeHomeServiceAccess`, `cleanupHome({keepEndpoints:false})`, `DELETE FROM homes`; 409 gövdesinde yalnız engelleyen evler; denetim `details.released_homes`; boş ev silinince servis oturumu önbelleği düşer). Gerçekleşen (C2): istemci engellemiyordu (yalnız 409'a tepki veriyor); `cloud_models.dart` `AccountDeletionResult`, `ev_cloud_api_service.dart` / `automation_state.dart` `deleteAccount` dönüşü, `delete_account_dialog.dart` iletisi "Hesabınız silindi. Üyesi ve panosu olmayan N daireniz de kaldırıldı."
- Test: S2 `test/service_panel/account_deletion_bos_daire.test.js` (8; atomik geri alma dahil), `account_deletion.test.js` (uyarlandı), `uyelik_pg.test.js`. C2 `test/ui/fx_c2_delete_account_released_test.dart`, `test/services/fx_c2_auth_api_test.dart`.
- Durum: **düzeltildi** (CONTRACTS §1.5c). Not: denetim metnindeki örnek (11.3 ile sahiplenip acil sıfırlamayla stoğa dönen daire) boş-sahipli daire ÜRETMEZ: acil sıfırlama evin tüm `home_users` satırlarını siler (`device_service.js` `emergencyReset` adım 5). Bugünkü akışlarda boş tek-sahipli daire ancak eski veriden ya da elle oluşur; düzeltme savunma ve mağaza "uygulama içi hesap silme" gereksinimi için yine doğrudur (kontrol listesi ön koşulu: §9).

**UYELIK-04 [medium] — Telefon-OTP girişi istemcide sunuluyor ama sunucuda SMS göndericisi bağlı değil: üretimde her zaman 503.**

- Karar D6 (sunucu): kimliksiz `GET /auth/capabilities` → `{sms_otp, google, apple}`; değerler mevcut 503 koşullarından türetilir. Karar D22 (istemci): SMS düğmesi yalnız `sms_otp === true` iken; uç yoksa / hata → gizli (fail-closed); Google/Apple değişmez.
- Gerçekleşen (S2): `routes/auth_routes.js` (`GET /capabilities`, IP başına 120/15 dk), `auth_service.js` (`getCapabilities`, `_canSendPhoneOtp`, `_googleAudiences` / `_appleAudiences`: `sendPhoneOtp` / `loginWithGoogle` / `loginWithApple` aynı yardımcıları kullanır). Gerçekleşen (C2): `cloud_models.dart` `AuthCapabilities`, `ev_cloud_api_service.dart` `fetchAuthCapabilities` (kimliksiz, 8 sn), `automation_state.dart` `loadAuthCapabilities` (tek uçuş, yalnız başarılı yanıt bellekte), `pages/auth/login_page.dart`.
- Test: S2 `test/auth/uyelik_yetenekler.test.js` (8). C2 `test/ui/fx_c2_login_capabilities_test.dart`, `fx_c2_auth_api_test.dart`; düğmeye dayanan 5 mevcut test dosyası sahte yetenekle güncellendi; `FakeCloudApi` varsayılanı `404` (düğme gizli).
- Durum: **düzeltildi** (sunucu + istemci; CONTRACTS §1.1b, §1.5, §6). SMS sağlayıcı hâlâ yok: üretimde düğme gizli; sağlayıcı bağlanınca `server.js`'te `setSmsSender` + `SMS_*` ile kendiliğinden görünür. QA'da `ALLOW_DEBUG_OTP=true` olduğundan `sms_otp:true` ve düğme görünür.

**UYELIK-05 [low] — Şifre sıfırlama bağlantısı başka hesap açıkken onaysız hesap değiştiriyor.** Karar D23. Gerçekleşen (C2): `pages/auth/magic_link_page.dart` (oturum açıkken magic-login ile aynı uyarı + "Bu Bağlantıyla Devam Et" / "Vazgeç"; `_submitReset` savunması), `automation_state.dart` `resetPassword` dönüşü artık "oturum benimsendi mi" (önceden her zaman `true`). Test: `test/ui/fx_c2_magic_link_reset_test.dart`. **Düzeltildi.**

**UYELIK-06 [low] — 401 `INVALID_TOKEN`'da sözleşmeye aykırı olarak önce refresh deneniyor.** Karar D11 (belge): kod değil belge güncellendi (doğrulayıcı kararı; imza anahtarı değişiminde refresh oturumu kurtarır, güvenlik riski yok, mevcut test davranışı sabitliyor). CONTRACTS §1.1 tablo satırı: "tek-uçuş refresh bir kez; reddedilirse oturum kapanır". **Belgeyle kapatıldı** (bu commit).

**UYELIK-07 [low] — SMS / Apple-gizli hesaplarda yer tutucu e-posta profilde "E-Posta" olarak gösteriliyor.**

- Karar D7 (sunucu): dışarı dönen kullanıcı nesnesinde yer tutucu → `email: null`; içerdeki kullanım bozulmaz. Karar D24 (istemci): null güvenli; profil "Belirtilmedi"; savunma olarak istemci de yer tutucuyu boş sayar.
- Gerçekleşen (S2): `auth_service.js` `publicUser` (`isPlaceholderEmail`: `@ahbu.local`, `@users.noreply.invalid`, `@deleted.invalid`; büyük/küçük harf duyarsız, sonda sabit), `account_deletion_service.js` (yardımcı dışa açık). Gerçekleşen (C2): `cloud_models.dart` (`UserModel.isPlaceholderEmail`, `contactEmailFrom`, `contactEmail`; `UserModel.fromJson` ve `HomeMember.fromJson` normalleştirir), `widgets/user_profile_dialog.dart`.
- Test: S2 `test/auth/uyelik_yer_tutucu_eposta.test.js` (9; UYELIK-08 ile ortak), `uyelik_pg.test.js`. C2 `test/ui/fx_c2_profile_email_and_forgot_test.dart`, `fx_c2_auth_api_test.dart`.
- Durum: **düzeltildi.** Kalan: sunucu `GET /homes/:id/members` (`invitation_service.getHomeMembers`, S2'nin dosyası değil) yer tutucuyu hâlâ döndürür (istemci normalleştiriyor; §8); yönetici uçları ham değeri bilerek gösterir.

**UYELIK-08 [low] — Yalnız SMS ile açılmış hesapta telefonla "Şifremi Unuttum" teslim edilmeyecek bir kod için "gönderildi" diyor.**

- Karar D8 (sunucu): yer tutucu e-postalı hesapta reset satırı açma, mailer'ı çağırma; yanıt genel `200` ile aynı. Karar D25 (istemci): kimlik biçimden telefonsa ipucu (sunucu yanıtından bağımsız).
- Gerçekleşen (S2): `auth_service.requestPasswordReset` (yer tutucu → kayıtsız kimlik gibi). Gerçekleşen (C2): `pages/auth/forgot_password_dialog.dart` (ipucu "Yalnızca telefonla açılmış hesapların şifresi ve e-postası yoktur; bu hesaplara sıfırlama kodu gönderilemez."; iki adımda da).
- Test: yukarıdaki S2/C2 dosyaları + PG (`password_resets` kullanıcı satırı 0).
- Durum: **düzeltildi.** Kararla fark: "satır açma" kullanıcıya bağlı satır açılmaması olarak uygulandı; kayıtsız kimlikteki gibi kullanıcısız (tüketilemez) satır yazılır, yazılmasaydı 60 sn içindeki ikinci istekte `200` / `429` farkı hesap varlığını sızdırırdı.

**UYELIK-09 [low] — forgot-password: var olan hesapta SMTP beklenip hata hâlinde 503, yok hesapta anında 200 (hesap varlığı zamanlama/kodla açığa çıkıyor).** **Bilinçli kabul**: kod değişmedi; dürüst teslim hatası tasarımının bedeli olarak CONTRACTS §1.1b'ye takas notu yazıldı (bu commit). UYELIK-08 sonrası yer tutucu hesaplar da hızlı (kayıtsız) yolda.

**UYELIK-10 [low] — Kimlik bazlı başarısız giriş sayacı üçüncü kişiye 15 dk hesap kilitleme imkânı veriyor.** Karar D9. Gerçekleşen (S2): `routes/auth_routes.js` (`loginFailures` anahtarı `login-id:<kimlik>|<ip>` en çok 10; yeni `loginFailuresTotal` `login-id:<kimlik>` en çok 50; ikisi de 15 dk; `peek` login'den önce; yalnız `401`'de ikisi artar, başarıda ikisi sıfırlanır; `Retry-After` engelleyenlerin en büyüğü). Test: `test/auth/uyelik_giris_kilidi.test.js` (7), `auth_login_refresh.test.js` ve `push_token_privacy.test.js` uyarlandı. **Düzeltildi** (CONTRACTS §1.1b). Sınırlar: §6. fx2 ikinci tur (S-5, M1-01/M1-02): sayaç anahtarlarında IPv6 adresi /64 önekine indirgenir (`rate_limit.limitKey`; IPv4 ve `::ffff:` aynen; auth_routes'taki tüm IP başına sınırlayıcılar ve çift anahtar), kimlik kısmı `sha256(normalize kimlik)` (64 hex). 320 karakter üstünü 400 ile reddetmek yerine özet seçildi: yeni istemci metni gerektirmez, sayaç davranışı (uzun kimlik de sayılır) korunur, bellek anahtar başına sabit kalır. Test: `uyelik_giris_kilidi.test.js` (aynı /64'ten 50 adres → kilit 10'da; anahtar sabit uzunluk), `rate_limit.test.js`.

**UYELIK-11 [low] — CONTRACTS §1.2 "ev devri → refresh iptal + token_version artar" diyor; gerçekleşme yalnız ev kapsamlı iptal yapıyor.** Karar D12 (belge): §1.2 cümlesi düzeltildi (ev devri hesap düzeyinde iptal yapmaz; yalnız o evin üyelik, uygulama MQTT kimlikleri, servis PIN/oturumları). **Belgeyle kapatıldı** (bu commit).

**UYELIK-K1** — Şifre sıfırlama / telefon OTP: önceki kodlar transaction içinde kapatılıyor, teslim başarısızsa eski kod da kaybediliyordu. Karar D10. Gerçekleşen (S2): `auth_service.requestPasswordReset` ve `sendPhoneOtp` (önceki geçerli kodlar yalnız yeni kod başarıyla teslim edilince — geliştirmede debug ile de — kapanır; teslim hatasında yalnız yeni kod iptal, yanıt aynen `503 DELIVERY_FAILED`; `INVALID_RECIPIENT`: yeni iptal + genel `200`; `sendPhoneOtp` ön koşulu `_canSendPhoneOtp`). Test: `test/auth/uyelik_kod_teslim.test.js` (7), `uyelik_pg.test.js`, `auth_otp_reset.test.js` (değişmeden yeşil). **Düzeltildi** (CONTRACTS §1.1b).

**UYELIK-K2** — Derin bağlantının şifre sıfırlama kolu biyometrik kilit sürerken beklemiyordu. Karar D26. Gerçekleşen (C2): `magic_link_page.dart` (sıfırlama kolu `checking` iken bekleme görünümü: istek yok, kilit atlatılmaz; kilit açılınca oturum varsa onay, yoksa form), `lib/ui/common/deep_links.dart` (yorum). Test: `fx_c2_magic_link_reset_test.dart` (gerçek kilit: kayıtlı oturum + biyometrik başarısız). **Düzeltildi.**

## 4. Bu commit'teki belge değişiklikleri

- `docs/CONTRACTS.md`: §1.1 (`INVALID_TOKEN` tek-uçuş refresh; `409 CONFLICT`'in `PUT` anlamları), §1.1b (yeni blok: giriş yetenekleri, yer tutucu e-posta, şifremi unuttum / OTP ve eski kod kuralı, UYELIK-09 takası, iki katmanlı giriş kilidi, sıfırlama bağlantısı onayı ve kilit beklemesi), §1.2 (oturum iptali = MQTT kimlik iptali + istemci davranışı; ev devri cümlesi), §1.4 (servis personeli kapsam notu), §1.5 (yeni `GET /auth/capabilities` satırı; toplu ışık kapatma priz kuralı; `PUT …/endpoints/:id` onay bekleme, iki `409`, `503`, `type` alanı; acil sıfırlama yerel anahtar değerleri), §1.5b (acil sıfırlama `pending` / telafi / yanıt kuralları; istemcinin çevrimdışı pano gösterimi; close-all ↔ toplu komut; "Bir dairede tek pano"; uzlaştırıcıda bekleyen anahtar; toplu iptalde MQTT), §1.5c (Home Admin OTP `503` netleştirmesi; hesap silmede boş daire ve `released_homes`; etiket yeniden üretiminde bekleyen anahtar), §2.2 (toplu iptal ve hesap silmede kimlik silme; uygulama istemcisinin CONNACK reddi kuralı), §2.3 (`all_lights_off` ve priz; `all_shutters_*` tam süre, DAIRE-K2), §2.4 (`last_id` = cihaz onayı; DAIRE-05 konum sınırı), §3 (bekleyen anahtar; `factory/init` atomikliği; `RESETKEY` sonrası tercih edilen yol), §3b (`503 storage`; risk notu), §3c (`RESETKEY` yanıt metni; `FACTORYINIT` geri alma ve ortak kilit; araç testlerinin kaynaktan denetimi), §3d (kipten bağımsız kimlik kuralı), §6 (EMQX kick notu, `ALLOW_DEBUG_OTP`, SMS sağlayıcı yok, `TRUST_PROXY`, migration `032`), §7 (geçici sahiplik satırı).
- `docs/DEPLOY_RUNBOOK.md`: §5 (migration listesine `032`, sıra / geri alma / QA notu, `check_schema_contract.js --live`, akış denetimi sunucu ayarları), §6 (`/auth/capabilities` denetimi), §7 (firmware v1.1.2 notu ve tek kart denemesi), §8 (istemci ↔ sunucu sürüm uyumu), §10 (izlenecek günlükler).

## 5. Rapor ↔ kod farkları ve kararla sapmalar (doğrulama notları)

Kod esas alındı; CONTRACTS koda göre yazıldı.

1. **`local_key_publish` değerleri:** C1'in sözleşme önerisi `published | pending | skipped` diyor; S1 kodu `failed`'ı da döndürür (yayın ve telafi birlikte başarısız; `local_key` bir kez döner, uyarı fx2 S-3'ten beri "Yeni yerel anahtar panoya iletilemedi; anahtar yalnız bu yanıtta gösterilir. Panoya seri konsoldan RESETKEY ve ardından FACTORYINIT ile (fabrika aracı) yazılabilir."; önceki metin "… cihaza yerinde elle yazılmalıdır." idi). C1'in `api_models.dart` belge yorumu `failed`'ı yalnız eski sunucu değeri sayıyor; davranış yine doğru (anahtar + seri konsol yönergesi).
2. **Telefon OTP eski kod kuralı:** C2'nin sözleşme önerisi "sunucu önceki kodu yalnız yeni kod ÜRETİLDİĞİNDE tüketir" diyor; S2'nin K1 düzeltmesinden sonra kural "yalnız yeni kod BAŞARIYLA TESLİM EDİLİNCE". CONTRACTS ikincisini yazar.
3. **`/auth/capabilities` hız sınırı:** C2 "hız sınırı genel" diyor; S2 kodu ayrı sınırlayıcı kullanır: IP başına 120/15 dk.
4. **D2 (priz denetimi):** karar "hedef cihazın uç noktalarında priz" diyordu; kod ev düzeyinde denetler (S1 raporu açıklıyor; tek panolu evde sonuç aynı).
5. **D1 (`reissueLabel`):** karar `inventory_service`'te açık temizlik diyordu; kod `032` tetikleyicisini kullanır (S1 gerekçesi §3.2).
6. **D8:** karar "reset satırı AÇMA" diyordu; kod kullanıcısız, tüketilemez satır yazar (S2 gerekçesi §3.4).
7. **SMS düğmesi QA'da:** C2'nin kontrol listesi notu "SMS göndericisi bağlı değilse satırın görünmemesi beklenir" yalnız üretim için doğru; QA yığını `ALLOW_DEBUG_OTP=true` + `NODE_ENV=development` ile çalıştığından (`tools/qa_stack/lib/api_server.js`) QA'da `sms_otp:true` ve düğme görünür.
8. **S1 PG'li tam koşu:** rapordaki "0 kırık" yalnız temiz koşular için (günlüklerde 6 koşunun 3'ü); diğer üç koşuda dosya düzeyinde süreç çökmesi (`0xC0000409`; `reissue_label`, `layout_pg`, `server_resilience` + `routes_matrix`) var. Taban (`daffee9`) koşusunda da aynı belirti görüldü ve ilgili dosyalar tek başına geçiyor: ortamsal kabul edildi, birleşik koşuda yeniden bakılmalı.
9. **UYELIK-03 örneği:** denetim metnindeki "11.3 + acil sıfırlama" örneği boş-sahipli daire üretmez (acil sıfırlama tüm üyelikleri siler); bkz. §3.4.
10. **Karar numaraları:** D11 ve D12 ekip istemlerinde tanımlanmadı; bu belge UYELIK-06 / UYELIK-11 belge kararları olarak kaydetti.

## 6. Kalan riskler

**Sunucu (S1, S2)**

- Firmware `sys set_local_key`'i yankılamaz: uzlaştırıcı takası PUBACK'e dayanır. Pano NVS'e yazamazsa sunucu yeni anahtara geçer, pano eskide kalır (çevrimiçi sıfırlama yolunda zaten vardı). Öneri: firmware'de anahtar sürümü/özeti onayı.
- Bayat `is_online` penceresi: pano aniden enerjisiz kalırsa ~120 sn `is_online` TRUE kalabilir; bu pencerede sıfırlama `publish` yolunu seçer, broker PUBACK verir ama pano almaz (dar pencerede SERVIS-01 çıkmazı sürer). Öneri: `publish` yolunu `last_seen_at` ≤ ~60 sn ile sınırlamak.
- Kuramsal yarış (ms): uzlaştırıcı eski bekleyeni yayınlarken eşzamanlı çevrimiçi yeni bir sıfırlama olursa pano eski bekleyen anahtarda kalabilir; CAS veritabanını korur, panoyu korumaz.
- Sihirbaz deneyimi: uzlaştırıcı anahtarı döndürdükten sonraki ilk LAN çağrısı bir kez `401` alır; "Tekrar dene" kurtarır (otomatik tek yeniden deneme önerisi §8).
- `032` tetikleyicisi veritabanı düzeyinde örtük bir kuraldır (yalnız sahipsiz kayıtta, bekleyene dokunmadan anahtar değişirse); migration başlığında, `inventory_service` yorumunda ve PG testlerinde belgelendi.
- Çok panolu evde bekleyen anahtar otomatik iletilmez (DAIRE-04 gereği pratikte oluşmaz).
- D3: `state` QoS 0; onay yankısı kaybolur ya da broker 4 sn'yi aşarsa uygulanmış süre `409` alır (DB eski, pano yeni; yeniden deneme düzeltir). İstek en kötü ~9 sn sürer (istemci zaman aşımı 10 sn).
- D3/D17: iki farklı `409 CONFLICT` sunucu fx2 S-4'ten beri gövdede makine-okur `reason` taşır (`NOT_APPLIED` | `TYPE_CHANGED`); istemci bunu okuyana kadar mesaj metninden ayırır (sunucu metni değişirse istemci yerleşim yoluna düşer).
- D2: prizli evde komut başına ayrı yayın (≤ 40 komut); canlı anlık görüntü yoksa (`is_online` TRUE ama `last_seen_at` > 120 sn) `409 DEVICE_OFFLINE`; istemci `id`'si bu yolda kullanılmaz.
- D4: parola değişimi değişikliği yapan cihazın MQTT bağlantısını da atar (C2 istemcisi ele alır; ESKİ istemcide yavaş ağda oturum yanlışlıkla kapanabilir, DEPLOY_RUNBOOK §8). logout-all artık tek transaction; push iptali ≤ 3 sn + kick ≤ 5 sn: EMQX takılırsa yanıt ~8 sn gecikebilir. Kapsam genişlemesi: yönetici rol değişimi ve parola ataması da MQTT iptal eder.
- D5 yarışı: kontrol ile `DELETE FROM homes` arasında eşzamanlı pano sahiplenme / üye katılımı olursa `devices.home_id ON DELETE SET NULL` ile pano yetim kalabilir (admin kalıcı silmede de aynı; olasılık düşük).
- D9: sayaçlar süreç belleğinde (yeniden başlatmada sıfırlanır); aynı CGNAT arkasındaki saldırgan o IP için kullanıcıyı kilitleyebilir; ≥ 5 IP'li dağıtık saldırgan 50 tavanıyla 15 dk kimlik kilidi tetikleyebilir (kabul edilen takas). "IP" IPv6'da /64 önekidir (fx2 S-5); /48 sahibi binlerce /64'e sahip olduğundan IPv6'da asıl kilit vektörü yine 50'lik toplam tavandır. Kimlik başına deneme bütçesi tek katmanlı dönemin 10'u yerine 50'dir (bilinçli D9 parametresi).
- K1: yeni kodun gönderildiği SMTP/SMS penceresinde (saniyeler) doğrulama en yeni satırı hedefler; o arada girilen eski kod bir deneme hakkı yakar.
- `capabilities` sınırı IP başına 120/15 dk: kalabalık NAT'ta `429` olasılığı; istemci hatada SMS düğmesini gizler (fail-closed).

**İstemci (C1, C2)**

- D14: bellekte kimlik yokken sunucunun bayat `online=true` bilgisine güvenilir (ör. kick sonrası LWT işlenmeden uygulama yeniden açılırsa 6. adım kimliği yazmadan geçer); artık PIN ve personel kiplerinde de. Çevrimiçi kartta "Kimliği Yeniden Yaz" düğmesi yok (ayrı karar).
- D16: sayaç hapları kesin çevrimdışıyken tamamen gizlenir; `home_hero.dart` sayacı ve silüeti son bilinen değeri göstermeye devam eder.
- D15: kapsam notu süper olmayan tüm kalıcı personele (geçerli üyeliği olana da) gösterilir; `403` yönlendirmesi her `403`'te (iptal / askı dahil) eklenir.
- D13: `pending` ile `local_key` birlikte gelirse (sözleşmeye aykırı) anahtar bilinçli olarak gösterilmez.
- C2 ortak test destek dosyalarını değiştirdi (`test/support/fakes.dart`, `test/ui/e2_support.dart`): birleştirmede çakışma olabilir; `FakeCloudApi` varsayılanı SMS düğmesini gizler (yeni testler yetenek atamalı); `EvCloudApiService.deleteAccount` artık `Future<AccountDeletionResult>`; `AutomationState.resetPassword` dönüş anlamı değişti.
- Kimlik döndürme sürerken MQTT yeniden bağlanması REST bütçesi (~14 sn) kadar bekleyebilir; aracı arka ucu bozuksa her ret serisinde en çok bir ek kimlik isteği gider.
- Sıfırlama onay metni bağlantı aynı hesaba aitse de "başka bir hesap açık" der (istemci belirteçten hesabı bilemez; magic-login ile aynı sınır).
- `test/visual/auth/auth_gallery_test.dart` (tag `visual`) çalıştırılmadı.
- C1'in ilk `flutter test` koşusu `--no-pub` olmadan örtük `pub get` tetikledi; `pubspec.lock` değişmedi (ekip raporu).

**Firmware (F1)**

- Donanımda doğrulanmadı: NVS hatası ve seri ↔ HTTP yarışı yalnız simülatör, gerçek `ConfigManager.cpp`'nin MSVC derlemesi ve kaynak incelemesiyle sınandı; `WebPortal.cpp` işleyicileri PC'de derlenemedi.
- `rekey`'in NVS hatası `500 storage_error` → `503 storage` oldu (depodaki istemciler ikisini aynı iletiye eşler; depo dışı istemci farklı görür).
- Onaysız süreç değişikliği: `tools/qa_stack/test/fwcheck.test.js` simülatör ↔ firmware eşitliğini `npm test`'te zorunlu kılar; izlenen firmware kaynağı simülatör eşitlenmeden ve `node run.js fwcheck --update` çalıştırılmadan değişirse `npm test` kırılır.
- `PortalState.qaBeforeProvision` yalnız test kancasıdır (firmware'de karşılığı yok).
- Paketlenmiş ikililer derleme dizinine bağlıdır (başka dizinde derleme 64 bayt farklı çıkar); `pio test -e native` bu makinede hâlâ çalışmıyor (gcc yok).

**Entegrasyon / dağıtım**

- Beş commit birlikte hiç koşulmadı; birleşik sunucu, Flutter, QA ve araç takımları koşulmadan dağıtım yapılmamalı (§7).
- Yeni kod `032`'siz veritabanında acil sıfırlamada `42703` verir: sıra migration → kod.
- F1 ikilileri düz `git diff` ile taşınmaz.

## 7. Entegrasyon ve dağıtım sırası

1. Entegrasyon dalında beş commit'i birleştir (`5b8afda`, `cd135a8`, `3dcf32f`, `f1e9f33`, `9ef99ba`; F1 için `git diff --binary`, `format-patch` ya da cherry-pick). Sonra birlikte: `server` `npm test` (PG'siz + `EV_PG_TEST_URL` ile PG'li), `node scripts/check_syntax.js`, `node scripts/check_schema_contract.js` (+ `--live`), `node scripts/check_client_contract.js`; `flutter analyze` + `flutter test`; `tools/qa_stack` `npm test` ve `node run.js fwcheck`; fabrika aracı `python -m unittest discover -s tests`; görünmez karakter taraması.
2. Canlı sunucu: yedek → migration `032` → kod + PM2 yeniden başlatma → `check_schema_contract.js --live` → `GET /api/v1/auth/capabilities` denetimi → günlük izleme (`docs/DEPLOY_RUNBOOK.md` §5, §6, §10).
3. Mobil uygulama (APK/IPA) aynı dönemde (yeni istemci eski sunucuyla da çalışır; tersi için `docs/DEPLOY_RUNBOOK.md` §8).
4. Firmware v1.1.2: önce tek test kartında flash + USB `FACTORYINIT` + `RESETKEY` / yeniden `FACTORYINIT` + `factory/init` (provizyonluda `403`) + `rekey`; sonra `SURUM_NOTLARI.md` bandını güncelle ve yaygınlaştır (`docs/DEPLOY_RUNBOOK.md` §7).

## 8. Bu belgenin sahibi olmayan dosyalarda gereken değişiklikler

- `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md`, `ev_otomasyon_servis_yazilimi/EV_OTOMASYON_KULLANIM_REHBERI.md` (ve gerekirse `docs/DENEME_REHBERI.md`): §9.
- `docs/QA_STACK.md`: `/__sim/hw-fail` gövdesine `nvs_fail_keys` (`lk` | `ap_pw` alt kümesi; `[]` arızayı kaldırır; yeniden açılışta sürer); kimlik yazımında NVS arızası → `factory/init` / `rekey` `503 storage`; `fwcheck` özetleri satır sonu normalleştirilmiş SHA-256'dır ve `npm test` güncelliğini denetler (firmware kaynağı değişince simülatörü eşitleyip `node run.js fwcheck --update` zorunlu).
- `docs/FLUTTER_API_CHANGES.md`: `EvCloudApiService.fetchAuthCapabilities`, `deleteAccount` → `AccountDeletionResult`, `AutomationState.loadAuthCapabilities` / `authCapabilities`, `resetPassword` dönüş anlamı, `UserModel.isPlaceholderEmail` / `contactEmail`, `EmergencyResetResult.localKeyPending`.
- Sunucu, `invitation_service.getHomeMembers`: yer tutucu e-postayı `null` döndür (`require('./account_deletion_service').isPlaceholderEmail`).
- Sunucu, `endpoint_service`: `409` gövdesine makine-okur `reason` — fx2 S-4 ile YAPILDI (`NOT_APPLIED` | `TYPE_CHANGED`). İstemci tarafı (reason okuma) ayrı iştir.
- Sunucu, `server.js`: SMS sağlayıcı seçilince `authService.setSmsSender(...)` + CONTRACTS §6'ya `SMS_*`.
- Sunucu, `device_service.emergencyReset`: `publish` yolunu taze `last_seen_at` ile sınırlamak (öneri).
- Sunucu testleri (`test/service_panel`): `reissueLabel` bekleyen temizliği açık SQL'e geçirilecekse sahte işleyici (`_world.js`) ve yazma sayısı (`reissue_label.test.js`) güncellenmeli; sonra `032` tetikleyicisi kaldırılabilir (yeni migration ile).
- İstemci, `lib/ui/pages/service_setup/setup_context.dart` `deviceCall`: `401`'de `ensureDeviceReady(refreshKey: true)` ile otomatik tek yeniden deneme (uzlaştırıcı anahtarı döndürdükten sonra).
- İstemci, `lib/ui/dashboard/home_hero.dart`: kesin çevrimdışıyken "Açık lamba" sayacı ve silüet (DAIRE-K1 kökü; ayrı karar).
- İstemci, `lib/services/api_exception.dart`: `isConflict` belge yorumuna "pano süreyi uygulamadı" anlamı (isteğe bağlı).
- Firmware: `POST /api/config`, `wifi/disconnect`, `rs485/baud`, `system/reset` NVS hatasını `503 storage`'a çekmek (karar bekliyor); `sys set_local_key` için onay (anahtar sürümü/özeti); MSVC glue testi ve Unity çalıştırıcısının `test/**`'e alınması (öneri).

## 9. Saha kontrol listesi için GEREKEN değişiklikler (kontrol listesi sahibine iletilecek)

Satır numaraları `daffee9`'daki `EVOTOMASYON_CANLI_TEST_KONTROL_LISTESI.md` içindir. Bu oturum listeyi DEĞİŞTİRMEDİ.

1. **Başlangıç Bilgileri → Cihaz Envanteri (satır 62)** ve **Doğrulanmayanlar (satır 866)** (SERVIS-K3): "firmware v1.1.0 (donanımda henüz denenmedi)" / "firmware v1.1.0 hiçbir karta yazılıp denenmedi" → "firmware v1.1.2 (`version_info.json`'daki güncel sürüm; donanımda henüz denenmedi)". Satır 885: "migration 001–031" → "001–032".
2. **1.1 Uygulamayı Başlatma** (UYELIK-04): "Telefon Numarası ile Şifresiz Giriş (SMS)" yalnız sunucu `GET /api/v1/auth/capabilities` → `data.sms_otp:true` iken görünür. Canlıda (SMS sağlayıcı yok) GÖRÜNMEMESİ beklenen davranıştır; QA'da (`ALLOW_DEBUG_OTP=true`) görünür. Google, Apple ve "E-postadaki Bağlantım Var" değişmedi. Canlı sunucu denetimi: `curl https://evotomasyon.gudeteknoloji.com.tr/api/v1/auth/capabilities` → `data.sms_otp=false`.
3. **4.5 Masaüstü aracı girişi** (SERVIS-05, "Beni hatırla"): giriş penceresinde "Beni hatırla (şifreli oturum anahtarı bu bilgisayarda saklanır; ortak bilgisayarda işareti kaldırın)" kutusu varsayılan işaretli (DPAPI olmayan sistemde pasif: "Beni hatırla (bu bilgisayarda kullanılamıyor)"). Beklenen şerit: "<e-posta> (süper kullanıcı, hatırlanıyor)". Aracı kapatıp açınca giriş penceresi GELMEZ; araç kayıtlı oturumla sessizce girer (günlük: "[BAŞARILI] Kayıtlı oturum sessizce açıldı. 'Oturumu Kapat' hatırlanan oturumu siler."). "Oturumu Kapat" hatırlanan oturumu siler; sonraki açılışta giriş penceresi geri gelir. Ortak bilgisayarda kutuyu kaldırın ya da işten sonra "Oturumu Kapat".
4. **4.8 Etiket, firmware, USB provizyonu** (SERVIS-05/K3, F1): dosya yolu `firmware_releases/v1.1.0/firmware_combined_0x0.bin` (satır 189) → `firmware_releases/v1.1.2/firmware_combined_0x0.bin` ("Bizim Geliştirdiğimiz Yazılım" bu yolu getirir). Yeni adımlar: kart açılınca `fw` = 1.1.2 (Sistem sekmesi / `GET /api/status`); seri terminalde `RESETKEY` yanıtı "[CLI-SONUC] Yerel anahtar SILINDI. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init). AP gerekirse: AP ON"; provizyonlu karta araçla yeniden USB provizyonu → "Kartta Eski Anahtar Var" sorusuna "Evet" → araç `RESETKEY`'i tanır, `FACTORYINIT` yeniden `OK`. Wi-Fi yedek yolu: provizyonlu karta "Wi-Fi ile Provizyonla (güvensiz yedek yol)" → "Cihaz zaten provizyonlu (başka bir anahtarla kurulmuş)."; bilgi notu: NVS yazma hatasında araç "Cihaz anahtarı kalıcı belleğe yazamadı (storage)." + "Kartı yeniden başlatıp tekrar deneyin; sürerse 'Hafızayı Sil (Erase Flash)' ile firmware'i yeniden yükleyin." gösterir (sahada üretilemez).
5. **6.3 Panjur süresi (Adım 8)** (DAIRE-03): yeni olumsuz adım: süre kaydedilirken ("Kaydet ve Panoda Doğrula") panjur hareket halindeyse (ör. duvar anahtarıyla) "Süre panoda uygulanmadı" başlığı, sunucu mesajı "Pano panjur süresini uygulamadı (panjur hareket halinde olabilir). Panjuru durdurup yeniden deneyin." ve "Tekrar dene" görünür; "Kanal yerleşimi değişti" GÖRÜNMEZ; sunucudaki `endpoints.shutter_duration_sec` değişmez. "Tekrar dene" panjuru durdurup süreyi yeniden yazar; panjur durunca kayıt başarılı olur ve sunucu ile pano (`/api/config` `runtime_sec`) aynı değeri taşır. Zamanlamayı tutturmak zor olabilir: yapılamazsa "yapılamadı".
6. **8.2 / yeni 8.6 Hızlı Senaryolar, prizli daire** (DAIRE-01): ön koşul: bir lamba kanalı priz yapılmış olmalı. Uygulamada priz işaretleme ekranı YOKTUR; API ile (ev sahibi ya da servis belirteciyle) `PUT /api/v1/homes/<ev>/endpoints/<uç nokta>` gövde `{"type":"plug"}`; bu listede belgelenmiş bir komut yoksa "yapılamadı". Yapın: prizi ve iki lambayı açın → "Tüm Lambalar" / "İyi Geceler" / "Evden Çıkıyorum". Beklenen: yalnız lambalar kapanır, priz AÇIK kalır; priz kartı komut sürerken değişmez. Prizsiz dairede aynı senaryolar tek toplu komutla tüm lambaları kapatır (değişmedi). Bilgi (DAIRE-K2, bilinçli): "İyi Geceler" / "Evden Çıkıyorum" zaten kapalı panjurların motorunu da tam süre çalıştırır.
7. **8.3 Olumsuz (pano çevrimdışı)** (DAIRE-02/K1): beklenene ekle: huzur bandı ("N lamba açık kaldı." + "Hepsini Kapat") GÖRÜNMEZ; durum şeridinde "N Işık Açık", "Tüm Işıklar Kapalı" ve "Panjurlar Sabit" hapları çizilmez, yalnız "Pano çevrimdışı" sistem hapı kalır; pano dönünce sayaçlar ve band geri gelir. Yerel (LAN) modda cihaza ulaşılamayınca aynı ("Cihaza ulaşılamıyor"). Bilinen sınır: üstteki "Açık lamba" sayacı (ev kartı) son bilinen değeri göstermeye devam eder.
8. **14.1 / 14.2 Acil sıfırlama** (SERVIS-01/K1/K2/07):
   - Pano ÇEVRİMDIŞIYKEN (QA: ilgili simülatöre `__sim/offline`; gerçek panoda enerji kesik) sıfırlama: sonuç yine kısmi başarıdır (14.1 "Sıfırlama kısmen tamamlandı", 14.2 "Bazı adımlar eksik kaldı; aşağıdaki uyarılara bakın."; çocuk kilidi uyarısı yüzünden); sunucu uyarısı yalnız çocuk kilidi içindir (fx2 S-1/S-2): devirde "Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Kilit, pano bağlandığında otomatik kaldırılacak.", stoğa almada "Pano çevrimdışı; çocuk kilidi sıfırlama komutu gönderilemedi. Pano yerelde kilitli kalmış olabilir." (pano çevrimiçi ama sunucunun MQTT köprüsü kopuksa baş kısım "Bulut bağlantısı yok; …" olur, "Pano çevrimdışı" denmez); bekleyen yerel anahtar için uyarı satırı YOKTUR; bilgi notu "Yeni yerel anahtar, pano buluta bağlandığında sunucu tarafından otomatik iletilecek; o zamana kadar panonun mevcut anahtarı geçerlidir." (14.1'de yeni sahibe devirde sonuna şu cümle eklenir: «"Panoyu şimdi bağla" ile kuruluma devam edebilirsiniz.»). YEREL ANAHTAR satırı / kartı, kopyala düğmesi ve "panoya yerinde yazılmalıdır" ("yerinde girilmeli") yönergesi GÖRÜNMEZ. Stoğa almada not var, "Panoyu şimdi bağla" anılmaz ve düğmesi yoktur.
   - Süper yönetici hesabıyla yapılan devirde (M4-02) "Panoyu şimdi bağla" bu hesapla ÇALIŞMAZ: yerel anahtar ucu süper yöneticiye kapalıdır ve devir personele üyelik vermez; pano, yeni sahibin uygulamasından alınan servis PIN'iyle servis girişi yapılarak bağlanır (devri servis personeli yaptıysa 72 saatlik kurulum penceresinde personel hesabıyla da bağlanabilir). Aşağıdaki adım servis personeli ya da servis PIN oturumu içindir.
   - Devirde "Panoyu şimdi bağla" (servis personeli / servis PIN oturumu) → sihirbazın 6. adımı panonun MEVCUT anahtarıyla LAN'dan geçer ve yeni bulut kimliğini yazar; pano buluta bağlanınca ~2–5 sn içinde sunucu yeni anahtarı iletir (sunucu günlüğü `[RECONCILE] yerel_anahtar home=… cihaz=… sonuc=uygulandi`, `device_audit_logs` `local_key_rotated`, `devices.local_key_pending_enc` NULL; günlük/DB erişimi gerekir). Sihirbazın sonraki LAN adımı bir kez "anahtar kabul edilmedi" derse "Tekrar dene" yeni anahtarı sunucudan alır (bilinen sınır).
   - Pano ÇEVRİMİÇİYKEN: sonuç `published`, anahtar gösterilmez; eski anahtarla LAN reddedilir, sunucudaki yeni anahtarla çalışır.
   - Servis sorumlusu (süper değil): "Acil Servis Sıfırlaması" kartında ve konsol/çekmece "Acil Sıfırlama" penceresinde kapsam notu "Servis personeli yalnız son 72 saat içinde kurduğu ya da devraldığı dairelerin panolarını sıfırlayabilir; diğer daireler için süper yöneticiye başvurun." görünür; süper yöneticide görünmez. 14.1 Olumsuz'daki yetkisiz denemede sunucu iletisinin altında aynı not görünür (ekranda tek kez).
   - Geçiş dönemi (eski sunucu): sonuçta anahtar gösterilirse altındaki yönerge "Bu anahtar panoya ağ üzerinden yazılamaz: panoyu USB ile bağlayıp seri konsolda önce RESETKEY, ardından FACTORYINIT ile yazın (fabrika aracı). …" olmalı.
   - Listede ya da rehberlerde "Cihaz çevrimdışı; yeni yerel anahtar … yerinde elle yazılmalıdır" / `skipped_offline` + `local_key` beklentisi varsa yeni sözleşmeye (`pending`, anahtar dönmez) göre güncellenmeli.
   - Etiket yeniden üretimi (DB denetimi, isteğe bağlı): çevrimdışıyken stoğa alınmış (bekleyen anahtarlı) cihazda `reissue-label` sonrası `devices.local_key_pending_enc` NULL olmalı.
9. **23.2 Karışık Durum (İki Pano)** (DAIRE-04): ön koşul "iki panolu daire" uygulama/API ile OLUŞTURULAMAZ (claim yalnız sahibin panosuz evine ya da yeni eve bağlar; acil sıfırlama cihazı aynı evde tutar; pano değişimi eskisini çıkarır; cihaz MQTT kimliği ev başına tek). Madde "yapılamadı" işaretlenmeli ya da kaldırılmalı (yalnız veritabanına elle ikinci pano eklenerek; önerilmez). "Ortam özeti"ndeki "23.x ve 23.2 (iki panolu daire)" ifadesi de güncellenmeli.
10. **26.3 / 26.4 Şifremi Unuttum** (UYELIK-08, UYELIK-K1): kimlik alanına telefon numarası yazınca bilgi ipucu "Yalnızca telefonla açılmış hesapların şifresi ve e-postası yoktur; bu hesaplara sıfırlama kodu gönderilemez." çıkar; kod telefonla istendiyse ikinci adımda da kalır; e-posta yazınca çıkmaz. Yalnız SMS ile açılmış hesabın numarasıyla "Kod Gönder": kayıtlı olmayan numarayla aynı genel ileti, kod gelmez (sunucu göndermeyi denemez; bu hesap QA'da yalnız debug OTP ile açılabilir, yoksa "yapılamadı"). Yeni madde: kod geldikten sonra "Kodu Tekrar Gönder" `503` "gönderilemedi" verirse (SMTP geçici arıza) elde olan önceki kod hâlâ kabul edilir; yeni kod başarıyla gelirse önceki kod artık "Hatalı kod" verir (SMTP arızası sahada zor üretilir: yapılamazsa "yapılamadı"). Telefon OTP için de aynısı.
11. **26.1 / 26.5 / 31.2 Oturumların toplu iptali** (UYELIK-02): 26.5 ve 31.2 Beklenen'e ekle: ikinci cihazda canlı durum (lamba/panjur) akışı HEMEN durur (MQTT bağlantısı atılır; canlıda `EMQX_API_*` tanımlıysa, QA brokerı destekler); ikinci cihaz birkaç saniye içinde, REST işlemi beklemeden "Oturumunuz sona erdi. Lütfen tekrar giriş yapın." ile giriş ekranına düşer. Doğrulama: ikinci cihazda pano açıkken birinci cihazdan çıkış / parola değişimi yapın; ardından fiziksel anahtarla lamba yakın: ikinci cihaz değişimi GÖRMEMELİ. 26.1 / 31.2: parolayı DEĞİŞTİREN cihazda canlı durum ~2–3 sn kopup yeni kimlikle kendiliğinden geri gelmeli, oturum KAPANMAMALI (kapanırsa istemci hatası olarak kaydedin).
12. **27.1 SMS ile giriş** (UYELIK-04, UYELIK-01, UYELIK-K1): canlıda (SMS kapalı) "düğme görünmüyor" = GEÇTİ ("yapılamadı" yerine). Satır 675'teki "yeni kod isteği 60 sn bekleme kuralına tabidir ve öncekini geçersiz kılar" → "önceki kodu yalnız yeni kod başarıyla teslim edilince geçersiz kılar" (QA'da debug OTP ile hemen). SMS açıkken (QA debug ya da ileride sağlayıcı) eklenecek adım: kod geldikten 60 sn sonra "Tekrar Kod İste"; `429` ya da `503` gelirse kod alanı ve "Giriş Yap" kalmalı, ilk kodla giriş tamamlanmalı; `429`'da "Tekrar Kod İste (mm:ss)" geri sayılır; kod alanı kırmızı çizilmez (yalnız hata iletisi). (26.3'teki SMS kod penceresi notu da aynı.)
13. **28.2 SOLE_OWNER** (UYELIK-03): Beklenen güncelle: yalnız başka üyesi VEYA panosu olan daireler listelenir; boş (üyesiz + panosuz) daire listede GÖRÜNMEZ. Yeni 28.2b: yalnız boş dairesi olan hesapla 28.1 → hesap silinir, boş daire de kaldırılır; ileti "Hesabınız silindi. Üyesi ve panosu olmayan N daireniz de kaldırıldı."; süper yönetici listesinde daire yoktur. Ön koşul notu: böyle bir hesap bugünkü akışlarla kolay üretilmez (acil sıfırlama evin TÜM üyeliklerini de sildiği için 11.3 + 14.x yolu bunu oluşturmaz); QA'da hazır yoksa "yapılamadı".
14. **Profil (yeni madde, UYELIK-07)**: telefon-OTP ile ya da e-postasını gizleyen Apple ile açılmış hesapta Profil → "E-Posta: Belirtilmedi"; `@ahbu.local` / `@users.noreply.invalid` adresi profil, ayarlar bilgi kartı, karşılama adı ve aile üye listesinde görünmez (üye kartı telefona düşer). Böyle hesap QA'da yalnız debug OTP ile (API) açılabilir; yoksa "yapılamadı".
15. **30.1 Şifre sıfırlama bağlantısı** (UYELIK-05, UYELIK-K2): yeni adımlar: bağlantı oturum AÇIKKEN açılırsa önce "Bu cihazda şu anda başka bir hesap açık. Bağlantıyla şifre yenilerseniz mevcut oturum kapanır ve bağlantının hesabı açılır." ve "Bu Bağlantıyla Devam Et" / "Vazgeç"; "Vazgeç" oturumu değiştirmez; onaydan sonra form açılır. Biyometrik kilit sürerken `/reset-password#token=` formu açılmaz ("Oturum durumu kontrol ediliyor. Uygulama kilitliyse önce kilidi açın..."); kilit açılınca onay ya da form gelir.
16. **32.x PIN oturumu (yeni madde, SERVIS-02)**: geçici servis (PIN) oturumunda çalışan (çevrimiçi) panoda "Yeni Kurulum Başlat" → 6. adım "Pano sunucuda zaten çevrimiçi: çalışan panonun bulut kimliği DEĞİŞTİRİLMEDİ." demeli; pano buluttan düşmemeli, ev sahibinin uygulamasında kesinti olmamalı.
17. **Bu sürümde değişenler (satır 856)**: özet satırı ekle: "Akış denetimi düzeltmeleri (2026-10-04): bekleyen yerel anahtar (migration 032), prizli evde toplu ışık kapatma, panjur süresinde cihaz onayı, oturum iptalinde MQTT kimliği iptali, boş daireyle hesap silme, giriş yetenekleri ucu, yer tutucu e-posta, iki katmanlı giriş kilidi, kod teslim sırası, firmware v1.1.2 (provizyon yolu); ayrıntı `docs/superpowers/specs/2026-10-04-akis-denetimi-duzeltmeleri.md`." Metni değişen maddelerin kutuları boşaltılmalı.
18. **Kullanım rehberi** (`EV_OTOMASYON_KULLANIM_REHBERI.md`, F1 + C2): seri komut tablosunda `RESETKEY` satırı (≈ satır 487): «Yerel anahtarı siler (cihaz provizyonsuz olur). Yanıt: "Yerel anahtar SILINDI. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da /api/factory/init)"; yeniden anahtarlama tercihen aynı terminalden FACTORYINIT ile.»; sorun giderme tablosuna (Wi-Fi yedek yolu) "Cihaz anahtarı kalıcı belleğe yazamadı (storage)." | kartın kalıcı belleğine (NVS) yazılamadı | kartı yeniden başlatıp deneyin; sürerse "Hafızayı Sil (Erase Flash)" ile firmware'i yeniden yükleyin; Teknik Ek'teki imaj yolu varsa v1.1.2; "SMS ile giriş seçeneği yalnız sunucuda SMS sağlayıcı yapılandırılmışsa görünür."
