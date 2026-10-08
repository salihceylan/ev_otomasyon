# -*- coding: utf-8 -*-
"""
Kablolama şeması (``wiring_pdf``): 1. bölümdeki klemens etiketleri, yedek yazı tipi ve genel kurallar - Tk'siz, ağsız.

* Klemens etiketi KISADIR: giriş adı · kısa kip -> hedef röle ("Salon Panjur Butonu · Panjur adım -> R1"), sensörde
  tür · NO/NC · bölge, boşta girişte "Boşta"; rölenin üstünde ad · tür (adda geçmeyen oda). Uzun kip açıklaması ve hedef
  rölenin adı tablolarda (2. ve 3. bölüm) kalır.
* Etiket çizim alanına (en çok ``BOARD_LABEL_LINES`` satır) sığar. Sığmazsa önce oda atılır, sonra ad "…" ile kısaltılır;
  hedef röle (-> Rn), sensör ayrıntısı ve röle türü HİÇ kesilmez; klemens kimliği (R1 COM|NO / D1 DI|GND) hep çizilir.
* Yedek (TrueType'sız) yazı tipinde çizilemeyen karakterler (–, •, …) çökme yerine ASCII'ye indirgenir.
* "Genel kurallar" bölümü yetkili elektrikçi / sigortalar kapalı kuralıyla başlar.

Diğer PDF testleri (sayfa boyutu, karekod, başlık, daire etiketi) ``test_site_template.WiringPdfTests`` içindedir.
"""

import json
import os
import sys
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)

from PIL import ImageFont  # noqa: E402

import template_model as tm  # noqa: E402
import wiring_pdf  # noqa: E402

FIXTURES = os.path.normpath(os.path.join(TOOL_DIR, "..", "docs", "contracts", "template", "fixtures"))
OK_FIXTURES = ("ok_1p1.json", "ok_2p1_genel.json", "ok_3p1_vana_dimmer.json", "ok_dubleks_ekmodul16.json")
SAFETY_RULE = "Tüm bağlantılar yetkili elektrikçi tarafından, ilgili sigortalar kapalıyken yapılmalıdır."


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


def flat(text):
    """Boşluksuz karşılaştırma: satır kaydırması ve uzun sözcüğün harf harf bölünmesi yok sayılır."""
    return "".join(text.split())


def char_wrap(width):
    """Yazı tipinden bağımsız sınama: her karakter 1 birim genişlik."""
    return lambda text: wiring_pdf.wrap_text(text, len, width)


def long_name_template():
    """40 kanallı (ek modül 32) şablon: tüm röle/giriş adları ve odalar en uzun (31 bayt, en geniş harf), en uzun sensör
    ayrıntısı (anahtarlı kontak, tüm bölgeler), iki haneli hedefler ve güvenlik cihazı (siren) rölesi."""
    t = load_fixture("ok_3p1_vana_dimmer.json")
    tm.set_ext_module(t, True, 32, 1)
    for relay in t["relays"]:
        relay["name"], relay["room"] = "W" * 31, "M" * 31
    for item in t["dis"]:
        item["name"] = "W" * 31
    t["dis"][8].update(target_relay=40, mode="toggle")       # D9 -> R40
    t["dis"][9].update(target_relay=39, mode="momentary")    # D10 -> R39
    tm.set_di_sensor(t, 6, "arm_key", zone=0)                 # D6: Anahtarlı kontak (kurma) · NC · tüm bölgeler
    t["safety"]["actuators"].append({"relay": 38, "kind": "siren", "zones": [1], "name": "Siren"})
    return t


