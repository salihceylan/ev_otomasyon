# -*- coding: utf-8 -*-
"""
Seri port taklitleri (donanımsız, ağsız) - G2 testleri için.

* ``FakeFirmwareCli``  : firmware seri CLI'sının (main.cpp, docs/CONTRACTS.md §3c) saf-Python benzeri. Baytlar içeri /
                         baytlar dışarı; SAAT BİLMEZ (bu yüzden sahte ``serial`` paketine aynen gömülebilir).
                         Satır tamponu (159), yankı kuralları (FACTORYINIT/WIFI yankılanmaz), ``STATUS`` çıktısı,
                         ``FACTORYINIT`` (CliParse.h anlamı), ``RESETKEY``, açılış gecikmesi ve gürültülü günlükler.
* ``FakeClock``        : sahte zaman (``sleep`` zamanı ilerletir; gerçek bekleme yok).
* ``FakeConnection``   : SerialProvisioner'ın beklediği bağlantı (write/read/close) + boşta okumada saat ilerletme.
* ``FakeSerialBackend``: ``list_ports()`` / ``open()`` arka ucu (port gecikmeli görünme, açma hataları...).
* ``write_stub_serial_package``: BAŞKA bir yorumlayıcıda ``import serial`` edilecek sahte pyserial paketi (röle testi).

Not: bu dosya test altyapısıdır; ``test*.py`` adıyla eşleşmediği için keşfedilen bir test içermez.
"""

import inspect
import os
import textwrap
import threading


