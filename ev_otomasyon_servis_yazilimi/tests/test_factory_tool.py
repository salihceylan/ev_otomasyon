# -*- coding: utf-8 -*-
"""
Fabrika/servis aracı duman testleri (donanımsız, internetsiz).

Çalıştırma:
    cd ev_otomasyon_servis_yazilimi && python -m unittest discover -s tests -v

Kapsam:
  (a) Tk kök penceresi withdraw() ile örneklenir; sekmeler/düğme geri çağrıları SAHTE ağ ile çağrılır
  (b) PIN üreticisi: 6 hane ve `secrets` kullanımı (random yok)
  (c) Etiket karekod içeriği: https://.../claim?uid=...&pin=...
  (d) Sunucu hata yanıtlarının Türkçe mesaja çevrilmesi (ham gövde sızmaz)
  (e) Provizyon çağrısı: doğru uç / başlık / gövde (sahte HTTP + gerçek loopback HTTP)
  (f) Kaynak taraması: sabit sır/parola/API anahtarı yok

Not: Gerçek ağ erişimi yasaktır (yalnızca 127.0.0.1 loopback'e izin verilir). Gerçek COM portu ve
esptool çalıştırılmaz. Test çıktısı cp1254 konsollarda bozulmasın diye ileti/ad metinlerinde emoji yoktur.
"""

import ast
import gc
import http.server
import io
import ipaddress
import json
import os
import re
import secrets as std_secrets
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from types import SimpleNamespace
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)
if TESTS_DIR not in sys.path:
    sys.path.insert(0, TESTS_DIR)

import factory_client as fc  # noqa: E402
from qr_decode import decode_qr_image, label_qr_boxes  # noqa: E402
from serial_fakes import FakeClock, FakeFirmwareCli, FakeSerialBackend  # noqa: E402
from wifi_qr_reference import reference_parse_wifi_qr  # noqa: E402

try:
    import ev_otomasyon_sistemi as tool  # noqa: E402

    TOOL_IMPORT_ERROR = tool._MISSING_DEPENDENCY
except Exception as _exc:  # noqa: BLE001 - ortam sorunu: arayüz testleri atlanır
    tool = None
    TOOL_IMPORT_ERROR = type(_exc).__name__

SOURCE_FILES = [
    os.path.join(TOOL_DIR, "ev_otomasyon_sistemi.py"),
    os.path.join(TOOL_DIR, "factory_client.py"),
]

# --- Test için çalışma anında üretilen SAHTE değerler (sabit sır değildir) --------------------------------
FAKE_PASSWORD = "pw-" + "q" * 14
ACCESS_1, REFRESH_1 = "acc-one-" + "a" * 20, "ref-one-" + "b" * 20
ACCESS_2, REFRESH_2 = "acc-two-" + "c" * 20, "ref-two-" + "d" * 20
FAKE_LOCAL_KEY = "TEST-KEY-1234567"          # sahte; firmware kuralı: 8-32 karakter, boşluksuz
MAC = "E8:F6:0A:DD:87:54"
UID = "AHBU-S3-DD8754"
SSID = "AHBU-DD8754"

_LOOPBACK_NAMES = {"127.0.0.1", "::1", "localhost"}
_REAL_CONNECT = socket.socket.connect
_REAL_GETADDRINFO = socket.getaddrinfo


def _guarded_connect(self, address):
    host = address[0] if isinstance(address, tuple) else address
    if str(host) not in _LOOPBACK_NAMES:
        raise AssertionError("Test gerçek ağa bağlanmaya çalıştı: %r" % (host,))
    return _REAL_CONNECT(self, address)


def _guarded_getaddrinfo(host, *args, **kwargs):
    if host is not None and str(host) not in _LOOPBACK_NAMES:
        raise AssertionError("Test gerçek DNS sorgusu yapmaya çalıştı: %r" % (host,))
    return _REAL_GETADDRINFO(host, *args, **kwargs)


_PATCHES = []


def setUpModule():
    for target, replacement in ((socket.socket, ("connect", _guarded_connect)), (socket, ("getaddrinfo", _guarded_getaddrinfo))):
        patcher = mock.patch.object(target, replacement[0], replacement[1])
        patcher.start()
        _PATCHES.append(patcher)


def tearDownModule():
    for patcher in reversed(_PATCHES):
        patcher.stop()
    _PATCHES.clear()


# ============================================================================================================
# Yardımcılar: sahte HTTP taşımaları
# ============================================================================================================
class FakeApi:
    """Sahte sunucu taşıması. İstekler `calls` listesine yazılır; yanıtlar `routes` ile belirlenir."""

    def __init__(self):
        self.calls = []
        self.routes = {}
        self.login_role = "super_user"
        self.set_default_routes()

    def set_default_routes(self):
        self.routes["POST /api/v1/auth/login"] = self._login
        self.routes["POST /api/v1/auth/logout"] = lambda call: (200, {"success": True, "message": "ok", "data": None}, {})
        self.routes["POST /api/v1/auth/refresh"] = lambda call: (
            200,
            {"success": True, "message": "ok", "data": {"access_token": ACCESS_2, "refresh_token": REFRESH_2}},
            {},
        )
        self.routes["POST /api/v1/admin/inventory/register"] = self._register
        self.routes["GET /api/v1/admin/inventory"] = lambda call: (
            200,
            {
                "success": True,
                "message": "ok",
                "data": {
                    "total": 2,
                    "stats": {"total": 2, "in_stock": 1, "claimed": 1, "suspended": 0, "revoked": 0},
                    "items": [
                        {"serial_no": 2, "device_uuid": UID, "mac_address": MAC, "model": "M", "status": "IN_STOCK", "created_at": "2026-10-01T10:00:00Z"},
                        {"serial_no": 1, "device_uuid": "AHBU-S3-000001", "mac_address": "AA:BB:CC:00:00:01", "model": "M", "status": "CLAIMED",
                         "created_at": "2026-09-30T10:00:00Z", "claimed_at": "2026-10-01T09:00:00Z"},
                    ],
                },
            },
            {},
        )

    def _login(self, call):
        if call.body and call.body.get("password") == FAKE_PASSWORD:
            return 200, {
                "success": True,
                "message": "Giriş başarılı.",
                "data": {
                    "access_token": ACCESS_1,
                    "refresh_token": REFRESH_1,
                    "token_type": "Bearer",
                    "expires_in": 900,
                    "user": {"id": "u-1", "email": call.body.get("email"), "full_name": "Test Yonetici", "role": self.login_role},
                    "homes": [],
                },
            }, {}
        return 401, {"success": False, "message": "E-posta veya şifre hatalı.", "code": "INVALID_CREDENTIALS"}, {}

    def _register(self, call):
        body = call.body or {}
        return 201, {
            "success": True,
            "message": "Cihaz envantere kaydedildi.",
            "data": {
                "device": {
                    "id": "d-1",
                    "serial_no": 7,
                    "device_uuid": body.get("device_uuid"),
                    "mac_address": body.get("mac_address"),
                    "model": body.get("model"),
                    "batch_no": body.get("batch_no"),
                    "status": "IN_STOCK",
                    "created_at": "2026-10-01T10:20:30.000Z",
                },
                "local_key": FAKE_LOCAL_KEY,
                "qr_claim_url": "https://evotomasyon.gudeteknoloji.com.tr/claim?uid=%s&pin=%s" % (body.get("device_uuid"), body.get("pin")),
            },
        }, {}

    def __call__(self, method, url, headers, body, timeout):
        parts = urllib.parse.urlsplit(url)
        call = SimpleNamespace(
            method=method,
            url=url,
            path=parts.path,
            query=parts.query,
            headers={k.lower(): v for k, v in headers.items()},
            body=json.loads(body.decode("utf-8")) if body else None,
            raw_body=body,
            timeout=timeout,
        )
        self.calls.append(call)
        handler = self.routes.get("%s %s" % (method, parts.path))
        if handler is None:
            status, payload, extra = 404, {"success": False, "message": "Yok", "code": "NOT_FOUND"}, {}
        else:
            status, payload, extra = handler(call)
        data = b"" if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8"))
        return fc.TransportResponse(status, {k.lower(): v for k, v in extra.items()}, data)

    def paths(self):
        return ["%s %s" % (c.method, c.path) for c in self.calls]


class FakeDevice:
    """Sahte cihaz (firmware yerel API'si, CONTRACTS §3). Ağ kesintisi `fail_network` ile simüle edilir."""

    def __init__(self, uid=UID, provisioned=False, accept_key=None):
        self.calls = []
        self.uid = uid
        self.provisioned = provisioned
        self.key = accept_key
        self.fail_network = set()  # örn. {"/api/auth/check"}
        self.fail_all = False
        self.init_error = None

    def __call__(self, method, url, headers, body, timeout):
        parts = urllib.parse.urlsplit(url)
        call = SimpleNamespace(
            method=method, url=url, host=parts.netloc, path=parts.path,
            headers={k.lower(): v for k, v in headers.items()},
            body=json.loads(body.decode("utf-8")) if body else None, timeout=timeout,
        )
        self.calls.append(call)
        if self.fail_all or parts.path in self.fail_network:
            raise fc.NetworkError("ag yok")

        def reply(status, payload):
            return fc.TransportResponse(status, {}, json.dumps(payload).encode("utf-8"))

        if parts.path == "/api/status":
            return reply(200, {"device": self.uid, "name": "AHBU", "fw": "1.1.0", "provisioned": self.provisioned, "wifi_connected": False})
        if parts.path == "/api/factory/init" and method == "POST":
            if self.init_error:
                return reply(*self.init_error)
            if self.provisioned:
                return reply(403, {"error": "already_provisioned"})
            self.provisioned, self.key = True, call.body["local_key"]
            return reply(200, {"status": "ok"})
        if parts.path == "/api/auth/check":
            if not self.provisioned:
                return reply(403, {"error": "unprovisioned"})
            if call.headers.get("x-device-key") != self.key:
                return reply(401, {"error": "unauthorized"})
            return reply(200, {"status": "ok"})
        return reply(404, {"error": "not_found"})


class LoopbackHttpServer:
    """Gerçek HTTP sunucusu (yalnızca 127.0.0.1): varsayılan taşıma katmanını uçtan uca sınamak için."""

    def __init__(self, handler):
        outer = self
        self.requests = []

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.0"

            def log_message(self, *args):
                return

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                request = SimpleNamespace(
                    method=self.command, path=self.path, raw=raw,
                    headers={k.lower(): v for k, v in self.headers.items()},
                    body=json.loads(raw.decode("utf-8")) if raw else None,
                )
                outer.requests.append(request)
                status, payload, headers = handler(request)
                data = b"" if payload is None else (payload if isinstance(payload, bytes) else json.dumps(payload).encode("utf-8"))
                try:
                    self.send_response(status)
                    for key, value in headers.items():
                        self.send_header(key, value)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except OSError:
                    pass  # istemci zaman aşımıyla bağlantıyı kapattı (beklenen durum)

            do_GET = do_POST = do_PATCH = do_DELETE = _handle

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join(timeout=5)


def make_client(api=None, **kwargs):
    api = api or FakeApi()
    scrubber = kwargs.pop("scrubber", fc.SecretScrubber())
    return fc.ServerClient(kwargs.pop("base_url", None), transport=api, env=kwargs.pop("env", {}), scrubber=scrubber, **kwargs), api


# ============================================================================================================
# (b) PIN / AP parolası üreticileri
# ============================================================================================================
class GeneratorTests(unittest.TestCase):
    def test_pin_is_always_six_digits(self):
        for _ in range(500):
            pin = fc.generate_setup_pin()
            self.assertRegex(pin, r"^\d{6}$")

    def test_pin_uses_secrets_and_zero_pads(self):
        with mock.patch.object(fc.secrets, "randbelow", return_value=42) as rb:
            self.assertEqual(fc.generate_setup_pin(), "000042")
        rb.assert_called_once_with(10 ** 6)

    def test_pin_does_not_touch_random_module(self):
        import random

        with mock.patch.object(random, "randint", side_effect=AssertionError("random kullanilamaz")), \
                mock.patch.object(random, "choice", side_effect=AssertionError("random kullanilamaz")), \
                mock.patch.object(random, "random", side_effect=AssertionError("random kullanilamaz")):
            self.assertRegex(fc.generate_setup_pin(), r"^\d{6}$")
            self.assertEqual(len(fc.generate_ap_pass()), 10)

    def test_pin_values_are_spread(self):
        values = {fc.generate_setup_pin() for _ in range(200)}
        self.assertGreater(len(values), 150)

    def test_ap_pass_length_and_alphabet(self):
        for _ in range(100):
            ap = fc.generate_ap_pass()
            self.assertEqual(len(ap), 10)
            self.assertTrue(set(ap) <= set(fc.AP_PASS_ALPHABET))
            self.assertTrue(fc.is_valid_ap_pass(ap))

    def test_ap_pass_has_no_confusable_characters(self):
        for ch in "0O1lIio":
            self.assertNotIn(ch, fc.AP_PASS_ALPHABET)

    def test_ap_pass_uses_secrets_choice(self):
        with mock.patch.object(fc.secrets, "choice", side_effect=lambda seq: seq[0]) as choice:
            self.assertEqual(fc.generate_ap_pass(), "A" * 10)
        self.assertEqual(choice.call_count, 10)

    def test_ap_pass_is_per_device_random(self):
        self.assertEqual(len({fc.generate_ap_pass() for _ in range(100)}), 100)

    def test_ap_pass_length_bounds(self):
        with self.assertRaises(ValueError):
            fc.generate_ap_pass(7)
        self.assertEqual(len(fc.generate_ap_pass(32)), 32)

    def test_uid_and_ssid_follow_firmware_rule(self):
        self.assertEqual(fc.uid_from_mac("e8:f6:0a:dd:87:54"), UID)
        self.assertEqual(fc.uid_from_mac("E8-F6-0A-DD-87-54"), UID)
        self.assertEqual(fc.ap_ssid_from_mac("e8f60add8754"), SSID)
        self.assertIsNone(fc.uid_from_mac("E8:F6:0A"))
        self.assertIsNone(fc.uid_from_mac("ZZ:F6:0A:DD:87:54"))
        self.assertIsNone(fc.ap_ssid_from_mac(None))

    def test_normalize_mac(self):
        self.assertEqual(fc.normalize_mac(" e8:f6:0a:dd:87:54 "), MAC)
        self.assertIsNone(fc.normalize_mac("E8:F6:0A:DD:87"))
        self.assertIsNone(fc.normalize_mac("E8F60ADD875"))
        self.assertIsNone(fc.normalize_mac(12345))

    def test_local_key_validation_matches_firmware(self):
        self.assertTrue(fc.is_valid_local_key(FAKE_LOCAL_KEY))
        self.assertFalse(fc.is_valid_local_key("short"))
        self.assertFalse(fc.is_valid_local_key("has space inside"))
        self.assertFalse(fc.is_valid_local_key("x" * 33))
        self.assertFalse(fc.is_valid_local_key(None))


# ============================================================================================================
# (c) Etiket karekod içeriği
# ============================================================================================================
class ClaimUrlTests(unittest.TestCase):
    def test_build_claim_url_format(self):
        url = fc.build_claim_url(UID, "123456")
        self.assertRegex(url, r"^https://[A-Za-z0-9.\-]+/claim\?uid=AHBU-[A-Z0-9-]+&pin=\d{6}$")
        self.assertEqual(url, "https://evotomasyon.gudeteknoloji.com.tr/claim?uid=%s&pin=123456" % UID)

    def test_parse_claim_url_round_trip(self):
        self.assertEqual(fc.parse_claim_url(fc.build_claim_url(UID, "000042")), (UID, "000042"))

    def test_parse_claim_url_rejects_malformed(self):
        bad = [
            "https://x.y/claim?uid=%s" % UID,                       # pin yok
            "https://x.y/claim?pin=123456",                          # uid yok
            "https://x.y/other?uid=%s&pin=123456" % UID,             # yol yanlis
            "https://x.y/claim?uid=%s&uid=%s&pin=123456" % (UID, UID),  # tekrar
            "https://x.y/claim?uid=%s&pin=12345" % UID,              # 5 hane
            "https://x.y/claim?uid=nope&pin=123456",                 # uid gecersiz
            "ftp://x.y/claim?uid=%s&pin=123456" % UID,
            "%s:123456" % UID,                                       # serbest metin
            "",
            None,
        ]
        for value in bad:
            self.assertIsNone(fc.parse_claim_url(value), value)

    def test_claim_url_matches_requires_same_uid_and_pin(self):
        url = fc.build_claim_url(UID, "123456")
        self.assertTrue(fc.claim_url_matches(url, UID, "123456"))
        self.assertTrue(fc.claim_url_matches(url, UID.lower(), "123456"))
        self.assertFalse(fc.claim_url_matches(url, UID, "654321"))
        self.assertFalse(fc.claim_url_matches(url, "AHBU-S3-AAAAAA", "123456"))


# ============================================================================================================
# Adres normalizasyonu
# ============================================================================================================
class AddressTests(unittest.TestCase):
    def test_server_url_default_and_variants(self):
        self.assertEqual(fc.normalize_server_url(None), fc.DEFAULT_SERVER_URL)
        self.assertEqual(fc.normalize_server_url(""), fc.DEFAULT_SERVER_URL)
        self.assertEqual(fc.normalize_server_url("evotomasyon.gudeteknoloji.com.tr"), fc.DEFAULT_SERVER_URL)
        self.assertEqual(fc.normalize_server_url("https://evotomasyon.gudeteknoloji.com.tr/api/v1/"), fc.DEFAULT_SERVER_URL)
        self.assertEqual(fc.normalize_server_url("https://evotomasyon.gudeteknoloji.com.tr/api"), fc.DEFAULT_SERVER_URL)
        self.assertEqual(fc.normalize_server_url("http://127.0.0.1:5000"), "http://127.0.0.1:5000")
        self.assertEqual(fc.normalize_server_url("http://localhost:5000/api"), "http://localhost:5000")

    def test_server_url_rejects_plain_http_for_remote_hosts(self):
        for value in ("http://evotomasyon.gudeteknoloji.com.tr", "http://192.168.1.20:5000", "http://10.0.2.2:5000"):
            with self.assertRaises(ValueError, msg=value):
                fc.normalize_server_url(value)

    def test_server_url_rejects_credentials_paths_and_garbage(self):
        for value in ("https://user:pw@evotomasyon.gudeteknoloji.com.tr", "https://x.y/foo", "https://x.y/?a=1", "ftp://x.y", "https://x.y:99999"):
            with self.assertRaises(ValueError, msg=value):
                fc.normalize_server_url(value)

    def test_device_host_accepts_only_local_addresses(self):
        self.assertEqual(fc.normalize_device_host(None), "192.168.4.1")
        self.assertEqual(fc.normalize_device_host("127.0.0.1:8081"), "127.0.0.1:8081")
        self.assertEqual(fc.normalize_device_host("10.0.2.2:8081"), "10.0.2.2:8081")
        self.assertEqual(fc.normalize_device_host("localhost:8081"), "localhost:8081")
        for value in ("8.8.8.8", "evil.example.com", "http://192.168.4.1", "192.168.4.1/api", "192.168.4.1:99999"):
            with self.assertRaises(ValueError, msg=value):
                fc.normalize_device_host(value)

    def test_env_overrides_are_validated(self):
        client = fc.ServerClient(env={fc.ENV_SERVER_URL: "http://127.0.0.1:5000"})
        self.assertEqual(client.base_url, "http://127.0.0.1:5000")
        with self.assertRaises(ValueError):
            fc.ServerClient(env={fc.ENV_SERVER_URL: "http://uzak-sunucu.example.com"})
        device = fc.DeviceClient(env={fc.ENV_DEVICE_HOST: "127.0.0.1:8081"})
        self.assertEqual(device.base_url, "http://127.0.0.1:8081")


