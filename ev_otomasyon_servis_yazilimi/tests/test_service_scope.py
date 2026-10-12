# -*- coding: utf-8 -*-
"""
Servis sorumlusu "KENDİ kapsamında süper" modeli (tasarım 2026-10-12, sunucu 77e1f91) - fabrika/servis aracı testleri.
Donanımsız, internetsiz (sahte HTTP taşıma + gizli Tk penceresi).

* Servis girişinde fabrika kaydı / askıya alma / aktif etme / silme / etiket yenileme AÇIK; iptal (REVOKED) kapalı.
* Kök-yalnız öğeler: envanterde "Servis" sütunu, "Servise Aktar" (kart + site); servis girişinde görünmez, istek de gitmez.
* Aktarım istekleri: gövde ``{"service_user_id": "<uuid>" | null}``, doğru uçlar, servis hesabı listesi.
* Sunucu 403 / 404 yanıtları anlaşılır Türkçe iletiyle gösterilir (sunucunun ham metni gösterilmez).
* Genel şablonlar: servis okur/kullanır, değiştiremez (kopyalayabilir).
"""

import os
import sys
import unittest
import urllib.parse
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
for _path in (TOOL_DIR, TESTS_DIR):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import factory_client as fc  # noqa: E402
import test_factory_tool as base  # noqa: E402 - FakeApi, ağ koruması, AppSmokeTests altyapısı
from test_site_template import FLAT_ID, SITE_ID, TID, ok_template, site_routes  # noqa: E402

SVC_A = "aaaaaaaa-1111-4222-8333-444444444444"
SVC_B = "bbbbbbbb-1111-4222-8333-444444444444"
SVC_PENDING = "cccccccc-1111-4222-8333-444444444444"
HOME_ID = "dddddddd-1111-4222-8333-444444444444"
GTID = "99999999-5b7d-4e8f-9a01-23456789abcd"  # genel (site'siz) şablon

# Sunucunun (inventory_service / site_template_service / service_scope_service / auth_middleware) gerçek 403 iletileri
SERVER_403 = {
    "revoke": "Cihazı iptal etme (REVOKED) yalnızca süper yöneticiye aittir.",
    "transfer": "Kapsamlar arası aktarım yalnızca kök yöneticiye aittir.",
    "root": "Bu işlem yalnızca kök yönetici (Süper Yönetici) içindir.",
    "global_template": "Genel (standart) şablonları yalnızca kök yönetici değiştirebilir.",
    "other_stock": "Bu kart başka bir servis sorumlusunun stoğunda; daireye bağlanamaz.",
    "inventory_gate": "Bu işlem için Süper Yönetici yetkisi gereklidir.",
    "service_gate": "Bu işlem için Servis Sorumlusu veya Süper Yönetici yetkisi gereklidir.",
    "plain": "Bu işlem için yetkiniz bulunmamaktadır.",
}


def setUpModule():
    base.setUpModule()


def tearDownModule():
    base.tearDownModule()


def ok(data, status=200, message="ok"):
    return lambda call: (status, {"success": True, "message": message, "data": data}, {})


def error(status, message, code):
    return lambda call: (status, {"success": False, "message": message, "code": code}, {})


def service_accounts():
    """GET /admin/users?role=service_user yanıtı: iki etkin hesap + davet bekleyen + (sunucu süzse de) başka rol."""
    return [
        {"id": SVC_A.upper(), "email": "servis.a@example.com", "full_name": "Servis A", "role": "service_user",
         "is_active": True, "account_status": "active"},
        {"id": SVC_B, "email": "servis.b@example.com", "full_name": "", "role": "service_user", "is_active": True,
         "account_status": "active"},
        {"id": SVC_PENDING, "email": "bekleyen@example.com", "full_name": "Bekleyen", "role": "service_user",
         "is_active": True, "account_status": "pending_invite"},
        {"id": "eeeeeeee-1111-4222-8333-444444444444", "email": "musteri@example.com", "full_name": "Müşteri", "role": "user",
         "is_active": True, "account_status": "active"},
        {"id": "not-a-uuid", "email": "bozuk@example.com", "full_name": "Bozuk", "role": "service_user", "is_active": True,
         "account_status": "active"},
    ]


def inventory_items():
    stamp = "2026-10-01T10:00:00Z"
    return [
        {"serial_no": 4, "device_uuid": base.UID, "mac_address": base.MAC, "model": "M", "status": "IN_STOCK", "created_at": stamp,
         "service_owner_id": SVC_A, "service_owner_email": "servis.a@example.com"},
        {"serial_no": 3, "device_uuid": "AHBU-S3-000003", "mac_address": "AA:BB:CC:00:00:03", "model": "M", "status": "IN_STOCK",
         "created_at": stamp, "service_owner_id": None, "service_owner_email": None},
        {"serial_no": 2, "device_uuid": "AHBU-S3-000002", "mac_address": "AA:BB:CC:00:00:02", "model": "M", "status": "CLAIMED",
         "created_at": stamp, "claimed_at": stamp, "claimed_home_id": HOME_ID,
         "service_owner_id": SVC_B, "service_owner_email": "servis.b@example.com"},
        {"serial_no": 1, "device_uuid": "AHBU-S3-000001", "mac_address": "AA:BB:CC:00:00:01", "model": "M", "status": "REVOKED",
         "created_at": stamp, "service_owner_id": None, "service_owner_email": None},
    ]


