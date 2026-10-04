# Uç nokta yerleşim eşitleme (pano → bulut) — tasarım

> Tarih: 2026-10-03 · İş paketi: **WP-L** · Kapsam: yalnız sunucu (`server/`) + belgeler. Pano yazılımı ve Flutter uygulaması **değişmez**.

## 1. Sorun (kodla doğrulandı)

Servis sorumlusu panoyu hotspot/portal üzerinden ayarlar (hangi çift panjur, hangi röle lamba/darbe, kanal adları). Daire kullanıcısının ekranındaki kontroller ise panodan değil, sunucunun **sahiplenme (claim) anında sabit şablondan** açtığı `endpoints` satırlarından çizilir:

- Şablon: `server/src/services/device_service.js` `SEED_ENDPOINTS_SQL` — kanal 1-2 ve 3-4 panjur, 5-8 aydınlatma, 9+ "Ek Modül Röle N" (satır sayısı envanterdeki model adındaki `NRO` değerinden).
- Pano her `state` mesajında her rölenin `id + name + type` bilgisini ve geçerli panjur çiftlerini yayınlar (`MqttManager.cpp` `publishState`), fakat köprü yalnız `id + state` ve `pair + pos` alır (`mqtt_bridge.js` `validateStatePayload`); ad ve tip **atılır**.
- Uygulamada kanal adı/odası/tipi düzenleyen ekran **yoktur**; pano yapılandırmasını yazan istemci çağrısı (`saveConfig`) hiç kullanılmaz.

Sonuç: pano fabrika yerleşiminde bırakılırsa her şey kendiliğinden çalışır. Yerleşim değiştirilirse (örnek: 5-6 panjur yapıldı) bulut bunu öğrenmez:

| Panoda yapılan | Daire ekranında bugün olan |
|---|---|
| 5-6 panjur çifti yapıldı | İki **lamba** kartı görünür; karta dokunmak panjur motorunu yürütür. Sihirbazın 8. adımı "Sunucuda bu panjur için kayıt yok" ile takılır. |
| 1-2 iki lambaya çevrildi | "Salon Panjur" kartı durur ama çalışmaz; lambaların kartı yoktur. |
| Bir röle darbe (kapı/kilit) yapıldı | Kart aç/kapa anahtarı olarak çizilir (işlev çalışır, görünüm yanlış). |
| RS485 ek modül eklendi (röle 9+) | Model `8RO` ise bu çıkışların kartı hiç oluşmaz. |
| Kanallara ad verildi ("Mutfak Spot") | Ekranda şablon adı ("Mutfak Aydınlatma") kalır. |

## 2. Hedef

Servis sorumlusu **yalnız panoyu ayarlar**; bulut uç noktaları (dolayısıyla daire kullanıcısının ekranı) panonun bildirdiği gerçek yerleşimden **otomatik** oluşur ve güncel kalır: tip, panjur çiftleri, kanal sayısı ve adlar. Kullanıcının bulutta verdiği ad/oda korunur.

