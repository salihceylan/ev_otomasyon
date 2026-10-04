# Uç nokta yerleşimi: istemci tarafı gecikmeli sessiz yenileme (WP-STATE2)

> Tarih: 2026-10-03 · Dal: `state2` (temel: dev master `0199369`) · Kapsam: yalnız durum katmanı (`lib/models/endpoint_sync.dart`, `lib/services/automation_state.dart`) + testler. Arayüz, REST biçimi ve sunucu **değişmez**. Sunucu tarafı: CONTRACTS §2.4b (WP-L).

## 1. Sorun

Sunucu köprüsü panonun canlı `state`'indeki yerleşimi (röle türleri, panjur çiftleri, kanal sayısı) ~1 sn içinde buluttaki uç noktalara otomatik eşitler. Açık duran uygulama ise `GET /homes/:id/endpoints` listesini yalnız ev seçiminde, çekip yenilemede, öne almada ve kendi işlemlerinden sonra çeker; yerleşim değişimini **kendiliğinden görmez**. Örnek: 5-6. kanallar panjur yapılınca uygulamada hâlâ iki lamba kartı görünür. Kartlar yanıltıcıdır ama karta dokunmak panjur motorunu SÜRMEZ: sunucu panjur kanalına gelen röle komutunu `400` ile reddeder (bkz. §6); sorun, kullanıcının var olmayan bir lambaya dokunup hata görmesi ve listenin bayat kalmasıdır.

## 2. Tetik koşulu

`AutomationState._applyCloudSnapshot` sonunda, **hepsi** sağlanınca (hafif karşılaştırma, O(kanal)):

| Koşul | Neden |
|---|---|
| ileti **canlı** (`retained == false`) | bayat retained ileti sunucuyu da tetiklemez |
| bulut modu, ön plan, aktif ev, `_endpointsLoaded` | ilk REST yüklemesi sürerken/başarısızken ek zamanlayıcı yok (PF-11 yeniden denemesi onu yürütür) |
| iletinin yerleşimi çözülebiliyor (`ReportedLayout.from != null`) | sunucunun **kabul koşulları** aynalanır: kısıtlı değil; `relays` 1..N (N ≤ 40) boşluksuz, yinelemesiz; her rölenin `type`'ı bildirilmiş; panjur röleleri tam çift (`2p-1` YUKARI ⇔ `2p` AŞAĞI); `shutters[]` çift kümesi türlerden çıkan kümeyle aynı. Sunucu böyle bir iletiyi yok sayar, liste değişmez → boşuna yenileme beklenmez |
| yerleşim uç noktalarla **uyuşmuyor** | aşağıdaki kurallar |