# ============================================================================================================
# Etiket metni (çizimden bağımsız)
# ============================================================================================================
class DiagramLabelTextTests(unittest.TestCase):
    def test_input_label_is_short_and_names_the_target_relay(self):
        t = load_fixture("ok_3p1_vana_dimmer.json")
        expected = {
            1: "Salon Panjur Butonu · Panjur adım -> R1",
            2: "Yatak Panjur Butonu · Panjur adım -> R3",
            3: "Salon Anahtar · Aç/Kapa -> R5",
            5: "Çocuk Odası Anahtar · Aç/Kapa -> R7",
        }
        for ch, text in expected.items():
            with self.subTest(giris=f"D{ch}"):
                self.assertEqual(wiring_pdf.di_board_label(t, ch).text, text)
        duplex = load_fixture("ok_dubleks_ekmodul16.json")
        self.assertEqual(wiring_pdf.di_board_label(duplex, 2).text, "Anahtar 2 · Aç/Kapa -> R8")
        self.assertEqual(wiring_pdf.di_board_label(duplex, 8).text, "Anahtar 8 · Aç/Kapa -> R14")

    def test_every_input_mode_has_a_short_name(self):
        t = load_fixture("ok_3p1_vana_dimmer.json")
        t["dis"][0]["mode"] = "shutter_up"     # D1 -> R1 (panjur çifti)
        t["dis"][1]["mode"] = "shutter_down"   # D2 -> R3
        t["dis"][2]["mode"] = "momentary"      # D3 -> R5 (lamba)
        self.assertIsNone(tm.validate_template(t))
        self.assertEqual(wiring_pdf.di_board_label(t, 1).text, "Salon Panjur Butonu · Panjur yukarı -> R1")
        self.assertEqual(wiring_pdf.di_board_label(t, 2).text, "Yatak Panjur Butonu · Panjur aşağı -> R3")
        self.assertEqual(wiring_pdf.di_board_label(t, 3).text, "Salon Anahtar · Basılı tut -> R5")
        self.assertEqual(set(wiring_pdf.DI_MODE_SHORT), set(tm.DI_MODES))

    def test_sensor_and_idle_inputs(self):
        t = load_fixture("ok_3p1_vana_dimmer.json")
        self.assertEqual(wiring_pdf.di_board_label(t, 7).text, "Mutfak Su Sensörü · Su baskını · NO · bölge 1")
        self.assertEqual(wiring_pdf.di_board_label(t, 6).text, "Boşta")
        duplex = load_fixture("ok_dubleks_ekmodul16.json")
        self.assertEqual(wiring_pdf.di_board_label(duplex, 16).text, "Mutfak Gaz Dedektörü · Gaz · NC · bölge 1")
        self.assertEqual(wiring_pdf.di_board_label(duplex, 9).text, "Anahtar 9 · Boşta")
        t["dis"][5]["name"] = "Alarm Butonu"
        tm.set_di_sensor(t, 6, "alarm_ack", zone=0)
        self.assertEqual(wiring_pdf.di_board_label(t, 6).text, "Alarm Butonu · Alarm susturma butonu · NO · tüm bölgeler")

    def test_relay_label_keeps_the_type_and_skips_a_room_already_in_the_name(self):
        t = load_fixture("ok_3p1_vana_dimmer.json")
        self.assertEqual(wiring_pdf.relay_board_label(t, 1).text, "Salon Panjur Yukarı · Panjur Yukarı")
        self.assertEqual(wiring_pdf.relay_board_label(t, 7).text, "Çocuk Odası · Lamba/Priz")
        self.assertEqual(wiring_pdf.relay_board_label(t, 8).text, "Su Vanası · Vana · Mutfak")  # güvenlik cihazı: cihaz türü
        duplex = load_fixture("ok_dubleks_ekmodul16.json")
        self.assertEqual(wiring_pdf.relay_board_label(duplex, 9).text, "Üst Kat Lamba 1 · Lamba/Priz")
        self.assertEqual(wiring_pdf.relay_board_label(duplex, 15).text, "Siren · Siren · Antre")
        t["relays"][6].update(name="Çalışma Odası", room="Oda")  # "Oda" adda ayrı sözcük olarak geçmiyor: oda yazılır
        self.assertEqual(wiring_pdf.relay_board_label(t, 7).text, "Çalışma Odası · Lamba/Priz · Oda")


