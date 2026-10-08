# -*- coding: utf-8 -*-
"""
Site + kurulum şablonu (Faz 3, İP-3.1..3.6) testleri - donanımsız, internetsiz.

* Ortak örnek dosyalar (docs/contracts/template/fixtures): her ``ok_*`` geçerli, her ``bad_*`` TAM beklenen kodu verir.
* Model yardımcıları (panjur çifti, ek modül yeniden boyutlama, DI sensörü, zarf/parçalama, dimmer yönergesi).
* ``ServerClient`` site/daire/şablon/yazım uçları (sahte taşıma), ``service_user`` girişi.
* USB ``TPL`` yazımı: ``FakeFirmwareCli`` (TPL destekli) + sahte saat; Ethernet: gerçek 127.0.0.1 ``LoopbackHttpServer``.
* PDF kablolama şeması (sayfa boyutu, metinler, karekod) ve etiket daire satırı.
* Tk arayüzü: 5 sekme, servis sorumlusu yetkileri, site/şablon listeleri, düzenleyici, karta yazım akışı.
"""

import copy
import glob
import json
import os
import re
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
import template_model as tm  # noqa: E402
import wiring_pdf  # noqa: E402
from qr_decode import decode_qr_image  # noqa: E402
from serial_fakes import FakeClock, FakeFirmwareCli, FakeSerialBackend  # noqa: E402
import test_factory_tool as base  # noqa: E402 - FakeApi, LoopbackHttpServer, ağ koruması, AppSmokeTests altyapısı

FIXTURES = os.path.normpath(os.path.join(TOOL_DIR, "..", "docs", "contracts", "template", "fixtures"))
SITE_ID = "8c1d2e3f-4a5b-4c6d-8e7f-0123456789ab"
TID = "3f2a9c1e-5b7d-4e8f-9a01-23456789abcd"
FLAT_ID = "11111111-2222-4333-8444-555555555555"


def setUpModule():
    base.setUpModule()


def tearDownModule():
    base.tearDownModule()