def scope_routes(api, *, users=None, items=None):
    items = items if items is not None else inventory_items()
    api.routes["GET /api/v1/admin/inventory"] = ok({
        "total": len(items), "items": items,
        "stats": {"total": len(items), "in_stock": 2, "claimed": 1, "suspended": 0, "revoked": 1},
    })
    api.routes["GET /api/v1/admin/users"] = ok({
        "total": len(service_accounts()) if users is None else len(users), "limit": 100, "offset": 0,
        "users": service_accounts() if users is None else users,
    })

    def transferred(call):
        target = (call.body or {}).get("service_user_id")
        return 200, {"success": True, "message": "Kart yeni servis sorumlusunun stoğuna aktarıldı.", "data": {
            "device_uuid": base.UID, "service_owner_id": target, "previous_service_owner_id": None, "changed": True,
            "message": "Kart yeni servis sorumlusunun stoğuna aktarıldı."}}, {}

    api.routes["PATCH /api/v1/admin/inventory/%s/service-owner" % base.UID] = transferred
    api.routes["PATCH /api/v1/admin/inventory/AHBU-S3-000003/service-owner"] = transferred
    api.routes["PATCH /api/v1/admin/sites/%s/service-owner" % SITE_ID] = lambda call: (200, {"success": True, "message": "ok", "data": {
        "site_id": SITE_ID, "service_owner_id": (call.body or {}).get("service_user_id"), "previous_service_owner_id": None,
        "changed": True}}, {})


def shown_columns(tree):
    columns = tuple(tree.cget("displaycolumns"))
    return list(tree.cget("columns")) if columns == ("#all",) else list(columns)


# ============================================================================================================
# 403 iletileri (istemci katmanı)
# ============================================================================================================
class ForbiddenMessageTests(unittest.TestCase):
    EXPECTED = {
        "revoke": fc.FORBIDDEN_REVOKE_TEXT,
        "transfer": fc.FORBIDDEN_TRANSFER_TEXT,
        "root": fc.FORBIDDEN_ROOT_ONLY_TEXT,
        "global_template": fc.FORBIDDEN_GLOBAL_TEMPLATE_TEXT,
        "other_stock": fc.FORBIDDEN_OTHER_STOCK_TEXT,
        "inventory_gate": fc.FORBIDDEN_ROOT_ONLY_TEXT,
        "service_gate": fc.FORBIDDEN_DEFAULT_TEXT,
        "plain": fc.FORBIDDEN_DEFAULT_TEXT,
    }

    def test_known_server_403_messages_become_the_tools_own_turkish_text(self):
        for key, message in SERVER_403.items():
            with self.subTest(durum=key):
                text = fc.friendly_api_error(403, "FORBIDDEN", message)
                self.assertEqual(text, self.EXPECTED[key])
                self.assertNotEqual(text, message)  # sunucunun ham metni gösterilmez

    def test_unknown_or_hostile_403_messages_fall_back_to_the_default_text(self):
        for hostile in (None, "", "SQLSTATE 23505 leak", "<b>x</b>", "{json}", "x" * 500):
            with self.subTest(ileti=hostile):
                self.assertEqual(fc.friendly_api_error(403, "FORBIDDEN", hostile), fc.FORBIDDEN_DEFAULT_TEXT)

    def test_default_403_text_describes_the_scoped_model_not_the_old_one(self):
        text = fc.FORBIDDEN_DEFAULT_TEXT
        for needle in ("yetkiniz yok", "kendi stoğundaki", "iptal etme (REVOKED)", "servisler arası aktarım", "genel şablonları",
                       "kök yöneticiye"):
            with self.subTest(gerekli=needle):
                self.assertIn(needle, text)
        self.assertNotIn("yalnızca süper kullanıcıya açıktır", text)  # eski model: kayıt/askıya alma/silme süper kullanıcıya
        for code in ("ACCOUNT_DISABLED", "ACCOUNT_PENDING", "REAUTH_REQUIRED", "SERVICE_SESSION_FORBIDDEN"):
            self.assertNotEqual(fc.friendly_api_error(403, code, SERVER_403["revoke"]), fc.FORBIDDEN_REVOKE_TEXT)

    def test_403_over_the_wire_carries_the_translated_text(self):
        client, api = base.make_client()
        api.login_role = "service_user"
        api.routes["PATCH /api/v1/admin/inventory/%s/status" % base.UID] = error(403, SERVER_403["revoke"], "FORBIDDEN")
        client.login("servis@example.com", base.FAKE_PASSWORD)
        with self.assertRaises(fc.ApiError) as ctx:
            client.update_status(base.UID, "SUSPENDED")
        self.assertEqual((ctx.exception.status, ctx.exception.code), (403, "FORBIDDEN"))
        self.assertEqual(str(ctx.exception), fc.FORBIDDEN_REVOKE_TEXT)
        self.assertTrue(client.is_authenticated)  # 403 oturumu kapatmaz / yenilemeyi tetiklemez
        self.assertNotIn("POST /api/v1/auth/refresh", api.paths())


