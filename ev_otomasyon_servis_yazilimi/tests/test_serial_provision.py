# -*- coding: utf-8 -*-
"""
G2 - USB-seri provizyon (FACTORYINIT) testleri (donanımsız, ağsız).

Çalıştırma:
    cd ev_otomasyon_servis_yazilimi && python -m unittest discover -s tests -v

Kapsam:
  * sahte seri port (FakeFirmwareCli: main.cpp CLI'sının bayt-bayt benzeri) ile FACTORYINIT akışı
  * firmware'in her ERR kodunun Türkçe eşlemesi, zaman aşımı, yeniden deneme, iptal, USB kopması
  * parametrelerin (yerel anahtar / AP parolası) log, ilerleme metni, hata mesajı, argv ve kaynak kodunda ASLA yer almaması
  * pyserial arka uç seçimi: aracın kendi Python'u -> PlatformIO penv (röle alt süreç) -> yok (yeni paket KURULMAZ)
  * röle arka ucunun gerçek bir alt süreçle (sahte pyserial paketi ile) uçtan uca denemesi

Test çıktısı cp1254 konsollarda bozulmasın diye ad/ileti metinlerinde emoji yoktur.
"""

import ast
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(TESTS_DIR)
for _path in (TOOL_DIR, TESTS_DIR):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import factory_client as fc  # noqa: E402
from serial_fakes import (  # noqa: E402
    FakeClock,
    FakeFirmwareCli,
    FakeSerialBackend,
    write_stub_serial_package,
)

KEY = "TEST-KEY-1234567"     # sahte yerel anahtar (firmware kuralı: 8-32, boşluksuz)
AP = "AP-TEST-12"            # sahte AP parolası
MAC = "E8:F6:0A:DD:87:54"
SOURCE_FILES = [
    os.path.join(TOOL_DIR, "ev_otomasyon_sistemi.py"),
    os.path.join(TOOL_DIR, "factory_client.py"),
]


def make(firmware=None, backend_kwargs=None, **firmware_kwargs):
    clock = FakeClock()
    firmware = firmware or FakeFirmwareCli(**firmware_kwargs)
    firmware.watch = [KEY, AP]
    backend = FakeSerialBackend(firmware, clock, **(backend_kwargs or {}))
    provisioner = fc.SerialProvisioner(backend, clock=clock.now, sleep=clock.sleep)
    return provisioner, backend, firmware, clock


def run(provisioner, **kwargs):
    lines = []
    kwargs.setdefault("expected_mac", MAC)
    outcome = provisioner.provision("COM7", KEY, AP, progress=lines.append, **kwargs)
    return outcome, lines


