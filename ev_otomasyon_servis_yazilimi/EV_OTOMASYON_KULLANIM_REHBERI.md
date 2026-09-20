# EV VE BİNA OTOMASYONU KULLANIM REHBERİ
## Waveshare ESP32-S3-ETH-8DI-8RO Endüstriyel Pano Kontrol Modülü

Bu rehber, **Waveshare ESP32-S3-ETH-8DI-8RO** endüstriyel röle ve giriş modülünün ev, bina ve site kapı otomasyonu sistemlerinde kurulumu, erişimi, firmware yükleme süreçleri, donanım mimarisi ve AHBU sistemiyle entegrasyonuna dair tüm teknik detayları içerir.

---

## 1. Donanıma Genel Bakış ve Özellikler

Waveshare ESP32-S3-ETH-8DI-8RO; prototip kartların aksine pano montajına uygun (DIN-Rail ray tipi), endüstriyel koruma devrelerine sahip profesyonel bir otomasyon kartıdır.

* **İşlemci:** ESP32-S3 (Xtensa® 32-bit LX7 çift çekirdek, 240 MHz, 2.4 GHz Wi-Fi + BLE 5)
* **Kablolu Ağ:** W5500 SPI 10/100M Ethernet (RJ45 konnektör)
* **Röle Çıkışları (8RO):** 8 adet yüksek kaliteli mekanik röle (10A 250V AC / 10A 30V DC), optokuplör izolasyonlu
* **Dijital Girişler (8DI):** 8 adet opto-izole dijital giriş (kuru kontak butonlar, manyetik sensörler, loop dedektörleri vb.)
* **Haberleşme Portları:** RS485 (İzole, Modbus RTU uyumlu), USB Type-C, Bluetooth LE
* **Besleme:** 7~36V DC geniş endüstriyel voltaj aralığı (klemens) veya 5V/1A USB Type-C
* **Yardımcı Donanımlar:** 
  - Dahili Buzzer (Sesli uyarı)
  - WS2812 RGB Durum LED'i
  - PCF85063 Gerçek Zamanlı Saat (RTC - Pil yuvası ile internet/elektrik kesilse de saati korur)
  - MicroSD (TF Card) yuvası
* **Kasa:** Standart elektrik panosu rayına oturan ABS koruma kutusu (DIN-Rail)

---

## 2. Kullanım Alanları ve Otomasyon Senaryoları (Henüz Kesinleşmemiştir - Taslak)

> [!NOTE]
> **Önemli Not:** Aşağıda listelenen kullanım senaryoları donanımın teknik yeteneklerini ve potansiyelini gösteren **taslak senaryolardır; şu an için kesinleşmiş bir kullanım alanı kararı yoktur.** Cihaz sahada hangi amaç veya ihtiyaç için değerlendirilmek istenirse o senaryo üzerinden ilerlenecektir (kafa karışıklığı oluşmaması için kesinleşmiş bir uygulama olarak düşünülmemelidir).

### A. Kablolu Ethernet (RJ45) ile Kesintisiz İletişim
Site ve bina elektrik panolarının içi metal zırh görevi görerek Wi-Fi sinyallerini engeller. Cihaz, doğrudan Ethernet kablosu ile switch/modeme bağlanarak 7/24 sıfır paket kaybı ve sıfır gecikmeyle çalışır.

### B. Çoklu Kapı & Bariyer Yönetimi (8 Röle)
Tek bir pano modülü ile sitenin 8 farklı geçiş noktası bağımsız olarak yönetilebilir:
1. Giriş Araç Bariyeri
2. Çıkış Araç Bariyeri
3. Blok Giriş Yaya Kapısı (Manyetik Kilit)
4. Kapalı Otopark Otomatik Kepengi
5. Yangın / Acil Çıkış Kapısı
6. Havuz / Sosyal Tesis Turnikesi
7. Çöp Alanı / Depo Kapısı
8. Yedek / Genel Aydınlatma Kontrolü

