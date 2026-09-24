# GÜDE TEKNOLOJİ - ENDÜSTRİYEL AKILLI EV OTOMASYONU SİSTEMİ
## MASTER TEKNİK DOKÜMAN, MİMARİ STANDARTLAR VE ATOMİK İŞ PLANI

> **ÖNEMLİ NOT (AJAN ROL TANIMI):**  
> Bu bir hobi veya prototip projesi DEĞİLDİR. Binlerce daireye kurulacak, 7/24 sahada kesintisiz çalışacak, endüstriyel standartlarda **ticari bir IoT ürünüdür**.  
> Bu projede görev alan yapay zeka ajanı (Antigravity); **Kıdemli Gömülü Sistem Mühendisi (Embedded C++/FreeRTOS)**, **Kıdemli Flutter & Mobil Sistem Mimarı** ve **Bulut Altyapı Uzmanı** yetkinliğinde çalışmak zorundadır. Kolaycı, geçici, bloklayıcı (`delay()`), hafıza yıpratıcı veya sahada çökecek kestirme kodlar üretilemez.

---

## 1. MİMARİ KARARLAR VE ARKA PLAN (CONTEXT & ARCHITECTURE)

### 1.1. Mevcut Site Kapı Açma Sisteminin Korunması (Sıfır Kesinti İlkesi)
- **Mevcut Durum:** Sunucuda halihazırda üretimde (production) olan ve aktif kullanılan bir site kapı açma sistemi (API + Mosquitto MQTT) çalışmaktadır.
- **Kesin Kural:** Mevcut sisteme en ufak bir kesinti yaşatılmayacaktır. Sunucu genelindeki servisleri etkileyecek (`systemctl restart mosquitto`, global iptables sıfırlama vb.) hiçbir işlem yapılmayacaktır.
- **İzolasyon Stratejisi:** Ev otomasyonuna ait tüm servisler (Broker, Backend, Veritabanı, Cache) izole **Docker Compose** ortamında çalışacaktır.
- **Ağ ve DNS:** Yeni bir subdomain karmaşası (`mqtt2...` vb.) açılmayacaktır. Tek bir subdomain tanımlanmıştır: `evotomasyon.gudeteknoloji.com.tr`.
  - **HTTPS / Web API (Port 443):** Nginx Reverse Proxy üzerinden izole Docker backend'e yönlendirilir.
  - **MQTTS Broker (Port 8884):** Mevcut kapı sisteminin MQTT portlarıyla (1883/8883) çakışmaması için ev otomasyonu MQTTS broker'ı `8884` portundan izole TLS 1.3 ile hizmet verir.

### 1.2. Donanım ve Genişleme Mimarisi (32+ Röle Standardı)
- **Merkezi Gateway (Beyin):** *Waveshare ESP32-S3 Endüstriyel PoE Röle Modülü*.
- **Geliştirme Ortamı Bağlantısı:** İlk geliştirme ve laboratuvar testlerinde cihaz **2.4 GHz Wi-Fi (STA modu)** ile ağa bağlanacaktır. (Donanım üzerindeki W5500 SPI Ethernet ileride metal pano içi saha kurulumlarında devreye alınacaktır).
- **Genişleme (8 + 8 + ...):** Panoda gereksiz Wi-Fi kirliliği ve maliyeti önlemek için sisteme asla ikinci bir ESP32 eklenmeyecektir. Ana kartın üzerindeki izole **RS485** hattı üzerinden papatya dizilimiyle (daisy-chain) standart **Modbus RTU Slave röle modülleri** bağlanarak sistem 16, 24 veya 32 röleye genişletilecektir.
- **Pano Güç Güvenliği:** 32 röle aynı anda çektiğinde kartın reset atmasını (brownout) önlemek için panoda harici bir 12V/24V Mean Well DIN-ray güç kaynağı konumlandırılacaktır.

### 1.3. Donanım ve Can Güvenliği Kuralları
- **Panjur Interlock & Ölü Zaman (Dead-Time):** Panjur motorlarına aynı anda hem yukarı hem aşağı fazı verilmesi motoru yakar. Yazılım seviyesinde iki röle birbirine donanımsal ve mantıksal olarak kilitli (mutually exclusive) olacaktır. Yön değişimlerinde en az 500 ms ölü zaman (dead-time) state machine tarafından garanti edilecektir.
- **Süre Bazlı Pozisyonlama:** Mekanik limit switch'li motorlarda %0-%100 arası konum hesabı, kalibre edilen çalışma süresi üzerinden mikrodenetleyici yerel zamanlayıcılarıyla yönetilecektir.
- **Local-First Prensibi:** Evdeki internet veya bulut sunucu kopsa dahi, kart üzerindeki 8 opto-izole DI girişine bağlı duvardaki yaylı anahtarlar (light butonları) röleleri sıfır gecikmeyle tetiklemeye devam edecektir.

### 1.4. Rol Tabanlı Yetkilendirme (RBAC)
- **Kurulumcu / Teknisyen:** Donanım pin eşleme, kalibrasyon ve interlock ayarlarını yapan gizli servis menüsüdür.
- **Ev Sahibi (Home Admin):** QR kod okutarak cihazı sahiplenen (device claiming), aile bireylerini davet eden, oda ve senaryo oluşturan tam yetkili kullanıcıdır.
- **Sakin / Misafir:** Sadece yetkilendirildiği odalardaki cihazları kontrol edebilen kısıtlı kullanıcıdır.

---

## 2. YAZILIM MÜHENDİSLİĞİ STANDARTLARI (KODLAMA ANAYASASI)

### A. Gömülü Yazılım (ESP32-S3 / C++ / FreeRTOS)
1. **Asla `delay()` Kullanılmayacak:** Tüm gecikmeler ve zamanlamalar non-blocking state machine, `millis()` veya FreeRTOS `vTaskDelay()` / Software Timers ile yürütülecektir.
2. **Çift Çekirdek (Dual-Core) Görev Dağılımı:**
   - **Core 0:** Wi-Fi bağlantı yönetimi, TLS el sıkışması, MQTTS istemcisi, Keep-Alive pingleri.
   - **Core 1:** 8 opto-izole DI kesmeleri (Interrupts), röle sürüş mantığı, panjur state machine ve RS485 Modbus RTU sorguları.
   - İki çekirdek arasındaki veri transferi sadece FreeRTOS Queue (`xQueueSend` / `xQueueReceive`) ve Mutex mekanizmalarıyla thread-safe yapılacaktır.
3. **NVS Flash Aşınma Koruması (Anti Wear-Out):** Röle aç/kapa durumları veya anlık telemetri **ASLA her tetiklemede Flash'a yazılmayacaktır**. Röle durumları RAM'de tutulacak, durum senkronizasyonu MQTT `Retain` bayrağı ile bulut üzerinden çözülecektir. Flash'a yalnızca Wi-Fi kimlikleri, Cihaz ID ve panjur süre kalibrasyonu gibi nadir değişen ayarlar yazılacaktır.
4. **RS485 Half-Duplex Koruması:** RS485 hattında aynı anda veri gönderilip alınamaz. Modbus sorguları `Mutex` ile korunacak ve harici röle komutları bir kuyruk üzerinden sırayla hatta basılacaktır.
5. **Task Watchdog Timer (TWDT):** Ağ kopsa veya Modbus hattı yanıt vermese dahi hiçbir görev kilitlenmeyecektir. Görevler TWDT ile beslenecek, kilitlenme halinde cihaz kendini güvenli şekilde yeniden başlatacaktır.

### B. Mobil Uygulama (Flutter / Dart)
1. **Geliştirme Ortamı:** VS Code, Flutter SDK (Modern State Management: Riverpod veya BLoC).
2. **Kullanıcı Deneyimi (UX):**
   - Kullanıcı röleleri değil; odaları, işlevleri ve senaryoları yönetecektir.
   - Panjur için iki ayrı buton yerine tek dikey kaydırıcı (%0-%100) ve anlık `"Durdur"` butonu sunulacaktır.
   - Tek elle kullanım için kritik butonlar alt yarıda (thumb zone) konumlandırılacaktır.
3. **Optimistic UI ve Rollback:**
   - Düğmeye basıldığı an arayüz 16 ms içinde görsel/haptik tepki verecektir.
   - 2.5 saniye içinde donanımdan MQTTS onayı (`state`) gelmezse buton eski haline dönecek ve kullanıcıya alttan nazik bir uyarı (Snackbar) verilecektir.
4. **Bağlantı ve Yaşam Döngüsü (App Lifecycle):**
   - Uygulama arka plana geçtiğinde gereksiz soket/veri trafiği durdurulacak; ön plana geldiğinde anlık durumlar Redis/REST üzerinden tek bir snapshot ile tazelenecektir.

### C. Bulut & Sunucu Standartları (Docker, API, MQTT)
1. **Durum Yönetimi (Redis-First):** Mobil uygulama açıldığında yüzlerce cihazın anlık durumu veritabanından değil, Redis cache üzerinden milisaniyeler içinde sunulacaktır.
2. **Topic Hiyerarşisi:**
   - Komut: `ev/{home_id}/cmd/{endpoint_id}` -> Payload: `{"state": "ON"}` (QoS 1)
   - Durum: `ev/{home_id}/state/{endpoint_id}` -> Payload: `{"state": "ON", "source": "button"}` (QoS 1, Retain = true)
3. **Dinamik ACL:** Her cihaz ve kullanıcı sadece kendi `ev/{home_id}/#` konusuna erişebilir; başka dairelerin mesajlarını göremez veya müdahale edemez.

