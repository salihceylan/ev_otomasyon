# Kurulum şablonu sözleşmesi — `ahbu-template/1`

Plan: `docs/superpowers/plans/2026-10-08-site-sablon-kurulum.md` (K-Ş2..K-Ş6). Bu belge **tek kaynaktır**: sunucu
(`server/src/utils/template_schema.js`), firmware (`src/template/`) ve servis yazılımı (`template_model.py`) aynı kuralları
uygular ve bu klasördeki örnek dosyalarla test edilir (`fixtures/`). Firmware son söz sahibidir; sunucu ve araç erken uyarıdır,
ama örnek dosyalarda **üçü de aynı sonucu** vermelidir.

Biçim bilinçli olarak panonun bugünkü sözleşmelerinin birleşimidir:
- `relays[]` / `dis[]` / `ext_module` = `POST /api/config` alanları (adlandırılmış tipler/kiplerle),
- `safety.*` öğeleri = `cfg_patch` `set` gövdeleri (CONTRACTS §2.6, `SafetyCfgApi.h`) **birebir**.

## Kök

```json
{
  "schema": "ahbu-template/1",
  "meta": { ... },
  "ext_module": { ... },
  "relays": [ ... ],
  "dis": [ ... ],
  "safety": { ... }
}
```
Kökte başka alan yok (`bad_field`). `schema` farklıysa `schema`.

## `meta`
| Alan | Tip | Kural |
|---|---|---|
| `template_id` | string | UUID (küçük harf, 36 karakter) |
| `version` | int | 1..2^31-1 |
| `name` | string | 1..48 bayt UTF-8, kontrol karakteri yok |
| `flat_type` | string | 1..16 bayt (ör. `1+1`, `2+1`, `3+1`, `dubleks`) |
| `site_id` | string\|null | UUID ya da `null` (genel/standart şablon) |

Firmware `meta.template_id` ve `meta.version`'ı saklar (`ahbu_tpl`); `name`/`flat_type`/`site_id`'yi doğrular ama saklamaz.

## `ext_module`
`{"enabled": bool, "channels": int, "address": int}` — `channels` ∈ {0,2,4,8,12,16,24,32} (enabled=false ise 0 olmalı;
enabled=true ise 0 olamaz), `address` 1..247. Hata: `invalid_ext_channels`, `invalid_ext_address`.

**Toplam kanal** `N = 8 + (enabled ? channels : 0)` (en çok 40).

## `relays[]` — tam olarak N öğe, `ch` 1..N sırayla
| Alan | Tip | Kural |
|---|---|---|
| `ch` | int | dizideki sıra + 1 (aksi `relay_count`) |
| `name` | string | 1..31 bayt UTF-8 (`invalid_name`) |
| `room` | string | 0..31 bayt; **kartta saklanmaz**, buluta tohum ve PDF için |
| `type` | string | `light` \| `shutter_up` \| `shutter_down` \| `impulse` (`invalid_type`) |
| `runtime_s` | int | yalnız panjur: 1..300 (zorunlu); diğerlerinde YASAK (`invalid_runtime`) |
| `pulse_ms` | int | yalnız darbe: 100..60000 (zorunlu); diğerlerinde YASAK (`invalid_runtime`) |
| `load` | string | 0..48 bayt; serbest "bağlanacak yük" notu (PDF); **kartta saklanmaz** |

Dizi uzunluğu ≠ N → `relay_count`. Panjur çifti: (2p-1, 2p) = (`shutter_up`, `shutter_down`) olmalı; yetim / ters / çift
dışı panjur rölesi → `invalid_shutter_pair`. Panjur çiftinin iki rölesi aynı `runtime_s`'e sahip olmalı (`invalid_runtime`).

## `dis[]` — tam olarak N öğe, `ch` 1..N sırayla
| Alan | Tip | Kural |
|---|---|---|
| `ch` | int | sıra + 1 (`di_count`) |
| `name` | string | 1..31 bayt (`invalid_name`) |
| `target_relay` | int | 0 (boşta / sensör) .. N (`invalid_target_relay`) |
| `mode` | string | `toggle` \| `momentary` \| `shutter_step` \| `shutter_up` \| `shutter_down` (`invalid_mode`) |
| `wiring` | string | 0..48 bayt; PDF notu (ör. "Salon kapı yanı anahtar"); **kartta saklanmaz** |

Panjur kipleri (`shutter_*`) bir panjur çiftinin **yukarı** rölesini hedeflemeli (`invalid_target_relay`).
Güvenlik sensörü olarak kullanılan DI'nin `target_relay`'i 0 olmalı (`sensor_di_is_button`).