### C. Kapı Durumunu Algılama & Sensör/Buton Geri Bildirimi (8DI)
* **Manyetik Kapı Sensörü (Reed Kontak):** Kapının fiilen açık, kapalı veya zorlanmış (açık unutulmuş) olduğunu anlık algılar.
* **Fiziksel Çıkış Butonu / Güvenlik Butonu:** Güvenlik kulübesi butonuna basıldığında röleyi tetikler ve sunucuya "Güvenlik butonuyla açıldı" kaydı düşer.
* **Araç Manyetik Loop Dedektörü:** Araç yanaştığında tetik alır.
* **Yangın Santrali Entegrasyonu:** Yangın alarmı kontağı geldiğinde 8 kapıyı acil tahliye için serbest bırakır.

### D. Asansör Kat Yetkilendirme
8 röle, bir asansörün 8 farklı kat çağrı butonunu kilitleyip açmak için doğrudan kullanılabilir (Yetkisi olan daire sakini sadece kendi katına çıkabilir).

### E. RS485 ile Uzun Mesafe GM60 / Kart Okuyucu Hattı
Dış ortamdaki turnikeye veya araç bariyeri giriş direğine yerleştirilen **GM60 QR Okuyucu** veya Wiegand-RS485 tuş takımları, parazitsiz RS485 diferansiyel hattı üzerinden yüzlerce metre mesafeden ana panodaki bu cihaza bağlanabilir.

---

## 3. Cihaz Arayüzlerine Erişim (Web, BLE, MQTT)

### A. Web Sayfası ile Erişim (Dahili Web Server)
Cihazın içerisinde gömülü bir web sunucusu bulunur.

* **Wi-Fi AP Modu ile Erişim:**  
  Cihaz ilk açıldığında doğrudan bir Wi-Fi erişim noktası (Access Point) yayar:
  - **Wi-Fi Adı (SSID):** `ESP32-S3-POE-ETH-8DI-8RO`
  - **Wi-Fi Şifresi:** `waveshare` *(veya bazı test sürümlerinde `waveshare0755`)*
  - **Web Arayüzü Adresi:** Tarayıcıya **`http://192.168.4.1`** yazılarak doğrudan röle kontrol arayüzüne girilir.
* **Kablolu Ethernet ile Erişim:**  
  RJ45 kablosu takıldığında modemden otomatik DHCP IP alır (Örn: `192.168.1.150`). Aynı yerel ağdaki herhangi bir cihazın tarayıcısına bu IP yazıldığında 8 rölenin butonları açılır.

### B. Bluetooth (BLE) Arayüzü
Telefona **nRF Connect** veya **Serial Bluetooth Terminal** yüklenerek cihaza kablosuz bağlanılabilir; röle durumları hex/metin komutlarla (`0x06 0x01` vb.) değiştirilebilir.

### C. Son Kullanıcı Arayüzü mü, Servis Arayüzü mü?
* **Dahili Fabrika Arayüzü:** Yalnızca **teknik/servis ve test arayüzüdür**. Elektrikçi veya teknisyenin rölelerin ve girişlerin çalıştığını teyit etmesi için basit bir HTML sayfasıdır; şifreli kullanıcı rolleri veya modern tasarımlar içermez.
* **Son Kullanıcı Arayüzü (AHBU):** Daire sakinlerinin ve site yöneticilerinin kullanacağı arayüz **AHBU Mobil ve Web Paneli** olacaktır. Kullanıcı cep telefonundan kapıyı aç butonuna bastığında sunucumuz MQTT protokolü üzerinden bu cihaza emir iletir ve röleyi 1 saniyede çektirir.

---

## 4. İlk Firmware Yükleme ve Programlama

* **Bağlantı Şekli:** Cihaz üzerinde yer alan **USB Type-C** portu hem 5V enerji sağlar hem de ESP32-S3'ün doğrudan USB CDC/JTAG indirme portudur.
* **COM Port Tanıma:** Type-C kablosuyla bilgisayara bağlandığı anda sürücü gerektirmeden COM port olarak listelenir.
* **Bootloader Modu (Gerekirse):** Cihaz yanıt vermezse üzerindeki `BOOT` butonuna basılı tutulur, `RESET` butonuna bir kez basılıp bırakılır ve ardından `BOOT` bırakılır.

### Grafiksel Yükleme Aracı (Tek Tıkla Yükleme):
Proje dizinindeki **`ev_otomasyon_sistemi.bat`** dosyasına çift tıklayarak grafiksel arayüzü açabilirsiniz.