Kapsam dışı (bilinçli): pano yazılımı değişikliği (panjur süresini `state`'e ekleme, ad değişiminde anında yayın), Flutter'da ad/oda düzenleme ekranı ve "liste değişti" anlık yenilemesi, çok panolu evde komut adresleme.

## 3. Yaklaşım seçimi

| | Yaklaşım | Artı | Eksi |
|---|---|---|---|
| **A (seçildi)** | Sunucu, canlı `state` mesajındaki yerleşimden `endpoints` satırlarını uzlaştırır | Pano ve uygulama değişmez; portal dahil her yoldan yapılan değişikliği yakalar; kendi kendini onarır | Sunucuda yeni iş + bir göç |
| B | Sihirbaz panodan `GET /api/config` okuyup buluta yazar | Açık, tek seferlik | Uygulama değişir; yalnız sihirbaz kullanılırsa çalışır; teslimden sonraki değişiklikleri kaçırır; yeni yetkili API yüzeyi |
| C | Pano ayrı bir `config` konusu + revizyon yayınlar | En temiz sözleşme | Yeni pano imajı, QA simülatörü, ACL ve sahadaki panoların yeniden yüklenmesi gerekir |

A, gereken veriyi zaten taşıyan mevcut mesajı kullandığı için en az riskli ve en geniş kapsamlı çözümdür.

## 4. Mimari

```
pano --(MQTT ev/{t}/state, canlı)--> mqtt_bridge._processState
                                        | (durum/konum güncellemesi COMMIT edildikten sonra, hata yalıtımlı)
                                        v
                         EndpointLayoutSync.onLiveState({homeId, deviceId, layout})
                                        | imza önbelleği (bellek) -> değişmediyse hiçbir sorgu yok
                                        v
                         kuyruk (ev başına sıralı) -> tek transaction:
                            devices satırı kilidi -> endpoints satırları kilidi -> plan (saf) ->
                            INSERT / UPDATE / DELETE endpoints, zamanlı kuralları kapat,
                            devices.reported_layout (taban), device_audit_logs
```

Dosyalar:

| Dosya | Sorumluluk |
|---|---|
| `server/src/utils/endpoint_layout.js` (yeni) | SAF: `extractReportedLayout`, `planLayoutSync`, ad/oda kuralları, varsayılan tabloları |
| `server/src/services/endpoint_layout_sync.js` (yeni) | G/Ç: önbellek, kuyruk, transaction, denetim kaydı, istatistik |
| `server/src/mqtt_bridge.js` (küçük kanca) | Yerleşimi mesajdan çıkarır; canlı state COMMIT'inden sonra servisi çağırır |
| `server/migrations/031_endpoint_layout_sync.sql` (yeni) | `devices.reported_layout`, `devices.reported_layout_at` |
| `server/test/layout/**` (yeni) | Birim, servis, köprü ve gerçek PostgreSQL testleri |

Köprünün ana `state` yolu (toplu UPDATE, retain farkındalığı, sorgu/transaction sayısı) **değişmez**; eşitleme ayrı, sonradan ve hata yalıtımlı çalışır (uzlaştırıcı `device_reconciler.js` ile aynı desen).

## 5. Kurallar

### 5.1 Hangi mesaj kabul edilir (`extractReportedLayout`)

En küçük şüphede `null` döner ve o mesaj için eşitleme **hiç çalışmaz**:

- `v >= 2`; `relays` ve `shutters` dizi.
- `relays`: 1..N (N ≤ 40) boşluksuz, yinelemesiz ve **sıralı** (i. kayıt `id = i`; pano `publishState` böyle yayınlar, sıra dışı yük şüphelidir); her kayıtta `type` ∈ {`light`, `impulse`, `shutter_up`, `shutter_down`} ve boolean `state`; `name` varsa dizge (`null` dahil başka tür reddedilir).
- Panjur çiftleri tam: röle `2p-1` = `shutter_up` ⇔ röle `2p` = `shutter_down`; ters/yetim panjur rölesi yok (pano portalı da bunu zorunlu kılar: `WebPortal.cpp` `invalid_shutter_pair`).
- `shutters[]` içindeki çift kümesi, tiplerden çıkan çift kümesiyle **aynı** (pano yalnız geçerli çiftleri bildirir; tutarsız anlık görüntü bir sonraki mesajı bekler).
- Adlar temizlenir: kontrol ve görünmez biçim karakterleri atılır, boşluklar birleştirilir, en çok 100 karakter.

Yalnız **canlı** (retained olmayan) mesaj kullanılır; bayat retained mesaj satır değiştirmez.

### 5.2 Tip ve panjur çifti — pano esastır

| Pano tipi | Bulut satırı |
|---|---|
| `shutter_up` + `shutter_down` (çift p) | kanal `2p-1` ve `2p`: `type='shutter'`, `shutter_pair_index=p`; süre: satır zaten panjursa korunur, değilse 20 sn |
| `impulse` | `type='impulse'` |
| `light` | `type='light'`; satır `plug` ise `plug` **korunur** (priz yalnız bulutta bilinen kozmetik ayrım) |

Sınıf (röle ↔ panjur) değişince: panjur olan satırda konum panonun bildirdiği değere, röle olan satırda çift/süre `NULL`, konum 0 yapılır. Satır **yerinde** güncellenir (kimlik korunur).

### 5.3 Ad

Tanımlar: `N` = panonun bildirdiği ad; `D` = bu panonun bir önceki uygulanan bildirimi (taban, `devices.reported_layout`); "pano adı özel" = `N`, panonun fabrika adı ya da bulut şablon adı **değil** (karşılaştırma büyük/küçük harf, aksan ve noktalama duyarsız: "Salon Panjur (Yukari)" ≡ "Salon Panjur Yukarı"); "bulut adı otomatik" = şablon adı, fabrika adı ya da `Röle N` / `Panjur P Yukarı|Aşağı`.

| Durum | Bulut adı |
|---|---|
| Yeni satır ya da sınıf değişti, pano adı özel | `N` |
| Yeni satır ya da sınıf değişti, pano adı özel değil | Şablon adı (sınıf şablonla aynıysa), değilse `Panjur P Yukarı/Aşağı` ya da `Röle N` |
| Sınıf aynı, pano adı özel, `D` var ve `N ≠ D` (panoda ad değişti) | `N` (son yazan kazanır) |
| Sınıf aynı, pano adı özel, bulut adı otomatik | `N` |
| Sınıf aynı, pano adı özel, bulut adı kullanıcıya ait, panoda değişiklik yok | Bulut adı **korunur** |
| Sınıf aynı, pano adı varsayılana döndü, bulut hâlâ eski pano adını (`D`) gösteriyor | Varsayılan ad |
| Diğer | Bulut adı korunur |

Panonun ASCII fabrika adları ("Salon Aydinlatma") buluta **taşınmaz**; bulutun Türkçe varsayılanları kalır. Panjurda iki röle kendi adlarını alır ("X (Yukari)", "X (Asagi)"); uygulama ortak adı yön ekini atarak türetir (`shutterBaseName`).

Karşılaştırma katlaması (`foldName`) Türkçe harfleri katlar, aksanları atar ve **Unicode harf/rakamları korur** (Kiril, Arap, CJK adlar ayırt edilir). "Boş ad" yalnız temizlenmiş ham ad boşsa geçerlidir; yalnız emoji/noktalamadan oluşan bir ad (katlaması boş ama ham hâli dolu) **özel** addır (2026-10-04 düzeltmesi: önceden bu adlar boş sayılıp kullanıcı adı ezilebiliyordu).

Ad temizliği Unicode kategorilerine göredir: `Cc`, `Cf` (yön değiştiriciler, bidi yalıtımları, yumuşak tire, etiket karakterleri dahil), `Zl`, `Zp`, yalnız vekiller (`Cs`) ve Hangul dolguları boşluğa çevrilir; sonuç iyi biçimli UTF-16'dır (PostgreSQL `jsonb`'ye yazılırken `22P02` olmaz).