## `safety`
```json
"safety": {
  "policy":    {"on": true, "dry_hold_ms": 10000},
  "intrusion": {"exit_s": 45, "entry_s": 30},
  "zones":     [{"id": 1, "name": "Ev"}],
  "sensors":   [ {cfg_patch set.sensor} ],
  "actuators": [ {cfg_patch set.actuator, "id" YOK} ],
  "lights":    [ {cfg_patch set.light} ]
}
```
- `policy` zorunlu; `on` bool, `dry_hold_ms` 1000..600000 (`dry_hold`).
- `intrusion` isteğe bağlı; `exit_s`/`entry_s` 0..255 (0 = varsayılan).
- `zones`: 1..4 öğe, `id` 1..4 benzersiz, `name` 1..15 bayt. Bölge 1 her zaman bulunur.
- `sensors`: en çok 56. Öğe = `SafetyCfgApi.h` sensör nesnesi (`id` `d1..dN` ya da `b1..b16`, `kind`, `zone`,
  `active_open`, `flags`, `confirm_ms`, `name`≤19 bayt). Kurallar firmware `validate` ile aynı: aynı `id` iki kez
  `sensor_dup`; gaz/duman `active_open`=1 olmalı, yani NC kontak (`gas_smoke_not_nc`); anahtarlı kontak (`arm_key`) da
  NC (`arm_key_not_nc`); tehlike sensörlerinde `zone` 1..4 ve tanımlı bir bölge, kumanda sensörlerinde (`alarm_ack`,
  `valve_close`, `gas_reset`, `arm_key`) 0..4 (`sensor_zone`).
- `actuators`: en çok 16; sıra = `a1..`. Öğe = eylemci nesnesi **`id` alanı olmadan**. `relay` 1..N; panjur rölesi
  `act_relay_shutter`, darbe rölesi `act_relay_impulse`; aynı röle iki kez `act_relay_dup`; `zones` mevcut bölgeler.
- `lights`: en çok N; `relay` 1..N `light` tipinde, benzersiz. `dimmable`, `src` 0..2, `addr` 0..247, `ch` 0..255.

Güvenlik doğrulamasının tamamı firmware `safety::validate` + `validateSystemChange` kurallarıdır; sunucu/araç bu
listedeki kodları üretir, firmware ek olarak kendi kodlarını (`CfgErr` metinleri) üretebilir.

## Kartta uygulama zarfı

`POST /api/template/apply` (KEYED) ve seri `TPL` aynı gövdeyi taşır:
```json
{"template": { ...ahbu-template/1... }, "label": "Güneş Sitesi A-12"}
```
`label` isteğe bağlı, 0..31 bayt; `device_name` olarak yazılır (boşsa `meta.name`'in ilk 31 baytı).

Yanıt (200): `{"ok":true,"template_id":"…","version":4,"rev":<yeni güvenlik rev>}`.
Pano yazmayı bekleme süresinde bitiremezse **202** `{"pending":true}`: istemci `GET /api/template`'i (≈1 sn arayla,
≈20 sn) yoklar; id+sürüm eşleşirse başarı sayar. Ağ hatası/zaman aşımında da aynı geri okuma yapılır (yazım kaydı
yanlışlıkla "hata" olmasın).
Yeni (provizyonsuz) kart: `POST /api/factory/init` kurulum AP'sinden **ve Ethernet'ten** kabul edilir (kullanıcı kararı
2026-10-08; atölye zinciri USB'siz de olabilir: USB flash → Ethernet provizyon → Ethernet şablon). Eski v1.3.0 ön sürümü
403 `factory_ap_only` dönebilir.
Yarım kalmış uygulama (elektrik kesintisi): kart güvenli kipe girer; seri `TPL` ya da LAN uygulamasıyla yeniden
uygulanarak düzelir. Bildirim: tam durumda `"tpl_incomplete":true`, `GET /api/template`'te `"incomplete":true`, seri
`STATUS` `Sablon:` satırında `YARIM (...)` eki. `ahbu_tpl` ayrıca `txn` (u8) tutar. Bir uygulama sürerken ikinci LAN
isteği `503 busy`, ikinci seri `COMMIT` `ERR busy` alır.
Hata (400): `{"error":"<kod>","path":"relays[3].runtime_s"}` — `path` isteğe bağlı ama sunucu/araç her zaman doldurur.
**Kablolu Ethernet'ten gelen istek** (bağlantının yerel ucu panonun Ethernet IP'si) tüm yerel API'de
**anahtarsız ve provizyonsuz** yetkilidir; `/api/safety/config` gevşetmesi de serbesttir (kullanıcı kararı 2026-10-08, ikinci).
LAN gevşetme kuralı **kaldırıldı** (kullanıcı kararı 2026-10-08): LAN'dan her geçerli şablon uygulanır; eski
sürümler 403 `local_loosen_forbidden` dönebilir. Kilitli bölge 409 `zone_latched`; kurulu alarm 409 `armed`;
panjur hareket halinde 409 `busy`; NVS yetersiz 507 `storage`.

