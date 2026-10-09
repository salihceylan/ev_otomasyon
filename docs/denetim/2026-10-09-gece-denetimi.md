# Gece Denetimi — 2026-10-09

> Tüm ev otomasyon projesi (sunucu, uygulama, firmware, servis yazılımı, bileşenler arası sözleşmeler) mantık hatalarına
> karşı tarandı. Yöntem: 7 alanda salt okunur tarama → birleştirme ve planlama → bileşen başına test önce yazılarak (TDD)
> düzeltme → çapraz inceleme ve tüm test paketleri → belge güncellemesi. Ekran ekran deneme yapılmadı (isteğiniz).
> Bu dosya iş akışı çıktısından betikle üretildi (elle yazılmadı).

## Özet

- **Aday bulgu:** 50 (yüksek 3, orta 18, düşük 29).
- **Birleştirme sonrası düzeltmeye alınan:** 42 madde (yüksek 5, orta 14, düşük 23); **elenen** 7 (tekrar/aynı kök); **kararınızı bekleyen** 19.
- **Düzeltilen:** sunucu 17, uygulama 16, firmware 5, servis yazılımı 4 (toplam 42 kayıt; bir madde birden çok bileşende düzeltildiyse her bileşende sayıldı).
- **Atlanan:** 1 (aşağıda, gerekçesiyle).
- **Testler (sabah benim koşumum):** sunucu PG'siz 2634 test (2454 geçti, 180 PG'ye bağlı atlandı, 0 hata); sunucu PG'li, yeni veritabanında 001-041 ile 2639 test (2638 geçti, 1 atlandı, 0 hata); uygulama analizi temiz, 4968 test geçti (485 önceden atlanan), 0 hata; servis yazılımı 576 test, 0 hata; firmware birim testleri 25 grup / 423 test, 0 hata; QA yığını 639/639.
- **Dağıtım:** Sunucu canlıda (2026-10-09 03:53; migration 039-041 uygulandı, şema sözleşmesi temiz, sağlık 200). Yedek: ~/backups/ev_20261009_005205. Geri alma: cd ~/ev_otomasyon && mv server server_bad && mv server_prev_20261009_005205 server && pm2 restart ev-api. /yasal/kullanici-sozlesmesi ve /yasal/gizlilik-politikasi 200 (TASLAK bandı); pano AHBU-S3-DD8754 yeniden başlatmadan hemen sonra çevrimiçi, anahtar izi aynı. Yeni APK: build/app/outputs/flutter-apk/app-release.apk. 15 commit yerelde, push sizde (dal master).
- **Firmware:** v1.3.2 paketlendi (firmware_releases/v1.3.2: birleşik 0x0 + uygulama 0x10000), derleme paketle bayt bayt aynı; KARTTA DENENMEDİ. Servis yazılımında seçili sürüm 1.3.1'de bırakıldı. Kart (COM9) gözetimsiz güncellenmedi; onayınızla yalnız uygulama bölümü (ayarlar korunur) yazılabilir.

## Düzeltilen maddeler

