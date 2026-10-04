# -*- coding: utf-8 -*-
"""Görsel tema (tool_theme.py) testleri: Tk AÇILMAZ; yalnızca belirteçler, kontrast hesabı, günlük etiketi ve tercih deposu.

Çalıştırma:
    cd ev_otomasyon_servis_yazilimi && python -m unittest discover -s tests -v
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)

import tool_theme as theme  # noqa: E402


class ContrastTests(unittest.TestCase):
    def test_contrast_ratio_matches_wcag_reference_values(self):
        self.assertAlmostEqual(theme.contrast_ratio("#FFFFFF", "#000000"), 21.0, places=2)
        self.assertAlmostEqual(theme.contrast_ratio("#000000", "#FFFFFF"), 21.0, places=2)  # simetrik
        self.assertAlmostEqual(theme.contrast_ratio("#777777", "#FFFFFF"), 4.48, places=2)  # bilinen sınır değeri

    def test_every_text_pair_in_both_palettes_meets_its_threshold(self):
        for name in theme.THEMES:
            for label, fg, bg, ratio, minimum in theme.contrast_report(name):
                with self.subTest(tema=name, cift=label):
                    self.assertGreaterEqual(ratio, minimum, f"{label}: {fg} / {bg} = {ratio}")

    def test_readable_ink_prefers_the_higher_contrast(self):
        self.assertEqual(theme.readable_ink("#0B1120"), "#FFFFFF")
        self.assertEqual(theme.readable_ink("#F8FAFC"), "#0B1120")

    def test_blend_interpolates_between_colors(self):
        self.assertEqual(theme.blend("#FFFFFF", "#000000", 0.0), "#000000")
        self.assertEqual(theme.blend("#FFFFFF", "#000000", 1.0), "#FFFFFF")
        self.assertEqual(theme.blend("#FFFFFF", "#000000", 0.5), "#808080")


class PaletteTests(unittest.TestCase):
    def test_palettes_share_the_same_token_keys(self):
        dark, light = theme.build_palette("dark"), theme.build_palette("light")
        self.assertEqual(set(dark), set(light))
        self.assertEqual(dark["bg"].upper(), "#0B1120")  # şartname zemini
        for family in theme.FAMILIES:
            self.assertIn(f"accent_{family}_text", dark)

    def test_unknown_theme_is_rejected(self):
        with self.assertRaises(ValueError):
            theme.build_palette("sepia")


class LogTagTests(unittest.TestCase):
    def test_lines_are_classified_by_meaning(self):
        self.assertEqual(theme.log_line_tag("❌ [HATA] İşlem başarısız oldu (Hata Kodu: 2)"), "err")
        self.assertEqual(theme.log_line_tag("[UYARI] Sunucu adresi kullanılamadı"), "warn")
        self.assertEqual(theme.log_line_tag("✅ [BAŞARILI] İşlem eksiksiz tamamlandı!"), "ok")
        self.assertEqual(theme.log_line_tag("[KOMUT] esptool.py --chip esp32s3"), "info")
        self.assertEqual(theme.log_line_tag("=" * 50), "muted")
        self.assertIsNone(theme.log_line_tag("Writing at 0x00010000... (12 %)"))
        self.assertIsNone(theme.log_line_tag("   "))

    def test_error_wins_over_success_words_in_the_same_line(self):
        self.assertEqual(theme.log_line_tag("❌ Provizyon tamamlandı sanılan kart doğrulanamadı"), "err")


class PreferenceStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "alt", "ayarlar.json")

    def test_default_is_dark_and_saved_preference_round_trips(self):
        with mock.patch.dict(os.environ, {theme.ENV_THEME: ""}):
            self.assertEqual(theme.load_theme_preference(self.path), "dark")
            self.assertTrue(theme.save_theme_preference("light", self.path))
            self.assertEqual(theme.load_theme_preference(self.path), "light")
            with open(self.path, encoding="utf-8") as handle:
                data = json.load(handle)
            self.assertEqual(data, {"theme": "light"})  # yalnızca görünüm tercihi; başka hiçbir şey yazılmaz

    def test_other_keys_in_the_file_are_preserved(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w", encoding="utf-8") as handle:
            json.dump({"baska": 1}, handle)
        with mock.patch.dict(os.environ, {theme.ENV_THEME: ""}):
            theme.save_theme_preference("light", self.path)
        with open(self.path, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), {"baska": 1, "theme": "light"})

    def test_environment_variable_overrides_the_file_and_garbage_is_ignored(self):
        with open(os.path.join(self.tmp.name, "bozuk.json"), "w", encoding="utf-8") as handle:
            handle.write("{bozuk")
        with mock.patch.dict(os.environ, {theme.ENV_THEME: "light"}):
            self.assertEqual(theme.load_theme_preference(os.path.join(self.tmp.name, "bozuk.json")), "light")
        with mock.patch.dict(os.environ, {theme.ENV_THEME: "neon"}):  # geçersiz değer: dosya/varsayılan
            self.assertEqual(theme.load_theme_preference(os.path.join(self.tmp.name, "bozuk.json")), "dark")
        self.assertFalse(theme.save_theme_preference("neon", self.path))


if __name__ == "__main__":
    unittest.main()