* **🚀 Bizim Geliştirdiğimiz Yazılım (Varsayılan):**  
  Arayüz açıldığında doğrudan bizim geliştirdiğimiz firmware (`firmware_releases/vX.X.X/`) otomatik olarak seçili gelir. Arayüzdeki **"➕ Versiyon Arttır"** butonuna basıldığında sürüm numarası (örn: v1.0.0 -> v1.0.1) otomatik artırılır ve yeni sürüm klasörü oluşturulur.
* **🛡️ Fabrika Çıkış Orijinal Yazılımı (Test Modu):**  
  Bu seçenek tıklandığında Waveshare'in orijinal test firmware'i (`waveshare_s3_demo/Firmware/ESP32-S3-POE-ETH-8DI-8RO.bin`) otomatik seçilir. Orijinal fabrika yazılımı hiçbir zaman değiştirilmez veya bozulmaz.

### Komut Satırından Hızlı Yükleme:
```bash
python -m esptool --chip esp32s3 --port COM_PORTUNUZ write_flash 0x0 waveshare_s3_demo/Firmware/ESP32-S3-POE-ETH-8DI-8RO.bin
```

---

## 5. Donanım Pin Haritası

| Donanım Bileşeni | Kontrol Pini / Çip | İşlevi |
| :--- | :--- | :--- |
| **8 Adet Röle (RO)** | **TCA9554PWR** (I2C Adresi) | I2C üzerinden `EXIO1 ~ EXIO8` ile 8 röleyi sürer. |
| **Kablolu Ethernet** | **W5500 SPI** | `CS: 16`, `SCLK: 15`, `MOSI: 13`, `MISO: 14`, `INT: 12` |
| **8 Dijital Giriş (DI)** | **GPIO4 ~ GPIO11** | `DI1: 4`, `DI2: 5`, `DI3: 6`, `DI4: 7`, `DI5: 8`, `DI6: 9`, `DI7: 10`, `DI8: 11` |
| **RS485 Portu** | **GPIO17 (TX), GPIO18 (RX)** | Harici okuyucular/PLC ile seri haberleşme. |
| **Buzzer** | **GPIO46** | Sesli bildirim ve alarm. |
| **RGB LED** | **GPIO38** | WS2812 Neopixel durum ışığı. |
| **RTC Saat Çipi** | **PCF85063** (I2C) | `SCL: 41`, `SDA: 42`, Kesme: `GPIO40` |
| **BOOT Butonu** | **GPIO0** | İndirme / kurtarma butonu. |

---

## 6. Proje Klasör Rehberi (`waveshare_s3_demo/`)

Proje alanımızda oluşturulan izole geliştirme klasöründeki modüller:

* **`main.cpp` (veya `MAIN_ALL.ino`):** Ana başlatıcı (`setup` ve `loop`). Tüm donanımları ayağa kaldırır.
* **`WS_Relay.cpp / .h`:** 8 rölenin mantıksal fonksiyonları (`Relay_ON`, `Relay_OFF`, `Relay_Toggle`, `ALL_ON`, `ALL_OFF`).
* **`WS_TCA9554PWR.cpp / .h`:** I2C I/O expander sürücüsü; röle bobinlerini fiziksel olarak tetikler.
* **`WS_DIN.cpp / .h`:** 8 opto-izole girişi dinleyen ve buton tetiklerini yöneten kodlar.
* **`WS_ETH.cpp / .h`:** W5500 SPI Ethernet sürücüsü ve IP alma mantığı.
* **`WS_WIFI.cpp / .h`:** Wi-Fi AP/STA modları ve gömülü HTML Web Kontrol Sunucusu.
* **`WS_MQTT.cpp / .h`:** Bulut/sunucu MQTT mesaj dinleme ve yayınlama katmanı.
* **`WS_Bluetooth.cpp / .h`:** Telefonla doğrudan kontrol için BLE sunucu yazılımı.
* **`WS_RS485.cpp / .h` & `WS_Serial.cpp / .h`:** Turnike/GM60 için RS485 seri iletişim katmanı.
* **`WS_PCF85063.cpp / .h` & `WS_RTC.cpp / .h`:** Pil destekli donanımsal gerçek zaman saati sürücüsü.
* **`WS_GPIO.cpp / .h`:** RGB LED (GPIO38) ve Buzzer (GPIO46) efektleri.
* **`WS_SD.cpp / .h`:** TF/MicroSD kart dosya kayıt sistemi.
* **`I2C_Driver.cpp / .h`:** TCA9554 ve RTC için ortak I2C veri yolu sürücüsü.
* **`WS_Information.h`:** Cihazın genel bayrakları ve modül açma/kapama tanımlamaları.
* **`ConfigManager.cpp / .h`:** Kalıcı NVS (Non-Volatile Storage) ayar yöneticisi. Cihaz adı, Wi-Fi parametreleri, RS485 baud hızı, kanal isimleri ve panjur süreleri saklanır.
* **`SmartAutomation.cpp / .h`:** Panjur karşılıklı kilitleme (interlock), motor emniyet gecikmesi (150 ms), süre sayacı otomatik kesme, darbe rölesi ve RS485 canlı tampon yöneticisi.
* **`WebPortal.cpp / .h`:** Modern, karanlık temalı, mobil uyumlu gömülü Web Portalı ve REST API uç noktaları.

