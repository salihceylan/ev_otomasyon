# Firmware v1.3.1 — Sürüm Notları (2026-10-08)

> Durum: v1.3.1 = v1.3.0 + 2026-10-08 mantık denetimi düzeltmeleri (ayrıntı: `docs/denetim/2026-10-08-mantik-denetimi.md`).
> Kartta denendi (COM9, AHBU-S3-DD8754, 2026-10-08 ~21:56, yalnız uygulama 0x10000, ayarlar korundu): açılış, Wi-Fi,
> MQTTS bağlantısı, `fw: 1.3.1`, seri "Anahtar izi"; sunucu panonun izini kaydetti ve kendi anahtarından hesapladığı izle
> eşleşti. `version_info.json` bu sürümü gösterir.

## Dosyalar

| Dosya | Boyut | Ne zaman |
|---|---|---|
| `firmware_combined_0x0.bin` | 1409600 | Yeni / boş kart. 0x0'a yazılır. **Panonun ayarlarını (NVS: anahtar, Wi-Fi, bulut kimliği, güvenlik) SİLER.** |
| `app_0x10000_v1.3.1.bin` | 1344064 | Kurulu kartı güncellemek. **0x10000'e** yazılır; ayarlar korunur. 0x0'a yazmayın (kart açılmaz). |

SHA-256 (ana imaj): `7dd872a3527026e8a5da881ca0b13638912b136031ddcdb47972bf9744d12304`
SHA-256 (yalnız uygulama): `e2af218617340a3bb1533ecd699914a9692b80dd21e03c9f6ed5160fb383f6b8`
ELF SHA-256: `b3f75c55e8261e3ee96b924f6b9172412695321e8c19decf8be69b02930e32a8`

Derleme: PlatformIO espressif32@7.1.3 (Arduino-ESP32 2.0.17 / IDF 4.4), esptool `merge_bin` (`--flash_mode dio --flash_freq 80m
--flash_size 16MB`; 0x0 bootloader / 0x8000 bölüm tablosu / 0xe000 boot_app0 / 0x10000 uygulama). 0x0-0xFFFF bölgesi v1.2.1 ile aynı.
Boyut: Flash 1343693 bayt (%42,7), statik RAM ~69 KB. Testler: 25 grup / 417 test, 0 hata.

## v1.3.0'a göre değişenler

1. **Yerel anahtar parmak izi `lk_fp`** (pano-5): tam `GET /api/status`, MQTT state ve seri `STATUS` ("Anahtar izi:") — yalnız
   provizyonluyken. `HMAC-SHA256(local_key, "ahbu-lk-fp/1|" + UID)` ilk 8 hex; anahtarın kendisi hiçbir yere yazılmaz. Sunucu ve
   servis yazılımı panodaki anahtarın sunucudakiyle aynı olduğunu bununla doğrular (Ethernet'te auth/check her zaman 200 olduğu için).
2. **`ev/{t}/status` artık JSON** `{"status":"online|offline","uid":"<UID>"}` (bağlantı, LWT, planlı yeniden başlatma) (guvenlik-6):
   çok panolu evde bir panonun düşmesi diğerini çevrimdışı göstermez. Sunucu düz metni de okur (geriye uyumlu).
3. **Tam durumda gerçek `provisioned`** (servis_kurulum-1): Ethernet'ten anahtarsız erişilen provizyonsuz pano artık
   `provisioned:false` bildirir; sihirbaz/araç önce hazırlar.
4. **Provizyonsuz panoda `POST /api/auth/rekey` 403 `unprovisioned`, MQTT `set_local_key` yok sayılır** (pano-7): kurulum ağı
   parolasız kalmaz.
5. **Kurulum ağı istemcisi panonun Ethernet IP'sine istek atarsa "kablodan gelmiş" sayılmaz** (pano-3).
6. **Yalnız sensörlü güvenlik kurulumunda kilitli alarmla açılan pano güvenli kipe (latch_orphan) düşmez** (pano-1).
7. **Ek modül kanal sayısı değişince yeni girişler güvenle başlatılır** (pano-4): NC gaz/duman sensörü sahte alarm üretmez.
8. **Boş güvenlik yapılandırmasında da `cfg.safety{rev,crc}` bildirilir** (guvenlik-3): buluttan ilk yapılandırma yazılabilir.
9. **Reddedilen genel komutlar `last_rej` üretir** (pano-8): bulut zaman aşımı beklemez.
10. **Seri `DEFAULT_DI` güvenlik çapraz denetiminden geçer** (pano-9).

## Bilinen / donanımda doğrulanacaklar
- Ethernet (W5500) ve bootstrap HTTPS gerçek kablo/sunucu ile denenmedi.
- `lk_fp` sunucuyla uçtan uca doğrulandı (yukarıda). Anahtar döndürme (`set_local_key` + izle takas) kartta henüz
  tetiklenmedi; QA yığınındaki simülatörde uçtan uca geçiyor.