| Madde | Önem | Bileşen | Başlık | Kanıtlayan test |
|---|---|---|---|---|
| fw-tarama-1/app | yüksek | uygulama | Kablosuz sensor ekleme ve kopruye atama yalniz 'bridge' yetenegi bildiren panoda gosterilsin | test/models/safety_models_test.dart (supportsBridge, sensor_bridge_unsupported text); test/services/safety_contract_alignment_test.dart (LAN 400 cfg_invalid wi… |
| fw-tarama-1/firmware | yüksek | firmware | Firmware: surucusu olmayan kopru sensoru yazim yollarinda reddedilsin (acilista kayitli yapilandirma korunur); simulator aynasi | RED->GREEN: native test_safety_config/test_bridge_sensor_rejected_on_write_paths_only (did not compile: SENSOR_BRIDGE_UNSUPPORTED missing). Native test_templat… |
| fw-tarama-1/server | yüksek | sunucu | Kopru (kablosuz) sensor: sablon ve bulut yapilandirma dogrulamasi desteklenmeyen sensoru reddetsin | template_schema.test.js: b1 water / duplicate b16 -> sensor_bridge_unsupported (path safety.sensors); control kind on b1 -> sensor_src. safety_cfg_patch.test.j… |
| fw-tarama-1/tool | yüksek | servis yazılımı | Servis yazilimi sablon dogrulayicisi kopru sensorunu sunucuyla ayni kodla reddetsin | tests.test_site_template.FixtureValidationTests.test_bridge_sensor_is_refused_with_the_server_code. RED: a b1 water sensor was accepted (issue None). GREEN: a … |
| uygulama-ekranlar-1 | yüksek | uygulama | Biyometrik yeniden kilit servis kurulum sihirbazini kapatmasin; sihirbaz tek giristen (adlandirilmis rota + yarim kayit sorusu) acilsin | test/ui/auth_gate_wizard_relock_test.dart (relock after 31 s: opaque non-poppable '/biometric-lock' route on top, wizard stays in the stack, same State object … |
| cekirdek-1 | orta | uygulama | Misafir erisimi acilinca/uzatilinca canli kanal baslasin; baslangic ve bitis sunucu saatine gore hesaplansin | test/services/guest_window_test.dart (not_started -> active: MQTT starts and REST loads; extension after expiry restarts MQTT; valid_from timer calls fetchHome… |
| cekirdek-2 | orta | uygulama | Uc nokta listesi yuklenemezse canli kanal baglaninca yeniden denensin; kritik alarm karti bu durumda da gorunsun | test/services/state_load_retry_test.dart (after the 4 automatic retries are used up, a connected transition and a live snapshot each trigger one reload); test/… |
| cekirdek-3 | orta | uygulama | Guvenli depo okunamadiginda arka plan alarm izleme ayari kapatilmasin | test/ui/alarm_watch_card_test.dart (cold start with failReads: no stop, setting stays enabled; a real logout afterwards stops the service via the logout hook) |
| fw-tarama-3 | orta | firmware | Onay suresi (confirm_ms) tur penceresinden uzunsa pencere buyusun; tehlike sensoru alarmsiz kalmasin | RED->GREEN: qa_stack fw_sensor_hub '(fw-tarama-3)' failed with 'gelen 0': gas at 1500 ms never confirmed after 10 s of continuous activity. Also added the wind… |
| hesap-uyelik-3 | orta | sunucu | Telefon-OTP girisi yalniz dogrulanmis telefona baglansin (users.phone_verified) | auth_phone_verified.test.js (the probe test made permanent): register with a phone + OTP -> 409 CONFLICT, reason PHONE_NOT_VERIFIED, exact message. No new acco… |
| sko-1 | orta | sunucu | Cevrimdisi panoya kuyruklanan alarm onayi, isteyenin yetkisi bitince ya da 24 saatten eskiyse iletilmesin | alarm_service.test.js: a revoked or expired service session means no alarm_ack is sent; the request is dropped and audited as 'alarm_ack_request_dropped' {reas… |
| sko-2 | orta | sunucu | Guvenlik alarmi push'u gecici hata ya da yeniden baslatmada kaybolmasin (acik alarmda en az bir kez teslim) | alarm_service.test.js: FCM throws twice -> 'failed'; after +61 s, retryStuckPushes sends it (sent, attempts 2). claimed/sending older than 3 min and pending ro… |
| sozlesme-1 | orta | sunucu | Bootstrap IP butcesini yalniz basarisiz (200/202 disi) istekler harcasin | 61 different cards from one IP all get 202 (and 200), where the 61st used to get 429. After 60 x 401, the 61st request gets 429 + Retry-After and the service i… |
| tarama-sunucu-cihaz-site-1/app | orta | uygulama | Pano degisimi sonucu: guvenlik ayarlari aktarilmadiysa 'bir sey yapmaniz gerekmez' denmesin | test/ui/replace_board_result_roles_test.dart (required -> card 'replace_safety_restore_warning' plus 'Güvenlik ayarları (su/gaz sensörü, vana) yeni panoya akta… |
| tarama-sunucu-cihaz-site-1/server | orta | sunucu | Pano degisimi: guvenlik yapilandirmasi aktarilmadiginda yanit bunu acikca soylesin (ara cozum) | replace_board.test.js: a sensor or actuator in the old board's safety copy -> 'required' + C4 warning + new message, and safety_restore in the audit record. ac… |
| tarama-sunucu-cihaz-site-6 | orta | sunucu | Daire durumu: baska sablonun yazimi 'Yazildi' yapmasin; kart ayirma/degistirme durumu tutarli tutsun | site_flat_write_link_pg.test.js (real PG): writing T2 to a T1 flat records the write, the flat stays 'planned', and the response has warning + flat_template_id… |
| uygulama-ekranlar-2 | orta | uygulama | Kapi gorunumu (sozlesme onayi / zorunlu parola) acikken bildirim yonlendirmesi, etiket baglantisi ve gece afisi bekletilsin; bekletilen dokunus ev listesi gelince islens… | test/services/safety_notice_controller_test.dart (terms gate and forced-password gate hold the tap until the gate passes; a tap made while logged out survives … |
| uygulama-ekranlar-3 | orta | uygulama | 'Panoyu Hazirla': kurulum agi (AP) parolasi iki kez girilsin ve etiketle karsilastirilsin | test/ui/f_setup_device_steps_test.dart (mismatched entries -> validation 'Kurulum ağı parolaları eşleşmiyor.', differs from label -> 'Yazdığınız parola etikett… |
| cekirdek-6 | düşük | uygulama | Yasal onay durumu buluta geciste ve on plana donuste (en cok 12 saatte bir) esitlensin | test/services/legal_state_test.dart (session opened in LAN mode -> setMode(cloud) -> fetchMe and needsTermsAcceptance true; resume after 13 h -> one fetchMe, r… |
| cekirdek-7/server | düşük | sunucu | GET /homes: misafir ve kurulum erisim penceresi icin sunucu saatine goreli kalan sureler | With a mocked server clock: guest [30, 7200] (start rounded up, end rounded down); active guest [0, 90]; expired guest [0, 0]; owner [null, null]; service_user… |
| fw-tarama-4 | düşük | firmware | Ek modul kanal sayisi azalinca kapsam disi roleler kapatilsin; EXTMOD ek panjur hareket ederken reddedilsin | RED->GREEN: sim_automation out-of-range OFF test (channel 13 stayed on after 16->8). sim_automation retry test, including dropping after 5 attempts on a channe… |
| fw-tarama-5 | düşük | firmware | Kilit kaydi, hirsiz kipi ve vana konumu NVS yazimi basarisizsa yeniden denensin | RED->GREEN in the simulator with NvsImage.failKeys fault injection. sim_safety_hooks latch test (the record was never written after the fault cleared) and the … |
| hesap-uyelik-5/app | düşük | uygulama | Katilim/devir: hata ya da zaten-uye yanitinda ev listesi tazelensin ve ev secilsin | test/family_sharing_test.dart (network error then 410 on join -> fetchHomes each time; transfer 410 -> fetchHomes; transfer already_member parsed and the home … |
| hesap-uyelik-5/server | düşük | sunucu | Ayni kullanicinin davet/devir kodunu yeniden gondermesi idempotent basari donsun | Second join and second accept by the same user -> 200 already_member with the C3 messages, no writes, MQTT or cleanup. Another user, or a user who is no longer… |
| hesap-uyelik-6 | düşük | sunucu | Dondur/coz: davet bekleyen hesap 'active' olmasin, silinmis hesap dondurulamasin/acilamasin | pending_invite freeze/unfreeze keeps 'pending_invite' (it used to become suspended/active). Soft delete of a pending_invite account only sets is_active=FALSE. … |
| hesap-uyelik-7 | düşük | sunucu | Davet ve servis PIN'i uretimi sahiplik degisimiyle yarismasin (ayni islemde yetki yeniden dogrulansin) | Membership row deleted after the middleware check (concurrent transfer) -> 403 'Bu işlem için yetkiniz yok.' and no invitation/PIN is created (it used to be 20… |
| sko-3 | düşük | sunucu | Pano degisimi sonrasi panjur suresi esitlemesi yalniz panonun onayiyla 'synced' sayilsin | Board with caps 'intrusion': the waiter is set up before publish (5000 ms, uid). A rejection or timeout leaves the marker pending and backs off; once confirmed… |
| sko-4 | düşük | sunucu | Zamanli kural: yayindan onceki gecici DB hatasi yuvayi tuketmesin | If SQL.devices or SQL.creator throws once: the slot is logged 'failed', released is true and the claim is given back; the next minute's tick sends it. |
| sko-5/firmware | düşük | firmware | Firmware: state.cfg.safety.id ile bulut yamasinin hangi rev'i urettigini bildir | RED->GREEN: native test_safety_view/test_cfg_safety_id_echo did not compile (StateMeta.cfgId missing). The sim_safety 'C6 (sko-5)' MQTT flow failed with cfg.sa… |
| sko-5/server | düşük | sunucu | Yapilandirma kuyrugu: bas ogenin uygulandigini state.cfg.safety.id ile dogrula (araya giren komut kuyrugu dusurmesin) | With last_id from another command and cfgId equal to the head item -> applied_inferred; the queue is not dropped and there is no push (it used to be a conflict… |
| sko-6 | düşük | sunucu | Sistem doktoru: bulut-MQTT kopru kesintisini evin elektrik/internet arizasi diye teshis etmesin | Bridge disconnected (or reconnected within 120 s): a stale board is UNKNOWN/UNKNOWN/warning with the C15 texts and a null action; no 'Güç Kesik' or 'Wi-Fi Kurt… |
| sozlesme-4 | düşük | servis yazılımı | Sablon geri okumasi 'YARIM' (incomplete) durumunu ve yazim oncesi kaydi hesaba katsin | RED then GREEN. LanTemplateWriterTests: test_pending_apply_on_an_incomplete_board_is_not_reported_as_written, test_pending_apply_succeeds_once_the_incomplete_f… |
| sozlesme-5 | düşük | servis yazılımı | Envanter sekmesine arama ve 'Daha fazla' (sayfalama) eklensin | RED then GREEN: ServerClientTests.test_list_inventory_passes_search_and_offset (list_inventory takes search, trimmed to 64 characters, and offset); AppSmokeTes… |
| sozlesme-6 | düşük | uygulama | Uygulama ev/{t}/status yukundeki uid'yi kullansin: bir panonun LWT'si tum evi cevrimdisi gostermesin | test/services/device_presence_test.dart (two uids online, B offline -> home stays online, both offline -> offline; offline without uid -> offline as before); t… |
| tarama-sunucu-cihaz-site-3/server | düşük | sunucu | E-postasiz (telefon-OTP) musteri icin sahiplenme kodu istenince acik hata donsun | A phone target whose account email is a placeholder -> 400 VALIDATION, reason CUSTOMER_EMAIL_REQUIRED, C8 message. No mailer call and no OTP row. claimDevice g… |
| tarama-sunucu-cihaz-site-6/tool | düşük | servis yazılımı | Servis yazilimi: FLAT_TEMPLATE_MISMATCH uyarisini gostersin, 'Son yazim' farkli sablonu isaretlesin | SiteTemplateAppTests (RED then GREEN): test_flat_last_write_column_marks_a_write_of_another_template ('(farklı şablon)' is added and versions are no longer com… |
| uygulama-ekranlar-5 | düşük | uygulama | Zamanli kural diyalogu guvenlik eylemcisi kanallarini (vana/siren/fan) listelemesin | test/scheduled_rules_test.dart (valve, siren and fan channels left out; the first (default) option is a valid channel) |
| uygulama-ekranlar-6 | düşük | uygulama | 9. adim (Duvar Butonlari) guvenlik rolune atanmis girisleri buton saymasin | test/ui/f_setup_device_steps_test.dart (d3 water sensor and fb_di 2 -> buttons [1, 4], safetyInputCount 2, isComplete depends only on the real buttons) |
| uygulama-ekranlar-7/app | düşük | uygulama | Oda cipleri yalniz gosterilen satirlardan turetilsin (panjurun ikincil satiri haric) | test/ui/room_options_test.dart (primary row room 'Yatak Odası', secondary row room 'Çocuk Odası' -> no 'Çocuk Odası' chip) |
| uygulama-ekranlar-7/server | düşük | sunucu | Panjur ciftinin ad ve odasi iki satira birlikte yazilsin | Room on the primary row is also written to the pair's other row. The lock order is unchanged and each row gets one UPDATE; duration+name+room go in one UPDATE.… |
| tarama-sunucu-cihaz-site-3 (app side) | - | uygulama | (plan dışı / ortak madde) | test/ui/f_setup_controller_test.dart (400 VALIDATION with reason CUSTOMER_EMAIL_REQUIRED -> why is the server message, todo points to the customer's own QR cla… |
| sko-6 (app side) | - | uygulama | (plan dışı / ortak madde) | test/system_doctor_and_disaster_recovery_test.dart (cloud DEGRADED + network/power UNKNOWN -> levels unknown, suggestsWifiRecovery false; existing case without… |

**Planda olup düzeltme kaydı olmayan maddeler:**

- sozlesme-2 (servis yazılımı): Ethernet'ten sablon yazimi kartin UID'sini dogrulasin; yanlis IP'deki karta yazilmasin
- docs-gece-1 (belge): Belgeler: bu gecenin sozlesme degisiklikleri CONTRACTS.md ve akis belgelerine islensin

**Atlananlar:**

- sozlesme-2 (servis yazılımı): This would reverse an explicit user decision. On 2026-10-08 the user approved removing the IP-UID pre-check for Ethernet template writes, after being shown the risks. Evidence: commit c365995 'kullanici karari - ... IP-UID on denetimi ... kaldirildi' (it deleted TemplateLanWriter.verify_identity, which did exactly this GET /api/status check); docs/superpowers/plans/2026-10-08-site-sablon-kurulum.…

## Kararınızı bekleyen maddeler

Bunlar ürün, hukuk ya da altyapı kararı gerektirdiği için bu gece uygulanmadı.

### karar-yerel-anahtar-personel — Personel ve super yoneticinin musteri panosunun yerel anahtarini okumasi yasal metinlerle celisiyor (hesap-uyelik-1)

GET /admin/inventory/:uuid/local-key (site_template_routes.js:159, site_template_service.js:778-809) CLAIMED musteri karti dahil her anahtari suresiz donduruyor (2026-10-08 kullanici karari: Ethernet sablon yazimi icin 'musteri karti dahil'); bu gece yazilan gizlilik-politikasi.md:143-144, kullanici-sozlesmesi.md:137 ve docs/yasal/README.md:265-266 aksini soyluyor; pano-6 anahtar donusu personele karsi etkisiz. Davranis ya da metin degismeli: urun + hukuk karari.

**Seçenekler:** A) Uc daraltilsin: service_user yalniz IN_STOCK karta ya da gecerli (installer_expires_at dolmamis) service_user uyeligi olan evdeki karta; super_user (karar 3) korunur, metin super icin duzeltilir (denetim kaydiyla). B) Davranis kalsin; metinler, README §7 ve CONTRACTS §1.4 personel/yoneticinin anahtari suresiz okuyabildigini acikca yazsin. Oneri: A (Ethernet yazimi stoktaki kartta ve kurulum penceresinde calismaya devam eder).

### karar-servis-pin-kaba-kuvvet — Servis PIN'ine dagitik kaba kuvvet (hesap-uyelik-2)

6 haneli kuresel PIN; genel butce dolunca her yeni ag 15 dk'da 3 deneme aliyor, toplam tahmin saldirganin ag sayisiyla buyuyor (uyelik-15 duzeltmesinin siniri). DoS (teknisyenin kilitlenmesi) ile kaba kuvvet arasindaki takas ve PIN bicimi urun karari.

**Seçenekler:** A) PIN eve baglansin (PIN + ev sahibinin ekranindaki kisa ev kodu/QR; sunucu + uygulama). B) PIN 8-10 haneye ciksin. C) Genel butce dolunca tum yeni aglar da engellensin (ev sahibi 'PIN'i yeniden uret' ile asar). Oneri: A; kisa vadede B.

### karar-telefon-bicimi — Telefon numarasi kanonik bicimi ve telefonla devir (hesap-uyelik-4)

normalizePhone ulke kodunu bilincli olarak eklemiyor (validators.dart:58-63); '+90555...' ve '0555...' farkli sayiliyor, telefonla baslatilan devir alici hesabinda ayni bicim yoksa kabul edilemiyor ve alici telefonunu ekleyemiyor. Kanoniklestirme ve mevcut verinin donusumu urun karari.

**Seçenekler:** A) TR varsayilanli E.164 kanonik bicim (sunucu normalizePhone, device_service.normalizeIdentifier, Flutter AuthValidators) + cakisma raporlu veri migration'i. B) Yalniz karsilastirmada TR esdegerligi (identityMatches ve join preview), veri degismez. C) Degismesin; devir ekrani e-postayi onersin ve telefon eslesme kosulunu soylesin. Oneri: A; acil ara cozum B.

### karar-dondurma-yetkisi — Personelin super yoneticinin dondurmasini kaldirabilmesi (hesap-uyelik-6 kalan kismi)

Personel kendi actigi musteri hesabinda is_active degistirebiliyor (admin_user_service.js:57-61, :310) ve dondurmayi kimin yaptigi tutulmuyor; personel yetkisi gizlilik metninde (5.2) yazili. Davet bekleyen ve silinmis hesap hatalari bu gece duzeltiliyor (hesap-uyelik-6).

**Seçenekler:** A) suspended_by_role saklansin (migration), personel superin dondurmasini kaldiramasin (403). B) Degismesin. Oneri: A.

### karar-sozlesme-kaydi-saklama — Kalici silmede sozlesme kabul kayitlari (hesap-uyelik-8)

039_legal_acceptances.sql:38 ON DELETE CASCADE; yonetici kalici silmesi (admin_user_service.js:517) kabul kayitlarini siliyor; gizlilik-politikasi.md:198 ve :227 hesap silinse de saklandigini soyluyor. Saklama suresi/ispat yukumlulugu hukuk karari.

**Seçenekler:** A) legal_acceptances.user_id ON DELETE SET NULL; anonim kabul kaydi saklanir. B) CASCADE kalsin, metin kalici silmede kabul kayitlarinin da silindigini soylesin. Oneri: A (hukuk onayiyla).

### karar-evden-ayrilma — Aile uyesi ve misafirin evden kendisinin ayrilmasi (hesap-uyelik-9)

Sahip olmayan uye kendi uyeligini sonlandiramiyor; tek cikis tum hesabi silmek. Yeni ozellik (uc + ekran + metin).

**Seçenekler:** A) DELETE /homes/:homeId/members/me (owner haric; MQTT kimlikleri iptal, resident icin pano-6 donusu) + uygulamada 'Evden ayrıl'. B) Degismesin (ev sahibi cikarir). Oneri: A, sonraki surum.

### karar-pano-degisimi-geri-yukleme — Pano degisiminde yerlesim ve guvenlik yapilandirmasinin yeni panoya geri yuklenmesi (tarama-sunucu-cihaz-site-1)

replaceBoard yalniz bulut kayitlarini tasiyor; panodaki yerlesim ve guvenlik (sensor/vana/bolge) yapilandirmasi yazilmiyor. Buluttaki kopyadan geri yukleme K5'e (asil kaynak panodaki NVS) dokunuyor. Bu gece yalniz durust uyari (safety_restore) ekleniyor.

**Seçenekler:** A) Buluttaki son kopyadan 'restore' niyeti; uzlastirici cfg yetenekli canli panoya uygular (K5 istisnasi). B) Guvenlik yapilandirmali evde ev sahibinin kendi basina degisimi engellensin, teknisyen zorunlu. C) Yalniz uyari (bu geceki durum). Oneri: kisa vadede B, sonraki surumde A.