# ============================================================================================================
# Satır kurma / ayrıştırma
# ============================================================================================================
class SerialLineTests(unittest.TestCase):
    def test_factory_init_line_format(self):
        line = fc.build_factory_init_line(KEY, AP)
        self.assertEqual(bytes(line), b"FACTORYINIT TEST-KEY-1234567 AP-TEST-12\r\n")
        self.assertIsInstance(line, bytearray)  # sıfırlanabilir tampon
        self.assertLessEqual(len(line), fc.SERIAL_MAX_LINE + 2)

    def test_wipe_zeroes_the_buffer(self):
        line = fc.build_factory_init_line(KEY, AP)
        fc.wipe_bytes(line)
        self.assertEqual(set(line), {0})

    def test_values_are_validated_like_the_firmware(self):
        bad = [
            ("short", AP),                      # anahtar < 8
            ("K" * 33, AP),                     # anahtar > 32
            ("has space inside", AP),           # anahtarda boşluk
            ("anahtar-\u00fc-123456", AP),      # ASCII dışı
            (KEY, "kisa"),                      # parola < 8
            (KEY, "x" * 33),                    # parola > 32
            (KEY, " baslangicta-bosluk"),       # firmware baştaki/sondaki boşluğu keser: reddedilir
            (KEY, "sonda-bosluk "),
        ]
        for key, password in bad:
            with self.assertRaises(fc.ProvisionError, msg=(key, password)):
                fc.build_factory_init_line(key, password)
        # parola içinde TEK/çoklu iç boşluk serbesttir (satırın geri kalanı)
        self.assertTrue(fc.build_factory_init_line(KEY, "iki kelime parola"))

    def test_line_buffer_splits_on_cr_and_lf(self):
        buffer = fc._LineBuffer()
        self.assertEqual(buffer.feed(b"ab"), [])
        self.assertEqual(buffer.feed(b"c\r\n\r\nOK factory_init\r\nbir"), ["abc", "OK factory_init"])
        self.assertEqual(buffer.feed(b"\n"), ["bir"])
        self.assertEqual(buffer.feed("T\u00fcrk\u00e7e\r\n".encode("utf-8")), ["T\u00fcrk\u00e7e"])
        self.assertEqual(buffer.feed(b"\xff\xfe\n"), ["\ufffd\ufffd"])  # bozuk bayt: istisna yok

    def test_line_buffer_is_bounded(self):
        buffer = fc._LineBuffer()
        buffer.feed(b"x" * 50_000)
        self.assertLess(len(buffer._buf), 8192)

    def test_result_parser(self):
        self.assertEqual(fc.parse_factory_init_result("OK factory_init"), (True, ""))
        self.assertEqual(fc.parse_factory_init_result("ERR persist_failed"), (False, "persist_failed"))
        self.assertEqual(fc.parse_factory_init_result("[WiFiManager] log OK factory_init"), (True, ""))
        for noise in ("[CLI] Komut alindi: STATUS", "OK", "ERR", "ERR <script>", "ERR " + "a" * 41, "", "OK factory_init2"):
            self.assertIsNone(fc.parse_factory_init_result(noise), noise)

    def test_status_parser(self):
        status = fc.SerialStatus()
        for line in (
            "[STATUS] Cihaz: AHBU Akilli Ev Kontrol (MAC: e8:f6:0a:dd:87:54)",
            "- Kurtarma/servis AP: ACIK (SSID: AHBU-dd8754, IP: 192.168.4.1) | Ac/kapat: AP ON | AP OFF",
            "- Yerel anahtar (local_key): YOK (provizyonsuz cihaz)",
        ):
            status.absorb(line)
        self.assertEqual((status.mac, status.ap_ssid, status.provisioned), (MAC, "AHBU-DD8754", False))
        status.absorb("- Yerel anahtar (local_key): tanimli")
        self.assertTrue(status.provisioned)
        other = fc.SerialStatus()
        other.absorb("rastgele satir (MAC: yok)")
        self.assertEqual((other.mac, other.provisioned), (None, None))