# ============================================================================================================
# Satır kaydırma ve etiket sığdırma (yazı tipinden bağımsız: her karakter 1 birim)
# ============================================================================================================
class LabelFittingTests(unittest.TestCase):
    def test_arrow_stays_with_the_target_relay(self):
        self.assertEqual(wiring_pdf.wrap_text("Panjur adım -> R12", len, 14), ["Panjur adım", "-> R12"])

    def test_separator_never_starts_a_line(self):
        self.assertEqual(wiring_pdf.wrap_text("Mutfak Su · Gaz", len, 9), ["Mutfak", "Su · Gaz"])

    def test_a_word_wider_than_the_line_is_split_wherever_it_is(self):
        lines = wiring_pdf.wrap_text("ab " + "W" * 12 + " cd", len, 5)
        self.assertTrue(all(len(line) <= 5 for line in lines), lines)
        self.assertEqual(flat(" ".join(lines)), "ab" + "W" * 12 + "cd")
        self.assertEqual(wiring_pdf.wrap_text("", len, 5), [""])

    def test_label_that_fits_is_drawn_unchanged(self):
        label = wiring_pdf.BoardLabel("Salon Panjur Butonu", "Panjur adım -> R1")
        self.assertEqual(label.fit(char_wrap(12)), ["Salon Panjur", "Butonu ·", "Panjur adım", "-> R1"])

    def test_room_is_dropped_first_then_the_name_is_shortened(self):
        label = wiring_pdf.BoardLabel("Su Vanası", "Vana", "Mutfak")
        self.assertEqual(label.fit(char_wrap(12)), ["Su Vanası ·", "Vana ·", "Mutfak"])
        self.assertEqual(label.fit(char_wrap(12), max_lines=2), ["Su Vanası ·", "Vana"])
        # sığan en uzun ad başı kalır ("Salon Panjur Bu…"); ayrıntı tam ve sonda
        lines = wiring_pdf.BoardLabel("Salon Panjur Butonu", "Panjur adım -> R1").fit(char_wrap(12), max_lines=3)
        self.assertEqual(lines, ["Salon Panjur", "Bu… · Panjur", "adım -> R1"])

    def test_detail_is_never_cut_even_when_the_name_must_go(self):
        lines = wiring_pdf.BoardLabel("W" * 31, "Panjur adım -> R40").fit(char_wrap(20), max_lines=1)
        self.assertEqual(lines, ["Panjur adım -> R40"])


# ============================================================================================================
# Gerçek yazı tipiyle çizilen şema
# ============================================================================================================
class DiagramRenderTests(unittest.TestCase):
    def assert_fitted(self, doc, terminal, label):
        """Klemens etiketi en çok BOARD_LABEL_LINES satır; ya tam çizilmiş ya da ayrıntısı (kip -> hedef / sensör / tür)
        eksiksiz ve sonda (oda atılmış, ad kısalmış). Çizilen satırları döndürür."""
        lines = doc.board_labels[terminal]
        with self.subTest(klemens=terminal):
            self.assertLessEqual(len(lines), wiring_pdf.BOARD_LABEL_LINES, lines)
            drawn = flat(" ".join(lines))
            if drawn != flat(label.text):
                self.assertTrue(drawn.endswith(flat(label.detail)), lines)
        return lines

    def test_reported_labels_are_drawn_in_full(self):
        cases = {
            "ok_3p1_vana_dimmer.json": ("Salon Panjur Butonu · Panjur adım -> R1", "Çocuk Odası Anahtar · Aç/Kapa -> R7",
                                        "Mutfak Su Sensörü · Su baskını · NO · bölge 1"),
            "ok_dubleks_ekmodul16.json": ("Anahtar 2 · Aç/Kapa -> R8", "Anahtar 8 · Aç/Kapa -> R14",
                                          "Mutfak Gaz Dedektörü · Gaz · NC · bölge 1"),
        }
        for name, needles in cases.items():
            doc = wiring_pdf.build_wiring_document(load_fixture(name), site_name="Güneş Sitesi", block="A", number=12)
            drawn = " ".join(" ".join(doc.texts).split())
            for needle in needles:
                with self.subTest(sablon=name, etiket=needle):
                    self.assertIn(needle, drawn)

    def test_every_fixture_label_fits_in_full_and_keeps_its_target(self):
        for name in OK_FIXTURES:
            t = load_fixture(name)
            doc = wiring_pdf.build_wiring_document(t)
            for ch in range(1, tm.total_channels(t) + 1):
                relay = wiring_pdf.relay_board_label(t, ch)
                label = wiring_pdf.di_board_label(t, ch)
                relay_lines = self.assert_fitted(doc, f"R{ch}", relay)
                di_lines = self.assert_fitted(doc, f"D{ch}", label)
                with self.subTest(sablon=name, kanal=ch):
                    self.assertEqual(flat(" ".join(relay_lines)), flat(relay.text))  # gerçek adlar kısalmadan sığar
                    self.assertEqual(flat(" ".join(di_lines)), flat(label.text))
                    target = t["dis"][ch - 1]["target_relay"]
                    if target:
                        self.assertTrue(" ".join(di_lines).endswith(f"-> R{target}"), di_lines)
                    self.assertFalse(any(line.endswith("->") for line in di_lines), di_lines)

    def test_longest_names_are_shortened_but_targets_types_and_terminals_stay(self):
        t = long_name_template()
        self.assertIsNone(tm.validate_template(t))
        doc = wiring_pdf.build_wiring_document(t)
        shortened = 0
        for ch in range(1, tm.total_channels(t) + 1):
            self.assertIn(f"R{ch} COM|NO", doc.texts)
            self.assertIn(f"D{ch} DI|GND", doc.texts)
            relay_lines = self.assert_fitted(doc, f"R{ch}", wiring_pdf.relay_board_label(t, ch))
            di_lines = self.assert_fitted(doc, f"D{ch}", wiring_pdf.di_board_label(t, ch))
            shortened += sum("…" in " ".join(lines) for lines in (relay_lines, di_lines))
        self.assertGreater(shortened, 0)  # kısaltma yolu gerçekten çizimde sınandı
        joined = {terminal: " ".join(lines) for terminal, lines in doc.board_labels.items()}
        self.assertTrue(joined["D1"].endswith("Panjur adım -> R1"), joined["D1"])
        self.assertTrue(joined["D9"].endswith("Aç/Kapa -> R40"), joined["D9"])
        self.assertTrue(joined["D10"].endswith("Basılı tut -> R39"), joined["D10"])
        self.assertTrue(joined["D6"].endswith("Anahtarlı kontak (kurma) · NC · tüm bölgeler"), joined["D6"])
        self.assertTrue(joined["R1"].endswith("Panjur Yukarı"), joined["R1"])
        self.assertTrue(joined["R38"].endswith("Siren"), joined["R38"])