### karar-cihaz-mqtt-kimligi — Erisimi biten kisinin elindeki cihaz MQTT kimligi d_{t} yenilenmiyor (tarama-sunucu-cihaz-site-2)

Cihaz kimligini alan servis oturumu/uye erisimi bittikten sonra ayni kimlikle paralel baglanip cmd/sys dinleyebiliyor, sahte olay yayinlayabiliyor, pano-6'nin yeni anahtarini sys'ten yakalayabiliyor. Eski firmware'de (bootstrap'siz) kimlik donusu panoyu buluttan dusurur; EMQX authn sorgusuna client_id baglamak sunucuda altyapi degisikligi (EMQX yapilandirmasi/dagitim) ister.

**Seçenekler:** A) Erisim biterken (oturum sonu/iptal, owner cikarma, devir, assign-admin) d_{t} dondurulsun ve kick (fw >= 1.3.0 bootstrap ile yenisini alir); anahtar rotasyonu kimlik yenilendikten sonra yayinlansin. B) EMQX'te cihaz kimligi icin client_id = kullanici adi kosulu (paralel oturum yok). C) Degismesin. Oneri: A + B; eski firmware icin A atlanir.

### karar-sahiplenme-sms — E-postasiz (telefon-OTP) musteriye personel sahiplenmesi icin SMS (tarama-sunucu-cihaz-site-3)

