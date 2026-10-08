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
        self.assertIn("USB ile yazın", tm.describe_error("local_loosen_forbidden"))


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

    def test_lan_loosen_forbidden_tells_to_use_usb(self):
        state = {"error": (403, {"error": "local_loosen_forbidden"}, {})}
        with base.LoopbackHttpServer(self.handler_for(state)) as server:
            writer = fc.TemplateLanWriter(f"127.0.0.1:{server.port}")
            with self.assertRaises(fc.TemplateWriteError) as ctx:
                writer.apply(base.FAKE_LOCAL_KEY, tm.envelope_bytes(ok_template()))
        self.assertTrue(ctx.exception.use_usb)
        self.assertIn("USB ile yazın", str(ctx.exception))

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
                    self.assertIn("Önce FACTORYINIT (provizyon) yapın ya da USB ile yazın", str(ctx.exception))
                if code == "cfg_invalid":
                    self.assertIn("panjur rölesine", str(ctx.exception))

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
                       "Evye altı"):
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

    def test_save_template_validates_remotely_then_creates_new_version(self):
        self.login_as("service_user")
        body = ok_template()
        self.app._save_template(body, TID, SITE_ID)
        paths = self.api.paths()
        self.assertLess(paths.index("POST /api/v1/templates/validate"), paths.index(f"PUT /api/v1/templates/{TID}"))
        self.assertIn("sürüm v5", self.dialogs.all_text())

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
        self.dialogs.confirm = False  # kartı bağlama ve PDF sorularına "hayır"
        with mock.patch("site_template_ui.TemplateWriteDialog.ask", return_value=request):
            self.app.write_flat_template()
        self.assertEqual(self.firmware.tpl_id, TID)
        self.assertEqual(self.firmware.tpl_label, "Güneş Sitesi A-12")
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual(record.body, {"device_uuid": base.UID, "template_id": TID, "version": 4, "via": "usb", "result": "ok",
                                       "flat_id": FLAT_ID})
        log = self.app.tpl_log.get("1.0", "end")
        self.assertIn("Şablon karta yazıldı ve geri okundu", log)
        titles = [c[1] for c in self.dialogs.calls]
        self.assertIn("Kartı Daireye Bağla", titles)
        self.assertIn("Şablon Karta Yazıldı", titles)
        self.assert_no_callback_errors()

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

    def test_ethernet_write_uses_server_local_key_without_showing_it(self):
        self.login_as("service_user")
        device_calls = []

        def device(method, url, headers, body, timeout):
            device_calls.append((method, url, dict(headers)))
            if url.endswith("/api/template/apply"):
                return fc.TransportResponse(403, {}, json.dumps({"error": "local_loosen_forbidden"}).encode())
            return fc.TransportResponse(404, {}, b"{}")

        self.app._device_transport = device
        ui = __import__("site_template_ui")
        request = ui.TemplateWriteRequest("eth", label="A-12", host="192.168.1.60", device_uid=base.UID)
        self.app.start_template_write(ok_template(), request)
        self.assertIn(f"GET /api/v1/admin/inventory/{base.UID}/local-key", self.api.paths())
        self.assertEqual(device_calls[0][2]["X-Device-Key"], base.FAKE_LOCAL_KEY)
        self.assertEqual(device_calls[0][1], "http://192.168.1.60/api/template/apply")
        shown = self.dialogs.all_text() + self.app.tpl_log.get("1.0", "end")
        self.assertNotIn(base.FAKE_LOCAL_KEY, shown)
        self.assertIn("USB ile yazın", self.dialogs.of("error")[-1][2])
        record = [c for c in self.api.calls if c.path == "/api/v1/template-writes"][-1]
        self.assertEqual((record.body["via"], record.body["error_code"]), ("eth", "local_loosen_forbidden"))

    def test_template_tab_pdf_button_writes_a_pdf(self):
        self.login_as("service_user")
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