# ============================================================================================================
# SerialProvisioner: FACTORYINIT akışı
# ============================================================================================================
class SerialProvisionerTests(unittest.TestCase):
    def test_happy_path_writes_key_over_usb_and_verifies_with_status(self):
        provisioner, backend, firmware, _ = make()
        outcome, lines = run(provisioner)
        self.assertTrue(outcome.initialized and outcome.verified)
        self.assertFalse(outcome.needs_reconnect)
        self.assertEqual(outcome.via, "serial")
        self.assertEqual(outcome.mac, MAC)
        self.assertEqual(outcome.device_uid, "AHBU-S3-DD8754")
        self.assertEqual(outcome.ap_ssid, "AHBU-DD8754")
        self.assertTrue(firmware.provisioned)
        self.assertEqual((firmware.local_key, firmware.ap_pass), (KEY, AP))
        self.assertEqual(backend.opened, [("COM7", 115200)])
        self.assertTrue(backend.all_closed())
        # Sıra: STATUS (kart/durum) -> FACTORYINIT -> STATUS (doğrulama)
        commands = firmware.commands
        self.assertEqual(commands[0], "STATUS")
        self.assertEqual(commands.count("FACTORYINIT"), 1)
        self.assertEqual(commands[-1], "STATUS")
        self.assertLess(commands.index("STATUS"), commands.index("FACTORYINIT"))
        self.assertTrue(any("doğrulan" in line for line in lines))

    def test_firmware_receives_the_exact_line_and_it_is_never_echoed(self):
        provisioner, _, firmware, _ = make(noise=True)
        run(provisioner)
        self.assertEqual(firmware.received.count("FACTORYINIT %s %s" % (KEY, AP)), 1)
        self.assertEqual(firmware.leaks, [])

    def test_garbage_in_firmware_line_buffer_is_flushed_before_factoryinit(self):
        # Satır tamponunda çöp kalırsa FACTORYINIT "junkFACTORYINIT ..." olur ve firmware onu (gizli değerlerle) YANKILAR.
        provisioner, _, firmware, _ = make(inject_garbage=True)
        outcome, _ = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertEqual(firmware.leaks, [])
        self.assertIn("junk", firmware.received)

    def test_boot_wait_polls_status_until_firmware_answers(self):
        provisioner, _, firmware, _ = make(boot_ticks=12)
        outcome, lines = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertTrue(any("açılması" in line for line in lines))

    def test_wait_for_port_after_flash(self):
        provisioner, backend, _, _ = make(backend_kwargs={"hidden_polls": 4})
        outcome, lines = run(provisioner, wait_for_port=True)
        self.assertTrue(outcome.verified)
        self.assertGreaterEqual(backend.list_calls, 5)
        self.assertTrue(any("yeniden görünmesi" in line for line in lines))

    def test_missing_port_fails_fast_when_not_waiting(self):
        provisioner, backend, firmware, clock = make(backend_kwargs={"hidden_polls": 99})
        start = clock.now()
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "port_not_found")
        self.assertIn("COM7", ctx.exception.message)
        self.assertEqual(backend.opened, [])
        self.assertLess(clock.now() - start, 5)  # beklemeden hata

    def test_port_that_never_returns_times_out(self):
        provisioner, _, _, clock = make(backend_kwargs={"hidden_polls": 10 ** 9})
        start = clock.now()
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner, wait_for_port=True)
        self.assertEqual(ctx.exception.code, "port_not_found")
        self.assertLessEqual(clock.now() - start, fc.SERIAL_PORT_WAIT_S + fc.SERIAL_BOOT_WAIT_S + 5)

    def test_transient_busy_port_is_retried(self):
        provisioner, backend, _, _ = make()
        backend.open_errors = [fc.SerialError("meşgul", kind="busy"), fc.SerialError("meşgul", kind="busy")]
        outcome, _ = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertEqual(len(backend.opened), 3)

    def test_permanently_busy_port_reports_which_program_to_close(self):
        provisioner, backend, _, _ = make()
        backend.open_errors = [fc.SerialError("meşgul", kind="busy") for _ in range(200)]
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "port_busy")
        self.assertIn("Seri monitör", ctx.exception.hint)

    def test_unresponsive_firmware_gives_no_response_after_bounded_wait(self):
        provisioner, backend, _, clock = make(unresponsive=True)
        start = clock.now()
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "no_response")
        self.assertIn("firmware", ctx.exception.hint)
        self.assertTrue(backend.all_closed())
        self.assertLessEqual(clock.now() - start, fc.SERIAL_BOOT_WAIT_S + fc.SERIAL_STATUS_TIMEOUT_S + 3)

    def test_usb_dropout_during_probe_reconnects(self):
        provisioner, backend, _, _ = make(boot_ticks=6)
        backend.next_drop_after_reads = 3  # ilk bağlantı yeniden numaralanırken kopar
        outcome, _ = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertEqual(len(backend.connections), 2)
        self.assertTrue(backend.all_closed())

    def test_mac_mismatch_blocks_before_anything_is_written(self):
        provisioner, _, firmware, _ = make(mac="AA:BB:CC:00:11:22")
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "mac_mismatch")
        self.assertIn("AA:BB:CC:00:11:22", ctx.exception.message)
        self.assertIn(MAC, ctx.exception.message)
        self.assertNotIn("FACTORYINIT", firmware.commands)
        self.assertFalse(firmware.provisioned)

    def test_already_provisioned_needs_explicit_reset_and_is_not_touched_otherwise(self):
        provisioner, _, firmware, _ = make(provisioned=True)
        firmware.local_key = "ESKI-ANAHTAR-12345"
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "already_provisioned")
        self.assertTrue(ctx.exception.can_reset)
        self.assertIn("RESETKEY", ctx.exception.hint)
        self.assertEqual(firmware.local_key, "ESKI-ANAHTAR-12345")  # dokunulmadı
        self.assertNotIn("RESETKEY", firmware.commands)
        self.assertNotIn("FACTORYINIT", firmware.commands)

    def test_reset_existing_sends_resetkey_then_provisions(self):
        provisioner, _, firmware, _ = make(provisioned=True)
        outcome, lines = run(provisioner, reset_existing=True)
        self.assertTrue(outcome.verified)
        self.assertEqual((firmware.local_key, firmware.ap_pass), (KEY, AP))
        self.assertLess(firmware.commands.index("RESETKEY"), firmware.commands.index("FACTORYINIT"))
        self.assertTrue(any("RESETKEY" in line for line in lines))

    def test_reset_failure_is_reported(self):
        provisioner, _, firmware, _ = make(provisioned=True, reset_fails=True)
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner, reset_existing=True)
        self.assertEqual(ctx.exception.code, "reset_failed")
        self.assertNotIn("FACTORYINIT", firmware.commands)

    def test_every_documented_err_code_has_a_turkish_message(self):
        cases = {
            "invalid_local_key": ("yerel anahtarı reddetti", "invalid_local_key"),
            "invalid_ap_pass": ("AP parolasını reddetti", "invalid_ap_pass"),
            "persist_failed": ("kalıcı belleğe yazamadı", "persist_failed"),
            "already_provisioned": ("zaten bir yerel anahtar", "already_provisioned"),
        }
        for firmware_code, (needle, expected_code) in cases.items():
            provisioner, _, firmware, _ = make(force_error=firmware_code)
            with self.assertRaises(fc.ProvisionError) as ctx:
                run(provisioner)
            self.assertEqual(ctx.exception.code, expected_code, firmware_code)
            self.assertIn(needle, ctx.exception.message, firmware_code)
            self.assertFalse(firmware.provisioned)
            text = fc.provision_error_text(ctx.exception)
            self.assertNotIn(KEY, text)
            self.assertNotIn(AP, text)
        # persist_failed: ne yapılacağı söylenir
        provisioner, _, _, _ = make(force_error="persist_failed")
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertIn("Erase Flash", ctx.exception.hint)

    def test_unknown_err_code_is_shown_only_as_a_safe_token(self):
        provisioner, _, _, _ = make(force_error="weird_code")
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "unexpected")
        self.assertIn("weird_code", ctx.exception.message)

    def test_hostile_device_line_is_never_shown(self):
        provisioner, _, _, _ = make(force_error="<script>alert(1)</script>")
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        text = fc.provision_error_text(ctx.exception)
        self.assertNotIn("script", text)  # ayrıştırılamayan satır: yanıt yok sayılır -> no_response
        self.assertEqual(ctx.exception.code, "no_response")

    def test_persist_failed_is_retried_and_can_succeed(self):
        provisioner, _, firmware, _ = make(persist_failures=2)
        outcome, lines = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertEqual(firmware.commands.count("FACTORYINIT"), 3)
        self.assertTrue(any("yeniden deneniyor" in line for line in lines))

    def test_persist_failed_gives_up_after_bounded_retries(self):
        provisioner, _, firmware, _ = make(persist_failures=99)
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "persist_failed")
        self.assertEqual(firmware.commands.count("FACTORYINIT"), fc.SERIAL_PERSIST_RETRIES)
        self.assertFalse(firmware.provisioned)

    def test_lost_ok_but_device_provisioned_counts_as_success_without_resending(self):
        provisioner, _, firmware, _ = make(mute_factoryinit=1)
        outcome, _ = run(provisioner)
        self.assertTrue(outcome.verified)
        self.assertEqual(firmware.commands.count("FACTORYINIT"), 1)  # kart zaten provizyonlu: tekrar gönderilmez

    def test_silent_firmware_is_retried_then_times_out(self):
        provisioner, _, firmware, clock = make(drop_factoryinit=True)
        start = clock.now()
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner)
        self.assertEqual(ctx.exception.code, "no_response")
        self.assertEqual(firmware.commands.count("FACTORYINIT"), fc.SERIAL_PERSIST_RETRIES)
        self.assertLessEqual(clock.now() - start, 120)  # sınırlı bekleme

    def test_cancel_stops_before_writing(self):
        provisioner, backend, firmware, clock = make(boot_ticks=50)
        cancel = threading.Event()
        clock.on_sleep = cancel.set  # kullanıcı bekleme sırasında "iptal"e bastı
        with self.assertRaises(fc.ProvisionError) as ctx:
            run(provisioner, cancel=cancel)
        self.assertEqual(ctx.exception.code, "cancelled")
        self.assertNotIn("FACTORYINIT", firmware.commands)
        self.assertTrue(backend.all_closed())

    def test_invalid_values_never_reach_the_wire(self):
        provisioner, backend, firmware, _ = make()
        with self.assertRaises(fc.ProvisionError) as ctx:
            provisioner.provision("COM7", "kisa", AP, expected_mac=MAC)
        self.assertEqual(ctx.exception.code, "rejected")
        self.assertEqual(backend.opened, [])
        self.assertEqual(firmware.received, [])

    def test_noisy_logs_do_not_break_parsing_and_are_never_displayed(self):
        provisioner, _, firmware, _ = make(noise=True)
        outcome, lines = run(provisioner)
        self.assertTrue(outcome.verified)
        for line in lines:  # ilerleme metinleri aracın kendi cümleleri: ham cihaz satırı YOK
            self.assertNotIn("[WiFiManager]", line)
            self.assertNotIn("[STATUS]", line)
            self.assertNotIn("[CLI]", line)

    def test_send_buffers_are_wiped_after_use(self):
        seen = []
        original = fc.wipe_bytes

        def spy(buffer):
            seen.append(buffer)
            original(buffer)

        provisioner, _, _, _ = make(persist_failures=1)
        with mock.patch.object(fc, "wipe_bytes", spy):
            run(provisioner)
        self.assertEqual(len(seen), 2)  # iki deneme = iki tampon
        for buffer in seen:
            self.assertEqual(set(buffer), {0})

    def test_flash_workflow_wait_for_port_with_boot_and_noise(self):
        # Gerçek akışa en yakın birleşim: port gecikmeli, açılış gecikmeli, gürültülü günlük, USB bir kez kopar
        provisioner, backend, firmware, _ = make(boot_ticks=9, noise=True, backend_kwargs={"hidden_polls": 3})
        backend.next_drop_after_reads = 4
        outcome, _ = run(provisioner, wait_for_port=True)
        self.assertTrue(outcome.verified)
        self.assertEqual((firmware.local_key, firmware.ap_pass), (KEY, AP))
        self.assertEqual(firmware.leaks, [])