### 5.4 Oda

Panoda oda yoktur. Otomatik oda: ad şablon adıysa şablon odası; değilse adın başındaki bilinen oda adı (Flutter `labels.dart` `_knownRooms` ile aynı küme + "Oda": "Yatak Odası Panjur (Yukari)" → "Yatak Odası"); yoksa "Genel".

Oda şu durumlarda yeniden hesaplanır: yeni satır ve sınıf (röle ↔ panjur) değişimi (**her zaman**; eski oda yeni cihaz türü için anlamsız sayılır); ad bu eşitlemede değişti **ve** mevcut oda otomatik bir değer (boş / "Genel" / şablon odası / eski addan türetilmiş oda). Sınıf değişmedikçe kullanıcının verdiği oda korunur.

### 5.5 Satır kümesi

- Bildirilen 1..N kanalları için eksik satır **açılır** (ek modül röleleri dahil).
- N'den büyük kanallı satırlar (ek modül kapatıldı/küçüldü) **silinir**, ama yalnız aynı küçülme en az 20 sn arayla **ikinci kez** görülünce (tek bir tutarsız mesaj satır silemez).

### 5.6 Zamanlı kurallar

`scheduled_rules` kanal numarası + kanal tipiyle bağlıdır. Aynı transaction'da şu kurallar `enabled = FALSE` yapılır (silinmez; kullanıcı görür, düzeltir):