Yalnız **aynı cihaza** ait satırlar değerlendirilir (`applyStatusToEndpoints` ile aynı kural: `state.uid` ya da satırın `deviceUuid`'i yoksa aynı cihaz sayılır; büyük/küçük harf duyarsız). Bir kanalda birden çok satır (kimlik belirsiz) → karar verilmez.

### Uyuşmazlık kuralları (`ReportedLayout.compareWith`, `endpointLayoutMismatch`)

* panjur çiftleri kümesi farklı (yeni çift, kalkan çift, başka çifte kayan);
* panoda lamba/priz ya da darbe olan kanalda satır yok ya da sınıfı farklı (lamba ↔ darbe; `plug` lamba sınıfıdır); ek modül (9..16) normal kanaldır;
* panoda panjur rölesi olan kanalda lamba/darbe (panjur olmayan) satır var;
* satırın kanalı panonun bildirdiği 1..N dışında (küçülme, ek modül kapandı) — yalnız `relays` gerçekten sağlanmış ve geçerliyse.

**Adlar karşılaştırılmaz** (pano ASCII fabrika adı, bulut Türkçe ad: sürekli yanlış alarm olurdu), anlık değerler (açık/kapalı, konum) de değil. Panjurun yalnız bir satırı eksikse görünür fark yoktur, sayılmaz.

## 3. Planlama ve sınırlar

* **Gecikme:** uyuşmazlık görülünce 2 sn sonra **tek** sessiz uç nokta yüklemesi (`_loadEndpoints(silent: true)`; cihaz/çocuk kilidi/huzur çekilmez → `refresh(silent: true)`'ten hafif). Tam yenileme (`_cloudRefreshFlight`) zaten sürüyorsa ona katılır, paralel ikinci istek açılmaz.
* **Debounce:** bekleyen zamanlayıcı varken yenisi kurulmaz; ~30 sn'de bir gelen özdeş kalp atışı istek/bildirim üretmez (zaten uyuşan listede zamanlayıcı hiç kurulmaz).
* **Sınırlı deneme (pano başına, yerleşim imzası başına):** 2 sn, +10 sn, +30 sn → **en çok 3 deneme** (her gecikme bir önceki denemenin sonundan; toplam ≈ 2, 12, 42 sn). Gerekçe: sunucu eşitlemesi en geç bir kalp atışında (30 sn) biter; küçülmede satır silmek için aynı küçülmenin ≥ 20 sn arayla ikinci kez görülmesi gerekir (bir kalp atışı daha). Sayaç dolunca **imza değişene ya da uyuşma sağlanana kadar durur**: `ENDPOINT_LAYOUT_SYNC=off` ya da sunucu hatasında sonsuz istek yok. Uyuşma sağlanınca ya da imza değişince o panonun sayacı sıfırlanır (imza değişiminde bekleyen zamanlayıcı 2 sn'ye yeniden kurulur).
* **İmza** (`ReportedLayout.signature`, `deviceLayoutSignature`): `UID|` + röle başına bir harf (`L` lamba/priz, `I` darbe, `U`/`D` panjur yukarı/aşağı), ör. `AHBU-S3-AB12CD|UDUDLLLL`. Ad ve anlık değer imzayı değiştirmez.
* **Çok panolu ev:** izleme pano başınadır; bir panonun uyuşan kalp atışı ötekinin bekleyen zamanlayıcısını iptal etmez; bir istek tüm panoları birlikte görür (deneme ortak harcanır), toplam yine ≤ 3.
* **Bekleyen komut (`_pipeline.hasPending`) varken** zamanlayıcı tetiklenirse yenileme **ertelenir** (1 sn adımla, en çok 5 kez; ertelemeler deneme sayılmaz, sonra yine de yapılır). Gerekçe: REST yanıtı veritabanından okunur ve komut onayı olan canlı `state`'ten milisaniyeler geride kalabilir; bu pencerede REST, yeni uygulanan onaylı değeri eski değerle ezip kartı bir an geri çevirebilir. `_loadEndpoints` iyimser değeri zaten korur (görünüm = gerçek durum + bekleyen hedefler) ve REST'ten onay da gözler; erteleme yalnız bu yarışı kapatır ve komut onay penceresinin (2,5 sn) dolmasını/onayı bekler.
* **Canlı değer korunur:** yenilemeden dönen REST listesinin üzerine en son canlı `state` anlık görüntüsü her zaman uygulanır (`_loadEndpoints(preferLive: true)`). Uç noktaların `current_state` / `current_position` değerini yalnız köprü canlı `state`'ten yazar (`mqtt_bridge.js`) ve veritabanı canlı iletinin milisaniyeler gerisinde kalabilir; yenileme bu gecikmeli değerle kartı geri çevirmez. (Genel `_loadEndpoints` yolu değişmedi: orada yalnız istekten sonra gelen canlı ileti uygulanır.)
* **İptal noktaları** (`_resetLayoutRefresh`): `_cancelAllTimers` (`dispose` + oturum sıfırlama/çıkış), `_resetHomeScopedState` (ev değişimi, erişim kaybı, misafir süresi dolması), `_enterBackground`, `setMode`. Zamanlayıcı geri çağrısı ayrıca `_homeEpoch`, arka plan, mod, oturum, misafir süresi ve `canViewState` denetler.

## 4. Sessizlik (arayüz)

* `_endpointsLoading` hiç açılmaz (`silent: true`).
* Başarısız deneme `endpointsError` yazmaz → "Cihazlar güncellenemedi" şeridi çıkmaz; son bilinen liste ekranda kalır (kalan denemeler yine dener). Başarılı yükleme daha önce görünen hatayı temizler ve bunu bildirir.
* Bildirim yalnız liste gerçekten değiştiyse (`sameEndpointList`) ya da hata şeridi kalktıysa gelir: sunucu henüz eşitlemediyse (liste aynı) deneme **bildirim üretmez**.
* Hareket/animasyon eklenmedi; kartlar yeni yerleşime bir sonraki kareyle geçer (panjur kartı oluşur, lamba kartı kaybolur).

## 5. Zamanlama beklentisi (sözleşmeden türetildi; ölçülmedi)

| Değişim | Pano `state`'i buluta | Arayüze yansıma |
|---|---|---|
| panjur çifti / kanal sayısı (ek modül büyümesi) | ~0,4 sn (değişiklik gözcüsü), sunucu ~1 sn sonra eşitler | ≈ 2,5-3 sn |
| lamba ↔ darbe | bir sonraki kalp atışında (en geç 30 sn) | ≤ ≈ 33 sn |
| küçülme (ek modül kapandı) | ilk görüş + ≥ 20 sn sonra ikinci görüş (kalp atışı) | 3. deneme ≈ 42 sn'de görür |

## 6. DOĞRULANMADI / bilinen sınırlar

* **Gerçek pano ve gerçek EMQX üzerinde doğrulanmadı.** Kalp atışı aralığı (30 sn), sunucu eşitleme gecikmesi (~1 sn) ve küçülme onayı (≥ 20 sn arayla ikinci görüş) CONTRACTS §2.4b / tasarım belgesinden alındı; gecikmeler (2/10/30 sn) bunlardan türetildi, ölçülmedi. `ENDPOINT_LAYOUT_SYNC=off` yalnız sahte API ile (liste değişmeyen sunucu) simüle edildi.
* Sunucunun kabul koşullarından `v >= 2` istemcide denetlenemez (`DeviceStatus` sürüm alanını tutmaz); sürüm 1 bellenim zaten `type` bildirmez ve türden elenir. Sunucunun ad temizliği/`state` boolean denetimi gibi istemcinin göremediği ret nedenleri kalıcı uyuşmazlık bırakabilir → en çok 3 deneme, sonra durur.
* **Ad değişimi izlenmez** (bilinçli): adlar yalnız bir sonraki doğal yenilemede (çekip yenile, öne alma, kendi işlem) gelir.
* Küçülmede ikinci görüş kaybolursa (QoS 0 ileti kaybı) 3 deneme (≈ 42 sn) kaçırılabilir; sayaç dolu olduğundan sonraki kalp atışı yenileme başlatmaz (imza değişmedikçe). Elle çekip yenileme/öne alma listeyi getirir.
* Yenileme gelene kadar (~2-3 sn) ekranda eski lamba kartı görünür; sunucu panjura dönmüş kanala gelen röle komutunu `400` ('Panjur kanalları röle komutuyla sürülemez') ile reddeder (`device_service.js` `_assertCommandTarget`; eşitleme tamamlandıktan sonra, ≈1 sn), kart eski hâline döner. Gerçek motor hareketi riski yalnız sunucu eşitlemesi kapalıyken (`ENDPOINT_LAYOUT_SYNC=off`) ya da köprü commit'inden önceki <1 sn'lik aralıkta vardır; istemci tarafı ek koruma bu yüzden eklenmedi.
* RS485 bağlantısı titreyen bir kurulumda (kanal sayısı sürekli 8 ↔ 16) her yön değişimi yeni bir 2 sn'lik deneme başlatır; hız pano değişim hızıyla sınırlıdır (tek zamanlayıcı), ek üst sınır konmadı.
* Çok panolu ev: pano başına izleme gerçek çok panolu kurulumda denenmedi (testte iki sahte pano).

## 7. Testler

* `test/services/endpoint_layout_mismatch_test.dart` (32 test): denetleyici / imza / `sameEndpointList` birim testleri (saf).
* `test/services/state_layout_refresh_test.dart` (38 test): `AutomationState` — sahte saat + sahte bulut API + sahte MQTT; iptal noktaları zamanlayıcının kendisinin kalktığını denetler; `DeviceSections` ile arayüz kartlarının (panjur kartı oluşur, lamba kartları kaybolur) geçişi dahil.
* Doğrulama: `flutter analyze` 0 sorun; tam `flutter test` +3330 (taban +3260 + 70 yeni), ~272 atlanan, hepsi yeşil. Yeni testler ~30 kasıtlı kod bozma (mutasyon) ile sınandı: her kural/iptal noktası/sınır bozulunca en az bir test kırıldı.

## 8. Sunucu inceleme düzeltmelerinin istemci karşılığı (WP-SRVERR)

WP-L incelemesinde (CONTRACTS §2.4b) sunucuya iki yeni yanıt eklendi. REST biçimi değişmedi; istemci karşılıkları:

| Sunucu yanıtı | İstemci davranışı | Yer |
|---|---|---|
| `PUT /homes/:id/scheduled-rules/:ruleId {enabled:true}`: kapalı kural yeniden açılırken kanal tipi doğrulanır; uyumsuzsa `400 VALIDATION` + mesaj (ör. "Kanal 5 bir panjura ayrılmış; röle kuralı yerine panjur kuralı oluşturun") | Mesaj **aynen** gösterilir (`ApiException.message` ← sunucu `message`; `showFriendlyError` iletir). Genel "Kural güncellenemedi…" yalnız `ApiException` OLMAYAN bilinmeyen hatada çıkar. Anahtar iyimser çevrilmez: görünen değer `AutomationState.scheduledRules`'tan (sunucu yanıtından) çizilir, hatada liste değişmediği için anahtar KAPALI kalır ve yeniden denenebilir. Kural diyaloğunda (kaydet; düzenlemede `action` hep gönderildiği için sunucu yeniden doğrular) mesaj `text_rule_error`'da kalır, girdi korunur. | `scheduled_rules_page.dart` `_toggle`, `rule_dialog.dart` `_save` (kod DEĞİŞMEDİ; test eklendi) |
| `PUT /homes/:id/endpoints/:id`: eşitleme satırı bu arada değiştirdiyse `409 CONFLICT` "Kanal tipi değişti; listeyi yenileyin." (panjur süresi yazımında sunucu `set_runtime`'ı yayınlar ama çift artık panjur değilse veritabanına yazmaz; light↔plug tip yazımı) | `ApiException.isConflict` (`code == 'CONFLICT'`; `DEVICE_OFFLINE` ve öteki 409 kodları HARİÇ). Servis sihirbazı 8. adım (`ShutterLogic._putRuntime`; süre kaydı, ölçüm hazırlığı ve geri yükleme): uç nokta listesi (`_endpointIds`, `_endpointFor`'un tek kaynağı) yeniden okunur ve PUT **bir kez** yinelenir; yine 409 → `SetupProblem(conflict, "Kanal yerleşimi değişti", why: sunucu mesajı, todo: Listeyi yenileyip "Tekrar dene"ye basın.)`. "Tekrar dene" aynı yolu baştan yürütür (yeniden okur, yeniden dener). | `api_exception.dart`, `shutter_logic.dart` |

**Bilgi amaçlı sunucu değişiklikleri (istemci kodu gerekmedi):**

* Zamanlayıcı röle kuralını panjur kanalında yayınlamaz (`scheduled_rule_runs.status = 'skipped_invalid'`); istemci kural çalışma geçmişini göstermez.
* Lamba/priz ↔ darbe değişimi de röle kurallarını kapatır (`enabled = false`). Kural listesi `ScheduledRulesPage` HER açılışta (`initState`, ilk kareden sonra `fetchScheduledRules`) ve ayarlar özet kartı (`ScheduledRulesCard`) açılırken sunucudan okunur; çekip yenile ve ↻ da okur. Bu yüzden `_watchEndpointLayout` başarılı yenilemesi sonrası "kural listesi bayat" işareti **eklenmedi**: bayatlık yalnız kural sayfası/ayarlar AÇIKKEN yerleşim değişirse oluşur ve ↻ / çekip yenile listeyi getirir.

**Sınırlar / doğrulanmadı:**

* Gerçek sunucu ve panoda denenmedi; sunucu yanıtları CONTRACTS §2.4b ve servis kaynağından okunarak sahte API ile simüle edildi.
* Yenileme + tek yeniden deneme yalnız `409 CONFLICT` içindir. Silinmiş kimlik (`404`) ve `_endpointFor`'un kimliği hiç bulamadığı durum ("Sunucuda bu panjur için kayıt yok") listeyi yenilemez; bu yol eskisi gibidir.
* `AutomationState.updateEndpoint` (state sarmalayıcısı) uygulamada çağrılmıyor (yalnız testler): 409 için ek mantık eklenmedi; çağıran `ApiException.isConflict` ile ayırt edebilir.
* İkinci istekte de 409 gelirse (eşitleme hâlâ sürüyor) üçüncü deneme otomatik yapılmaz; kullanıcı "Tekrar dene" der.

**Testler (27 yeni):**

* `test/services/server_error_codes_test.dart` (6): gerçek `EvCloudApiService` + sahte HTTP; 400 VALIDATION mesajı ve 409 CONFLICT kodu / `isConflict` çözümlemesi (DEVICE_OFFLINE ve kodsuz 409 hariç).
* `test/ui/server_error_handling_test.dart` (8): kural sayfası ve diyalog; mesaj görünür, anahtar kapalı kalır (widget + anlamsal durum), başarı yolu, bilinmeyen hatada genel metin.
* `test/ui/f_setup_endpoint_conflict_test.dart` (13): sihirbaz 8. adım; 409 → yenile + yeniden dene → başarı (yeni kimlikle), iki kez 409 → `SetupProblem` (+ arayüz hata kutusu, "Tekrar dene"), çakışma dışı hatalarda yenileme/yeniden deneme yok, ölçüm hazırlığı yolu. Destek: `ServiceFakeCloud.updateEndpointErrorQueue` (`test/ui/f_support.dart`).
* Yeni testler kasıtlı kod bozma ile sınandı: genel metne düşme, geri alınmayan iyimser çevirme ve aşırı geniş `isConflict` (`statusCode == 409`) bozulunca ilgili testler kırıldı; yeniden deneme/yenileme kaldırılınca (uygulamadan önce) sihirbaz testleri kırmızıydı.
* Doğrulama: `flutter analyze` 0 sorun; tam `flutter test --concurrency=4` +4048, ~493 atlanan, hepsi yeşil (27 yeni test dahil; mevcut test dosyalarında yalnız `f_support.dart`'a eklemeli bir kanca konuldu, hiçbir mevcut test değişmedi; taban = 4048 − 27 = 4021 olarak türetildi, ayrıca ölçülmedi).