`GET /api/template` (KEYED) → `{"template_id":"…"|null,"version":N|0,"label":"…","applied_at_uptime_s":…}`.
Durum (`/api/status` tam) ve MQTT state: `"tpl":{"id":"…","ver":N}` (şablon yoksa alan yok).

## Seri protokol (USB)
```
TPL BEGIN <bayt> <crc32-hex8>      -> OK tpl_begin
TPL DATA <base64, ≤150 karakter>   -> OK tpl_data <alınan_bayt>
TPL COMMIT                         -> OK tpl_applied <template_id> <version>   |  ERR <kod> [path]
TPL ABORT                          -> OK tpl_abort
TPL STATUS                         -> TPL <template_id|-> <version> <label>
```
Gövde = uygulama zarfının UTF-8 JSON baytları; en çok 24576 bayt. CRC-32 (IEEE, `zlib.crc32`). `BEGIN`'den sonra 30 sn
içinde `COMMIT` yoksa aktarım silinir (`ERR tpl_timeout` bir sonraki komutta). Seri yol provizyon gerektirmez; LAN gibi güvenlik
tablosunu tamamen değiştirebilir (K-Ş4 değişikliği). `TPL DATA` satırları `[CLI] Komut alindi` ile yankılanmaz.
Hata kodları: `tpl_no_begin`, `tpl_size`, `tpl_crc`, `tpl_overflow`, `tpl_timeout`, `bad_json` + uygulama kodları.

## Sürümler (sunucu)
Şablon her kaydedildiğinde `meta.version` +1 olan yeni değişmez sürüm üretilir; sunucu `meta.template_id`/`version`'ı
kendisi doldurur (istemcinin gönderdiği değerler yok sayılır). Gövde SHA-256'sı sürümle saklanır.

## Ek hata kodları (firmware v1.3.0 ile hizalandı, 2026-10-08)
Yukarıdaki tablolarda adı geçmeyen durumlar için üç doğrulayıcı da şunları döndürür:

| Durum | Kod |
|---|---|
| `meta` alanları | `invalid_template_id`, `invalid_version`, `invalid_name`, `invalid_flat_type`, `invalid_site_id` |
| `relays[].room` / `relays[].load` / `dis[].wiring` | `invalid_room` / `invalid_load` / `invalid_wiring` |
| `safety.lights`: ışık olmayan röle ya da tekrar | `invalid_light` |
| eylemci `zones` içinde tanımsız bölge | `act_zone` |
| `zones` listesi: id hatası/tekrarı/bölge 1 yok · ad hatası | `bad_zone` · `bad_name` |
| yapı/tip hatası, bilinmeyen ya da eksik anahtar | `bad_field` |
| güvenlik öğe ayrıştırıcıları (`SafetyCfgApi`) | `bad_id`, `bad_kind`, `bad_zone`, `bad_value`, `bad_relay`, `bad_name`, `bad_field` |
| liste sınırı aşıldı | `count` |
| çapraz güvenlik kuralları (`safety::validate`) | `CfgErr` metinleri (`sensor_dup`, `act_relay_dup`, `fb_di_conflict` …) |
| zarf `label` | `invalid_label` (yalnız firmware; sunucu yalnız gövdeyi doğrular) |

Yol (`path`): öğe ayrıştırıcı hataları öğeyi (`safety.sensors[0]`), çapraz kural hataları listeyi (`safety.sensors`) gösterir.

Firmware'e özgü yanıtlar: HTTP bozuk JSON `400 invalid_json` (seri `bad_json`); cihaz durumuyla çakışma
`409 cfg_invalid` + `detail`; provizyonsuz kartta HTTP uygulama `403 unprovisioned` (atölye zinciri: flash → `FACTORYINIT`
→ şablon; ya da USB `TPL`); seri `ERR tpl_b64` (bozuk base64 / 150 karakter üstü satır), `ERR busy` (bellek yok).
`GET /api/template` `label` alanı etkin addır (label ya da `meta.name`'in ilk 31 baytı).

## Doğrulama sırası (ilk hata döner)
`schema` → kök alanlar (`bad_field`) → `meta` → `ext_module` → `relays` (sayı/sıra → her öğe → panjur çiftleri →
çift süreleri) → `dis` (sayı/sıra → her öğe) → `safety` (`policy` → `intrusion` → `zones` → `sensors` → `actuators` →
`lights`). Örneklerdeki beklenen kodlar bu sıraya göre seçilmiştir.

## Örnek dosyalar (`fixtures/`)
Üretici: `gen_fixtures.py` (elle düzenlemeyin; betiği değiştirip yeniden çalıştırın).
`ok_*.json` geçerli şablonlardır. `bad_*.json` dosyaları `{"expect": "<kod>", "template": {...}}` biçimindedir;
doğrulayıcı tam bu kodu döndürmelidir. Yeni kural eklenince buraya örnek eklenir.