class FakeFirmwareCli:
    """main.cpp seri CLI'sının bayt-bayt benzeri (yalnızca provizyonla ilgili komutlar + gürültü)."""

    MAX_LINE = 159

    def __init__(
        self,
        mac="E8:F6:0A:DD:87:54",
        provisioned=False,
        boot_ticks=0,
        persist_failures=0,
        noise=False,
        mute_factoryinit=0,
        name="AHBU Akilli Ev Kontrol",
        force_error=None,
        unresponsive=False,
        reset_fails=False,
        drop_factoryinit=False,
        inject_garbage=False,
        tpl_supported=True,
        tpl_error=None,
        tpl_drop_data=0,
    ):
        self.mac = mac.upper()
        self.provisioned = provisioned
        self.local_key = ""
        self.ap_pass = ""
        self.boot_ticks = boot_ticks
        self.persist_failures = persist_failures
        self.noise = noise
        self.mute_factoryinit = mute_factoryinit  # FACTORYINIT yanıtını bu kadar kez YUT (komut yine uygulanır)
        self.name = name
        self.force_error = force_error            # her FACTORYINIT'e "ERR <bu>" yanıtı (durum değişmez)
        self.unresponsive = unresponsive          # CLI hiç yanıt vermez (yanlış/bozuk firmware)
        self.reset_fails = reset_fails
        self.drop_factoryinit = drop_factoryinit  # FACTORYINIT satırı hiç işlenmez (yanıt da yok)
        self.inject_garbage = inject_garbage      # ilk STATUS'tan sonra satır tamponuna çöp bırakır (USB gürültüsü)
        self._garbage_pending = False
        # Şablon (TPL, README "Seri protokol"): v1.3.0+ firmware'i. tpl_error: COMMIT'te "ERR <kod> [yol]" (örn.
        # "zone_latched"); tpl_drop_data: ilk N DATA parçası kaybolur (CRC uyuşmazlığı benzetimi).
        self.tpl_supported = tpl_supported
        self.tpl_error = tpl_error
        self.tpl_drop_data = tpl_drop_data
        self.tpl_id = None
        self.tpl_ver = 0
        self.tpl_label = ""
        self.tpl_applied = []                     # TEST DENETİMİ: uygulanan zarflar (dict)
        self._tpl = None                          # {"len", "crc", "buf"} aktarım sürerken
        self.booted = boot_ticks <= 0
        self.received = []                        # TEST DENETİMİ: cihazın aldığı (kırpılmış) komut satırları
        self.commands = []                        # ilk sözcükler (STATUS, FACTORYINIT, ...)
        self.leaks = []                           # yankıda izlenen gizli değer görüldüyse (test denetimi)
        self.watch = []                           # yankıda aranacak gizli değerler
        self._line = bytearray()
        self._overflow = False
        self._input = bytearray()                 # açılış bitene kadar USB tamponunda bekleyen baytlar
        self._out = bytearray()

    # ---- bayt arayüzü ----
    def feed(self, data):
        if self.unresponsive:
            return
        if not self.booted:
            self._input.extend(data)
            return
        self._consume(data)

    def tick(self):
        if self.booted:
            return
        self.boot_ticks -= 1
        if self.boot_ticks <= 0:
            self.booted = True
            self._say("[BOOT] ConfigManager tamam.")
            self._say("Sistem hazir!")
            pending = bytes(self._input)
            self._input.clear()
            self._consume(pending)

    def pull(self, size):
        data = bytes(self._out[:size])
        del self._out[:size]
        return data

    def available(self):
        return len(self._out)

    # ---- CLI ----
    def _say(self, text):
        if any(w and w in text for w in self.watch):
            self.leaks.append(text)
        self._out.extend((text + "\r\n").encode("latin-1", errors="replace"))

    def _noise(self, text):
        if self.noise:
            self._say(text)

    def _consume(self, data):
        for c in data:
            if c in (10, 13):
                if len(self._line) > 0 and not self._overflow:
                    self._handle(bytes(self._line))
                elif self._overflow:
                    self._say("[CLI-HATA] Satir cok uzun (en cok %d karakter)." % self.MAX_LINE)
                self._line = bytearray()
                self._overflow = False
                if self._garbage_pending:
                    self._garbage_pending = False
                    self._line = bytearray(b"junk")
            elif len(self._line) < self.MAX_LINE:
                self._line.append(c)
            else:
                self._overflow = True

    def _handle(self, raw):
        cmd = raw.decode("latin-1").strip(" \t\r\n")
        if not cmd:
            return
        words = cmd.split(" ")
        first = words[0]
        upper = first.upper()
        self.received.append(cmd)
        self.commands.append(upper)
        if upper == "FACTORYINIT":
            pass  # yankı YOK
        elif upper == "TPL" and self.tpl_supported and (words + [""])[1].upper() == "DATA":
            pass  # README: TPL DATA satırları yankılanmaz
        elif upper == "WIFI" and (words + ["", ""])[1].upper() != "CLEAR":
            self._say("")
            self._say("[CLI] Komut alindi: WIFI <ssid> <gizli>")
        else:
            self._say("")
            self._say("[CLI] Komut alindi: " + cmd)
        self._noise("[WiFiManager] arka plan gunlugu")
        if upper == "STATUS":
            self._status()
            if self.inject_garbage:
                self.inject_garbage = False
                self._garbage_pending = True
        elif upper == "FACTORYINIT":
            if not self.drop_factoryinit:
                self._factory_init(cmd)
        elif upper == "RESETKEY":
            # main.cpp ile AYNI satır (tests/test_serial_provision.py FirmwareSerialOutputContractTests denetler)
            reply = ("[CLI-SONUC] Yerel anahtar %s. Cihaz artik PROVIZYONSUZ (FACTORYINIT <local_key> <ap_pass> ya da "
                     "/api/factory/init). AP gerekirse: AP ON")
            if self.reset_fails:
                self._say(reply % "SILINEMEDI")
            else:
                self.provisioned = False
                self.local_key = ""
                self._say(reply % "SILINDI")
        elif upper == "TPL" and self.tpl_supported:
            self._tpl_command(words[1:])
        elif upper in ("HELP", "?"):
            self._say("[CLI] Komutlar: STATUS, MQTT, ... FACTORYINIT <local_key> <ap_pass> (yalniz PROVIZYONSUZ cihazda), RESETKEY, REBOOT")
        else:
            self._say("[CLI] Bilinmeyen komut: '%s'. (HELP yazin)" % first)

    def _tpl_command(self, args):
        """README: TPL BEGIN <bayt> <crc32-hex8> | DATA <base64> | COMMIT | ABORT | STATUS (sınıf kendi içinde: stub paket)."""
        import base64
        import binascii
        import json
        import zlib

        sub = (args[0].upper() if args else "")
        if sub == "STATUS":
            line = "TPL %s %d %s" % (self.tpl_id or "-", self.tpl_ver, self.tpl_label)
            self._out.extend((line.rstrip() + "\r\n").encode("utf-8"))  # firmware UTF-8 yazar (etiket Türkçe olabilir)
        elif sub == "ABORT":
            self._tpl = None
            self._say("OK tpl_abort")
        elif sub == "BEGIN":
            try:
                size, crc = int(args[1]), args[2].lower()
            except (IndexError, ValueError):
                self._say("ERR tpl_size")
                return
            if size <= 0 or size > 24576 or len(crc) != 8:
                self._say("ERR tpl_size")
                return
            self._tpl = {"len": size, "crc": crc, "buf": bytearray()}
            self._say("OK tpl_begin")
        elif sub == "DATA":
            if self._tpl is None:
                self._say("ERR tpl_no_begin")
                return
            try:
                chunk = base64.b64decode((args + [""])[1], validate=True)
            except (binascii.Error, ValueError):
                self._tpl = None
                self._say("ERR tpl_b64")
                return
            if self.tpl_drop_data > 0:
                self.tpl_drop_data -= 1
                chunk = b"\x00" * len(chunk)  # bozulan parça: CRC tutmaz
            self._tpl["buf"].extend(chunk)
            if len(self._tpl["buf"]) > self._tpl["len"]:
                self._tpl = None
                self._say("ERR tpl_overflow")
                return
            self._say("OK tpl_data %d" % len(self._tpl["buf"]))
        elif sub == "COMMIT":
            state, self._tpl = self._tpl, None
            if state is None:
                self._say("ERR tpl_no_begin")
                return
            data = bytes(state["buf"])
            if len(data) != state["len"] or ("%08x" % (zlib.crc32(data) & 0xFFFFFFFF)) != state["crc"]:
                self._say("ERR tpl_crc")
                return
            try:
                envelope = json.loads(data.decode("utf-8"))
                meta = envelope["template"]["meta"]
            except (ValueError, KeyError, TypeError):
                self._say("ERR bad_json")
                return
            if self.tpl_error:
                self._say("ERR " + self.tpl_error)
                return
            self.tpl_applied.append(envelope)
            self.tpl_id, self.tpl_ver = meta["template_id"], int(meta["version"])
            self.tpl_label = envelope.get("label") or meta.get("name", "")[:31]
            self._say("OK tpl_applied %s %d" % (self.tpl_id, self.tpl_ver))
        else:
            self._say("ERR bad_cmd")

    def _status(self):
        ssid = "AHBU-" + self.mac.replace(":", "")[-6:]
        lines = [
            "[STATUS] Cihaz: %s (MAC: %s)" % (self.name, self.mac),
            "  - IP (STA): Yok (Bagli: HAYIR, Sinyal: 0 dBm, Calisma: 5 sn, Deneme: 0)",
            "  - Kurtarma/servis AP: ACIK (SSID: %s, IP: 192.168.4.1) | Ac/kapat: AP ON | AP OFF" % ssid,
            "  - MQTTS (:0): BAGLANTI YOK | Kimlik: YOK (provizyon gerekli)",
            "  - Yerel anahtar (local_key): %s" % ("tanimli" if self.provisioned else "YOK (provizyonsuz cihaz)"),
            "  - Ek Modul: PASIF (Kanal: 0, Adres: 1, Yanit: HAYIR)",
            "  - Toplam Role: 8, Toplam DI: 8",
            "  - Yigin (hic kullanilmayan en az bayt): loopTask=2048, ShutterGuard=1024",
            "  - child_lock: OFF",
            "  - Yerel Roleler (8RO): [R1:0 R2:0 R3:0 R4:0 R5:0 R6:0 R7:0 R8:0]",
            "  - Yerel Girisler (8DI): [D1:0 D2:0 D3:0 D4:0 D5:0 D6:0 D7:0 D8:0]",
            "  - Panjurlar: []",
        ]
        if self.tpl_supported:  # v1.3.0+: CONTRACTS §3e yeni STATUS satırları (eski satırlar aynen kalır)
            lines += ["  - Ethernet: yok -", "  - Sablon: %s v%d" % (self.tpl_id or "-", self.tpl_ver)]
        for text in lines:
            self._say(text)
            self._noise("[WiFiManager] kesintili gunluk")

    @staticmethod
    def _parse(cmd):
        """CliParse.h anlamı: komut sözcüğü, local_key sözcüğü, ap_pass = satırın geri kalanı."""
        s = cmd.rstrip(" \t\r\n")
        n = len(s)
        i = 0
        while i < n and s[i] == " ":
            i += 1
        while i < n and s[i] != " ":
            i += 1
        while i < n and s[i] == " ":
            i += 1
        key_start = i
        while i < n and s[i] != " ":
            i += 1
        key_len = i - key_start
        while i < n and s[i] == " ":
            i += 1
        pass_start = i
        pass_len = n - pass_start
        if key_len < 8 or key_len > 32:
            return None, None, "invalid_local_key"
        if any(not (0x21 <= ord(ch) <= 0x7E) for ch in s[key_start:key_start + key_len]):
            return None, None, "invalid_local_key"
        if pass_len < 8 or pass_len > 32:
            return None, None, "invalid_ap_pass"
        if any(not (0x20 <= ord(ch) <= 0x7E) for ch in s[pass_start:]):
            return None, None, "invalid_ap_pass"
        return s[key_start:key_start + key_len], s[pass_start:], None

    def _reply(self, text):
        if self.mute_factoryinit > 0:
            self.mute_factoryinit -= 1
            return
        self._say(text)

    def _factory_init(self, cmd):
        if self.provisioned:
            self._reply("ERR already_provisioned")
            return
        if self.force_error:
            self._reply("ERR " + self.force_error)
            return
        key, password, error = self._parse(cmd)
        if error:
            self._reply("ERR " + error)
            return
        if self.persist_failures > 0:
            self.persist_failures -= 1
            self._reply("ERR persist_failed")
            return
        self.local_key, self.ap_pass, self.provisioned = key, password, True
        self._noise("[WiFiManager] AP yeniden baslatiliyor (WPA2)")
        self._reply("OK factory_init")