# ============================================================================================================
# (d) Sunucu hata yanıtlarının Türkçe mesaja çevrilmesi
# ============================================================================================================
class ErrorTranslationTests(unittest.TestCase):
    def _error_for(self, status, payload, headers=None):
        api = FakeApi()
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (status, payload, headers or {})
        client, _ = make_client(api, env={fc.ENV_API_KEY: "k" * 40})  # sahte, yalnızca "kimlik doğrulanmış" olmak için
        client.use_api_key()
        with self.assertRaises(fc.ApiError) as ctx:
            client.request("GET", "/admin/inventory")
        return ctx.exception

    def test_401_variants(self):
        err = fc.friendly_api_error(401, "INVALID_CREDENTIALS")
        self.assertIn("hatalı", err)
        self.assertIn("süresi doldu", fc.friendly_api_error(401, "TOKEN_EXPIRED"))
        self.assertIn("geçersiz", fc.friendly_api_error(401, "INVALID_TOKEN"))
        self.assertIn("yeniden giriş", fc.friendly_api_error(401, None))

    def test_403_variants(self):
        self.assertIn("yetkiniz yok", fc.friendly_api_error(403, "FORBIDDEN"))
        self.assertIn("dondurulmuş", fc.friendly_api_error(403, "ACCOUNT_DISABLED"))
        self.assertIn("etkinleştirilmemiş", fc.friendly_api_error(403, "ACCOUNT_PENDING"))
        self.assertIn("yeniden doğrulama", fc.friendly_api_error(403, "REAUTH_REQUIRED"))

    def test_423_and_429_show_wait_time(self):
        self.assertIn("45 saniye", fc.friendly_api_error(423, "PIN_LOCKED", retry_after=45))
        self.assertIn("kilitlendi", fc.friendly_api_error(423, "PIN_LOCKED", retry_after=45))
        self.assertIn("Çok fazla", fc.friendly_api_error(429, "RATE_LIMITED", retry_after=30))
        self.assertIn("30 saniye", fc.friendly_api_error(429, "RATE_LIMITED", retry_after=30))
        self.assertIn("5 dakika", fc.friendly_api_error(429, "RATE_LIMITED", retry_after=300))
        self.assertIn("biraz sonra", fc.friendly_api_error(429, "RATE_LIMITED"))

    def test_5xx_never_shows_server_text(self):
        leaky = "duplicate key value violates unique constraint users_email_key SELECT * FROM users"
        for status in (500, 502, 503, 504):
            text = fc.friendly_api_error(status, "INTERNAL", leaky)
            self.assertNotIn("constraint", text)
            self.assertNotIn("SELECT", text)
            self.assertTrue(text.startswith("Sunucu"), text)
        self.assertIn("Hata ref: abc123def456", fc.friendly_api_error(500, "INTERNAL", None, error_ref="abc123def456"))
        self.assertNotIn("Hata ref", fc.friendly_api_error(500, "INTERNAL", None, error_ref="<script>"))

    def test_4xx_uses_only_safe_server_messages(self):
        self.assertEqual(fc.friendly_api_error(409, "CONFLICT", "Bu cihaz kimliği envanterde zaten kayıtlı."),
                         "Bu cihaz kimliği envanterde zaten kayıtlı.")
        self.assertEqual(fc.friendly_api_error(400, "VALIDATION", "Geçersiz MAC adresi."), "Geçersiz MAC adresi.")
        for hostile in ("<html><body>502</body></html>", '{"error":"x"}', "x" * 500, "violates foreign key constraint fk_x",
                        "at Object.<anonymous> (/srv/app/index.js:10:5)"):
            text = fc.friendly_api_error(400, "VALIDATION", hostile)
            self.assertNotIn(hostile, text)
            self.assertEqual(text, "Gönderilen bilgiler geçersiz. Alanları kontrol edin.")

    def test_redirect_and_misc_statuses(self):
        self.assertIn("yönlendirme", fc.friendly_api_error(302))
        self.assertIn("içerik türü", fc.friendly_api_error(415))
        self.assertIn("çok büyük", fc.friendly_api_error(413))
        self.assertIn("Kayıt bulunamadı", fc.friendly_api_error(404, "NOT_FOUND"))

    def test_client_translates_json_error_bodies(self):
        err = self._error_for(429, {"success": False, "message": "Too many", "code": "RATE_LIMITED"}, {"Retry-After": "120"})
        self.assertEqual(err.status, 429)
        self.assertEqual(err.code, "RATE_LIMITED")
        self.assertEqual(err.retry_after, 120)
        self.assertIn("2 dakika", str(err))

        err = self._error_for(423, {"success": False, "message": "locked", "code": "PIN_LOCKED", "retry_after": 60})
        self.assertIn("60 saniye", str(err))

        err = self._error_for(403, {"success": False, "message": "forbidden stuff", "code": "FORBIDDEN"})
        self.assertIn("yetkiniz yok", str(err))
        self.assertNotIn("forbidden stuff", str(err))

    def test_client_hides_raw_5xx_and_html_bodies(self):
        err = self._error_for(500, {"success": False, "message": "SQLSTATE 23505 pg_catalog leak", "code": "INTERNAL"}, {"X-Error-Ref": "0a1b2c3d4e5f"})
        self.assertNotIn("SQLSTATE", str(err))
        self.assertNotIn("pg_catalog", str(err))
        self.assertIn("0a1b2c3d4e5f", str(err))

        err = self._error_for(502, b"<html><h1>502 Bad Gateway</h1>nginx</html>")
        self.assertNotIn("nginx", str(err))
        self.assertNotIn("<html>", str(err))
        self.assertIn("Sunucu", str(err))

    def test_client_rejects_non_json_success_and_redirects(self):
        err = self._error_for(302, None, {"Location": "https://baska.example.com/"})
        self.assertIn("yönlendirme", str(err))
        api = FakeApi()
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (200, b"<html>login sayfasi</html>", {})
        client, _ = make_client(api, env={fc.ENV_API_KEY: "k" * 40})
        client.use_api_key()
        with self.assertRaises(fc.ApiError) as ctx:
            client.request("GET", "/admin/inventory")
        self.assertEqual(ctx.exception.code, "BAD_RESPONSE")
        self.assertNotIn("login sayfasi", str(ctx.exception))

    def test_network_errors_are_described_without_raw_text(self):
        import ssl
        import urllib.error

        cases = [
            (urllib.error.URLError(socket.timeout("zaman")), "zaman aşımı"),
            (urllib.error.URLError(socket.gaierror(11001, "getaddrinfo failed")), "DNS"),
            (urllib.error.URLError(ConnectionRefusedError(10061, "refused")), "reddetti"),
            (urllib.error.URLError(ssl.SSLCertVerificationError(1, "CERTIFICATE_VERIFY_FAILED secret-detail")), "sertifika"),
            (ConnectionResetError(10054, "reset"), "kesildi"),
            (OSError("beklenmedik ham metin"), "Sunucuya ulaşılamadı"),
        ]
        for exc, expected in cases:
            text = fc.describe_network_error(exc)
            self.assertIn(expected, text)
            self.assertNotIn("secret-detail", text)
            self.assertNotIn("beklenmedik ham metin", text)

    def test_provision_error_text_includes_ssid_hint(self):
        err = fc.ProvisionError("unreachable", "Cihaza ulaşılamadı.", hint="Bağlanın: {ssid}.")
        self.assertEqual(fc.provision_error_text(err, SSID), "Cihaza ulaşılamadı.\nBağlanın: %s." % SSID)
        self.assertIn("kurulum ağı", fc.provision_error_text(err, None))


