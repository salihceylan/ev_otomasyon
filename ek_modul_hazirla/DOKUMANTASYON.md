# AHBU Ev Otomasyonu - Ek Modül Hazırlama Uygulaması Kılavuzu

---

## 1. Uygulamanın Amacı ve Ne İşe Yaradığı

Bu uygulama, **AHBU Ev Otomasyonu** sistemine kablolu **RS485 veri yolu** üzerinden bağlanacak olan ek röle ve dijital giriş modüllerini (örneğin ESP32-WROOM-32U tabanlı 8 Röleli, 8 Dijital Girişli kartları) sahada veya atölyede **hızlı, hatasız ve tek tıkla** üretime hazırlamak amacıyla geliştirilmiştir.

### Temel Görevleri:
1. **Kimliklendirme (Cihaz No / Slave ID Atama):**
   - Ana kontrol panosuna RS485 hattından birden fazla ek modül bağlanabilir (Cihaz 1, Cihaz 2, Cihaz 3...).
   - Uygulama, seçtiğiniz cihaz numarasına göre firmware kodunu anında yeniden yapılandırır.
2. **Otomatik Derleme & Yükleme (One-Click Flash):**
   - Kaynak kodları PlatformIO altyapısıyla otomatik derler.
   - CH340 USB-UART dönüştürücüsü üzerinden ESP32 flaşına doğrudan yazar.
3. **Bilinmeyen Kartlar İçin Pin Teşhis & Keşif (Pin Scanner):**
   - Piyasadan temin edilen veya şeması bilinmeyen kartlarda (örneğin üzerindeki Konya Diafon kartı gibi), hangi ESP32 pininin hangi röleye veya girişe gittiğini 1 dakikada keşfetmenizi sağlar.
4. **Modbus RTU Endüstriyel Haberleşme Desteği:**
   - Hazırlanan firmware, ana pano ile endüstri standardı **Modbus RTU (9600 baud, 8N1)** protokolüyle haberleşir.
   - Ana modül tek bir RS485 sorgusuyla ek modülün 8 rölesini açıp kapatabilir ve 8 girişinin (buton, manyetik kontak, su sensörü vb.) anlık durumunu okuyabilir.

---

## 2. Donanım Mimarisi ve Devre Analizi

Mevcut prototipte kullanılan donanım özellikleri:

* **İşlemci:** Espressif **ESP32-WROOM-32U** (Harici IPEX/U.FL anten konnektörlü).
* **Röle Çıkışları (8 Adet):**
  - Panasonic 12V 16A röleler (`ALZ11B12`).
  - Röle durum LED'leri (`RL1` ... `RL8`).
  - **Sürücü Entegresi:** 18 bacaklı **`ULN2803AG`** Darlington Transistör Dizisi. ESP32'nin GPIO çıkışları doğrudan ULN2803 girişlerine bağlıdır. Pini `HIGH` yapmak röleyi çektirir.
* **Dijital Girişler (8 Adet):**
  - Klemensler: `IN1-IN4, COM` ve `IN5-IN8, COM`.
  - Optokuplör ve filtre devreleri.
  - **Okuma Entegresi:** 16 bacaklı **`74HC165D`** (Paralel Giriş - Seri Çıkış Shift Register). 8 giriş ESP32'nin sadece 3 piniyle (Data, Clock, Latch) okunur.
* **RS485 Haberleşme Hattı:**
  - Klemens etiketleri: `MAST A` ve `MAST B-` (Ana pano bağlantısı), `GND-` (Sinyal toprağı).
  - 8 bacaklı SOIC-8 RS485 alıcı-verici entegresi (MAX485 / SP3485 türevi).
* **Besleme:**
  - `- 12V +` yeşil klemensinden 12V DC beslenir. Dahili step-down bobini ve regülatörü kartın 5V ve 3.3V ihtiyaçlarını üretir.

---

## 3. Bağlantı Şeması (CH340 ve RS485)

### A. CH340 Programlama Bağlantısı:
ESP32 modülünün hemen üstündeki 5 delikli header (`o o o o o`):

