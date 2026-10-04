# -*- coding: utf-8 -*-
"""
"Beni hatırla" oturum deposu testleri (GUI AÇMAZ): şifreli token dosyası, kimlik ayarı, rotasyon yazımı, sessiz geri
yükleme sonuçları. Gerçek %APPDATA%\\AHBU içeriğine DOKUNMAZ (her test kendi geçici dizinini kullanır).

Çalıştırma: python -m unittest discover -s tests
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
if TOOL_DIR not in sys.path:
    sys.path.insert(0, TOOL_DIR)

import factory_client as fc  # noqa: E402
import session_store as ss  # noqa: E402
import tool_theme as theme  # noqa: E402

# Çalışma anında üretilen SAHTE değerler (sabit sır değildir)
REFRESH_A = "ref-aaa-" + "a" * 24
REFRESH_B = "ref-bbb-" + "b" * 24
REFRESH_C = "ref-ccc-" + "c" * 24
ACCESS_A = "acc-aaa-" + "x" * 24
ACCESS_B = "acc-bbb-" + "y" * 24
FAKE_PASSWORD = "pw-" + "z" * 14
EMAIL = "yonetici@example.com"
URL = fc.DEFAULT_SERVER_URL


def fake_protect(data: bytes) -> bytes:
    return bytes(data)[::-1]


def fake_unprotect(blob: bytes) -> bytes:
    return bytes(blob)[::-1]


class FakeServer:
    """Sahte AHBU sunucusu (taşıma). Yanıtlar `routes` ile; istekler `calls` listesinde."""

    def __init__(self) -> None:
        self.calls: list[SimpleNamespace] = []
        self.role = "super_user"
        self.refresh_queue = [(ACCESS_B, REFRESH_B), ("acc-ccc-" + "w" * 24, REFRESH_C)]
        self.routes = {
            "POST /api/v1/auth/refresh": self._refresh,
            "GET /api/v1/auth/me": self._me,
            "POST /api/v1/auth/logout": lambda call: (200, {"success": True, "message": "ok", "data": None}),
            "GET /api/v1/admin/inventory": lambda call: (200, {"success": True, "message": "ok", "data": {"items": [], "total": 0}}),
        }
        self.expire_inventory_once = False

    def _refresh(self, call):
        if not self.refresh_queue:
            return 401, {"success": False, "message": "x", "code": "INVALID_TOKEN"}
        access, refresh = self.refresh_queue.pop(0)
        return 200, {"success": True, "message": "ok", "data": {"access_token": access, "refresh_token": refresh}}

    def _me(self, call):
        return 200, {"success": True, "message": "ok", "data": {"user": {"id": "u-1", "email": EMAIL, "full_name": "Y", "role": self.role}, "homes": []}}

    def __call__(self, method, url, headers, body, timeout):
        import urllib.parse

        path = urllib.parse.urlsplit(url).path
        call = SimpleNamespace(method=method, path=path, body=json.loads(body.decode("utf-8")) if body else None,
                               headers={k.lower(): v for k, v in headers.items()})
        self.calls.append(call)
        if path == "/api/v1/admin/inventory" and self.expire_inventory_once:
            self.expire_inventory_once = False
            return fc.TransportResponse(401, {}, json.dumps({"success": False, "message": "x", "code": "TOKEN_EXPIRED"}).encode("utf-8"))
        handler = self.routes.get("%s %s" % (method, path))
        if handler is None:
            return fc.TransportResponse(404, {}, b'{"success": false, "code": "NOT_FOUND", "message": "yok"}')
        status, payload = handler(call)
        return fc.TransportResponse(status, {}, json.dumps(payload).encode("utf-8"))

    def paths(self):
        return ["%s %s" % (c.method, c.path) for c in self.calls]


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "factory_session.dat")
        self.prefs = os.path.join(self.tmp.name, "prefs.json")

    def make_store(self, **kw):
        kw.setdefault("protect", fake_protect)
        kw.setdefault("unprotect", fake_unprotect)
        return ss.SessionStore(path=self.path, prefs_path=self.prefs, **kw)


class SessionStoreTests(StoreCase):
    def test_roundtrip_and_plaintext_never_on_disk(self):
        store = self.make_store()
        self.assertTrue(store.save(URL, EMAIL, REFRESH_A))
        loaded = store.load()
        self.assertEqual((loaded.server_url, loaded.email, loaded.refresh_token), (URL, EMAIL, REFRESH_A))
        with open(self.path, "rb") as handle:
            self.assertNotIn(REFRESH_A.encode("utf-8"), handle.read())
        with open(self.prefs, "rb") as handle:
            prefs = handle.read()
        self.assertNotIn(REFRESH_A.encode("utf-8"), prefs)
        self.assertEqual(json.loads(prefs.decode("utf-8")), {"server_url": URL, "email": EMAIL})

    def test_repr_never_leaks_the_token(self):
        store = self.make_store()
        store.save(URL, EMAIL, REFRESH_A)
        self.assertNotIn(REFRESH_A, repr(store.load()))
        self.assertNotIn(REFRESH_A, str(store.load()))

    def test_corrupt_foreign_or_wrong_version_files_load_as_none(self):
        store = self.make_store()
        store.save(URL, EMAIL, REFRESH_A)
        with open(self.path, "wb") as handle:
            handle.write(b"\x00\x01 bozuk")
        self.assertIsNone(store.load())

        def refuse(_blob):
            raise OSError("baska kullanici")  # DPAPI: başka Windows kullanıcısına ait blob çözülemez

        self.assertIsNone(self.make_store(unprotect=refuse).load())
        with open(self.path, "wb") as handle:
            handle.write(fake_protect(json.dumps({"v": 99, "server_url": URL, "email": EMAIL, "refresh_token": REFRESH_A}).encode("utf-8")))
        self.assertIsNone(store.load())
        with open(self.path, "wb") as handle:
            handle.write(fake_protect(json.dumps({"v": ss.FORMAT_VERSION, "server_url": URL, "email": EMAIL, "refresh_token": ""}).encode("utf-8")))
        self.assertIsNone(store.load())

    def test_without_a_protector_only_the_identity_is_remembered(self):
        store = ss.SessionStore(path=self.path, prefs_path=self.prefs, protect=None, unprotect=None)
        with mock.patch.object(ss, "dpapi_available", return_value=False):
            store = ss.SessionStore(path=self.path, prefs_path=self.prefs)
        self.assertFalse(store.can_store_token)
        self.assertFalse(store.save(URL, EMAIL, REFRESH_A))  # token YAZILMAZ
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(store.identity(), (URL, EMAIL))  # kimlik yine hatırlanır
        self.assertIsNone(store.load())

    def test_protector_failure_or_unwritable_target_never_raises(self):
        def boom(_data):
            raise OSError("sifreleme basarisiz")

        store = self.make_store(protect=boom)
        self.assertFalse(store.save(URL, EMAIL, REFRESH_A))
        self.assertFalse(os.path.exists(self.path))
        os.makedirs(self.path)  # hedef bir DİZİN: yazma OSError verir
        self.assertFalse(self.make_store().save(URL, EMAIL, REFRESH_B))

    def test_clear_token_keeps_identity_and_clear_removes_everything(self):
        store = self.make_store()
        store.save(URL, EMAIL, REFRESH_A)
        store.clear_token()
        self.assertFalse(store.has_token())
        self.assertEqual(store.identity(), (URL, EMAIL))
        store.save(URL, EMAIL, REFRESH_A)
        store.clear()
        self.assertFalse(store.has_token())
        self.assertEqual(store.identity(), ("", ""))
        store.clear()  # tekrar: hata vermez

    def test_identity_and_theme_preferences_do_not_clobber_each_other(self):
        theme.update_preferences({theme.PREFERENCE_KEY: theme.THEME_LIGHT}, path=self.prefs)
        store = self.make_store()
        store.save(URL, EMAIL, REFRESH_A)
        data = theme.read_preferences(self.prefs)
        self.assertEqual(data[theme.PREFERENCE_KEY], theme.THEME_LIGHT)
        self.assertEqual(data["email"], EMAIL)
        self.assertTrue(theme.save_theme_preference(theme.THEME_DARK, path=self.prefs))
        self.assertEqual(store.identity(), (URL, EMAIL))
        store.forget_identity()
        self.assertEqual(theme.read_preferences(self.prefs), {theme.PREFERENCE_KEY: theme.THEME_DARK})

    @unittest.skipUnless(ss.dpapi_available(), "DPAPI yalnızca Windows'ta vardır")
    def test_real_dpapi_roundtrip_binds_the_blob_and_hides_the_token(self):
        store = ss.SessionStore(path=self.path, prefs_path=self.prefs)
        self.assertTrue(store.can_store_token)
        self.assertTrue(store.save(URL, EMAIL, REFRESH_A))
        with open(self.path, "rb") as handle:
            blob = handle.read()
        self.assertNotIn(REFRESH_A.encode("utf-8"), blob)
        self.assertNotIn(EMAIL.encode("utf-8"), blob)
        self.assertEqual(store.load().refresh_token, REFRESH_A)
        # blob bozulursa DPAPI doğrulaması reddeder
        tampered = bytearray(blob)
        tampered[len(tampered) // 2] ^= 0xFF
        with open(self.path, "wb") as handle:
            handle.write(bytes(tampered))
        self.assertIsNone(store.load())
        # başka bir uygulamanın entropisiyle şifrelenmiş blob bu depoda çözülmez
        raw = ss.dpapi_protect(b"baska")
        self.assertEqual(ss.dpapi_unprotect(raw), b"baska")


class SessionKeeperTests(StoreCase):
    def setUp(self):
        super().setUp()
        self.server = FakeServer()
        self.scrubber = fc.SecretScrubber()
        self.client = fc.ServerClient(URL, transport=self.server, scrubber=self.scrubber)
        self.store = self.make_store()
        self.keeper = ss.SessionKeeper(self.client, self.store)

    def login_and_remember(self):
        self.server.routes["POST /api/v1/auth/login"] = lambda call: (200, {"success": True, "message": "ok", "data": {
            "access_token": ACCESS_A, "refresh_token": REFRESH_A,
            "user": {"id": "u-1", "email": EMAIL, "full_name": "Y", "role": "super_user"}}})
        self.client.login(EMAIL, FAKE_PASSWORD)
        self.assertTrue(self.keeper.remember(EMAIL))

    def test_remember_saves_identity_and_encrypted_token_and_hooks_rotation(self):
        self.login_and_remember()
        self.assertTrue(self.keeper.remembered)
        self.assertEqual(self.store.load().refresh_token, REFRESH_A)
        self.assertIsNotNone(self.client.session_listener)

    def test_mid_session_refresh_rotation_is_written_to_the_store_immediately(self):
        self.login_and_remember()
        self.server.expire_inventory_once = True  # erişim token'ı süresi dolmuş: istemci refresh eder (rotasyon)
        self.client.request("GET", "/admin/inventory")
        self.assertEqual(self.client.current_refresh_token(), REFRESH_B)
        self.assertEqual(self.store.load().refresh_token, REFRESH_B)  # eski token KULLANILMIŞ sayıldı: yenisi depoda

    def test_rotation_write_failure_is_fail_closed(self):
        self.login_and_remember()
        with mock.patch.object(self.store, "save", return_value=False):
            self.client._notify_rotation(REFRESH_B)
        self.assertFalse(self.store.has_token())  # bayat token dosyada BIRAKILMAZ ("yeniden kullanım" alarmı olmasın)
        self.assertFalse(self.keeper.remembered)
        self.assertIsNone(self.client.session_listener)

    def test_listener_errors_never_break_the_session(self):
        self.client.session_listener = mock.Mock(side_effect=RuntimeError("disk dolu"))
        self.client._notify_rotation(REFRESH_B)  # istisna sızmaz

    def test_restore_success_rotates_and_marks_remembered(self):
        self.store.save(URL, EMAIL, REFRESH_A)
        outcome, email = self.keeper.try_restore()
        self.assertEqual((outcome, email), (ss.RESTORED, EMAIL))
        self.assertTrue(self.client.is_authenticated)
        self.assertEqual(self.client.user_email, EMAIL)
        self.assertEqual(self.store.load().refresh_token, REFRESH_B)
        self.assertEqual(self.server.paths(), ["POST /api/v1/auth/refresh", "GET /api/v1/auth/me"])
        self.assertEqual(self.server.calls[0].body, {"refresh_token": REFRESH_A})
        self.assertTrue(self.keeper.remembered)

    def test_restore_when_me_fails_on_network_still_persists_the_rotated_token(self):
        self.store.save(URL, EMAIL, REFRESH_A)

        def offline(call):
            raise fc.NetworkError("ag yok")

        self.server.routes["GET /api/v1/auth/me"] = offline
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.NETWORK)
        self.assertFalse(self.client.is_authenticated)
        self.assertEqual(self.store.load().refresh_token, REFRESH_B)  # sunucu REFRESH_A'yı kullanılmış saydı: yenisi kayıtlı

    def test_restore_rejected_token_is_cleared_but_identity_stays(self):
        self.store.save(URL, EMAIL, REFRESH_A)
        self.server.refresh_queue.clear()  # sunucu 401 INVALID_TOKEN döner
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.EXPIRED)
        self.assertFalse(self.store.has_token())
        self.assertEqual(self.store.identity(), (URL, EMAIL))
        self.assertFalse(self.keeper.remembered)
        self.assertIsNone(self.client.session_listener)

    def test_restore_refresh_network_error_keeps_the_token(self):
        self.store.save(URL, EMAIL, REFRESH_A)

        def offline(call):
            raise fc.NetworkError("ag yok")

        self.server.routes["POST /api/v1/auth/refresh"] = offline
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.NETWORK)
        self.assertEqual(self.store.load().refresh_token, REFRESH_A)

    def test_restore_server_error_keeps_the_token(self):
        self.store.save(URL, EMAIL, REFRESH_A)
        self.server.routes["POST /api/v1/auth/refresh"] = lambda call: (503, {"success": False, "message": "x", "code": "UNAVAILABLE"})
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.NETWORK)
        self.assertTrue(self.store.has_token())

    def test_restore_non_super_user_is_forbidden_cleared_and_revoked(self):
        self.store.save(URL, EMAIL, REFRESH_A)
        self.server.role = "user"
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.FORBIDDEN)
        self.assertFalse(self.client.is_authenticated)
        self.assertFalse(self.store.has_token())
        self.assertEqual(self.server.paths()[-1], "POST /api/v1/auth/logout")
        self.assertEqual(self.server.calls[-1].body, {"refresh_token": REFRESH_B})

    def test_restore_never_contacts_a_server_that_differs_from_the_stored_one(self):
        self.store.save("http://127.0.0.1:5000", EMAIL, REFRESH_A)
        outcome, _email = self.keeper.try_restore()
        self.assertEqual(outcome, ss.MISMATCH)
        self.assertEqual(self.server.calls, [])  # token başka sunucuya GİTMEDİ
        self.assertTrue(self.store.has_token())

    def test_restore_without_a_record_is_a_noop(self):
        self.assertEqual(self.keeper.try_restore(), (ss.NONE, ""))
        self.assertEqual(self.server.calls, [])

    def test_forget_removes_everything_and_unhooks(self):
        self.login_and_remember()
        self.keeper.forget()
        self.assertFalse(self.store.has_token())
        self.assertEqual(self.store.identity(), ("", ""))
        self.assertFalse(self.keeper.remembered)
        self.assertIsNone(self.client.session_listener)
        self.server.expire_inventory_once = True
        self.client.request("GET", "/admin/inventory")  # rotasyon artık depoya yazılmaz
        self.assertFalse(self.store.has_token())

    def test_remember_without_encryption_is_false_and_keeps_only_identity(self):
        store = ss.SessionStore(path=self.path, prefs_path=self.prefs, protect=None, unprotect=None)
        with mock.patch.object(ss, "dpapi_available", return_value=False):
            store = ss.SessionStore(path=self.path, prefs_path=self.prefs)
        keeper = ss.SessionKeeper(self.client, store)
        self.server.routes["POST /api/v1/auth/login"] = lambda call: (200, {"success": True, "message": "ok", "data": {
            "access_token": ACCESS_A, "refresh_token": REFRESH_A,
            "user": {"id": "u-1", "email": EMAIL, "full_name": "Y", "role": "super_user"}}})
        self.client.login(EMAIL, FAKE_PASSWORD)
        self.assertFalse(keeper.remember(EMAIL))
        self.assertFalse(keeper.remembered)
        self.assertFalse(os.path.exists(self.path))
        self.assertEqual(store.identity(), (URL, EMAIL))

    def test_password_is_never_written_anywhere(self):
        self.login_and_remember()
        self.server.expire_inventory_once = True
        self.client.request("GET", "/admin/inventory")
        for name in os.listdir(self.tmp.name):
            with open(os.path.join(self.tmp.name, name), "rb") as handle:
                self.assertNotIn(FAKE_PASSWORD.encode("utf-8"), handle.read(), name)


if __name__ == "__main__":
    unittest.main()
