# -*- coding: utf-8 -*-
"""G3: etiketin 2. karekodu - kurulum/kurtarma Wi-Fi'sine telefon kamerasıyla tek dokunuşla bağlanma.

Etiket iki karekod taşır: 1) Daireye bağla (PIN'li claim adresi, uygulama okur) ve
2) Kurulum Wi-Fi'sine bağlan (``WIFI:T:WPA;S:<AP SSID>;P:<ap_pass>;;``, telefon kamerası okur).

Kapsam (donanımsız, ağsız, gerçek yazıcısız):
  * saf üretici ``factory_client.wifi_qr_payload`` / ``device_wifi_qr_payload``: biçim, kaçışlar, SSID kuralı
  * uygulamanın ``lib/utils/wifi_qr_parser.dart`` (WifiQrParser) kurallarının Python'da AYNI kaçış/doğrulama kurallarıyla
    yazılmış referans ayrıştırıcısı (uygulamanın kendi test vektörleriyle doğrulanır) ve gidiş-dönüş testleri
  * Dart SDK kuruluysa uygulamanın GERÇEK WifiQrParser kodu da çalıştırılır (çapraz denetim; Dart yoksa atlanır)
  * etiket PNG'si: iki karekod gerçekten bağımsız bir QR çözücüyle (tests/qr_decode.py) çözülür
  * ap_pass yalnızca metinde ve 2. karekodda bulunur; claim karekodunda ve loglarda YOKTUR
"""
import ast
import contextlib
import io
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
for _path in (TOOL_DIR, TESTS_DIR):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import factory_client as fc  # noqa: E402
from qr_decode import QrDecodeError, decode_qr_image, label_qr_boxes  # noqa: E402
from wifi_qr_reference import WifiQrRefError, reference_parse_wifi_qr  # noqa: E402

try:
    import qrcode  # noqa: E402
except ImportError:  # ortam sorunu: QR çözücü öz-sınaması atlanır
    qrcode = None

try:
    import ev_otomasyon_sistemi as tool  # noqa: E402

    TOOL_IMPORT_ERROR = tool._MISSING_DEPENDENCY
except Exception as _exc:  # noqa: BLE001 - ortam sorunu: etiket testleri atlanır
    tool = None
    TOOL_IMPORT_ERROR = type(_exc).__name__

MAC = "E8:F6:0A:DD:87:54"
UID = "AHBU-S3-DD8754"
SSID = "AHBU-DD8754"
PIN = "482915"
SOURCE_FILES = [os.path.join(TOOL_DIR, "ev_otomasyon_sistemi.py"), os.path.join(TOOL_DIR, "factory_client.py")]
ESCAPED = '\\;,:"'  # Wi-Fi karekodunda kaçışlanan beş karakter: ters bölü ; , : "

# Kaçış gerektiren karakterleri içeren (firmware kuralına uyan: 8..32, ASCII) örnek parolalar
SPECIAL_PASSWORDS = [
    'a"b;c\\d,e:f',                     # beşi bir arada
    '"quoted-password"',                # çift tırnakla başlayıp biter (uygulama ayrıştırıcısında tırnak kırpma kuralı)
    'ends-with-backslash\\',            # sonda ters bölü
    '\\\\\\\\;;;;,,,,::::""""',         # yalnızca kaçışlanacak karakterler
    ";leading-semicolon",
    "trailing-semicolon;",
    " spaces inside and edges ",        # baştaki/sondaki boşluk korunur
    "p:a:s:s:w:o:r:d",
    "a;b;c;d;e;f;g;h",
    "WIFI:T:WPA;S:x;P:y;;",             # karekod metni gibi görünen parola
]


# Uygulamanın KENDİ testlerindeki (test/services/qr_parsers_test.dart) vektörler.
# Kabul edilenler: (ham metin, ssid, parola, güvenlik, gizli)
ACCEPTED_VECTORS = [
    ("WIFI:T:WPA;S:Ev_Agi;P:sifre123;H:false;;", "Ev_Agi", "sifre123", "WPA", False),
    ("wifi:H:true;P:parola1234;S:Gizli;t:wpa2;;", "Gizli", "parola1234", "WPA", True),
    (r"WIFI:T:WPA;S:Ev\;Agi\:2\,4\\G;P:a\"b\;c\\d12345;;", r"Ev;Agi:2,4\G", r'a"b;c\d12345', "WPA", False),
    ('WIFI:T:WPA;S:"12345678";P:"parola 1234";;', "12345678", "parola 1234", "WPA", False),
    (r"WIFI:T:WPA;S:\"Ag\";P:parola1234;;", '"Ag"', "parola1234", "WPA", False),
    (r'WIFI:T:WPA;S:"Ag\";P:parola1234;;', '"Ag"', "parola1234", "WPA", False),
    ("WIFI:T:nopass;S:Misafir;;", "Misafir", "", "nopass", False),
    ("WIFI:S:Misafir;;", "Misafir", "", "nopass", False),
    ("WIFI:T:nopass;S:Misafir;P:ihmal;;", "Misafir", "", "nopass", False),
    ("WIFI:S:Ag;P:parola1234;;", "Ag", "parola1234", "WPA", False),
    ("WIFI:T:SAE;S:Ag;P:parola1234;;", "Ag", "parola1234", "WPA", False),
    ("WIFI:T:WPA3;S:Ag;P:parola1234;;", "Ag", "parola1234", "WPA", False),
]
# Reddedilenler: ham metin -> WifiQrError adı
REJECTED_VECTORS = {
    "WIFI:T:WEP;S:Ag;P:12345;;": "wepUnsupported",
    "WIFI:T:WPA2-EAP;S:Kurum;;": "eapUnsupported",
    "WIFI:T:WPA;S:Kurum;E:PEAP;P:parola1234;;": "eapUnsupported",
    "WIFI:T:WPA;S:Kurum;A:anon;P:parola1234;;": "eapUnsupported",
    "WIFI:T:XYZ;S:Ag;P:parola1234;;": "unknownSecurity",
    "WIFI:T:WPA;P:parola1234;;": "missingSsid",
    "WIFI:T:WPA;S:;P:parola1234;;": "missingSsid",
    "WIFI:T:WPA;S:Ag;P:kisa;;": "passwordLength",
    "WIFI:T:WPA;S:Ag;P:;;": "passwordLength",
    "WIFI:T:WPA;S:Ag;P:1234567;;": "passwordLength",
    "WIFI:T:WPA;S:Ag;P:\u0001parola1234;;": "controlCharacters",
    "WIFI:T:WPA;S:A\u0000g;P:parola1234;;": "controlCharacters",
    "WIFI:T:WPA;S:Ag;P:parola1234\\": "malformed",  # yarım kaçış
    "METIN": "notWifi",
    "WIFI:T:WPA;S:%s;P:parola1234;;" % ("a" * 33): "ssidTooLong",
    "WIFI:T:WPA;S:%s;P:parola1234;;" % ("\u011f" * 17): "ssidTooLong",  # 17 x 2 bayt = 34 bayt
    "WIFI:T:WPA;S:Ag;P:%s;;" % ("p" * 64): "passwordLength",
    "WIFI:T:WPA;S:Ag;P:%s;;" % ("p" * 600): "tooLong",
}