# ============================================================================================================
# Yedek yazı tipi (TrueType yok): Türkçe ve tipografik karakterler ASCII'ye indirgenir, çizim çökmez
# ============================================================================================================
class FallbackFontTests(unittest.TestCase):
    def test_ascii_fallback_maps_typographic_characters(self):
        self.assertEqual(wiring_pdf._to_ascii("Aç/Kapa – yaylı · Salon Pan… • ✓"), "Ac/Kapa - yayli - Salon Pan... * ?")

    @unittest.skipUnless(hasattr(ImageFont, "load_default_imagefont"), "Pillow 10.1+ gerekir")
    def test_bitmap_font_renders_every_page_and_the_flat_label(self):
        def bitmap_loader(_candidates, _size):
            return ImageFont.load_default_imagefont(), False

        for name in OK_FIXTURES:
            with self.subTest(sablon=name):
                doc = wiring_pdf.build_wiring_document(load_fixture(name), site_name="Güneş Sitesi – A",
                                                       font_loader=bitmap_loader)
                self.assertTrue(doc.pages)
        self.assertTrue(wiring_pdf.build_wiring_document(long_name_template(), font_loader=bitmap_loader).pages)
        label = wiring_pdf.build_flat_label(device_uid="AHBU-S3-DD8754", site_name="Güneş Sitesi – A", block="A", number=12,
                                            template_name="B Tipi 3+1", version=4, font_loader=bitmap_loader)
        self.assertEqual(label.image.size, wiring_pdf.FLAT_LABEL_SIZE)


# ============================================================================================================
# 6. Genel kurallar
# ============================================================================================================
class GeneralRulesTests(unittest.TestCase):
    def test_general_rules_start_with_the_electrician_rule_and_keep_the_others(self):
        self.assertEqual(wiring_pdf.GENERAL_NOTES[0], SAFETY_RULE)
        self.assertEqual(len(wiring_pdf.GENERAL_NOTES), 4)
        for start in ("Röle kontakları kuru kontaktır", "Girişler (DI) kuru kontak içindir",
                      "Bu şema karta yazılan şablon sürümüne göredir"):
            with self.subTest(kural=start):
                self.assertTrue(any(note.startswith(start) for note in wiring_pdf.GENERAL_NOTES[1:]))
        doc = wiring_pdf.build_wiring_document(load_fixture("ok_1p1.json"))
        drawn = " ".join(" ".join(doc.texts).split())
        self.assertIn("• " + SAFETY_RULE, drawn)
        self.assertLess(drawn.index("6. Genel kurallar"), drawn.index(SAFETY_RULE))


if __name__ == "__main__":
    unittest.main()