Onay kodu yalniz e-postayla gidiyor; telefonla kayitli musteri icin kod gonderilemiyor. SMS saglayicisi ve maliyet karari; bu gece yalniz acik hata iletisi (CUSTOMER_EMAIL_REQUIRED) ekleniyor.

**Seçenekler:** A) Claim OTP'si SMS ile (saglayici baglaninca). B) E-postasiz musteri yalniz kendi sahiplenmesiyle kurulsun (bu geceki ileti bunu soyler). Oneri: SMS acilana kadar B.

### karar-alarm-gecmisi-devir — Devir/acil sifirlama/Home Admin atamasindan sonra onceki ailenin alarm gecmisi (tarama-sunucu-cihaz-site-7)

home_cleanup.js:117-147 alarmlari ve device_events'i kapsamiyor; GET /homes/:id/alarms?state=all tarih/sahiplik suzgeci yok. Mulkun guvenlik gecmisi ile onceki ailenin gizliligi arasinda tercih.

**Seçenekler:** A) homes.ownership_epoch ve listAlarms'ta (raised_at >= epoch OR acik) suzgeci. B) Ev temizliginde kapali alarmlar arsivlensin. C) Degismesin. Oneri: A.

### karar-kalici-silme-panolu-ev — Super yoneticinin kalici silmesinde panosu takili tek sahipli ev (tarama-sunucu-cihaz-site-8)

admin_user_service.js:478-510 cihaz sayisina bakmadan evi 'bos daire' sayip siliyor; tetikleyici envanteri SUSPENDED yapar, pano buluttan duser; kendi silmede (account_deletion_service.js:186-200) ayni durum engelleniyor. KVKK silme talebinde ev ve panonun akibeti urun/yasal karar.

**Seçenekler:** A) Kendi silmedeki gibi 409 SOLE_OWNER_WITH_DEVICES (once devir/acil sifirlama). B) force + gerekce ile sil ve panoyu stoga al (IN_STOCK + etiket yenileme). C) Degismesin. Oneri: A (+ 'bos daire' iletisinin duzeltilmesi).

### karar-kablosuz-sensor-kapsami — Kablosuz (kopru) sensor urun kapsaminda mi? (fw-tarama-1)

Hub surucusu yok; bu gece 'bridge' yetenek kapisi ve yazim reddiyle guvenli hale getiriliyor (karar gerektirmez). Ozelligin kaldirilip kaldirilmayacagi ya da surucunun ne zaman gelecegi urun karari.

**Seçenekler:** A) Kapsam disi: uygulama/arac/sablon semasindan tamamen kaldirilsin. B) Yakinda: caps 'bridge' kapisiyla kalsin (bu geceki durum). C) Surucu gelistirilsin. Oneri: B.