| CH340 Dönüştürücü | ESP32 Kartı | Açıklama |
|---|---|---|
| **GND** | **GND** | Ortak toprak |
| **TXD** | **RX0** (GPIO 3) | CH340 Gönderir -> ESP32 Alır |
| **RXD** | **TX0** (GPIO 1) | CH340 Alır <- ESP32 Gönderir |
| **3.3V / 5V** | **VCC** | *(Kart klemensine 12V bağlıysa bağlamanıza gerek yoktur)* |

> **Not (indirme modu):** Yalnız GND/TX/RX bağlıyken adaptörün DTR/RTS uçları karta gitmez; esptool kartı kendisi resetleyip indirme moduna alamaz. Yüklemeden önce: **BOOT'a basılı tut → RST/EN'e bas-bırak (ya da 12V'u kes-ver) → BOOT'u bırak.** Yalnız BOOT'a basılı tutmak yetmez, çip BOOT'u yalnızca reset anında okur. Yükleme bitince yeni yazılımın çalışması için BOOT'a basmadan RST/EN'e bir kez basın. Kartta düğme yoksa IO0'ı geçici olarak GND'ye köprüleyip besleme kes-ver yapın.

### B. RS485 Ana Modül Bağlantısı:
| Ek Modül Klemensi | Ana Modül (Master) |
|---|---|
| **MAST A** | RS485 A (Data +) |
| **MAST B-** | RS485 B (Data -) |
| **GND-** | RS485 Sinyal GND |

---

## 4. Kullanım Adımları

### Adım 1: Uygulamayı Başlatma
- Klasördeki **`ek_modul_hazirla.bat`** dosyasına çift tıklayın (veya PowerShell / Terminalden `python ek_modul_hazirla.py` çalıştırın).
- CH340 takılı olan COM portunu seçin (örneğin `COM3`).

### Adım 2: Pinleri Doğrulama (İlk Kurulum İçin)
1. **"🔍 Pin Keşif & Teşhis Yazılımını Kur"** butonuna basın.
2. Yazılım yüklendikten sonra arayüzün altındaki konsola **`SCAN`** yazıp Gönder'e tıklayın.
3. ESP32 çıkış pinlerini sırayla 1.5 saniye arayla çektirir. Çeken rölenin numarasını (RL1..RL8) ve ekranda yazan GPIO numarasını not alın.
4. Not aldığınız pinleri [pin_haritasi.json](file:///g:/site/ev_otomasyon/ek_modul_hazirla/pin_haritasi.json) dosyasına kaydedin.

### Adım 3: Cihaz 1 Yazılımını Kurma
1. Cihaz No kutusuna **`1`** yazın.
2. **"⚡ Cihaz Firmware'ini Hazırla ve Kur"** butonuna basın.
3. Uygulama otomatik olarak:
   - Cihaz 1'in Modbus ID'sini ayarlar,
   - Firmware'i derler,
   - PlatformIO'nun yazdığı dört görüntünün hepsini (bootloader 0x1000, bölüm tablosu 0x8000, boot_app0 0xE000, uygulama 0x10000) CH340 üzerinden ESP32'ye yazar. boot_app0 atlanırsa, kartta OTA ile ikinci bölüme geçmiş eski bir yazılım varsa eski yazılım açılmaya devam eder.
4. "BAŞARIYLA YÜKLENDİ" görününce RST/EN'e basın. Artık Cihaz 1 ana modüle bağlanmaya hazırdır!

> İlk denemede **"🔌 Bağlantıyı Test Et"** ile (firmware yazmadan) kartın cevap verdiğini doğrulayın. Hata çıkarsa araç esptool çıktısının tamamını ve Türkçe öneriyi loga yazar; ayrıntılı tablo [README.md](README.md) "Sorun Giderme" bölümündedir.

---

## 5. Gelecek Adım: Özel Üretim Kendi Kartımıza Geçiş

Şu an kullanılan "Konya Diafon" kartı bir köprü / geliştirme adımıdır. İleride kendi tasarlayacağımız özel donanım versiyonuna geçtiğimizde:
- Tek yapılması gereken [pin_haritasi.json](file:///g:/site/ev_otomasyon/ek_modul_hazirla/pin_haritasi.json) dosyasındaki pinleri yeni kartımızın şemasına göre güncellemek olacaktır.
- `ek_modul_hazirla` uygulaması aynı şekilde çalışmaya devam edecek, Cihaz 1, Cihaz 2, Cihaz 3 üretimleri kesintisiz yürütülecektir.

