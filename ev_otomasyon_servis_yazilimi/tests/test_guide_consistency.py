# -*- coding: utf-8 -*-
"""Kullanım rehberi (EV_OTOMASYON_KULLANIM_REHBERI.md) ile araç arasındaki tutarlılık testleri.

Rehber fabrika personeline düğme/pencere/mesaj adlarını aynen söyler; arayüz metni değişir de rehber eski kalırsa
personel yanlış yönlendirilir. Bu testler ağ/Tk/donanım kullanmaz: yalnızca kaynak ve rehber metni karşılaştırılır.
"""
from __future__ import annotations

import os
import re
import unittest

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _read(name: str) -> str:
    with open(os.path.join(BASE_DIR, name), encoding="utf-8") as handle:
        return handle.read()


class GuideConsistencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.guide = _read("EV_OTOMASYON_KULLANIM_REHBERI.md")
        cls.source = "\n".join(
            _read(name)
            for name in ("ev_otomasyon_sistemi.py", "factory_client.py", "site_template_ui.py", "template_model.py", "wiring_pdf.py")
        )

    # Rehberde kalın yazılan düğme/sekme adları (emoji önekleri hariç) aracın kaynağında aynen bulunmalıdır.
    BUTTONS = (
        "Sunucuya Giriş",
        "Oturumu Kapat",
        "Hesap Değiştir",
        "Giriş Yap",
        "Portları Yenile",
        "Karttan MAC Oku",
        "UID Üret (MAC'ten)",
        "Rastgele PIN Üret",
        "SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET",
        "Etiketi Kaydet (PNG)",
        "Yazdır (Barkod / Termal)",
        "Listeyi Yenile",
        "Askıya Al (Kilit)",
        "Aktif Et (Stok)",
        "Envanterden Sil",
        "FİRMWARE'İ KARTA YÜKLE (FLASH)",
        "Hafızayı Sil (Erase Flash)",
        "Versiyon Arttır",
        "Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)",
        "Fabrika Çıkış Orijinal Yazılımı",
        "Seri (USB) ile Provizyonla (Önerilen)",
        "Beklemeyi İptal Et",
        "Elle Provizyon Talimatı",
        "Kaydı Bellekten Sil / Yeni Cihaz",
        "Wi-Fi ile Provizyonla (güvensiz yedek yol)",
        "Wi-Fi ile Doğrula",
        "Ethernet ile Provizyonla",
        "Anahtarı kopyala",
        "AP parolasını kopyala",
        "1. Firmware Yükleyici",
        "2. Karekod Üret & Etiket Bas (Envanter)",
        "3. Cihaz Provizyonu (USB / Wi-Fi)",
        # Faz 3: siteler ve kurulum şablonları (Bölüm 4b)
        "4. Siteler",
        "5. Şablonlar",
        "Siteleri Yenile",
        "Site Ekle",
        "Siteyi Düzenle",
        "Siteyi Sil",
        "Toplu Daire Üret",
        "Şablon Ata",
        "Kart Bağla",
        "Karta Yaz",
        "Kablolama Şeması (PDF)",
        "Şablonları Yenile",
        "Yeni Şablon",
        "Şablonu Düzenle",
        "Çoğalt",
        "Sürüm Geçmişi",
        "Şablonu Sil",
        "Doğrula ve Kaydet (yeni sürüm)",
        "Kanalları Uygula",
        "Şablon Yaz (aynı USB portu)",
        "Lamba/Priz",
        "Panjur (çift)",
        "Parlaklık ayarı yapılacak mı?",
        "Ek modül (RS485) var",
        # 2026-10-08 düzeltmeleri (atolye-1/2/6/11, servis_kurulum-10)
        "Güncelle (ayarlar korunur)",
        "Etiketi Yeniden Bas (USB)",
        "Sunucudaki Anahtarla Yeniden Provizyon (USB)",
        "Teslim Edildi",
        "Bekleyen Kayıtları Gönder",
        "Alarmı Onayla (USB)",
        # 2026-10-09 (sozlesme-5): envanter araması ve sayfalama
        "Daha fazla",
    )

    # Bölüm 4b'nin alıntıladığı kart/araç mesajları (template_model.ERROR_TEXTS ve PDF).
    TEMPLATE_TEXTS = (
        "Önce provizyon yapın",
        "Kartın firmware'i şablon yazmayı desteklemiyor",
        "Aktarım bozuldu (CRC uyuşmadı)",
        "Bu şema şablon sürümü v",
        "servis sorumlusu",
        "unprovisioned",
        "tpl_crc",
        "tpl_b64",
        "zone_latched",
        "Kalıcı (mandallı) duvar anahtarı DESTEKLENMEZ; tüm girişlere yaylı buton bağlayın",
        "Aç/Kapa – yaylı (kalıcı olmayan) buton; her basışta değiştirir",
        "Basılı tut (yaylı buton; basılıyken açık)",
        # 2026-10-09: köprü sensörü (C1), yarım kalmış şablon (sozlesme-4), dairenin güncel şablonu (C2)
        "Kablosuz (köprü) sensör bu sürümde desteklenmiyor",
        "Şablon yarım kaldı; aynı şablonu yeniden yazın.",
        "farklı şablon",
        "Karta yazılan şablon dairenin güncel şablonu değil; daire Yazıldı yapılmadı.",
    )

    # Rehberin alıntıladığı pencere başlıkları.
    DIALOG_TITLES = (
        "Cihaz Envantere Eklendi!",
        "MAC Okundu",
        "MAC Okunamadı",
        "UID MAC ile Uyuşmuyor",
        "Mükerrer Cihaz Uyarısı",
        "Önceki Cihaz Tamamlanmadı",
        "Firmware Uyarısı",
        "Provizyon Tamamlandı",
        "Provizyon Tamamlanmadı",
        "Kartta Eski Anahtar Var",
        "USB (Seri) Provizyon Yapılamadı - Yedek Yol?",
        "Silme Onayı",
        "İşlem Sürüyor",
        "Eksik Paket",
        # 2026-10-08 düzeltmeleri
        "Kart Ayarları Silinecek",
        "Güncelleme Yapılamadı",
        "Etiket Yenilendi",
        "Sunucudaki Anahtarla Yeniden Provizyon",
        "Ethernet ile Doğrulanamadı",
        "Güvenlik Öğesi Silinecek",
        "NC Tehlike Girişi",
        "Alarm Kilitlendi (Atölye)",
        "Şablon Değişti",
        "Daire Etiketi",
        # 2026-10-08 inceleme düzeltmeleri: sürüm düşürme, yoklama hatası, SAFETY, yazım kaydı reddi, teslim ön denetimi
        "Sürüm Düşürme Engellendi",
        "Sürüm Düşürme",
        "Kart Durumu Okunamadı",
        "Güncelle Kipi Seçildi",
        "Güvenlik Durumu Okunamadı",
        "Alarm Sürüyor",
        "Yazım Kaydı Reddedildi",
        "Teslim Edilemez",
        # 2026-10-09 (tarama-sunucu-cihaz-site-6): yazımdan önce daire yeniden okunur; yazım kaydı uyarısı
        "Daire Şablonu Değişti",
        "Daire Şablonu Farklı",
        "Daire Değişti",
    )

    # Rehberin 6. adımda sıraladığı ilerleme satırları (başlangıç parçaları).
    PROGRESS_LINES = (
        "USB (seri) provizyon başlıyor (",
        "Kart yeniden başlıyor; USB seri portun yeniden görünmesi bekleniyor...",
        "Seri porta bağlanıldı; kartın açılması ve STATUS yanıtı bekleniyor...",
        "Kart provizyonsuz; yerel anahtar ve AP parolası USB üzerinden yazılıyor (kablosuz ağdan geçmez)...",
        "FACTORYINIT gönderildi (parametreler gizli); kartın yanıtı bekleniyor...",
        "Yazma tamam; kart STATUS ile doğrulanıyor...",
        "USB (seri) provizyon tamamlandı ve doğrulandı",
    )

    # G3: etiketin iki karekodu: etikette çizilen başlık/açıklama/güvenlik notu rehberde AYNEN anlatılır.
    LABEL_TEXTS = (
        "1) Daireye bağla (uygulama)",
        "2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)",
        "Karekodu uygulamayla okutun",
        "Telefon kamerasıyla okutun, ağa bağlanın",
        "GİZLİ: Bu etiket yalnızca cihaz üzerinde/elde saklanır; fotoğrafı paylaşılmaz (kurulum parolası ve PIN içerir).",
        "Wi-Fi karekodu üretilemedi",
        "WIFI:T:WPA;S:",
    )

    # Rehberdeki ortam değişkenleri ve firmware seri yanıtları (teknik ek).
    TECHNICAL_NAMES = (
        "EV_SERVER_URL",
        "EV_DEVICE_AP_HOST",
        "ADMIN_API_KEY",
        "ESPTOOL_PATH",
        "PLATFORMIO_CORE_DIR",
        "EV_TOOL_DEBUG",
        "OK factory_init",
        "ERR already_provisioned",
        "ERR invalid_local_key",
        "ERR invalid_ap_pass",
        "ERR persist_failed",
    )

    def _assert_in_guide_and_tool(self, names, kind):
        for name in names:
            with self.subTest(**{kind: name}):
                self.assertIn(name, self.guide, f"rehberde yok: {name}")
                self.assertIn(name, self.source, f"araçta yok (rehber eski kalmış olabilir): {name}")

    def test_buttons_and_tabs_named_in_the_guide_exist_in_the_tool(self):
        self._assert_in_guide_and_tool(self.BUTTONS, "dugme")

    def test_dialog_titles_quoted_in_the_guide_exist_in_the_tool(self):
        self._assert_in_guide_and_tool(self.DIALOG_TITLES, "baslik")

    def test_progress_lines_listed_in_the_guide_exist_in_the_tool(self):
        self._assert_in_guide_and_tool(self.PROGRESS_LINES, "satir")

    def test_template_texts_quoted_in_the_guide_exist_in_the_tool(self):
        self._assert_in_guide_and_tool(self.TEMPLATE_TEXTS, "sablon")

    def test_label_texts_quoted_in_the_guide_exist_in_the_tool(self):
        self._assert_in_guide_and_tool(self.LABEL_TEXTS, "etiket")

    def test_guide_has_the_phone_camera_step_and_the_label_secrecy_rule(self):
        self.assertIn("Etiketteki 2. karekodu telefon kamerasıyla okutun, ağa bağlanın", self.guide)
        for needle in (
            "2. karekod",                        # sözlük, adım, güvenlik tablosu
            "yalnızca cihaz üzerinde",           # etiket yalnızca cihaz üzerinde/elde saklanır
            "fotoğrafı",                         # fotoğrafı paylaşılmaz
            "Etiket ve telefonla bağlanma",      # sorun giderme tablosu
        ):
            with self.subTest(needle=needle):
                self.assertIn(needle, self.guide)
        # Adımlar sıralı ve eksiksiz: Adım 1 ... Adım 8
        steps = re.findall(r"(?m)^### Adım (\d+) — ", self.guide)
        self.assertEqual(steps, [str(number) for number in range(1, 9)])

    def test_environment_variables_and_firmware_replies_match_the_tool(self):
        # Seri yanıtlar kaynakta "OK factory_init" gibi tek parça değil kodlarla geçer: iki ayrı parça aranır.
        for name in self.TECHNICAL_NAMES:
            with self.subTest(isim=name):
                self.assertIn(name, self.guide)
        for name in ("EV_SERVER_URL", "EV_DEVICE_AP_HOST", "ADMIN_API_KEY", "ESPTOOL_PATH", "PLATFORMIO_CORE_DIR", "EV_TOOL_DEBUG"):
            with self.subTest(ortam=name):
                self.assertIn(name, self.source)
        for code in ("factory_init", "already_provisioned", "invalid_local_key", "invalid_ap_pass", "persist_failed"):
            with self.subTest(kod=code):
                self.assertIn(code, self.source)

    def test_guide_describes_the_new_flow_and_not_the_old_one(self):
        lowered = self.guide.lower()
        for needle in ("süper kullanıcı", "usb (seri)", "güvensiz", "açık wi-fi penceresi", "factoryinit", "in_stock"):
            with self.subTest(gerekli=needle):
                self.assertIn(needle, lowered)
        # Eski (artık geçersiz) rehberden kalıntı bulunmamalı: sabit AP parolası ve eski interlock süresi.
        for stale in ("`waveshare`", "150 ms"):
            with self.subTest(eski=stale):
                self.assertNotIn(stale, lowered)

    def test_stale_screen_texts_are_gone_and_current_ones_exist(self):
        """atolye-16: ekrandaki eskimiş metinler (Ethernet'te anahtar sunucudan alınır, var olmayan düğme, yalnız süper kullanıcı
        girişi) kaldırıldı; yerlerine güncel davranışı anlatan metinler geldi."""
        for stale in ("Süper Kullanıcı Girişi", "Provizyonu Başlat", "yerel anahtar sunucudan alınır",
                      "yerel anahtar bu UID'ye göre alınır", "Envanteri görmek için süper kullanıcı hesabıyla giriş yapın"):
            with self.subTest(eski=stale):
                self.assertNotIn(stale, self.source)
        for current in ("Sunucuya Giriş (süper kullanıcı / servis sorumlusu)",
                        "Ethernet (LAN) - kartın Ethernet IP'si; anahtar gerekmez",
                        "IP'nin doğru karta ait olduğu DENETLENMEZ, yanlış IP başka karta yazar; UID yalnız yazım kaydı içindir",
                        "Yazım kaydı için kart UID'si gerekir"):
            with self.subTest(guncel=current):
                self.assertIn(current, self.source)

    def test_guide_is_current(self):
        """Rehber: seçili sürüm version_info.json'a göre; Ethernet artık firmware'de etkin; roller; yeni akışlar."""
        with open(os.path.join(BASE_DIR, "waveshare_s3_demo", "firmware_releases", "version_info.json"), encoding="utf-8") as handle:
            import json

            current = json.load(handle)["current_version"]
        self.assertIn(f"v{current}", self.guide)
        self.assertIn("v1.3.1", self.guide)  # donanım denemesi bekleyen sürüm
        for stale in ("firmware'de kapalı", "bu firmware'de etkin değildir", "Güncel imaj `v1.1.2`'dir",
                      "Bu araç yalnızca süper kullanıcı hesabıyla çalışır"):
            with self.subTest(eski=stale):
                self.assertNotIn(stale, self.guide)
        for needle in ("2026-10-08", "anahtarsız", "servis sorumlusu", "NC", "DI-GND", "köprü", "app_0x10000"):
            with self.subTest(gerekli=needle):
                self.assertIn(needle, self.guide)

    def test_guide_describes_the_flash_and_workshop_safeguards(self):
        """Yükleme kipi (BOOT+RESET), yoklama süresi, sürüm düşürme, FAULT bölgesi ve kalıcı kayıt reddi araçla aynı anlatılır."""
        for needle in ("BOOT'a basmadan", "~10 sn", "app_0x10000_v1.3.0.bin", "FAULT", "temizlemez", "kalıcı olarak reddetti",
                       "kuyruktan çıkarıl"):
            with self.subTest(gerekli=needle):
                self.assertIn(needle, self.guide)
        for needle in ("BOOT'a basmadan", "kalıcı olarak reddetti", "temizlemez", "~10 sn"):
            with self.subTest(arac=needle):
                self.assertIn(needle, self.source)
        # 'Güncelleme Yapılamadı' satırı önce normal RESET'i önerir (birleşik imaj kurulu kartın ayarlarını siler)
        row = next(line for line in self.guide.splitlines() if line.startswith("| Güncelleme Yapılamadı"))
        self.assertIn("BOOT'a basmadan", row)
        self.assertLess(row.index("BOOT'a basmadan"), row.index("birleşik") if "birleşik" in row else len(row))

    def test_guide_contains_no_secret_like_assignments(self):
        # Parola/anahtar/token atamaları (ör. "parola: abc123...") rehberde yer almamalı.
        pattern = r"(?i)(parola|şifre|password|api[_ -]?key|token)\s*[:=]\s*[A-Za-z0-9+/_\-]{12,}"
        self.assertIsNone(re.search(pattern, self.guide))

    def test_markdown_has_a_single_title_and_balanced_code_fences(self):
        self.assertEqual(len(re.findall(r"(?m)^# ", self.guide)), 1)
        self.assertEqual(self.guide.count("```") % 2, 0)


if __name__ == "__main__":
    unittest.main()