class ReferenceParserTests(unittest.TestCase):
    """Referans ayrıştırıcı, uygulamanın KENDİ testlerindeki vektörlerle sınanır (ve Dart varsa gerçek ayrıştırıcıyla
    karşılaştırılır: AppParserCrossCheckTests): "uygulama bu karekodu aynı şekilde çözer" iddiası gerçek beklentilere dayanır."""

    def test_vectors_accepted_by_the_app(self):
        for raw, ssid, password, security, hidden in ACCEPTED_VECTORS:
            with self.subTest(raw=raw):
                parsed = reference_parse_wifi_qr(raw)
                self.assertEqual((parsed.ssid, parsed.password, parsed.security, parsed.hidden), (ssid, password, security, hidden))

    def test_vectors_rejected_by_the_app(self):
        for raw, code in REJECTED_VECTORS.items():
            with self.subTest(code=code, raw=raw[:30]):
                with self.assertRaises(WifiQrRefError) as ctx:
                    reference_parse_wifi_qr(raw)
                self.assertEqual(ctx.exception.code, code)

    def test_size_limits_match_the_app(self):
        self.assertEqual(reference_parse_wifi_qr("WIFI:T:WPA;S:%s;P:parola1234;;" % ("a" * 32)).ssid, "a" * 32)
        self.assertEqual(reference_parse_wifi_qr("WIFI:T:WPA;S:%s;P:parola1234;;" % ("\u011f" * 16)).ssid, "\u011f" * 16)
        for length in (8, 63):
            self.assertEqual(reference_parse_wifi_qr("WIFI:T:WPA;S:Ag;P:%s;;" % ("p" * length)).password, "p" * length)


# ============================================================================================================
# Uygulamanın GERÇEK Dart ayrıştırıcısıyla çapraz denetim (Dart SDK varsa)
# ============================================================================================================
DART = shutil.which("dart")
DART_PARSER = os.path.normpath(os.path.join(TOOL_DIR, "..", "lib", "utils", "wifi_qr_parser.dart"))
DART_SCRIPT = r"""import 'dart:convert';
import 'dart:io';

import '__PARSER_URI__';

// Çıktı yalnızca ASCII (konsol kod sayfasından bağımsız): ASCII dışı karakterler \\uXXXX olarak yazılır.
String asciiJson(Object value) {
  final b = StringBuffer();
  for (final unit in jsonEncode(value).codeUnits) {
    if (unit < 0x80) {
      b.writeCharCode(unit);
    } else {
      b.write('\\u' + unit.toRadixString(16).padLeft(4, '0'));
    }
  }
  return b.toString();
}

void main(List<String> args) {
  final inputs = (jsonDecode(File(args[0]).readAsStringSync()) as List).cast<String>();
  for (final raw in inputs) {
    final r = WifiQrParser.parseDetailed(raw);
    final c = r.credentials;
    if (c != null) {
      print(asciiJson({'ok': true, 'ssid': c.ssid, 'password': c.password, 'security': c.security, 'hidden': c.hidden}));
    } else {
      print(asciiJson({'ok': false, 'error': r.error.toString().split('.').last}));
    }
  }
}
"""