class FakeClock:
    """Sahte zaman: ``sleep`` ve boşta okumalar zamanı ilerletir (gerçek bekleme yok)."""

    def __init__(self, start=1000.0):
        self.t = start
        self.on_sleep = None  # test kancası: her sleep'te çağrılır

    def now(self):
        return self.t

    def advance(self, seconds):
        self.t += max(float(seconds), 0.0)

    def sleep(self, seconds):
        self.advance(seconds)
        if self.on_sleep is not None:
            self.on_sleep()


class FakeConnection:
    """SerialProvisioner için bağlantı: yazılanlar firmware'e gider; boşta okuma zamanı ilerletir."""

    def __init__(self, firmware, clock, drop_after_reads=None):
        self.firmware = firmware
        self.clock = clock
        self.closed = False
        self.reads = 0
        self.drop_after_reads = drop_after_reads

    def write(self, data):
        from factory_client import SerialError

        if self.closed:
            raise SerialError("kapali", kind="io")
        self.firmware.feed(bytes(data))

    def read(self, size=4096, timeout=0.2):
        from factory_client import SerialError

        if self.closed:
            raise SerialError("kapali", kind="io")
        self.reads += 1
        if self.drop_after_reads is not None and self.reads > self.drop_after_reads:
            self.closed = True
            raise SerialError("USB koptu", kind="io")
        self.firmware.tick()
        data = self.firmware.pull(size)
        if data:
            return data
        self.clock.advance(timeout)
        return b""

    def close(self):
        self.closed = True


