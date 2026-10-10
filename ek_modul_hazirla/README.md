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

> **İndirme modu (önemli):** Yalnız GND/TX/RX bağlıyken adaptör kartı kendisi resetleyemez (DTR/RTS yok). Yüklemeden önce ESP32'yi elle indirme moduna alın: **BOOT'a basılı tutun → RST/EN'e basıp bırakın (ya da 12V'u kesip verin) → BOOT'u bırakın.** Yalnız BOOT'a basılı tutmak yetmez; çip BOOT'u yalnızca reset anında okur. Kart bu modda bekler, sonra uygulamadan yüklemeyi başlatın.
>
> **Yükleme bittikten sonra:** Yeni yazılımın çalışması için BOOT'a basmadan RST/EN'e bir kez basın (ya da 12V'u kesip verin).

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
2. **COM Port:** CH340 adaptörünüzün bağlı olduğu COM portunu seçin. 'Yenile', her portun USB kimliğini loga yazar; CH340 `VID:PID 1A86:7523` olarak görünür. Emin değilseniz adaptörü çıkarıp 'Yenile'ye basın: kaybolan port doğru porttur.
3. Kartı indirme moduna alın (yukarıdaki BOOT → RST adımı) ve **"🔌 Bağlantıyı Test Et"** ile kartın cevap verdiğini görün. Bu adım firmware yazmaz.
4. **Cihaz No (Slave ID):** Hangi cihazı hazırlıyorsanız numarasını girin (Örn: `1`).
5. **"Cihaz Firmware'ini Hazırla ve Kur"** butonuna basın.
   - Uygulama Cihaz 1 için Modbus RTU Slave kodunu hazırlar, derler ve PlatformIO'nun yazdığı dört görüntüyü (bootloader 0x1000, bölüm tablosu 0x8000, boot_app0 0xE000, uygulama 0x10000) CH340 üzerinden ESP32'ye yazar.
   - Bitince RST/EN'e basın.

---

## 4. Pinleri Tespit Etme (İlk Kurulum İçin)

Karttaki röle pinlerini doğrulamak için:
1. Uygulamadan **"Pin Keşif & Teşhis Yazılımını Kur"** butonuna basın.
2. Yazılım yüklendikten sonra kartı RST/EN ile yeniden başlatın, alttaki komut satırına **`SCAN`** yazıp Gönder'e basın. Konsol açık kaldıkça karttan gelen satırlar loga akar; yeni yükleme başlarken araç portu kendiliğinden kapatır.
3. Röleler 1.5 saniye arayla tek tek çekecektir. Çeken rölenin LED'ini ve ekranda yazan GPIO numarasını not edin.
4. Not ettiğiniz pinleri **`pin_haritasi.json`** dosyasına kaydedin.
5. Ardından **"Cihaz Firmware'ini Hazırla ve Kur"** butonuna basarak Cihaz 1'i üretime hazır hale getirin!

---

## 5. Sorun Giderme

Araç esptool çıktısının tamamını loga yazar ve bilinen hataların altına `*` ile öneri ekler.

| Logdaki hata | Anlamı / yapılacak |
|---|---|
| `No serial data received` | Karttan hiç cevap yok: port doğru mu, TXD→RX0 / RXD→TX0 çapraz mı, GND ortak mı, kart besleniyor mu, kart indirme modunda mı (BOOT → RST)? |
| `Wrong boot mode detected` | Kart normal açılmış: BOOT basılıyken RST/EN'e bas-bırak. |
| `PermissionError` / `Erişim engellendi` | Port başka programda açık (seri monitör, Arduino IDE, ikinci araç penceresi). |
| `FileNotFoundError` | Port yok: adaptör çıkmış ya da COM numarası değişmiş, 'Yenile'. |
| `Invalid head of packet` / `serial noise` | Gürültü ya da seviye uyumsuzluğu: kısa kablo, adaptörü 3.3V'a al, GND. |
| Yükleme "BAŞARILI" ama kart eski davranıyor | RST/EN'e basmadınız (kart indirme modunda kaldı). |