### karar-bulut-host-degisikligi — Yerel anahtarla (Ethernet'te anahtarsiz) bulut MQTT host'unun degistirilebilmesi (fw-tarama-2, yuksek)

WebPortal.cpp:622 ve :1913-1937 /api/mqtt/config host'u yalniz sozdizimiyle denetliyor; TLS koku ISRG oldugu icin sertifikali her alan adi geciyor; pano saldirganin broker'ina tasinip cmd/sys (vana, alarm cozme, set_local_key) ile kalici denetime giriyor, anahtar donusu panoya ulasmiyor. Hangi host'larin kabul edilecegi (gelistirme/QA broker'i; uretimdeki MQTT_PUBLIC_HOST'un firmware DEFAULT_MQTT_SERVER ile ayni olup olmadigi - .env okunamadi) altyapi bilgisi ister ve Ethernet anahtarsiz yetkiyle (karar 1, guvenlik-14) birlikte degerlendirilmeli.

**Seçenekler:** A) Firmware host'u derleme ici izin listesine (DEFAULT_MQTT_SERVER + derleme bayragi) sinirlasin; farkli host yalniz seri CLI/fabrika yolunda; bootstrap yaniti da ayni kurala tabi. B) Ilk basarili bulut baglantisindan sonra host sabitlensin (TOFU), degisiklik yalniz seri/fabrika sifirlamada. C) Degismesin. Oneri: A, oncelikli (once uretimdeki MQTT_PUBLIC_HOST'un firmware varsayilaniyla ayni oldugu dogrulanmali).

### karar-kilitliyken-fabrika-sifirlama — Kilitliyken zorla fabrika sifirlamasinda 1-4. rolelerdeki vana (fw-tarama-6)

WebPortal.cpp:1767-1803 ?force=1; varsayilan yapilandirma role 1-4'u panjur yapar ve stepOutputs kilit maskesini ezer (SmartAutomation.cpp:1058-1074); [Y-5] kilidin korunmasi ile panjur kilidi onceligi catisiyor; role gercekten motora baglanmissa maskeyi dayatmak motoru surer.

**Seçenekler:** A) Kilitliyken agdan force sifirlama reddedilsin (yalniz seri). B) Varsayilan yapilandirma kilit/safe maskesindeki roleleri LIGHT biraksin. C) stepOutputs actuatorMask'teki roleyi ezmesin. Oneri: A.

### karar-sunucu-kapilari — Sozlesme onayi ve zorunlu sifre degisiminin sunucuda zorlanmasi (cekirdek-6, uygulama-ekranlar-2 notu)