# ============================================================================================================
# Gizli değerlerin hiçbir yerde görünmemesi (çalışma zamanı + kaynak taraması)
# ============================================================================================================
class SerialSecretHandlingTests(unittest.TestCase):
    def test_runtime_secrets_never_appear_in_progress_outcome_or_errors(self):
        everything = []
        scenarios = [
            dict(),                                    # başarı
            dict(noise=True, inject_garbage=True),     # gürültü + çöp
            dict(provisioned=True),                    # already_provisioned
            dict(force_error="invalid_ap_pass"),
            dict(persist_failures=99),
            dict(mac="AA:BB:CC:00:11:22"),
            dict(unresponsive=True),
        ]
        for scenario in scenarios:
            provisioner, backend, firmware, _ = make(**scenario)
            try:
                outcome, lines = run(provisioner)
                everything.extend(lines)
                everything.append(repr(outcome))
            except fc.ProvisionError as exc:
                everything.extend([str(exc), exc.message, exc.hint, repr(exc), fc.provision_error_text(exc, "AHBU-DD8754")])
            self.assertEqual(firmware.leaks, [], scenario)
        joined = "\n".join(everything)
        self.assertNotIn(KEY, joined)
        self.assertNotIn(AP, joined)
        self.assertNotIn("FACTORYINIT " + KEY, joined)

    def test_relay_process_arguments_never_contain_secrets(self):
        recorded = []
        real_popen = subprocess.Popen

        def spy(args, *a, **k):
            recorded.append((list(args), dict(k.get("env") or {})))
            return real_popen(args, *a, **k)

        with tempfile.TemporaryDirectory() as tmp:
            write_stub_serial_package(tmp, boot_ticks=0)
            backend = fc.RelayBackend(sys.executable, env={"PYTHONPATH": tmp})
            provisioner = fc.SerialProvisioner(backend)
            with mock.patch.object(subprocess, "Popen", spy):
                outcome = provisioner.provision("COM7", KEY, AP, expected_mac=None)
        self.assertTrue(outcome.verified)
        self.assertTrue(recorded)
        for args, env in recorded:
            self.assertTrue(all(isinstance(a, str) for a in args))
            blob = " ".join(args) + " " + env.get("PYTHONPATH", "")  # yalnızca argv + aracın verdiği PYTHONPATH
            self.assertNotIn(KEY, blob)
            self.assertNotIn(AP, blob)

    def test_source_never_passes_secrets_to_logging_or_ui_functions(self):
        secret_names = {"local_key", "ap_pass", "payload", "pin", "password", "qr_claim_url", "access_token", "refresh_token", "api_key",
                        # G3: etiketin 2. karekodu AP parolasını taşır
                        "wifi_payload", "wifi_qr_payload", "device_wifi_qr_payload", "label_wifi_qr_payload", "escape_wifi_qr_value"}
        sinks = {"print", "say", "progress", "_prov_say", "log", "ui_info", "ui_warn", "ui_error", "ui_confirm",
                 "showinfo", "showwarning", "showerror", "askyesno", "debug", "info", "warning", "error", "exception"}

        def callee_name(node):
            if isinstance(node, ast.Name):
                return node.id
            if isinstance(node, ast.Attribute):
                return node.attr
            return ""

        def names_in(node):
            for child in ast.walk(node):
                if isinstance(child, ast.Name):
                    yield child.id
                elif isinstance(child, ast.Attribute):
                    yield child.attr

        findings = []
        for path in SOURCE_FILES:
            with open(path, "r", encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and callee_name(node.func) in sinks:
                    leaked = secret_names.intersection(n for arg in list(node.args) + [k.value for k in node.keywords] for n in names_in(arg))
                    if leaked:
                        findings.append((os.path.basename(path), node.lineno, sorted(leaked)))
        self.assertEqual(findings, [])

    def test_no_logging_module_and_no_stderr_dumps_in_serial_code(self):
        for path in SOURCE_FILES:
            with open(path, "r", encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    self.assertNotIn("logging", [a.name for a in node.names], os.path.basename(path))
                if isinstance(node, ast.ImportFrom):
                    self.assertNotEqual(node.module, "logging", os.path.basename(path))
        with open(SOURCE_FILES[1], "r", encoding="utf-8") as handle:
            client_tree = ast.parse(handle.read())
        for node in ast.walk(client_tree):  # (alt yorumlayıcıya giden betik metinleri çağrı değildir)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                self.assertNotEqual(node.func.id, "print")
            if isinstance(node, ast.Attribute):
                self.assertNotEqual(node.attr, "stderr")

    def test_no_package_is_ever_installed(self):
        # pyserial yoksa araç YENİ PAKET KURMAZ: hiçbir alt süreç çağrısının argümanında pip/install geçmez
        for path in SOURCE_FILES:
            with open(path, "r", encoding="utf-8") as handle:
                tree = ast.parse(handle.read())
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and callee_name_for_subprocess(node):
                    for sub in ast.walk(node):
                        if isinstance(sub, ast.Constant) and isinstance(sub.value, str):
                            self.assertNotRegex(sub.value.lower(), r"\bpip\b|\binstall\b", os.path.basename(path))

    def test_send_buffers_use_bytearray_and_are_wiped_in_source(self):
        with open(SOURCE_FILES[1], "r", encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn("wipe_bytes(payload)", source)
        self.assertIn("bytearray(", source)


def callee_name_for_subprocess(call):
    func = call.func
    return (
        isinstance(func, ast.Attribute)
        and func.attr in ("run", "Popen", "check_call", "check_output", "call")
        and isinstance(func.value, ast.Name)
        and func.value.id == "subprocess"
    )


# ============================================================================================================
# Hata sınıflandırma ve arka uçlar
# ============================================================================================================
class FakePySerialModule:
    """Aracın kendi pyserial'ını taklit eder (``PySerialBackend`` enjeksiyonu)."""

    class SerialException(Exception):
        pass

    class Serial:
        instances = []
        open_error = None

        def __init__(self):
            self.port = None
            self.baudrate = None
            self.timeout = None
            self.write_timeout = None
            self.dtr = True
            self.rts = True
            self.state_at_open = None
            self.written = []
            self.rx = bytearray()
            self.io_error = None
            self.closed = False
            type(self).instances.append(self)

        def open(self):
            self.state_at_open = (self.dtr, self.rts)
            if type(self).open_error is not None:
                raise type(self).open_error

        @property
        def in_waiting(self):
            return len(self.rx)

        def read(self, size=1):
            if self.io_error:
                raise self.io_error
            data = bytes(self.rx[:size])
            del self.rx[:size]
            return data

        def write(self, data):
            if self.io_error:
                raise self.io_error
            self.written.append(bytes(data))
            return len(data)

        def flush(self):
            pass

        def close(self):
            self.closed = True


class FakeListPorts:
    @staticmethod
    def comports():
        return [mock.Mock(device="COM7", description="USB Serial (test)"), mock.Mock(device="COM9", description=None)]


class PySerialBackendTests(unittest.TestCase):
    def setUp(self):
        FakePySerialModule.Serial.instances = []
        FakePySerialModule.Serial.open_error = None

    def backend(self):
        return fc.PySerialBackend(serial_module=FakePySerialModule, list_ports_module=FakeListPorts)

    def test_list_ports(self):
        self.assertEqual(self.backend().list_ports(), [("COM7", "USB Serial (test)"), ("COM9", "")])

    def test_open_never_asserts_dtr_rts_and_sets_baud_and_timeouts(self):
        connection = self.backend().open("COM7")
        ser = FakePySerialModule.Serial.instances[-1]
        self.assertEqual(ser.state_at_open, (False, False))  # açarken kart sıfırlanmasın
        self.assertEqual((ser.port, ser.baudrate), ("COM7", 115200))
        self.assertGreater(ser.timeout, 0)
        self.assertGreater(ser.write_timeout, 0)
        connection.close()
        self.assertTrue(ser.closed)

    def test_open_errors_are_classified_in_turkish(self):
        cases = [
            (FakePySerialModule.SerialException("could not open port 'COM9': FileNotFoundError(2, 'The system cannot find the file specified.', None, 2)"), "not_found"),
            (FakePySerialModule.SerialException("could not open port 'COM7': PermissionError(13, 'Access is denied.', None, 5)"), "busy"),
            (FakePySerialModule.SerialException("garip bir hata"), "other"),
        ]
        for error, kind in cases:
            FakePySerialModule.Serial.open_error = error
            with self.assertRaises(fc.SerialError) as ctx:
                self.backend().open("COM7")
            self.assertEqual(ctx.exception.kind, kind)
            self.assertNotIn("FileNotFoundError", str(ctx.exception))  # ham metin gösterilmez
            self.assertNotIn("Access is denied", str(ctx.exception))

    def test_io_errors_become_a_clean_serial_error(self):
        connection = self.backend().open("COM7")
        ser = FakePySerialModule.Serial.instances[-1]
        ser.io_error = FakePySerialModule.SerialException("ClearCommError failed (PermissionError(13, 'Access is denied.'))")
        with self.assertRaises(fc.SerialError) as ctx:
            connection.read(100, 0.1)
        self.assertEqual(ctx.exception.kind, "io")
        with self.assertRaises(fc.SerialError):
            connection.write(b"STATUS\r\n")

    def test_read_returns_burst_up_to_size(self):
        connection = self.backend().open("COM7")
        ser = FakePySerialModule.Serial.instances[-1]
        ser.rx.extend(b"abcdef")
        self.assertEqual(connection.read(4, 0.1), b"abcd")
        self.assertEqual(connection.read(10, 0.1), b"ef")
        self.assertEqual(connection.read(10, 0.1), b"")


class SerialBackendSelectionTests(unittest.TestCase):
    def test_own_python_is_preferred_and_no_other_interpreter_is_probed(self):
        probed = []
        backend = fc.select_serial_backend(["pythonA"], in_process_probe=lambda: True, interpreter_probe=lambda exe: probed.append(exe) or True)
        self.assertIsInstance(backend, fc.PySerialBackend)
        self.assertEqual(probed, [])

    def test_falls_back_to_platformio_penv_via_relay(self):
        probed = []

        def probe(exe):
            probed.append(exe)
            return exe == "second-python"

        backend = fc.select_serial_backend(["first-python", "second-python", "third-python"], in_process_probe=lambda: False, interpreter_probe=probe)
        self.assertIsInstance(backend, fc.RelayBackend)
        self.assertEqual(backend.python, "second-python")
        self.assertEqual(probed, ["first-python", "second-python"])  # bulunca durur
        self.assertIn("second-python", backend.description)

    def test_unavailable_everywhere_never_installs_anything(self):
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("alt surec calistirilmamali")), \
                mock.patch.object(subprocess, "Popen", side_effect=AssertionError("alt surec calistirilmamali")):
            with self.assertRaises(fc.SerialUnavailableError) as ctx:
                fc.select_serial_backend(["x"], in_process_probe=lambda: False, interpreter_probe=lambda exe: False)
        self.assertIn("KURMAZ", str(ctx.exception))
        self.assertIn("1 yardımcı Python", str(ctx.exception))
        with self.assertRaises(fc.SerialUnavailableError) as ctx:
            fc.select_serial_backend([], in_process_probe=lambda: False)
        self.assertIn("PlatformIO penv da bulunamadı", str(ctx.exception))

    def test_platformio_candidates_cover_windows_and_posix_layouts(self):
        candidates = fc.platformio_python_candidates(["C:\\pio", "C:\\pio", "/home/u/.platformio"])
        self.assertEqual(len(candidates), 4)  # tekrarsız: 2 kök x 2 düzen
        self.assertTrue(any(c.endswith(os.path.join("penv", "Scripts", "python.exe")) for c in candidates))
        self.assertTrue(any(c.endswith(os.path.join("penv", "bin", "python")) for c in candidates))

    def test_default_interpreter_probe_uses_list_args_timeout_and_no_shell(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = os.path.join(tmp, "python.exe")
            open(exe, "w").close()
            completed = subprocess.CompletedProcess([exe], 0, stdout="PYSERIAL_OK 3.5\n", stderr="")
            with mock.patch.object(subprocess, "run", return_value=completed) as run_mock:
                self.assertTrue(fc._default_interpreter_probe(exe))
            args, kwargs = run_mock.call_args
            self.assertEqual(args[0][0], exe)
            self.assertEqual(args[0][1], "-c")
            self.assertIsInstance(args[0], list)
            self.assertFalse(kwargs.get("shell", False))
            self.assertGreater(kwargs["timeout"], 0)
            failed = subprocess.CompletedProcess([exe], 1, stdout="", stderr="ModuleNotFoundError")
            with mock.patch.object(subprocess, "run", return_value=failed):
                self.assertFalse(fc._default_interpreter_probe(exe))
            with mock.patch.object(subprocess, "run", side_effect=subprocess.TimeoutExpired(exe, 1)):
                self.assertFalse(fc._default_interpreter_probe(exe))
            with mock.patch.object(subprocess, "run", side_effect=OSError("yok")):
                self.assertFalse(fc._default_interpreter_probe(exe))
        with mock.patch.object(subprocess, "run", side_effect=AssertionError("dosya yokken calistirilmamali")):
            self.assertFalse(fc._default_interpreter_probe(os.path.join(tmp, "yok", "python.exe")))
            self.assertFalse(fc._default_interpreter_probe(""))

    def test_real_interpreter_probe_with_stub_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            write_stub_serial_package(tmp)
            env = dict(os.environ, PYTHONPATH=tmp)
            done = subprocess.run([sys.executable, "-c", fc._PROBE_SCRIPT], capture_output=True, text=True, env=env, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn("PYSERIAL_OK", done.stdout)


class RelayBackendEndToEndTests(unittest.TestCase):
    """Gerçek alt süreç + sahte pyserial paketi: röle protokolü ve uçtan uca provizyon."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def backend(self, **firmware_kwargs):
        write_stub_serial_package(self.tmp.name, **firmware_kwargs)
        return fc.RelayBackend(sys.executable, env={"PYTHONPATH": self.tmp.name})

    def test_list_ports_through_helper_interpreter(self):
        self.assertEqual(self.backend().list_ports(), [("COM7", "Stub USB Serial")])

    def test_relay_opens_with_dtr_rts_low_and_streams_bytes(self):
        backend = self.backend()
        connection = backend.open("COM7")  # stub, DTR/RTS açıksa SerialException fırlatır
        try:
            connection.write(b"\r\nSTATUS\r\n")
            collected = b""
            for _ in range(40):
                collected += connection.read(4096, 0.25)
                if b"local_key" in collected:
                    break
            self.assertIn(b"[STATUS] Cihaz:", collected)
            self.assertIn(b"YOK (provizyonsuz cihaz)", collected)
        finally:
            connection.close()

    def test_relay_open_errors_are_classified(self):
        backend = self.backend()
        with self.assertRaises(fc.SerialError) as ctx:
            backend.open("COM_MISSING")
        self.assertEqual(ctx.exception.kind, "not_found")
        with self.assertRaises(fc.SerialError) as ctx:
            backend.open("COM_BUSY")
        self.assertEqual(ctx.exception.kind, "busy")

    def test_missing_helper_python_is_a_clean_error(self):
        backend = fc.RelayBackend(os.path.join(self.tmp.name, "yok", "python.exe"))
        with self.assertRaises(fc.SerialError):
            backend.open("COM7")
        with self.assertRaises(fc.SerialError):
            backend.list_ports()

    def test_full_provisioning_through_the_relay(self):
        backend = self.backend(boot_ticks=3)
        outcome = fc.SerialProvisioner(backend).provision("COM7", KEY, AP, expected_mac=MAC)
        self.assertTrue(outcome.verified)
        self.assertEqual(outcome.via, "serial")
        self.assertEqual(outcome.mac, MAC)

    def test_relay_provisioning_reports_already_provisioned(self):
        backend = self.backend(provisioned=True)
        with self.assertRaises(fc.ProvisionError) as ctx:
            fc.SerialProvisioner(backend).provision("COM7", KEY, AP, expected_mac=MAC)
        self.assertEqual(ctx.exception.code, "already_provisioned")


if __name__ == "__main__":
    unittest.main(verbosity=2)