def load_fixture(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


def ok_template(name="ok_3p1_vana_dimmer.json"):
    return load_fixture(name)


# ============================================================================================================
# Ortak örnek dosyalar (K-Ş2: üç uygulayıcı aynı sonucu vermeli)
# ============================================================================================================
class FixtureValidationTests(unittest.TestCase):
    def test_fixture_directory_has_ok_and_bad_examples(self):
        names = [os.path.basename(p) for p in glob.glob(os.path.join(FIXTURES, "*.json"))]
        self.assertGreaterEqual(len([n for n in names if n.startswith("ok_")]), 4)
        self.assertGreaterEqual(len([n for n in names if n.startswith("bad_")]), 20)

    def test_every_fixture_gives_the_expected_result(self):
        for path in sorted(glob.glob(os.path.join(FIXTURES, "*.json"))):
            name = os.path.basename(path)
            data = load_fixture(name)
            with self.subTest(ornek=name):
                if name.startswith("ok_"):
                    self.assertIsNone(tm.validate_template(data))
                else:
                    issue = tm.validate_template(data["template"])
                    self.assertIsNotNone(issue)
                    self.assertEqual(issue.code, data["expect"])

    def test_issue_text_is_turkish_and_has_code_and_path(self):
        issue = tm.validate_template(load_fixture("bad_shutter_runtime_mismatch.json")["template"])
        self.assertEqual(issue.path, "relays[1].runtime_s")
        self.assertIn("panjur", str(issue))
        self.assertIn("invalid_runtime @ relays[1].runtime_s", str(issue))

    def test_codes_for_cases_the_readme_left_open_match_the_firmware(self):
        def broken(mutate):
            t = load_fixture("ok_3p1_vana_dimmer.json")
            mutate(t)
            issue = tm.validate_template(t)
            return issue.code if issue else None

        cases = {
            "invalid_template_id": lambda t: t["meta"].update(template_id="xyz"),
            "invalid_version": lambda t: t["meta"].update(version=0),
            "invalid_name": lambda t: t["meta"].update(name=""),
            "invalid_flat_type": lambda t: t["meta"].update(flat_type="x" * 17),
            "invalid_site_id": lambda t: t["meta"].update(site_id="site-1"),
            "invalid_room": lambda t: t["relays"][0].update(room="R" * 32),
            "invalid_load": lambda t: t["relays"][0].update(load="L" * 49),
            "invalid_wiring": lambda t: t["dis"][0].update(wiring="W" * 49),
            "invalid_light": lambda t: t["safety"]["lights"][0].update(relay=1),
            "bad_relay": lambda t: t["safety"]["lights"][0].update(relay=41),
            "act_zone": lambda t: t["safety"]["actuators"][0].update(zones=[2]),
            "bad_zone": lambda t: t["safety"]["zones"].append({"id": 1, "name": "Tekrar"}),
            "bad_name": lambda t: t["safety"]["zones"][0].update(name="Z" * 16),
            "bad_kind": lambda t: t["safety"]["sensors"][0].update(kind="lava"),
            "bad_id": lambda t: t["safety"]["sensors"][0].update(id="d07"),
            "bad_value": lambda t: t["safety"]["actuators"][0].update(close_mode="maybe"),
            "bad_field": lambda t: t["safety"]["actuators"][0].update(id="a1"),
            "count": lambda t: t["safety"]["zones"].extend({"id": i, "name": "Z"} for i in range(2, 6)),
        }
        for code, mutate in cases.items():
            with self.subTest(kod=code):
                self.assertEqual(broken(mutate), code)
                self.assertIn(code, tm.ERROR_TEXTS) if code != "count" else None

    def test_unsafe_code_and_path_are_not_echoed(self):
        text = tm.describe_error("<script>", "a b{}")
        self.assertNotIn("<script>", text)
        self.assertNotIn("{", text)


class ModelHelperTests(unittest.TestCase):
    def test_new_template_is_valid_after_server_assigns_an_id(self):
        body = tm.new_template("Deneme", "2+1", SITE_ID)
        self.assertIsNone(tm.validate_template(body))
        self.assertEqual(body["meta"]["template_id"], tm.PLACEHOLDER_ID)

    def test_shutter_kind_always_builds_a_pair_and_breaking_it_cleans_partner(self):
        body = tm.new_template()
        tm.set_relay_kind(body, 4, "shutter", runtime_s=40)  # çift (3,4)
        self.assertEqual([r["type"] for r in body["relays"][2:4]], ["shutter_up", "shutter_down"])
        self.assertEqual({r["runtime_s"] for r in body["relays"][2:4]}, {40})
        body["dis"][0].update(target_relay=3, mode="shutter_step")
        self.assertIsNone(tm.validate_template(body))
        tm.set_relay_kind(body, 3, "impulse")
        self.assertEqual(body["relays"][2]["type"], "impulse")
        self.assertEqual(body["relays"][3]["type"], "light")
        self.assertNotIn("runtime_s", body["relays"][3])
        self.assertEqual(body["dis"][0]["mode"], "toggle")  # panjur kipi düz anahtara döndü
        self.assertIsNone(tm.validate_template(body))

    def test_shutter_runtime_is_written_to_both_relays(self):
        body = tm.new_template()
        tm.set_relay_kind(body, 1, "shutter")
        tm.set_shutter_runtime(body, 2, 55)
        self.assertEqual([body["relays"][0]["runtime_s"], body["relays"][1]["runtime_s"]], [55, 55])

    def test_actuator_on_relay_turned_into_shutter_is_dropped(self):
        body = ok_template()
        tm.set_relay_kind(body, 7, "shutter")  # R7-R8 çifti: R8'deki vana eylemcisi ve R5 dışı ışıklar
        self.assertEqual(body["safety"]["actuators"], [])
        self.assertIsNone(tm.validate_template(body))

    def test_relay_kind_side_effects_list_the_safety_items_that_would_be_deleted(self):
        body = ok_template()  # R8: 'Ana Su Vanası' (su vanası), R5: dimmer
        self.assertEqual(tm.relay_kind_side_effects(body, 7, "shutter"), ["R8 Ana Su Vanası (vana, su)"])  # eşin vanası
        self.assertEqual(tm.relay_kind_side_effects(body, 8, "impulse"), ["R8 Ana Su Vanası (vana, su)"])
        self.assertEqual(tm.relay_kind_side_effects(body, 5, "impulse"), ["R5 dimmer"])
        self.assertEqual(tm.relay_kind_side_effects(body, 5, "shutter"), ["R5 dimmer"])  # çift (5,6)
        self.assertEqual(tm.relay_kind_side_effects(body, 8, "light"), [])
        self.assertEqual(body, ok_template())  # yalnız listeler; modeli değiştirmez
        gas = ok_template("ok_dubleks_ekmodul16.json")
        self.assertEqual(tm.relay_kind_side_effects(gas, 15, "shutter"), ["R16 Gaz Vanası (vana, gaz)", "R15 İç Siren (siren)"])
        removed = tm.set_relay_kind(body, 8, "impulse")
        self.assertEqual(removed, ["R8 Ana Su Vanası (vana, su)"])
        self.assertEqual(body["safety"]["actuators"], [])

    def test_nc_hazard_inputs_and_the_workshop_warning(self):
        self.assertEqual(tm.nc_hazard_inputs(ok_template()), [])  # su sensörleri NO: atölyede alarm vermez
        self.assertEqual(tm.nc_hazard_inputs(ok_template("ok_dubleks_ekmodul16.json")), [(16, "gas", 1)])
        body = tm.new_template()
        tm.set_di_sensor(body, 3, "gas", zone=1)
        tm.set_di_sensor(body, 5, "water", zone=1, normally_closed=True)  # NC su: tehlike
        tm.set_di_sensor(body, 6, "water", zone=1)  # NO su: değil
        tm.set_di_sensor(body, 7, "door", zone=1, normally_closed=True)  # kapı: tehlike sensörü değil
        self.assertEqual(tm.nc_hazard_inputs(body), [(3, "gas", 1), (5, "water", 1)])
        self.assertEqual(tm.nc_hazard_warning([(3, "gas", 1)]),
                         "D3 (Gaz) NC: atölyede giriş boşsa kart hemen alarma geçip kilitlenir (vana kapanır, siren çalar). "
                         "Yazmadan önce girişi DI-GND köprüleyin ya da dedektörü bağlayın.")
        self.assertTrue(tm.nc_hazard_warning(tm.nc_hazard_inputs(body)).startswith("D3 (Gaz), D5 (Su baskını) NC:"))
        self.assertGreaterEqual(tm.nc_hazard_settle_seconds(body), 1.0)
        latched = tm.describe_error("zone_latched")
        self.assertIn("kilitli", latched)
        self.assertIn("Atölyede", latched)
        self.assertIn("SAFETY ACK", latched)

    def test_ext_module_resize_grows_and_shrinks_tables_and_cleans_references(self):
        body = ok_template("ok_dubleks_ekmodul16.json")
        self.assertEqual(tm.total_channels(body), 16)
        tm.set_ext_module(body, False, 0, 1)
        self.assertEqual(len(body["relays"]), 8)
        self.assertEqual(len(body["dis"]), 8)
        self.assertTrue(all(a["relay"] <= 8 for a in body["safety"]["actuators"]))
        self.assertFalse(any(s["id"] == "d16" for s in body["safety"]["sensors"]))
        self.assertIsNone(tm.validate_template(body))
        tm.set_ext_module(body, True, 32, 5)
        self.assertEqual(len(body["relays"]), 40)
        self.assertEqual(body["relays"][-1]["ch"], 40)
        self.assertIsNone(tm.validate_template(body))

    def test_gas_sensor_is_always_nc_and_clears_button_target(self):
        body = tm.new_template()
        body["dis"][2].update(target_relay=3, mode="toggle")
        tm.set_di_sensor(body, 3, "gas", zone=1, normally_closed=False)
        sensor = tm.di_sensor(body, 3)
        self.assertEqual(sensor["active_open"], 1)
        self.assertEqual(body["dis"][2]["target_relay"], 0)
        self.assertIsNone(tm.validate_template(body))
        tm.set_di_sensor(body, 3, None)
        self.assertIsNone(tm.di_sensor(body, 3))

    def test_envelope_chunks_fit_the_serial_line_and_reassemble(self):
        data = tm.envelope_bytes(ok_template(), "Güneş Sitesi A-12")
        chunks = tm.serial_chunks(data)
        self.assertTrue(all(len(c) <= 150 for c in chunks))
        self.assertTrue(all(len("TPL DATA " + c) <= 159 for c in chunks))
        import base64

        self.assertEqual(b"".join(base64.b64decode(c) for c in chunks), data)
        self.assertEqual(json.loads(data.decode("utf-8"))["label"], "Güneş Sitesi A-12")
        self.assertRegex(tm.crc32_hex(data), r"^[0-9a-f]{8}$")

    def test_label_limits(self):
        with self.assertRaises(ValueError):
            tm.envelope_bytes(ok_template(), "Ç" * 16)  # 32 bayt
        self.assertEqual(len(tm.default_label("Çok Uzun Bir Site Adı Örneği", "A", 12).encode("utf-8")) <= 31, True)
        self.assertEqual(tm.default_label("Güneş", "A", 12), "Güneş A-12")
        self.assertEqual(tm.default_label(template=ok_template()), "B Tipi 3+1")

    def test_flat_info_line(self):
        self.assertEqual(tm.flat_info_line("A", 12, "3+1", 4), "A Blok / Daire 12 · 3+1 · Şablon v4")
        self.assertEqual(tm.flat_info_line("", "", "", None), "")

    def test_dimmer_guidance_k4(self):
        self.assertIn("dimmer gerekmez", tm.dimmer_guidance(None, "Salon"))
        text = tm.dimmer_guidance({"dimmable": 1, "src": 1, "addr": 2, "ch": 1}, "Salon")
        self.assertIn("Modbus dimmer modülü", text)
        self.assertIn("adres 2", text)
        self.assertIn("köprü", tm.dimmer_guidance({"dimmable": 1, "src": 2, "addr": 1, "ch": 3}))
        body = tm.new_template()
        tm.set_light_dimmer(body, 2, True, src=1, addr=3, dim_ch=4)
        self.assertEqual(tm.light_option(body, 2)["addr"], 3)
        self.assertIsNone(tm.validate_template(body))
        tm.set_light_dimmer(body, 2, False)
        self.assertIsNone(tm.light_option(body, 2))

    def test_di_modes_describe_spring_buttons_not_latching_switches(self):
        self.assertIn("yaylı (kalıcı olmayan) buton; her basışta değiştirir", tm.DI_MODE_TEXT["toggle"])
        self.assertIn("basılıyken açık", tm.DI_MODE_TEXT["momentary"])
        for mode in ("shutter_step", "shutter_up", "shutter_down"):
            self.assertIn("yaylı buton", tm.DI_MODE_TEXT[mode])
        self.assertNotIn("anahtar", " ".join(tm.DI_MODE_TEXT.values()).lower())

    def test_duplicate_resets_identity(self):
        dup = tm.duplicate_template(ok_template(), "Kopya")
        self.assertEqual(dup["meta"]["template_id"], tm.PLACEHOLDER_ID)
        self.assertEqual(dup["meta"]["version"], 1)
        self.assertEqual(dup["relays"], ok_template()["relays"])

    def test_every_device_error_code_from_the_readme_has_a_turkish_text(self):
        for code in ("tpl_no_begin", "tpl_size", "tpl_crc", "tpl_overflow", "tpl_timeout", "bad_json",
                     "local_loosen_forbidden", "zone_latched", "armed", "busy", "storage"):
            with self.subTest(kod=code):
                self.assertIn(code, tm.ERROR_TEXTS)
        # Firmware artık LAN'da local_loosen_forbidden döndürmez; eski kartlar için zararsız eşleme kalır ("USB ile yazın" yönergesi YOK).
        self.assertNotIn("USB ile yazın", tm.describe_error("local_loosen_forbidden"))


# ============================================================================================================
# Sunucu uçları (CONTRACTS §3e)
# ============================================================================================================
def site_routes(api, *, flats=None, templates=None, body=None):
    flats = flats if flats is not None else [{"id": FLAT_ID, "site_id": SITE_ID, "block": "A", "number": 12, "flat_type": "3+1",
                                              "template_id": TID, "device_uuid": None, "status": "planned", "last_write": None}]
    templates = templates if templates is not None else [{"id": TID, "site_id": SITE_ID, "name": "B Tipi 3+1", "flat_type": "3+1",
                                                          "current_version": 4, "updated_at": "2026-10-08T10:00:00Z"}]
    body = body or ok_template()

    def ok(data, status=200):
        return lambda call: (status, {"success": True, "message": "ok", "data": data}, {})

    api.routes["GET /api/v1/sites"] = ok([{"id": SITE_ID, "name": "Güneş Sitesi", "city": "Ankara", "district": "Çankaya",
                                          "contact_name": "Ali", "contact_phone": "0555 000 00 00", "block_count": 2,
                                          "flat_count": 48, "flat_stats": {"planned": 46, "written": 2, "installed": 0, "handed_over": 0}}])
    api.routes["POST /api/v1/sites"] = ok({"id": SITE_ID}, 201)
    api.routes[f"PATCH /api/v1/sites/{SITE_ID}"] = ok({"id": SITE_ID})
    api.routes[f"DELETE /api/v1/sites/{SITE_ID}"] = ok(None)
    api.routes[f"GET /api/v1/sites/{SITE_ID}/flats"] = ok(flats)
    api.routes[f"POST /api/v1/sites/{SITE_ID}/flats/bulk"] = ok([{"id": "f-%d" % i} for i in range(3)], 201)
    api.routes[f"PATCH /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}"] = ok({"id": FLAT_ID})
    api.routes[f"DELETE /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}"] = ok(None)
    api.routes[f"PUT /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}/device"] = ok({"id": FLAT_ID})
    api.routes["GET /api/v1/templates"] = ok(templates)
    api.routes["POST /api/v1/templates"] = ok({"id": TID, "current_version": 1}, 201)
    api.routes[f"GET /api/v1/templates/{TID}"] = ok({"id": TID, "current_version": 4, "body": body})
    api.routes[f"PUT /api/v1/templates/{TID}"] = ok({"id": TID, "current_version": 5})
    api.routes[f"DELETE /api/v1/templates/{TID}"] = ok(None)
    api.routes[f"GET /api/v1/templates/{TID}/versions"] = ok([{"version": 4, "sha256": "ab" * 32, "created_at": "2026-10-08T10:00:00Z", "created_by": "a@b"}])
    api.routes[f"GET /api/v1/templates/{TID}/versions/4"] = ok({"version": 4, "body": body})
    api.routes["POST /api/v1/templates/validate"] = ok({"ok": True})
    api.routes["POST /api/v1/template-writes"] = ok({"id": "w-1"}, 201)
    api.routes[f"GET /api/v1/admin/inventory/{base.UID}/local-key"] = ok({"local_key": base.FAKE_LOCAL_KEY})


class ServerClientSiteTests(unittest.TestCase):
    def client(self, role="service_user"):
        client, api = base.make_client()
        api.login_role = role
        site_routes(api)
        client.login("servis@example.com", base.FAKE_PASSWORD)
        return client, api

    def test_service_user_can_log_in_and_role_text_is_shown(self):
        client, api = self.client()
        self.assertTrue(client.is_authenticated)
        self.assertEqual(client.role_text, "servis sorumlusu")
        self.assertFalse(client.can_manage_inventory)
        self.assertNotIn("POST /api/v1/auth/logout", api.paths())

    def test_other_roles_are_still_rejected(self):
        client, api = base.make_client()
        api.login_role = "user"
        with self.assertRaises(fc.ApiError) as ctx:
            client.login("a@example.com", base.FAKE_PASSWORD)
        self.assertIn("servis sorumlusu", str(ctx.exception))
        self.assertFalse(client.is_authenticated)

    def test_site_and_flat_endpoints(self):
        client, api = self.client()
        self.assertEqual(client.list_sites()[0]["name"], "Güneş Sitesi")
        client.create_site({"name": "X"})
        self.assertEqual(api.calls[-1].body, {"name": "X"})
        client.update_site(SITE_ID, {"notes": "n"})
        client.delete_site(SITE_ID)
        self.assertEqual(len(client.list_flats(SITE_ID)), 1)
        created = client.bulk_create_flats(SITE_ID, block="A", start=1, end=3, flat_type="3+1", template_id=TID)
        self.assertEqual(len(created), 3)
        self.assertEqual(api.calls[-1].body, {"block": "A", "from": 1, "to": 3, "flat_type": "3+1", "template_id": TID})
        client.update_flat(SITE_ID, FLAT_ID, {"template_id": TID})
        client.link_flat_device(SITE_ID, FLAT_ID, "ahbu-s3-dd8754")
        self.assertEqual(api.calls[-1].body, {"device_uuid": base.UID})
        client.link_flat_device(SITE_ID, FLAT_ID, None)
        self.assertEqual(api.calls[-1].body, {"device_uuid": None})
        client.delete_flat(SITE_ID, FLAT_ID)
        self.assertTrue(all(c.headers.get("authorization", "").startswith("Bearer ") for c in api.calls[1:]))

    def test_template_endpoints(self):
        client, api = self.client()
        self.assertEqual(client.list_templates(SITE_ID)[0]["id"], TID)
        self.assertIn("site_id=" + SITE_ID, api.calls[-1].query)
        self.assertIn("include_global=1", api.calls[-1].query)
        client.list_templates(None)
        self.assertNotIn("site_id", api.calls[-1].query)
        body = ok_template()
        client.validate_template_remote(body)
        self.assertEqual(api.calls[-1].body, {"body": body})
        client.create_template(SITE_ID, body)
        self.assertEqual(api.calls[-1].body, {"site_id": SITE_ID, "body": body})
        self.assertEqual(client.update_template(TID, body)["current_version"], 5)
        self.assertEqual(client.get_template(TID)["body"], body)
        self.assertEqual(client.list_template_versions(TID)[0]["version"], 4)
        self.assertEqual(client.get_template_version(TID, 4)["body"], body)
        client.delete_template(TID)
        self.assertEqual(api.calls[-1].method, "DELETE")

    def test_update_template_sends_the_base_version_and_reports_a_concurrent_change(self):
        client, api = self.client()
        body = ok_template()
        client.update_template(TID, body, base_version=4)
        self.assertEqual(api.calls[-1].body, {"body": body, "base_version": 4})
        client.update_template(TID, body)  # üstüne yazma: base_version gönderilmez
        self.assertEqual(api.calls[-1].body, {"body": body})
        api.routes[f"PUT /api/v1/templates/{TID}"] = lambda call: (
            409, {"success": False, "code": "TEMPLATE_CHANGED", "message": "Şablon değişti.", "data": {"current_version": 6}}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.update_template(TID, body, base_version=4)
        self.assertEqual((ctx.exception.status, ctx.exception.code), (409, "TEMPLATE_CHANGED"))
        self.assertEqual(ctx.exception.data.get("current_version"), 6)

    def test_validate_422_carries_template_code_and_path(self):
        client, api = self.client()
        api.routes["POST /api/v1/templates/validate"] = lambda call: (
            422, {"success": False, "code": "TEMPLATE_INVALID", "message": "Şablon geçersiz.", "error": "invalid_runtime",
                  "path": "relays[1].runtime_s"}, {})
        with self.assertRaises(fc.ApiError) as ctx:
            client.validate_template_remote(ok_template())
        self.assertEqual((ctx.exception.status, ctx.exception.code), (422, "TEMPLATE_INVALID"))
        self.assertEqual((ctx.exception.detail, ctx.exception.path), ("invalid_runtime", "relays[1].runtime_s"))

    def test_template_write_record_and_validation(self):
        client, api = self.client()
        client.record_template_write(device_uuid=base.UID, template_id=TID, version=4, via="usb", result="ok", flat_id=FLAT_ID)
        self.assertEqual(api.calls[-1].body, {"device_uuid": base.UID, "template_id": TID, "version": 4, "via": "usb",
                                              "result": "ok", "flat_id": FLAT_ID})
        client.record_template_write(device_uuid=base.UID, template_id=TID, version=4, via="eth", result="error",
                                     error_code="local_loosen_forbidden")
        self.assertEqual(api.calls[-1].body["error_code"], "local_loosen_forbidden")
        with self.assertRaises(fc.FactoryError):
            client.record_template_write(device_uuid=base.UID, template_id=TID, version=4, via="wifi", result="ok")

    def test_local_key_is_tracked_by_the_scrubber_and_never_in_messages(self):
        scrubber = fc.SecretScrubber()
        client, api = base.make_client(scrubber=scrubber)
        api.login_role = "service_user"
        site_routes(api)
        client.login("s@example.com", base.FAKE_PASSWORD)
        key = client.fetch_local_key(base.UID)
        self.assertEqual(key, base.FAKE_LOCAL_KEY)
        self.assertEqual(scrubber.scrub("anahtar " + key), "anahtar ***")
        self.assertEqual(api.calls[-1].path, f"/api/v1/admin/inventory/{base.UID}/local-key")

    def test_ids_cannot_inject_paths(self):
        client, api = self.client()
        for bad in ("../admin", "a/b", "x?y=1", ""):
            with self.subTest(kimlik=bad), self.assertRaises(fc.FactoryError):
                client.get_template(bad)

    def test_api_key_mode_cannot_manage_sites(self):
        client, api = base.make_client(env={fc.ENV_API_KEY: "k" * 40})
        client.use_api_key()
        with self.assertRaises(fc.ApiError):
            client.list_sites()


# ============================================================================================================
# USB (seri TPL) yazımı
# ============================================================================================================
class SerialTemplateWriterTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()

    def writer(self, **firmware_kwargs):
        self.firmware = FakeFirmwareCli(mac=base.MAC, provisioned=True, **firmware_kwargs)
        self.backend = FakeSerialBackend(self.firmware, self.clock)
        return fc.TemplateSerialWriter(self.backend, clock=self.clock.now, sleep=self.clock.sleep)

    def envelope(self, label="Güneş Sitesi A-12"):
        return tm.envelope_bytes(ok_template(), label)

    def test_write_commits_and_reads_back(self):
        progress = []
        outcome = self.writer().write("COM7", self.envelope(), template_id=TID, version=4, label="Güneş Sitesi A-12",
                                      progress=progress.append)
        self.assertEqual((outcome.template_id, outcome.version, outcome.via), (TID, 4, "usb"))
        self.assertEqual(outcome.device_uid, base.UID)
        self.assertEqual(outcome.label, "Güneş Sitesi A-12")
        self.assertEqual(self.firmware.tpl_applied[0]["template"], ok_template())
        commands = [c for c in self.firmware.received if c.startswith("TPL")]
        self.assertTrue(commands[0].startswith("TPL BEGIN "))
        self.assertEqual(commands[-2:], ["TPL COMMIT", "TPL STATUS"])
        self.assertTrue(all(len(c) <= 159 for c in self.firmware.received))
        self.assertTrue(self.backend.all_closed())
        # gövde (base64) ilerleme metnine yazılmaz
        self.assertFalse(any("TPL DATA" in p for p in progress))

    def test_device_error_is_reported_with_code_and_path(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer(tpl_error="invalid_runtime relays[1].runtime_s").write("COM7", self.envelope(), template_id=TID, version=4)
        self.assertEqual((ctx.exception.code, ctx.exception.path), ("invalid_runtime", "relays[1].runtime_s"))
        self.assertIn("panjur", str(ctx.exception))

    def test_zone_latched_and_storage(self):
        for code in ("zone_latched", "storage", "armed", "busy"):
            with self.subTest(kod=code), self.assertRaises(fc.TemplateWriteError) as ctx:
                self.writer(tpl_error=code).write("COM7", self.envelope(), template_id=TID, version=4)
            self.assertEqual(ctx.exception.code, code)

    def test_corrupted_transfer_is_rejected_by_crc_and_nothing_changes(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer(tpl_drop_data=1).write("COM7", self.envelope(), template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "tpl_crc")
        self.assertIsNone(self.firmware.tpl_id)
        self.assertIn("CRC", str(ctx.exception))

    def test_old_firmware_says_update_first(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer(tpl_supported=False).write("COM7", self.envelope(), template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "unsupported_fw")
        self.assertIn("v1.3.0", str(ctx.exception))

    def test_wrong_board_is_detected_before_anything_is_sent(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer().write("COM7", self.envelope(), template_id=TID, version=4, expected_uid="AHBU-S3-000001")
        self.assertEqual(ctx.exception.code, "mac_mismatch")
        self.assertFalse(any(c.startswith("TPL") for c in self.firmware.received))

    def test_readback_mismatch_is_an_error(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer().write("COM7", self.envelope(), template_id=TID, version=5)  # kart v4 dedi
        self.assertEqual(ctx.exception.code, "readback_mismatch")

    def test_oversized_envelope_is_refused_locally(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer().write("COM7", b"x" * (tm.MAX_ENVELOPE_BYTES + 1), template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "tpl_size")

    def test_error_codes_with_digits_are_parsed(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer(tpl_error="tpl_b64").write("COM7", self.envelope(), template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "tpl_b64")
        self.assertIn("base64", str(ctx.exception))

    def test_unknown_board_identity_stops_before_begin_when_a_board_is_expected(self):
        writer = self.writer()
        self.firmware.mac = "??"  # STATUS'ta MAC okunamaz
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            writer.write("COM7", self.envelope(), template_id=TID, version=4, expected_uid=base.UID)
        self.assertEqual(ctx.exception.code, "mac_mismatch")
        self.assertIn("doğrulanamadı", str(ctx.exception))
        self.assertFalse(any(c.startswith("TPL") for c in self.firmware.received))

    def test_lost_commit_reply_is_resolved_with_tpl_status(self):
        outcome = self.writer(tpl_mute_commit=True).write("COM7", self.envelope("A-12"), template_id=TID, version=4)
        self.assertEqual((outcome.template_id, outcome.version), (TID, 4))
        self.assertNotIn("TPL ABORT", self.firmware.received)

    def test_lost_commit_reply_without_apply_aborts_with_error(self):
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            self.writer(tpl_mute_commit=True, tpl_error="storage").write("COM7", self.envelope(), template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "no_response")
        self.assertIn("TPL ABORT", self.firmware.received)
        self.assertEqual(ctx.exception.device_uid, base.UID)  # yazım kaydı için kart biliniyor

    def test_safety_status_lines_are_parsed(self):
        summary = fc.parse_safety_lines([
            "[CLI] Komut alindi: SAFETY",
            "[GUVENLIK] politika=ACIK kip=normal rev=3 acilis=2 bn=0000abcd",
            "- Bolge 1: latched (aid 3f2a, 5 sn once, caliyor)",
            "- Bolge 3: fault (aid 0000, 1 sn once, susturuldu)",
            "- Sensor d16 (gaz, bolge 1): AKTIF",
        ])
        self.assertTrue(summary.seen)
        self.assertEqual((summary.latched, summary.faults), ([1], [3]))
        normal = fc.parse_safety_lines(["[GUVENLIK] politika=ACIK kip=normal rev=1 acilis=1 bn=0", "- Butun bolgeler NORMAL"])
        self.assertEqual((normal.seen, normal.latched), (True, []))
        self.assertFalse(fc.parse_safety_lines(["- Bolge 1: latched (aid x)"]).seen)  # başlıksız satır sayılmaz

    def test_usb_write_of_an_nc_hazard_template_reads_safety_and_reports_latched_zones(self):
        gas = ok_template("ok_dubleks_ekmodul16.json")
        writer = self.writer(latch_nc_hazards=True)
        outcome = writer.write("COM7", tm.envelope_bytes(gas, "A-1"), template_id=TID, version=2, read_safety=True,
                               safety_settle_s=2.0)
        self.assertTrue(outcome.safety_checked)
        self.assertEqual(outcome.latched_zones, [1])
        self.assertIn("SAFETY", self.firmware.commands)
        writer = self.writer(latch_nc_hazards=True)
        outcome = writer.write("COM7", tm.envelope_bytes(gas, "A-1"), template_id=TID, version=2)
        self.assertNotIn("SAFETY", self.firmware.commands)  # istenmedikçe SAFETY okunmaz
        self.assertEqual(outcome.latched_zones, [])

    def test_alarm_acknowledge_sends_safety_ack_and_reads_back(self):
        gas = ok_template("ok_dubleks_ekmodul16.json")
        writer = self.writer(latch_nc_hazards=True)
        writer.write("COM7", tm.envelope_bytes(gas, "A-1"), template_id=TID, version=2)
        self.assertEqual(self.firmware.latched_zones, [1])
        still = writer.acknowledge_alarm("COM7", [1])  # giriş köprülenmedi: kilit sürer
        self.assertIn("SAFETY ACK 1", self.firmware.received)
        self.assertEqual(still.latched, [1])
        self.firmware.inputs_bridged = True
        done = writer.acknowledge_alarm("COM7", [1])
        self.assertEqual(done.latched, [])
        self.assertTrue(self.backend.all_closed())

    def test_write_reports_fault_zones_and_whether_safety_could_be_read(self):
        gas = ok_template("ok_dubleks_ekmodul16.json")
        outcome = self.writer(fault_zones=[2]).write("COM7", tm.envelope_bytes(gas, "A-1"), template_id=TID, version=2,
                                                     read_safety=True, safety_settle_s=0)
        self.assertTrue(outcome.safety_checked)
        self.assertEqual((outcome.latched_zones, outcome.fault_zones), ([], [2]))
        outcome = self.writer(safety_silent=True).write("COM7", tm.envelope_bytes(gas, "A-1"), template_id=TID, version=2,
                                                        read_safety=True, safety_settle_s=0)
        self.assertFalse(outcome.safety_checked)  # SAFETY başlığı gelmedi: durum BİLİNMİYOR (normal değil)
        self.assertEqual((outcome.latched_zones, outcome.fault_zones), ([], []))

    def test_alarm_acknowledge_does_not_clear_a_valve_fault_zone(self):
        # Firmware: ack() FAULT bölgesini onaylar ama canClear() yalnız LATCHED bölgeyi temizler.
        writer = self.writer(fault_zones=[2], inputs_bridged=True)
        summary = writer.acknowledge_alarm("COM7", [0], settle_s=0)
        self.assertIn("SAFETY ACK 0", self.firmware.received)
        self.assertEqual((summary.seen, summary.latched, summary.faults), (True, [], [2]))

    def test_identified_hook_runs_before_anything_is_written_and_can_abort(self):
        seen = []
        writer = self.writer()
        writer.write("COM7", self.envelope(), template_id=TID, version=4,
                     on_identified=lambda uid: seen.append((uid, any(c.startswith("TPL") for c in self.firmware.received))))
        self.assertEqual(seen, [(base.UID, False)])

        def refuse(uid):
            raise fc.TemplateWriteError("flat_link_failed", message=f"Kart {uid} başka bir daireye bağlı; şablon yazılmadı.")

        writer = self.writer()
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            writer.write("COM7", self.envelope(), template_id=TID, version=4, on_identified=refuse)
        self.assertEqual(ctx.exception.code, "flat_link_failed")
        self.assertFalse(any(c.startswith("TPL") for c in self.firmware.received))
        self.assertTrue(self.backend.all_closed())

    def test_read_status(self):
        writer = self.writer()
        writer.write("COM7", self.envelope("A-12"), template_id=TID, version=4)
        self.assertEqual(writer.read_status("COM7"), (TID, 4, "A-12"))

    def test_stub_serial_package_still_builds_with_tpl_support(self):
        from serial_fakes import write_stub_serial_package

        with tempfile.TemporaryDirectory() as tmp:
            package = write_stub_serial_package(tmp)
            with open(os.path.join(package, "__init__.py"), encoding="utf-8") as handle:
                compile(handle.read(), "serial/__init__.py", "exec")


# ============================================================================================================
# Ethernet (LAN) yazımı - gerçek 127.0.0.1 HTTP
# ============================================================================================================
class LanTemplateWriterTests(unittest.TestCase):
    def handler_for(self, state):
        def handler(request):
            if request.headers.get("x-device-key") != base.FAKE_LOCAL_KEY:
                return 401, {"error": "unauthorized"}, {}
            if request.path == "/api/template/apply" and request.method == "POST":
                if state.get("error"):
                    return state["error"]
                meta = request.body["template"]["meta"]
                state["applied"] = request
                state["tpl"] = {"template_id": meta["template_id"], "version": meta["version"], "label": request.body.get("label", "")}
                return 200, {"ok": True, "template_id": meta["template_id"], "version": meta["version"], "rev": 7}, {}
            if request.path == "/api/template" and request.method == "GET":
                return 200, dict(state.get("tpl") or {"template_id": None, "version": 0}, applied_at_uptime_s=5), {}
            return 404, {"error": "not_found"}, {}
        return handler

    def test_apply_and_read_back_over_loopback(self):
        state = {}
        with base.LoopbackHttpServer(self.handler_for(state)) as server:
            writer = fc.TemplateLanWriter(f"127.0.0.1:{server.port}")
            outcome = writer.write(base.FAKE_LOCAL_KEY, tm.envelope_bytes(ok_template(), "Güneş A-12"), template_id=TID,
                                   version=4, label="Güneş A-12", device_uid=base.UID)
        self.assertEqual((outcome.via, outcome.version, outcome.rev, outcome.label), ("eth", 4, 7, "Güneş A-12"))
        applied = state["applied"]
        self.assertIn("Güneş".encode("utf-8"), applied.raw)  # UTF-8, kaçışsız
        self.assertEqual(applied.headers["x-device-key"], base.FAKE_LOCAL_KEY)
        self.assertEqual(server.requests[-1].path, "/api/template")

    def test_old_board_loosen_forbidden_is_mapped_without_usb_guidance(self):
        state = {"error": (403, {"error": "local_loosen_forbidden"}, {})}
        with base.LoopbackHttpServer(self.handler_for(state)) as server:
            writer = fc.TemplateLanWriter(f"127.0.0.1:{server.port}")
            with self.assertRaises(fc.TemplateWriteError) as ctx:
                writer.apply(base.FAKE_LOCAL_KEY, tm.envelope_bytes(ok_template()))
        self.assertEqual(ctx.exception.code, "local_loosen_forbidden")
        self.assertFalse(hasattr(ctx.exception, "use_usb"))
        self.assertNotIn("USB ile yazın", str(ctx.exception))

    def test_error_mapping(self):
        cases = [
            ((400, {"error": "invalid_runtime", "path": "relays[1].runtime_s"}), "invalid_runtime"),
            ((409, {"error": "zone_latched"}), "zone_latched"),
            ((409, {"error": "busy"}), "busy"),
            ((507, {"error": "storage"}), "storage"),
            ((404, {"error": "not_found"}), "unsupported_fw"),
            ((423, {"error": "locked"}), "locked"),
            ((403, {"error": "unprovisioned"}), "unprovisioned"),
            ((400, {"error": "invalid_json"}), "invalid_json"),
            ((400, {"error": "invalid_label"}), "invalid_label"),
            ((409, {"error": "cfg_invalid", "detail": "act_relay_shutter"}), "cfg_invalid"),
        ]
        for (status, payload), code in cases:
            state = {"error": (status, payload, {})}
            with self.subTest(kod=code), base.LoopbackHttpServer(self.handler_for(state)) as server:
                with self.assertRaises(fc.TemplateWriteError) as ctx:
                    fc.TemplateLanWriter(f"127.0.0.1:{server.port}").apply(base.FAKE_LOCAL_KEY, b"{}")
                self.assertEqual(ctx.exception.code, code)
                if code == "unprovisioned":
                    self.assertIn("Önce provizyon yapın", str(ctx.exception))
                if code == "cfg_invalid":
                    self.assertIn("panjur rölesine", str(ctx.exception))

    def test_pending_apply_is_polled_until_the_template_appears(self):
        state = {"polls": 0}

        def device(method, url, headers, body, timeout):
            if url.endswith("/api/template/apply"):
                return fc.TransportResponse(202, {}, json.dumps({"pending": True}).encode())
            if url.endswith("/api/template"):
                state["polls"] += 1
                done = state["polls"] >= 3
                return fc.TransportResponse(200, {}, json.dumps(
                    {"template_id": TID if done else None, "version": 4 if done else 0, "label": "A-12"}).encode())
            return fc.TransportResponse(404, {}, b"{}")

        sleeps = []
        writer = fc.TemplateLanWriter("192.168.1.60", transport=device, sleep=sleeps.append)
        outcome = writer.write(base.FAKE_LOCAL_KEY, b"{}", template_id=TID, version=4)
        self.assertEqual((outcome.template_id, outcome.version), (TID, 4))
        self.assertEqual(sleeps, [1.0, 1.0])

    def test_pending_that_never_finishes_times_out_after_20s(self):
        def device(method, url, headers, body, timeout):
            if url.endswith("/api/template/apply"):
                return fc.TransportResponse(202, {}, json.dumps({"pending": True}).encode())
            return fc.TransportResponse(200, {}, json.dumps({"template_id": None, "version": 0}).encode())

        sleeps = []
        with self.assertRaises(fc.TemplateWriteError) as ctx:
            fc.TemplateLanWriter("192.168.1.60", transport=device, sleep=sleeps.append).write(
                base.FAKE_LOCAL_KEY, b"{}", template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "tpl_timeout")
        self.assertEqual(sum(sleeps), 20.0)

    def test_network_error_after_post_is_resolved_by_reading_back(self):
        def applied(method, url, headers, body, timeout):
            if url.endswith("/api/template/apply"):
                raise fc.NetworkError("koptu")
            return fc.TransportResponse(200, {}, json.dumps({"template_id": TID, "version": 4, "label": "A-12"}).encode())

        outcome = fc.TemplateLanWriter("192.168.1.60", transport=applied).write(base.FAKE_LOCAL_KEY, b"{}", template_id=TID, version=4)
        self.assertEqual(outcome.version, 4)

        def not_applied(method, url, headers, body, timeout):
            if url.endswith("/api/template/apply"):
                raise fc.NetworkError("koptu")
            return fc.TransportResponse(200, {}, json.dumps({"template_id": None, "version": 0}).encode())

        with self.assertRaises(fc.TemplateWriteError) as ctx:
            fc.TemplateLanWriter("192.168.1.60", transport=not_applied).write(base.FAKE_LOCAL_KEY, b"{}", template_id=TID, version=4)
        self.assertEqual(ctx.exception.code, "unreachable")

    def test_factory_init_over_ethernet_is_refused_with_turkish_hint(self):
        device = base.FakeDevice()
        device.init_error = (403, {"error": "factory_ap_only"})
        client = fc.DeviceClient("192.168.1.60", transport=device, env={})
        with self.assertRaises(fc.ProvisionError) as ctx:
            client.factory_init(base.FAKE_LOCAL_KEY, "Abcdefgh23")
        self.assertEqual(ctx.exception.code, "factory_ap_only")
        self.assertIn("eski firmware", fc.provision_error_text(ctx.exception))
        self.assertIn("factory_ap_only", tm.ERROR_TEXTS)

    def test_wrong_key_and_unreachable(self):
        with base.LoopbackHttpServer(self.handler_for({})) as server:
            with self.assertRaises(fc.TemplateWriteError) as ctx:
                fc.TemplateLanWriter(f"127.0.0.1:{server.port}").apply("WRONG-KEY-123", b"{}")
        self.assertEqual(ctx.exception.code, "key_mismatch")

        def down(*_args):
            raise fc.NetworkError("yok")

        with self.assertRaises(fc.TemplateWriteError) as ctx:
            fc.TemplateLanWriter("192.168.1.50", transport=down).apply(base.FAKE_LOCAL_KEY, b"{}")
        self.assertEqual(ctx.exception.code, "unreachable")

    def test_only_local_addresses_are_accepted(self):
        for host in ("8.8.8.8", "evotomasyon.gudeteknoloji.com.tr", "http://192.168.1.2", ""):
            with self.subTest(adres=host), self.assertRaises(ValueError):
                fc.TemplateLanWriter(host)


# ============================================================================================================
# PDF kablolama şeması ve etiket daire satırı
# ============================================================================================================
class WiringPdfTests(unittest.TestCase):
    def test_pdf_is_a4_300dpi_multipage_with_footer_and_qr(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sema.pdf")
            doc = wiring_pdf.save_wiring_pdf(path, ok_template(), site_name="Güneş Sitesi", block="A", number=12)
            with open(path, "rb") as handle:
                data = handle.read()
        self.assertTrue(data.startswith(b"%PDF"))
        self.assertEqual(len(re.findall(rb"/Type\s*/Page\b", data)), len(doc.pages))
        self.assertGreaterEqual(len(doc.pages), 2)
        self.assertTrue(all(page.size == wiring_pdf.PAGE_SIZE for page in doc.pages))
        media = re.search(rb"/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]", data)
        self.assertAlmostEqual(float(media.group(1)), 595.2, places=1)   # A4 genişlik (pt)
        self.assertAlmostEqual(float(media.group(2)), 841.92, places=1)  # A4 yükseklik (pt)
        texts = " ".join(" ".join(doc.texts).split())  # satır kaydırması: sözcükler boşlukla birleşir
        for needle in ("Güneş Sitesi", "A Blok / Daire 12", "B Tipi 3+1", "3+1", "v4", "Bu şema şablon sürümü v4 içindir",
                       "R1 COM|NO", "D8 DI|GND", "Salon panjur motoru (yukarı)", "Panjur YUKARI yön ucu", "kilit",
                       "Su baskını · NO (normalde açık) · bölge 1", "Modbus dimmer modülü", "Enerji verince kapanır",
                       "Evye altı", "Kalıcı (mandallı) duvar anahtarı DESTEKLENMEZ; tüm girişlere yaylı buton bağlayın",
                       "Aç/Kapa – yaylı (kalıcı olmayan) buton; her basışta değiştirir"):
            with self.subTest(metin=needle):
                self.assertIn(needle.lower(), texts.lower())
        self.assertEqual(decode_qr_image(doc.pages[0], doc.qr_box), f"AHBU-TPL:{TID}:v4")

    def test_gas_warning_and_ext_module_block(self):
        doc = wiring_pdf.build_wiring_document(ok_template("ok_dubleks_ekmodul16.json"))
        texts = "\n".join(doc.texts)
        self.assertIn("EN 50194", texts)
        self.assertIn("Ek modül (RS485 Modbus): adres 1, 8 kanal", texts)
        self.assertIn("R16 COM|NO", texts)
        self.assertIn("NC (normalde kapalı)", texts)
        self.assertIn("Enerji kesilince kapanır", texts)

    def test_invalid_template_is_refused(self):
        with self.assertRaises(ValueError):
            wiring_pdf.build_wiring_document(load_fixture("bad_shutter_swapped.json")["template"])

    def test_header_carries_the_card_uid(self):
        doc = wiring_pdf.build_wiring_document(ok_template(), site_name="Güneş Sitesi", block="A", number=12, device_uid=base.UID)
        self.assertIn("Kart UID:", doc.texts)
        self.assertEqual(doc.texts[doc.texts.index("Kart UID:") + 1], base.UID)
        unknown = wiring_pdf.build_wiring_document(ok_template())
        self.assertEqual(unknown.texts[unknown.texts.index("Kart UID:") + 1], "-")

    def test_flat_label_has_the_identity_and_no_secrets(self):
        import inspect

        label = wiring_pdf.build_flat_label(device_uid=base.UID, site_name="Güneş Sitesi", block="A", number=12,
                                            template_name="B Tipi 3+1", version=4, flat_type="3+1")
        texts = " ".join(label.texts)
        for needle in (base.UID, "Güneş Sitesi", "A Blok / Daire 12", "B Tipi 3+1", "v4", "3+1"):
            with self.subTest(metin=needle):
                self.assertIn(needle, texts)
        self.assertEqual(label.image.size, wiring_pdf.FLAT_LABEL_SIZE)
        params = set(inspect.signature(wiring_pdf.build_flat_label).parameters)
        self.assertFalse(params & {"pin", "ap_pass", "local_key", "qr_claim_url", "password"})  # gizli değer alınmaz bile
        self.assertIn("içermez", texts)

    def test_font_fallback_still_produces_ascii_text(self):
        doc = wiring_pdf.build_wiring_document(ok_template(), font_loader=lambda c, s: (wiring_pdf.ImageFont.load_default(), False))
        self.assertTrue(doc.pages)


@unittest.skipIf(base.tool is None or base.TOOL_IMPORT_ERROR, "arayüz bağımlılıkları yok")
class LabelFlatLineTests(unittest.TestCase):
    def record(self, info=""):
        return fc.DeviceRecord(uid=base.UID, mac=base.MAC, pin="123456", local_key=base.FAKE_LOCAL_KEY, ap_pass="Abcdefgh23",
                               qr_claim_url=fc.build_claim_url(base.UID, "123456"), flat_info=info)

    def test_flat_line_is_drawn_only_when_given(self):
        plain = base.tool.build_label_image(self.record())
        with_flat = base.tool.build_label_image(self.record("A Blok / Daire 12 · 3+1 · Şablon v4"))
        self.assertEqual(plain.size, with_flat.size)
        footer = (230, plain.height - 34, 570, plain.height - 8)
        self.assertNotEqual(plain.crop(footer).tobytes(), with_flat.crop(footer).tobytes())
        top = (0, 0, plain.width, plain.height - 40)
        self.assertEqual(plain.crop(top).tobytes(), with_flat.crop(top).tobytes())  # QR'lar ve gövde değişmez


# ============================================================================================================
# Tk arayüzü
# ============================================================================================================
@unittest.skipIf(base.tool is None or base.TOOL_IMPORT_ERROR, "arayüz bağımlılıkları yok")
class SiteTemplateAppTests(base.AppSmokeTests):
    """AppSmokeTests altyapısı (sahte ağ/seri/iletişim kutuları) ile; miras alınan testler burada TEKRAR koşmaz."""

    def setUp(self):
        super().setUp()
        site_routes(self.api)
        self.firmware.provisioned = True

    def run(self, result=None):  # yalnız bu sınıfta tanımlı testler (test_ ile başlayan, burada yazılanlar)
        if self._testMethodName not in type(self).__dict__:
            return result
        return super().run(result)

    def login_as(self, role):
        self.api.login_role = role
        self.patch_login()
        self.app.login_clicked()

    def test_five_tabs_with_sites_and_templates(self):
        titles = [self.app.notebook.tab(i, "text") for i in range(self.app.notebook.index("end"))]
        self.assertEqual(len(titles), 5)
        self.assertEqual(titles[3], "🏢 4. Siteler")
        self.assertEqual(titles[4], "📐 5. Şablonlar")
        self.assert_no_callback_errors()

    def test_service_user_sees_role_and_inventory_actions_are_disabled(self):
        self.login_as("service_user")
        self.assertIn("servis sorumlusu", self.app.lbl_session.cget("text"))
        for button in (self.app.btn_register_device, self.app.btn_suspend, self.app.btn_activate, self.app.btn_delete_device):
            self.assertEqual(str(button.cget("state")), "disabled")
        self.assertIn("yalnızca süper kullanıcıya açıktır", self.app.inv_role_note.get())
        self.login_as("super_user")
        self.assertIn("süper kullanıcı", self.app.lbl_session.cget("text"))
        self.assertEqual(str(self.app.btn_delete_device.cget("state")), "normal")
        self.assertEqual(self.app.inv_role_note.get(), "")

    def test_sites_flats_and_templates_load(self):
        self.login_as("service_user")
        self.app.refresh_sites()
        self.assertEqual(len(self.app.sites_tree.get_children()), 1)
        values = self.app.sites_tree.item("0")["values"]
        self.assertEqual(values[0], "Güneş Sitesi")
        self.assertIn("Yazıldı 2", values[-1])
        self.app.sites_tree.selection_set("0")
        self.app.refresh_flats()
        flat = self.app.flats_tree.item("0")["values"]
        self.assertEqual(str(flat[1]), "12")
        self.assertIn("B Tipi 3+1 (v4)", flat[3])
        self.assertEqual(flat[5], "Planlandı")
        self.app.tpl_scope.current(1)
        self.app.refresh_templates()
        self.assertEqual(self.app.tpl_tree.item("0")["values"][0], "B Tipi 3+1")
        self.assertIn("site_id=" + SITE_ID, self.api.calls[-1].query)
        self.assert_no_callback_errors()

    def test_add_site_validates_and_posts(self):
        self.login_as("service_user")
        form = {"name": "Yeni Site", "city": "İzmir", "contact_phone": "0532 111 22 33", "contact_email": "a@b.co",
                "block_count": "2", "flat_count": "40"}
        body, error = base.tool.SiteTemplateTabsMixin and __import__("site_template_ui").validate_site_form(form)
        self.assertEqual(error, "")
        with mock.patch("site_template_ui.SiteDialog.ask", return_value=body):
            self.app.add_site()
        post = [c for c in self.api.calls if c.method == "POST" and c.path == "/api/v1/sites"][-1]
        self.assertEqual(post.body["name"], "Yeni Site")
        self.assertEqual(post.body["flat_count"], 40)
        self.assertIn("Site Eklendi", self.dialogs.all_text())
        ui = __import__("site_template_ui")
        self.assertIsNone(ui.validate_site_form({"name": ""})[0])
        self.assertIsNone(ui.validate_site_form({"name": "x", "contact_email": "bozuk"})[0])
        self.assertIsNone(ui.validate_site_form({"name": "x", "flat_count": "-3"})[0])

    def _select_site_and_flat(self):
        self.login_as("service_user")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        self.app.refresh_flats()
        self.app.flats_tree.selection_set("0")

    def test_bulk_flats_assign_and_link(self):
        self._select_site_and_flat()
        with mock.patch("site_template_ui.BulkFlatsDialog.ask",
                        return_value={"block": "B", "start": 1, "end": 3, "flat_type": "2+1", "template_id": TID}):
            self.app.bulk_flats()
        bulk = [c for c in self.api.calls if c.path.endswith("/flats/bulk")][-1]
        self.assertEqual(bulk.body, {"block": "B", "from": 1, "to": 3, "flat_type": "2+1", "template_id": TID})
        self.app.flats_tree.selection_set("0")
        with mock.patch("site_template_ui.ChoiceDialog.ask", return_value=0):
            self.app.assign_flat_template()
        patch = [c for c in self.api.calls if c.method == "PATCH" and "/flats/" in c.path][-1]
        self.assertEqual(patch.body, {"template_id": TID})
        self.app.flats_tree.selection_set("0")
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value="ahbu-s3-dd8754"):
            self.app.link_flat_device()
        put = [c for c in self.api.calls if c.method == "PUT"][-1]
        self.assertEqual(put.body, {"device_uuid": base.UID})
        self.assert_no_callback_errors()

    def test_editor_round_trips_a_fixture_without_changes(self):
        ui = __import__("site_template_ui")
        for name in ("ok_1p1.json", "ok_3p1_vana_dimmer.json", "ok_dubleks_ekmodul16.json"):
            with self.subTest(ornek=name):
                original = ok_template(name)
                editor = ui.TemplateEditorDialog(self.app, self.app.theme, original, "Test")
                try:
                    self.assertIsNone(editor.validate_now())
                    self.assertEqual(editor.t, original)
                finally:
                    editor.destroy()

    def test_editor_shutter_pair_dimmer_sensor_and_ext_module(self):
        ui = __import__("site_template_ui")
        editor = ui.TemplateEditorDialog(self.app, self.app.theme, tm.new_template("Ed", "2+1", SITE_ID), "Test")
        try:
            editor.relay_rows[5]["kind"].set("Panjur (çift)")
            editor.on_kind(6)  # R6 -> çift (5,6)
            self.assertEqual([editor.t["relays"][4]["type"], editor.t["relays"][5]["type"]], ["shutter_up", "shutter_down"])
            editor.relay_rows[4]["time"].delete(0, "end")
            editor.relay_rows[4]["time"].insert(0, "33")
            editor.apply_dimmer(1, {"dimmable": 1, "src": 1, "addr": 4, "ch": 2})
            self.assertEqual(editor.t["relays"][5]["runtime_s"], 33)
            editor.di_rows[7]["role"].set("Gaz")
            editor.on_role(8)
            self.assertEqual(tm.di_sensor(editor.t, 8)["active_open"], 1)
            editor.var_ext.set(True)
            editor.c_ext.set("8")
            editor.apply_ext()
            self.assertEqual(len(editor.relay_rows), 16)
            editor.add_actuator()
            self.assertEqual(editor.t["safety"]["actuators"][0]["relay"], 16)
            self.assertIsNone(editor.validate_now())
            editor.relay_rows[0]["name"].delete(0, "end")
            self.assertEqual(editor.validate_now().code, "invalid_name")
            self.assertIn("invalid_name", editor.status.cget("text"))
        finally:
            editor.destroy()

    def _editor(self, template):
        ui = __import__("site_template_ui")
        editor = ui.TemplateEditorDialog(self.app, self.app.theme, template, "Test")
        self.addCleanup(self._close, editor)
        return editor

    @staticmethod
    def _close(widget):
        try:
            widget.destroy()
        except Exception:  # noqa: BLE001 - zaten kapanmış olabilir
            pass

    def test_editor_asks_before_a_kind_change_deletes_a_safety_device(self):
        editor = self._editor(ok_template())
        before = copy.deepcopy(editor.t)
        self.dialogs.confirm = False
        editor.relay_rows[7]["kind"].set("Darbe")  # R8 (vana rölesi) -> darbe
        editor.on_kind(8)
        self.assertEqual(editor.t, before)  # reddedildi: model değişmedi
        self.assertEqual(editor.relay_rows[7]["kind"].get(), "Lamba/Priz")  # açılır kutu eski değere döndü
        self.assertEqual(self.dialogs.of("confirm")[-1][2],
                         "Bu değişiklik şu güvenlik öğelerini silecek: R8 Ana Su Vanası (vana, su). Devam?")
        self.dialogs.confirm = True
        editor.relay_rows[7]["kind"].set("Darbe")
        editor.on_kind(8)
        self.assertEqual(editor.t["safety"]["actuators"], [])
        self.assertIn("Silindi: R8 Ana Su Vanası (vana, su)", editor.status.cget("text"))

    def test_editor_kind_change_without_side_effects_asks_nothing(self):
        editor = self._editor(ok_template())
        editor.relay_rows[6]["kind"].set("Darbe")  # R7: güvenlik öğesi yok
        editor.on_kind(7)
        self.assertEqual(self.dialogs.of("confirm"), [])
        self.assertEqual(editor.t["relays"][6]["type"], "impulse")

    def test_editor_save_is_the_last_defence_when_safety_devices_disappeared(self):
        editor = self._editor(ok_template())
        editor.remove_actuator()  # vana silindi (ör. yanlışlıkla)
        self.dialogs.confirm = False
        editor._save()
        self.assertIsNone(editor.result)  # kaydedilmedi, düzenleyici açık
        self.assertEqual(self.dialogs.of("confirm")[-1][2], "1 güvenlik cihazı silindi, yine de kaydedilsin mi?")
        self.dialogs.confirm = True
        editor._save()
        self.assertEqual(editor.result["safety"]["actuators"], [])

    def test_editor_writes_an_address_only_ext_change_directly(self):
        editor = self._editor(ok_template("ok_dubleks_ekmodul16.json"))  # ek modül: 8 kanal, adres 1
        editor.e_addr.delete(0, "end")
        editor.e_addr.insert(0, "7")
        self.assertIsNone(editor.collect())
        self.assertEqual(editor.t["ext_module"], {"enabled": True, "channels": 8, "address": 7})
        self.assertEqual(self.dialogs.of("confirm"), [])

    def test_editor_does_not_silently_drop_an_unapplied_ext_module_change(self):
        editor = self._editor(tm.new_template("Ed", "2+1", SITE_ID))
        editor.var_ext.set(True)
        editor.c_ext.set("8")
        self.dialogs.confirm = False
        self.assertEqual(editor.collect(), "Ek modül değişikliği uygulanmadı: Kanalları Uygula düğmesine basın")
        self.assertEqual(len(editor.t["relays"]), 8)  # model değişmedi
        editor._save()
        self.assertIsNone(editor.result)  # kayıt durduruldu
        self.assertIn("Kanalları Uygula", editor.status.cget("text"))
        self.dialogs.confirm = True  # "uygulansın mı?" -> evet: apply_ext çalışır
        self.assertIsNone(editor.collect())
        self.assertEqual(len(editor.t["relays"]), 16)
        self.assertEqual(editor.t["ext_module"]["channels"], 8)
        self.assertIsNone(tm.validate_template(editor.t))

    def test_save_template_validates_remotely_then_creates_new_version(self):
        self.login_as("service_user")
        body = ok_template()
        self.app._save_template(body, TID, SITE_ID)
        paths = self.api.paths()
        self.assertLess(paths.index("POST /api/v1/templates/validate"), paths.index(f"PUT /api/v1/templates/{TID}"))
        self.assertIn("sürüm v5", self.dialogs.all_text())

    def _answers(self, *answers):
        """Sıradaki onay kutularına sırayla verilecek yanıtlar (evet/hayır)."""
        queue = list(answers)

        def askyesno(title=None, message=None, **kw):
            self.dialogs._record("confirm", title, message)
            return queue.pop(0) if queue else self.dialogs.confirm

        self.dialogs.askyesno = askyesno

    def _template_conflict_route(self):
        puts = []

        def put(call):
            puts.append(call.body)
            if "base_version" in call.body:
                return 409, {"success": False, "code": "TEMPLATE_CHANGED", "message": "Şablon değişti.",
                             "data": {"current_version": 6}}, {}
            return 200, {"success": True, "data": {"id": TID, "current_version": 7}}, {}

        self.api.routes[f"PUT /api/v1/templates/{TID}"] = put
        return puts

    def test_editor_sends_the_opened_version_as_base_version(self):
        self.login_as("service_user")
        puts = self._template_conflict_route()
        self.api.routes[f"PUT /api/v1/templates/{TID}"] = lambda call: (
            puts.append(call.body) or (200, {"success": True, "data": {"id": TID, "current_version": 5}}, {}))
        edited = ok_template()
        edited["relays"][4]["name"] = "Yeni ad"
        with mock.patch("site_template_ui.TemplateEditorDialog.ask", return_value=edited):
            self.app._edit_and_save(ok_template(), TID, None)  # açılan gövde v4
        self.assertEqual(puts[-1]["base_version"], 4)
        self.assertEqual(puts[-1]["body"]["relays"][4]["name"], "Yeni ad")

    def test_concurrent_edit_can_open_the_new_version(self):
        self.login_as("service_user")
        puts = self._template_conflict_route()
        self._answers(True)  # "yeni sürümü aç"
        with mock.patch("site_template_ui.TemplateEditorDialog.ask", return_value=None) as editor:
            self.app._save_template(ok_template(), TID, SITE_ID, base_version=4)
        self.assertEqual(len(puts), 1)  # üstüne YAZILMADI
        self.assertIn("Şablon siz düzenlerken v6 oldu", self.dialogs.of("confirm")[0][2])
        self.assertEqual(self.api.paths()[-1], f"GET /api/v1/templates/{TID}")  # güncel sürüm alındı
        editor.assert_called_once()

    def test_concurrent_edit_can_overwrite_on_purpose(self):
        self.login_as("service_user")
        puts = self._template_conflict_route()
        self._answers(False, True)  # yeni sürümü açma -> yine de üstüne yaz
        self.app._save_template(ok_template(), TID, SITE_ID, base_version=4)
        self.assertEqual([("base_version" in body) for body in puts], [True, False])
        self.assertIn("sürüm v7", self.dialogs.all_text())

    def test_server_rejection_shows_the_template_code(self):
        self.login_as("service_user")
        self.api.routes["POST /api/v1/templates/validate"] = lambda call: (
            422, {"success": False, "code": "TEMPLATE_INVALID", "message": "x", "error": "sensor_zone", "path": "safety.sensors[0].zone"}, {})
        self.dialogs.confirm = False
        self.app._save_template(ok_template(), TID, SITE_ID)
        self.assertNotIn(f"PUT /api/v1/templates/{TID}", self.api.paths())
        self.assertIn("sensor_zone @ safety.sensors[0].zone", self.dialogs.of("error")[-1][2])

    def test_usb_write_for_a_flat_records_the_write_and_offers_pdf(self):
        self._select_site_and_flat()
        ui = __import__("site_template_ui")
        request = ui.TemplateWriteRequest("usb", label="Güneş Sitesi A-12", port="COM7")
        self.dialogs.confirm = False  # PDF ve daire etiketi sorularına "hayır"
        with mock.patch("site_template_ui.TemplateWriteDialog.ask", return_value=request):
            self.app.write_flat_template()
        self.assertEqual(self.firmware.tpl_id, TID)
        self.assertEqual(self.firmware.tpl_label, "Güneş Sitesi A-12")
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual(record.body, {"device_uuid": base.UID, "template_id": TID, "version": 4, "via": "usb", "result": "ok",
                                       "flat_id": FLAT_ID})
        log = self.app.tpl_log.get("1.0", "end")
        self.assertIn("Şablon karta yazıldı ve geri okundu", log)
        # atolye-10: kartsız daireye USB yazımında kart, yazımdan ÖNCE daireye bağlanır (sonradan "bağlansın mı?" sorulmaz)
        link = [c for c in self.api.calls if c.method == "PUT" and c.path.endswith("/device")]
        self.assertEqual([c.body for c in link], [{"device_uuid": base.UID}])
        titles = [c[1] for c in self.dialogs.calls]
        self.assertNotIn("Kartı Daireye Bağla", titles)
        self.assertIn("Şablon Karta Yazıldı", titles)
        self.assertIn("Yazım kaydı: sunucuya işlendi", [c for c in self.dialogs.calls if c[1] == "Şablon Karta Yazıldı"][0][2])
        self.assert_no_callback_errors()

    # ---- atolye-10: kartsız daireye USB yazımı: önce bağla, çakışmada yazma ------------------------------------------
    def test_usb_write_to_a_cardless_flat_links_the_card_before_writing(self):
        self._select_site_and_flat()
        seen = []

        def put(call):
            seen.append(any(c.startswith("TPL") for c in self.firmware.received))
            return 200, {"success": True, "data": {"id": FLAT_ID}}, {}

        self.api.routes[f"PUT /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}/device"] = put
        self.dialogs.confirm = False
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"),
                                      site=self.app._sites[0], flat=self.app._flats[0])
        self.assertEqual(seen, [False])  # bağlama, karta hiçbir TPL komutu gitmeden yapıldı
        self.assertEqual(self.firmware.tpl_id, TID)

    def test_usb_write_is_not_sent_when_the_card_belongs_to_another_flat(self):
        self._select_site_and_flat()
        self.api.routes[f"PUT /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}/device"] = lambda call: (
            409, {"success": False, "code": "DEVICE_ALREADY_LINKED", "message": "x"}, {})
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"),
                                      site=self.app._sites[0], flat=self.app._flats[0])
        self.assertFalse(any(c.startswith("TPL") for c in self.firmware.received))  # yazım komutu GÖNDERİLMEDİ
        self.assertIsNone(self.firmware.tpl_id)
        self.assertIn(f"Kart {base.UID} başka bir daireye bağlı", self.dialogs.of("error")[-1][2])
        self.assertNotIn("/api/v1/template-writes", [c.path for c in self.api.calls])

    def test_write_record_warning_about_another_flat_is_an_error_window(self):
        self.login_as("service_user")
        self.api.routes["POST /api/v1/template-writes"] = lambda call: (
            201, {"success": True, "data": {"id": "w-1", "warning": "DEVICE_LINKED_ELSEWHERE",
                                            "linked_flat_id": "99999999-2222-4333-8444-555555555555"}}, {})
        self.dialogs.confirm = False
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"))
        error = self.dialogs.of("error")[-1]
        self.assertIn("başka bir daireye bağlı", error[2])

    # ---- atolye-11: işlenemeyen yazım kaydı kaybolmaz ----------------------------------------------------------------
    def test_failed_write_record_is_queued_and_can_be_resent(self):
        self._select_site_and_flat()
        state = {"fail": True}
        self.api.routes["POST /api/v1/template-writes"] = lambda call: (
            (503, {"success": False, "code": "SERVICE_UNAVAILABLE", "message": "x"}, {}) if state["fail"]
            else (201, {"success": True, "data": {"id": "w-1"}}, {}))
        self.dialogs.confirm = False
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"),
                                      site=self.app._sites[0], flat=self.app._flats[0])
        self.assertEqual(len(self.app._pending_writes), 1)
        self.assertIn("Yazım kaydı işlenemedi", self.dialogs.all_text())
        success = [c for c in self.dialogs.calls if c[1] == "Şablon Karta Yazıldı"][0]
        self.assertIn("Yazım kaydı: işlenemedi", success[2])
        state["fail"] = False
        self.app.send_pending_writes()
        self.assertEqual(self.app._pending_writes, [])
        bodies = [c.body for c in self.api.calls if c.path == "/api/v1/template-writes"]
        self.assertEqual(len(bodies), 2)
        self.assertEqual(bodies[0], bodies[1])
        self.assertIn("Bekleyen Kayıtları Gönder", [self.app.btn_send_pending.cget("text")[2:]])

    def test_write_record_rejected_by_the_server_is_dropped_and_reported_once(self):
        # Kalıcı ret (400/404/409/422): kuyrukta tutulursa her yazımda ve 'Bekleyen Kayıtları Gönder'de yeniden gönderilir.
        self.login_as("service_user")
        ui = __import__("site_template_ui")
        cases = (
            (404, "NOT_FOUND", "Bu cihaz envanterde kayıtlı değil."),
            (409, "TEMPLATE_DELETED", "Şablon silinmiş; yazım kaydedilemez."),
            (409, "CONFLICT", "Daireye başka bir kart bağlı."),
            (422, "TEMPLATE_SITE_MISMATCH", "Şablon başka bir siteye ait; bu daireye yazım kaydedilemez."),
            (400, "VALIDATION", "Geçersiz sürüm numarası."),
        )
        for status, code, message in cases:
            with self.subTest(kod=code):
                self.dialogs.calls.clear()
                self.api.routes["POST /api/v1/template-writes"] = (
                    lambda call, s=status, c=code, m=message: (s, {"success": False, "code": c, "message": m}, {}))
                posts = lambda: len([c for c in self.api.calls if c.path == "/api/v1/template-writes"])  # noqa: E731
                before = posts()
                self.dialogs.confirm = False
                self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"))
                self.assertEqual(self.app._pending_writes, [])
                errors = [c for c in self.dialogs.of("error") if c[1] == "Yazım Kaydı Reddedildi"]
                self.assertEqual(len(errors), 1)
                for needle in (base.UID, "v4", code, message):
                    self.assertIn(needle, errors[0][2])
                self.assertNotIn("Yazım Kaydı İşlenemedi", [c[1] for c in self.dialogs.calls])
                success = [c for c in self.dialogs.calls if c[1] == "Şablon Karta Yazıldı"][0]
                self.assertIn("Yazım kaydı: sunucu reddetti", success[2])
                self.app.send_pending_writes()
                self.assertEqual(self.dialogs.of("info")[-1][1], "Bekleyen Kayıt Yok")
                self.assertEqual(posts() - before, 1)  # yeniden gönderilmedi

    def test_transient_write_record_failures_stay_queued(self):
        self.login_as("service_user")
        ui = __import__("site_template_ui")

        def network_down(call):
            raise fc.NetworkError("Sunucuya bağlanılamadı.")

        for name, route in (("429", lambda call: (429, {"success": False, "code": "RATE_LIMITED", "message": "x"}, {})),
                            ("500", lambda call: (500, {"success": False, "code": "INTERNAL", "message": "x"}, {})),
                            ("ag", network_down)):
            with self.subTest(hata=name):
                self.app._pending_writes = []
                self.dialogs.calls.clear()
                self.api.routes["POST /api/v1/template-writes"] = route
                self.dialogs.confirm = False
                self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"))
                self.assertEqual(len(self.app._pending_writes), 1)
                self.assertIn("Yazım Kaydı İşlenemedi", [c[1] for c in self.dialogs.calls])
                self.assertNotIn("Yazım Kaydı Reddedildi", [c[1] for c in self.dialogs.calls])
        self.app._pending_writes = []

    def test_closing_with_unsent_write_records_asks_first(self):
        self.app._pending_writes = [{"seq": 1, "uid": base.UID, "template_id": TID, "version": 4, "via": "usb", "result": "ok",
                                     "flat_id": None, "error_code": None}]
        self.dialogs.confirm = False
        self.app.on_close()
        self.assertEqual(self.app.winfo_exists(), 1)  # kapanmadı
        self.assertIn("1 yazım kaydı", self.dialogs.of("confirm")[-1][2])
        self.app._pending_writes = []

    def test_write_without_a_session_keeps_the_record_until_login(self):
        self.dialogs.confirm = False
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"))
        self.assertEqual(self.firmware.tpl_id, TID)  # USB yazımı oturumsuz da yapılır
        self.assertEqual(len(self.app._pending_writes), 1)
        self.assertNotIn("/api/v1/template-writes", [c.path for c in self.api.calls])
        self.assertIn("oturum", self.app.tpl_log.get("1.0", "end"))
        self.patch_login()
        self.app.send_pending_writes()
        self.assertEqual(self.app._pending_writes, [])
        self.assertIn("/api/v1/template-writes", [c.path for c in self.api.calls])

    # ---- atolye-15: şemada kart UID'si; yazımdan sonra gizli değer içermeyen daire etiketi ---------------------------
    def test_flat_write_offers_a_secret_free_flat_label_and_the_pdf_carries_the_uid(self):
        self._select_site_and_flat()
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self._answers(True, True)  # PDF: evet; daire etiketi: evet (sonrası hayır)
        captured = {}
        real_pdf = wiring_pdf.save_wiring_pdf

        def spy(path, body, **kwargs):
            captured.update(kwargs)
            return real_pdf(path, body, **kwargs)

        with tempfile.TemporaryDirectory() as tmp:
            pdf, png = os.path.join(tmp, "sema.pdf"), os.path.join(tmp, "daire.png")
            with mock.patch("site_template_ui.filedialog.asksaveasfilename", side_effect=[pdf, png]), \
                    mock.patch.object(wiring_pdf, "save_wiring_pdf", spy):
                self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"),
                                              site=self.app._sites[0], flat=self.app._flats[0])
            self.assertEqual(captured.get("device_uid"), base.UID)
            self.assertTrue(os.path.isfile(png))
            with open(png, "rb") as handle:
                self.assertEqual(handle.read(8), b"\x89PNG\r\n\x1a\n")
        self.assertIn("Daire Etiketi", [c[1] for c in self.dialogs.calls])
        self.assertNotIn(base.FAKE_LOCAL_KEY, self.dialogs.all_text())

    # ---- atolye-6: NC tehlike girişli şablon atölyede kartı alarma kilitler ------------------------------------------
    def test_nc_hazard_template_asks_before_writing(self):
        gas = ok_template("ok_dubleks_ekmodul16.json")
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self.app.start_template_write(gas, ui.TemplateWriteRequest("usb", label="A-1", port="COM7"))
        self.assertIsNone(self.firmware.tpl_id)  # "hayır": hiçbir şey yazılmadı
        self.assertFalse(any(c.startswith("TPL") for c in self.firmware.received))
        self.assertIn("D16 (Gaz) NC: atölyede giriş boşsa kart hemen alarma geçip kilitlenir (vana kapanır, siren çalar).",
                      self.dialogs.of("confirm")[-1][2])

    def test_latched_zone_after_a_usb_write_is_explained_and_can_be_acknowledged(self):
        self.login_as("service_user")
        self.firmware.latch_nc_hazards = True
        gas = ok_template("ok_dubleks_ekmodul16.json")
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self._answers(True, False)  # NC uyarısı: devam; "alarmı şimdi onayla?": hayır (giriş henüz köprülenmedi)
        self.app.start_template_write(gas, ui.TemplateWriteRequest("usb", label="A-1", port="COM7"))
        self.assertEqual(self.firmware.tpl_id, TID)
        warning = [c for c in self.dialogs.calls if c[0] == "warning" and "SAFETY ACK 1" in c[2]]
        self.assertTrue(warning, self.dialogs.all_text())
        self.assertIn("Köprüleyin ve SAFETY ACK 1 gönderin", warning[0][2])
        self.assertNotIn("SAFETY ACK 1", self.firmware.received)
        self.firmware.inputs_bridged = True  # teknisyen girişi DI-GND köprüledi
        self.app.btn_ack_alarm.invoke()  # '🔕 Alarmı Onayla (USB)'
        self.assertIn("SAFETY ACK 1", self.firmware.received)
        self.assertEqual(self.firmware.latched_zones, [])
        self.assertIn("Alarm Onaylandı", [c[1] for c in self.dialogs.calls])
        self.assert_no_callback_errors()

    def test_alarm_ack_with_a_valve_fault_is_not_reported_as_normal(self):
        self.firmware.fault_zones = [2]  # vana geri bildirimi 'kapalı' görülmedi (atölyede vana bağlı değil)
        self.app.acknowledge_safety_alarm()
        self.assertIn("SAFETY ACK 0", self.firmware.received)
        self.assertNotIn("Alarm Onaylandı", [c[1] for c in self.dialogs.calls])
        warning = self.dialogs.of("warning")[-1]
        self.assertEqual(warning[1], "Alarm Sürüyor")
        for needle in ("Bölge 2", "FAULT", "temizlemez"):
            self.assertIn(needle, warning[2])
        self.assertEqual(self.app._last_latched, {"port": "COM7", "zones": [2]})
        self.assert_no_callback_errors()

    def test_alarm_ack_without_a_readable_safety_status_is_not_reported_as_normal(self):
        self.firmware.safety_silent = True
        self.app.acknowledge_safety_alarm()
        self.assertNotIn("Alarm Onaylandı", [c[1] for c in self.dialogs.calls])
        warning = self.dialogs.of("warning")[-1]
        self.assertEqual(warning[1], "Güvenlik Durumu Okunamadı")
        self.assertIn("SAFETY", warning[2])
        self.assertNotIn("✅", self.app.tpl_log.get("1.0", "end"))

    def test_usb_write_of_an_nc_template_says_when_safety_could_not_be_read(self):
        self.login_as("service_user")
        self.firmware.safety_silent = True
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self._answers(True)  # NC tehlike uyarısı: devam (sonraki sorular: hayır)
        self.app.start_template_write(ok_template("ok_dubleks_ekmodul16.json"),
                                      ui.TemplateWriteRequest("usb", label="A-1", port="COM7"))
        self.assertEqual(self.firmware.tpl_id, TID)
        warning = [c for c in self.dialogs.of("warning") if c[1] == "Güvenlik Durumu Okunamadı"]
        self.assertTrue(warning, self.dialogs.all_text())
        self.assertIn("Alarmı Onayla (USB)", warning[0][2])
        self.assertEqual(self.app._last_latched, {"port": "COM7", "zones": [0]})  # düğme bütün bölgeleri onaylar

    def test_usb_write_reports_a_valve_fault_zone(self):
        self.login_as("service_user")
        self.firmware.fault_zones = [1]
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self._answers(True, False)  # NC uyarısı: devam; "alarmı şimdi onayla?": hayır
        self.app.start_template_write(ok_template("ok_dubleks_ekmodul16.json"),
                                      ui.TemplateWriteRequest("usb", label="A-1", port="COM7"))
        warning = [c for c in self.dialogs.of("warning") if c[1] == "Alarm Kilitlendi (Atölye)"]
        self.assertTrue(warning, self.dialogs.all_text())
        for needle in ("Bölge 1", "FAULT", "temizlemez"):
            self.assertIn(needle, warning[0][2])
        self.assertEqual(self.app._last_latched, {"port": "COM7", "zones": [1]})

    def test_usb_write_updates_the_label_of_the_current_device(self):
        self._select_site_and_flat()
        self.app.current_record = fc.DeviceRecord(uid=base.UID, mac=base.MAC, pin="123456", local_key=base.FAKE_LOCAL_KEY,
                                                  ap_pass="Abcdefgh23", qr_claim_url=fc.build_claim_url(base.UID, "123456"),
                                                  state="verified")
        ui = __import__("site_template_ui")
        self.dialogs.confirm = False
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", label="A-12", port="COM7"),
                                      site=self.app._sites[0], flat=self.app._flats[0])
        self.assertEqual(self.app.current_record.flat_info, "A Blok / Daire 12 · 3+1 · Şablon v4")
        self.assertIsNotNone(self.app.current_label_img)

    def test_usb_device_error_is_recorded_and_shown_in_turkish(self):
        self._select_site_and_flat()
        self.firmware.tpl_error = "zone_latched"
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("usb", port="COM7"),
                                      site=self.app._sites[0], flat=self.app._flats[0])
        error = self.dialogs.of("error")[-1]
        self.assertEqual(error[1], "Karta Yazılamadı")
        self.assertIn("kilitli", error[2])
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual((record.body["result"], record.body["error_code"]), ("error", "zone_latched"))

    def test_ethernet_write_needs_no_local_key_or_provisioning(self):
        # Kullanıcı kararı (2026-10-08, ikinci): kablolu Ethernet'ten gelen istek kartta anahtarsız yetkilidir -> araç sunucudan
        # anahtar İSTEMEZ (envantere kaydedilmemiş/provizyonsuz kartta da yazılabilir).
        self.login_as("service_user")
        self.api.routes.pop(f"GET /api/v1/admin/inventory/{base.UID}/local-key", None)
        calls = []

        def device(method, url, headers, body, timeout):
            calls.append((method, url, dict(headers)))
            if url.endswith("/api/template/apply"):
                meta = json.loads(body.decode("utf-8"))["template"]["meta"]
                return fc.TransportResponse(200, {}, json.dumps({"ok": True, "template_id": meta["template_id"],
                                                                 "version": meta["version"], "rev": 1}).encode())
            return fc.TransportResponse(200, {}, json.dumps({"template_id": TID, "version": 4, "label": "A-12"}).encode())

        self.app._device_transport = device
        self.dialogs.confirm = False
        self.app.start_template_write(ok_template(), self._eth_request())
        self.assertNotIn(f"GET /api/v1/admin/inventory/{base.UID}/local-key", self.api.paths())
        self.assertEqual([c[1] for c in calls], ["http://192.168.1.60/api/template/apply", "http://192.168.1.60/api/template"])
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual((record.body["via"], record.body["result"]), ("eth", "ok"))

    def test_ethernet_write_error_is_recorded_without_server_key(self):
        self.login_as("service_user")
        device_calls = []

        def device(method, url, headers, body, timeout):
            device_calls.append((method, url, dict(headers)))
            if url.endswith("/api/status"):
                return fc.TransportResponse(200, {}, json.dumps({"device": base.UID, "provisioned": True}).encode())
            if url.endswith("/api/template/apply"):
                return fc.TransportResponse(403, {}, json.dumps({"error": "local_loosen_forbidden"}).encode())
            return fc.TransportResponse(404, {}, b"{}")

        self.app._device_transport = device
        ui = __import__("site_template_ui")
        request = ui.TemplateWriteRequest("eth", label="A-12", host="192.168.1.60", device_uid=base.UID)
        self.app.start_template_write(ok_template(), request)
        self.assertNotIn(f"GET /api/v1/admin/inventory/{base.UID}/local-key", self.api.paths())
        # Kullanıcı kararları: IP<->UID ön denetimi YOK; Ethernet'te kart anahtar istemez -> sabit biçim başlığı gider.
        self.assertNotIn("http://192.168.1.60/api/status", [c[1] for c in device_calls])
        self.assertEqual(device_calls[0][2]["X-Device-Key"], fc.ETH_NO_KEY)
        self.assertEqual(device_calls[0][1], "http://192.168.1.60/api/template/apply")
        shown = self.dialogs.all_text() + self.app.tpl_log.get("1.0", "end")
        self.assertNotIn(base.FAKE_LOCAL_KEY, shown)
        self.assertNotIn("USB ile yazın", self.dialogs.of("error")[-1][2])
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual((record.body["via"], record.body["error_code"]), ("eth", "local_loosen_forbidden"))

    def _eth_request(self, uid=base.UID):
        ui = __import__("site_template_ui")
        return ui.TemplateWriteRequest("eth", label="A-12", host="192.168.1.60", device_uid=uid)

    def test_flat_link_of_a_board_not_in_stock_is_explained(self):
        self._select_site_and_flat()
        self.api.routes[f"PUT /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}/device"] = lambda call: (
            409, {"success": False, "code": "DEVICE_NOT_IN_STOCK", "message": "x"}, {})
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
            self.app.link_flat_device()
        self.assertIn("Bu kart stokta değil", self.dialogs.of("error")[-1][2])
        self.assertIn("daireye bağlanamaz", self.dialogs.of("error")[-1][2])

    # ---- atolye-8: daireye kart bağlama hata metinleri -----------------------------------------------------------
    def test_flat_link_error_codes_map_to_clear_messages(self):
        text = fc.friendly_api_error(409, "DEVICE_NOT_IN_STOCK", "x")
        self.assertIn("Bu kart stokta değil", text)
        self.assertIn("Kart pano değişimiyle bu daireye takıldıysa bağlantı sunucuda otomatik taşınır; değilse süper kullanıcı "
                      "bağlayabilir.", text)
        self.assertEqual(fc.friendly_api_error(409, "DEVICE_LINKED_TO_FLAT", "x"), "Kart bir daireye bağlı; önce daireden ayırın.")
        self._select_site_and_flat()
        self.api.routes[f"PUT /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}/device"] = lambda call: (
            409, {"success": False, "code": "DEVICE_LINKED_TO_FLAT", "message": "x"}, {})
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
            self.app.link_flat_device()
        self.assertEqual(self.dialogs.of("error")[-1][2], "Kart bir daireye bağlı; önce daireden ayırın.")

    # ---- atolye-14: "Genel" kapsamda yalnız genel şablonlar --------------------------------------------------------
    def test_general_scope_lists_only_general_templates(self):
        templates = [{"id": TID, "site_id": SITE_ID, "name": "B Tipi 3+1", "flat_type": "3+1", "current_version": 4},
                     {"id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "site_id": None, "name": "Genel 2+1", "flat_type": "2+1",
                      "current_version": 1}]
        site_routes(self.api, templates=templates)
        self.login_as("service_user")
        self.app.tpl_scope.current(0)
        self.app.refresh_templates()
        names = [self.app.tpl_tree.item(i)["values"][0] for i in self.app.tpl_tree.get_children()]
        self.assertEqual(names, ["Genel 2+1"])
        self.assertEqual(self.app._site_name(SITE_ID), "Site 8c1d2e3f")  # site listesi yüklenmemiş: kısa kimlik
        self.assertEqual(self.app._site_name(None), "Genel")

    # ---- servis_kurulum-10: daireyi "Teslim edildi" yapma ------------------------------------------------------------
    @staticmethod
    def _flat(**overrides):
        flat = {"id": FLAT_ID, "site_id": SITE_ID, "block": "A", "number": 12, "flat_type": "3+1", "template_id": TID,
                "device_uuid": base.UID, "status": "written", "last_write": None}
        flat.update(overrides)
        return flat

    def test_flat_can_be_marked_handed_over_and_progress_is_refreshed(self):
        site_routes(self.api, flats=[self._flat()])  # kart bağlı, şablon yazılmış daire
        self._select_site_and_flat()
        before = len(self.api.calls)
        self.app.mark_flat_handed_over()
        patch = [c for c in self.api.calls if c.method == "PATCH" and c.path.endswith(FLAT_ID)][-1]
        self.assertEqual(patch.body, {"status": "handed_over"})
        later = [c.path for c in self.api.calls[before:]]
        self.assertIn("/api/v1/sites", later)  # İlerleme sütunu (Teslim edildi sayısı) yenilendi
        ui = __import__("site_template_ui")
        self.assertEqual(ui.flat_progress_text({"planned": 1, "written": 2, "installed": 3, "handed_over": 4}),
                         "Planlandı 1 · Yazıldı 2 · Kuruldu 3 · Teslim edildi 4")

    def test_handed_over_needs_a_linked_card_and_a_written_template(self):
        # Araç da denetler (sunucu kuralına ek): kartsız ya da şablonu yazılmamış daire 'Teslim edildi' yapılmaz.
        self.login_as("service_user")
        self.app.refresh_sites()
        self.app.sites_tree.selection_set("0")
        for overrides, needle in (({"device_uuid": None}, "Kart Bağla"), ({"status": "planned"}, "Karta Yaz")):
            with self.subTest(**{key: str(value) for key, value in overrides.items()}):
                site_routes(self.api, flats=[self._flat(**overrides)])
                self.app.refresh_flats()
                self.app.flats_tree.selection_set("0")
                self.dialogs.calls.clear()
                before = len(self.api.calls)
                self.app.mark_flat_handed_over()
                self.assertFalse([c for c in self.api.calls[before:] if c.method == "PATCH"])  # sunucuya hiçbir şey gitmedi
                self.assertEqual(self.dialogs.of("confirm"), [])
                warning = self.dialogs.of("warning")[-1]
                self.assertEqual(warning[1], "Teslim Edilemez")
                self.assertIn(needle, warning[2])
        for status in ("written", "installed"):
            with self.subTest(durum=status):
                site_routes(self.api, flats=[self._flat(status=status)])
                self.app.refresh_flats()
                self.app.flats_tree.selection_set("0")
                before = len(self.api.calls)
                self.app.mark_flat_handed_over()
                patches = [c for c in self.api.calls[before:] if c.method == "PATCH" and c.path.endswith(FLAT_ID)]
                self.assertEqual([c.body for c in patches], [{"status": "handed_over"}])

    def test_invalid_status_transition_is_shown(self):
        site_routes(self.api, flats=[self._flat()])
        self._select_site_and_flat()
        self.api.routes[f"PATCH /api/v1/sites/{SITE_ID}/flats/{FLAT_ID}"] = lambda call: (
            409, {"success": False, "code": "INVALID_STATUS_TRANSITION",
                  "message": "Teslim için daireye kart bağlı olmalı."}, {})
        self.app.mark_flat_handed_over()
        error = self.dialogs.of("error")[-1]
        self.assertIn("Teslim için daireye kart bağlı olmalı.", error[2])
        self.assertIn("yalnız ileri", error[2])

    # ---- atolye-7: son yazım sütunu: hata / eski sürüm / başka kart ---------------------------------------------------
    def test_flat_last_write_column_distinguishes_error_old_version_and_other_card(self):
        ui = __import__("site_template_ui")
        tpl = {"id": TID, "current_version": 5}
        at = "2026-10-08T10:00:00Z"
        ok = {"device_uuid": base.UID,
              "last_write": {"version": 5, "via": "usb", "at": at, "result": "ok", "device_uuid": base.UID},
              "last_ok_write": {"version": 5, "via": "usb", "at": at, "device_uuid": base.UID}}
        self.assertEqual(ui.flat_last_write_text(ok, tpl), "v5 · USB · 2026-10-08 10:00")
        failed = {"device_uuid": base.UID,
                  "last_write": {"version": 5, "via": "eth", "at": at, "result": "error", "error_code": "zone_latched",
                                 "device_uuid": base.UID},
                  "last_ok_write": {"version": 4, "via": "usb", "at": at, "device_uuid": base.UID}}
        text = ui.flat_last_write_text(failed, tpl)
        self.assertTrue(text.startswith("⚠ v5 (zone_latched)"), text)
        self.assertIn("eski sürüm", text)  # son başarılı yazım v4 < güncel v5
        other = {"device_uuid": base.UID,
                 "last_write": {"version": 5, "via": "usb", "at": at, "result": "ok", "device_uuid": "AHBU-S3-000001"},
                 "last_ok_write": {"version": 5, "via": "usb", "at": at, "device_uuid": "AHBU-S3-000001"}}
        self.assertIn("başka kart (AHBU-S3-000001)", ui.flat_last_write_text(other, tpl))
        self.assertEqual(ui.flat_last_write_text({"last_write": None}, tpl), "")
        flats = [dict(failed, id=FLAT_ID, site_id=SITE_ID, block="A", number=12, flat_type="3+1", template_id=TID,
                      status="written")]
        site_routes(self.api, flats=flats, templates=[{"id": TID, "site_id": SITE_ID, "name": "B", "flat_type": "3+1",
                                                       "current_version": 5}])
        self._select_site_and_flat()
        self.assertTrue(str(self.app.flats_tree.item("0")["values"][6]).startswith("⚠ v5 (zone_latched)"))

    def test_changing_the_card_of_a_written_flat_warns_to_rewrite_the_template(self):
        flats = [{"id": FLAT_ID, "site_id": SITE_ID, "block": "A", "number": 12, "flat_type": "3+1", "template_id": TID,
                  "device_uuid": "AHBU-S3-000001", "status": "written",
                  "last_write": {"version": 4, "via": "usb", "at": "2026-10-08T10:00:00Z", "result": "ok",
                                 "device_uuid": "AHBU-S3-000001"},
                  "last_ok_write": {"version": 4, "via": "usb", "at": "2026-10-08T10:00:00Z", "device_uuid": "AHBU-S3-000001"}}]
        site_routes(self.api, flats=flats)
        self._select_site_and_flat()
        with mock.patch.object(base.tool.simpledialog, "askstring", return_value=base.UID):
            self.app.link_flat_device()
        self.assertIn("Şablon yeni karta yeniden yazılmalı", self.dialogs.all_text())

    def test_ethernet_write_does_not_query_device_identity_first(self):
        self.login_as("service_user")
        urls = []

        def device(method, url, headers, body, timeout):
            urls.append(url)
            if url.endswith("/api/template/apply"):
                meta = json.loads(body.decode("utf-8"))["template"]["meta"]
                return fc.TransportResponse(200, {}, json.dumps({"ok": True, "template_id": meta["template_id"],
                                                                 "version": meta["version"], "rev": 1}).encode())
            return fc.TransportResponse(200, {}, json.dumps({"template_id": TID, "version": 4, "label": "A-12"}).encode())

        self.app._device_transport = device
        self.dialogs.confirm = False
        ui = __import__("site_template_ui")
        self.app.start_template_write(ok_template(), ui.TemplateWriteRequest("eth", label="A-12", host="192.168.1.60",
                                                                             device_uid=base.UID))
        self.assertEqual(urls, ["http://192.168.1.60/api/template/apply", "http://192.168.1.60/api/template"])
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual((record.body["via"], record.body["result"]), ("eth", "ok"))

    def test_template_tab_pdf_button_writes_a_pdf(self):
        self.login_as("service_user")
        self.app.refresh_sites()
        self.app.tpl_scope.current(1)  # şablon bir siteye ait: 'Genel' kapsamda listelenmez (atolye-14)
        self.app.refresh_templates()
        self.app.tpl_tree.selection_set("0")
        with tempfile.TemporaryDirectory() as tmp:
            target = os.path.join(tmp, "sema.pdf")
            with mock.patch.object(base.tool.filedialog, "asksaveasfilename", return_value=target), \
                    mock.patch("site_template_ui.filedialog.asksaveasfilename", return_value=target):
                self.app.template_wiring_pdf()
            self.assertTrue(os.path.isfile(target))
            with open(target, "rb") as handle:
                self.assertTrue(handle.read(5).startswith(b"%PDF"))
        self.assertIn("Kablolama Şeması Kaydedildi", self.dialogs.all_text())

    def test_unsaved_or_invalid_template_is_not_written(self):
        ui = __import__("site_template_ui")
        self.app.start_template_write(tm.new_template(), ui.TemplateWriteRequest("usb", port="COM7"))
        self.assertIn("Kaydedilmemiş Şablon", self.dialogs.all_text())
        self.app.start_template_write(load_fixture("bad_type.json")["template"], ui.TemplateWriteRequest("usb", port="COM7"))
        self.assertIn("Şablon Geçersiz", self.dialogs.all_text())
        self.assertIsNone(self.firmware.tpl_id)

    def test_template_after_provision_preselects_the_flash_port(self):
        self.app._flash_port = "COM7"
        self.app.template_after_provision()
        self.assertEqual(self.app._tpl_preset_port, "COM7")
        self.assertEqual(self.app.notebook.index("current"), 4)

    def test_write_dialog_requires_uid_for_ethernet_and_local_ip(self):
        ui = __import__("site_template_ui")
        dialog = ui.TemplateWriteDialog(self.app, self.app.theme, target="t", ports=["COM7"], label="A-12")
        try:
            dialog.via.set("eth")
            dialog.e_host.insert(0, "8.8.8.8")
            dialog._ok()
            self.assertIsNone(dialog.result)
            self.assertIn("yerel ağ", self.dialogs.of("warning")[-1][2])
            dialog.e_host.delete(0, "end")
            dialog.e_host.insert(0, "192.168.1.60")
            dialog._ok()  # UID yok: yalnız yazım kaydı için gerekir (anahtar için değil)
            self.assertIsNone(dialog.result)
            self.assertEqual(self.dialogs.of("warning")[-1][2], "Yazım kaydı için kart UID'si gerekir (AHBU-S3-XXXXXX).")
            dialog.e_uid.insert(0, base.UID)
            dialog._ok()
            self.assertEqual(dialog.result.via, "eth")
            self.assertEqual(dialog.result.host, "192.168.1.60")
        finally:
            try:
                dialog.destroy()
            except Exception:  # noqa: BLE001
                pass


if __name__ == "__main__":
    unittest.main()