- sınıfı röle → panjur olan kanala yazılmış **röle** kuralları (aksi halde "lambayı aç" kuralı motoru sürerdi);
- sınıfı panjur → röle olan çifte yazılmış **panjur** kuralları;
- tipi lamba/priz ↔ **darbe** değişen kanala yazılmış **röle** kuralları (aksi halde "lambayı aç" kuralı her gün kapı/kilit darbesi tetikler; tersi yönde "Tetikle" kuralı röleyi kalıcı çekili bırakır). Lamba ↔ priz kozmetiktir, kapatılmaz;
- silinen satırların kanal/çiftlerine yazılmış kurallar.

Kapsam: `home_id` eşit ve (`device_id` bu cihaz ya da `device_id` boş **ve evde tek cihaz var**).

Kapatma tek başına yetmez; iki ek katman vardır (2026-10-04):

- **Yeniden açma doğrulaması:** `scheduled_rules_service.updateRule`, kural kapalıyken açılırsa (`enabled` false → true) kanal/tip/eylemi uç noktalara göre yeniden doğrular; uymuyorsa `400 VALIDATION`. Kapatma her zaman serbesttir.
- **Ateşleme anı denetimi:** zamanlayıcı yayından önce hedefi uç noktalardan okur: röle kuralının kanalı panjursa ya da panjur kuralının çiftinin iki kanalı da panjur değilse komut **yayınlanmaz** (`scheduled_rule_runs.status = 'skipped_invalid'`). Uç nokta satırı yoksa eski davranış sürer. Bu katman eşitleme kapalıyken (`ENDPOINT_LAYOUT_SYNC=off`) ve kural oluşturma ile eşitleme arasındaki yarışta da motoru korur.

### 5.7 Taban (`devices.reported_layout`)

Bu panonun en son uygulanan bildirimi: `{"v":1,"relays":[{"id":1,"type":"shutter_up","name":"…"}, …]}`. Ad kuralındaki `D` buradan okunur. Satırları yeniden tohumlayan, silen ya da cihazı başka eve/sahibe bağlayan akışlar tabanı **boşaltır**: sahiplenme (upsert), acil sıfırlama (devir ve stoğa dönüş), pano değişimi (yeni cihaz satırı, upsert dahil). Pano değişiminde taşınan satırların korunması §5.8'deki geçici pano korumasıyla sağlanır (taban boş olması tek başına yetmez: sınıf değişiminde ad/oda/süre yeniden hesaplanır).

### 5.8 Geçici (fabrika) pano koruması (2026-10-04)