class FakeSerialBackend:
    """``list_ports()`` / ``open()`` arka ucu. Aynı firmware nesnesi yeniden bağlanmalarda korunur."""

    kind = "fake"
    description = "sahte seri arka uç"

    def __init__(self, firmware, clock, ports=(("COM7", "USB Serial (test)"),), hidden_polls=0):
        self.firmware = firmware
        self.clock = clock
        self.ports = [tuple(p) for p in ports]
        self.hidden_polls = hidden_polls  # ilk N list_ports çağrısında port görünmez (USB yeniden numaralanıyor)
        self.list_calls = 0
        self.open_errors = []             # sıradaki open() çağrılarında fırlatılacak istisnalar
        self.open_threads = []            # open() hangi iş parçacıklarından çağrıldı (arayüz iş parçacığı olmamalı)
        self.opened = []
        self.connections = []
        self.next_drop_after_reads = None

    def list_ports(self):
        self.list_calls += 1
        if self.list_calls <= self.hidden_polls:
            return []
        return list(self.ports)

    def open(self, port, baud=115200):
        self.opened.append((port, baud))
        self.open_threads.append(threading.current_thread())
        if self.open_errors:
            raise self.open_errors.pop(0)
        connection = FakeConnection(self.firmware, self.clock, self.next_drop_after_reads)
        self.next_drop_after_reads = None
        self.connections.append(connection)
        return connection

    def all_closed(self):
        return all(c.closed for c in self.connections)