# ============================================================================================================
# Sunucu istemcisi: kimlik doğrulama, refresh, API anahtarı
# ============================================================================================================
class ServerClientTests(unittest.TestCase):
    def test_login_posts_credentials_without_auth_header(self):
        client, api = make_client()
        user = client.login("  teknisyen@example.com ", FAKE_PASSWORD)
        call = api.calls[0]
        self.assertEqual((call.method, call.path), ("POST", "/api/v1/auth/login"))
        self.assertEqual(call.body, {"email": "teknisyen@example.com", "password": FAKE_PASSWORD})
        self.assertNotIn("authorization", call.headers)
        self.assertNotIn("x-api-key", call.headers)
        self.assertEqual(call.headers["content-type"].split(";")[0], "application/json")
        self.assertTrue(client.is_authenticated)
        self.assertEqual(client.auth_mode, "jwt")
        self.assertEqual(user["role"], "super_user")

    def test_password_is_never_retained(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        client.request("GET", "/admin/inventory")
        client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        self.assertNotIn(FAKE_PASSWORD, repr(vars(client)))
        for call in api.calls[1:]:
            self.assertNotIn(FAKE_PASSWORD, json.dumps(call.headers))
            self.assertNotIn(FAKE_PASSWORD, (call.raw_body or b"").decode("utf-8"))

    def test_wrong_password_gives_turkish_message(self):
        client, _ = make_client()
        with self.assertRaises(fc.ApiError) as ctx:
            client.login("a@example.com", "yanlis-parola")
        self.assertEqual(ctx.exception.status, 401)
        self.assertIn("hatalı", str(ctx.exception))
        self.assertFalse(client.is_authenticated)

    def test_login_requires_both_fields(self):
        client, api = make_client()
        for email, pwd in (("", "x"), ("a@example.com", "")):
            with self.assertRaises(fc.FactoryError):
                client.login(email, pwd)
        self.assertEqual(api.calls, [])

    def test_non_super_user_is_rejected_and_session_revoked(self):
        client, api = make_client()
        api.login_role = "service_user"
        with self.assertRaises(fc.ApiError) as ctx:
            client.login("a@example.com", FAKE_PASSWORD)
        self.assertEqual(ctx.exception.status, 403)
        self.assertIn("süper kullanıcı", str(ctx.exception))
        self.assertFalse(client.is_authenticated)
        self.assertEqual(api.paths(), ["POST /api/v1/auth/login", "POST /api/v1/auth/logout"])
        self.assertEqual(api.calls[1].body, {"refresh_token": REFRESH_1})

    def test_register_sends_bearer_and_payload(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        result = client.register_device(uid=UID, mac=MAC, pin="123456", model="ESP32-S3-POE-ETH-8DI-8RO", batch_no="BATCH-2026-10")
        call = api.calls[-1]
        self.assertEqual((call.method, call.path), ("POST", "/api/v1/admin/inventory/register"))
        self.assertEqual(call.headers["authorization"], "Bearer " + ACCESS_1)
        self.assertEqual(call.body, {"device_uuid": UID, "mac_address": MAC, "pin": "123456", "model": "ESP32-S3-POE-ETH-8DI-8RO", "batch_no": "BATCH-2026-10"})
        self.assertEqual(result.local_key, FAKE_LOCAL_KEY)
        self.assertTrue(result.qr_from_server)
        self.assertTrue(fc.claim_url_matches(result.qr_claim_url, UID, "123456"))
        self.assertNotIn(FAKE_LOCAL_KEY, repr(result))
        self.assertTrue(all(isinstance(c.timeout, float) and c.timeout > 0 for c in api.calls))

    def test_register_falls_back_when_server_qr_is_missing_or_wrong(self):
        for bad_url in (None, "https://x.y/claim?uid=AHBU-S3-AAAAAA&pin=111111", "garbage"):
            client, api = make_client()
            client.login("a@example.com", FAKE_PASSWORD)
            original = api.routes["POST /api/v1/admin/inventory/register"]

            def patched(call, original=original, bad_url=bad_url):
                status, payload, headers = original(call)
                payload["data"]["qr_claim_url"] = bad_url
                return status, payload, headers

            api.routes["POST /api/v1/admin/inventory/register"] = patched
            result = client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
            self.assertFalse(result.qr_from_server)
            self.assertEqual(result.qr_claim_url, fc.build_claim_url(UID, "123456"))

    def test_register_without_local_key_is_an_error(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["POST /api/v1/admin/inventory/register"] = lambda call: (201, {"success": True, "data": {"device": {"device_uuid": UID}}}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        self.assertEqual(ctx.exception.code, "BAD_RESPONSE")

    def test_register_duplicate_conflict_message(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["POST /api/v1/admin/inventory/register"] = lambda call: (
            409, {"success": False, "message": "Bu cihaz kimliği envanterde zaten kayıtlı.", "code": "CONFLICT"}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        self.assertEqual(ctx.exception.status, 409)
        self.assertIn("zaten kayıtlı", str(ctx.exception))

    def test_token_expired_triggers_single_refresh_and_retry(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        state = {"n": 0}

        def inventory(call):
            state["n"] += 1
            if call.headers.get("authorization") == "Bearer " + ACCESS_1:
                return 401, {"success": False, "message": "exp", "code": "TOKEN_EXPIRED"}, {}
            return 200, {"success": True, "data": {"items": []}}, {}

        api.routes["GET /api/v1/admin/inventory"] = inventory
        data = client.request("GET", "/admin/inventory")
        self.assertEqual(data, {"items": []})
        self.assertEqual(api.paths()[1:], ["GET /api/v1/admin/inventory", "POST /api/v1/auth/refresh", "GET /api/v1/admin/inventory"])
        self.assertEqual(api.calls[2].body, {"refresh_token": REFRESH_1})
        self.assertEqual(api.calls[3].headers["authorization"], "Bearer " + ACCESS_2)
        # Refresh döndü: sonraki çağrı yeni belirteçle gider, tekrar refresh olmaz
        client.request("GET", "/admin/inventory")
        self.assertEqual(api.paths().count("POST /api/v1/auth/refresh"), 1)

    def test_403_never_triggers_refresh(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (403, {"success": False, "message": "x", "code": "FORBIDDEN"}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.request("GET", "/admin/inventory")
        self.assertEqual(ctx.exception.status, 403)
        self.assertNotIn("POST /api/v1/auth/refresh", api.paths())
        self.assertTrue(client.is_authenticated)

    def test_refresh_failure_closes_session(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (401, {"success": False, "message": "x", "code": "TOKEN_EXPIRED"}, {})
        api.routes["POST /api/v1/auth/refresh"] = lambda call: (401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}, {})
        with self.assertRaises(fc.SessionExpiredError):
            client.request("GET", "/admin/inventory")
        self.assertFalse(client.is_authenticated)

    def test_refresh_network_error_keeps_session(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (401, {"success": False, "message": "x", "code": "TOKEN_EXPIRED"}, {})

        def boom(call):
            raise fc.NetworkError("ag yok")

        api.routes["POST /api/v1/auth/refresh"] = boom
        with self.assertRaises(fc.NetworkError):
            client.request("GET", "/admin/inventory")
        self.assertTrue(client.is_authenticated)

    def test_invalid_token_closes_session_without_refresh(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}, {})
        with self.assertRaises(fc.SessionExpiredError):
            client.request("GET", "/admin/inventory")
        self.assertFalse(client.is_authenticated)
        self.assertNotIn("POST /api/v1/auth/refresh", api.paths())

    def test_request_without_session_is_refused_locally(self):
        client, api = make_client()
        with self.assertRaises(fc.SessionExpiredError):
            client.request("GET", "/admin/inventory")
        self.assertEqual(api.calls, [])

    def test_api_key_mode_uses_x_api_key_only(self):
        key = std_secrets.token_hex(20)  # 40 karakter, test için üretildi
        client, api = make_client(env={fc.ENV_API_KEY: key})
        self.assertTrue(client.api_key_available())
        client.use_api_key()
        self.assertEqual(client.auth_mode, "api_key")
        client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        call = api.calls[-1]
        self.assertEqual(call.headers["x-api-key"], key)
        self.assertNotIn("authorization", call.headers)
        self.assertNotIn(key, repr(vars(client).get("_user")))

    def test_api_key_must_be_long_enough(self):
        client, _ = make_client(env={fc.ENV_API_KEY: "k" * 31})
        self.assertFalse(client.api_key_available())
        with self.assertRaises(fc.FactoryError):
            client.use_api_key()
        client, _ = make_client(env={})
        with self.assertRaises(fc.FactoryError):
            client.use_api_key()

    def test_api_key_rejection_is_not_treated_as_expired_session(self):
        client, api = make_client(env={fc.ENV_API_KEY: "k" * 40})
        client.use_api_key()
        api.routes["GET /api/v1/admin/inventory"] = lambda call: (401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.request("GET", "/admin/inventory")
        self.assertNotIsInstance(ctx.exception, fc.SessionExpiredError)
        self.assertIn("API anahtarı", str(ctx.exception))

    def test_status_and_delete_need_jwt_not_api_key(self):
        client, api = make_client(env={fc.ENV_API_KEY: "k" * 40})
        client.use_api_key()
        for action in (lambda: client.update_status(UID, "SUSPENDED"), lambda: client.delete_device(UID)):
            with self.assertRaises(fc.ApiError) as ctx:
                action()
            self.assertEqual(ctx.exception.status, 403)
            self.assertIn("e-posta + parola", str(ctx.exception))
        self.assertEqual(api.calls, [])

    def test_status_and_delete_endpoints(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["PATCH /api/v1/admin/inventory/%s/status" % UID] = lambda call: (200, {"success": True, "data": {"status": "SUSPENDED"}}, {})
        api.routes["DELETE /api/v1/admin/inventory/%s" % UID] = lambda call: (200, {"success": True, "message": "silindi", "data": None}, {})
        client.update_status(UID.lower(), "SUSPENDED")
        client.delete_device(UID)
        self.assertEqual(api.calls[-2].body, {"status": "SUSPENDED"})
        self.assertEqual(api.paths()[-2:], ["PATCH /api/v1/admin/inventory/%s/status" % UID, "DELETE /api/v1/admin/inventory/%s" % UID])
        with self.assertRaises(fc.FactoryError):
            client.delete_device("../../etc/passwd")

    def test_list_inventory_query(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        client.list_inventory(limit=500, offset=-3, status="IN_STOCK")
        query = urllib.parse.parse_qs(api.calls[-1].query)
        self.assertEqual(query, {"limit": ["100"], "offset": ["0"], "status": ["IN_STOCK"]})

    def test_changing_server_address_drops_session(self):
        client, _ = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        self.assertFalse(client.set_base_url(fc.DEFAULT_SERVER_URL))
        self.assertTrue(client.is_authenticated)
        self.assertTrue(client.set_base_url("http://127.0.0.1:5000"))
        self.assertFalse(client.is_authenticated)

    def test_logout_clears_and_revokes(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        refresh = client.end_session_local()
        self.assertEqual(refresh, REFRESH_1)
        self.assertFalse(client.is_authenticated)
        client.revoke_refresh_token(refresh)
        self.assertEqual(api.paths()[-1], "POST /api/v1/auth/logout")

    def test_account_switch_revokes_previous_session(self):
        client, api = make_client()
        client.login("a@example.com", FAKE_PASSWORD)
        api.routes["POST /api/v1/auth/login"] = lambda call: (
            200, {"success": True, "data": {"access_token": ACCESS_2, "refresh_token": REFRESH_2,
                                            "user": {"email": "b@example.com", "role": "super_user"}}}, {})
        client.login("b@example.com", FAKE_PASSWORD)
        self.assertEqual(api.calls[-1].body, {"refresh_token": REFRESH_1})
        self.assertEqual(client.user_email, "b@example.com")

    def test_scrubber_masks_session_and_registration_secrets(self):
        scrubber = fc.SecretScrubber()
        client, _ = make_client(scrubber=scrubber)
        client.login("a@example.com", FAKE_PASSWORD)
        client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        text = "tok %s ref %s key %s" % (ACCESS_1, REFRESH_1, FAKE_LOCAL_KEY)
        masked = scrubber.scrub(text)
        for secret in (ACCESS_1, REFRESH_1, FAKE_LOCAL_KEY):
            self.assertNotIn(secret, masked)
        self.assertEqual(masked.count("***"), 3)
        client.end_session_local()
        self.assertIn(ACCESS_1, scrubber.scrub(ACCESS_1))  # oturum kapanınca izlenmez

    def test_record_repr_hides_secrets(self):
        record = fc.DeviceRecord(uid=UID, mac=MAC, pin="482915", local_key=FAKE_LOCAL_KEY, ap_pass="AP-TEST-12",
                                 qr_claim_url=fc.build_claim_url(UID, "482915"))
        text = repr(record) + str(record)
        for secret in ("482915", FAKE_LOCAL_KEY, "AP-TEST-12"):
            self.assertNotIn(secret, text)
        record.wipe()
        self.assertEqual((record.pin, record.local_key, record.ap_pass, record.qr_claim_url), ("", "", "", ""))
        self.assertEqual(record.state, "wiped")


# ============================================================================================================
# (e) Provizyon: doğru uç, başlık ve gövde
# ============================================================================================================
class DeviceProvisionTests(unittest.TestCase):
    AP_PASS = "AP-TEST-12"

    def make(self, **kwargs):
        device = FakeDevice(**kwargs)
        sleeps = []
        client = fc.DeviceClient(transport=device, env={}, sleep=sleeps.append)
        return client, device, sleeps

    def test_factory_init_request_shape(self):
        client, device, _ = self.make()
        client.factory_init(FAKE_LOCAL_KEY, self.AP_PASS)
        call = device.calls[0]
        self.assertEqual(call.method, "POST")
        self.assertEqual(call.url, "http://192.168.4.1/api/factory/init")
        self.assertEqual(call.headers["content-type"], "application/json")
        self.assertEqual(call.body, {"local_key": FAKE_LOCAL_KEY, "ap_pass": self.AP_PASS})
        self.assertNotIn("authorization", call.headers)
        self.assertNotIn("x-api-key", call.headers)

    def test_verify_uses_device_key_header(self):
        client, device, _ = self.make(provisioned=True, accept_key=FAKE_LOCAL_KEY)
        self.assertTrue(client.verify(FAKE_LOCAL_KEY))
        call = device.calls[0]
        self.assertEqual((call.method, call.url), ("GET", "http://192.168.4.1/api/auth/check"))
        self.assertEqual(call.headers["x-device-key"], FAKE_LOCAL_KEY)
        self.assertNotIn("authorization", call.headers)

    def test_full_provision_happy_path(self):
        client, device, _ = self.make()
        progress = []
        outcome = client.provision(FAKE_LOCAL_KEY, self.AP_PASS, expected_uid=UID, progress=progress.append)
        self.assertTrue(outcome.initialized and outcome.verified)
        self.assertFalse(outcome.needs_reconnect)
        self.assertEqual([(c.method, c.path) for c in device.calls],
                         [("GET", "/api/status"), ("POST", "/api/factory/init"), ("GET", "/api/auth/check")])
        self.assertEqual(outcome.device_uid, UID)
        self.assertEqual(outcome.firmware, "1.1.0")
        for line in progress:  # ilerleme metni gizli değer taşımaz
            self.assertNotIn(FAKE_LOCAL_KEY, line)
            self.assertNotIn(self.AP_PASS, line)
        self.assertTrue(all(c.timeout > 0 for c in device.calls))

    def test_init_ok_but_ap_restart_needs_reconnect(self):
        client, device, _ = self.make()
        device.fail_network = {"/api/auth/check"}  # AP WPA2'ye geçti, bilgisayar bağlantısı düştü
        outcome = client.provision(FAKE_LOCAL_KEY, self.AP_PASS, expected_uid=UID)
        self.assertTrue(outcome.initialized)
        self.assertFalse(outcome.verified)
        self.assertTrue(outcome.needs_reconnect)
        # Kullanıcı yeniden bağlanınca doğrulama başarılı olur
        device.fail_network = set()
        self.assertTrue(client.verify(FAKE_LOCAL_KEY))

    def test_unreachable_device_retries_and_explains(self):
        client, device, sleeps = self.make()
        device.fail_all = True
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS, status_attempts=3, retry_delay=2.0)
        self.assertEqual(ctx.exception.code, "unreachable")
        self.assertEqual(len(device.calls), 3)
        self.assertEqual(sleeps, [2.0, 2.0])
        text = fc.provision_error_text(ctx.exception, SSID)
        self.assertIn(SSID, text)
        self.assertIn("Wi-Fi", text)
        self.assertIn("AP ON", text)  # kurulum ağı kapandıysa seri komutla yeniden açılır
        self.assertNotIn("ag yok", text)

    def test_already_provisioned_with_other_key(self):
        client, device, _ = self.make(provisioned=True, accept_key="baska-anahtar-123")
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS)
        self.assertEqual(ctx.exception.code, "already_provisioned")
        self.assertIn("RESETKEY", ctx.exception.hint)
        self.assertNotIn("/api/factory/init", [c.path for c in device.calls])

    def test_already_provisioned_with_same_key_is_idempotent(self):
        client, device, _ = self.make(provisioned=True, accept_key=FAKE_LOCAL_KEY)
        outcome = client.provision(FAKE_LOCAL_KEY, self.AP_PASS)
        self.assertTrue(outcome.verified)
        self.assertNotIn("/api/factory/init", [c.path for c in device.calls])

    def test_wrong_board_is_detected_by_uid(self):
        client, device, _ = self.make(uid="AHBU-S3-AAAAAA")
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS, expected_uid=UID)
        self.assertEqual(ctx.exception.code, "uid_mismatch")
        self.assertNotIn("/api/factory/init", [c.path for c in device.calls])

    def test_device_error_mapping(self):
        cases = [
            ((403, {"error": "already_provisioned"}), "already_provisioned"),
            ((503, {"error": "busy"}), "busy"),
            ((400, {"error": "invalid_key"}), "rejected"),
            ((415, {"error": "unsupported_media_type"}), "rejected"),
            ((500, {"error": "boom"}), "unexpected"),
        ]
        for init_error, code in cases:
            client, device, _ = self.make()
            device.init_error = init_error
            with self.assertRaises(fc.ProvisionError) as ctx:
                client.factory_init(FAKE_LOCAL_KEY, self.AP_PASS)
            self.assertEqual(ctx.exception.code, code, init_error)

    def test_verify_error_mapping(self):
        client, device, _ = self.make(provisioned=True, accept_key="baska-anahtar-123")
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY)
        self.assertEqual(ctx.exception.code, "key_mismatch")
        client, device, _ = self.make(provisioned=False)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY)
        self.assertEqual(ctx.exception.code, "not_provisioned")

    def test_verify_locked_reports_wait(self):
        device = FakeDevice(provisioned=True, accept_key=FAKE_LOCAL_KEY)
        original = device.__call__

        def locked(method, url, headers, body, timeout):
            return fc.TransportResponse(423, {}, json.dumps({"error": "locked", "retry_after": 60}).encode())

        client = fc.DeviceClient(transport=locked, env={}, sleep=lambda s: None)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY)
        self.assertEqual(ctx.exception.code, "locked")
        self.assertIn("60 saniye", ctx.exception.hint)
        self.assertIsNotNone(original)

    def test_verify_retries_network_errors(self):
        client, device, sleeps = self.make(provisioned=True, accept_key=FAKE_LOCAL_KEY)
        device.fail_network = {"/api/auth/check"}
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY, attempts=4, delay=1.5)
        self.assertEqual(ctx.exception.code, "unreachable")
        self.assertEqual(len(device.calls), 4)
        self.assertEqual(sleeps, [1.5, 1.5, 1.5])

    def test_provision_rejects_invalid_values_before_any_request(self):
        client, device, _ = self.make()
        for key, ap in (("short", self.AP_PASS), (FAKE_LOCAL_KEY, "short")):
            with self.assertRaises(fc.ProvisionError):
                client.provision(key, ap)
        self.assertEqual(device.calls, [])

    def test_manual_instructions_cover_fallback(self):
        text = fc.manual_provision_instructions(SSID)
        for needle in (SSID, "192.168.4.1", "RESETKEY", "AP ON", "Doğrula", "PAROLASIZ", "HEMEN", "Erase Flash"):
            self.assertIn(needle, text)
        self.assertNotIn(FAKE_LOCAL_KEY, text)

    def test_urgency_notice_warns_about_open_setup_network(self):
        text = fc.provision_urgency_notice(SSID)
        self.assertIn(SSID, text)
        self.assertIn("PAROLASIZ", text)
        self.assertIn("sahiplenebilir", text)
        self.assertIn("HEMEN", text)
        self.assertIn("AHBU-XXXXXX", fc.provision_urgency_notice())

    def test_wait_mode_polls_until_device_appears(self):
        client, device, sleeps = self.make()
        remaining = {"n": 3}
        original = device.__call__

        def flaky(method, url, headers, body, timeout):
            if urllib.parse.urlsplit(url).path == "/api/status" and remaining["n"] > 0:
                remaining["n"] -= 1
                raise fc.NetworkError("ag yok")
            return original(method, url, headers, body, timeout)

        client._transport = flaky
        progress = []
        outcome = client.provision(FAKE_LOCAL_KEY, self.AP_PASS, expected_uid=UID, wait_seconds=60, retry_delay=2.0, progress=progress.append)
        self.assertTrue(outcome.verified)
        self.assertEqual(sleeps, [2.0, 2.0, 2.0])
        self.assertTrue(any("aranıyor" in line for line in progress))
        self.assertEqual([c.path for c in device.calls if c.method == "POST"], ["/api/factory/init"])

    def test_wait_mode_gives_up_after_deadline(self):
        client, device, sleeps = self.make()
        device.fail_all = True
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS, wait_seconds=10, retry_delay=2.0)
        self.assertEqual(ctx.exception.code, "unreachable")
        self.assertEqual(len(device.calls), 6)  # 10 sn / 2 sn + 1 deneme
        self.assertEqual(len(sleeps), 5)

    def test_wait_mode_tolerates_foreign_http_server_but_normal_mode_does_not(self):
        def router_page(*args):
            return fc.TransportResponse(200, {}, b"<html>router giris</html>")

        client = fc.DeviceClient(transport=router_page, env={}, sleep=lambda s: None)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS)
        self.assertEqual(ctx.exception.code, "unexpected")
        self.assertIn("AHBU cihazı gibi yanıt vermedi", ctx.exception.message)
        sleeps = []
        client = fc.DeviceClient(transport=router_page, env={}, sleep=sleeps.append)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS, wait_seconds=6, retry_delay=2.0)
        self.assertEqual(ctx.exception.code, "unexpected")
        self.assertEqual(len(sleeps), 3)  # bekleme modunda tekrar denendi

    def test_status_payload_must_look_like_a_device(self):
        for payload in ({"device": UID}, {"provisioned": False}, {"device": 5, "provisioned": False}, {}):
            def transport(*args, p=payload):
                return fc.TransportResponse(200, {}, json.dumps(p).encode())

            client = fc.DeviceClient(transport=transport, env={})
            with self.assertRaises(fc.ProvisionError) as ctx:
                client.status()
            self.assertEqual(ctx.exception.code, "unexpected")

    def test_cancel_stops_waiting_without_touching_the_device(self):
        client, device, sleeps = self.make()
        device.fail_all = True
        cancel = threading.Event()

        def sleeper(seconds):
            sleeps.append(seconds)
            cancel.set()  # kullanıcı "iptal"e bastı

        client._sleep = sleeper
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.provision(FAKE_LOCAL_KEY, self.AP_PASS, wait_seconds=120, retry_delay=2.0, cancel=cancel)
        self.assertEqual(ctx.exception.code, "cancelled")
        self.assertEqual(len(device.calls), 1)
        self.assertNotIn("POST", [c.method for c in device.calls])
        cancel.set()
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY, cancel=cancel)
        self.assertEqual(ctx.exception.code, "cancelled")

    def test_documented_firmware_error_codes_are_mapped(self):
        cases = [
            ((409, {"error": "busy"}), "busy"),
            ((503, {"error": "queue_full"}), "busy"),
            ((503, {"error": "storage"}), "storage"),
            ((400, {"error": "invalid_json"}), "rejected"),
            ((400, {"error": "empty_body"}), "rejected"),
            ((400, {"error": "bad_host"}), "rejected"),
            ((403, {"error": "bad_origin"}), "rejected"),
            ((413, {"error": "too_large"}), "rejected"),
            ((415, {"error": "unsupported_media_type"}), "rejected"),
        ]
        for init_error, code in cases:
            client, device, _ = self.make()
            device.init_error = init_error
            with self.assertRaises(fc.ProvisionError) as ctx:
                client.factory_init(FAKE_LOCAL_KEY, self.AP_PASS)
            self.assertEqual(ctx.exception.code, code, init_error)
            self.assertNotIn("<", ctx.exception.message)
        client, device, _ = self.make()
        device.init_error = (503, {"error": "storage"})
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.factory_init(FAKE_LOCAL_KEY, self.AP_PASS)
        self.assertIn("Erase Flash", ctx.exception.hint)  # kullanıcıya ne yapacağı söylenir

    def test_error_ids_from_device_are_sanitized(self):
        def hostile(*args):
            return fc.TransportResponse(400, {}, json.dumps({"error": "<script>alert(1)</script>"}).encode())

        client = fc.DeviceClient(transport=hostile, env={}, sleep=lambda s: None)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.factory_init(FAKE_LOCAL_KEY, self.AP_PASS)
        self.assertNotIn("script", ctx.exception.message)

    def test_locked_reads_retry_after_header(self):
        def locked(*args):
            return fc.TransportResponse(423, {"retry-after": "75"}, json.dumps({"error": "locked"}).encode())

        client = fc.DeviceClient(transport=locked, env={}, sleep=lambda s: None)
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.verify(FAKE_LOCAL_KEY)
        self.assertEqual(ctx.exception.retry_after, 75)
        self.assertIn("75 saniye", ctx.exception.hint)


class LoopbackTransportTests(unittest.TestCase):
    """Varsayılan (urllib) taşıma katmanı gerçek HTTP ile: başlıklar/gövde/yönlendirme/zaman aşımı."""

    def test_device_provision_over_real_http(self):
        state = {"key": None}

        def firmware(request):
            if request.path == "/api/status":
                return 200, {"device": UID, "name": "AHBU", "fw": "1.1.0", "provisioned": state["key"] is not None, "wifi_connected": False}, {}
            if request.path == "/api/factory/init" and request.method == "POST":
                ctype = request.headers.get("content-type", "")
                if not ctype.startswith("application/json"):
                    return 415, {"error": "unsupported_media_type"}, {}
                state["key"] = request.body["local_key"]
                return 200, {"status": "ok"}, {}
            if request.path == "/api/auth/check":
                return (200, {"status": "ok"}, {}) if request.headers.get("x-device-key") == state["key"] else (401, {"error": "unauthorized"}, {})
            return 404, {"error": "not_found"}, {}

        with LoopbackHttpServer(firmware) as server:
            client = fc.DeviceClient("127.0.0.1:%d" % server.port, env={}, sleep=lambda s: None)
            outcome = client.provision(FAKE_LOCAL_KEY, "AP-TEST-12", expected_uid=UID)
        self.assertTrue(outcome.verified)
        init = [r for r in server.requests if r.path == "/api/factory/init"][0]
        self.assertEqual(init.method, "POST")
        self.assertEqual(init.headers["content-type"], "application/json")
        self.assertEqual(init.body, {"local_key": FAKE_LOCAL_KEY, "ap_pass": "AP-TEST-12"})
        self.assertEqual(init.headers["host"], "127.0.0.1:%d" % server.port)
        check = [r for r in server.requests if r.path == "/api/auth/check"][0]
        self.assertEqual(check.headers["x-device-key"], FAKE_LOCAL_KEY)

    def test_server_login_and_register_over_real_http(self):
        def api(request):
            if request.path == "/api/v1/auth/login":
                return 200, {"success": True, "data": {"access_token": ACCESS_1, "refresh_token": REFRESH_1,
                                                       "user": {"email": "a@example.com", "role": "super_user"}}}, {}
            if request.path == "/api/v1/admin/inventory/register":
                if request.headers.get("authorization") != "Bearer " + ACCESS_1:
                    return 401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}, {}
                return 201, {"success": True, "data": {"device": {"device_uuid": UID, "serial_no": 3}, "local_key": FAKE_LOCAL_KEY,
                                                       "qr_claim_url": fc.build_claim_url(UID, "123456")}}, {}
            return 404, {"success": False, "message": "yok", "code": "NOT_FOUND"}, {}

        with LoopbackHttpServer(api) as server:
            client = fc.ServerClient("http://127.0.0.1:%d" % server.port, env={})
            client.login("a@example.com", FAKE_PASSWORD)
            result = client.register_device(uid=UID, mac=MAC, pin="123456", model="M", batch_no="B")
        self.assertEqual(result.local_key, FAKE_LOCAL_KEY)
        self.assertEqual(server.requests[0].headers["user-agent"], fc.USER_AGENT)
        self.assertEqual(server.requests[0].headers["content-type"], "application/json; charset=utf-8")

    def test_redirects_are_not_followed(self):
        def api(request):
            return 302, None, {"Location": "http://baska-sunucu.example.invalid/api/v1/auth/login"}

        with LoopbackHttpServer(api) as server:
            client = fc.ServerClient("http://127.0.0.1:%d" % server.port, env={})
            with self.assertRaises(fc.ApiError) as ctx:
                client.login("a@example.com", FAKE_PASSWORD)
        self.assertEqual(ctx.exception.status, 302)
        self.assertIn("yönlendirme", str(ctx.exception))
        self.assertEqual(len(server.requests), 1)

    def test_oversized_response_is_refused(self):
        with LoopbackHttpServer(lambda request: (200, b"x" * 5000, {})) as server:
            client = fc.ServerClient("http://127.0.0.1:%d" % server.port, env={})
            with mock.patch.object(fc, "MAX_RESPONSE_BYTES", 1000):
                with self.assertRaises(fc.NetworkError) as ctx:
                    client.login("a@example.com", FAKE_PASSWORD)
        self.assertIn("büyük", str(ctx.exception))

    def test_timeout_is_enforced(self):
        def slow(request):
            time.sleep(2.5)
            return 200, {"success": True, "data": {}}, {}

        with LoopbackHttpServer(slow) as server:
            client = fc.ServerClient("http://127.0.0.1:%d" % server.port, env={}, timeout=0.3)
            started = time.monotonic()
            with self.assertRaises(fc.NetworkError) as ctx:
                client.login("a@example.com", FAKE_PASSWORD)
            self.assertLess(time.monotonic() - started, 2.0)
        self.assertIn("zaman aşımı", str(ctx.exception))

    def test_http_error_bodies_become_responses_not_exceptions(self):
        with LoopbackHttpServer(lambda request: (500, {"success": False, "message": "SQLSTATE leak", "code": "INTERNAL"}, {"X-Error-Ref": "aabbccddeeff"})) as server:
            client = fc.ServerClient("http://127.0.0.1:%d" % server.port, env={})
            with self.assertRaises(fc.ApiError) as ctx:
                client.login("a@example.com", FAKE_PASSWORD)
        self.assertEqual(ctx.exception.status, 500)
        self.assertNotIn("SQLSTATE", str(ctx.exception))
        self.assertIn("aabbccddeeff", str(ctx.exception))


# ============================================================================================================
# Flash yardımcıları: port / firmware / esptool doğrulaması
# ============================================================================================================
@unittest.skipIf(tool is None or TOOL_IMPORT_ERROR, "arayüz bağımlılıkları (tk/pyserial/qrcode/pillow) yok")
class FlashHelperTests(unittest.TestCase):
    def _image(self, directory, name="fw.bin", merged=True, size=80_000, magic=b"\xe9"):
        data = bytearray(size)
        data[0:1] = magic
        if merged:
            data[0x8000:0x8002] = b"\xaa\x50"
        path = os.path.join(directory, name)
        with open(path, "wb") as handle:
            handle.write(bytes(data))
        return path

    def test_serial_port_validation_windows(self):
        self.assertEqual(tool.validate_serial_port("com7", {"COM7"}, windows=True), "COM7")
        for bad in ("", None, "--help", "COM", "COM1 --baud 9", "COM7;calc", "/dev/ttyUSB0", "COM1000"):
            with self.assertRaises(tool.ToolError, msg=repr(bad)):
                tool.validate_serial_port(bad, None, windows=True)
        with self.assertRaises(tool.ToolError):
            tool.validate_serial_port("COM9", {"COM7"}, windows=True)

    def test_serial_port_validation_posix(self):
        self.assertEqual(tool.validate_serial_port("/dev/ttyUSB0", {"/dev/ttyUSB0"}, windows=False), "/dev/ttyUSB0")
        for bad in ("-x", "/etc/passwd", "COM3", "/dev/../etc/x"):
            with self.assertRaises(tool.ToolError, msg=bad):
                tool.validate_serial_port(bad, None, windows=False)

    def test_firmware_inspection(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = tool.inspect_firmware_file(self._image(tmp))
            self.assertEqual(good.warnings, [])
            self.assertTrue(os.path.isabs(good.path))
            app_only = tool.inspect_firmware_file(self._image(tmp, "app.bin", merged=False))
            self.assertEqual(len(app_only.warnings), 1)
            self.assertIn("BİRLEŞİK", app_only.warnings[0])
            for bad in (
                os.path.join(tmp, "yok.bin"),
                self._image(tmp, "kucuk.bin", size=1000),
                self._image(tmp, "bozuk.bin", magic=b"\x00"),
                self._image(tmp, "fw.txt"),
                "",
                None,
            ):
                with self.assertRaises(tool.ToolError, msg=str(bad)):
                    tool.inspect_firmware_file(bad)

    def test_firmware_inspection_detects_images_without_the_serial_provisioning_command(self):
        marker = tool.SERIAL_PROVISION_MARKER
        with tempfile.TemporaryDirectory() as tmp:
            stale = self._image(tmp, "eski.bin")  # birleşik ama FACTORYINIT yok: eski firmware
            fresh = self._image(tmp, "yeni.bin")
            with open(fresh, "r+b") as handle:
                handle.seek(0x9000)
                handle.write(marker)
            # varsayılan çağrı (Waveshare fabrika yazılımı gibi): komut aranmaz
            self.assertIsNone(tool.inspect_firmware_file(stale).supports_serial_provisioning)
            self.assertEqual(tool.inspect_firmware_file(stale).warnings, [])
            # AHBU firmware'i bekleniyorsa
            old = tool.inspect_firmware_file(stale, expect_serial_provisioning=True)
            self.assertIs(old.supports_serial_provisioning, False)
            self.assertEqual(len(old.warnings), 1)
            self.assertIn("FACTORYINIT", old.warnings[0])
            self.assertIn("ESKİ", old.warnings[0])
            new = tool.inspect_firmware_file(fresh, expect_serial_provisioning=True)
            self.assertIs(new.supports_serial_provisioning, True)
            self.assertEqual(new.warnings, [])
            # uygulama-only + eski imaj: iki ayrı uyarı
            both = tool.inspect_firmware_file(self._image(tmp, "ikisi.bin", merged=False), expect_serial_provisioning=True)
            self.assertEqual(len(both.warnings), 2)

    def test_esptool_discovery_validates_candidates(self):
        with tempfile.TemporaryDirectory() as tmp:
            good = os.path.join(tmp, "esptool.py")
            open(good, "w").close()
            wrong_name = os.path.join(tmp, "calc.py")
            open(wrong_name, "w").close()
            with mock.patch.dict(os.environ, {"ESPTOOL_PATH": good}):
                self.assertEqual(tool.find_esptool_command(), [sys.executable, good])
            for bad in (wrong_name, os.path.join(tmp, "yok", "esptool.py")):
                with mock.patch.dict(os.environ, {"ESPTOOL_PATH": bad}):
                    with self.assertRaises(tool.ToolError):
                        tool.find_esptool_command()

    def test_esptool_discovery_error_when_nothing_found(self):
        with mock.patch.dict(os.environ, {"ESPTOOL_PATH": ""}), \
                mock.patch.object(tool, "_platformio_core_dirs", return_value=[]), \
                mock.patch.object(tool.shutil, "which", return_value=None), \
                mock.patch.object(tool.importlib.util, "find_spec", return_value=None):
            with self.assertRaises(tool.ToolError) as ctx:
                tool.find_esptool_command()
        self.assertIn("pip install esptool", str(ctx.exception))

    def test_esptool_falls_back_to_python_module(self):
        with mock.patch.dict(os.environ, {"ESPTOOL_PATH": ""}), \
                mock.patch.object(tool, "_platformio_core_dirs", return_value=[]), \
                mock.patch.object(tool.shutil, "which", return_value=None), \
                mock.patch.object(tool.importlib.util, "find_spec", return_value=object()):
            self.assertEqual(tool.find_esptool_command(), [sys.executable, "-m", "esptool"])

    def test_version_helpers(self):
        self.assertEqual(tool.increment_version_str("1.0.1"), "1.0.2")
        self.assertEqual(tool.increment_version_str("abc"), "abc.1")
        self.assertEqual(tool.format_serial_badge(7), "#0007")
        self.assertEqual(tool.format_serial_badge(None), "#0001")
        self.assertEqual(tool.format_serial_badge("#12"), "#0012")


# ============================================================================================================
# (c) Etiket: karekod içeriği ve okunabilir metin
# ============================================================================================================
@unittest.skipIf(tool is None or TOOL_IMPORT_ERROR, "arayüz bağımlılıkları (tk/pyserial/qrcode/pillow) yok")
class LabelTests(unittest.TestCase):
    def record(self, **overrides):
        values = dict(uid=UID, mac=MAC, pin="482915", local_key=FAKE_LOCAL_KEY, ap_pass="AP-TEST-12",
                      qr_claim_url=fc.build_claim_url(UID, "482915"), serial_no=7, model="ESP32-S3-POE-ETH-8DI-8RO",
                      created_at="2026-10-01T10:20:30.000Z")
        values.update(overrides)
        return fc.DeviceRecord(**values)

    def test_qr_payload_is_claim_url_with_uid_and_pin(self):
        payload = tool.label_qr_payload(self.record())
        self.assertRegex(payload, r"^https://[^/]+/claim\?uid=AHBU-[A-Z0-9-]+&pin=\d{6}$")
        self.assertEqual(fc.parse_claim_url(payload), (UID, "482915"))

    def test_qr_payload_falls_back_when_server_url_is_inconsistent(self):
        payload = tool.label_qr_payload(self.record(qr_claim_url="https://x.y/claim?uid=AHBU-S3-AAAAAA&pin=000000"))
        self.assertEqual(payload, fc.build_claim_url(UID, "482915"))
        payload = tool.label_qr_payload(self.record(qr_claim_url=""))
        self.assertEqual(payload, fc.build_claim_url(UID, "482915"))

    def test_image_encodes_the_claim_url_first_and_the_wifi_qr_second(self):
        captured = []
        original = tool.qrcode.QRCode.add_data

        def spy(qr_self, data, optimize=20):
            captured.append(data)
            return original(qr_self, data, optimize)

        with mock.patch.object(tool.qrcode.QRCode, "add_data", spy):
            image = tool.build_label_image(self.record())
        # G3: etiket İKİ karekod taşır; 1. karekod (claim adresi) AYNEN kalır, AP parolası yalnızca 2. karekodda
        self.assertEqual(captured, [fc.build_claim_url(UID, "482915"), "WIFI:T:WPA;S:%s;P:AP-TEST-12;;" % SSID])
        self.assertNotIn("AP-TEST-12", captured[0])
        self.assertEqual(image.size, tool.LABEL_SIZE)
        self.assertEqual(image.mode, "RGB")

    def test_label_text_has_uid_pin_ssid_and_ap_pass_but_not_local_key(self):
        record = self.record()
        lines = tool.label_text_lines(record)
        values = dict(lines)
        self.assertEqual(values["CİHAZ SERİ NO (UID)"], UID)
        self.assertEqual(values["KURULUM PIN"], "482 915")
        self.assertEqual(values["KURULUM Wi-Fi AĞI"], SSID)
        self.assertEqual(values["AĞ PAROLASI (AP)"], "AP-TEST-12")
        self.assertEqual(values["MAC ADRESİ"], MAC)
        everything = json.dumps(lines, ensure_ascii=False) + tool.label_qr_payload(record)
        self.assertNotIn(FAKE_LOCAL_KEY, everything)
        self.assertNotIn("AP-TEST-12", tool.label_qr_payload(record))  # AP parolası karekodda değil, yalnız metinde

    def test_building_the_label_never_writes_to_disk(self):
        with mock.patch.object(tool.Image.Image, "save", side_effect=AssertionError("diske yazilamaz")), \
                mock.patch("builtins.open", side_effect=AssertionError("dosya acilamaz")):
            tool.build_label_image(self.record())

    def test_label_without_system_fonts_is_ascii_safe(self):
        real_truetype = tool.ImageFont.truetype

        def no_system_fonts(font, *args, **kwargs):
            if isinstance(font, str):  # dosya adıyla yazı tipi bulunamıyor (ör. Windows dışı)
                raise OSError("sistem yazi tipi yok")
            return real_truetype(font, *args, **kwargs)  # Pillow'un gömülü varsayılan yazı tipi

        drawn = []
        original_text = tool.ImageDraw.ImageDraw.text

        def spy(draw_self, xy, text, *args, **kwargs):
            drawn.append(text)
            return original_text(draw_self, xy, text, *args, **kwargs)

        with mock.patch.object(tool.ImageFont, "truetype", no_system_fonts), \
                mock.patch.object(tool.ImageDraw.ImageDraw, "text", spy):
            image = tool.build_label_image(self.record())
        self.assertEqual(image.size, tool.LABEL_SIZE)
        self.assertTrue(drawn)
        for text in drawn:  # Türkçe karakterler ASCII'ye indirgenir (kutucuk çıkmasın)
            self.assertTrue(all(ord(ch) < 128 for ch in text), text)


# ============================================================================================================
# (f) Kaynak taraması: sabit sır yok
# ============================================================================================================
SECRET_NAME = re.compile(r"(?i)(pass(?:word|wd)?|pwd|secret|api[_-]?key|token|bearer|credential)")
ENV_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")
HEADER_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)+$")
SECRET_HEADERS = {"x-api-key", "x-admin-api-key", "authorization", "x-device-key"}
RAW_PATTERNS = [
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.")),
    ("pem", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("aws", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("url-credentials", re.compile(r"https?://[^/\s:@]+:[^/\s@]+@")),
    ("uzun-hex", re.compile(r"(?<![0-9A-Za-z])[0-9a-fA-F]{32,}(?![0-9A-Za-z])")),
]


def _benign(value):
    if len(value) < 8:
        return True
    if re.search(r"[\s/:\\.]", value):
        return True  # cümle, yol, adres, dosya adı
    return bool(ENV_NAME.match(value) or HEADER_NAME.match(value))


def _high_entropy(value):
    return (
        len(value) >= 20
        and re.fullmatch(r"[A-Za-z0-9_\-+=]+", value) is not None
        and re.search(r"[a-z]", value) is not None
        and re.search(r"[A-Z]", value) is not None
        and re.search(r"\d", value) is not None
    )


def _target_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    if isinstance(node, ast.Subscript):
        index = node.slice
        if isinstance(index, ast.Constant) and isinstance(index.value, str):
            return index.value
    return ""


def scan_source_for_secrets(source):
    """Kaynakta sabit sır kalıplarını arar; bulguların (satır, tür) listesini döndürür (değerleri DEĞİL)."""
    findings = []
    tree = ast.parse(source)
    exempt = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if any("ALPHABET" in _target_name(t).upper() for t in targets) and isinstance(node.value, ast.Constant):
                exempt.add(id(node.value))
    for node in ast.walk(tree):
        if isinstance(node, (ast.Assign, ast.AnnAssign)) and isinstance(getattr(node, "value", None), ast.Constant):
            value = node.value.value
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            if isinstance(value, str) and id(node.value) not in exempt:
                for target in targets:
                    if SECRET_NAME.search(_target_name(target)) and not _benign(value):
                        findings.append((node.lineno, "ad-tabanlı sabit"))
                    if isinstance(target, ast.Subscript) and _target_name(target).lower() in SECRET_HEADERS and value:
                        findings.append((node.lineno, "başlık sabiti"))
        elif isinstance(node, ast.Dict):
            for key, value in zip(node.keys, node.values):
                if isinstance(key, ast.Constant) and isinstance(key.value, str) and isinstance(value, ast.Constant) and isinstance(value.value, str):
                    if SECRET_NAME.search(key.value) and not _benign(value.value):
                        findings.append((node.lineno, "sözlük sabiti"))
                    if key.value.lower() in SECRET_HEADERS and value.value and not value.value.endswith(" "):
                        findings.append((node.lineno, "başlık sabiti"))
        elif isinstance(node, ast.keyword):
            if node.arg and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                if SECRET_NAME.search(node.arg) and not _benign(node.value.value):
                    findings.append((node.value.lineno, "parametre sabiti"))
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in exempt:
            if _high_entropy(node.value):
                findings.append((node.lineno, "yüksek entropili sabit"))
    for number, line in enumerate(source.splitlines(), 1):
        for name, pattern in RAW_PATTERNS:
            if pattern.search(line):
                findings.append((number, name))
    return sorted(set(findings))


class SourceScanTests(unittest.TestCase):
    def read(self, path):
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()

    def test_tool_sources_contain_no_hardcoded_secrets(self):
        for path in SOURCE_FILES:
            self.assertEqual(scan_source_for_secrets(self.read(path)), [], os.path.basename(path))

    def test_scanner_detects_synthetic_offenders(self):
        fake = "Xy" + "Zq" * 12 + "7k"  # çalışma anında üretilen sahte "sır" (kaynakta bulunmaz)
        offenders = [
            'API_KEY = "%s"' % fake,
            'server_password = "%s"' % fake,
            'headers = {"x-api-key": "%s"}' % fake,
            'headers = {"X-Admin-Api-Key": "%s"}' % fake,
            'session.headers["x-api-key"] = "%s"' % fake,
            'connect(password="%s")' % fake,
            'blob = "%s"' % fake,
            'cfg = {"password": "%s"}' % fake,
            'token = "Bearer%s"' % fake,
            'u = "https://admin:%s@example.com/x"' % ("s3cretValue" * 2),
        ]
        for source in offenders:
            self.assertTrue(scan_source_for_secrets(source), "bulunamadı: " + source.split("=")[0])
        benign = [
            'ENV_API_KEY = "ADMIN_API_KEY"',
            'headers = {"x-api-key": key, "Authorization": "Bearer " + token}',
            'label = "Parola kaydedilmez; yalnızca bu oturum için kullanılır."',
            'AP_PASS_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"',
            'header = "X-Device-Key"',
            'path = "/api/v1/auth/login"',
        ]
        for source in benign:
            self.assertEqual(scan_source_for_secrets(source), [], source)

    def test_no_shell_true_or_os_system(self):
        for path in SOURCE_FILES:
            tree = ast.parse(self.read(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.keyword) and node.arg == "shell":
                    self.assertFalse(isinstance(node.value, ast.Constant) and node.value.value is True, "kabuk (shell) kullanimi: " + os.path.basename(path))
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                    owner = node.func.value
                    if isinstance(owner, ast.Name) and owner.id == "os" and node.func.attr in ("system", "popen"):
                        self.fail("os.%s kullanimi: %s" % (node.func.attr, os.path.basename(path)))

    def test_random_module_is_never_imported(self):
        for path in SOURCE_FILES:
            tree = ast.parse(self.read(path))
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    self.assertNotIn("random", [a.name.split(".")[0] for a in node.names], os.path.basename(path))
                if isinstance(node, ast.ImportFrom):
                    self.assertNotEqual((node.module or "").split(".")[0], "random", os.path.basename(path))
            self.assertNotRegex(self.read(path), r"\brandom\.(randint|choice|random|randrange|sample|shuffle)\b")

    def test_tls_verification_is_never_disabled(self):
        for path in SOURCE_FILES:
            text = self.read(path)
            for forbidden in ("_create_unverified_context", "CERT_NONE", "check_hostname = False", "verify=False"):
                self.assertNotIn(forbidden, text, os.path.basename(path))

    def test_plain_http_urls_only_point_to_local_addresses(self):
        for path in SOURCE_FILES:
            for match in re.finditer(r"http://([A-Za-z0-9._\-]+)(?::\d+)?", self.read(path)):
                host = match.group(1)
                if host in ("localhost",):
                    continue
                try:
                    address = ipaddress.ip_address(host)
                except ValueError:
                    self.fail("http:// adresi yerel degil: %s (%s)" % (host, os.path.basename(path)))
                self.assertTrue(address.is_loopback or address.is_private, host)

    def test_old_header_name_is_gone(self):
        for path in SOURCE_FILES:
            self.assertNotIn("X-Admin-Api-Key", self.read(path), os.path.basename(path))
            self.assertNotIn("session_server_password", self.read(path), os.path.basename(path))

    def test_every_network_call_has_a_timeout(self):
        text = self.read(SOURCE_FILES[1])
        self.assertIn("timeout=timeout", text)
        self.assertGreater(fc.SERVER_TIMEOUT_S, 0)
        self.assertGreater(fc.DEVICE_TIMEOUT_S, 0)


# ============================================================================================================
# (a) Tk arayüzü: gizli pencere + sahte ağ ile tüm geri çağrılar
# ============================================================================================================
class DialogRecorder:
    """tkinter.messagebox yerine geçer: iletişim kutularını kaydeder, bloklamaz."""

    def __init__(self):
        self.calls = []
        self.confirm = True

    def _record(self, kind, title, text):
        self.calls.append((kind, str(title), str(text)))
        return "ok"

    def showinfo(self, title=None, message=None, **kw):
        return self._record("info", title, message)

    def showwarning(self, title=None, message=None, **kw):
        return self._record("warning", title, message)

    def showerror(self, title=None, message=None, **kw):
        return self._record("error", title, message)

    def askyesno(self, title=None, message=None, **kw):
        self._record("confirm", title, message)
        return self.confirm

    def of(self, kind):
        return [c for c in self.calls if c[0] == kind]

    def all_text(self):
        return "\n".join("%s|%s|%s" % c for c in self.calls)


class FakePopen:
    """subprocess.Popen yerine geçer: gerçek esptool/COM portu çalıştırılmaz."""

    instances = []
    lines = ["esptool v4.5.1", "Chip is ESP32-S3", "MAC: e8:f6:0a:dd:87:54", "Hard resetting via RTS pin..."]
    returncode_value = 0

    def __init__(self, args, **kwargs):
        self.args = list(args)
        self.kwargs = kwargs
        self.stdout = iter(list(type(self).lines))
        self.returncode = type(self).returncode_value
        self.killed = False
        type(self).instances.append(self)

    def wait(self, timeout=None):
        return self.returncode

    def kill(self):
        self.killed = True


class FakePort:
    def __init__(self, device, description):
        self.device = device
        self.description = description


@unittest.skipIf(tool is None or TOOL_IMPORT_ERROR, "arayüz bağımlılıkları (tk/pyserial/qrcode/pillow) yok")
class AppSmokeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dialogs = DialogRecorder()
        self.api = FakeApi()
        self.device = FakeDevice()
        self.secret_values = []
        self.serial_clock = FakeClock()
        self.firmware = FakeFirmwareCli(mac=MAC)  # USB-seri: kartın seri CLI'sı
        self.serial_backend = FakeSerialBackend(self.firmware, self.serial_clock)
        FakePopen.instances = []
        FakePopen.lines = ["esptool v4.5.1", "Chip is ESP32-S3", "MAC: e8:f6:0a:dd:87:54", "Hard resetting via RTS pin..."]
        FakePopen.returncode_value = 0

        # Gerçek sürüm dosyaları/dizinleri bozulmasın: geçici dizine yönlendirilir
        releases = os.path.join(self.tmp.name, "firmware_releases")
        os.makedirs(os.path.join(releases, "v1.0.1"))
        self.image = self._merged_image(os.path.join(releases, "v1.0.1", "firmware_v1.0.1.bin"))
        with open(os.path.join(releases, "version_info.json"), "w", encoding="utf-8") as handle:
            json.dump({"current_version": "1.0.1", "firmware_file": "v1.0.1/firmware_v1.0.1.bin"}, handle)
        patches = [
            mock.patch.object(tool, "RELEASES_DIR", releases),
            mock.patch.object(tool, "VERSION_FILE", os.path.join(releases, "version_info.json")),
            mock.patch.object(tool, "messagebox", self.dialogs),
            mock.patch.object(tool.subprocess, "Popen", FakePopen),
            mock.patch.object(tool, "find_esptool_command", return_value=[sys.executable, "esptool.py"]),
            mock.patch.object(tool.simpledialog, "askstring", return_value=""),
            mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=""),
            mock.patch.object(tool.filedialog, "askopenfilename", return_value=""),
            mock.patch.object(tool.ServerLoginDialog, "ask", return_value=None),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)

        try:
            self.app = tool.EvOtomasyonServisApp(
                transport=self.api,
                device_transport=self.device,
                synchronous=True,
                serial_backend=self.serial_backend,
                serial_clock=self.serial_clock,
            )
        except Exception as exc:  # noqa: BLE001
            if exc.__class__.__name__ == "TclError":
                self.skipTest("Tk penceresi oluşturulamadı (ekran yok): %s" % exc.__class__.__name__)
            raise
        self.app.withdraw()
        self.app.update()
        self.app.device._sleep = lambda seconds: None  # testlerde gerçek bekleme yok
        self.addCleanup(self._destroy_app)

    def _destroy_app(self):
        # Arka plan iş parçacıkları bitsin; Tk değişkenlerinin (Variable.__del__) çöp toplaması ARAYÜZ iş parçacığında
        # yapılsın: aksi halde bir çalışan iş parçacığında tetiklenen GC, ölü yorumlayıcıya Tcl çağrısı yapıp takılır.
        for thread in threading.enumerate():
            if thread.name in ("ev-worker", "ev-logout"):
                thread.join(timeout=5)
        try:
            self.app.destroy()
        except Exception:  # noqa: BLE001
            pass
        self.app = None
        gc.collect()

    @staticmethod
    def _merged_image(path, serial_cmd=True):
        """Birleşik (0x0) sahte imaj. ``serial_cmd``: güncel firmware gibi FACTORYINIT komut adını içerir."""
        data = bytearray(90_000)
        data[0] = 0xE9
        data[0x8000:0x8002] = b"\xaa\x50"
        if serial_cmd:
            marker = tool.SERIAL_PROVISION_MARKER
            data[0x9000:0x9000 + len(marker)] = marker
        with open(path, "wb") as handle:
            handle.write(bytes(data))
        return path

    def login_request(self):
        return tool.LoginRequest("password", fc.DEFAULT_SERVER_URL, "yonetici@example.com", FAKE_PASSWORD)

    def patch_login(self, request=None):
        patcher = mock.patch.object(tool.ServerLoginDialog, "ask", return_value=request or self.login_request())
        patcher.start()
        self.addCleanup(patcher.stop)

    def fill_form(self, mac=MAC, uid=UID, pin="482915", model="ESP32-S3-POE-ETH-8DI-8RO", batch="BATCH-2026-10"):
        for entry, value in ((self.app.inv_mac_entry, mac), (self.app.inv_uuid_entry, uid), (self.app.inv_pin_entry, pin),
                             (self.app.inv_model_entry, model), (self.app.inv_batch_entry, batch)):
            entry.delete(0, "end")
            entry.insert(0, value)

    def register(self):
        self.patch_login()
        self.fill_form()
        self.app.register_device_and_generate_label()
        record = self.app.current_record
        if record is not None:  # sızıntı denetimi için gizli değerler (kayıt silinince boşalır)
            # PIN, yerel anahtar, AP parolası, claim adresi + (G3) Wi-Fi karekod metni ve kaçışlı AP parolası
            self.secret_values = [value for value in record.secret_values() if value]
            self.firmware.watch = [record.local_key, record.ap_pass]
        return record

    def assert_no_callback_errors(self):
        self.assertEqual(self.app._callback_errors, [])

    def assert_no_secrets_shown(self):
        shown = "\n".join(
            [
                self.dialogs.all_text(),
                self.app.log_text.get("1.0", "end"),
                self.app.prov_log.get("1.0", "end"),
                self.app.prov_device_var.get(),
                self.app.prov_steps_var.get(),
                self.app.prov_warn_var.get(),
                self.app.inv_status_var.get(),
            ]
        )
        for secret in self.secret_values:
            self.assertTrue(secret)
            self.assertNotIn(secret, shown)

    # ---- iskelet --------------------------------------------------------------------------------------------
    def test_window_has_three_tabs_and_no_callback_errors(self):
        titles = [self.app.notebook.tab(i, "text") for i in range(self.app.notebook.index("end"))]
        self.assertEqual(len(titles), 3)
        self.assertIn("Provizyon", titles[2])
        self.assertIn("Giriş yapılmadı", self.app.lbl_session.cget("text"))
        self.assertEqual(str(self.app.btn_logout.cget("state")), "disabled")
        self.assert_no_callback_errors()

    def test_no_hardcoded_credentials_are_used_at_startup(self):
        self.assertFalse(self.app.client.is_authenticated)
        self.assertEqual(self.api.calls, [])  # açılışta sunucuya hiçbir istek gitmez
        self.assertEqual(self.dialogs.calls, [])

    def test_invalid_env_server_url_falls_back_with_warning(self):
        with mock.patch.dict(os.environ, {fc.ENV_SERVER_URL: "http://uzak.example.com"}):
            app = tool.EvOtomasyonServisApp(synchronous=True)
        try:
            app.withdraw()
            self.assertEqual(app.client.base_url, fc.DEFAULT_SERVER_URL)
            self.assertIn("[UYARI]", app.log_text.get("1.0", "end"))
        finally:
            app.destroy()

    # ---- (b) PIN / UID ---------------------------------------------------------------------------------------
    def test_pin_button_generates_six_digits_with_secrets(self):
        with mock.patch.object(fc.secrets, "randbelow", return_value=7) as rb:
            self.app.generate_random_pin()
        rb.assert_called_once()
        self.assertEqual(self.app.inv_pin_entry.get(), "000007")
        self.app.generate_random_pin()
        self.assertRegex(self.app.inv_pin_entry.get(), r"^\d{6}$")
        self.assertEqual(self.app.inv_pin_entry.cget("show"), "•")  # ekranda varsayılan gizli

    def test_uid_is_derived_from_mac_only(self):
        self.app.inv_mac_entry.insert(0, "e8:f6:0a:dd:87:54")
        self.app.generate_device_uuid()
        self.assertEqual(self.app.inv_uuid_entry.get(), UID)
        self.app.inv_mac_entry.delete(0, "end")
        self.app.inv_uuid_entry.delete(0, "end")
        self.app.generate_device_uuid()
        self.assertEqual(self.app.inv_uuid_entry.get(), "")
        self.assertEqual(len(self.dialogs.of("warning")), 1)

    # ---- Flasher ----------------------------------------------------------------------------------------------
    def test_ports_and_mode_selection(self):
        self.assertIn("COM7", self.app.port_combo.get())
        self.assertEqual(self.app.get_selected_port(), "COM7")
        self.app.mode_var.set("factory")
        self.app.apply_mode_selection()
        self.assertTrue(self.app.file_entry.get().endswith("ESP32-S3-POE-ETH-8DI-8RO.bin"))
        self.assertEqual(str(self.app.inc_ver_btn.cget("state")), "disabled")
        self.app.mode_var.set("custom")
        self.app.apply_mode_selection()
        self.assertTrue(self.app.file_entry.get().endswith("firmware_v1.0.1.bin"))

    def test_no_port_gives_warning(self):
        self.serial_backend.ports = []
        self.app.refresh_ports()
        self.assertEqual(self.app.get_selected_port(), None)
        self.app.start_flash()
        self.assertEqual(FakePopen.instances, [])
        self.assertEqual(len(self.dialogs.of("warning")), 1)

    def test_flash_runs_esptool_with_list_args_and_no_shell(self):
        self.app.start_flash()
        self.assertEqual(len(FakePopen.instances), 1)
        proc = FakePopen.instances[0]
        self.assertIsInstance(proc.args, list)
        self.assertEqual(proc.args[:2], [sys.executable, "esptool.py"])
        self.assertEqual(proc.args[2:], ["--chip", "esp32s3", "--port", "COM7", "--baud", "460800", "write_flash", "0x0", os.path.abspath(self.image)])
        self.assertIs(proc.kwargs.get("shell"), False)
        self.assertIn("Chip is ESP32-S3", self.app.log_text.get("1.0", "end"))
        self.assertEqual(len(self.dialogs.of("info")), 1)
        self.assertIn("3. sekme", self.dialogs.of("info")[0][2])
        self.assertFalse(self.app._esptool_busy)
        self.assertEqual(str(self.app.btn_flash.cget("state")), "normal")
        self.assert_no_callback_errors()

    def test_flash_failure_is_reported(self):
        FakePopen.returncode_value = 2
        self.app.start_flash()
        self.assertEqual(len(self.dialogs.of("error")), 1)
        self.assertIn("Hata Kodu: 2", self.app.log_text.get("1.0", "end"))
        self.assertFalse(self.app._esptool_busy)

    def test_flash_rejects_missing_or_wrong_file_before_launching(self):
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, os.path.join(self.tmp.name, "yok.bin"))
        self.app.start_flash()
        self.assertEqual(FakePopen.instances, [])
        self.assertEqual(len(self.dialogs.of("warning")), 1)

    def test_flash_warns_about_non_merged_image(self):
        data = bytearray(90_000)
        data[0] = 0xE9
        app_only = os.path.join(self.tmp.name, "app.bin")
        with open(app_only, "wb") as handle:
            handle.write(bytes(data))
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, app_only)
        self.dialogs.confirm = False
        self.app.start_flash()
        self.assertEqual(FakePopen.instances, [])
        self.assertIn("BİRLEŞİK", self.dialogs.of("confirm")[0][2])
        self.dialogs.confirm = True
        self.app.start_flash()
        self.assertEqual(len(FakePopen.instances), 1)

    def test_flash_warns_when_image_lacks_the_serial_provisioning_command(self):
        stale = self._merged_image(os.path.join(self.tmp.name, "eski.bin"), serial_cmd=False)
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, stale)
        self.dialogs.confirm = False
        self.app.start_flash()
        self.assertEqual(FakePopen.instances, [])  # kullanıcı vazgeçti: hiçbir şey yazılmadı
        warning = self.dialogs.of("confirm")[0]
        self.assertEqual(warning[1], "Firmware Uyarısı")
        self.assertIn("FACTORYINIT", warning[2])
        self.assertIn("ESKİ", warning[2])
        self.dialogs.confirm = True  # bilerek devam: engellenmez
        self.app.start_flash()
        self.assertEqual(len(FakePopen.instances), 1)

    def test_flash_of_the_vendor_original_firmware_does_not_look_for_the_ahbu_command(self):
        factory = self._merged_image(os.path.join(self.tmp.name, "orijinal.bin"), serial_cmd=False)
        self.app.mode_var.set("factory")
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, factory)
        self.dialogs.confirm = False
        self.app.start_flash()
        self.assertEqual(self.dialogs.of("confirm"), [])  # uyarı yok: Waveshare yazılımı AHBU komutlarını bilmez
        self.assertEqual(len(FakePopen.instances), 1)

    def test_flash_success_provisions_over_usb_automatically_and_waits_for_the_port(self):
        record = self.register()
        self.serial_backend.hidden_polls = 3  # kart yeniden başlarken USB portu kısa süre kaybolur
        self.dialogs.calls.clear()
        self.app.start_flash()
        self.assertEqual(record.state, "verified")  # MAC eşleşti: bekleyen provizyon USB (seri) ile yapıldı
        self.assertEqual(record.path, "serial")
        self.assertEqual(self.device.calls, [])  # kablosuz/HTTP yolu hiç kullanılmadı
        self.assertEqual(self.serial_backend.opened[0], ("COM7", 115200))  # flash ile AYNI port
        self.assertEqual((self.firmware.local_key, self.firmware.ap_pass), (FAKE_LOCAL_KEY, record.ap_pass))
        self.assertEqual(self.app.notebook.index("current"), 2)  # 3. sekmeye geçildi
        flash_info = [c for c in self.dialogs.of("info") if c[1] == "Başarılı"][0]
        for needle in ("USB (seri)", "OTOMATİK", "GEREKMEZ", "ÇIKARMAYIN"):
            self.assertIn(needle, flash_info[2])
        self.assertEqual(self.firmware.leaks, [])
        self.assert_no_secrets_shown()
        self.assert_no_callback_errors()

    def test_flash_with_other_board_does_not_provision_pending_record(self):
        record = self.register()
        FakePopen.lines = ["Chip is ESP32-S3", "MAC:                aa:bb:cc:00:11:22", "Hard resetting via RTS pin..."]
        self.dialogs.calls.clear()
        self.app.start_flash()
        self.assertEqual(record.state, "registered")
        self.assertEqual(self.device.calls, [])
        self.assertEqual(self.serial_backend.opened, [])  # USB-seri de başlatılmadı
        flash_info = [c for c in self.dialogs.of("info") if c[1] == "Başarılı"][0]
        self.assertIn("eşleşmiyor", flash_info[2])
        self.assertIn("AA:BB:CC:00:11:22", flash_info[2])

    def test_flash_without_pending_record_only_warns(self):
        self.app.start_flash()
        self.assertEqual(self.device.calls, [])
        self.assertEqual(self.serial_backend.opened, [])
        info = self.dialogs.of("info")[0]
        self.assertIn("PAROLASIZ", info[2])
        self.assertIn("AHBU-DD8754", info[2])  # SSID, esptool çıktısındaki MAC'ten türetildi
        self.assertIn("kaydedilmediyse", info[2])
        self.assertIn("Seri (USB) ile Provizyonla", info[2])

    def test_flash_without_visible_mac_still_checks_the_board_over_serial(self):
        record = self.register()
        FakePopen.lines = ["Hard resetting via RTS pin..."]
        self.firmware.mac = "AA:BB:CC:00:11:22"  # başka bir kart bağlı: seri STATUS'taki MAC kayıtla eşleşmiyor
        self.app.start_flash()
        self.assertEqual(record.state, "registered")
        self.assertNotIn("FACTORYINIT", self.firmware.commands)
        self.assertEqual(self.device.calls, [])
        self.assertIn("eşleşmiyor", self.dialogs.of("error")[-1][2])
        self.assertEqual(self.dialogs.of("confirm"), [])  # yanlış kart için yedek yol ÖNERİLMEZ

    # ---- G2: USB (seri) provizyon ------------------------------------------------------------------------
    def test_serial_button_writes_key_over_usb_and_never_touches_the_wifi_path(self):
        record = self.register()
        self.dialogs.calls.clear()
        self.app.start_serial_provision()
        self.assertEqual(record.state, "verified")
        self.assertEqual(record.path, "serial")
        self.assertEqual(self.device.calls, [])  # HTTP/Wi-Fi yolu hiç kullanılmadı
        self.assertEqual((self.firmware.local_key, self.firmware.ap_pass), (FAKE_LOCAL_KEY, record.ap_pass))
        self.assertEqual(self.serial_backend.opened, [("COM7", 115200)])
        self.assertTrue(self.serial_backend.all_closed())
        self.assertEqual(self.firmware.leaks, [])
        self.assertEqual(self.firmware.commands[0], "STATUS")
        self.assertEqual(self.firmware.commands[-1], "STATUS")  # doğrulama seri STATUS ile
        self.assertIn("USB seri", self.app.prov_device_var.get())
        for name in ("btn_prov_serial", "btn_prov_start", "btn_prov_verify"):
            self.assertEqual(str(getattr(self.app, name).cget("state")), "disabled", name)
        info = self.dialogs.of("info")[-1]
        self.assertIn("USB", info[2])
        self.assertIn("STATUS", info[2])
        self.assertIn("kablosuz ağdan geçmedi", self.app.prov_log.get("1.0", "end"))
        self.assert_no_secrets_shown()
        self.assert_no_callback_errors()

    def test_serial_mac_mismatch_blocks_writing_and_offers_no_fallback(self):
        record = self.register()
        self.firmware.mac = "AA:BB:CC:00:11:22"
        self.app.start_serial_provision()
        self.assertEqual(record.state, "registered")
        self.assertNotIn("FACTORYINIT", self.firmware.commands)
        self.assertIn("eşleşmiyor", self.dialogs.of("error")[-1][2])
        self.assertEqual(self.dialogs.of("confirm"), [])

    def test_serial_unavailable_explains_why_and_fallback_needs_confirmation(self):
        record = self.register()
        self.app._serial_backend = None
        self.app._serial_backend_error = "Bu Python ortamında pyserial bulunamadı. Araç yeni paket KURMAZ."
        self.dialogs.confirm = False
        self.app.start_serial_provision()
        self.assertEqual(record.state, "registered")
        self.assertEqual(self.device.calls, [])  # onay verilmedi: güvensiz yol ÇALIŞMAZ
        confirm = self.dialogs.of("confirm")[-1]
        for needle in ("GÜVENSİZ", "DÜZ HTTP", "pyserial"):
            self.assertIn(needle, confirm[2])
        self.assertIn("pyserial", self.dialogs.of("error")[-1][2])  # neden arayüzde söylenir
        # onay verilirse güvensiz yedek yol çalışır ve açıkça "wifi" olarak işaretlenir
        self.dialogs.confirm = True
        self.app.start_serial_provision()
        self.assertEqual(record.state, "verified")
        self.assertEqual(record.path, "wifi")
        self.assertEqual([c.path for c in self.device.calls], ["/api/status", "/api/factory/init", "/api/auth/check"])

    def test_missing_usb_port_offers_the_fallback_but_wrong_card_does_not(self):
        record = self.register()
        self.serial_backend.hidden_polls = 10 ** 9
        self.dialogs.confirm = False
        self.app.start_serial_provision()
        self.assertEqual(record.state, "registered")
        self.assertEqual(self.serial_backend.opened, [])
        self.assertIn("Seri port bulunamadı", self.dialogs.of("confirm")[-1][2])
        self.assertIn("Seri port bulunamadı", self.dialogs.of("error")[-1][2])

    def test_already_provisioned_card_offers_reset_and_retry(self):
        record = self.register()
        self.firmware.provisioned = True
        self.firmware.local_key = "ESKI-ANAHTAR-12345"
        self.dialogs.confirm = False
        self.app.start_serial_provision()
        self.assertEqual(record.state, "registered")
        self.assertNotIn("RESETKEY", self.firmware.commands)
        self.assertIn("SIFIRLAYIP", self.dialogs.of("confirm")[-1][2])
        self.assertEqual(self.firmware.local_key, "ESKI-ANAHTAR-12345")  # reddedilince dokunulmaz
        self.dialogs.confirm = True
        self.app.start_serial_provision()
        self.assertEqual(record.state, "verified")
        self.assertEqual(self.firmware.local_key, FAKE_LOCAL_KEY)
        self.assertLess(self.firmware.commands.index("RESETKEY"), self.firmware.commands.index("FACTORYINIT"))
        self.assert_no_secrets_shown()

    def test_firmware_err_codes_are_shown_in_turkish_dialogs(self):
        record = self.register()
        cases = (
            ("invalid_local_key", "yerel anahtarı reddetti"),
            ("invalid_ap_pass", "AP parolasını reddetti"),
            ("persist_failed", "kalıcı belleğe yazamadı"),
        )
        for code, needle in cases:
            self.firmware.force_error = code
            self.dialogs.calls.clear()
            self.app.start_serial_provision()
            error = self.dialogs.of("error")[-1]
            self.assertIn(needle, error[2], code)
            self.assertEqual(record.state, "registered")
            self.assertEqual(self.dialogs.of("confirm"), [], code)  # yedek yol bu hatalarla çözülmez: önerilmez
        self.assertFalse(self.firmware.provisioned)
        self.assert_no_secrets_shown()

    def test_serial_path_and_flash_exclude_each_other(self):
        self.register()
        self.app._esptool_busy = True
        self.app.start_serial_provision()
        self.assertEqual(self.serial_backend.opened, [])
        self.assertEqual(self.dialogs.of("info")[-1][1], "Meşgul")
        self.app._esptool_busy = False
        self.app._prov_busy = True
        self.app._prov_mode = "serial"
        self.app.start_read_info()
        self.assertEqual(FakePopen.instances, [])
        self.assertIn("USB (seri) provizyon sürüyor", self.dialogs.of("info")[-1][2])
        self.app._prov_busy = False
        self.app._prov_mode = ""

    def test_wifi_button_warns_about_the_insecure_path_before_doing_anything(self):
        self.register()
        self.dialogs.confirm = False
        self.app.btn_prov_start.invoke()
        self.assertEqual(self.device.calls, [])
        warning = self.dialogs.of("confirm")[-1]
        for needle in ("DÜZ HTTP", "dinleyebilir", "USB (seri)"):
            self.assertIn(needle, warning[2])
        self.dialogs.confirm = True
        self.app.btn_prov_start.invoke()
        self.assertTrue(self.device.calls)

    def test_button_labels_mark_the_recommended_and_the_insecure_path(self):
        self.assertIn("Önerilen", self.app.btn_prov_serial.cget("text"))
        self.assertIn("Seri (USB)", self.app.btn_prov_serial.cget("text"))
        self.assertIn("güvensiz", self.app.btn_prov_start.cget("text"))
        self.assertIn("Wi-Fi", self.app.btn_prov_verify.cget("text"))
        self.assertEqual(str(self.app.btn_prov_serial.cget("state")), "disabled")  # kayıt yokken kapalı

    def test_register_info_recommends_usb_and_explains_automatic_provisioning(self):
        self.register()
        info = self.dialogs.of("info")[0]
        for needle in ("USB (seri)", "OTOMATİK", "PAROLASIZ", "sahiplenebilir"):
            self.assertIn(needle, info[2])

    def test_serial_button_without_record_or_port(self):
        self.app.start_serial_provision()
        self.assertEqual(self.dialogs.of("warning")[-1][1], "Kayıt Yok")
        self.register()
        self.serial_backend.ports = []
        self.app.refresh_ports()
        self.app.start_serial_provision()
        self.assertEqual(self.dialogs.of("warning")[-1][1], "Port Seçilmedi")
        self.assertEqual(self.serial_backend.opened, [])

    def test_port_list_failure_is_explained_not_crashing(self):
        self.app._serial_backend = None
        self.app._serial_backend_error = "Bu Python ortamında pyserial bulunamadı. Araç yeni paket KURMAZ."
        self.app.refresh_ports()
        self.assertIn("bulunamadı", self.app.port_combo.get())
        self.assertIn("KURMAZ", self.app.log_text.get("1.0", "end"))
        self.assertIsNone(self.app.get_selected_port())
        self.assert_no_callback_errors()

    def test_esptool_runs_under_the_interpreter_that_has_pyserial_when_relay_is_used(self):
        relay = fc.RelayBackend(r"C:\pio\penv\Scripts\python.exe")
        self.app._serial_backend = relay
        with mock.patch.object(tool, "find_esptool_command", return_value=[sys.executable, "esptool.py"]):
            command = self.app.build_esptool_cmd(["--chip", "esp32s3", "chip_id"])
        self.assertEqual(command[0], relay.python)
        self.assertEqual(command[1:], ["esptool.py", "--chip", "esp32s3", "chip_id"])
        with mock.patch.object(tool, "find_esptool_command", return_value=["esptool.exe"]):
            self.assertEqual(self.app.build_esptool_cmd(["x"]), ["esptool.exe", "x"])  # ayrı exe'ye dokunulmaz

    def test_cancelled_provisioning_is_quiet(self):
        record = self.register()
        self.app._prov_busy = True
        self.app.cancel_provision()
        self.assertTrue(self.app._prov_cancel.is_set())
        errors_before = len(self.dialogs.of("error"))
        self.app._on_provision_done(record, None, fc.ProvisionError("cancelled", "İşlem iptal edildi."))
        self.assertEqual(len(self.dialogs.of("error")), errors_before)
        self.assertEqual(record.state, "registered")
        self.assertFalse(self.app._prov_busy)
        self.assertIn("iptal", self.app.prov_log.get("1.0", "end"))

    def test_provision_tab_shows_urgency_and_open_network_info(self):
        self.assertIn("PAROLASIZ", self.app.prov_warn_var.get())  # kayıt yokken de uyarı görünür
        self.register()
        self.assertIn(SSID, self.app.prov_warn_var.get())
        steps = self.app.prov_steps_var.get()
        for needle in ("USB (seri)", "OTOMATİK", "GEREKMEZ", "DÜZ HTTP", "Hafızayı Sil", "AP PAROLASI", "Wi-Fi ile Doğrula"):
            self.assertIn(needle, steps)
        self.assertIn("http://192.168.4.1", self.app.prov_device_var.get())  # yedek Wi-Fi adresi görünür

    def test_factory_firmware_mode_does_not_claim_ahbu_provisioning(self):
        record = self.register()
        self.app.mode_var.set("factory")
        self.app.apply_mode_selection()
        factory_image = self._merged_image(os.path.join(self.tmp.name, "ESP32-S3-POE-ETH-8DI-8RO.bin"))
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, factory_image)
        self.dialogs.calls.clear()
        self.app.start_flash()
        self.assertEqual(self.device.calls, [])  # AHBU provizyonu denenmez
        self.assertEqual(record.state, "registered")
        info = [c for c in self.dialogs.of("info") if c[1] == "Başarılı"][0]
        self.assertIn("Waveshare", info[2])
        self.assertNotIn("PAROLASIZ", info[2])

    def test_server_dates_are_shown_in_local_time(self):
        from datetime import datetime as dt

        expected = dt.fromisoformat("2026-10-01T10:20:30+00:00").astimezone().strftime("%d.%m.%Y %H:%M")
        self.assertEqual(tool._local_datetime_text("2026-10-01T10:20:30.000Z"), expected)
        self.assertEqual(self.app._format_server_date("2026-10-01T10:20:30Z"), expected)
        self.assertEqual(tool._local_datetime_text(None), "")
        self.assertEqual(tool._local_datetime_text("bozuk-tarih-degeri"), "bozuk-tarih-degeri"[:16])

    def test_duplicate_registration_explains_recovery(self):
        self.api.routes["POST /api/v1/admin/inventory/register"] = lambda call: (
            409, {"success": False, "message": "Bu cihaz kimliği envanterde zaten kayıtlı.", "code": "CONFLICT"}, {})
        self.assertIsNone(self.register())
        text = self.dialogs.of("error")[0][2]
        self.assertIn("yeniden gösterilemez", text)
        self.assertIn("Stokta", text)

    def test_timeout_kills_process(self):
        class SlowPopen(FakePopen):
            def __init__(self, args, **kwargs):
                super().__init__(args, **kwargs)

                def blocking():
                    while not self.killed:
                        time.sleep(0.01)
                    return
                    yield  # pragma: no cover

                self.stdout = blocking()

        with mock.patch.object(tool.subprocess, "Popen", SlowPopen):
            code, timed_out = tool.EvOtomasyonServisApp._run_process(["x"], 0.2, lambda line: None)
        self.assertTrue(timed_out)

    def test_chip_info_and_erase(self):
        self.app.start_read_info()
        self.assertEqual(FakePopen.instances[-1].args[-1], "chip_id")
        self.dialogs.confirm = False
        count = len(FakePopen.instances)
        self.app.start_erase()
        self.assertEqual(len(FakePopen.instances), count)  # onay verilmedi: çalışmaz
        self.dialogs.confirm = True
        self.app.start_erase()
        self.assertEqual(FakePopen.instances[-1].args[-1], "erase_flash")
        self.assert_no_callback_errors()

    def test_missing_esptool_is_a_clear_error(self):
        with mock.patch.object(tool, "find_esptool_command", side_effect=tool.ToolError("esptool bulunamadı.")):
            self.app.start_read_info()
        self.assertEqual(FakePopen.instances, [])
        self.assertIn("esptool bulunamadı", self.dialogs.of("error")[0][2])

    def test_busy_flag_blocks_parallel_serial_jobs(self):
        self.app._esptool_busy = True
        self.app.start_read_info()
        self.assertEqual(FakePopen.instances, [])
        self.assertEqual(len(self.dialogs.of("info")), 1)

    def test_read_mac_fills_form(self):
        self.app.read_mac_from_board()
        self.assertEqual(self.app.inv_mac_entry.get(), MAC)
        self.assertEqual(self.app.inv_uuid_entry.get(), UID)
        self.assertEqual(self.app.btn_read_mac.cget("text"), "📡 Karttan MAC Oku")
        self.assertEqual(FakePopen.instances[0].args[-1], "read_mac")
        self.assert_no_callback_errors()

    def test_read_mac_failure(self):
        FakePopen.lines = ["A fatal error occurred: Failed to connect to ESP32-S3"]
        FakePopen.returncode_value = 2
        self.app.read_mac_from_board()
        self.assertEqual(self.app.inv_mac_entry.get(), "")
        self.assertIn("Failed to connect", self.dialogs.of("error")[0][2])

    def test_version_increment_writes_only_to_patched_release_dir(self):
        self.app.inc_version()
        self.assertEqual(self.app.version_data["current_version"], "1.0.2")
        self.assertTrue(os.path.isfile(os.path.join(tool.RELEASES_DIR, "v1.0.2", "firmware_v1.0.2.bin")))
        with open(tool.VERSION_FILE, "r", encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["current_version"], "1.0.2")
        self.assertIn("v1.0.2", self.app.ver_label.cget("text"))

    def test_browse_sets_chosen_file(self):
        with mock.patch.object(tool.filedialog, "askopenfilename", return_value=self.image):
            self.app.browse_custom_file()
        self.assertEqual(self.app.file_entry.get(), os.path.normpath(self.image))

    # ---- Oturum / envanter -----------------------------------------------------------------------------------
    def test_inventory_refresh_needs_login(self):
        self.app.refresh_inventory_list()  # diyalog iptal (ask -> None)
        self.assertEqual(self.api.calls, [])
        self.assertFalse(self.app.client.is_authenticated)

    def test_login_then_list_populates_table(self):
        self.patch_login()
        self.app.login_clicked()
        self.assertTrue(self.app.client.is_authenticated)
        self.assertIn("yonetici@example.com", self.app.lbl_session.cget("text"))
        self.assertEqual(len(self.app.inv_tree.get_children()), 2)
        self.assertIn("Toplam: 2", self.app.inv_status_var.get())
        self.assertEqual(self.api.paths(), ["POST /api/v1/auth/login", "GET /api/v1/admin/inventory"])
        self.assertEqual(self.api.calls[1].headers["authorization"], "Bearer " + ACCESS_1)
        self.assert_no_callback_errors()

    def test_failed_login_shows_turkish_error_and_stays_logged_out(self):
        self.patch_login(tool.LoginRequest("password", fc.DEFAULT_SERVER_URL, "x@example.com", "yanlis"))
        self.app.login_clicked()
        self.assertFalse(self.app.client.is_authenticated)
        errors = self.dialogs.of("error")
        self.assertEqual(len(errors), 1)
        self.assertIn("hatalı", errors[0][2])
        self.assertIn("Giriş yapılmadı", self.app.lbl_session.cget("text"))

    def test_non_super_user_cannot_use_tool(self):
        self.api.login_role = "user"
        self.patch_login()
        self.app.login_clicked()
        self.assertFalse(self.app.client.is_authenticated)
        self.assertIn("süper kullanıcı", self.dialogs.of("error")[0][2])

    def test_api_key_login_path(self):
        key = std_secrets.token_hex(20)
        self.app.client._env = {fc.ENV_API_KEY: key}
        self.patch_login(tool.LoginRequest("api_key", fc.DEFAULT_SERVER_URL))
        self.app.login_clicked()
        self.assertEqual(self.app.client.auth_mode, "api_key")
        self.assertEqual(self.api.calls[-1].headers["x-api-key"], key)
        self.assertNotIn(key, self.app.lbl_session.cget("text"))
        self.assertNotIn(key, self.dialogs.all_text())

    def test_logout_clears_session_and_revokes(self):
        self.patch_login()
        self.app.login_clicked()
        self.app.logout_clicked()
        self.assertFalse(self.app.client.is_authenticated)
        self.assertEqual(len(self.app.inv_tree.get_children()), 0)
        self.assertEqual(self.api.paths()[-1], "POST /api/v1/auth/logout")
        self.assertEqual(self.api.calls[-1].body, {"refresh_token": REFRESH_1})

    def test_expired_session_message_and_relogin_prompt(self):
        self.patch_login()
        self.app.login_clicked()
        self.api.routes["GET /api/v1/admin/inventory"] = lambda call: (401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}, {})
        self.app.refresh_inventory_list()
        self.assertFalse(self.app.client.is_authenticated)
        self.assertIn("Giriş yapılmadı", self.app.lbl_session.cget("text"))

    def test_list_error_is_shown_without_raw_body(self):
        self.patch_login()
        self.app.login_clicked()
        self.api.routes["GET /api/v1/admin/inventory"] = lambda call: (500, {"success": False, "message": "SQLSTATE 23505", "code": "INTERNAL"}, {})
        self.app.refresh_inventory_list()
        text = self.app.inv_status_var.get()
        self.assertIn("Liste yüklenemedi", text)
        self.assertNotIn("SQLSTATE", text)

    def test_status_change_and_delete_flow(self):
        self.patch_login()
        self.app.login_clicked()
        self.api.routes["PATCH /api/v1/admin/inventory/%s/status" % UID] = lambda call: (200, {"success": True, "data": {"status": "SUSPENDED"}}, {})
        self.api.routes["DELETE /api/v1/admin/inventory/%s" % UID] = lambda call: (200, {"success": True, "message": "silindi", "data": None}, {})
        first = self.app.inv_tree.get_children()[0]
        self.app.inv_tree.selection_set(first)
        self.app.suspend_selected_device()
        self.assertIn("PATCH /api/v1/admin/inventory/%s/status" % UID, self.api.paths())
        self.app.inv_tree.selection_set(self.app.inv_tree.get_children()[0])  # liste yenilenince seçim temizlenir
        self.app.activate_selected_device()
        patches = [c for c in self.api.calls if c.method == "PATCH"]
        self.assertEqual([c.body for c in patches], [{"status": "SUSPENDED"}, {"status": "IN_STOCK"}])
        # Silme: yanlış UID yazılırsa yapılmaz, doğru yazılırsa yapılır
        self.app.inv_tree.selection_set(self.app.inv_tree.get_children()[0])
        with mock.patch.object(tool.simpledialog, "askstring", return_value="AHBU-S3-YANLIS"):
            self.app.delete_selected_device()
        self.assertFalse([c for c in self.api.calls if c.method == "DELETE"])
        self.app.inv_tree.selection_set(self.app.inv_tree.get_children()[0])
        with mock.patch.object(tool.simpledialog, "askstring", return_value=UID.lower()):
            self.app.delete_selected_device()
        self.assertEqual(len([c for c in self.api.calls if c.method == "DELETE"]), 1)
        self.assert_no_callback_errors()

    def test_actions_without_selection_inform_user(self):
        self.patch_login()
        self.app.login_clicked()
        for action in (self.app.suspend_selected_device, self.app.activate_selected_device, self.app.delete_selected_device):
            action()
        self.assertEqual(len(self.dialogs.of("info")), 3)
        self.assertFalse([c for c in self.api.calls if c.method in ("PATCH", "DELETE")])

    # ---- Kayıt + etiket + gizli değerler ---------------------------------------------------------------------
    def test_register_flow_creates_record_label_and_hides_secrets(self):
        with mock.patch.object(tool.Image.Image, "save", side_effect=AssertionError("kayit sirasinda diske yazilamaz")):
            record = self.register()
        self.assertIsNotNone(record)
        self.assertEqual(record.local_key, FAKE_LOCAL_KEY)
        self.assertEqual(record.pin, "482915")
        self.assertEqual(record.uid, UID)
        self.assertEqual(record.ap_ssid, SSID)
        self.assertTrue(fc.is_valid_ap_pass(record.ap_pass) and len(record.ap_pass) == 10)
        self.assertEqual(record.state, "registered")
        self.assertTrue(fc.claim_url_matches(record.qr_claim_url, UID, "482915"))
        # İstek içeriği
        call = [c for c in self.api.calls if c.path.endswith("/register")][0]
        self.assertEqual(call.body, {"device_uuid": UID, "mac_address": MAC, "pin": "482915",
                                     "model": "ESP32-S3-POE-ETH-8DI-8RO", "batch_no": "BATCH-2026-10"})
        self.assertEqual(call.headers["authorization"], "Bearer " + ACCESS_1)
        # Etiket önizlemesi bellekte, kaydet/yazdır etkin
        self.assertIsNotNone(self.app.current_label_img)
        self.assertEqual(str(self.app.btn_save_label.cget("state")), "normal")
        self.assertIsNone(self.app.saved_label_path)
        # Gizli değerler iletişim kutularında / loglarda yok
        everything = self.dialogs.all_text() + self.app.log_text.get("1.0", "end") + self.app.prov_log.get("1.0", "end")
        for secret in (FAKE_LOCAL_KEY, "482915", record.ap_pass, ACCESS_1, REFRESH_1, FAKE_PASSWORD):
            self.assertNotIn(secret, everything)
        # Aynı PIN ikinci cihaza kalmasın
        self.assertNotEqual(self.app.inv_pin_entry.get(), "482915")
        self.assertRegex(self.app.inv_pin_entry.get(), r"^\d{6}$")
        # Provizyon sekmesi hazır
        self.assertIn(UID, self.app.prov_device_var.get())
        self.assertIn(SSID, self.app.prov_device_var.get())
        self.assertEqual(self.app.prov_key_var.get(), FAKE_LOCAL_KEY)
        self.assertEqual(str(self.app.btn_prov_start.cget("state")), "normal")
        self.assert_no_callback_errors()

    # ---- G3: etiketin 2. karekodu (kurulum Wi-Fi'si) -------------------------------------------------------------
    def decode_current_label(self, image=None):
        record = self.app.current_record
        image = image or self.app.current_label_img
        box_claim, box_wifi = label_qr_boxes(tool, record)
        return decode_qr_image(image, box_claim), decode_qr_image(image, box_wifi)

    def test_registered_label_has_two_qr_codes_and_the_wifi_qr_carries_the_ap_pass(self):
        record = self.register()
        claim, wifi = self.decode_current_label()
        self.assertEqual(claim, fc.build_claim_url(UID, "482915"))
        self.assertEqual(fc.parse_claim_url(claim), (UID, "482915"))
        self.assertEqual(wifi, "WIFI:T:WPA;S:%s;P:%s;;" % (SSID, record.ap_pass))  # üretilen parola kaçış gerektirmez
        parsed = reference_parse_wifi_qr(wifi)  # uygulamanın WifiQrParser kurallarıyla çözülür
        self.assertEqual((parsed.ssid, parsed.password, parsed.security), (SSID, record.ap_pass, "WPA"))
        self.assertNotIn(record.ap_pass, claim)  # AP parolası claim karekodunda YOK
        self.assertNotIn(FAKE_LOCAL_KEY, claim + wifi)  # yerel anahtar hiçbir karekodda yok
        self.assert_no_secrets_shown()
        self.assert_no_callback_errors()

    def test_register_with_special_character_ap_pass_end_to_end(self):
        special = 'Ab;c,d:e"f\\g 12'  # kaçış gerektiren her karakter (ters bölü ; , : ") + boşluk; firmware kuralına uyar
        self.assertTrue(fc.is_valid_ap_pass(special))
        with mock.patch.object(tool, "generate_ap_pass", return_value=special):
            record = self.register()
        self.assertEqual(record.ap_pass, special)
        claim, wifi = self.decode_current_label()
        self.assertEqual(wifi, r'WIFI:T:WPA;S:AHBU-DD8754;P:Ab\;c\,d\:e\"f\\g 12;;')
        parsed = reference_parse_wifi_qr(wifi)
        self.assertEqual((parsed.ssid, parsed.password), (SSID, special))
        self.assertNotIn(special, claim)
        # kaçışlı biçim ve tüm karekod metni de gizli değer sayılır: ekranda/log'da/iletişim kutusunda yok, maskelenir
        self.assertIn(fc.escape_wifi_qr_value(special), self.secret_values)
        self.assertIn(wifi, self.secret_values)
        self.assert_no_secrets_shown()
        self.assertEqual(self.app.scrubber.scrub(wifi), "***")
        self.assertNotIn(special, self.app.scrubber.scrub("parola: " + special))
        self.assert_no_callback_errors()

    def test_register_dialog_announces_two_qr_codes_and_label_secrecy(self):
        self.register()
        info = [call for call in self.dialogs.of("info") if call[1] == "Cihaz Envantere Eklendi!"][0]
        self.assertIn(tool.LABEL_HEADING_CLAIM, info[2])
        self.assertIn(tool.LABEL_HEADING_WIFI, info[2])
        self.assertIn("yalnızca cihaz üzerinde/elde saklanır", info[2])
        self.assertIn("fotoğrafı paylaşılmaz", info[2])

    def test_saved_label_png_has_two_decodable_qr_codes_and_the_real_size(self):
        record = self.register()
        saved = os.path.join(self.tmp.name, "etiket.png")
        with mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=saved):
            self.assertTrue(self.app.save_label_file())
        image = tool.Image.open(saved)
        image.load()
        self.assertEqual(image.size, tool.LABEL_SIZE)
        self.assertAlmostEqual(image.info["dpi"][0], 203, delta=1)  # 100 x 50 mm
        claim, wifi = self.decode_current_label(image.convert("RGB"))
        self.assertEqual(wifi, fc.device_wifi_qr_payload(MAC, record.ap_pass))
        self.assertEqual(fc.parse_claim_url(claim), (UID, "482915"))
        self.assertIn("2. karekod", self.dialogs.of("info")[-1][2])  # kaydedildi iletişim kutusu: gizlilik notu

    def test_label_preview_fits_the_preview_box(self):
        self.register()
        preview = self.app.label_canvas_img.image
        self.assertLessEqual(preview.width(), 420)
        self.assertLessEqual(preview.height(), 240)

    def test_register_validates_form_locally(self):
        self.patch_login()
        cases = [
            dict(mac="E8:F6"),
            dict(uid="HATALI"),
            dict(pin="12345"),
            dict(pin="abcdef"),
            dict(model="model;rm"),
            dict(batch="x" * 80),
        ]
        for overrides in cases:
            self.fill_form(**overrides)
            self.app.register_device_and_generate_label()
        self.assertEqual(self.api.calls, [])
        self.assertEqual(len(self.dialogs.of("warning")), len(cases))
        self.assertIsNone(self.app.current_record)

    def test_register_uid_mismatch_needs_confirmation(self):
        self.patch_login()
        self.fill_form(uid="AHBU-S3-ABCDEF")
        self.dialogs.confirm = False
        self.app.register_device_and_generate_label()
        self.assertEqual(self.api.calls, [])
        self.assertIn("MAC", self.dialogs.of("confirm")[0][2])

    def test_register_duplicate_shows_clear_message(self):
        self.api.routes["POST /api/v1/admin/inventory/register"] = lambda call: (
            409, {"success": False, "message": "Bu cihaz kimliği envanterde zaten kayıtlı.", "code": "CONFLICT"}, {})
        self.assertIsNone(self.register())
        error = self.dialogs.of("error")[0]
        self.assertIn("Mükerrer", error[1])
        self.assertIn("zaten kayıtlı", error[2])
        self.assertEqual(self.app._register_busy, False)
        self.assertEqual(str(self.app.btn_register_device.cget("state")), "normal")

    def test_register_server_error_hides_internal_details(self):
        self.api.routes["POST /api/v1/admin/inventory/register"] = lambda call: (
            500, {"success": False, "message": "insert into device_inventory violates constraint", "code": "INTERNAL"}, {})
        self.assertIsNone(self.register())
        text = self.dialogs.all_text()
        self.assertNotIn("violates", text)
        self.assertNotIn("device_inventory", text)

    def test_label_is_saved_only_on_explicit_request(self):
        record = self.register()
        saved = os.path.join(self.tmp.name, "etiket.png")
        self.assertEqual(os.listdir(self.tmp.name).count("etiket.png"), 0)
        with mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=saved):
            self.assertTrue(self.app.save_label_file())
        with open(saved, "rb") as handle:
            self.assertEqual(handle.read(8), b"\x89PNG\r\n\x1a\n")
        self.assertEqual(self.app.saved_label_path, saved)
        self.assertIn("silin", self.dialogs.of("info")[-1][2])
        # Kullanıcı vazgeçerse hiçbir şey yazılmaz
        other = os.path.join(self.tmp.name, "baska.png")
        with mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=""):
            self.assertFalse(self.app.save_label_file())
        self.assertFalse(os.path.exists(other))
        self.assertIsNotNone(record)

    def test_print_requires_explicit_save_first(self):
        self.register()
        sent = []
        with mock.patch.object(tool.os, "startfile", lambda path, verb: sent.append((path, verb)), create=True):
            self.app.print_label_file()  # kaydetme iletişim kutusu iptal -> yazdırılmaz
            self.assertEqual(sent, [])
            saved = os.path.join(self.tmp.name, "etiket.png")
            with mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=saved):
                self.app.print_label_file()
        if os.name == "nt":
            self.assertEqual(sent, [(saved, "print")])
        self.assertTrue(os.path.isfile(saved))

    def test_register_unwritable_save_path_gives_clear_error(self):
        self.register()
        bad = os.path.join(self.tmp.name, "olmayan-klasor", "etiket.png")
        with mock.patch.object(tool.filedialog, "asksaveasfilename", return_value=bad):
            self.assertFalse(self.app.save_label_file())
        self.assertIn("yazılamadı", self.dialogs.of("error")[-1][2])
        self.assertNotIn(bad, self.dialogs.of("error")[-1][2])

    def test_second_registration_requires_confirmation_when_unprovisioned(self):
        first = self.register()
        self.dialogs.confirm = False
        self.fill_form(mac="E8:F6:0A:DD:87:55", uid="AHBU-S3-DD8755")
        self.app.register_device_and_generate_label()
        self.assertIs(self.app.current_record, first)
        self.assertEqual(len([c for c in self.api.calls if c.path.endswith("/register")]), 1)
        self.dialogs.confirm = True
        self.app.register_device_and_generate_label()
        self.assertIsNot(self.app.current_record, first)
        self.assertEqual(first.state, "wiped")
        self.assertEqual(first.local_key, "")

    # ---- Provizyon -------------------------------------------------------------------------------------------
    def test_provision_success_marks_record_verified(self):
        record = self.register()
        self.app.start_provision()
        self.assertEqual(record.state, "verified")
        self.assertEqual([(c.method, c.path) for c in self.device.calls],
                         [("GET", "/api/status"), ("POST", "/api/factory/init"), ("GET", "/api/auth/check")])
        init = self.device.calls[1]
        self.assertEqual(init.body, {"local_key": FAKE_LOCAL_KEY, "ap_pass": record.ap_pass})
        self.assertEqual(init.url, "http://192.168.4.1/api/factory/init")
        self.assertEqual(init.headers["content-type"], "application/json")
        self.assertEqual(self.device.calls[2].headers["x-device-key"], FAKE_LOCAL_KEY)
        self.assertEqual(record.path, "wifi")
        self.assertIn("Provizyon doğrulandı", self.app.prov_device_var.get())
        self.assertIn("Wi-Fi", self.app.prov_device_var.get())
        self.assertEqual(str(self.app.btn_prov_start.cget("state")), "disabled")
        self.assertIn("doğrulandı", self.app.prov_log.get("1.0", "end"))
        # Sonuç alanı ve kutular gizli değer içermez
        shown = self.dialogs.all_text() + self.app.prov_log.get("1.0", "end") + self.app.log_text.get("1.0", "end")
        self.assertNotIn(FAKE_LOCAL_KEY, shown)
        self.assertNotIn(record.ap_pass, shown)
        self.assert_no_callback_errors()

    def test_provision_unreachable_gives_step_by_step_help(self):
        record = self.register()
        self.device.fail_all = True
        self.app.start_provision(wait_seconds=0)
        self.assertEqual(record.state, "registered")
        error = self.dialogs.of("error")[-1]
        self.assertIn("Cihaza ulaşılamadı", error[2])
        self.assertIn(SSID, error[2])
        self.assertIn("Elle Provizyon", error[2])
        self.assertNotIn("ag yok", error[2])
        self.assertEqual(str(self.app.btn_prov_start.cget("state")), "normal")  # yeniden denenebilir
        self.assertFalse(self.app._prov_busy)
        self.assertEqual(str(self.app.btn_prov_cancel.cget("state")), "disabled")

    def test_provision_reconnect_then_verify(self):
        record = self.register()
        self.device.fail_network = {"/api/auth/check"}
        self.app.start_provision()
        self.assertEqual(record.state, "init_sent")
        info = self.dialogs.of("info")[-1]
        self.assertIn(SSID, info[2])
        self.assertIn("AP PAROLASI", info[2])
        self.assertEqual(str(self.app.btn_prov_start.cget("state")), "disabled")
        self.assertEqual(str(self.app.btn_prov_verify.cget("state")), "normal")
        # Bilgisayar yeniden bağlandı
        self.device.fail_network = set()
        self.app.verify_provision()
        self.assertEqual(record.state, "verified")

    def test_verify_not_provisioned_allows_restart(self):
        record = self.register()
        record.state = "init_sent"
        self.app._refresh_provision_tab()
        self.app.verify_provision()  # cihaz hala provizyonsuz (403 unprovisioned)
        self.assertEqual(record.state, "registered")
        self.assertIn("provizyonsuz", self.dialogs.of("error")[-1][2])

    def test_provision_without_record(self):
        self.app.start_provision()
        self.app.verify_provision()
        self.assertEqual(self.device.calls, [])
        self.assertEqual(len(self.dialogs.of("warning")), 2)

    def test_manual_help_and_clipboard_helpers(self):
        record = self.register()
        self.app.show_manual_provision_help()
        self.assertIn("RESETKEY", self.dialogs.of("info")[-1][2])
        self.app.copy_local_key()
        self.assertEqual(self.app.clipboard_get(), FAKE_LOCAL_KEY)
        self.app.copy_ap_pass()
        self.assertEqual(self.app.clipboard_get(), record.ap_pass)
        self.app._clear_clipboard_if(record.ap_pass)
        with self.assertRaises(Exception):
            self.app.clipboard_get()  # pano temizlendi
        self.assertNotIn(FAKE_LOCAL_KEY, self.app.prov_log.get("1.0", "end"))

    def test_secret_entries_are_masked_until_revealed(self):
        self.register()
        entry = self.app._prov_secret_entries[0]
        self.assertEqual(entry.cget("show"), "•")
        self.app._prov_show_secrets.set(True)
        self.app._toggle_prov_secret_visibility()
        self.assertEqual(entry.cget("show"), "")

    def test_forget_record_wipes_memory(self):
        record = self.register()
        self.dialogs.confirm = False
        self.app.forget_record()  # onay verilmedi: silinmez
        self.assertEqual(record.state, "registered")
        self.dialogs.confirm = True
        self.app.forget_record()
        self.assertIsNone(self.app.current_record)
        self.assertEqual(record.local_key, "")
        self.assertIsNone(self.app.current_label_img)
        self.assertEqual(self.app.prov_key_var.get(), "")
        self.assertEqual(str(self.app.btn_save_label.cget("state")), "disabled")
        self.assertIn("Henüz kayıtlı cihaz yok", self.app.prov_device_var.get())

    def test_scrubber_masks_log_lines(self):
        record = self.register()
        self.app.log("sızdırma denemesi: %s ve %s" % (record.local_key, record.pin))
        text = self.app.log_text.get("1.0", "end")
        self.assertNotIn(record.local_key, text)
        self.assertNotIn(record.pin, text)
        self.assertIn("***", text)

    def test_results_for_a_wiped_record_are_ignored(self):
        record = self.register()
        record.wipe()  # kayıt, işlem sürerken bellekten silindi
        self.app._prov_busy = True
        self.app._on_provision_done(record, fc.ProvisionOutcome(initialized=True, verified=True), None)
        self.assertEqual(record.state, "wiped")  # "verified"a dönüşmez
        self.assertFalse(self.app._prov_busy)
        self.app._prov_busy = True
        self.app._on_verify_done(record, True, None)
        self.assertEqual(record.state, "wiped")
        self.assertFalse(self.app._prov_busy)
        self.assertEqual(self.dialogs.of("error"), [])

    def test_forget_is_refused_while_provisioning_runs(self):
        record = self.register()
        self.app._prov_busy = True
        self.app.forget_record()
        self.assertEqual(record.state, "registered")
        self.assertIs(self.app.current_record, record)
        self.app._prov_busy = False

    # ---- Kapanış ----------------------------------------------------------------------------------------------
    def test_close_warns_when_provisioning_is_pending(self):
        record = self.register()
        self.dialogs.confirm = False
        self.app.on_close()
        self.assertEqual(self.app.winfo_exists(), 1)
        self.assertEqual(record.state, "registered")
        self.dialogs.confirm = True
        self.app.on_close()
        self.assertEqual(record.state, "wiped")
        self.assertEqual(self.api.paths()[-1], "POST /api/v1/auth/logout")  # oturum sunucuda kapatılır

    def test_close_without_secrets_does_not_ask(self):
        self.app.on_close()
        self.assertEqual(self.dialogs.of("confirm"), [])

    # ---- Tüm düğmeler ------------------------------------------------------------------------------------------
    def test_every_button_callback_runs_without_errors(self):
        def clickables(widget):
            for child in widget.winfo_children():
                if child.winfo_class() in ("Button", "Radiobutton", "Checkbutton"):
                    yield child
                yield from clickables(child)

        # Her düğme önce oturumsuz, sonra oturumlu + kayıtlı cihazla çağrılır
        for stage in ("oturumsuz", "oturumlu"):
            if stage == "oturumlu":
                self.patch_login()
                self.app.login_clicked()
                self.fill_form()
                self.app.register_device_and_generate_label()
                self.assertIsNotNone(self.app.current_record)
            invoked = 0
            for button in list(clickables(self.app)):
                button.invoke()
                invoked += 1
            self.assertGreater(invoked, 18, stage)
            self.assert_no_callback_errors()
        self.assertFalse(self.app._esptool_busy)
        self.assertFalse(self.app._prov_busy)

    def test_login_dialog_widget_validates_and_returns_request(self):
        dialog = tool.ServerLoginDialog(self.app, server_url=fc.DEFAULT_SERVER_URL, email="a@example.com", api_key_available=True)
        dialog.withdraw()
        dialog.pwd_entry.insert(0, " " + FAKE_PASSWORD + " ")
        dialog._on_ok()
        self.assertEqual(dialog.result.mode, "password")
        self.assertEqual(dialog.result.password, " " + FAKE_PASSWORD + " ")  # parola kırpılmaz
        self.assertNotIn(FAKE_PASSWORD, repr(dialog.result))

        dialog = tool.ServerLoginDialog(self.app, server_url="http://uzak.example.com", email="a@example.com")
        dialog.withdraw()
        dialog.pwd_entry.insert(0, FAKE_PASSWORD)
        dialog._on_ok()
        self.assertIsNone(dialog.result)  # düz http reddedildi, uyarı gösterildi
        self.assertTrue(self.dialogs.of("warning"))
        dialog.destroy()

        dialog = tool.ServerLoginDialog(self.app, server_url=fc.DEFAULT_SERVER_URL, email="", api_key_available=True)
        dialog.withdraw()
        dialog._on_ok()  # e-posta/parola boş
        self.assertIsNone(dialog.result)
        dialog._on_api_key()
        self.assertEqual(dialog.result.mode, "api_key")