---

## 7. Gelişmiş Web Portalı Kullanımı (v1.0.0 Firmware)

Cihazın fabrika arayüzü yerine geliştirdiğimiz modern web portalı, daire otomasyonu için özel olarak tasarlanmıştır.

### Portala Giriş:
1. Bilgisayarınızdan veya cep telefonunuzdan cihazın yaydığı Wi-Fi ağına bağlanın:
   - **SSID:** `ESP32-S3-POE-ETH-8DI-8RO`
   - **Şifre:** `waveshare`
2. Tarayıcınızda (Chrome, Safari vb.) **`http://192.168.4.1`** adresini açın.

### Portal Sekmeleri ve Yetenekleri:
1. **🎛️ Kontrol Sekmesi:**
   - 8 Rölenin anlık durumunu (AÇIK / KAPALI), atanan özel isimlerini ve yük tipini gösterir.
   - Her röle tek tıkla açılıp kapatılabilir.
   - "Tümünü Aç" ve "Tümünü Kapat" butonları ile toplu işlem yapılabilir.
   - Sayfanın sağ tarafında 8 Dijital Girişin (DI1 ~ DI8) anlık elektriksel durumu yeşil/kırmızı canlı rozetlerle izlenir.
2. **⚙️ Kanal Ayarları Sekmesi:**
   - **Röle Yapılandırması:** Her röleye özel isim (örn: *Salon Panjuru Yukarı*, *Mutfak Spot Lambası*, *Balkon Işığı*) verilebilir.
   - **Yük Tipi Seçimi:**
     - *Normal Anahtar / Aydınlatma*
     - *Panjur Aç / Yukarı (Kanal 1-2, 3-4, 5-6, 7-8)*
     - *Panjur Kapat / Aşağı (Kanal 1-2, 3-4, 5-6, 7-8)*
     - *Darbe / Tetik Rölesi (Örn: Kapı otomatiği için 1 saniyelik impuls)*
   - **Çalışma Süresi (Sn):** Panjurlar için motor çalışma süresi (örn: 20 saniye). Süre bitiminde motor rölesi otomatik kapanır.
   - **Fiziksel Giriş (8DI) Eşleşmesi:** Her bir duvardaki butonun hangi röleyi tetikleyeceği ve çalışma modu (Toggle / Direkt Takip / Darbe) seçilebilir.
   - Ayarlar "💾 Ayarları Kaydet" butonuna basıldığında NVS belleğe kalıcı yazılır.
3. **📶 Wi-Fi & Ağ Sekmesi:**
   - **Canlı Ağ Tarama:** "🔍 Ağları Tara" butonuyla etraftaki 2.4 GHz kablosuz ağlar sinyal kaliteleriyle birlikte taranıp listelenir.
   - **Ev Modemi Eşleştirme:** Evin Wi-Fi adı (SSID) seçilip şifresi girilerek "Kaydet ve Bağlan" denildiğinde cihaz ev modemine bağlanır.
   - Cihaz ev modemine bağlandıktan sonra, modemin atadığı yerel IP adresi üzerinden de (örn: `http://192.168.1.105`) web portalına kesintisiz erişilebilir.
4. **📟 RS485 Terminal Sekmesi:**
   - RS485 portu üzerinden bağlı olan harici sensörler, enerji sayaçları veya GM60 okuyucular ile canlı iletişim sağlar.
   - Baud Rate seçimi (9600, 19200, 115200 vb.).
   - Hem **ASCII** metin hem de **HEX formatında (örn: `01 03 00 00 00 02 C4 0B`)** veri paketleri gönderilebilir.
   - Canlı terminal konsolunda gönderilen (TX) ve alınan (RX) paketler anlık zaman damgasıyla listelenir.