@unittest.skipUnless(DART and os.path.isfile(DART_PARSER), "Dart SDK veya uygulamanın WifiQrParser dosyası yok")
class AppParserCrossCheckTests(unittest.TestCase):
    """Etiketin 2. karekod metni, uygulamanın GERÇEK ``WifiQrParser`` kodu (lib/utils/wifi_qr_parser.dart, Dart ile
    çalıştırılır) tarafından özgün SSID/parolaya çözülür; ayrıca Python referans ayrıştırıcısı gerçek ayrıştırıcıyla
    farksız çalışır (uygulama vektörleri + rastgele fark testi)."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.script = os.path.join(cls._tmp.name, "parse_wifi_qr.dart")
        with open(cls.script, "w", encoding="utf-8") as handle:
            handle.write(DART_SCRIPT.replace("__PARSER_URI__", pathlib.Path(DART_PARSER).resolve().as_uri()))

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def run_dart(self, inputs):
        path = os.path.join(self._tmp.name, "input.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(inputs, handle)  # ASCII kaçışlı (ensure_ascii)
        try:
            done = subprocess.run([DART, self.script, path], capture_output=True, text=True, encoding="utf-8",
                                  timeout=180, shell=False, stdin=subprocess.DEVNULL)
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.skipTest("Dart çalıştırılamadı: %s" % type(exc).__name__)
        lines = [line for line in done.stdout.splitlines() if line.strip()]
        if done.returncode != 0 or len(lines) != len(inputs):
            self.skipTest("Dart çıktısı alınamadı (çıkış kodu %s): %s" % (done.returncode, (done.stderr or "")[:200]))
        return [json.loads(line) for line in lines]

    @staticmethod
    def reference_outcome(raw):
        try:
            parsed = reference_parse_wifi_qr(raw)
        except WifiQrRefError as exc:
            return {"ok": False, "error": exc.code}
        return {"ok": True, "ssid": parsed.ssid, "password": parsed.password, "security": parsed.security, "hidden": parsed.hidden}

    def test_real_parser_reads_every_generated_payload_back_to_the_original_values(self):
        rng = random.Random(20261002)
        alphabet = [chr(code) for code in range(0x20, 0x7F)] + list(ESCAPED) * 10
        passwords = list(SPECIAL_PASSWORDS) + [fc.generate_ap_pass() for _ in range(40)]
        passwords += ["".join(rng.choice(alphabet) for _ in range(rng.randint(8, 32))) for _ in range(200)]
        payloads = [fc.device_wifi_qr_payload(MAC, password) for password in passwords]
        results = self.run_dart(payloads)
        for password, payload, result in zip(passwords, payloads, results):
            self.assertEqual(result, {"ok": True, "ssid": SSID, "password": password, "security": "WPA", "hidden": False},
                             "uygulamanın ayrıştırıcısı parolayı özgün haliyle geri vermedi")

    def test_reference_parser_agrees_with_the_real_parser_on_the_apps_own_vectors(self):
        inputs = [raw for raw, *_rest in ACCEPTED_VECTORS] + list(REJECTED_VECTORS)
        for raw, result in zip(inputs, self.run_dart(inputs)):
            with self.subTest(raw=raw[:40]):
                self.assertEqual(result, self.reference_outcome(raw))
        for (raw, ssid, password, security, hidden), result in zip(ACCEPTED_VECTORS, self.run_dart([v[0] for v in ACCEPTED_VECTORS])):
            self.assertEqual(result, {"ok": True, "ssid": ssid, "password": password, "security": security, "hidden": hidden})
        for (raw, code), result in zip(REJECTED_VECTORS.items(), self.run_dart(list(REJECTED_VECTORS))):
            self.assertEqual(result, {"ok": False, "error": code})

    def test_reference_parser_agrees_with_the_real_parser_on_random_inputs(self):
        rng = random.Random(77)
        tokens = ["WIFI:", "T:", "S:", "P:", "H:", "E:", "WPA", "WPA2", "nopass", "WEP", "true", ";", ";;", "\\", ",", ":", '"',
                  "a", "b", "1", " ", "ssid", "pass1234", "parola1234", "\u011f", "\\;", '\\"', "\\:", "\\,"]
        inputs = []
        for _ in range(400):
            body = "".join(rng.choice(tokens) for _ in range(rng.randint(2, 18)))
            inputs.append(("WIFI:" if rng.random() < 0.85 else "") + body)
        mismatches = []
        for raw, result in zip(inputs, self.run_dart(inputs)):
            if result != self.reference_outcome(raw):
                mismatches.append((raw, result, self.reference_outcome(raw)))
        self.assertEqual(mismatches[:3], [])


# ============================================================================================================
# Bağımsız QR çözücünün öz-sınaması (etiket testleri ona güvenir)
# ============================================================================================================
@unittest.skipIf(qrcode is None, "qrcode kütüphanesi yok")
class QrDecoderSelfTests(unittest.TestCase):
    PAYLOADS = [
        "1",                                                   # sayısal
        "12345678901234567890",
        "HELLO WORLD",                                         # alfasayısal
        "HELLO-WORLD 1234:/.$%*+",
        "hello world",                                         # bayt
        "WIFI:T:WPA;S:AHBU-DD8754;P:Kx7mPq2Wd9;;",
        r'WIFI:T:WPA;S:AHBU-DD8754;P:A\;b\,c\:d\"e\\f 1234567890123456;;',
        "https://evotomasyon.gudeteknoloji.com.tr/claim?uid=AHBU-S3-DD8754&pin=482915",
        "x" * 150,
        "Türkçe ğüşiöç 0123456789",  # UTF-8 çok baytlı
        "AB12" * 60,
        "9" * 200,
    ]

    @staticmethod
    def render(payload, level, box=4):
        qr = qrcode.QRCode(error_correction=level, border=2, box_size=box)
        qr.add_data(payload)
        qr.make(fit=True)
        return qr.make_image(fill_color="black", back_color="white").convert("RGB"), qr.version

    def test_decodes_library_generated_codes_in_all_modes_and_error_levels(self):
        levels = [qrcode.constants.ERROR_CORRECT_L, qrcode.constants.ERROR_CORRECT_M,
                  qrcode.constants.ERROR_CORRECT_Q, qrcode.constants.ERROR_CORRECT_H]
        decoded = 0
        for level in levels:
            for payload in self.PAYLOADS:
                image, version = self.render(payload, level, box=3 + len(payload) % 4)
                if version > 10:
                    continue
                with self.subTest(level=level, payload=payload[:24]):
                    self.assertEqual(decode_qr_image(image), payload)
                    decoded += 1
        self.assertGreater(decoded, 30)

    def test_rejects_regions_without_a_qr_code(self):
        from PIL import Image
        blank = Image.new("RGB", (200, 200), "white")
        with self.assertRaises(QrDecodeError):
            decode_qr_image(blank)
        noise = Image.new("RGB", (205, 205), "white")
        rng = random.Random(7)
        for _ in range(3000):
            noise.putpixel((rng.randrange(205), rng.randrange(205)), (0, 0, 0))
        with self.assertRaises(QrDecodeError):
            decode_qr_image(noise)

    def test_a_corrupted_symbol_never_decodes_to_the_original_text(self):
        payload = "WIFI:T:WPA;S:AHBU-DD8754;P:Kx7mPq2Wd9;;"
        image, _version = self.render(payload, qrcode.constants.ERROR_CORRECT_M, box=6)
        module = 6
        origin = 2 * module  # sessiz bölge (2 modül)
        for row, col in ((12, 12), (14, 20), (20, 14), (16, 16), (18, 22)):  # veri bölgesinden modüller
            x, y = origin + col * module, origin + row * module
            old = image.getpixel((x + 1, y + 1))
            flipped = (255, 255, 255) if old[0] < 128 else (0, 0, 0)
            for dx in range(module):
                for dy in range(module):
                    image.putpixel((x + dx, y + dy), flipped)
        try:
            self.assertNotEqual(decode_qr_image(image), payload)
        except QrDecodeError:
            pass


# ============================================================================================================
# Saf üretici: biçim, kaçışlar, SSID kuralı
# ============================================================================================================
class WifiQrBuilderTests(unittest.TestCase):
    def test_exact_format_for_plain_values(self):
        self.assertEqual(fc.wifi_qr_payload(SSID, "Kx7mPq2Wd9"), "WIFI:T:WPA;S:AHBU-DD8754;P:Kx7mPq2Wd9;;")

    def test_each_special_character_is_escaped_with_a_backslash(self):
        for ch in ESCAPED:
            with self.subTest(ch=ch):
                self.assertEqual(fc.escape_wifi_qr_value("ab%scd" % ch), "ab\\%scd" % ch)

    def test_exact_vector_with_all_special_characters(self):
        password = 'a\\b;c,d:e"f12'
        expected = r'WIFI:T:WPA;S:AHBU-DD8754;P:a\\b\;c\,d\:e\"f12;;'
        self.assertEqual(fc.wifi_qr_payload(SSID, password), expected)

    def test_only_the_five_characters_are_escaped(self):
        for code in range(0x20, 0x7F):
            ch = chr(code)
            expected = "\\" + ch if ch in ESCAPED else ch
            self.assertEqual(fc.escape_wifi_qr_value(ch), expected, repr(ch))
        untouched = "a b'c<d>e&f%g#h@i!j$k^l*m(n)o[p]q{r}s|t~u`v=w+x-y_z/./?"
        self.assertEqual(fc.escape_wifi_qr_value(untouched), untouched)

    def test_ssid_is_escaped_too(self):
        self.assertEqual(fc.wifi_qr_payload("Ev;Agi:2,4", "parola1234"), r"WIFI:T:WPA;S:Ev\;Agi\:2\,4;P:parola1234;;")

    def test_payload_shape_is_the_requested_one(self):
        payload = fc.wifi_qr_payload(SSID, "Kx7mPq2Wd9")
        self.assertTrue(payload.startswith("WIFI:T:WPA;S:"))
        self.assertTrue(payload.endswith(";;"))
        self.assertEqual(payload.count(";P:"), 1)
        self.assertNotIn("H:", payload)  # kurulum ağı gizli değildir (firmware: WiFi.softAP(..., gizli=0))

    def test_invalid_values_raise_without_echoing_the_secret(self):
        secret_like = "Gizli-Parola-1"
        bad = [
            ("", "parola1234"),
            ("x" * 33, "parola1234"),
            ("\u011f" * 17, "parola1234"),          # 34 bayt
            ("A\x00g", "parola1234"),
            ("Ag", "kisa"),                          # 4 karakter
            ("Ag", "p" * 64),
            ("Ag", "parola\n1234"),                  # kontrol karakteri
            ("Ag", None),
            (None, "parola1234"),
        ]
        for ssid, password in bad:
            with self.subTest(ssid=repr(ssid)[:20], password=repr(password)[:20]):
                with self.assertRaises(ValueError) as ctx:
                    fc.wifi_qr_payload(ssid, password)
                self.assertNotIn(secret_like, str(ctx.exception))
                if isinstance(password, str) and password:
                    self.assertNotIn(password, str(ctx.exception))
        with self.assertRaises(ValueError) as ctx:
            fc.wifi_qr_payload("Ag", secret_like + "\x01")
        self.assertNotIn(secret_like, str(ctx.exception))

    def test_device_payload_uses_the_firmware_ssid_rule(self):
        # firmware: snprintf("AHBU-%02X%02X%02X", mac[3], mac[4], mac[5]) -> MAC'in son 3 baytı, büyük harf
        for mac, ssid in (
            ("E8:F6:0A:DD:87:54", "AHBU-DD8754"),
            ("e8:f6:0a:dd:87:54", "AHBU-DD8754"),
            ("E8-F6-0A-DD-87-54", "AHBU-DD8754"),
            ("e8f60add8754", "AHBU-DD8754"),
            ("a1:b2:c3:d4:e5:f6", "AHBU-D4E5F6"),
            ("00:11:22:33:44:ab", "AHBU-3344AB"),
        ):
            with self.subTest(mac=mac):
                payload = fc.device_wifi_qr_payload(mac, "Kx7mPq2Wd9")
                self.assertEqual(payload, "WIFI:T:WPA;S:%s;P:Kx7mPq2Wd9;;" % ssid)
                self.assertEqual(ssid, fc.ap_ssid_from_mac(mac))
                mac_bytes = bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", mac))
                self.assertEqual(ssid, "AHBU-%02X%02X%02X" % (mac_bytes[3], mac_bytes[4], mac_bytes[5]))

    def test_device_payload_rejects_invalid_mac_or_ap_pass(self):
        for mac in ("", "E8:F6", "ZZ:F6:0A:DD:87:54", None, 12345):
            with self.subTest(mac=mac):
                with self.assertRaises(ValueError):
                    fc.device_wifi_qr_payload(mac, "Kx7mPq2Wd9")
        for ap_pass in ("kisa", "k" * 7, "p" * 33, "\u015fifre1234", "parola\t1234", "parola\x7f1234", None, 12345678):
            with self.subTest(ap_pass=repr(ap_pass)[:20]):
                with self.assertRaises(ValueError) as ctx:
                    fc.device_wifi_qr_payload(MAC, ap_pass)
                if isinstance(ap_pass, str) and len(ap_pass) > 6:
                    self.assertNotIn(ap_pass, str(ctx.exception))

    def test_firmware_accepts_everything_the_builder_accepts(self):
        # firmware ap_pass: 8..32 karakter, ASCII 0x20-0x7E; üretici aynı kümeyi kabul eder ve hiçbirini bozmaz
        rng = random.Random(20261001)
        alphabet = [chr(code) for code in range(0x20, 0x7F)]
        for _ in range(300):
            password = "".join(rng.choice(alphabet) for _ in range(rng.randint(8, 32)))
            self.assertTrue(fc.is_valid_ap_pass(password))
            payload = fc.device_wifi_qr_payload(MAC, password)
            self.assertLessEqual(len(payload), 512)  # uygulamanın "tooLong" sınırı

    def test_ssid_rule_and_open_ap_settings_match_the_firmware_source(self):
        path = os.path.join(TOOL_DIR, "waveshare_s3_demo", "src", "WiFiManager.cpp")
        if not os.path.isfile(path):
            self.skipTest("firmware kaynağı yok")
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        match = re.search(r"String WiFiManager::apSsid\(\)\s*\{(.*?)\n\}", source, re.S)
        self.assertIsNotNone(match, "apSsid() bulunamadı: firmware yeniden düzenlenmiş olabilir; SSID kuralını denetleyin")
        body = match.group(1)
        self.assertIn("ESP_MAC_WIFI_STA", body)
        self.assertIn('"AHBU-%02X%02X%02X", mac[3], mac[4], mac[5]', body)
        for soft_ap in re.finditer(r"WiFi\.softAP\(([^;]*)\);", source):  # ağ gizli değil: karekoda H:true gerekmez
            arguments = [part.strip() for part in soft_ap.group(1).split(",")]
            if len(arguments) >= 4:
                self.assertNotIn(arguments[3], ("1", "true"), "kurulum ağı gizli olursa karekoda H:true gerekir")


class RoundTripTests(unittest.TestCase):
    """Üretilen karekod metni, uygulamanın ayrıştırıcı kurallarıyla (referans) çözülünce özgün SSID/parola geri gelir."""

    def assertRoundTrip(self, ssid, password):
        payload = fc.wifi_qr_payload(ssid, password)
        parsed = reference_parse_wifi_qr(payload)
        self.assertEqual((parsed.ssid, parsed.password, parsed.security, parsed.hidden), (ssid, password, "WPA", False))

    def test_generated_ap_passwords_round_trip(self):
        for _ in range(100):
            self.assertRoundTrip(SSID, fc.generate_ap_pass())

    def test_special_character_passwords_round_trip(self):
        for password in SPECIAL_PASSWORDS:
            with self.subTest(password=password):
                self.assertTrue(fc.is_valid_ap_pass(password), "örnek parola firmware kuralına uymalı")
                self.assertRoundTrip(SSID, password)

    def test_random_printable_ascii_passwords_round_trip(self):
        rng = random.Random(1234567)
        alphabet = [chr(code) for code in range(0x20, 0x7F)] + list(ESCAPED) * 10  # kaçışlanacak karakterler sık gelsin
        for _ in range(500):
            password = "".join(rng.choice(alphabet) for _ in range(rng.randint(8, 32)))
            self.assertRoundTrip(SSID, password)

    def test_device_payload_round_trips_ssid_and_password(self):
        for mac in ("E8:F6:0A:DD:87:54", "a1:b2:c3:d4:e5:f6", "00:00:00:00:00:00"):
            payload = fc.device_wifi_qr_payload(mac, 'x;y"z\\1234')
            parsed = reference_parse_wifi_qr(payload)
            self.assertEqual(parsed.ssid, fc.ap_ssid_from_mac(mac))
            self.assertEqual(parsed.password, 'x;y"z\\1234')

    def test_unescaped_payload_would_be_misread(self):
        # Kaçışın neden şart olduğunun kanıtı: kaçışsız yazılan ';' parolayı keser (uygulama parolayı reddeder/yanlış okur)
        naive = "WIFI:T:WPA;S:%s;P:%s;;" % (SSID, "abc;defgh123")
        try:
            parsed = reference_parse_wifi_qr(naive)
            self.assertNotEqual(parsed.password, "abc;defgh123")
        except WifiQrRefError:
            pass


# ============================================================================================================
# Etiket görseli: iki karekod, içerik, gizlilik
# ============================================================================================================
@unittest.skipIf(tool is None or TOOL_IMPORT_ERROR, "arayüz bağımlılıkları (tk/qrcode/pillow) yok")
class LabelTwoQrTests(unittest.TestCase):
    def record(self, **overrides):
        values = dict(uid=UID, mac=MAC, pin=PIN, local_key="TEST-KEY-1234567", ap_pass="Kx7mPq2Wd9",
                      qr_claim_url=fc.build_claim_url(UID, PIN), serial_no=7, model="ESP32-S3-POE-ETH-8DI-8RO",
                      created_at="2026-10-01T10:20:30.000Z")
        values.update(overrides)
        return fc.DeviceRecord(**values)

    def png_roundtrip(self, image):
        """Etiketi PNG olarak yazıp (bellekte) yeniden okur: kullanıcının kaydettiği dosyayla aynı yol."""
        buffer = io.BytesIO()
        image.save(buffer, "PNG", dpi=tool.LABEL_DPI)
        buffer.seek(0)
        return tool.Image.open(buffer).convert("RGB")

    def decode_both(self, record):
        image = self.png_roundtrip(tool.build_label_image(record))
        box_claim, box_wifi = label_qr_boxes(tool, record)
        return decode_qr_image(image, box_claim), decode_qr_image(image, box_wifi)

    def drawn_texts(self, record):
        drawn = []
        original = tool.ImageDraw.ImageDraw.text

        def spy(draw_self, xy, text, *args, **kwargs):
            drawn.append((xy, text))
            return original(draw_self, xy, text, *args, **kwargs)

        with mock.patch.object(tool.ImageDraw.ImageDraw, "text", spy):
            tool.build_label_image(record)
        return drawn

    @staticmethod
    def fold(text):
        return text.translate(tool._TR_TO_ASCII)

    def assertDrawn(self, drawn, text):
        texts = {value for _xy, value in drawn}
        self.assertTrue(text in texts or self.fold(text) in texts, "etikette çizilmedi: %r" % text)

    # ---- iki karekod gerçekten etikette ve çözülebiliyor --------------------------------------------------
    def test_png_contains_two_decodable_qr_codes_with_the_expected_payloads(self):
        record = self.record()
        claim, wifi = self.decode_both(record)
        self.assertEqual(claim, fc.build_claim_url(UID, PIN))
        self.assertEqual(wifi, "WIFI:T:WPA;S:AHBU-DD8754;P:Kx7mPq2Wd9;;")
        self.assertEqual(fc.parse_claim_url(claim), (UID, PIN))

    def test_second_qr_round_trips_through_the_apps_parser_rules(self):
        record = self.record()
        _claim, wifi = self.decode_both(record)
        parsed = reference_parse_wifi_qr(wifi)
        self.assertEqual((parsed.ssid, parsed.password, parsed.security, parsed.hidden), (SSID, "Kx7mPq2Wd9", "WPA", False))

    def test_special_character_password_survives_png_and_parser(self):
        for password in SPECIAL_PASSWORDS:
            with self.subTest(password=password):
                record = self.record(ap_pass=password)
                claim, wifi = self.decode_both(record)
                self.assertEqual(wifi, fc.device_wifi_qr_payload(MAC, password))
                parsed = reference_parse_wifi_qr(wifi)
                self.assertEqual((parsed.ssid, parsed.password), (SSID, password))
                self.assertEqual(fc.parse_claim_url(claim), (UID, PIN))

    def test_longest_possible_payload_still_fits_and_decodes(self):
        record = self.record(ap_pass='"' * 32)  # 32 karakterin hepsi kaçışlanır: en uzun metin
        claim, wifi = self.decode_both(record)
        self.assertEqual(reference_parse_wifi_qr(wifi).password, '"' * 32)
        box_claim, box_wifi = label_qr_boxes(tool, record)
        self.assertLessEqual(box_wifi[2] - box_wifi[0], tool.LABEL_COL_RIGHT_W)  # sütuna sığar

    def test_qr_modules_are_large_enough_for_phone_cameras(self):
        # 203 dpi'de 4 px = 0,5 mm modül: telefon kameraları bu boyutu rahat okur (en uzun/kaçışlı parolada bile)
        for password in ("Kx7mPq2Wd9", 'A;b,c:d"e\\f 1234567890123456', '"' * 32):
            record = self.record(ap_pass=password)
            for payload in (tool.label_qr_payload(record), tool.label_wifi_qr_payload(record)):
                qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=2)
                qr.add_data(payload)
                qr.make(fit=True)
                image = tool.make_qr_image(payload)
                module_px = image.width // (qr.modules_count + 2 * qr.border)
                self.assertGreaterEqual(module_px, 4, (password, qr.version))
                self.assertEqual(image.width, module_px * (qr.modules_count + 2 * qr.border))  # tam sayı modül: bulanıklık yok

    def test_each_qr_is_generated_exactly_once_in_order_claim_then_wifi(self):
        captured = []
        original = tool.qrcode.QRCode.add_data

        def spy(qr_self, data, optimize=20):
            captured.append(data)
            return original(qr_self, data, optimize)

        record = self.record()
        with mock.patch.object(tool.qrcode.QRCode, "add_data", spy):
            image = tool.build_label_image(record)
        self.assertEqual(captured, [fc.build_claim_url(UID, PIN), "WIFI:T:WPA;S:AHBU-DD8754;P:Kx7mPq2Wd9;;"])
        self.assertEqual(image.size, tool.LABEL_SIZE)

    # ---- ap_pass yalnızca metinde ve 2. karekodda --------------------------------------------------------
    def test_ap_pass_is_only_in_the_text_and_the_second_qr(self):
        record = self.record(ap_pass='Zq;9,x:Y"w\\K3')
        claim, wifi = self.decode_both(record)
        escaped = fc.escape_wifi_qr_value(record.ap_pass)
        for forbidden in (record.ap_pass, escaped):  # 1. karekodda (claim adresi) YOK
            self.assertNotIn(forbidden, claim)
            self.assertNotIn(forbidden, record.qr_claim_url)
            self.assertNotIn(forbidden, tool.label_qr_payload(record))
        self.assertIn(escaped, wifi)  # 2. karekodda var (kaçışlı)
        self.assertNotIn(record.local_key, claim + wifi)  # yerel anahtar hiçbir karekodda yok
        drawn = self.drawn_texts(record)
        with_pass = [(xy, text) for xy, text in drawn if record.ap_pass in text]
        self.assertEqual(len(with_pass), 1, "AP parolası etiket metninde yalnızca bir kez (AĞ PAROLASI alanı) çizilmeli")
        captions = [text for _xy, text in drawn]
        self.assertTrue(any(self.fold("AĞ PAROLASI (AP)") == text or "AĞ PAROLASI (AP)" == text for text in captions))
        for _xy, text in drawn:  # PIN yalnızca KURULUM PIN kutusunda; yerel anahtar hiçbir yerde
            self.assertNotIn(record.local_key, text)

    def test_text_lines_are_unchanged(self):
        record = self.record()
        self.assertEqual(
            tool.label_text_lines(record),
            [
                ("CİHAZ SERİ NO (UID)", UID),
                ("KURULUM PIN", "482 915"),
                ("KURULUM Wi-Fi AĞI", SSID),
                ("AĞ PAROLASI (AP)", "Kx7mPq2Wd9"),
                ("MAC ADRESİ", MAC),
            ],
        )
        self.assertEqual(tool.label_qr_payload(record), fc.build_claim_url(UID, PIN))
        self.assertEqual(tool.LABEL_CAPTION_CLAIM_QR, "Karekodu uygulamayla okutun")

    # ---- düzen: iki karekod net ayrılmış ------------------------------------------------------------------
    def test_layout_has_clear_headings_captions_and_security_note(self):
        drawn = self.drawn_texts(self.record())
        for heading in (tool.LABEL_HEADING_CLAIM, tool.LABEL_HEADING_WIFI):
            head, sub = tool._split_heading(heading)
            self.assertEqual(head + " " + sub, heading)
            self.assertDrawn(drawn, head)
            self.assertDrawn(drawn, sub)
        self.assertEqual(tool.LABEL_HEADING_CLAIM, "1) Daireye bağla (uygulama)")
        self.assertEqual(tool.LABEL_HEADING_WIFI, "2) Kurulum Wi-Fi'sine bağlan (telefon kamerası)")
        self.assertDrawn(drawn, tool.LABEL_CAPTION_CLAIM_QR)
        self.assertDrawn(drawn, tool.LABEL_CAPTION_WIFI_QR)
        self.assertDrawn(drawn, tool.LABEL_SECURITY_NOTE)
        self.assertIn("yalnızca cihaz üzerinde/elde saklanır", tool.LABEL_SECURITY_NOTE)
        self.assertIn("fotoğrafı paylaşılmaz", tool.LABEL_SECURITY_NOTE)
        self.assertIn("kurulum parolası ve PIN içerir", tool.LABEL_SECURITY_NOTE)

    def test_layout_places_the_two_codes_left_and_right_with_the_texts_in_between(self):
        record = self.record()
        box_claim, box_wifi = label_qr_boxes(tool, record)
        width, height = tool.LABEL_SIZE
        for box in (box_claim, box_wifi):
            self.assertGreaterEqual(box[0], 10)
            self.assertGreaterEqual(box[1], 50)  # başlık bandının altında
            self.assertLessEqual(box[2], width - 10)
            self.assertLessEqual(box[3], height - 60)  # güvenlik notu ve alt bilgi için yer kalır
        self.assertLess(box_claim[2], box_wifi[0])  # 1. karekod solda, 2. sağda; çakışmaz
        self.assertGreater(box_wifi[0] - box_claim[2], 200)  # aralarında metin sütunu var
        _left, middle, _right = tool.label_columns()
        for xy, text in self.drawn_texts(record):
            if text in ("AHBU-S3-DD8754", "AHBU-DD8754", "Kx7mPq2Wd9", MAC):  # orta sütun metinleri
                self.assertGreaterEqual(xy[0], middle[0])
                self.assertLessEqual(xy[0], middle[1])

    def test_longest_and_widest_ap_pass_stays_inside_the_text_column(self):
        wide = "WMwm" * 8  # 32 karakter, üretici alfabesindeki en geniş harflerle (araç yalnızca 10 karakterlik parola üretir)
        record = self.record(ap_pass=wide)
        _left, middle, _right = tool.label_columns()
        spied = []
        original = tool.ImageDraw.ImageDraw.text

        def spy(draw_self, xy, text, *args, **kwargs):
            spied.append((xy, text, draw_self.textlength(text, font=kwargs.get("font"))))
            return original(draw_self, xy, text, *args, **kwargs)

        with mock.patch.object(tool.ImageDraw.ImageDraw, "text", spy):
            tool.build_label_image(record)
        checked = 0
        for xy, text, width in spied:
            if text in (wide, UID, SSID, MAC):
                self.assertGreaterEqual(xy[0], middle[0], text)
                self.assertLessEqual(xy[0] + width, middle[1], text)  # QR sütununa taşmaz
                checked += 1
        self.assertEqual(checked, 4)

    def test_png_dpi_describes_the_real_label_size(self):
        image = self.png_roundtrip(tool.build_label_image(self.record()))
        dpi = image.info.get("dpi")
        self.assertIsNotNone(dpi)
        self.assertAlmostEqual(dpi[0], 203, delta=1)
        width_mm = tool.LABEL_SIZE[0] / tool.LABEL_DPI[0] * 25.4
        height_mm = tool.LABEL_SIZE[1] / tool.LABEL_DPI[1] * 25.4
        self.assertAlmostEqual(width_mm, 100, delta=1)  # 4 x 2 inç etiket
        self.assertAlmostEqual(height_mm, 50, delta=1)

    # ---- geçersiz veri: sessizce atlanmaz, çökmez ---------------------------------------------------------
    def test_invalid_wifi_data_shows_a_notice_instead_of_a_misleading_qr(self):
        record = self.record(ap_pass="kisa")
        self.assertIsNone(tool.label_wifi_qr_payload(record))
        drawn = self.drawn_texts(record)
        self.assertTrue(any("karekodu" in text or "karekodu" in self.fold(text).lower() for _xy, text in drawn))
        texts = [text for _xy, text in drawn]
        self.assertNotIn(tool.LABEL_CAPTION_WIFI_QR, texts)  # "okutun" yazısı yanıltıcı olurdu
        self.assertNotIn(self.fold(tool.LABEL_CAPTION_WIFI_QR), texts)
        image = self.png_roundtrip(tool.build_label_image(record))
        box_claim = label_qr_boxes(tool, record)[0]
        self.assertEqual(decode_qr_image(image, box_claim), fc.build_claim_url(UID, PIN))  # 1. karekod etkilenmez
        with self.assertRaises(QrDecodeError):
            decode_qr_image(image, label_qr_boxes(tool, record)[1])

    def test_label_without_system_fonts_still_has_both_codes(self):
        real_truetype = tool.ImageFont.truetype

        def no_system_fonts(font, *args, **kwargs):
            if isinstance(font, str):
                raise OSError("sistem yazi tipi yok")
            return real_truetype(font, *args, **kwargs)

        record = self.record()
        with mock.patch.object(tool.ImageFont, "truetype", no_system_fonts):
            image = tool.build_label_image(record)
        box_claim, box_wifi = label_qr_boxes(tool, record)
        self.assertEqual(decode_qr_image(image, box_wifi), fc.device_wifi_qr_payload(MAC, record.ap_pass))
        self.assertEqual(decode_qr_image(image, box_claim), fc.build_claim_url(UID, PIN))

    # ---- günlük/çıktı yok ---------------------------------------------------------------------------------
    def test_building_the_label_prints_and_logs_nothing(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            tool.build_label_image(self.record(ap_pass='Zq;9,x:Y"w\\K3'))
        self.assertEqual(out.getvalue() + err.getvalue(), "")

    def test_building_the_label_never_writes_to_disk(self):
        with mock.patch.object(tool.Image.Image, "save", side_effect=AssertionError("diske yazilamaz")), \
                mock.patch("builtins.open", side_effect=AssertionError("dosya acilamaz")):
            tool.build_label_image(self.record())

    def test_record_masks_the_wifi_payload_and_the_escaped_password(self):
        record = self.record(ap_pass='Zq;9,x:Y"w\\K3')
        scrubber = fc.SecretScrubber()
        scrubber.add(*record.secret_values())
        payload = fc.device_wifi_qr_payload(MAC, record.ap_pass)
        escaped = fc.escape_wifi_qr_value(record.ap_pass)
        for text in (payload, "x " + payload + " y", escaped, record.ap_pass, "P:" + escaped + ";;"):
            masked = scrubber.scrub(text)
            self.assertNotIn(record.ap_pass, masked)
            self.assertNotIn(escaped, masked)
        self.assertEqual(scrubber.scrub(payload), "***")
        record.wipe()
        self.assertEqual(record.secret_values(), ("", "", "", ""))  # silinince Wi-Fi karekod metni üretilemez


# ============================================================================================================
# Kaynak yapısı: Wi-Fi karekod metni yalnızca etiket görseline gider
# ============================================================================================================
class WifiPayloadFlowTests(unittest.TestCase):
    """Wi-Fi karekod metni AP parolasını taşır. Üretici fonksiyonlar yalnızca izinli yerlerde çağrılır: etiket görseli ve
    gizli değer listesi (maskeleme). Başka bir yerden (log, iletişim kutusu, dosya) çağrılması bu testi kırar."""

    # ad -> kullanılabileceği işlevler (boş küme: o dosyada hiç kullanılamaz)
    ALLOWED = {
        "ev_otomasyon_sistemi.py": {
            "device_wifi_qr_payload": {"label_wifi_qr_payload"},
            "label_wifi_qr_payload": {"build_label_image"},
            "make_qr_image": {"build_label_image"},
            "wifi_qr_payload": set(),
            "escape_wifi_qr_value": set(),
        },
        "factory_client.py": {
            "device_wifi_qr_payload": {"secret_values"},
            "escape_wifi_qr_value": {"wifi_qr_payload", "secret_values"},
            "wifi_qr_payload": {"device_wifi_qr_payload"},
            "label_wifi_qr_payload": set(),
            "make_qr_image": set(),
        },
    }

    @staticmethod
    def references(tree, names):
        """(ad, kapsayan işlev) çiftleri: tanım ve import satırları hariç, ad kullanımları."""
        found = []

        class Visitor(ast.NodeVisitor):
            def __init__(self):
                self.stack = []

            def visit_FunctionDef(self, node):
                self.stack.append(node.name)
                for child in node.body:
                    self.visit(child)
                self.stack.pop()

            visit_AsyncFunctionDef = visit_FunctionDef

            def visit_ImportFrom(self, node):
                return  # import satırları kullanım değildir

            def visit_Name(self, node):
                if node.id in names:
                    found.append((node.id, self.stack[-1] if self.stack else "<modül>"))

            def visit_Attribute(self, node):
                if node.attr in names:
                    found.append((node.attr, self.stack[-1] if self.stack else "<modül>"))
                self.generic_visit(node)

        Visitor().visit(tree)
        return found

    def test_payload_builders_are_only_used_where_allowed(self):
        for path in SOURCE_FILES:
            rules = self.ALLOWED[os.path.basename(path)]
            with open(path, encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            for name, where in self.references(tree, set(rules)):
                self.assertIn(where, rules[name], "%s: %s beklenmeyen yerde kullanılıyor (%s)" % (os.path.basename(path), name, where))

    def test_payload_builders_are_never_arguments_of_log_or_ui_functions(self):
        sinks = {"print", "say", "progress", "_prov_say", "log", "ui_info", "ui_warn", "ui_error", "ui_confirm",
                 "showinfo", "showwarning", "showerror", "askyesno", "debug", "info", "warning", "error", "exception"}
        secret_names = {"wifi_qr_payload", "device_wifi_qr_payload", "label_wifi_qr_payload", "wifi_payload", "make_qr_image"}
        for path in SOURCE_FILES:
            with open(path, encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            for node in ast.walk(tree):
                if not isinstance(node, ast.Call):
                    continue
                callee = node.func.id if isinstance(node.func, ast.Name) else getattr(node.func, "attr", "")
                if callee not in sinks:
                    continue
                for arg in list(node.args) + [keyword.value for keyword in node.keywords]:
                    used = {n.id for n in ast.walk(arg) if isinstance(n, ast.Name)} | {n.attr for n in ast.walk(arg) if isinstance(n, ast.Attribute)}
                    self.assertFalse(used & secret_names, "%s satır %d: Wi-Fi karekod metni log/UI işlevine veriliyor" % (os.path.basename(path), node.lineno))

    def test_tool_never_stores_the_payload_in_an_attribute_or_global(self):
        with open(SOURCE_FILES[0], encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                for target in node.targets:
                    if isinstance(target, ast.Attribute) and any(isinstance(n, ast.Name) and n.id == "wifi_payload" for n in ast.walk(node.value)):
                        self.fail("Wi-Fi karekod metni nesne alanında saklanıyor (satır %d)" % node.lineno)


if __name__ == "__main__":
    unittest.main()