# ============================================================================================================
# Aktarım uçları (istemci katmanı)
# ============================================================================================================
class TransferClientTests(unittest.TestCase):
    def client(self, role="super_user", **kwargs):
        client, api = base.make_client(**kwargs)
        api.login_role = role
        scope_routes(api)
        site_routes(api)
        client.login("kisi@example.com", base.FAKE_PASSWORD)
        return client, api

    def test_role_helpers(self):
        root, _ = self.client("super_user")
        self.assertEqual((root.is_root, root.is_service, root.sees_all_stock, root.can_manage_inventory), (True, False, True, True))
        service, _ = self.client("service_user")
        self.assertEqual((service.is_root, service.is_service, service.sees_all_stock, service.can_manage_inventory),
                         (False, True, False, True))
        keyed, _ = base.make_client(env={fc.ENV_API_KEY: "k" * 40})
        keyed.use_api_key()
        self.assertEqual((keyed.is_root, keyed.is_service, keyed.sees_all_stock, keyed.can_manage_inventory),
                         (False, False, True, True))

    def test_list_service_users_asks_the_user_list_and_keeps_only_active_service_accounts(self):
        client, api = self.client()
        users = client.list_service_users()
        call = [c for c in api.calls if c.path == "/api/v1/admin/users"][-1]
        self.assertEqual(call.method, "GET")
        self.assertEqual(urllib.parse.parse_qs(call.query),
                         {"role": ["service_user"], "is_active": ["true"], "limit": ["100"], "offset": ["0"]})
        self.assertEqual([(u["id"], u["email"], u["full_name"]) for u in users],
                         [(SVC_A, "servis.a@example.com", "Servis A"), (SVC_B, "servis.b@example.com", "")])

    def test_list_service_users_follows_pages_until_the_total(self):
        client, api = self.client()
        pages = []

        def page(call):
            offset = int(urllib.parse.parse_qs(call.query)["offset"][0])
            pages.append(offset)
            rows = [{"id": "00000000-0000-4000-8000-%012d" % (offset + i), "email": "s%d@example.com" % (offset + i), "full_name": "",
                     "role": "service_user", "is_active": True, "account_status": "active"}
                    for i in range(100 if offset == 0 else 50)]
            return 200, {"success": True, "data": {"total": 150, "limit": 100, "offset": offset, "users": rows}}, {}

        api.routes["GET /api/v1/admin/users"] = page
        self.assertEqual(len(client.list_service_users()), 150)
        self.assertEqual(pages, [0, 100])

    def test_transfer_inventory_sends_the_documented_body_to_the_documented_path(self):
        client, api = self.client()
        result = client.transfer_inventory(base.UID.lower(), SVC_A.upper())
        call = api.calls[-1]
        self.assertEqual((call.method, call.path), ("PATCH", "/api/v1/admin/inventory/%s/service-owner" % base.UID))
        self.assertEqual(call.body, {"service_user_id": SVC_A})
        self.assertEqual(call.raw_body, ('{"service_user_id":"%s"}' % SVC_A).encode("utf-8"))
        self.assertEqual(result["service_owner_id"], SVC_A)
        client.transfer_inventory(base.UID, None)  # kök stoğuna al
        self.assertEqual(api.calls[-1].body, {"service_user_id": None})
        self.assertEqual(api.calls[-1].raw_body, b'{"service_user_id":null}')

    def test_transfer_site_sends_the_documented_body_to_the_documented_path(self):
        client, api = self.client()
        client.transfer_site(SITE_ID, SVC_B)
        call = api.calls[-1]
        self.assertEqual((call.method, call.path), ("PATCH", "/api/v1/admin/sites/%s/service-owner" % SITE_ID))
        self.assertEqual(call.body, {"service_user_id": SVC_B})
        client.transfer_site(SITE_ID, "")  # boş = köke al
        self.assertEqual(api.calls[-1].body, {"service_user_id": None})

    def test_transfer_rejects_malformed_ids_without_a_request(self):
        client, api = self.client()
        before = len(api.calls)
        for call in (lambda: client.transfer_inventory(base.UID, "kullanici-1"), lambda: client.transfer_inventory("../x", SVC_A),
                     lambda: client.transfer_site("../admin", SVC_A), lambda: client.transfer_site(SITE_ID, "' OR 1=1 --")):
            with self.assertRaises(fc.FactoryError):
                call()
        self.assertEqual(len(api.calls), before)

    def test_service_user_cannot_transfer_or_list_service_accounts_and_no_request_is_sent(self):
        client, api = self.client("service_user")
        before = len(api.calls)
        for call in (client.list_service_users, lambda: client.transfer_inventory(base.UID, SVC_A),
                     lambda: client.transfer_inventory(base.UID, None), lambda: client.transfer_site(SITE_ID, SVC_A)):
            with self.assertRaises(fc.ApiError) as ctx:
                call()
            self.assertEqual((ctx.exception.status, ctx.exception.code), (403, "FORBIDDEN"))
            self.assertEqual(str(ctx.exception), fc.FORBIDDEN_TRANSFER_TEXT)
        self.assertEqual(len(api.calls), before)

    def test_api_key_cannot_transfer(self):
        client, api = base.make_client(env={fc.ENV_API_KEY: "k" * 40})
        client.use_api_key()
        for call in (client.list_service_users, lambda: client.transfer_inventory(base.UID, SVC_A),
                     lambda: client.transfer_site(SITE_ID, None)):
            with self.assertRaises(fc.ApiError) as ctx:
                call()
            self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(api.calls, [])

    def test_unauthenticated_transfer_reports_the_missing_session(self):
        client, api = base.make_client()
        with self.assertRaises(fc.SessionExpiredError):
            client.transfer_inventory(base.UID, None)
        self.assertEqual(api.calls, [])

    def test_server_conflict_for_an_installed_card_is_kept(self):
        client, api = self.client()
        api.routes["PATCH /api/v1/admin/inventory/%s/service-owner" % base.UID] = error(
            409, "Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.", "CONFLICT")
        with self.assertRaises(fc.ApiError) as ctx:
            client.transfer_inventory(base.UID, SVC_A)
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(str(ctx.exception), "Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.")