---

## 3. AJAN ÇALIŞMA PROTOKOLÜ (KATI KURALLAR)

1. **Atomik İlerleme:** Asla birden fazla alt adımı aynı anda kodlama. Tek seferde sadece **1 dosya veya 1 mantıksal modül** üzerinde çalış.
2. **Açıkla, Uyar ve Kodla:** Kodu sunmadan önce:
   - Kodun ne yaptığını 1-2 cümleyle açıkla.
   - Varsa donanımsal/yazılımsal riskleri (interlock, thread-safety vb.) belirt.
3. **Doğrulama ve Test Yönergesi:** Kodun hemen ardından kullanıcının çalıştıracağı komutu, seri port log beklentisini veya Flutter test adımını yaz.
4. **DUR VE BEKLE:** Kullanıcıdan `"TAMAM"`, test çıktısı veya hata mesajı gelmeden bir sonraki adıma **KESİNLİKLE GEÇME**.
5. **İşaretleme:** Tamamlanan adımı bu belgede `[x]` olarak işaretle.

---

## 4. ADIM ADIM İŞ PAKETLERİ (MASTER CHECKLIST)

### FAZ 1: Sunucu Altyapısı ve İzole Ağ

#### Adım 1.1: Subdomain ve Nginx Server Bloğu
- **Ne Yapılıyor?:** `evotomasyon.gudeteknoloji.com.tr` için izole Nginx sanal sunucu bloğu oluşturulması ve Let's Encrypt SSL sertifikası alınması.
- **Neden Yapılıyor?:** Mevcut site kapı sisteminin API konfigürasyonuna dokunmadan, ev otomasyonu web/API trafiğini bağımsız bir iç porta (`localhost:5000`) yönlendirmek ve mobil uygulamaların zorunlu kıldığı HTTPS güvenliğini sağlamak için.
- **Test/Doğrulama:** `sudo nginx -t` ile mevcut sistemlerin etkilenmediği teyit edilir ve `curl -I https://evotomasyon.gudeteknoloji.com.tr` ile SSL doğrulanır.
- [x] Durum: Tamamlandı (21.09.2026 - Let's Encrypt SSL & HTTP/2 502 doğrulandı)

#### Adım 1.2: İzole Docker Compose Altyapısı (EMQX, Postgres, Redis)
- **Ne Yapılıyor?:** Proje kökünde izole `docker-compose.yml` hazırlanması; EMQX MQTTS (`8884` portu), PostgreSQL ve Redis servislerinin ayağa kaldırılması.
- **Neden Yapılıyor?:** Kapı sisteminin kullandığı mevcut Mosquitto broker'ı ve veritabanını riske atmamak; ev otomasyonunun yüksek mesaj yükünü izole ve performanslı bir broker'da taşımak için.
- **Test/Doğrulama:** `docker compose ps` ile tüm servislerin `Up (healthy)` olduğu ve port çakışması olmadığı gözlemlenir.
- [x] Durum: Tamamlandı (21.09.2026 - EMQX TLS 1.3 / Port 8884, Postgres 16, Redis 7 Up & Healthy)

#### Adım 1.3: EMQX Dinamik ACL ve Çoklu Kullanıcı Kuralları
- **Ne Yapılıyor?:** EMQX üzerinde ev otomasyonuna özel istemci doğrulama (auth) ve konu bazlı yetki (ACL) kurallarının tanımlanması.
- **Neden Yapılıyor?:** Farklı dairelerin kullanıcılarının veya cihazlarının birbirlerinin `ev/{home_id}/#` konularını dinlemesini veya müdahale etmesini broker seviyesinde engellemek için.
- **Test/Doğrulama:** `mosquitto_pub` / `mosquitto_sub` ile yetkisiz bir topic'e yazma testi yapılır; bağlantının reddedildiği (denied) loglanır.
- [x] Durum: Tamamlandı (21.09.2026 - PostgreSQL Auth, Dinamik Zero-Trust ACL, MQTTS TLS 1.3 & Çapraz Daire Engeli Doğrulandı)

---

### FAZ 2: ESP32-S3 Çekirdek Firmware & Güvenlik

#### Adım 2.1: PlatformIO Ortamı ve 2.4 GHz Wi-Fi Bağlantısı
- **Ne Yapılıyor?:** ESP32-S3 için PlatformIO C++ projesinin kurulması, 2.4 GHz Wi-Fi (STA modu) bağlantısının sağlanması ve bağlantı koptuğunda otomatik yeniden bağlanma (exponential backoff) döngüsünün yazılması.
- **Neden Yapılıyor?:** Geliştirme ve prototip aşamasında cihazın yerel ağa ve internete en hızlı şekilde çıkmasını sağlamak için.
- **Test/Doğrulama:** Seri monitörde (115200 baud) ESP32'nin Wi-Fi'a bağlandığı, yerel IP aldığı ve ağa ping atabildiği doğrulanır.
- [x] Durum: Tamamlandı (21.09.2026 - FreeRTOS Core 0 WiFiManager, Exponential Backoff, NVS kalıcı kayıt ve CLI STATUS/WIFI uçtan uca doğrulandı)

#### Adım 2.2: Dahili 8 Röle ve 8 Opto-İzole Giriş (DI) Sürücüsü
- **Ne Yapılıyor?:** Kart üzerindeki 8 röle çıkışı ve 8 opto-izole dijital girişin GPIO eşlemelerinin yapılması; buton arklarını önleyen yazılımsal filtreleme (debounce) eklenmesi.
- **Neden Yapılıyor?:** Duvardaki yaylı butonlara basıldığında rölelerin milisaniyeler içinde internetten bağımsız olarak açılıp kapanmasını sağlamak için.
- **Test/Doğrulama:** DI-1 klemensine kuru kontak verildiğinde Röle-1'in fiziksel olarak tık sesiyle çektiği ve bırakıldığı test edilir.
- [x] Durum: Tamamlandı (21.09.2026 - TCA9554 8RO ve GPIO 4-11 8DI 60ms debounce, CLI RELAY/DI komutları ve HTTP API üzerinden uçtan uca doğrulandı)

#### Adım 2.3: Panjur Güvenlik Motoru (Interlock & Dead-Time State Machine)
- **Ne Yapılıyor?:** Panjurlar için tanımlanan iki rölenin (Örn: Röle 1 Yukarı, Röle 2 Aşağı) aynı anda enerjilenmesini engelleyen mantıksal kilidin ve yön değişimlerinde 500 ms'lik zorunlu bekleme süresinin kodlanması.
- **Neden Yapılıyor?:** Panjur motor sargılarına aynı anda çift faz gitmesini ve motorun yanmasını yazılım seviyesinde kesin olarak engellemek için.
- **Test/Doğrulama:** Yukarı komutu aktifken aniden aşağı komutu verilir; seri logda önce yukarı rölesinin kapandığı, 500 ms beklendiği ve ardından aşağı rölesinin çektiği doğrulanır.
- [x] Durum: Tamamlandı (21.09.2026 - Asenkron 500ms Dead-Time & Çift Yönlü Hard Interlock kodlandı, COM9 donanımında anında yön değişimi ve 500ms ölü zaman geçişi canlı doğrulandı)

#### Adım 2.4: Panjur Süre Kalibrasyonu ve Pozisyon Yönetimi
- **Ne Yapılıyor?:** Panjurun tam açılma ve tam kapanma sürelerinin (ör. 18 sn) ölçülüp ESP32'nin kalıcı hafızasına (NVS Flash) kaydedilmesi; gelen % komutuna göre zamanlayıcıyla röleyi durduran fonksiyonun yazılması.
- **Neden Yapılıyor?:** Mekanik sensörsüz standart motorlarda kullanıcının mobil uygulamadan panjuru %50 (yarı açık) konumuna getirebilmesini sağlamak için.
- **Test/Doğrulama:** `%50` komutu gönderilir; rölenin tam 9 saniye çekili kalıp otomatik kapandığı doğrulanır.
- [x] Durum: Tamamlandı (21.09.2026 - %0-%100 pozisyon hesabı, NVS flash kalıcı saklama, mekanik re-homing marjı, CLI/HTTP API ve 10.00s / 5.00s hassas duruş COM9 üzerinde uçtan uca canlı doğrulandı)

#### Adım 2.5: Güvenli MQTTS (Port 8884) İstemcisi ve Durum Raporlama
- **Ne Yapılıyor?:** ESP32'nin sunucudaki EMQX broker'ına TLS 1.3 şifrelemeyle bağlanması, LWT (Last Will: `ev/{id}/status -> offline`) tanımlanması ve röle durumlarının Retain bayrağıyla yayınlanması.
- **Neden Yapılıyor?:** Elektrik kesildiğinde kullanıcının uygulamasında anında "Çevrimdışı" uyarısının çıkması ve uygulama açıldığında röle durumlarının anında yüklenmesi için.
- **Test/Doğrulama:** Cihazın Wi-Fi bağlantısı kesildiğinde broker tarafında saniyeler içinde `offline` LWT mesajının düştüğü gözlemlenir.
- [x] Durum: Tamamlandı (21.09.2026 - TLS 1.3 Port 8884 MQTTS istemcisi, Zero-Trust ACL yetkilendirmesi, LWT offline/online tescili, ev/{user}/state retain raporlama ve ev/{user}/cmd çift yönlü uzaktan yönetim uçtan uca canlı doğrulandı)

---

### FAZ 3: RS485 Modbus RTU Genişleme (32+ Röle Altyapısı)

#### Adım 3.1: RS485 Donanımsal Seri Port ve Modbus Master Entegrasyonu
- **Ne Yapılıyor?:** ESP32-S3'ün dahili RS485 transceiver pinleri (TX: GPIO17, RX: GPIO18, 8N1) üzerinden Modbus RTU Master kütüphanesinin/sürücüsünün kurulması ve FreeRTOS Mutex (`_rs485Mutex`) korumalı sorgu/işlem altyapısının oluşturulması.
- **Neden Yapılıyor?:** Çok çekirdekli (Core 0 MQTTS, Core 1 Döngü/Web/Girişler) ortamda RS485 bus çakışmasını engellemek, tek kablo hattı üzerinden yüksek hızda ve çakışmasız haberleşmek için.
- **Test/Doğrulama:** RS485 hattına komut gönderildiğinde Modbus frame yapısı (CRC16 dahil) ve CLI `RS485 STATUS`, `RS485 SCAN`, `RS485 SEND` komutları üzerinden canlı doğrulandı.
- [x] Durum: Tamamlandı (21.09.2026 - UART1 RX:18/TX:17 FreeRTOS Mutex korumalı atomik `rs485Transaction`, Modbus CRC-16-IBM ve CLI tanı araçları COM9 üzerinde canlı doğrulandı)

#### Adım 3.2: Harici Modbus Slave Röle Kartı Kontrolü
- **Ne Yapılıyor?:** RS485 hattına bağlı Modbus Slave röle kartının (ör. ID: `0x01` veya NVS adresi) coil kayıtlarına okuma/yazma fonksiyonlarının (`0x05 Write Single Coil`, `0x01 Read Coils`, `0x02 Read Discrete Inputs`) ve dinamik polling döngüsünün yazılması.
- **Neden Yapılıyor?:** Panodaki ilave 8, 16 veya 32 rölenin ve dijital girişin ESP32 tarafından bağımsız ve güvenli bir şekilde kontrol edilebilmesi için.
- **Test/Doğrulama:** Harici slave röleye komut gönderildiğinde `01 05 00 00 FF 00 8C 3A` (ON) ve `01 05 00 00 00 00 CD CA` (OFF) Modbus RTU frame'lerinin hat üzerinde hatasız CRC16 ile oluşturulduğu ve yürütüldüğü doğrulandı.
- [x] Durum: Tamamlandı (21.09.2026 - Modbus 0x05 Write Single Coil, 0x01 Read Coils, 0x02 Read Discrete Inputs ve periyodik sorgulama döngüsü COM9 üzerinde canlı doğrulandı)

#### Adım 3.3: Birleşik Röle Soyutlama Yöneticisi (Unified Relay Manager)
- **Ne Yapılıyor?:** Sistem genelinde tüm röleleri `1`den `40`a kadar tek bir fonksiyon altında toplayan şeffaf yönetim katmanının (`setRelayState(index, state)`, `getRelayState(index)`, `toggleRelay(index)`) yazılması.
- **Neden Yapılıyor?:** Mobil uygulama, Web portalı veya MQTT katmanının rölenin dahili TCA9554 üzerinde mi yoksa RS485 modülünde mi olduğunu bilmesine gerek kalmadan tek elden şeffaf yönetim sağlamak için.
- **Test/Doğrulama:** CLI `RELAY 1 ON` dahili röleyi, `RELAY 9 ON` harici slave röleyi tetikler. MQTTS `ev/home_101/cmd` üzerinden gelen `{"relay": 9, "state": true}` komutu RS485 Modbus frame'ini gönderip 16 rölelik durum raporunu EMQX broker'a anında yayınlar.
- [x] Durum: Tamamlandı (21.09.2026 - 1..40 birleşik röle soyutlaması, NVS dinamik kanal boyutu, CLI RELAY/SHUTTER ve çift yönlü TLS 1.3 MQTTS üzerinden harici röle yönetimi COM9 üzerinde uçtan uca canlı doğrulandı)


---

### FAZ 4: Backend API & Çoklu Kullanıcı / Güvenlik

#### Adım 4.1: Multi-Tenant Veritabanı Şeması (PostgreSQL)
- **Ne Yapılıyor?:** `Homes`, `Users`, `Roles (Kurulumcu, Ev Sahibi, Sakin)`, `Devices (ESP32 MAC/UUID)`, `Endpoints (Lamba, Panjur)` ilişkisel tablolarının oluşturulması.
- **Neden Yapılıyor?:** Binlerce dairenin verilerini, kullanıcı yetkilerini ve cihaz sahipliklerini birbirinden tamamen izole tutmak için.
- **Test/Doğrulama:** Veritabanı migration'ı çalıştırılır; örnek bir daire ve cihaz ilişkisi eklenerek sorgulanır.
- [x] Durum: Tamamlandı (21.09.2026 - PostgreSQL 16 izole Port 5434 veritabanında `users`, `homes`, `home_users`, `devices`, `endpoints`, `service_tokens` tabloları, trigger'lar ve indeksler oluşturuldu, ilişkisel sorgu doğrulandı)

#### Adım 4.2: Cihaz Sahiplenme (Device Claiming) API
- **Ne Yapılıyor?:** Pano kapağındaki QR kodda bulunan `Device UUID` ve fabrikasyon tek kullanımlık `Setup PIN`i doğrulayıp cihazı ilgili kullanıcının evine bağlayan API uç noktasının (`POST /api/devices/claim`) yazılması.
- **Neden Yapılıyor?:** Donanımın yetkisiz kişilerce çalınmasını/başka hesaba eklenmesini önlemek ve montajcının işini hızlandırmak için.
- **Test/Doğrulama:** Geçersiz PIN ile yapılan istek `403 Forbidden` döner; doğru PIN ile cihaz eşlenir (`201 Created`) ve mükerrer sahiplenmede `409 Conflict` hatası döndüğü canlı API üzerinde doğrulandı.
- [x] Durum: Tamamlandı (21.09.2026 - `POST /api/devices/claim` uç noktası canlı VPS'e dağıtıldı, 403 ve 201 durumları uçtan uca doğrulandı)

#### Adım 4.3: Geçici Teknisyen/Kurulumcu Yetki Sistemi
- **Ne Yapılıyor?:** Ev sahibinin uygulama üzerinden teknisyene 2 saat geçerli geçici servis PIN'i/token'ı üretebilmesini (`POST /api/homes/:home_id/service-token`) ve teknisyenin bu PIN ile servis oturumu açabilmesini (`POST /api/auth/service-login`) sağlayan servis.
- **Neden Yapılıyor?:** Teknisyenin pano kablolama veya kalibrasyon ayarlarını yapabilmesi, ancak iş bittikten sonra ailenin mahremiyetini izleyememesi için.
- **Test/Doğrulama:** Ev sahibi 6 haneli servis PIN'i üretti; teknisyen bu PIN ile 2 saat geçerli `installer` JWT oturumu açtı; aynı PIN ile 2. denemede `403 Forbidden` reddi alındığı doğrulandı.
- [x] Durum: Tamamlandı (21.09.2026 - 2 saatlik geçici servis PIN'i, tek kullanımlık tüketim ve teknisyen rolü canlı API üzerinden doğrulandı)


---

### FAZ 5: Flutter Mobil Uygulama & Kullanıcı Deneyimi (Frontend)

#### Adım 5.1: Flutter Temel Mimarisi ve MQTTS / REST Servis Katmanı
- **Ne Yapılıyor?:** Flutter projesinde Riverpod/BLoC mimarisinin kurulması; MQTTS (Port 8884) istemcisi ve REST API servislerinin bağlanması.
- **Neden Yapılıyor?:** Cihaz durumlarını gerçek zamanlı dinlemek ve çift yönlü komut akışını sağlamak için.
- **Test/Doğrulama:** Uygulama açıldığında test MQTT konusuna başarıyla bağlandığı ve log bastığı teyit edilir.
- [x] Durum: Tamamlandı (21.09.2026 - `mqtt_client: ^10.4.0` entegre edildi; `EvMqttService` Port 8884 TLS 1.3 çift yönlü haberleşme, `EvCloudApiService` REST istemcisi ve `AutomationState` birleşik sağlayıcısı kodlandı, 6/6 test ve clean analyze doğrulandı)

#### Adım 5.2: Ana Ekran (Glanceable UI & Durum Hapları)
- **Ne Yapılıyor?:** Üst barda durum çipleri (`"3 Işık Açık"`, `"Panjurlar Kapalı"`), hızlı senaryo butonları (`"Evden Çıkıyorum"`, `"Günaydın"`) ve oda filtreleme listesinin kodlanması.
- **Neden Yapılıyor?:** Kullanıcının uygulamayı açtığı ilk 2 saniyede evin tüm durumunu görüp tek tıkla toplu eylem alabilmesini sağlamak için.
- **Test/Doğrulama:** Flutter emülatöründe veya fiziksel cihazda senaryo butonunun tetiklendiği ve state güncellediği görülür.
- [x] Durum: Tamamlandı (21.09.2026 - Üst bar dinamik durum hapları, `QuickScenarioBar` kartları ve yatay kaydırılabilir `Room Filter Chips` responsive & taşmasız olarak kodlandı)

#### Adım 5.3: Panjur Özel Bileşeni ve Optimistic UI Rollback
- **Ne Yapılıyor?:** Panjurlar için tek bir dikey yüzde kaydırıcı (%0-%100) ve anlık `"Durdur"` butonu bileşeninin yazılması; 2.5 sn içinde donanım ACK vermezse eski konuma dönen Optimistic UI mekanizmasının eklenmesi.
- **Neden Yapılıyor?:** Panjur yönetimini basitleştirmek ve ağ gecikmelerinde arayüzün takılmış gibi hissettirmesini engellemek için.
- **Test/Doğrulama:** Slider %40'a çekilir; MQTT mesajı yollanır; cihaz çevrimdışıyken slider'ın eski konumuna zıplayıp Snackbar uyarısı verdiği test edilir.
- [x] Durum: Tamamlandı (21.09.2026 - `ShutterCard` %0-%100 kaydırıcı, `%` anlık pozisyon rozeti, anlık `DURDUR/AÇ/KAPAT` butonları ve 2.5 sn Optimistic Rollback mekanizması birim testleriyle doğrulandı)

#### Adım 5.4: Gizli Kurulumcu / Servis Menüsü (Service Mode)
- **Ne Yapılıyor?:** PIN korumalı servis ekranının kodlanması: Röleleri odalara atama, cihaz tiplerini belirleme (Lamba / Panjur / Priz) ve panjur motor çalışma sürelerini test edip kalibre etme arayüzü.
- **Neden Yapılıyor?:** Sahadaki montajcının kod veya konsol açmadan tüm evi 5 dakikada telefon üzerinden devreye alabilmesini sağlamak için.
- **Test/Doğrulama:** Menüden panjur açılma süresi 15 sn'den 22 sn'ye güncellenir; ESP32'nin yeni süreyi onayladığı görülür.
- [x] Durum: Tamamlandı (21.09.2026 - `ServiceModePage` 6 haneli geçici servis PIN girişi, ev sahibi için 2 saatlik PIN üretme, tek dokunuşla Cihaz Eşleme (Claiming) ve motor süresi kalibrasyon arayüzü kodlandı)

---

## 5. BAŞLANGIÇ YÖNERGESİ (BOOTSTRAP)

Bu belge VS Code Antigravity ajanına verildiğinde ajan:
1. Kuralları, ticari ürün disiplinini, Flutter ortamını ve sıfır-kesinti ilkesini anladığını kısaca teyit edecektir.
2. Doğrudan **Faz 1 - Adım 1.1**'i özetleyecek ve ilk yapılacak işi açıklayacaktır.
3. Kullanıcıdan açık onay gelmeden **kesinlikle kod yazmaya başlamayacaktır**.







GÜDE TEKNOLOJİ - AHBU OTOMASYON
EK İŞ PAKETİ: KULLANICI YÖNETİMİ, ENVANTER & KAREKODLU SAHİPLENME (CLAIMING) MİMARİSİ
> **DOKÜMAN AMACI & ROL TANIMI:**  
> Bu belge, ana `PROJECT_TASKS.md` dosyasına ek olarak hazırlanmış ticari devreye alma protokolüdür.  
> Yapay zeka asistanı (Antigravity); **Kıdemli Flutter Mimarı** ve **IoT Güvenlik Uzmanı** rolüyle çalışacaktır. Prototip kestirmeleri yasaktır. Tüm adımlar atomik olarak uygulanacak, test talimatı verilecek ve kullanıcı onayı beklenmeden sonraki adıma geçilmeyecektir.
---
1. TİCARİ YAŞAM DÖNGÜSÜ VE GÜVENLİK MODELİ
Sistem 3 temel aşamalı bir "Sıfır Güven" (Zero-Trust) zinciriyle çalışır:
Aşama 1: Atölye / Fabrika Tanımlama (Provisioning):
Kartın benzersiz donanım kimliği (`Chip UUID / MAC`) okunur.
Kriptografik rastgele 6 haneli tek kullanımlık `Setup PIN` üretilir.
Backend `device_inventory` tablosuna `IN_STOCK` durumuyla kaydedilir.
Pano kapağı için fiziksel QR etiket basılır: `https://evotomasyon.gudeteknoloji.com.tr/claim?uid={UID}&pin={PIN}`.
Aşama 2: Saha / Daire Kurulumu (Teknisyen):
Teknisyen panoyu fiziksel olarak daireye bağlar.
Gömülü Web Portalı veya Servis Menüsü ile röle/panjur süre kalibrasyonlarını tamamlar.
Cihaz artık çalışmaya ve devredilmeye hazırdır (`INSTALLED`).
Aşama 3: Müşteri Girişi & Cihazı Sahiplenme (Claiming):
Kullanıcı Flutter uygulamasını indirir, üye olur ve oturum açar.
Uygulama içindeki kamera ile panodaki QR kodu okutur.
Backend PIN'i doğrular, cihazı kullanıcının evine zimmetler (`CLAIMED`), PIN'i yakar (tek kullanımlık).
Kullanıcı, teknisyenin önceden yapılandırdığı lamba ve panjurları anında ekranında hazır bulur.
---
2. ADIM ADIM EK İŞ PAKETLERİ (CHECKLIST)
FAZ 6: Backend Envanter & Yetkilendirme Altyapısı
Adım 6.1: Envanter Veritabanı Şeması ve Migration
Ne Yapılıyor?: PostgreSQL üzerinde `device_inventory` tablosunun ve durum tiplerinin (`IN_STOCK`, `INSTALLED`, `CLAIMED`, `REVOKED`) oluşturulması.
Neden Yapılıyor?: Şirket envanterinde kayıtlı olmayan sahte/kaçak cihazların sisteme eklenmesini engellemek ve cihaz yaşam döngüsünü denetlemek için.
- [x] Durum: Tamamlandı (22.09.2026 - PostgreSQL 16 `device_inventory` tablosu, `IN_STOCK`/`INSTALLED`/`CLAIMED`/`REVOKED` durumları, brute-force kilit sayaçları, SHA-256 PIN hash'i ve indeksler izole Docker DB üzerinde oluşturuldu; test cihazı başarıyla kaydedildi)
Adım 6.2: Servis / Fabrika Kayıt API'si (`POST /api/v1/admin/inventory/register`)
Ne Yapılıyor?: Sadece şirket admin/servis API anahtarıyla erişilebilen; cihaz UID'si, PIN karması (SHA-256), model ve parti numarasını envantere kaydeden API uç noktasının yazılması.
Neden Yapılıyor?: Üretim hattında üretilen panoların merkezi veritabanına seri şekilde kaydedilebilmesi için.
- [x] Durum: Tamamlandı (22.09.2026 - `admin_api_key_middleware.js`, `inventory_service.js` ve `inventory_routes.js` kodlandı; VPS üzerinde PM2 `ev-api` güncellendi; 401 Unauthorized, 201 Created QR üretimi, 409 Conflict ve listeleme testleri canlı API üzerinde %100 doğrulandı)
Adım 6.3: Cihaz Sahiplenme Doğrulama Motoru (`POST /api/v1/devices/claim`)
Ne Yapılıyor?: Mobil uygulamadan gelen `{ uid, pin, homeName }` paketini doğrulayan; PIN eşleşirse cihazı kullanıcının yeni açılan evine bağlayan, `setup_pin`i geçersiz kılıp durumu `CLAIMED` yapan servis mantığının kodlanması.
Neden Yapılıyor?: Panonun kapağındaki QR kodu başkası görse dahi tek kullanımlık PIN yandığı için cihazın çalınmasını kesin olarak engellemek için. 5 yanlış denemede IP kısıtlaması (Rate-limiting) uygulanır.
- [x] Durum: Tamamlandı (22.09.2026 - `device_service.js` Zero-Trust doğrulama motoru kodlandı; brute-force kilit sayacı, SHA-256 PIN kontrolü, otomatik ev/daire ve 16 kanal endpoint kurulumu, tek kullanımlık PIN'in 'CLAIMED_BURNED_PIN' ile kalıcı yakılması ve mükerrer 409 Conflict koruması canlı VPS API üzerinde uçtan uca %100 doğrulandı)
---
FAZ 7: Flutter Kullanıcı Yönetimi & Oturum Mimarisi (Auth Lifecycle)
Adım 7.1: Güvenli Depolama & Auth State Yönetimi
Ne Yapılıyor?: `flutter_secure_storage` entegrasyonu; JWT access/refresh token'ların şifreli saklanması, `AuthProvider` (Riverpod/BLoC) ile oturum durumunun yönetilmesi.
Neden Yapılıyor?: Kullanıcının her uygulama açılışında tekrar şifre girmesini önlemek ve token süresi dolduğunda sessizce yenilemek (silent refresh) için.
- [x] Durum: Tamamlandı (22.09.2026 - `flutter_secure_storage: ^11.2.0` entegre edildi, `SecureStorageService` yazıldı, `AutomationState` içine `AuthStatus` durum makinesi ve sessiz oturum doğrulama (silent auth) eklendi; 9/9 birim/widget testleri ve analiz hatasız geçti)
Adım 7.2: Giriş, Kayıt ve Şifre Sıfırlama Ekranları (UI/UX)
Ne Yapılıyor?: Kurumsal AHBU Otomasyon temasına uygun `LoginScreen`, `RegisterScreen` ve `ForgotPasswordScreen` arayüzlerinin kodlanması.
Neden Yapılıyor?: Müşterinin sisteme kurumsal ve pürüzsüz bir arayüzle ilk temasını sağlamak için.
Test/Doğrulama: Geçersiz e-posta veya kısa şifre girildiğinde form doğrulama (validation) hatalarının gösterildiği; başarılı girişte dashboard'a geçildiği test edilir.
- [x] Durum: Tamamlandı (22.09.2026 - `LoginPage`, `RegisterPage`, `ForgotPasswordPage` ve `AuthGate` kurumsal tasarımla kodlandı; form doğrulama, şifre gizleme/gösterme, servis PIN girişi, yerel mod geçişi ve taşmasız (0 overflow) responsive düzen 14/14 test ve temiz analizle doğrulandı)
Adım 7.3: Profil ve Güvenli Çıkış (Logout Flow)
Ne Yapılıyor?: Profil/Ayarlar menüsüne kullanıcı bilgileri kartı ve `"Oturumu Kapat"` fonksiyonunun eklenmesi; çıkış yapıldığında yerel token'ların temizlenmesi, aktif MQTT bağlantılarının kapatılması ve giriş ekranına yönlendirilmesi.
Neden Yapılıyor?: Cihaz başkasına devredildiğinde veya hesap değiştirildiğinde eski kullanıcının veri ve bildirim almasını engellemek için.
Test/Doğrulama: Çıkış yap butonuna basılır; yerel hafızanın sıfırlandığı ve MQTT aboneliklerinin düştüğü doğrulanır.
- [x] Durum: Tamamlandı (22.09.2026 - `UserProfileDialog` kullanıcı profili ve güvenli çıkış bileşeni kodlandı; `DashboardPage` ve `DeviceSettingsPage` entegrasyonu yapıldı; `state.logout()` ile şifreli token'lar ve oturum hafızası temizlendi, MQTT abonelikleri kapatıldı ve `AuthGate` üzerinden `LoginPage`'e anında yönlendirme 15/15 test ve temiz analizle doğrulandı)
---
FAZ 8: Flutter Karekod ile Cihaz Eşleme (Claiming UI)
Adım 8.1: Kamera İzinleri ve `mobile_scanner` Entegrasyonu
Ne Yapılıyor?: Android (`AndroidManifest.xml`) ve iOS (`Info.plist`) kamera izinlerinin yapılandırılması; `mobile_scanner` paketi ile modern bir QR tarayıcı ekranının (`QrScannerScreen`) tasarlanması.
Neden Yapılıyor?: Kullanıcının panodaki karekodu tek dokunuşla hızlıca okutabilmesi için.
Test/Doğrulama: Kamera açılır; test amaçlı ekrandaki bir QR kod taratıldığında ham verinin yakalandığı seri logda görülür.
- [x] Durum: Tamamlandı (22.09.2026 - `mobile_scanner: ^7.4.2` paketi entegre edildi; AndroidManifest.xml CAMERA izinleri ve iOS Info.plist NSCameraUsageDescription eklendi; `QrScannerPage` vizör çerçeveli, flaş ve kamera çevirme kontrolleriyle kodlandı; 16/16 test ve temiz analizle doğrulandı)
Adım 8.2: QR Derleyici & Manuel Giriş Desteği (Fallback)
Ne Yapılıyor?: Taranan linkten (`.../claim?uid=XYZ&pin=123456`) UID ve PIN parametrelerini ayrıştıran parser fonksiyonunun yazılması; kamerası bozuk veya karanlık ortamdaki kullanıcılar için altta `"Kodu Elle Gir"` modal formunun eklenmesi.
Neden Yapılıyor?: Saha koşullarında kameranın odaklanamaması veya etiket deformasyonu durumunda sürecin tıkanmasını engellemek için.
Test/Doğrulama: Bozuk bir QR okutulduğunda kullanıcıya hata mesajı verilir; elle girilen geçerli UID/PIN ile akışın başarıyla devam ettiği doğrulanır.
- [x] Durum: Tamamlandı (22.09.2026 - `QrClaimParser` ile URL, JSON ve düz metin QR formatları ayrıştırıldı; `ClaimManualDialog` manuel form ve fallback entegrasyonu kodlandı; `DashboardPage` AppBar'ına 'Cihaz Eşle (Karekod)' butonu eklendi; 23/23 test ve temiz analizle doğrulandı)
Adım 8.3: Otomatik Karşılama ve Kanal Yükleme Akışı
Ne Yapılıyor?: Cihaz başarıyla sahiplenildiğinde kullanıcının yeni evine yönlendirilmesi; ESP32'nin NVS hafızasında teknisyenin yapılandırdığı kanal adlarının (Salon Panjur, Mutfak Spot vb.) REST/MQTT üzerinden çekilip Dashboard'a otomatik dizilmesi.
Neden Yapılıyor?: Kullanıcının elektrik bağlantılarıyla veya kanal yapılandırmasıyla uğraşmadan, sistemi anahtar teslim kullanabilmesi için.
Test/Doğrulama: Claim tamamlandığında ana ekranda panjur kartı ve lambaların isimleriyle birlikte anında listelendiği doğrulanır.
- [x] Durum: Tamamlandı (22.09.2026 - Cihaz claim edildikten sonra hedef ev ve kanalların otomatik yüklenmesi `state.claimDevice` içine entegre edildi; `DashboardPage` üzerine şık `_buildWelcomeClaimCard` boş durum (Empty State) ve hızlı karekod eşleme butonları eklendi; kullanıcı cihaz üzerinde çalışmasını canlı doğruladı)
---
FAZ 9: Aile Bireyleri Paylaşımı ve Rol Kısıtlamaları (Multi-User)
Adım 9.1: Aile Davet Linki / QR Üretme
Ne Yapılıyor?: Ev sahibinin (Owner) Ayarlar menüsünden `"Aile Bireyi Ekle"` diyerek 24 saat geçerli bir katılım QR kodu veya davet kodu üretebilmesi.
Neden Yapılıyor?: Evdeki diğer bireylerin panoyu tekrar taramadan aynı eve kolayca dahil olabilmesi için.
Test/Doğrulama: Üretilen davet kodu başka bir hesapla okutulduğunda kullanıcının ilgili eve `MEMBER` rolüyle bağlandığı test edilir.
- [x] Durum: Tamamlandı (22.09.2026 - VPS Docker Postgres üzerinde `004_home_invitations_schema.sql` çalıştırıldı; `invitation_service.js` (Owner yetki kontrolü, 24 saatlik `AHBU-XXXXXX` kodu, join akışı) ve REST API uç noktaları (`POST /api/v1/homes/:id/invitations`, `POST /api/v1/homes/join`) yazılıp PM2'de canlı doğrulandı; Flutter tarafında `InviteFamilyDialog` ve `JoinHomeDialog` diyalogları ve `UserProfileDialog` entegrasyonu tamamlandı)
Adım 9.2: Arayüz Rol Kısıtlamaları (Role Guards)
Ne Yapılıyor?: `MEMBER` rolündeki kullanıcılar için Servis Menüsü, Panjur Süre Kalibrasyonu, Cihaz Silme ve Wi-Fi Ayarları butonlarının gizlenmesi veya kilitlenmesi.
Neden Yapılıyor?: Çocukların veya misafirlerin panjur motor sürelerini ve donanım ayarlarını bozmasını engellemek için.
Test/Doğrulama: Member rolüyle giriş yapıldığında servis butonlarının görünmediği; URL/kod üzerinden çağrılsa dahi yetki hatası verdiği teyit edilir.
- [x] Durum: Tamamlandı (22.09.2026 - `AutomationState` içine `isOwner`, `isMember` getter'ları tanımlandı; `DashboardPage` AppBar menüsünde `!state.isMember` kısıtlaması ile Servis Menüsü, Cihaz Eşleme ve Pano Ayarları butonları gizlendi; `DeviceSettingsPage` içerisinde member rolü için kilit uyarısı, salt okunur IP alanı ve devre dışı bırakılmış kaydetme butonu uygulandı; tüm 7 test takımında 29/29 test ve temiz analizle doğrulandı)
---
3. BAŞLANGIÇ PROTOKOLÜ (ANTIGRAVITY TALİMATI)
Bu dosyayı okuduğunda:
Rolünü, sıfır-güvenlik modelini ve eksiklerin kapsamını anladığını teyit et.
Doğrudan Faz 6 - Adım 6.1 (Envanter Veritabanı Şeması ve Migration) ile başlayalım.
Yapacağın işi ve SQL/Prisma şemasını açıkla; onayımı almadan kesinlikle migration çalıştırma veya kod üretme.




### TİCARİ AKILLI EV OTOMASYONU - GELİŞTİRME PLANI (FAZ 6: KULLANICI DÖNGÜSÜ & SIFIR-SERVİS MİMARİSİ)

Önceki aşamada altyapı, firmware çekirdeği ve temel arayüz adımlarını (1'den 9'a kadar) tamamladık. Şimdi sistemi ticari bir ürüne dönüştüren; **Kullanıcı Giriş/Yetki Yaşam Döngüsü**, **Daire Devir Mekanizması** ve **Teknik Servis Maliyetini Sıfırlayan Dayanıklılık Özelliklerini** hayata geçireceğiz.

Yine kıdemli IoT mimarı ve Flutter uzmanı rolünle; **katı adım adım ilerleme kuralına uyacak**, asla birden fazla adımı aynı anda kodlamayacak, her adımdan sonra test yönergesi verip benden onay bekleyeceksin.

İş paketlerimiz önceki adımların devamı olarak **10. Adımdan** itibaren şu şekildedir:

---

### ADIM 10: Kalıcı Kimlik Doğrulama & Oturum Yönetimi (Auth Lifecycle) [TAMAMLANDI & CANLIDA DOĞRULANDI]
- **Kapsam (Backend & Flutter):**
  - [x] E-posta/Telefon + Şifre ile Kayıt Ol (`POST /api/v1/auth/register`), Giriş Yap (`POST /api/v1/auth/login`) ve Şifremi Unuttum (OTP/Mail: `POST /api/v1/auth/forgot-password` & `POST /api/v1/auth/reset-password`) akışları uçtan uca kodlandı.
  - [x] `refresh_tokens` ve `password_reset_tokens` tabloları PostgreSQL'de oluşturuldu (Migration 005 canlı VPS'te uygulandı).
  - [x] JWT Access Token (15 dk) ve Refresh Token (1 yıl / 365 gün) mimarisi kuruldu. Sessiz oturum yenileme (`POST /api/v1/auth/refresh`) devrede.
  - [x] Flutter tarafında `SecureStorageService` ile Access ve Refresh Token güvenli olarak şifreli saklandı.
  - [x] `EvCloudApiService` içine 401 Unauthorized durumunda otomatik token tazeleyip isteği tekrarlayan sessiz kurtarma interceptor'ı (`_authenticatedRequest`) entegre edildi.
  - [x] `AutomationState` açılışında (`_init`) kayıtlı oturum refresh token ile otomatik doğrulanıyor; kullanıcı açıkça "Çıkış Yap" butonuna basana kadar uygulama doğrudan Dashboard'a girmektedir.
  - [x] Tüm birim ve widget testleri (31/31) ve `flutter analyze` (0 hata) başarıyla geçildi; canlı VPS PM2 `ev-api` servisi güncellendi.

---

### ADIM 11: Rol Ayrımı & Servis Teslimat Akışı (RBAC & Provisioning) [TAMAMLANDI & CANLIDA DOĞRULANDI]
- **Kapsam (Backend & Gömülü Web/Servis Menüsü):**
  - [x] **Backend RBAC Koruması:** `PUT /api/v1/homes/:home_id/endpoints/:id` rotasında Aile Admini (`owner`) veya Aile Üyesi (`member`) hesaplarının donanım klemens (`channel`) ve motor kalibrasyon sürelerini (`shutter_duration_sec`) değiştirmesi 403 Forbidden ile kesin olarak engellendi. Canlı sunucu testinde doğrulandı.
  - [x] **Commissioning (Devreye Alma):** `POST /api/homes/:home_id/commissioning` uç noktası kuruldu. Yalnızca yetkili servis teknisyeni (`installer`) sistemi test edip "Çalışır" (`APPROVED_WORKING`) olarak onaylayabilir. Devreye alma geçmişi `commissioning_logs` tablosuna kaydedilir.
  - [x] **Teknisyen Teslimat (Claiming):** `POST /api/v1/devices/claim` rotasına `targetOwnerIdentifier` (Müşteri E-Posta / Telefonu) eklendi. Teknisyen panoyu kurduğunda tek tıkla doğrudan ev sahibinin hesabına devredebilir.
  - [x] **Canlı VPS & Veritabanı:** PostgreSQL'e `006_rbac_and_commissioning.sql` uygulandı (`is_commissioned`, `commissioned_at`, `commissioned_by`, `commissioning_status`, `commissioning_logs`), PM2 `ev-api` güncellendi ve canlı doğrulandı.
  - [x] **Flutter Servis & UI:**
    - `dashboard_page.dart`: Servis menüsü butonu kesin RBAC ile yalnızca `state.isInstaller` iken gösterilmektedir.
    - `service_mode_page.dart`: Yetkisiz erişimde "🔒 Donanım & Motor Koruması Aktif" uyarısı; teknisyen oturumunda "Sistemi Devreye Alma (Commissioning)" onay kartı, "Yeni Pano Eşleme & Müşteriye Teslim (targetOwner)" kartı ve panjur kalibrasyon araçları eklendi.
    - `device_settings_page.dart`: Ev Sahibi için "Teknisyen İçin 2 Saatlik Servis PIN'i Üret" aracı ve donanım koruma bilgilendirme rozeti entegre edildi.
  - [x] Tüm birim & widget testleri (34/34) ve `flutter analyze` (0 hata) başarıyla tamamlandı.

---

### ADIM 12: Aile İçi Katılım & Dinamik QR / Misafir Yönetimi [TAMAMLANDI & CANLIDA DOĞRULANDI]
- **Kapsam (Flutter & Backend):**
  - [x] **Backend & Veritabanı (Migration 007):** `home_invitations` ve `home_users` tablolarına `guest_valid_from`, `guest_valid_until`, `guest_name`, `valid_from`, `valid_until` eklendi; `role CHECK` kısıtlamasına `guest` entegre edildi. Canlı VPS'e uygulandı.
  - [x] **Self-Revoking Guest Access (Otomatik Yetki Düşümü):** `auth_middleware.js` ve `endpoint_routes.js` içinde `role === 'guest'` olan kullanıcıların süre dolumu (`valid_until < NOW()`) veya başlamamış erişimi (`valid_from > NOW()`) tespit edildiğinde `403 Forbidden` (`GUEST_EXPIRED`) ile erişimleri anında otomatik olarak kesilmektedir.
  - [x] **Dinamik QR & Süreli Misafir Davet Motoru:** `POST /api/v1/homes/:id/invitations` rotası `role` ('member' | 'guest'), `durationHours`, `validFrom`, `validUntil`, `guestName` parametreleriyle donatıldı; `AHBU-INVITE:AHBU-GUEST-XXXXXX` payload'ı üretildi.
  - [x] **Ev Üyeleri & Misafir Yönetim API:** `GET /api/v1/homes/:id/members` ve `DELETE /api/v1/homes/:id/members/:userId` uç noktalarıyla Ev Sahibi'nin üyeleri ve misafirleri listeleyebilmesi ve tek tıkla yetki iptali yapabilmesi sağlandı.
  - [x] **Flutter Mobil Uygulaması:**
    - `qr_flutter: ^4.1.0` entegre edildi.
    - `InviteFamilyDialog`: Aile Bireyi (kalıcı 24 saat) ve Süreli Misafir / Temizlikçi Modu (2, 4, 8, 24 saat seçenekli) olmak üzere çift sekmeli dinamik QR kod üreteci.
    - `FamilyMembersPage`: Ev Sahibi için kayıtlı kişileri, rolleri, misafir kalan süre rozetini (`⏳ X saat kaldı`) ve yetki iptal butonunu sunan liste ekranı.
    - `DashboardPage` & `UserProfileDialog`: Üst barda QR tarama butonu ve Ev Sahibi için Aile & Misafir Yönetimi kısayolu. Kamera ile okutulan davet QR'ı (`AHBU-INVITE:...`) doğrudan `state.joinHome` çağırarak kullanıcıyı anında eve bağlar.
  - [x] Tüm birim ve widget testleri (37/37) ve `flutter analyze` (0 hata) başarıyla tamamlandı.

---

### ADIM 13: Daire Devri, Eski Ailenin Azli & Acil Sıfırlama
- **Kapsam (Backend Mimarisi):**
  - **Normal Devir:** Daire satıldığında/kiralandığında mevcut Aile Admini "Daireyi Devret" emri verir ve yeni kullanıcının hesabına davet gönderir. Yeni admin daveti onayladığı an:
    1. Eski ailenin tüm üyeleri (`home_members`) veritabanından kalıcı olarak silinir.
    2. Eski ailenin aktif tüm MQTTS ve API oturumları (Token/Socket) zorla sonlandırılır.
    3. Yeni kullanıcı tek yetkili `OWNER` olur ve kendi aile bireylerini davet eder.
  - **Ulaşılamayan Kiracı / Acil Servis Sıfırlaması:** Eski kiracı onay vermeden kaçtıysa veya telefonunu kaybettiyse; Servis Yetkilisi panonun fiziksel doğrulamasıyla tapu/kontrat teyidi sonrası cihazı tek tıkla boşa (`IN_STOCK`) çıkarıp yeni sahibine atayabilir.

---

### ADIM 14: Wi-Fi Şifre Değişimi Kurtarma Modu (Smart AP Fallback) [TAMAMLANDI & DOĞRULANDI]
- **Kapsam (ESP32-S3 Firmware & Flutter):**
  - **Neden?:** Evde modem/şifre değiştiğinde müşterinin servisi aramasını engellemek için.
  - **Mekanizma:** ESP32 kayıtlı Wi-Fi'a 3 dakika (180 sn) bağlanamazsa otomatik olarak acil kurtarma ağı açar: `AHBU-Kurtarma-[Device/MAC]`.
  - Flutter uygulaması yerel ağ koptuğunda "Pano internete bağlanamıyor, yeni şifreyi girmek için tıklayın" uyarısı verir. Telefon geçici ağa bağlanıp yeni Wi-Fi şifresini panoya aktarır ve normal moda döner.
- **Gerçekleştirilen Geliştirmeler:**
  - [x] **ESP32-S3 WiFiManager Smart Fallback:** `_disconnectedSince` sayacı ile 180 saniye kesintide `startRecoveryAP()` otomatik tetiklenir, `AHBU-Kurtarma-...` ağı açılır (`192.168.4.1`, Şifre: `ahbu1234`).
  - [x] **ESP32-S3 WebPortal Kurtarma API Entegrasyonu:** `/api/wifi/scan` ile çevredeki ağları tarama ve `/api/wifi/connect` ile yeni SSID ve şifreyi kalıcı NVS'e yazıp normal STA moduna otomatik dönme.
  - [x] **Flutter Kurtarma Sihirbazı (`WifiRecoveryDialog`):** Kullanıcı dostu adım adım rehber, tek tıkla pano bağlantı testi, çevredeki Wi-Fi ağlarını listeleme ve güvenli şifre yükleme.
  - [x] **Dashboard & Ayarlar Entegrasyonu:** Cihaz çevrimdışı kaldığında Dashboard'da otomatik beliren kurtarma kartı ve `DeviceSettingsPage` içine eklenen kurtarma aksiyonu.
  - [x] **Birim & Widget Testleri:** `test/wifi_recovery_mode_test.dart` ile diyalog, form doğrulama, buton etkileşimi ve taşmasız layout test edildi; 44/44 Flutter testi başarıyla geçti.

---

### ADIM 15: Panjur Over-Run (+2 sn) & Elektrik Kesintisi Güvenliği (Firmware Resilience) [TAMAMLANDI & DOĞRULANDI]
- **Kapsam (ESP32-S3 State Machine):**
  - **Over-Run / Self-Healing:** Panjur %0 (Tam Aç) veya %100 (Tam Kapat) komutu aldığında, sürtünme/toz gecikmelerini sıfırlamak için kalibre edilen süreye otomatik **+2 saniye ilave süre (`SHUTTER_OVERRUN_MS = 2000`)** eklenir. Mekanik limit anahtarı motoru durdurur, kalibrasyon ömür boyu bozulmaz.
  - **Power-On State:** Gece elektrik kesilip geri geldiğinde (Power Restore), lambaların varsayılan durumu **KESİNLİKLE KAPALI (OFF)** kalır; panjurlar hareket etmez.
- **Gerçekleştirilen Geliştirmeler:**
  - [x] **Firmware SHUTTER_OVERRUN_MS Sabiti:** `SmartAutomation.h` içerisine 2000 ms over-run sabiti eklendi.
  - [x] **Tam Açılış & Kapanış Over-Run Mantığı:** `shutterUp()`, `shutterDown()`, `setShutterPosition(%100)` ve `setShutterPosition(%0)` durumlarında nominal motor süresine otomatik +2000 ms eklenerek mekanik limit switch oturması ve pozisyon kalibrasyonunun sıfırlanması sağlandı.
  - [x] **Pozisyon Self-Healing & Sıkışma Koruması:** `shutterStop()` içerisinde nominal süre dolduğunda pozisyon kesin 100 veya 0 olarak NVS'e kaydedildi; ara duruşlarda ise anlık oransal hesap korundu.
  - [x] **Power-On Restore Emniyeti:** `SmartAutomation::begin()` fonksiyonunda elektrik kesintisi dönüşünde tüm yerel ve harici RS485 rölelerin KESİNLİKLE KAPALI (OFF) başlatılması, panjurların hareketsiz kalması donanımsal ve yazılımsal olarak garanti altına alındı.
  - [x] **Flutter Arayüz & Test Doğrulaması:** `ShutterCard` ve `DeviceSettingsPage` bileşenlerinde donanım koruması ve limit oturması net olarak görselleştirildi; `test/shutter_resilience_and_power_restore_test.dart` ile 47/47 Flutter birim testi başarıyla geçirildi.

---

### ADIM 16: Sistem Doktoru & Buluttan Tek Tıkla Pano Değişimi [TAMAMLANDI & DOĞRULANDI]
- **Kapsam (Flutter & Backend):**
  - **Sistem Doktoru (Self-Diagnostic):** Kullanıcı "Uygulama çalışmıyor" dediğinde Ayarlar menüsünden tek tıkla test çalıştırır: `[Bulut: OK]`, `[Ev Modemi/İnternet: HATA]`, `[Pano Gücü: OK]`. Müşteri sorunun kendi internetinde olduğunu görür.
  - **Felaket Kurtarma (Disaster Recovery):** Pano yıldırım vb. ile yanarsa, yeni takılan boş karta backend'den tek tıkla eski dairenin tüm konfigürasyonu (oda isimleri, panjur süreleri, Modbus ayarları) 5 saniyede yüklenir.

---

### ADIM 17: Kullanıcı Konforu: Gece Bildirimi & Yazılımsal Çocuk Kilidi
- **Kapsam (Flutter & Backend & Firmware):**
  - **Huzur Bildirimi:** Her gece 23:30'da (veya evden uzaklaşıldığında) açık lamba/panjur varsa tek bildirim: *"Salonda 2 lamba açık. [Hepsini Kapat]"*. Dashboard üzerinde açık lamba uyarısı ve tek tıkla toplu kapatma butonu.
  - **Çocuk Kilidi:** Uygulamadan tek tıkla açılır; duvardaki fiziksel yaylı anahtarlar (DI girişleri) donanım ve NVS seviyesinde kilitlenir, lambalar/panjurlar sadece telefondan veya MQTT'den kontrol edilebilir.
- **Test/Doğrulama:**
  - Backend: PostgreSQL 010 migrasyonu canlı VPS'e uygulandı (`homes.child_lock_enabled`, `homes.peace_notification_enabled`, `peace_notification_logs`). `POST/GET /api/devices/child-lock`, `GET/PUT /api/devices/peace-notification/:home_id` ve `POST /api/devices/peace-notification/close-all` rotaları canlı PM2 (`ev-api`) üzerinde doğrulandı.
  - Firmware: `SmartAutomation` sınıfında NVS kalıcı `child_lock`, `checkDigitalInputs()` içinde fiziksel buton kilitleme, WebPortal REST ve MQTTS (`set_child_lock`) çift yönlü komut desteği eklendi.
  - Flutter & UI: `DeviceSettingsPage` çocuk kilidi ve gece huzur saati ayar kartları, `DashboardPage` durum hapı ve Huzur Bannerı eklendi.
  - Otomasyon Testleri: `test/child_lock_and_night_notification_test.dart` (6 test) ve tüm Flutter test suite'i (57/57 test) sıfır hata ve sıfır taşma ile yeşile alındı.
- [x] Durum: Tamamlandı (23.09.2026 - Uçtan Uca Doğrulandı)

---

### ADIM 17.1: Zamanlı Otomasyon Kuralları (Scheduled Rules) & Squircle Kurumsal Logo
- **Kapsam:**
  - **Kurumsal Logo:** 1024x1024 PNG için iOS app icon standardında (%22 radius) anti-aliased squircle maskesi uygulandı; `auth_gate.dart` ve `login_page.dart` içinde tam dolgu ve modern parıltı (glow) efektiyle köşeli/metalik çerçeve sorunu giderildi.
  - **Veritabanı (PostgreSQL):** `011_scheduled_rules.sql` ve `run_011.js` ile UUID uyumlu `scheduled_rules` tablosu oluşturuldu; `homes`, `devices` ve `users` tablolarına cascade/set-null foreign key ilişkileri ve performans indexleri eklendi.
  - **Backend (Node.js & Express):** `scheduled_rules_service.js` ve `scheduled_rules_routes.js` oluşturuldu (`GET`, `POST`, `PUT`, `DELETE /api/homes/:homeId/scheduled-rules`). Yetki kontrolleri `home_users` üzerinden `owner/admin` seviyesinde doğrulandı.
  - **Zamanlayıcı Motor (node-cron):** `server.js` içine entegre edilen cron job ile her dakika tetiklenmesi gereken kurallar (`getRulesDueNow`) çekilerek `mqtt_bridge.js` üzerinden ilgili cihaz/ev topic'ine (`ev/{mqtt_username}/cmd`) otomatik MQTT komutu yayınlandı.
  - **Mobil Arayüz (Flutter):** `ScheduledRule` modeli (`scheduled_rule_model.dart`), `ScheduledRulesPage` (kanal bazlı liste, gün seçici, time picker, anlık switch açma/kapama, düzenle/sil diyalogları), `DeviceSettingsPage` özet geçiş kartı kodlandı.
  - **Doğrulama & Testler:** `test/scheduled_rules_test.dart` ile model serileştirme ve responsive widget testleri yazıldı; `flutter analyze` 0 hata/uyarı, tüm test suite (66/66 test) %100 başarıyla geçti. Canlı VPS'e (178.210.161.55 / PM2 `ev-api`) dağıtıldı ve `/health` ile teyit edildi.
- [x] Durum: Tamamlandı (23.09.2026 - Canlı VPS ve Flutter Uçtan Uca Doğrulandı)

---

### ÇALIŞMA PROTOKOLÜ VE BAŞLANGIÇ:
1. Bu planı ve mimari kuralları anladığını kısaca teyit et.
2. Doğrudan **ADIM 10 (Kalıcı Kimlik Doğrulama & Oturum Yönetimi)** ile başlayalım.
3. Adım 10 için yapacağın işi (Backend endpoint'leri ve Flutter auth state yapısını) 2-3 cümleyle açıkla.
4. **Benden onay gelmeden KESİNLİKLE kod yazmaya başlama.**


---



Projeye ait `PROJECT_TASKS.md` dosyamızda Adım 17'ye kadar olan tüm iş paketleri tanımlandı. Şimdi kullanıcının ilk onboarding deneyimini, şifresiz konforunu ve biyometrik güvenliğini sağlayacak olan **ADIM 18** ile geliştirmeye devam ediyoruz.

Ticari bir IoT ürünü geliştiren Kıdemli Sistem Mimarı ve Flutter Uzmanı rolünle çalışacaksın.

### ÇALIŞMA KURALLARIN:
1. **Adım Adım İlerleme:** Yalnızca **ADIM 18 (Google, Apple Sign-In ve Telefon OTP Entegrasyonu)** üzerinde çalışacaksın.
2. **Kütüphane ve Mimari Kısıtlar:**
   - Flutter tarafında `google_sign_in` ve `sign_in_with_apple` kullanılacak.
   - Backend tarafında istemciden gelen token'lar kriptografik olarak doğrulanacak (`/api/v1/auth/google`, `/api/v1/auth/apple`).
   - Kullanıcı ilk kez geliyorsa arka planda hesabı otomatik açılacak, ek form doldurtulmayacak.
3. **Kalıcı Oturum:** Dönen JWT Access ve Refresh token'lar güvenli şekilde saklanmaya hazır olacak.
4. **DUR VE BEKLE:** Kod bloklarını yazmadan önce:
   - Flutter ve Backend tarafında atacağın ilk adımı 2-3 cümleyle açıkla.
   - Benden açık onay gelmeden KESİNLİKLE dosya oluşturma veya kod yazma.

### ADIM 18: Sıfır-Sürtünmeli Sosyal & Şifresiz Giriş (Google, Apple & Telefon OTP)
- **Kapsam (Flutter & Backend):**
  - **Google Sign-In (`google_sign_in`):** Tek dokunuşla Google hesabı seçilir. Alınan `idToken` backend'e (`POST /api/v1/auth/google`) gönderilir. Backend kriptografik doğrulamayı yapar; ad, soyad ve e-postayı otomatik alarak kullanıcıyı form doldurtmadan sisteme kaydeder/oturum açar.
  - **Sign in with Apple (`sign_in_with_apple`):** App Store kurallarına (Guideline 4.8) tam uyumlu Face ID/Touch ID destekli tek tıkla giriş. Kullanıcı "E-postamı Gizle" seçse dahi sistem sorunsuz çalışır.
  - **Telefon Numarası ile Şifresiz Giriş (Saha Dostu):** Daire devirlerinde ve yaşlı kullanıcılarda şifre stresini bitiren SMS/WhatsApp üzerinden 6 haneli OTP doğrulaması.
  - **Klasik E-posta / Şifre:** Sosyal hesap kullanmak istemeyenler için alternatif sade giriş.
- **Doğrulama / Test:** Hem Android hem iOS tarafında Google ve Apple butonlarına basıldığında backend'in geçerli JWT Access + Refresh token ürettiği ve kullanıcıyı beklemeden ana ekrana taşıdığı doğrulanır.
- [x] Durum: Tamamlandı (23.09.2026 - Canlı VPS ve Flutter Uçtan Uca Doğrulandı)
  - PostgreSQL 012 migrasyonu (`google_id`, `apple_id`, `phone_otp_codes` tablosu ve indexleri) canlıya uygulandı.
  - Backend API (`POST /api/v1/auth/google`, `POST /api/v1/auth/apple`, `POST /api/v1/auth/otp/send`, `POST /api/v1/auth/otp/verify`) canlı ortamda test edildi ve doğrulandı.
  - Flutter tarafında `google_sign_in`, `sign_in_with_apple` ve şık `PhoneOtpDialog` bileşeni eklendi; `LoginPage` üzerinden tek tıkla sosyal/şifresiz giriş sağlandı.
  - `test/social_and_otp_auth_test.dart` dahil 69/69 test %100 başarıyla geçti; `flutter analyze` 0 hata/uyarı.

---

### ADIM 19: Biyometrik Güvenlik & Anlık Giriş Deneyimi (`local_auth`)
- **Kapsam (Flutter):**
  - **İlk Kurulum Onayı:** İlk başarılı girişin hemen ardından kullanıcıyı yormayan tek seferlik şık bir diyaloğun çıkması:  
    > *"Sonraki girişlerinizde Face ID / Parmak İzi kullanılsın mı? [Evet, Etkinleştir]"*
  - **Donanımsal Kasa (`flutter_secure_storage`):** Kullanıcı onay verdiğinde JWT token'ları cihazın güvenli donanım alanında (Android Keystore / iOS Keychain) biyometrik kilit altına alınır.
  - **200 ms İçinde Açılış:** Uygulama sonraki açılışlarda doğrudan Face ID / Parmak İzi sensörünü tetikler. Kullanıcı ekrana dokunmadan veya tek parmak dokunuşuyla 200 ms içinde doğrudan ana ekrana ulaşır.
  - **Sessiz Otomatik Giriş (Fallback):** Biyometrik donanımı olmayan veya izin vermeyen cihazlarda kalıcı token üzerinden şifre sormadan otomatik giriş yapılır.
- **Doğrulama / Test:** Uygulama arka plandan tamamen kapatılıp yeniden açılır; sistemin biyometrik doğrulama istediği ve onay sonrası şifre sormadan ana ekranı açtığı görülür.
- [x] Durum: Tamamlandı (23.09.2026 - Uçtan Uca Doğrulandı)
  - `pubspec.yaml`'a `local_auth: ^2.3.0` eklendi; `SecureStorageService` içine biyometrik kilit durumları eklendi.
  - `BiometricAuthService` (`isBiometricSupported`, `authenticate`, `getBiometricLabel`) ve `AutomationState` içine anlık giriş/fallback yönetimi yazıldı.
  - İlk girişte şık `BiometricPromptDialog` onay modalı bağlandı.
  - `AuthGate` içerisine biyometrik açılış splash'i, başarısız durumda "Tekrar Dene" ve "Şifre ile Giriş Yap" butonları eklendi.
  - `DeviceSettingsPage` içerisine dinamik etiketli (Face ID / Parmak İzi) biyometrik açma/kapama switch kartı entegre edildi.
  - `test/biometric_auth_test.dart` dahil 73/73 test başarıyla geçti, `flutter analyze` 0 hata/0 uyarı ile temizlendi.

---

### ADIM 20: Sürtünmesiz Şifre Yenileme & Sıfır-Stres Hesap Kurtarma
- **Kapsam (Backend & Flutter):**
  - **Sihirli Bağlantı (Magic Link) / Hızlı OTP:** Kullanıcı şifresini unuttuğunda eski şifresini veya karmaşık güvenlik sorularını hatırlamak zorunda kalmaz.
  - E-posta veya telefonuna anında 6 haneli tek kullanımlık geçici kurtarma kodu veya doğrudan oturum açan güvenli bağlantı iletilir.
  - Kod doğrulandığı an kullanıcı doğrudan yeni şifresini belirler veya şifresiz yeni oturumuna başlar.
  - **Güvenlik Tedbiri:** Şifre yenilendiği anda o hesaba ait diğer tüm cihazlardaki eski aktif oturumlar soket seviyesinde zorla sonlandırılır.
- **Doğrulama / Test:** "Şifremi Unuttum" ekranından tek kullanımlık kod talep edilir; gelen kod girildiğinde şifrenin saniyeler içinde yenilendiği ve yeni token üretildiği test edilir.
- [x] Durum: Tamamlandı (23.09.2026 - Canlı VPS ve Flutter Uçtan Uca Doğrulandı)
  - PostgreSQL 013 migrasyonu (`password_resets` tablosu, `users.token_version` kolonu ve indexleri) canlıya uygulandı.
  - Backend API (`POST /api/v1/auth/forgot-password`, `POST /api/v1/auth/reset-password`, `GET /api/v1/auth/magic-login/:token`) canlı sunucuda (`178.210.161.55` / PM2 `ev-api`) doğrulandı.
  - Şifre yenilendiğinde `users.token_version` artırılarak ve `refresh_tokens` tablosu temizlenerek diğer tüm cihazlardaki oturumların anında düşürülmesi sağlandı.
  - Flutter tarafında `ForgotPasswordDialog` (2 adımlı sıfır-taşma garantili modal, 6 haneli kod, yeni şifre ve geri sayım sayacı) ve `LoginPage` bağlantısı entegre edildi.
  - `test/password_reset_and_recovery_test.dart` dahil 76/76 test %100 başarıyla geçti; `dart analyze lib test` 0 hata / 0 uyarı ile tamamlandı.

---

### ADIM 21: Açılış Deneyimi, Dairesel Neon AI Logo & Siber Devre Tasarımı
- **Kapsam (Flutter & Android OS):**
  - **Elektronik & Yapay Zeka Arka Planı:** Yüksek çözünürlüklü fütüristik siber devre ve nöral ağ arka planı (`assets/images/ai_circuit_bg.jpg`) oluşturuldu ve `_AuthSplashScreen` ile `LoginPage`'e siber gradyan karartma ile entegre edildi.
  - **Dairesel Neon Logo (Köşesiz Tasarım):** Eski squircle yapı kaldırıldı; akıllı ev IoT ve siber devre halkalı dairesel logo (`round_app_logo.png`) oluşturuldu, `ClipOval` ve çift katmanlı neon cyan/mavi parıltı (`#38BDF8`) ile donatıldı.
  - **Android Sistem Splash (Launch Screen) Düzeltmesi:** Android OS başlatma aşamasındaki beyaz zemin sorunu giderildi; `values-v31/styles.xml`, `colors.xml` ve `launch_background.xml` üzerinden `#0B1120` koyu zemin ve dairesel splash ikonu tanımlandı. Tüm mipmap launcher ikonları güncellendi.
  - **Doğrulama & Testler:** `test/splash_and_logo_design_test.dart` eklendi; 78/78 test %100 başarıyla geçti; `dart analyze lib test` 0 issue.
- [x] Durum: Tamamlandı (23.09.2026 - Uçtan Uca Doğrulandı)