Iki kapi yalniz uygulamada; sunucu hicbir ucta zorlamiyor (legal_service.js:86-101; middlewares'te eslesme yok). Bu gece istemci kapilari duzeltiliyor; sunucu zorlamasi eski uygulama surumlerini etkiler.

**Seçenekler:** A) Ara katman: /auth/* ve /legal disindaki uclarda 403 TERMS_REQUIRED / PASSWORD_CHANGE_REQUIRED (yeni uygulama yayginlasinca). B) Yalniz istemci (bugunku). Oneri: A, surum gecisinden sonra.

### guvenlik-14 — (dunden acik) Ethernet anahtarsiz erisimi (karar 1/2) gaz vanasi ve hirsiz alarmi kurallarini deliyor

fw-tarama-2 ayni Ethernet anahtarsiz yetki yolunun bulut host'unu da degistirebildigini gosteriyor; iki karar birlikte verilmeli.

**Seçenekler:** A) Oldugu gibi birakip belgeye yazmak. B) Dar duzeltme: isGasRelease her ag yolunda reddedilsin (409 gas_local_only), /api/arm Ethernet'te de X-Device-Key istesin, Ethernet olaylari VIA_ETH ('eth') ile kaydedilsin. Oneri: B (dunku oneri), karar-bulut-host-degisikligi A ile birlikte.

### kayit-dogrulama — (dunden acik) Kayitta e-posta/telefon dogrulamasi zorunlu degil

hesap-uyelik-3 (dogrulanmamis telefonla OTP girisi) ve tarama-sunucu-cihaz-site-3 ayni kokten. Bu gece phone_verified ile OTP girisi kapatiliyor; bilinen yan etki: baskasinin dogrulanmamis hesabina yazilmis telefonun sahibi SMS girisinden 409 PHONE_NOT_VERIFIED alir (kayitta dogrulama bunu cozer).

**Seçenekler:** A) Bekleyen kayit modeli (e-posta/telefon dogrulaninca hesap acilir). B) Bugunku sifirlama + davet. Oneri: A, sonraki surum.

### bireysel-9-yayin — (dunden acik) Android App Links / iOS Universal Links dogrulama dosyalari

uygulama-ekranlar-2 etiket baglantisinin (/claim) kapi arkasinda beklemesini sagliyor ama dogrulama dosyalari hala yok; release imza SHA-256 parmak izi, applicationId ve Apple Team ID gerekir (ajanlar uyduramaz).

**Seçenekler:** Kullanici degerleri verince sunucu/nginx sablonuna eklenip dagitilir.

### bireysel-5-eth — (dunden acik) Girissiz kullaniciya Ethernet'teki anahtarsiz erisim uygulamada da acilsin mi?

fw-tarama-2 Ethernet'te anahtarsiz erisimin bulut host'unu da degistirebildigini gosteriyor; uygulamadan bu yetkiyi girissiz kullaniciya acmak riski artirir.

**Seçenekler:** Oneri (dunku gibi): acilmasin.

## Elenen adaylar

- **tarama-sunucu-cihaz-site-4:** sozlesme-1 ile ayni bulgu (bootstrap IP butcesi); kanit sozlesme-1 maddesinde birlestirildi.
- **sozlesme-3:** tarama-sunucu-cihaz-site-6 ile ayni bulgu (recordWrite sablon denetimi); sunucu kismi tarama-sunucu-cihaz-site-6, arac kismi tarama-sunucu-cihaz-site-6/tool maddesinde.
- **tarama-sunucu-cihaz-site-5:** Gecerli; ayni dosya ve akis (site_template_service daire durumu) oldugu icin tarama-sunucu-cihaz-site-6 maddesine katildi (C13 kurallari).
- **cekirdek-8:** hesap-uyelik-5 ile ayni desen (katilim/devir yinelemesi 410); hesap-uyelik-5/server ve hesap-uyelik-5/app maddelerine katildi.
- **cekirdek-4:** uygulama-ekranlar-2 ile ayni bulgu (kapi gorunumunun bildirim/afisle asilmasi); karar kismi planlayicida (bekletme) cozuldu, sunucu zorlamasi karar-sunucu-kapilari'nda.
- **cekirdek-5:** Gecerli; ayni denetleyici (SafetyNoticeController._held) oldugu icin uygulama-ekranlar-2 maddesine katildi.
- **uygulama-ekranlar-4:** Gecerli; sihirbazin tek giris noktasi (adlandirilmis rota + yarim kayit sorusu) ile birlikte cozulecegi icin uygulama-ekranlar-1 maddesine katildi.

## Çapraz inceleme notları

- FIXED (app, high; fw-tarama-1/app vs firmware C1). Removing a bridge sensor never deleted it from the board. RelayLogic.removeBridgeSensor drops the slot from the plan, but buildSafetyPatches only deleted board sensors whose input was still in the plan, so no del patch was sent. Firmware v1.3.2 checks the whole table on every write (validate(forWrite)) and rejects each set patch with cfg_invalid/sensor_bridge_unsupported. Result: the plan could never be saved over LAN or cloud. Fix: a board sensor with id bN that is missing from the plan now gets a del patch, and deletes still come first. Tests: a unit test (seen failing first) and a widget test that removes b1 and saves through the fake bo…
- FIXED (app, low; sko-6 vs C15). In the 120 s after the bridge reconnects, the server sends network UNKNOWN, the C15 cloud text and action null, while cloud.status is OK. The app suggested Wi-Fi recovery in that window because its rule required cloud != OK. Since tonight the server sends network UNKNOWN only on the C15 path, so the app no longer suggests recovery when network is UNKNOWN and the report has a cloud block. A partial report without a cloud block keeps the old behaviour, and the existing tests still pass. New test seen failing first.
- NEEDS USER DECISION: the tool fixer skipped sozlesme-2 (check the card UID before an Ethernet template write). The user's 2026-10-08 decision K-S4 (commit c365995) removed this IP-UID pre-check on purpose, and a plan item does not override it. The risk stays open: a wrong IP writes the template to the wrong card and marks the flat 'Yazıldı'. The docs must keep saying the UID is not checked.
- RESIDUAL (server, low; hesap-uyelik-7). Rare deadlock: invitation/PIN creation now locks home_users FOR SHARE, then the FK takes a key-share lock on the homes row. Emergency reset and assign-admin lock homes FOR UPDATE, then DELETE home_users. If both run at the same instant, Postgres may abort one transaction with a 500; a retry works and no data is corrupted. Reversing the order would deadlock with account deletion instead (home_users, then homes). Not changed.
- NOTE (server, sko-2 deploy). On the first runs after deploy, alarms from before tonight that are still latched/fault and whose push failed (fewer than 5 attempts) or is stuck pending/claimed/sending will be pushed again. This is intended by C12. The once-a-minute stuckPushes query may later need an index.
- NOTE (tool/server, C1 edge). A server template that already contains bridge sensors now fails validation. Only a raw API call could have created one. The tool editor shows these sensors as 'değiştirilmeden korunur' and cannot remove them. A claim seed from such a template falls back to the fixed seed. Not changed.
- NOTE (app, wording). Behind a gate, the /claim page asks the user to re-scan the label, but it also opens the claim dialog by itself once the gate passes. Not changed.
- INTERMITTENT: in the first full PG run, server/test/devices/local_key_pending_pg.test.js failed at file level with no subtest run. It is not on the known list (PG D4, phase2_pg). It passed alone (9/9) and the full rerun was green. This matches the runner-level flakiness the server fixer already reported.

## Tarama kapsamı (ajanların kendi beyanı)

### tarama-sunucu-hesap-uyelik

İncelenen (kod okuma, çağıran -> çağrılan): auth_service (register + accept_terms_version, login, refresh dönüşümü ve uyelik-2 toleransı, logout/logout-all, revokeAllUserSessions, _revokeUserServicePins, neutralizeUnverifiedAccount, setPassword, changePassword, şifre sıfırlama/issueUserCode/_consumeResetRequest, magicLogin, telefon OTP gönder/doğrula, Google/Apple + _loginWithSocial, publicUser.legal); auth_routes ve tüm hız sınırlayıcıları; legal_service, legal_routes, server.js bağlama sırası, migration 039, legal metinlerin personel erişimi / silme / saklama bölümleri, docs/yasal/README §6-7; auth_middleware (authenticateToken, requestTargetsHome, requireHomeAccess, misafir penceresi, staff/servis oturumu), jwt_config, rate_limit, error_handler; role_matrix ve CONTRACTS §1.1b-1.5c; admin_user_service + admin_routes; account_deletion_service; invitation_service + routes; join_preview; transfer_service + routes; home_cleanup; service_token_service + service_routes; service_panel_service (assign-admin) + routes; device_service'in üyelik kısımları (claimDevice müşteri hesabı, emergencyReset yeni sahip); site_template_service.getInventoryLocalKey; push alıcıları; MQTT kimlik süresinin rol bağları; migration kısıtları (001/007/016/018/027/039). Uygulama tarafında yalnız ilgili sözleşme noktaları (telefon normalizasyonu, devir diyaloğu, katılım diyaloğu, davet isteği, legal alan adları). Çalıştırılan: yalnız bir bellek içi kanıt testi (scratchpad/hesap-uyelik-probe/otp_phone_pro…

### tarama-sunucu-cihaz-site

İncelenen (okuma ile, çağıran->çağrılan->veri): device_service.js claim (OTP, PIN kilidi, müşteri hesabı, daire tohumu), acil sıfırlama (pending/direct anahtar planı, temizlik, yayın), pano değişimi, yerel anahtar/kimlik yeniden üretimi, devreye alma; inventory_service + inventory_routes (kayıt, etiket yenileme, PIN kilidi kaldırma, durum geçişleri, silme); device_bootstrap_service + routes (aday anahtarlar, tekrar koruması, oran sınırları); local_key_rotation + tetikleyicileri (invitation_service.removeHomeMember, transfer_service.acceptTransfer, service_panel_service.assignAdmin, account_deletion_service, service_token_service süpürücüsü); device_reconciler yerel anahtar bölümü ve mqtt_bridge lk_fp yazımı; mqtt_credential_service + mqtt_routes; emqx.conf/acl.conf; site_template_service + routes (daire durum geçişleri, yazım kaydı, envanter yerel anahtarı); service_panel_service + routes; home_cleanup; admin_user_service.deleteUser; auth_middleware.requireHomeAccess; role_matrix; rate_limit; migration 020, 021 (FK/tetikleyici), 032, 035-038. 2026-10-08 denetim tablosu ve inceleme notları karşılaştırıldı; bilinen maddeler (karar 8 bootstrap notu, envanter yerel anahtarı kullanıcı kararı, çok panolu ev sınırları - CONTRACTS DAIRE-04, personel anahtar rotasyonu) yeniden raporlanmadı; bulgu 2, devir için bilinen 'düşük' notun servis oturumu/assign-admin genellemesidir. Kardeş bulucu dosyaları (hesap-üyelik, köprü-otomasyon) başlıkça kontrol edildi, çakışma yok. İncelenmeyen / d…

### tarama-sunucu-kopru-otomasyon

Incelenen (cagiran -> cagrilan -> veri): mqtt_bridge.js (state/status/event alimi, duz+JSON status, uid eslemesi, lk_fp, ack/outcome bekleyicileri, kuyruk birlestirme, supurucu, kapanis), device_reconciler.js tamami (cocuk kilidi, panjur sureleri, bekleyen anahtar + lk_fp takasi), local_key_rotation.js, device_bootstrap_service.js, device_service komut yolu (sendCommand, _assertCommandTarget, _sendSafetyCommand, _applyChildLock, replaceBoard, emergencyReset commit sonrasi, getSystemDiagnostic), endpoint_service.js, endpoint_routes, device_routes, home_device_routes, mqtt_routes + mqtt_credential_service (kimlik/ACL), scheduler.js tamami + scheduled_rules_service/routes + rule_creator, safety_routes/safety_service, alarm_service (olay, state uzlastirmasi, push, onay kuyrugu), safety_cfg_sync (REST + kuyruk), peace_reminder.js, peace_service.js, peace_snapshot.js, push_service (jeton/alicilar), push_routes, role_matrix + requireHomeAccess, transfer_service/home_cleanup yan etkileri, EMQX acl.conf/emqx.conf (authn/authz), ilgili migration'lar (011/022/030/033/034/037/038). Firmware'de yalniz sozlesme kesitleri dogrulandi (komut ayristirma, uid filtresi, ALL_LIGHTS_OFF, alarm ack, state yayini, UID bicimi); lk_fp test vektorleri sunucu uygulamasiyla dogrulandi (c7076562 / 9814f286). Calistirilan test: server test/bridge + test/peace + test/layout (PG'siz): 1038 test, 957 gecti, 0 basarisiz, 81 atlandi (PG). PG'li testler ve tam suite calistirilmadi; bulgular icin yeni test yazil…

### tarama-firmware

Okunan ve çağıran->çağrılan yoluyla izlenen: main.cpp (setup/loop, seri CLI: SAFETY/TPL/RELAY/SHUTTER/SET_DI/DEFAULT_DI/EXTMOD/CH/SEND/BAUD/CHILDLOCK/AP/FACTORYINIT/RESETKEY/REBOOT), WebPortal.cpp (yönlendirme, dispatch/yetki sınıfları, Ethernet/AP kökeni, auth limiter, kısıtlı/tam status, relay/all/child-lock, config get/save + loop işi, wifi scan/connect/status/disconnect, rs485 send/relay/baud/scan, reboot/reset, factory/init, rekey, mqtt/config, actuator/alarm/arm/events/safety config, template apply/get), MqttManager.cpp (görev döngüsü, bağlantı/LWT, abonelik penceresi, bootstrap, durum yayını, komut ayrıştırma/uid/yinelenen kimlik, sys set_local_key/cfg_get/cfg_patch, olay yayını), NetLinkCore.h, EthLink.cpp, ApAccess.h, NetTime.h (Wait, AuthLimiter, ApPolicy, PublishPacer), WiFiManager.cpp (olaylar, STA/aday akışı, AP), ConfigManager.cpp + SystemConfig.h validate, BootstrapCore.h, SmartAutomation.cpp (komut yürütme, panjur sarmalayıcı, DI kapısı, çıkış katmanı, ek modül yazımı, güvenlik turu, emniyet görevi, açılış), SmartAutomation_Rs485.cpp (yoklama, ham gönderim/röle, tarama girişi), ShutterFsm.h, DiGate.h, RelayRules.h, WS_TCA9554PWR.cpp, WS_Relay.cpp, safety/* (SafetyFsm, IntrusionFsm, SafetyManager, SafetyConfig validate/decideBootMode/crash, SafetyCfgEdit gevşetme/gaz kuralları, SafetyStore, ValveGuard), sensors/* (SensorHub, DiSensor, BridgeSensor, SensorTypes), actuators/ActuatorMap.h, events/EventOutbox.h, template/TemplateApply.cpp, TemplateRules.h, Templat…

### tarama-uygulama-cekirdek: uygulama çekirdeği (lib/services, lib/models, lib/utils) — oturum/ev geçişleri, çevrimdışı/çe…

İncelenen (kod okuma, çağıran->çağrılan izlenerek): automation_state.dart (init/geri yükleme, depo kuyruğu, oturum sıfırlama, oturum sonu/misafir sonu/403, yaşam döngüsü ve biyometrik kilit, giriş/kayıt/çıkış/logoutAll/servis PIN, _startSession, ev listesi/uzlaştırma/selectHome/setMode, yerel anahtar çözümü ve önden tazeleme, LAN yoklama, bulut yenileme ve yeniden deneme, MQTT bağlama ve snapshot uygulama, güvenlik komutları, çocuk kilidi/huzur, kurallar, katılım/devir, yasal blok), ev_cloud_api_service.dart (oturum durumu, _call/401 yenileme, tek-uçuş ve isolate kapılı yenileme, 429, auth uçları, güvenlik uçları), refresh_gate.dart, ev_mqtt_service.dart (tamamı), alarm_watch (service/engine/controller/notice), safety_notice_controller.dart (tamamı), peace_notice_controller.dart (uygunluk, kilit, afiş, closeAll), capabilities.dart (sunucu role_matrix.js ve requireHomeAccess ile karşılaştırıldı), cloud_models (UserModel/HomeModel/endpoint pair), legal_models, endpoint_sync, scheduled_rule_model, json_utils, clock, secure_storage_service (anahtarlar, önbellek, clearAll), command_pipeline (çekirdek), board_network_binding (kira/oturum), automation_api_service (adres/gönderim/hata), wifi_qr_parser, version_compare, QrClaimParser.normalizeUid. Sunucu tarafında yalnız sözleşme doğrulaması için auth_service publicUser/listHomesForUser/register, legal_service, mqtt_credential_service, invitation_service.join, safety_routes ack okundu. İncelenmeyen / yüzeysel: lib/services/push/* (bu…

### tarama-uygulama-ekranlar

İncelenen (okuma + çağıran->çağrılan izi): AuthGate (gateViewFor, itilmiş rota kapatma, Wi-Fi sihirbazı istisnası), Kullanıcı Sözleşmesi onay sayfası, kayıt sayfası sözleşme akışı, AutomationState yasal blok (acceptTerms/refreshCurrentUser/_syncLegalStatus) ve sunucu legal_service needs_acceptance; AppShell + SafetyNoticeHost/SafetyNoticeController yönlendirmesi; derin bağlantı (_ClaimLinkPage); servis sihirbazı denetleyicisi (adım tamamlanma, atlama, ilerleme kaydı/devam, _applyExisting/_applyRecord), handover_logic, customer_logic, identify_logic (PIN oturumu), claim_logic anahtar hazırlığı, wifi_logic (provision/Ethernet), 5. adım AP parolası arayüzü, button_logic, shutter_logic süre yazımı, relay_logic dünkü değişiklikleri (bölge testi), safety_config_transport.apply; servis paneli sihirbaz girişleri (service_mode_page, service_subscribers_page, emergency_reset_card, replace_board_dialog ev değişimi korumaları); aile üyeleri sayfası (yükleme/çıkarma/davet listesi), davet diyaloğu, katılma/devir diyaloğu + state joinHome/acceptHomeTransfer/fetchHomes/_reconcileHomes/selectHome, devir diyaloğu (başlat/iptal/acil sıfırlama), hesap silme diyaloğu; Kanallar ve Panjurlar sayfası + sunucu endpoint_service güncellemesi; zamanlı kurallar sayfası + kural diyaloğu + rule_logic + sunucu doğrulaması/üstlenme; Hepsini Kapat, gaz anahtarlama onayı, röle/panjur kart komutları, hızlı senaryolar, kritik alarm kartı (onay/vana kapat/vana aç), capabilities modeli ile sunucu role_matrix karş…

### tarama-servis-yazilimi-sozlesme

İNCELENEN. Servis yazılımı: factory_client.py (ServerClient giriş, yenileme ve tek uçuş; envanter, site, şablon ve yazım kaydı uçları; DeviceClient Wi-Fi/Ethernet provizyonu ve doğrulaması, lk_fp; SerialProvisioner yoklama, FACTORYINIT ve RESETKEY; TemplateSerialWriter, TemplateLanWriter; STATUS/TPL/SAFETY ayrıştırıcıları). ev_otomasyon_sistemi.py (flash kipleri, sürüm seçimi, yazım öncesi yoklama, sürüm düşürme, birleşik imaj sonrası otomatik yeniden provizyon, sunucudaki anahtarla provizyon, etiket yeniden basma, kayıt, envanter listesi). site_template_ui.py (Karta Yaz akışı, yazmadan önce daireye bağlama, bekleyen kayıt kuyruğu, SAFETY ACK, teslim, bağlama, atama, şablon kaydetme ve çakışma). template_model.py (zarf, parçalama, NC tehlike yardımcıları). wiring_pdf.py yalnız röle, panjur ve vana anlamı açısından tarandı. Sözleşmeler: CONTRACTS §3, §3b-3g ile şablon README'si koda karşı tarandı. Sunucuda site_template_routes/service, device_bootstrap_routes/service, rate_limit, mqtt_credential_service.issueDeviceCredential, inventory updateStatus, sahiplenmede tohumlama (_loadFlatSeed, endpointRowsFromTemplate) ve hata gövdesi biçimi okundu. Firmware'de TemplateApply/TemplateStore, WebPortal şablon uçları, main.cpp STATUS/TPL/SAFETY çıktıları, BootstrapCore bekleme süreleri, MqttManager bağlantı sırası ve 1500 ms yok sayma penceresi okundu. Bulunan: abone olma ve 'online' yayını sırası güvenli; sunucu 2 sn bekleyip yayınlıyor. Uygulamada MQTT presence ayrıştırması ve sahipl…

## Belgeler

- I updated the documents to match tonight's final code and checked every statement against server/src, lib, the firmware and the tool sources. **CONTRACTS.md** - New section 3h (legal texts, migration 039): - the server/legal files and their front matter - GET /yasal/:slug, GET /api(/v1)/legal and /legal/:id - POST /legal/accept, including 409 LEGAL_VERSION_MISMATCH with data.current_version - accept_terms_version at registration - publicUser.legal and the needs_acceptance rule (only for a final text, never for staff) - the app's registration checkbox, acceptance screen and settings entry - New section 3i: an index of C1–C16 plus sko-3/sko-4, hesap-uyelik-7 and fw-tarama-3/4/5, and the list of open decisions. - C1–C16 written into their sections (1.1b, 1.4, 1.5, 1.5b, 1.5c, 1.5d, 1.5e, 2.1, 2.5, 2.6, 3c, 3e, 3f, 5, 6 and 2.7). This includes migrations 040/041 and the K-Ş4 exception for staff reading any inventory card's local key. - Two stale facts fixed while checking: the bootstrap per-card limit is 20/h (the document said 6/h), and the flat row's last_write / last_ok_write fields were incomplete. **Flow documents** - New section 0 for 2026-10-09. Yesterday's items are kept in one paragraph so the diagram's section tags stay valid. - Behaviour updated where tonight's fixes changed it, and legal texts added to registration, login and settings. - "Açık kalan konular" lists: - None of the old items was fixed tonight. - New known limits: v1.3.2 untested on a board, long confirm…
- Akış PDF'leri: Built tools/belge_pdf/ (stdlib-only Python Markdown->HTML converter, A4 print CSS, two hand-designed diagram JSON configs, README) and rendered docs/akislar/SERVIS_SORUMLUSU_AKISI.pdf and DAIRE_KULLANICISI_AKISI.pdf (10 A4 pages each) with headless Edge (throwaway --user-data-dir profile; waits for the PDF timestamp to change). Output: cover page (title; 'Kimin için' + role chips and 'Belge hakkında' taken from the intro blockquote; phase strip; date = newest ISO date in the intro and headings, 8 Ekim 2026; Güde Teknoloji), automatic clickable table of contents, color/marker legend, colored numbered section bands, role chips with one color per role (headings, table headers, bold role labels, diagram lanes), Evet/Hayır pills in the permission tables, callout boxes with inline SVG icons (ev…

## Bilinen sınırlar

- Üretim sunucusunda EMQX_API_URL / EMQX_API_KEY / EMQX_API_SECRET tanımlı değil: evden çıkarılan ya da kimliği yenilenen kişinin AÇIK MQTT bağlantısı anında koparılamıyor (günlükte 102 'kick atlandı' uyarısı). Kimlik silindiği için yeniden bağlanamaz, ama açık oturum kopana kadar sürer. EMQX'te bir API anahtarı oluşturulup sunucu .env'sine eklenmeli (ayar işi, kod değil).
- PG'li sunucu testlerinde aralıklı, dosya düzeyinde çökme: 3-5 koşuda bir, her seferinde farklı bir dosya, tek başına koşunca geçiyor. Ürün hatası değil, test altyapısı sorunu; ayrıca incelenmeli.
- Ethernet (W5500) ve panonun kendi bulut kimliği (bootstrap) gerçek kabloyla denenmedi; firmware v1.3.2 kartta denenmedi.
- Yasal metinler TASLAK: 27 yer tutucu (şirket unvanı, MERSİS, vergi dairesi/no, KEP, barındırma ve e-posta sağlayıcısı, saklama süreleri vb.) ve avukat incelemesi bekliyor; 'final' yapılınca mevcut kullanıcılara bir kez onay ekranı çıkar.
- EMQX'te eski 'home_101' konusunda kalmış bir mesaj, köprü her yeniden başladığında hata günlüğüne birkaç zararsız satır yazdırıyor; temizlenebilir.
- Firmware birim test betiği native_msvc.bat iki grubu (test_bootstrap, test_template_parse) ArduinoJson yolu olmadan derleyemiyor; tpl_msvc.bat ile geçiyorlar (betik sınırı, önceden beri).
- Ekran ekran deneme yapılmadı (isteğiniz); doğrulama kod analizi ve otomatik testlerle yapıldı.
- Push yapılmadı: otomatik izin denetimi engelledi. G:/site/ev_otomasyon klasöründe 'git push' (dal master) çalıştırmanız gerekiyor.
- Maliyet: dün akşamki kitapçık/yasal iş 11 ajan ~5,7 milyon belirteç; gece denetimi 15 ajan ~7,3 milyon belirteç (~3 saat).
