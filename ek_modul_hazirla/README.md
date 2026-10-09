# AHBU Ev Otomasyonu - Ek Modül Hazırlama Rehberi

Bu klasör, ana modüle RS485 üzerinden bağlanacak ek röle ve giriş kartlarının (ESP32-WROOM-32U 8DI-8RO) yazılımını otomatik hazırlamak ve CH340 üzerinden tek tıkla yüklemek için oluşturulmuştur.

---

## 1. CH340 Programlama Bağlantısı (Kablo Şeması)

Kartın üzerinde ESP32'nin hemen üst kısmında 5 adet delikli pin yuvası (`o o o o o`) bulunur.
Standart USB-CH340 adaptörünüzü şu şekilde bağlayın:

| CH340 Pini | ESP32 Kartı | Açıklama |
|---|---|---|
| **GND** | **GND** | Ortak Toprak |
| **TXD** | **RX0** (GPIO 3) | CH340 Gönderme -> ESP32 Alma |
| **RXD** | **TX0** (GPIO 1) | CH340 Alma -> ESP32 Gönderme |
| **3.3V / 5V** | **VCC / 3.3V** | Besleme (Kart klemensine 12V bağlıysa CH340 VCC bağlanmayabilir, sadece GND, TX, RX yeterlidir) |

> **İpucu:** Firmware yüklerken bağlantı kurulamazsa (Connecting... hatası verirse) kartın üzerindeki **BOOT** butonuna basılı tutun, yükleme başlayınca bırakın.

---

## 2. RS485 Bağlantısı (Ana Modüle Bağlantı)

Kartın sağ üst köşesindeki yeşil klemensler:
- **`MAST A`** -> Ana Modül RS485 `A` (Data +)
- **`MAST B-`** -> Ana Modül RS485 `B` (Data -)
- **`GND-`** -> RS485 Ortak Sinyal Toprağı
- **`- 12V +`** -> 12V DC Güç Kaynağı

---

## 3. Uygulamanın Kullanımı

1. Klasördeki **`ek_modul_hazirla.bat`** dosyasına çift tıklayın (veya terminalden `python ek_modul_hazirla.py` çalıştırın).
2. **COM Port:** CH340 adaptörünüzün bağlı olduğu COM portunu seçin.
3. **Cihaz No (Slave ID):** Hangi cihazı hazırlıyorsanız numarasını girin (Örn: `1`).
4. **"Cihaz Firmware'ini Hazırla ve Kur"** butonuna basın.
   - Uygulama Cihaz 1 için Modbus RTU Slave kodunu hazırlar, derler ve CH340 üzerinden ESP32'ye flashlar.

---

## 4. Pinleri Tespit Etme (İlk Kurulum İçin)

Karttaki röle pinlerini doğrulamak için:
1. Uygulamadan **"Pin Keşif & Teşhis Yazılımını Kur"** butonuna basın.
2. Yazılım yüklendikten sonra alttaki komut satırına **`SCAN`** yazıp Gönder'e basın.
3. Röleler 1.5 saniye arayla tek tek çekecektir. Çeken rölenin LED'ini ve ekranda yazan GPIO numarasını not edin.
4. Not ettiğiniz pinleri **`pin_haritasi.json`** dosyasına kaydedin.
5. Ardından **"Cihaz Firmware'ini Hazırla ve Kur"** butonuna basarak Cihaz 1'i üretime hazır hale getirin!