5. **🛠️ Sistem Sekmesi:**
   - Bellek (Heap RAM), Uptime süresi, Firmware sürümü ve IP bilgileri görüntülenir.
   - "Yeniden Başlat" ve "Fabrika Ayarlarına Sıfırla" fonksiyonları tek tıkla çalıştırılabilir.

---

## 8. Daire İçi Panjur & Aydınlatma Tesisat Rehberi

### A. Panjur Motoru Güvenlik Kilidi (Interlock):
* Standart panjur tüp motorlarında 4 kablo bulunur: Nötr (Mavi), Toprak (Sarı-Yeşil), Yukarı Fazı (Kahverengi), Aşağı Fazı (Siyah).
* **Tehlike:** Yukarı ve Aşağı fazlarının aynı anda motora verilmesi motor bobinlerini yakar veya şalter attırır.
* **Firmware Güvenliği:** 
  - Yazılımımızda Kanal 1-2, 3-4, 5-6 ve 7-8 panjur çifti olarak tanımlandığında, yazılımsal karşılıklı kilitleme (*mutual exclusion*) devreye girer.
  - Yukarı çalışırken Aşağı komutu gelirse, önce Yukarı rölesi kapatılır, **150 milisaniye beklenir** ve ardından Aşağı rölesi çektirilir. Asla iki röle aynı anda çekili kalamaz.
  - Belirlenen süre (örn: 20 saniye) sonunda röle otomatik kapanır; motor şalteri sürekli gerilim altında kalmaz.

### B. Fiziksel Kuru Kontak Buton (8DI) Bağlantı Kuralı:
* **ÖNEMLİ KURAL:** Cihaz üzerindeki röle klemenslerinde bulunan `COM` terminalleri şebeke fazını röleye girmek içindir.
* Duvardaki yaylı anahtarlar (light butonlar) veya kapı manyetik kontakları **`DI1 ~ DI8` klemensleri ile `DGND` (Dijital Toprak) klemensi arasına** bağlanmalıdır.
* Butona basıldığında `DI` pini `DGND` ile kısa devre olur; optokuplör iletime geçer ve röle 1 milisaniyede anahtarlanır. İnternet veya Wi-Fi kesilse dahi lambalar ve panjurlar duvardan tıkır tıkır çalışır.

---

## 9. Firmware Derleme ve Cihaza Yükleme Adımları

### A. Grafiksel Arayüz ile Yükleme (Önerilen):
1. `ev_otomasyon_servis_yazilimi/ev_otomasyon_sistemi.bat` dosyasına çift tıklayın.
2. Açılan pencerede cihazınızın bağlı olduğu COM portu seçin.
3. Firmware olarak **"Bizim Geliştirdiğimiz Yazılım (v1.0.0)"** zaten otomatik seçilidir.
4. **"⚡ Firmware Yükle"** butonuna basın. Birkaç saniye içinde tam flash paketi cihaza yüklenir.

### B. PlatformIO ile Kod Geliştirme ve Derleme:
Kaynak kodları değiştirdiğinizde projeyi terminalden derlemek için:
```powershell
pio run -d ev_otomasyon_servis_yazilimi\waveshare_s3_demo
```
Derlenen binary dosyasını 0x0 birleşik paket haline getirmek için:
```powershell
python G:\.platformio\packages\tool-esptoolpy\esptool.py --chip esp32s3 merge_bin -o "ev_otomasyon_servis_yazilimi\waveshare_s3_demo\firmware_releases\v1.0.0\firmware_v1.0.0.bin" --flash_mode qio --flash_size 16MB 0x0 "ev_otomasyon_servis_yazilimi\waveshare_s3_demo\.pio\build\esp32-s3-waveshare\bootloader.bin" 0x8000 "ev_otomasyon_servis_yazilimi\waveshare_s3_demo\.pio\build\esp32-s3-waveshare\partitions.bin" 0x10000 "ev_otomasyon_servis_yazilimi\waveshare_s3_demo\.pio\build\esp32-s3-waveshare\firmware.bin"
```