# ============================================================================================================
# Arayüz
# ============================================================================================================
@unittest.skipIf(base.tool is None or base.TOOL_IMPORT_ERROR, "arayüz bağımlılıkları yok")
class ServiceScopeAppTests(base.AppSmokeTests):
    """AppSmokeTests altyapısı (sahte ağ/seri/iletişim kutuları); miras alınan testler burada TEKRAR koşmaz."""

    def setUp(self):
        super().setUp()
        site_routes(self.api)
        scope_routes(self.api)
        self.firmware.provisioned = True

    def run(self, result=None):
        if self._testMethodName not in type(self).__dict__:
            return result
        return super().run(result)

    def login_as(self, role):
        self.api.login_role = role
        self.patch_login()
        self.app.login_clicked()

    def calls_after(self, mark):
        return self.api.calls[mark:]

    def select_row(self, index):
        self.app.inv_tree.selection_set(self.app.inv_tree.get_children()[index])

    # ---- düğmeler ve sütun -----------------------------------------------------------------------------------
    def test_service_user_gets_the_factory_buttons_but_no_root_only_items(self):
        self.login_as("service_user")
        for name in ("btn_register_device", "btn_suspend", "btn_activate", "btn_delete_device", "btn_reissue_label"):
            with self.subTest(dugme=name):
                self.assertEqual(str(getattr(self.app, name).cget("state")), "normal")
        self.assertEqual(self.app.btn_register_device.cget("text"), "☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET")
        self.assertEqual(self.app.inv_role_note.get(), tool_module().SERVICE_INVENTORY_NOTE)
        for needle in ("Servis sorumlusu olarak giriş yaptınız", "KENDİ stoğunuza", "kendi kartlarınızı", "firmware yükleme ve provizyon",
                       "iptal etme (REVOKED)", "başka servise aktarılması yalnızca kök yöneticiye"):
            with self.subTest(not_metni=needle):
                self.assertIn(needle, self.app.inv_role_note.get())
        # kök-yalnız öğeler görünmez
        self.assertEqual(self.app.btn_transfer_device.winfo_manager(), "")
        self.assertEqual(self.app.btn_site_transfer.winfo_manager(), "")
        self.assertNotIn("service", shown_columns(self.app.inv_tree))
        self.assertIn("Kapsam: kendi stoğunuz", self.app.inv_status_var.get())
        # firmware yükleme zaten yerel: servis girişinde de açık
        self.assertEqual(str(self.app.btn_flash.cget("state")), "normal")
        self.assert_no_callback_errors()

    def test_there_is_no_revoke_button_for_anyone(self):
        # İptal (REVOKED) araçta hiç yok; sunucu da servis için reddeder (403) - servise açılacak bir iptal düğmesi eklenmedi.
        for role in ("super_user", "service_user"):
            self.login_as(role)
            labels = []

            def walk(widget):
                if widget.winfo_class() == "Button":
                    labels.append(str(widget.cget("text")))
                for child in widget.winfo_children():
                    walk(child)

            walk(self.app)
            with self.subTest(rol=role):
                self.assertGreater(len(labels), 10)
                self.assertFalse([text for text in labels if "REVOKE" in text.upper()], labels)

    def test_root_sees_the_service_column_and_both_transfer_buttons(self):
        self.login_as("super_user")
        self.assertEqual(self.app.inv_role_note.get(), "")
        self.assertIn("service", shown_columns(self.app.inv_tree))
        self.assertEqual(self.app.inv_tree.heading("service", "text"), "Servis")
        self.assertEqual(self.app.btn_transfer_device.winfo_manager(), "pack")
        self.assertEqual(self.app.btn_site_transfer.winfo_manager(), "pack")
        self.assertEqual(self.app.btn_transfer_device.cget("text"), "🔀 Servise Aktar")
        self.assertEqual(self.app.btn_site_transfer.cget("text"), "🔀 Siteyi Servise Aktar")
        cells = [str(self.app.inv_tree.item(row)["values"][5]) for row in self.app.inv_tree.get_children()]
        self.assertEqual(cells, ["servis.a@example.com", "Kök stoğu", "servis.b@example.com", "Kök stoğu"])
        self.assertNotIn("Kapsam: kendi stoğunuz", self.app.inv_status_var.get())
        self.assert_no_callback_errors()

    def test_root_only_items_follow_the_session(self):
        self.login_as("super_user")
        self.app.logout_clicked()
        self.assertEqual(self.app.btn_transfer_device.winfo_manager(), "")
        self.assertEqual(self.app.btn_site_transfer.winfo_manager(), "")
        self.assertNotIn("service", shown_columns(self.app.inv_tree))
        self.login_as("service_user")
        self.assertEqual(self.app.btn_transfer_device.winfo_manager(), "")
        self.login_as("super_user")
        self.assertEqual(self.app.btn_transfer_device.winfo_manager(), "pack")
        self.assert_no_callback_errors()

    def test_inventory_owner_text(self):
        owner = tool_module().inventory_owner_text
        self.assertEqual(owner({"service_owner_email": " servis@example.com "}), "servis@example.com")
        self.assertEqual(owner({"service_owner_id": None, "service_owner_email": None}), "Kök stoğu")
        self.assertEqual(owner({}), "Kök stoğu")
        self.assertEqual(owner({"service_owner_id": SVC_A, "service_owner_email": ""}), "Servis (e-posta yok)")
        self.assertEqual(owner("x"), "Kök stoğu")

    # ---- servis girişinde kayıt / durum / silme / etiket -----------------------------------------------------
    def test_service_user_registers_a_card_into_its_own_stock(self):
        self.api.login_role = "service_user"
        record = self.register()
        self.assertIsNotNone(record)
        post = [c for c in self.api.calls if (c.method, c.path) == ("POST", "/api/v1/admin/inventory/register")][-1]
        self.assertEqual(post.body["device_uuid"], base.UID)
        self.assertTrue(post.headers["authorization"].startswith("Bearer "))
        self.assertNotIn("x-api-key", post.headers)
        self.assertFalse([k for k in post.body if "service" in k])  # stok sahibini sunucu belirler (kendi hesabı)
        self.assertIn("Cihaz Envantere Eklendi!", [c[1] for c in self.dialogs.calls])
        self.assert_no_callback_errors()

    def test_service_user_suspends_activates_and_deletes_in_its_own_stock(self):
        self.login_as("service_user")
        self.api.routes["PATCH /api/v1/admin/inventory/%s/status" % base.UID] = ok({"status": "SUSPENDED"})
        self.api.routes["DELETE /api/v1/admin/inventory/%s" % base.UID] = ok(None, message="silindi")
        self.select_row(0)
        self.app.suspend_selected_device()
        self.select_row(0)
        self.app.activate_selected_device()
        self.assertEqual([c.body for c in self.api.calls if c.method == "PATCH"], [{"status": "SUSPENDED"}, {"status": "IN_STOCK"}])
        self.select_row(0)
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
            self.app.delete_selected_device()
        self.assertEqual(len([c for c in self.api.calls if c.method == "DELETE"]), 1)
        self.assertNotIn("Yetki Yok", [c[1] for c in self.dialogs.calls])
        self.assert_no_callback_errors()

    def test_service_user_reissues_the_label_of_its_own_card(self):
        self.api.login_role = "service_user"
        self._prepare_reissue()
        self.app.btn_reissue_label.invoke()
        self.assertEqual(self.app.current_record.pin, base.NEW_PIN)
        self.assertIn("Etiket Yenilendi", [c[1] for c in self.dialogs.calls])
        self.assertIn("POST /api/v1/admin/inventory/%s/reissue-label" % base.UID, self.api.paths())
        self.assert_no_callback_errors()

    def test_service_user_cannot_change_a_revoked_card_and_nothing_is_sent(self):
        self.login_as("service_user")
        self.api.routes["PATCH /api/v1/admin/inventory/AHBU-S3-000001/status"] = ok({"status": "IN_STOCK"})
        for action in (self.app.suspend_selected_device, self.app.activate_selected_device):
            self.select_row(3)  # REVOKED
            mark = len(self.api.calls)
            action()
            self.assertEqual(self.calls_after(mark), [])
        info = self.dialogs.of("info")[-1]
        self.assertEqual(info[1], "İptal Edilmiş Kart")
        self.assertIn("iptal edilmiş (REVOKED)", info[2])
        self.assertIn("yalnızca kök yönetici", info[2])
        self.assertFalse(self.dialogs.of("confirm"))  # askıya alma onayı bile sorulmaz

    def test_root_can_still_change_a_revoked_card(self):
        self.login_as("super_user")
        self.api.routes["PATCH /api/v1/admin/inventory/AHBU-S3-000001/status"] = ok({"status": "IN_STOCK"})
        self.select_row(3)
        self.app.activate_selected_device()
        self.assertEqual([c.body for c in self.api.calls if c.method == "PATCH"], [{"status": "IN_STOCK"}])

    # ---- 403 / 404 / 409 iletileri ---------------------------------------------------------------------------
    def test_revoke_403_from_the_server_is_explained_in_turkish(self):
        self.login_as("service_user")
        self.api.routes["PATCH /api/v1/admin/inventory/%s/status" % base.UID] = error(403, SERVER_403["revoke"], "FORBIDDEN")
        self.select_row(0)
        self.app.suspend_selected_device()
        shown = self.dialogs.of("error")[-1]
        self.assertEqual(shown[1], "Durum Güncellenemedi")
        self.assertEqual(shown[2], fc.FORBIDDEN_REVOKE_TEXT)
        self.assertNotIn(SERVER_403["revoke"], shown[2])
        self.assert_no_callback_errors()

    def test_card_of_another_scope_404_gets_the_own_stock_hint_for_the_service_user_only(self):
        self.api.routes["DELETE /api/v1/admin/inventory/%s" % base.UID] = error(404, "Cihaz bulunamadı.", "NOT_FOUND")
        for role, expect_hint in (("service_user", True), ("super_user", False)):
            with self.subTest(rol=role):
                self.dialogs.calls.clear()
                self.login_as(role)
                self.select_row(0)
                with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
                    self.app.delete_selected_device()
                text = self.dialogs.of("error")[-1][2]
                self.assertIn("Cihaz bulunamadı.", text)
                self.assertEqual(tool_module().SERVICE_NOT_YOUR_STOCK_HINT in text, expect_hint)

    def test_label_reissue_of_a_card_in_another_stock_explains_the_scope(self):
        self.api.login_role = "service_user"
        self._prepare_reissue(reissue=base.reissue_route(404, {"success": False, "message": "Cihaz bulunamadı.", "code": "NOT_FOUND"}))
        self.app.btn_reissue_label.invoke()
        error_dialog = self.dialogs.of("error")[-1]
        self.assertEqual(error_dialog[1], "Etiket Yenilenemedi")
        self.assertIn("Cihaz bulunamadı.", error_dialog[2])
        self.assertIn(tool_module().SERVICE_NOT_YOUR_STOCK_HINT, error_dialog[2])
        self.assertNotIn("RESETKEY", self.firmware.commands)
        self.assertIsNone(self.app.current_record)

    def test_registration_conflict_tells_the_service_user_the_card_may_be_in_another_stock(self):
        self.api.login_role = "service_user"
        self.api.routes["POST /api/v1/admin/inventory/register"] = error(409, "Bu cihaz kimliği envanterde zaten kayıtlı.", "CONFLICT")
        self.patch_login()
        self.fill_form()
        self.app.register_device_and_generate_label()
        shown = self.dialogs.of("error")[-1]
        self.assertEqual(shown[1], "Mükerrer Cihaz Uyarısı")
        self.assertIn("kök stoğunda ya da başka bir servisin", shown[2])
        # kök için ek ipucu yok
        self.dialogs.calls.clear()
        self.api.login_role = "super_user"
        self.patch_login()
        self.app.login_clicked()
        self.app.register_device_and_generate_label()
        self.assertNotIn("kök stoğunda ya da başka bir servisin", self.dialogs.of("error")[-1][2])

    def test_link_flat_device_403_for_a_card_in_another_services_stock(self):
        self.login_as("service_user")
        self.api.routes["PUT /api/v1/sites/%s/flats/%s/device" % (SITE_ID, FLAT_ID)] = error(403, SERVER_403["other_stock"], "FORBIDDEN")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        self.app.refresh_flats()
        self.app.flats_tree.selection_set("0")
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
            self.app.link_flat_device()
        shown = self.dialogs.of("error")[-1]
        self.assertEqual(shown[1], "Kart Bağlanamadı")
        self.assertEqual(shown[2], fc.FORBIDDEN_OTHER_STOCK_TEXT)
        self.assert_no_callback_errors()

    # ---- aktarım: kart ---------------------------------------------------------------------------------------
    def test_root_transfers_a_stock_card_to_a_service_account(self):
        self.login_as("super_user")
        self.select_row(1)  # kök stoğundaki kart
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=2) as ask:
            self.app.transfer_selected_device()
        # servis hesapları listesi istendi
        users_call = [c for c in self.api.calls if c.path == "/api/v1/admin/users"][-1]
        self.assertEqual(urllib.parse.parse_qs(users_call.query)["role"], ["service_user"])
        title, prompt, choices, initial = ask.call_args.args[2:6]
        self.assertEqual(title, "🔀 Servise Aktar")
        self.assertIn("AHBU-S3-000003", prompt)
        self.assertEqual(choices, ["Kök stoğuna al (hiçbir servise bağlı olmasın)", "Servis A · servis.a@example.com",
                                   "servis.b@example.com"])  # davet bekleyen / başka rol / bozuk kimlik listelenmez
        self.assertEqual(initial, 0)  # kart şu an kök stoğunda
        # aktarım isteği
        patch = [c for c in self.api.calls if c.method == "PATCH"][-1]
        self.assertEqual(patch.path, "/api/v1/admin/inventory/AHBU-S3-000003/service-owner")
        self.assertEqual(patch.body, {"service_user_id": SVC_B})
        info = self.dialogs.of("info")[-1]
        self.assertEqual(info[1], "Aktarıldı")
        self.assertEqual(info[2], "AHBU-S3-000003 kartı servis.b@example.com servis hesabının stoğuna aktarıldı.")
        self.assertIn("Servise Aktar", [c[1] for c in self.dialogs.of("confirm")])
        self.assertEqual(self.api.calls[-1].path, "/api/v1/admin/inventory")  # liste yenilendi
        self.assert_no_callback_errors()

    def test_root_moves_a_card_back_to_the_root_stock_with_a_null_body(self):
        self.login_as("super_user")
        self.select_row(0)  # servis A'nın stoğundaki kart
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=0) as ask:
            self.app.transfer_selected_device()
        self.assertEqual(ask.call_args.args[5], 1)  # açılışta mevcut sahip (Servis A) seçili gelir
        patch = [c for c in self.api.calls if c.method == "PATCH"][-1]
        self.assertEqual(patch.body, {"service_user_id": None})
        self.assertEqual(patch.raw_body, b'{"service_user_id":null}')
        self.assertEqual(self.dialogs.of("info")[-1][2], "%s kartı kök stoğuna alındı." % base.UID)

    def test_transfer_does_nothing_when_cancelled_declined_or_nothing_selected(self):
        self.login_as("super_user")
        mark = len(self.api.calls)
        self.app.transfer_selected_device()  # seçim yok
        self.assertEqual(self.calls_after(mark), [])
        self.assertEqual(self.dialogs.of("info")[-1][1], "Seçim Yapın")
        self.select_row(1)
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=None):  # pencere kapatıldı
            self.app.transfer_selected_device()
        self.assertFalse([c for c in self.api.calls if c.method == "PATCH"])
        self.dialogs.answers = [False]  # onay: Hayır
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1):
            self.app.transfer_selected_device()
        self.assertFalse([c for c in self.api.calls if c.method == "PATCH"])
        self.assert_no_callback_errors()

    def test_installed_card_is_not_offered_for_transfer(self):
        self.login_as("super_user")
        self.select_row(2)  # CLAIMED, evi var
        mark = len(self.api.calls)
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1) as ask:
            self.app.transfer_selected_device()
        ask.assert_not_called()
        self.assertEqual(self.calls_after(mark), [])
        info = self.dialogs.of("info")[-1]
        self.assertEqual(info[1], "Aktarılamaz")
        self.assertEqual(info[2], "Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.")

    def test_server_refusals_of_a_transfer_are_shown(self):
        self.login_as("super_user")
        self.select_row(1)
        for status, message, code in ((409, "Kurulu kartın sahibi evinin servisidir; kartı değil daireyi aktarın.", "CONFLICT"),
                                      (404, "Servis sorumlusu hesabı bulunamadı.", "NOT_FOUND"),
                                      (409, "Servis sorumlusu hesabı aktif değil.", "CONFLICT")):
            with self.subTest(durum=message):
                self.api.routes["PATCH /api/v1/admin/inventory/AHBU-S3-000003/service-owner"] = error(status, message, code)
                with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1):
                    self.app.transfer_selected_device()
                shown = self.dialogs.of("error")[-1]
                self.assertEqual((shown[1], shown[2]), ("Kart Aktarılamadı", message))
        self.assert_no_callback_errors()

    def test_the_server_says_unchanged_when_the_owner_is_the_same(self):
        self.login_as("super_user")
        self.select_row(1)
        self.api.routes["PATCH /api/v1/admin/inventory/AHBU-S3-000003/service-owner"] = ok(
            {"device_uuid": "AHBU-S3-000003", "service_owner_id": None, "changed": False})
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=0):
            self.app.transfer_selected_device()
        self.assertEqual(self.dialogs.of("info")[-1][2], "AHBU-S3-000003 kartı zaten bu stokta.")

    def test_service_user_cannot_transfer_a_card_and_no_request_is_sent(self):
        self.login_as("service_user")
        self.select_row(0)
        mark = len(self.api.calls)
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1) as ask:
            self.app.transfer_selected_device()
            self.app.btn_transfer_device.invoke()  # görünmez düğme bile çağrılırsa
        ask.assert_not_called()
        self.assertEqual(self.calls_after(mark), [])
        warnings = self.dialogs.of("warning")
        self.assertEqual(len(warnings), 2)
        self.assertEqual((warnings[-1][1], warnings[-1][2]), ("Yetki Yok", fc.FORBIDDEN_TRANSFER_TEXT))
        self.assert_no_callback_errors()

    # ---- aktarım: site ---------------------------------------------------------------------------------------
    def test_root_transfers_a_site_to_a_service_account_and_back(self):
        self.login_as("super_user")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1) as ask:
            self.app.transfer_selected_site()
        title, prompt, choices, _initial = ask.call_args.args[2:6]
        self.assertEqual(title, "🔀 Siteyi Servise Aktar")
        self.assertIn("Güneş Sitesi", prompt)
        self.assertEqual(choices[0], "Kök kapsamına al (hiçbir servise bağlı olmasın)")
        patch = [c for c in self.api.calls if c.method == "PATCH"][-1]
        self.assertEqual(patch.path, "/api/v1/admin/sites/%s/service-owner" % SITE_ID)
        self.assertEqual(patch.body, {"service_user_id": SVC_A})
        self.assertEqual(self.dialogs.of("info")[-1][2],
                         "'Güneş Sitesi' sitesi Servis A · servis.a@example.com servis hesabının kapsamına aktarıldı.")
        self.assertEqual(self.api.calls[-1].path, "/api/v1/sites")  # site listesi yenilendi
        self.app.sites_tree.selection_set("0")
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=0):
            self.app.transfer_selected_site()
        patch = [c for c in self.api.calls if c.method == "PATCH"][-1]
        self.assertEqual(patch.body, {"service_user_id": None})
        self.assertEqual(self.dialogs.of("info")[-1][2], "'Güneş Sitesi' sitesi kök kapsamına alındı.")
        self.assert_no_callback_errors()

    def test_service_user_cannot_transfer_a_site_and_no_request_is_sent(self):
        self.login_as("service_user")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        mark = len(self.api.calls)
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1) as ask:
            self.app.transfer_selected_site()
        ask.assert_not_called()
        self.assertEqual(self.calls_after(mark), [])
        self.assertEqual((self.dialogs.of("warning")[-1][1], self.dialogs.of("warning")[-1][2]),
                         ("Yetki Yok", fc.FORBIDDEN_TRANSFER_TEXT))

    def test_root_403_from_the_transfer_endpoint_if_the_role_changed_is_translated(self):
        self.login_as("super_user")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        self.api.routes["PATCH /api/v1/admin/sites/%s/service-owner" % SITE_ID] = error(403, SERVER_403["transfer"], "FORBIDDEN")
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=1):
            self.app.transfer_selected_site()
        shown = self.dialogs.of("error")[-1]
        self.assertEqual((shown[1], shown[2]), ("Site Aktarılamadı", fc.FORBIDDEN_TRANSFER_TEXT))

    # ---- genel şablonlar: servis okur / kullanır, değiştiremez -----------------------------------------------
    def _template_routes(self):
        general = {"id": GTID, "site_id": None, "name": "Standart 2+1", "flat_type": "2+1", "current_version": 2,
                   "updated_at": "2026-10-08T10:00:00Z"}
        own = {"id": TID, "site_id": SITE_ID, "name": "B Tipi 3+1", "flat_type": "3+1", "current_version": 4,
               "updated_at": "2026-10-08T10:00:00Z"}
        site_routes(self.api, templates=[general, own])
        self.api.routes["GET /api/v1/templates/%s" % GTID] = ok({"id": GTID, "site_id": None, "current_version": 2, "body": ok_template()})

    def test_service_user_cannot_add_edit_or_delete_general_templates(self):
        self._template_routes()
        self.login_as("service_user")
        self.app.tpl_scope.current(0)  # Genel
        self.app.refresh_templates()
        mark = len(self.api.calls)
        self.app.new_template()
        self.app.tpl_tree.selection_set("0")
        self.app.edit_template()
        self.app.delete_template()
        self.assertEqual(self.calls_after(mark), [])
        infos = [c for c in self.dialogs.of("info") if c[1] == "Genel Şablon"]
        self.assertEqual(len(infos), 3)
        self.assertTrue(all(c[2] == tool_ui().GENERAL_TEMPLATE_SERVICE_TEXT for c in infos))
        self.assertFalse(self.dialogs.of("confirm"))
        self.assertIn("servis sorumlusu bunları okur ve kullanır", tool_ui().GENERAL_TEMPLATE_SERVICE_TEXT)

    def test_service_user_may_use_a_general_template_and_copy_it_into_its_site(self):
        self._template_routes()
        self.login_as("service_user")
        self.app.refresh_sites()
        # siteyle birlikte listelenen genel şablon seçilir
        self.app.tpl_scope.current(1)
        self.app.refresh_templates()
        general_row = next(row for row in self.app.tpl_tree.get_children()
                           if str(self.app.tpl_tree.item(row)["values"][0]) == "Standart 2+1")
        self.app.tpl_tree.selection_set(general_row)
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value="Standart 2+1 (kopya)"):
            self.app.duplicate_template()
        post = [c for c in self.api.calls if (c.method, c.path) == ("POST", "/api/v1/templates")][-1]
        self.assertEqual(post.body["site_id"], SITE_ID)  # kopya genel değil, servisin sitesinde oluşur
        self.assertEqual(post.body["body"]["meta"]["site_id"], SITE_ID)
        self.assertEqual(post.body["body"]["meta"]["name"], "Standart 2+1 (kopya)")
        self.assertFalse([c for c in self.dialogs.of("info") if c[1] == "Genel Şablon"])
        self.assert_no_callback_errors()

    def test_service_user_copy_of_a_general_template_needs_a_site_scope(self):
        self._template_routes()
        self.login_as("service_user")
        self.app.tpl_scope.current(0)
        self.app.refresh_templates()
        self.app.tpl_tree.selection_set("0")
        mark = len(self.api.calls)
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value="Kopya") as ask:
            self.app.duplicate_template()
        ask.assert_not_called()
        self.assertEqual(self.calls_after(mark), [])
        self.assertEqual(self.dialogs.of("info")[-1][1], "Genel Şablon")

    def test_root_still_edits_general_templates(self):
        self._template_routes()
        self.login_as("super_user")
        self.app.tpl_scope.current(0)
        self.app.refresh_templates()
        self.app.tpl_tree.selection_set("0")
        self.app.edit_template()
        self.assertIn("GET /api/v1/templates/%s" % GTID, self.api.paths())
        self.assertFalse([c for c in self.dialogs.of("info") if c[1] == "Genel Şablon"])

    def test_general_template_403_from_the_server_is_translated(self):
        self._template_routes()
        self.login_as("service_user")
        self.api.routes["DELETE /api/v1/templates/%s" % TID] = error(403, SERVER_403["global_template"], "FORBIDDEN")
        self.app.refresh_sites()
        self.app.tpl_scope.current(1)
        self.app.refresh_templates()
        own_row = next(row for row in self.app.tpl_tree.get_children() if str(self.app.tpl_tree.item(row)["values"][0]) == "B Tipi 3+1")
        self.app.tpl_tree.selection_set(own_row)
        self.app.delete_template()
        shown = self.dialogs.of("error")[-1]
        self.assertEqual((shown[1], shown[2]), ("Şablon Silinemedi", fc.FORBIDDEN_GLOBAL_TEMPLATE_TEXT))


def tool_module():
    return base.tool


def tool_ui():
    import site_template_ui  # noqa: PLC0415

    return site_template_ui


if __name__ == "__main__":
    unittest.main()