def write_stub_serial_package(directory, **firmware_kwargs):
    """``directory`` altına sahte bir ``serial`` (pyserial) paketi yazar; başka bir yorumlayıcıda
    ``PYTHONPATH=directory`` ile ``import serial`` edilince FakeFirmwareCli ile konuşan bir ``Serial`` verir."""
    package = os.path.join(directory, "serial")
    os.makedirs(os.path.join(package, "tools"), exist_ok=True)
    firmware_source = textwrap.dedent(inspect.getsource(FakeFirmwareCli))
    init_source = (
        "# Sahte pyserial (yalnızca test)\n"
        "import time\n"
        "__version__ = '0.0-test'\n\n\n"
        "class SerialException(Exception):\n"
        "    pass\n\n\n"
        + firmware_source
        + "\n\n_FW = FakeFirmwareCli(**%r)\n\n\n" % (firmware_kwargs,)
        + "class Serial:\n"
        "    def __init__(self):\n"
        "        self.port = None\n"
        "        self.baudrate = 9600\n"
        "        self.timeout = None\n"
        "        self.write_timeout = None\n"
        "        self.dtr = True\n"
        "        self.rts = True\n"
        "        self.is_open = False\n\n"
        "    def open(self):\n"
        "        if self.port == 'COM_MISSING':\n"
        "            raise SerialException(\"could not open port 'COM_MISSING': FileNotFoundError(2, 'The system cannot find the file specified.', None, 2)\")\n"
        "        if self.port == 'COM_BUSY':\n"
        "            raise SerialException(\"could not open port 'COM_BUSY': PermissionError(13, 'Access is denied.', None, 5)\")\n"
        "        if self.dtr or self.rts:\n"
        "            raise SerialException('DTR/RTS acik acildi (kart sifirlanabilirdi)')\n"
        "        self.is_open = True\n\n"
        "    @property\n"
        "    def in_waiting(self):\n"
        "        return _FW.available()\n\n"
        "    def read(self, size=1):\n"
        "        _FW.tick()\n"
        "        data = _FW.pull(size)\n"
        "        if not data:\n"
        "            time.sleep(self.timeout or 0.05)\n"
        "        return data\n\n"
        "    def write(self, data):\n"
        "        _FW.feed(bytes(data))\n"
        "        return len(data)\n\n"
        "    def flush(self):\n"
        "        pass\n\n"
        "    def close(self):\n"
        "        self.is_open = False\n"
    )
    with open(os.path.join(package, "__init__.py"), "w", encoding="utf-8") as handle:
        handle.write(init_source)
    with open(os.path.join(package, "tools", "__init__.py"), "w", encoding="utf-8") as handle:
        handle.write("")
    with open(os.path.join(package, "tools", "list_ports.py"), "w", encoding="utf-8") as handle:
        handle.write(
            "class _Port:\n"
            "    def __init__(self, device, description):\n"
            "        self.device = device\n"
            "        self.description = description\n\n\n"
            "def comports():\n"
            "    return [_Port('COM7', 'Stub USB Serial')]\n"
        )
    return package