# ============================================================================================================
# Gerçek (iş parçacıklı) çalışma modu: ağ/flash işleri arka planda, arayüz donmaz
# ============================================================================================================
class ThreadRecordingPopen(FakePopen):
    creator_threads = []

    def __init__(self, args, **kwargs):
        super().__init__(args, **kwargs)
        type(self).creator_threads.append(threading.current_thread())


@unittest.skipIf(tool is None or TOOL_IMPORT_ERROR, "arayüz bağımlılıkları (tk/pyserial/qrcode/pillow) yok")
class ThreadedAppTests(unittest.TestCase):
    def setUp(self):
        gc.collect()  # önceki testlerin Tk artıkları (Variable.__del__) arayüz iş parçacığında temizlensin
        self.dialogs = DialogRecorder()
        self.api = FakeApi()
        self.network_threads = []
        self.serial_clock = FakeClock()
        self.firmware = FakeFirmwareCli(mac=MAC)
        self.serial_backend = FakeSerialBackend(self.firmware, self.serial_clock)
        ThreadRecordingPopen.instances = []
        ThreadRecordingPopen.creator_threads = []
        ThreadRecordingPopen.lines = ["Chip is ESP32-S3", "MAC: e8:f6:0a:dd:87:54", "Hard resetting via RTS pin..."]
        ThreadRecordingPopen.returncode_value = 0

        def slow_transport(method, url, headers, body, timeout):
            self.network_threads.append(threading.current_thread())
            time.sleep(0.2)  # yavaş ağ: arayüz bu sürede donmamalı
            return self.api(method, url, headers, body, timeout)

        self.slow_transport = slow_transport
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        image = os.path.join(tmp.name, "fw.bin")
        data = bytearray(90_000)
        data[0] = 0xE9
        data[0x8000:0x8002] = b"\xaa\x50"
        data[0x9000:0x9000 + len(tool.SERIAL_PROVISION_MARKER)] = tool.SERIAL_PROVISION_MARKER  # güncel firmware
        with open(image, "wb") as handle:
            handle.write(bytes(data))
        self.image = image
        patches = [
            mock.patch.object(tool, "messagebox", self.dialogs),
            mock.patch.object(tool.subprocess, "Popen", ThreadRecordingPopen),
            mock.patch.object(tool, "find_esptool_command", return_value=[sys.executable, "esptool.py"]),
            mock.patch.object(tool.ServerLoginDialog, "ask",
                              return_value=tool.LoginRequest("password", fc.DEFAULT_SERVER_URL, "yonetici@example.com", FAKE_PASSWORD)),
        ]
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        try:
            self.app = tool.EvOtomasyonServisApp(
                transport=self.slow_transport,  # synchronous=False: gerçek iş parçacıkları
                serial_backend=self.serial_backend,
                serial_clock=self.serial_clock,
            )
        except Exception as exc:  # noqa: BLE001
            if exc.__class__.__name__ == "TclError":
                self.skipTest("Tk penceresi oluşturulamadı (ekran yok)")
            raise
        self.app.withdraw()
        self.addCleanup(self._destroy_app)
        self.pump_until(lambda: self.app.get_selected_port() == "COM7")

    def _destroy_app(self):
        # Arka plan iş parçacıkları bitsin; Tk değişkenlerinin (Variable.__del__) çöp toplaması ARAYÜZ iş parçacığında
        # yapılsın: aksi halde bir çalışan iş parçacığında tetiklenen GC, ölü yorumlayıcıya Tcl çağrısı yapıp takılır.
        for thread in threading.enumerate():
            if thread.name in ("ev-worker", "ev-logout"):
                thread.join(timeout=5)
        try:
            self.app.destroy()
        except Exception:  # noqa: BLE001
            pass
        self.app = None
        gc.collect()

    def pump_until(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        iterations = 0
        while time.monotonic() < deadline:
            self.app.update()
            iterations += 1
            if predicate():
                return iterations
            time.sleep(0.01)
        self.fail("zaman aşımı: koşul gerçekleşmedi")

    def test_post_ui_from_worker_thread_runs_on_main_thread(self):
        seen = []
        worker = threading.Thread(target=lambda: self.app.post_ui(lambda: seen.append(threading.current_thread())))
        worker.start()
        worker.join()
        self.assertEqual(seen, [])  # henüz arayüz iş parçacığı çalıştırmadı
        self.pump_until(lambda: seen)
        self.assertIs(seen[0], threading.main_thread())

    def test_login_and_list_run_off_the_ui_thread_and_ui_stays_responsive(self):
        self.app.login_clicked()
        self.assertFalse(self.app.client.is_authenticated)  # login_clicked bloklamadı
        self.assertEqual(str(self.app.btn_login.cget("state")), "disabled")
        iterations = self.pump_until(lambda: self.app.client.is_authenticated)
        self.assertGreater(iterations, 3)  # ağ çağrısı sürerken arayüz döngüsü çalışmaya devam etti
        self.pump_until(lambda: len(self.app.inv_tree.get_children()) == 2)
        self.assertTrue(self.network_threads)
        self.assertTrue(all(t is not threading.main_thread() for t in self.network_threads))

    def test_registration_runs_in_background_and_updates_ui(self):
        self.app.login_clicked()
        self.pump_until(lambda: self.app.client.is_authenticated)
        for entry, value in ((self.app.inv_mac_entry, MAC), (self.app.inv_uuid_entry, UID), (self.app.inv_pin_entry, "482915")):
            entry.delete(0, "end")
            entry.insert(0, value)
        self.app.register_device_and_generate_label()
        self.assertEqual(str(self.app.btn_register_device.cget("state")), "disabled")  # işlem sürerken tekrar basılamaz
        self.pump_until(lambda: self.app.current_record is not None)
        self.assertEqual(str(self.app.btn_register_device.cget("state")), "normal")
        self.assertEqual(self.app.current_record.local_key, FAKE_LOCAL_KEY)
        self.pump_until(lambda: self.dialogs.of("info"))
        self.assertNotIn(FAKE_LOCAL_KEY, self.dialogs.all_text())

    def test_flash_runs_in_background_thread_and_logs_lines(self):
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, self.image)
        self.app.start_flash()
        self.assertTrue(self.app._esptool_busy)  # hemen döndü, işlem arka planda
        self.assertEqual(str(self.app.btn_flash.cget("state")), "disabled")
        self.pump_until(lambda: not self.app._esptool_busy)
        self.assertEqual(len(ThreadRecordingPopen.instances), 1)
        self.assertIsNot(ThreadRecordingPopen.creator_threads[0], threading.main_thread())
        self.assertIn("Chip is ESP32-S3", self.app.log_text.get("1.0", "end"))
        self.pump_until(lambda: [c for c in self.dialogs.of("info") if c[1] == "Başarılı"])
        self.assertEqual(str(self.app.btn_flash.cget("state")), "normal")

    def test_second_serial_job_is_refused_while_first_runs(self):
        self.app.start_read_info()
        self.assertTrue(self.app._esptool_busy)
        self.app.start_erase()  # onay kutusu otomatik "evet"; ama meşgul olduğu için başlatılmaz
        self.pump_until(lambda: not self.app._esptool_busy)
        self.assertEqual(len(ThreadRecordingPopen.instances), 1)

    def test_provision_wait_can_be_cancelled_without_freezing_ui(self):
        record = fc.DeviceRecord(uid=UID, mac=MAC, pin="482915", local_key=FAKE_LOCAL_KEY, ap_pass="AP-TEST-12",
                                 qr_claim_url=fc.build_claim_url(UID, "482915"), serial_no=1)
        self.app.current_record = record
        self.app._refresh_provision_tab()
        calls = []

        def unreachable(method, url, headers, body, timeout):
            calls.append(url)
            raise fc.NetworkError("ag yok")

        self.app.device._transport = unreachable
        self.app.device._sleep = lambda seconds: time.sleep(0.05)
        self.app.start_provision(wait_seconds=600)
        self.assertTrue(self.app._prov_busy)
        self.assertEqual(str(self.app.btn_prov_cancel.cget("state")), "normal")
        self.pump_until(lambda: len(calls) >= 3)  # cihaz bekleniyor, arayüz canlı
        self.app.cancel_provision()
        self.pump_until(lambda: not self.app._prov_busy)
        self.assertEqual(record.state, "registered")
        self.assertEqual(self.dialogs.of("error"), [])
        self.assertIn("iptal", self.app.prov_log.get("1.0", "end"))
        self.assertEqual(str(self.app.btn_prov_start.cget("state")), "normal")
        self.assertEqual(str(self.app.btn_prov_cancel.cget("state")), "disabled")

    def _direct_record(self):
        record = fc.DeviceRecord(uid=UID, mac=MAC, pin="482915", local_key=FAKE_LOCAL_KEY, ap_pass="AP-TEST-12",
                                 qr_claim_url=fc.build_claim_url(UID, "482915"), serial_no=1)
        self.app.current_record = record
        self.app._refresh_provision_tab()
        return record

    def test_flash_then_automatic_usb_provisioning_runs_in_background_threads(self):
        record = self._direct_record()
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, self.image)
        self.app.start_flash()
        self.assertTrue(self.app._esptool_busy)
        self.pump_until(lambda: record.state == "verified")
        self.assertEqual(record.path, "serial")
        self.assertIsNot(ThreadRecordingPopen.creator_threads[0], threading.main_thread())
        self.assertTrue(self.serial_backend.open_threads)
        self.assertTrue(all(t is not threading.main_thread() for t in self.serial_backend.open_threads))
        self.assertEqual(self.app.notebook.index("current"), 2)
        self.assertEqual(self.firmware.local_key, FAKE_LOCAL_KEY)

    def test_serial_provisioning_runs_in_background_and_locks_the_flash_buttons(self):
        record = self._direct_record()
        gate = threading.Event()
        self.firmware.boot_ticks, self.firmware.booted = 40, False  # açılış gecikmesi: bekleme (sleep) tetiklenir
        self.serial_clock.on_sleep = lambda: gate.wait(10)  # arka plan iş parçacığı burada durur
        self.app.file_entry.delete(0, "end")
        self.app.file_entry.insert(0, self.image)
        self.app.start_serial_provision()
        self.assertTrue(self.app._prov_busy)
        self.assertEqual(self.app._prov_mode, "serial")
        self.pump_until(lambda: self.serial_backend.opened)  # iş parçacığı çalışıyor, arayüz canlı
        for name in ("btn_flash", "btn_erase", "btn_read_info", "btn_read_mac", "btn_prov_serial", "btn_prov_start"):
            self.assertEqual(str(getattr(self.app, name).cget("state")), "disabled", name)
        self.assertEqual(str(self.app.btn_prov_cancel.cget("state")), "normal")
        self.app.start_flash()  # seri port tek işleme açık: reddedilir
        self.assertEqual(ThreadRecordingPopen.instances, [])
        gate.set()
        self.serial_clock.on_sleep = None
        self.pump_until(lambda: not self.app._prov_busy)
        self.assertEqual(record.state, "verified")
        self.assertEqual(str(self.app.btn_flash.cget("state")), "normal")
        self.assertEqual(str(self.app.btn_prov_cancel.cget("state")), "disabled")

    def test_serial_provisioning_can_be_cancelled_quietly(self):
        record = self._direct_record()
        gate = threading.Event()
        self.firmware.boot_ticks, self.firmware.booted = 10 ** 6, False  # kart hiç açılmıyor
        self.serial_clock.on_sleep = lambda: gate.wait(10)
        self.app.start_serial_provision()
        self.pump_until(lambda: self.serial_backend.opened)
        self.app.cancel_provision()
        gate.set()
        self.pump_until(lambda: not self.app._prov_busy)
        self.assertEqual(record.state, "registered")
        self.assertEqual(self.dialogs.of("error"), [])
        self.assertIn("iptal", self.app.prov_log.get("1.0", "end"))
        self.assertTrue(self.serial_backend.all_closed())
        self.assertEqual(str(self.app.btn_flash.cget("state")), "normal")
        self.assertNotIn("FACTORYINIT", self.firmware.commands)

    def test_deferred_dialogs_do_not_block_ui_queue(self):
        self.app.ui_info("Baslik", "Metin")
        self.assertEqual(self.dialogs.calls, [])  # ayrı Tk olayı olarak planlandı
        self.pump_until(lambda: self.dialogs.calls)
        self.assertEqual(self.dialogs.of("info")[0][1:], ("Baslik", "Metin"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