Sorun (inceleme bulgusu, gerçek PG'de yeniden üretildi): pano değiştirildikten sonra yeni pano **fabrika ayarında** buluta bağlanırsa, taşınan satırlar fabrika yerleşimine göre uzlaştırılıyordu: kullanıcının adı/odası ve ölçülmüş panjur süresi siliniyor, ek modül satırları 20 sn sonra siliniyor, kurallar kapanıyordu. Servis sorumlusu yeni panoyu eskisi gibi ayarladığında bunlar geri gelmiyordu.

Kural: cihaz **devreye alınmamış** (`devices.is_commissioned` doğru değil) **ve** tabanı **boş** iken pano **tam fabrika yerleşimini** (8 röle; 1, 3 `shutter_up`; 2, 4 `shutter_down`; 5-8 `light`; tüm adlar fabrika/tohum adı ya da boş) bildirirse plan **geçici** modda çalışır:

| Değişiklik | Geçici modda |
|---|---|
| Röle sınıfından (lamba/priz/darbe) panjura sınıf değişimi + röle kurallarının kapatılması | **Uygulanır** (bulutta lamba kartı panjur motorunu sürmesin) |
| Lamba/priz ↔ darbe tip değişimi + röle kurallarının kapatılması | **Uygulanır** |
| Eksik kanalların eklenmesi | **Uygulanır** |
| Panjurdan röle sınıfına dönüş | Ertelenir |
| Satır silme (küçülme) | Ertelenir (küçülme kaydı da tutulmaz) |
| Ad/oda değişimi (varsayılana dönüş dahil) | Ertelenir |
| Taban yazımı | Ertelenir |

Ertelenecek bir şey yoksa davranış normaldir (taban yazılır, imza önbelleğe alınır): yeni kurulumda fabrika pano + tohum satırları ve devreye alınmamış eski kurulumlar ek yük üretmez. Erteleme varsa imza önbelleğe "tamam" yazılmaz; her mesaj hız sınırı içinde yeniden değerlendirilir.

Çıkış: pano fabrika dışı bir yerleşim bildirir (servis sorumlusu yeni panoyu ayarladı) ya da cihaz devreye alınır (teslim; fabrika yerleşimi bilinçli). Güvenlik: ertelenen yönlerde bulut satırı eski yerleşimi gösterir, ama pano bu komutları reddeder (yapılandırılmamış panjur çifti: `pairConfigured`; aralık dışı röle).

## 6. Dayanıklılık ve güvenlik

- **Hata yalıtımı:** servisin her hatası yutulur ve sayılır; köprü mesaj hattı etkilenmez.
- **Yük:** imza (id+tip+ad) değişmediyse hiçbir sorgu yapılmaz. Aynı imza için cihaz başına 5 dakikada bir kilitsiz doğrulama okuması yapılır (sıfırlama/yeniden tohumlama sonrası kendi kendini onarma). Cihaz başına en sık 5 sn'de bir çalışır.
- **Çevrimiçi dönem:** canlı `status: offline` (LWT) bildiriminde o evin cihaz imza önbelleği atılır. Acil sıfırlama (devir) ayrıca COMMIT sonrası köprünün `invalidateLayout(deviceId)` metodunu çağırır (pano temiz kopuşla yeniden bağlanırsa LWT gelmeyebilir). Pano aynı imzayla dönünce ilk canlı state **hemen** kontrol edilir (5 dk beklenmez).
- **Kötüye kullanım / yazma bütçesi:** hız sınırı (`lastRunAt`) ve küçülme onayı imza önbelleğinden ayrı tutulur; LWT ya da geçersiz kılma bunları sıfırlamaz (önceden ele geçirilmiş bir cihaz kimliği her state'ten önce `offline` yayınlayarak hız sınırını atlatabiliyordu). Cihaz başına saatte en çok 30 satır değiştiren eşitleme uygulanır (`APPLY_BUDGET_PER_HOUR`); aşılırsa o saat yazılmaz, sayılır ve saatte bir uyarı loglanır.
- **Eşzamanlılık:** kilit sırası `devices` → `endpoints` (kanal sırasıyla) → `scheduled_rules` (claim/sıfırlama/pano değişimi ve köprünün kendi state transaction'ı ile aynı sıra). Kilitsiz ön okumada fark çıkarsa transaction içinde kilitli okuma ile plan **yeniden** hesaplanır. İnceleme gerçek PG'de iki kilitlenme (40P01) üretti ve ikisi de giderildi: kullanıcının panjur süresi PUT'u artık satırları kanal sırasında kilitler (`endpoint_service`); acil sıfırlama evin tüm cihaz satırlarını temizlikten önce id sırasıyla kilitler (`device_service`). Kullanıcının `light ↔ plug` PUT'u tipi koşullu yazar: araya eşitleme girip satırı panjur yaptıysa `409` döner (önceden panjur satırına `plug` yazılabiliyordu).
- **Uzlaştırıcı ile etkileşim:** pano değişiminden sonra panjur sürelerini yeni panoya basan uzlaştırıcı (`device_reconciler`, `runtime_sync`) yalnız eski panonun gerçek çiftlerini (`config_snapshot.endpoints`) ve hâlâ panjur olan satırları gönderir. Eşitlemenin yeni açtığı çiftin yer tutucu 20 sn'si panoya yazılmaz (önceden yeni panonun kendi kalibrasyonunu eziyordu).
- **Kapanış:** köprü `end()` sonrası gelen gecikmiş bir mesaj eşitleme servisini yeniden kurmaz (`init()` bayrağı sıfırlar).
- **Yetki sınırı:** `state` yalnız evin cihaz kimliğiyle (`d_{t}`) yayınlanabilir; eşitleme yalnız o evin, `uid` ile eşleşen cihazının satırlarına dokunur. Kullanıcının bulutta verdiği ad/oda, pano tarafında değişiklik olmadıkça ezilmez. Her uygulanan değişiklik `device_audit_logs`'a `endpoint_layout_synced` olayı olarak yazılır (ad içermez; sayılar ve kapatılan kural kimlikleri).
- **Kapatma anahtarı:** `ENDPOINT_LAYOUT_SYNC=off` eşitlemeyi kapatır (varsayılan açık). Göç geri alınmadan da güvenle kapatılabilir.
- **Eski yazılım / bozuk yük:** `type` alanı eksik ya da bilinmeyen ise eşitleme çalışmaz, tohum şablonu kalır.

## 7. Şema (031)

```sql
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout JSONB;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS reported_layout_at TIMESTAMPTZ;
```

Idempotent, `BEGIN/COMMIT` içermez (çalıştırıcı sarar), mevcut satırlara dokunmaz; eski kod yeni kolonları görmezden gelir (rolling deploy güvenli).

## 8. Arayüzler

`server/src/utils/endpoint_layout.js`: `extractReportedLayout(stateObj)`, `planLayoutSync({reported, base, rows, confirmShrink, provisional})` (çıktıda `deferred` sayısı; `deferred > 0` iken `newBase = null`), `isFactoryLayout(reported)`, `parseBase(raw)`, `serializeBase(reported)`, `seedDefaults(channel)`, `firmwareDefaultName(channel)`, `deriveRoom(name)`, `foldName`, `sanitizeReportedName`, sabitler.

`server/src/services/endpoint_layout_sync.js`: `createEndpointLayoutSync({db, logger, now, timers, QueueClass})` → `{ onLiveState({topicId, homeId, deviceId, layout}), onOffline(topicId), syncNow({homeId, deviceId, layout}), invalidate(deviceId), whenIdle(ms), stop(), stats() }`; ayrıca `SQL` ve `constants` (`APPLY_BUDGET_PER_HOUR` dahil) dışa aktarılır. `invalidate` ve `onOffline` yalnız imza önbelleğini siler (hız sınırı, küçülme onayı ve bütçe ayrı haritadadır). `syncNow` sonucu: `applied | noop | skipped (reason: device_not_found, home_mismatch, stopped, dropped, invalid_args, throttled) | error`. `stats()`: `devices, checks, applied, noops, skipped, rateLimited, errors, inserted, retyped, renamed, deleted, rulesDisabled, deferred, throttled, queue`.

`mqtt_bridge.js`: `invalidateLayout(deviceId)` (genel; servis yoksa no-op, asla fırlatmaz; `device_service.emergencyReset` devirden sonra çağırır).

## 8b. Doğrulama (2026-10-03, gerçekleşen)

- Birim/servis/köprü/göç testleri: `server/test/layout/**` 234 test; `npm test` klonda 1870 test (PG'siz 1770 geçti / 100 atlandı; gerçek PG `evy_gate` ile 1869 geçti / 1 atlandı), 0 kırık.
- QA yığını (gerçek sunucu + gömülü PostgreSQL + MQTT broker + firmware simülatörü `home1`, yalıtılmış portlar): simülatörde `POST /api/config` ile çift 3 panjur + röle 7 ad + röle 8 darbe → `GET /homes/:id/endpoints` ~1 sn içinde izledi (tip/çift/ad/oda, uç nokta kimlikleri korundu), kanal 5 röle kuralları `enabled=false`, yeni panjura `{pos:60}` komutu iletildi ve konum buluta yansıdı; eski yapılandırmaya dönüşte ≤ 30 sn'de birebir başlangıç durumu. Denetim kaydı 2 satır (ad yok). Gerçek panoda doğrulanmadı.

### 8c. Bağımsız inceleme ve düzeltmeler (2026-10-04, gerçekleşen)

- Dört bağımsız inceleme merceği (kurallar/veri, diğer akışlar, eşzamanlılık/kötüye kullanım/yük, sözleşme/test kalitesi) gerçek PostgreSQL'de deneyle 27 bulgu üretti (3 kritik, 7 yüksek, 9 orta, 8 düşük; çoğu aynı kök nedenlerin tekrarı). Kritik/yüksekler kodda yeniden doğrulandı ve §5.3-§5.8, §6 ve §10'daki kurallarla giderildi: geçici pano koruması, lamba/priz ↔ darbe kural kapatma, yeniden açma doğrulaması, ateşleme anı hedef denetimi, taban sıfırlama, devirde önbellek geçersiz kılma, uzlaştırıcının çift kaynağı, Unicode ad katlama ve temizliği, yazma bütçesi, iki kilitlenmenin giderilmesi, PUT tip yarışı.
- Her düzeltme önce kırmızı testle (birim + gerçek PG), sonra mutasyonla doğrulandı (ekip başına 7-32 mutasyon; kaçanlar eşdeğer mutant).
- Kapı (klon, 2026-10-04): `npm test` 1953 test; PostgreSQL'siz 1834 geçti / 119 atlandı, gerçek PostgreSQL ile iki ardışık koşuda 1952 geçti / 1 atlandı (ayrıcalıklı mod), **0 kırık**; `tools/qa_stack` 414/414; `lint:syntax` temiz.
- QA yığını uçtan uca: ana senaryo yeniden geçti; ek senaryo: pano 5-6'yı panjur yapınca kapanan `relay 5` kuralı `PUT {enabled:true}` ile **açılamadı** (400, Türkçe açıklama); uyumlu panjur kuralı açılıp kapatılabildi; pano geri alınıp kanal tekrar lamba olunca kural açılabildi.
- Kapıda görülen tek kırık (`pg_live.test.js` devreye alma testi, `39 !== 38`) üretim kodundan değil, testin tüm `users` tablosunu sayarak paralel PG test dosyalarıyla yarışmasından kaynaklanıyordu (tek başına 3/3 geçti). Test, yalnız bu çağrının oluşturabileceği kullanıcıları arayacak biçimde yalıtıldı. Mutasyonla (oturum için kullanıcı oluşturan sürüm) hâlâ kırmızıya düştüğü gösterildi.

`mqtt_bridge.js`: `new MqttBridge({ layoutSync: true })` (üretim tekili) ya da `{ layoutSyncer: örnek }` (test). `getStatus().layout_sync` istatistikleri verir.

REST sözleşmesi **değişmez**: `GET /homes/:homeId/endpoints` aynı biçimde, artık panonun gerçek yerleşimini döner.

## 9. İstemci etkisi

Uygulama değişmez. Liste bir sonraki çekimde (ev seçimi, aşağı çekip yenileme, uygulamayı öne alma, kendi işlemi sonrası) yeni yerleşimi alır; MQTT eşlemesi "tip + kanal" ile yapıldığı için düzeltilmiş satırlarla doğru çalışır. Sihirbazın 8. adımı, pano buluta bağlandıktan (6. adım) sonra satırlar eşitlendiği için üçüncü/dördüncü panjurda takılmaz.

## 10. Bilinen sınırlar

1. Ad ya da lamba ↔ darbe değişimi buluta panonun bir sonraki kalp atışında (en geç 30 sn) ulaşır; panjur çifti/kanal sayısı değişimi ~0,4 sn içinde.
2. Açık duran uygulama: istemci yenilemesi (ayrı iş, `docs/superpowers/analysis/endpoint-yerlesim-istemci-yenileme.md`) canlı state yerleşimi listeyle uyuşmazsa ≈2 sn sonra listeyi sessizce yeniden çeker; ad değişimi bu tetiğe dahil değildir (aşağı çekip yenileme gerekir).
3. Yeni açılan panjur satırı 20 sn süreyle başlar (pano süresini `state`'te yayınlamıyor); süre sihirbazın 8. adımında ölçülür.
4. Oda yalnız adın başında bilinen bir oda adı varsa türetilir; aksi halde "Genel".
5. Kullanıcı bulutta ad verdikten sonra servis sorumlusu panoda adı değiştirirse pano adı kazanır (son yazan).
6. Kapatılan zamanlı kurallar kullanıcıya bildirim olarak gitmez; kural listesinde "kapalı" görünür. Yerleşim geri dönse de kendiliğinden açılmaz (kullanıcı açar; açılırken kanal tipi doğrulanır).
7. Donanımda (gerçek pano + gerçek EMQX) doğrulanmadı; birim + gerçek PostgreSQL testleriyle ve QA yığınında simülatörle doğrulandı.
8. Geçici pano koruması yalnız **tam** fabrika yerleşimini tanır. Servis sorumlusu yeni panoda kısmen ayar yapıp (ör. yalnız bir ad) kalanı fabrikada bırakırsa bildirim fabrika dışıdır ve normal kurallar uygulanır.
9. Devreye alınmış bir panoda cihaz web sayfasından fabrika ayarlarına dönülürse (`POST /api/system/reset`; `ConfigManager::resetToDefaults` MQTT kimliğini ve yerel anahtarı **korur**, pano hemen fabrika yerleşimini bildirir) koruma devreye girmez: fabrika sıfırlaması bilinçli bir yeniden kurulum sayılır ve bulut panoya uyar (sınıfı değişen kanallarda ad/oda/süre yeniden hesaplanır, kurallar kapanır, ek modül satırları ikinci bildirimde silinir). Pano adları ve süreleri sıfırlamayla panoda da silindiği için bu tutarlıdır; kapanan kuralları kullanıcı yeniden açar.
10. Çok panolu evde kardeş panonun `uid`'siyle state yayınlama (aynı evin cihaz kimliği ortaktır) önceden var olan bir modeldir; çok panolu ev akışı bugün yoktur. Aynı evin iki panosuna **eşzamanlı iki acil sıfırlama** hâlâ kilitlenebilir (önceden de vardı; eşitleme ile sıfırlama arasındaki kilitlenme giderildi).
11. Panjur süresi PUT'u tasarım gereği komutu (`set_runtime`) DB'den önce yayınlar. Yayından sonra eşitleme çifti değiştirirse PUT `409` döner ve DB'ye yazmaz. Pano çifti hâlâ tanıyorsa yeni süreyi uygulamış olabilir; değer sonraki kalibrasyonda ya da pano değişimi uzlaştırıcısında yakınsar.
12. Zamanlayıcının hedef denetimi cihazın çevrimiçi denetiminden önce çalışır: kanal uyumsuzsa sonuç `skipped_invalid` olur ve yuva tüketilir (çevrimdışı telafi yolu açılmaz; uyumsuz kural sonradan da çalışmamalıdır).

## 11. Test stratejisi

- **Saf birim testleri:** her kural tablosu satırı için en az bir test; bozuk yük çeşitleri; idempotency (aynı girdi ikinci kez → değişiklik yok).
- **Servis testleri (sahte db):** önbellek, hız sınırı, küçülme onayı, hata yalıtımı, SQL metinleri.
- **Köprü testleri:** yalnız canlı state tetikler; retained ve geçersiz yük tetiklemez; ana yolun sorgu sayısı değişmez; kapatma anahtarı.
- **Gerçek PostgreSQL:** tohum → eşitleme uçtan uca; tip geçişleri; kural kapatma; taban; eşzamanlı PUT ile yarış; idempotency.
- **Regresyon:** `npm test` tamamı + gerçek PG'de tüm PG testleri.
