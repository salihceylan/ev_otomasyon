#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
EK MODÜL HAZIRLAMA VE YÜKLEME ARACI (AHBU Ev Otomasyonu)
=============================================================================
Bu araç, RS485 üzerinden ana modüle bağlanacak ek röle ve giriş modüllerinin
(ESP32-WROOM-32U 8DI-8RO vb.) yazılımını hazırlar, yapılandırır ve CH340
üzerinden karta yükler.

Kullanım:
    GUI Modu : python ek_modul_hazirla.py
    CLI Modu : python ek_modul_hazirla.py --cihaz 1 --mod kur --port COM3
    Bağlantı : python ek_modul_hazirla.py --mod test --port COM3
=============================================================================
"""

import os
import re
import sys
import json
import time
import subprocess
import argparse
import threading

try:
    import serial
    import serial.tools.list_ports
except ImportError:
    print("[HATA] 'pyserial' modülü eksik. Lütfen 'pip install pyserial' çalıştırın.")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
FIRMWARE_DIR = os.path.join(SCRIPT_DIR, "firmware")
CONFIG_H_PATH = os.path.join(FIRMWARE_DIR, "src", "config.h")
PIN_MAP_PATH = os.path.join(SCRIPT_DIR, "pin_haritasi.json")
PIO_ENV = "esp32_ek_modul"
BUILD_DIR = os.path.join(FIRMWARE_DIR, ".pio", "build", PIO_ENV)

# Bilinen USB-UART çevirici üreticileri (USB VID -> ad)
KNOWN_BRIDGES = {
    0x1A86: "WCH CH34x (CH340/CH343/CH9102)",
    0x10C4: "Silicon Labs CP210x",
    0x0403: "FTDI",
    0x303A: "Espressif yerel USB",
}

def load_pin_map():
    if os.path.exists(PIN_MAP_PATH):
        try:
            with open(PIN_MAP_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"[UYARI] Pin haritası okunamadı: {e}")
    return {
        "cihaz_no": 1,
        "role_pinleri": [25, 26, 27, 14, 12, 13, 32, 33],
        "role_aktif_seviye": "HIGH",
        "rs485": {"uart_no": 2, "tx_pin": 17, "rx_pin": 16, "de_re_pin": -1, "baudrate": 9600},
        "dijital_giris_74hc165": {"data_pin": 19, "clock_pin": 18, "latch_pin": 5}
    }

def save_pin_map(data):
    try:
        with open(PIN_MAP_PATH, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return True
    except Exception as e:
        print(f"[HATA] Pin haritası kaydedilemedi: {e}")
        return False

def generate_config_h(device_id=1, is_scanner=False):
    """config.h dosyasını verilen cihaz ID ve çalışma moduna göre günceller."""
    pin_data = load_pin_map()
    relays = pin_data.get("role_pinleri", [25, 26, 27, 14, 12, 13, 32, 33])
    relays_str = ", ".join(str(p) for p in relays)
    rs485 = pin_data.get("rs485", {})
    hc165 = pin_data.get("dijital_giris_74hc165", {})

    content = f"""#ifndef CONFIG_H
#define CONFIG_H

#include <Arduino.h>

// Otomatik Üretildi: {time.strftime('%Y-%m-%d %H:%M:%S')}
#define RUN_MODE_SCANNER {'1' if is_scanner else '0'}
#define DEVICE_ID {device_id}
#define RS485_BAUDRATE {rs485.get('baudrate', 9600)}

static const uint8_t RELAY_PINS[8] = {{ {relays_str} }};
#define RELAY_ACTIVE_LEVEL {pin_data.get('role_aktif_seviye', 'HIGH')}

#define RS485_TX_PIN {rs485.get('tx_pin', 17)}
#define RS485_RX_PIN {rs485.get('rx_pin', 16)}
#define RS485_DE_RE_PIN {rs485.get('de_re_pin', -1)}

#define HC165_DATA_PIN {hc165.get('data_pin', 19)}
#define HC165_CLOCK_PIN {hc165.get('clock_pin', 18)}
#define HC165_LATCH_PIN {hc165.get('latch_pin', 5)}

#endif // CONFIG_H
"""
    with open(CONFIG_H_PATH, "w", encoding="utf-8") as f:
        f.write(content)

def get_clean_env():
    """Python çakışmalarını önleyen izole ortam değişkenleri oluşturur."""
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    user_home = os.path.expanduser("~")
    penv_scripts = os.path.join(user_home, ".platformio", "penv", "Scripts")
    if os.path.exists(penv_scripts):
        env["PATH"] = penv_scripts + os.pathsep + env.get("PATH", "")
    return env

def get_esptool_env():
    """esptool çıktısının satır satır ve Türkçe karakterleri bozulmadan gelmesini sağlar."""
    env = os.environ.copy()
    env["PYTHONUNBUFFERED"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    return env

def find_pio_cmd():
    """PlatformIO komut listesini döndürür."""
    user_home = os.path.expanduser("~")
    penv_python = os.path.join(user_home, ".platformio", "penv", "Scripts", "python.exe")
    if os.path.exists(penv_python):
        return [penv_python, "-m", "platformio"]
    return ["pio"]

def build_firmware(log_cb=print):
    """PlatformIO ile firmware'i derler."""
    pio_cmd = find_pio_cmd()
    log_cb(f"[1/3] Firmware derleniyor ({' '.join(pio_cmd)})...")
    try:
        cmd = pio_cmd + ["run", "-d", FIRMWARE_DIR]
        clean_env = get_clean_env()
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace", env=clean_env)
        for line in iter(p.stdout.readline, ""):
            line_s = line.strip()
            if line_s:
                if any(k in line_s for k in ["Compiling", "Linking", "SUCCESS", "Archiving", "Building", "Generating", "FAILED", "Error", "error"]):
                    log_cb(f"  > {line_s}")
        p.stdout.close()
        p.wait()
        if p.returncode == 0:
            log_cb("[2/3] Derleme BAŞARILI!")
            return True
        else:
            log_cb(f"[HATA] Derleme başarısız oldu! (Çıkış kodu: {p.returncode})")
            return False
    except Exception as e:
        log_cb(f"[HATA] Derleme başlatılamadı: {e}")
        return False

def get_flash_images(log_cb=print):
    """'pio run -t upload' ile aynı (adres, dosya) listesini PlatformIO'dan okur.

    Arduino-ESP32 yüklemesi 4 görüntüdür: bootloader (0x1000), bölüm tablosu (0x8000),
    boot_app0/otadata (0xE000) ve uygulama (0x10000). boot_app0 yazılmazsa, kartta
    önceden OTA ile ikinci bölüme geçmiş bir yazılım varsa o eski yazılım açılmaya devam eder.
    """
    app_bin = os.path.join(BUILD_DIR, "firmware.bin")
    try:
        cmd = find_pio_cmd() + ["project", "metadata", "-d", FIRMWARE_DIR, "-e", PIO_ENV, "--json-output"]
        out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                             env=get_clean_env(), timeout=120).stdout
        data, _ = json.JSONDecoder().raw_decode(out, out.index("{"))
        extra = data[PIO_ENV]["extra"]
        images = [(img["offset"], img["path"]) for img in extra["flash_images"]]
        images.append((extra.get("application_offset", "0x10000"), app_bin))
        return images
    except Exception as e:
        log_cb(f"  > [UYARI] PlatformIO yükleme listesi okunamadı ({e}); boot_app0 (0xE000) yazılmayacak.")
        return [
            ("0x1000", os.path.join(BUILD_DIR, "bootloader.bin")),
            ("0x8000", os.path.join(BUILD_DIR, "partitions.bin")),
            ("0x10000", app_bin),
        ]

def run_esptool(args, log_cb=print):
    """esptool'u çalıştırır; çıktının tamamını (ilerleme satırlarını %10'da bir) loga aktarır."""
    cmd = [sys.executable, "-m", "esptool"] + args
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             encoding="utf-8", errors="replace", env=get_esptool_env())
    except Exception as e:
        log_cb(f"[HATA] esptool başlatılamadı: {e}")
        return 1, [str(e)]

    lines = []
    last_pct = -100.0
    for line in iter(p.stdout.readline, ""):
        line_s = line.strip()
        # esptool v5 eski (alt çizgili) seçenek adları için uyarı basar; adlar v4 ile uyum için korunuyor.
        if not line_s or line_s.startswith("WARNING: Deprecated"):
            continue
        lines.append(line_s)
        if line_s.startswith("Writing at"):
            m = re.search(r"(\d+(?:\.\d+)?)\s*%", line_s)
            if m:
                pct = float(m.group(1))
                if pct < last_pct:
                    last_pct = -100.0
                if pct < 100 and pct - last_pct < 10:
                    continue
                last_pct = pct
        log_cb(f"  > {line_s}")
    p.stdout.close()
    p.wait()
    return p.returncode, lines

def explain_esptool_failure(lines):
    """esptool hata çıktısını Türkçe, yapılabilir öneriye çevirir."""
    text = "\n".join(lines)
    hints = []
    if "No module named esptool" in text:
        hints.append(f"Bu Python'da esptool kurulu değil: \"{sys.executable}\" -m pip install esptool")
    if "FileNotFoundError" in text:
        hints.append("Port bulunamadı: adaptör çıkarılmış ya da COM numarası değişmiş. 'Yenile'ye basıp portu yeniden seçin.")
    elif any(k in text for k in ("PermissionError", "Erişim engellendi", "Access is denied", "port is busy")):
        hints.append("Port başka bir program tarafından açık (Arduino IDE / PlatformIO seri monitörü, "
                     "başka bir terminal, bu aracın ikinci kopyası). Onları kapatıp tekrar deneyin.")
    if "Wrong boot mode" in text:
        hints.append("Kart indirme modunda değil, normal açılmış. BOOT'a basılı tutun, RST/EN'e basıp bırakın "
                     "(ya da 12V'u kesip verin), sonra BOOT'u bırakıp tekrar deneyin.")
    if "No serial data received" in text:
        hints.append("ESP32'den hiç cevap gelmiyor. Sırayla kontrol edin: (1) Seçilen port gerçekten kartın "
                     "adaptörü mü (adaptörü çıkarıp 'Yenile' ile kaybolan portu bulun)? (2) Çapraz bağlantı: "
                     "adaptör TXD -> kart RX0, adaptör RXD -> kart TX0. (3) GND ortak mı? (4) Kart besleniyor mu "
                     "(12V veya 3.3V)? (5) Kart indirme modunda mı: BOOT basılıyken RST/EN'e bas-bırak, sonra BOOT'u bırak.")
    if any(k in text for k in ("Invalid head of packet", "serial noise", "Timed out waiting for packet", "stream stopped")):
        hints.append("Hat gürültülü ya da gerilim seviyesi uyumsuz: kabloyu kısaltın, adaptörün 3.3V/5V "
                     "seçicisini 3.3V'a alın, GND'nin bağlı olduğundan emin olun.")
    if "Failed to communicate with the flash" in text:
        hints.append("ESP32 cevap veriyor ama flaş belleğe erişemiyor: besleme yetersiz olabilir (kartı 12V'tan "
                     "besleyin) ya da GPIO12 açılışta HIGH tutuluyor olabilir.")
    m = re.search(r"This chip is (\S+)", text)
    if m:
        hints.append(f"Bağlanan çip ESP32 değil ({m.group(1)}); bu araç yalnız ESP32-WROOM kartlar içindir.")
    if not hints:
        hints.append("Yukarıdaki esptool çıktısının son satırlarını kontrol edin.")
    return hints

def boot_mode_instructions(log_cb):
    log_cb("  > Adaptörün DTR/RTS uçları karta bağlı değilse (yalnız GND/TX/RX), esptool kartı kendisi")
    log_cb("  >   resetleyemez; ESP32'yi ELLE indirme moduna alın:")
    log_cb("  >   1) BOOT'a basılı tutun  2) RST/EN'e basıp bırakın (ya da 12V'u kesip verin)  3) BOOT'u bırakın")
    log_cb("  >   Yalnız BOOT'a basılı tutmak yetmez: çip BOOT'u yalnızca reset anında okur.")

def test_connection(port, log_cb=print):
    """Firmware yazmadan, ESP32 ile esptool bağlantısını dener (chip_id)."""
    log_cb(f"[TEST] {port} üzerinden ESP32'ye bağlanılıyor (115200)...")
    boot_mode_instructions(log_cb)
    rc, lines = run_esptool([
        "--chip", "esp32", "--port", port, "--baud", "115200",
        "--before", "default_reset", "--after", "no_reset", "chip_id",
    ], log_cb)
    if rc == 0:
        log_cb(">> BAĞLANTI TAMAM: ESP32 indirme modunda ve cevap veriyor.")
        log_cb(">> Kartı resetlemeden 'Cihaz Firmware'ini Hazırla ve Kur' butonuna basabilirsiniz.")
        return True
    log_cb(f"[HATA] Bağlantı kurulamadı (esptool çıkış kodu: {rc}).")
    for h in explain_esptool_failure(lines):
        log_cb(f"  * {h}")
    return False

def flash_firmware(port, log_cb=print):
    """esptool ile derlenen firmware'i CH340 üzerinden ESP32'ye flaşlar."""
    images = get_flash_images(log_cb)
    missing = [path for _, path in images if not os.path.exists(path)]
    if missing:
        for path in missing:
            log_cb(f"[HATA] Yüklenecek dosya bulunamadı: {path}")
        return False

    log_cb(f"[3/3] ESP32'ye flaşlanıyor (Port: {port}, Hız: 115200)...")
    for offset, path in images:
        log_cb(f"  > {offset}  {os.path.basename(path)}")
    boot_mode_instructions(log_cb)
    args = [
        "--chip", "esp32",
        "--port", port,
        "--baud", "115200",
        "--before", "default_reset",
        "--after", "hard_reset",
        "write_flash", "-z",
        "--flash_mode", "dio",
        "--flash_freq", "40m",
        "--flash_size", "detect",
    ]
    for offset, path in images:
        args += [offset, path]

    rc, lines = run_esptool(args, log_cb)
    if rc == 0:
        log_cb("==================================================")
        log_cb(">> FIRMWARE BAŞARIYLA YÜKLENDİ! <<")
        log_cb("==================================================")
        log_cb("  > Yeni yazılımın çalışması için BOOT'a BASMADAN RST/EN'e bir kez basın ya da 12V'u kesip verin")
        log_cb("  >   (adaptörün RTS ucu karta bağlı değilse kart kendiliğinden yeniden başlamaz).")
        return True
    log_cb(f"[HATA] Flaşlama başarısız oldu (esptool çıkış kodu: {rc}).")
    for h in explain_esptool_failure(lines):
        log_cb(f"  * {h}")
    return False

def describe_port(p):
    """(etiket, bilinen_cevirici_mi) döndürür."""
    if p.vid is None:
        return f"{p.device} — {p.description} (USB değil)", False
    ids = f"VID:PID {p.vid:04X}:{p.pid:04X}"
    kind = KNOWN_BRIDGES.get(p.vid)
    if kind:
        return f"{p.device} — {p.description} — {ids} — {kind}", True
    return f"{p.device} — {p.description} — {ids} — tanınmayan çevirici (CH340 değil)", False

def list_serial_ports():
    return [p.device for p in serial.tools.list_ports.comports()]

# =============================================================================
# GUI ARAYÜZÜ (Tkinter)
# =============================================================================
def start_gui():
    import queue
    import tkinter as tk
    from tkinter import ttk, messagebox, scrolledtext

    root = tk.Tk()
    root.title("AHBU Ev Otomasyonu - Ek Modül Hazırlama Aracı")
    root.geometry("780x680")
    root.minsize(740, 620)

    # Arka plan iş parçacıkları Tk'ye doğrudan dokunmaz; işler bu kuyruktan ana döngüde yapılır.
    ui_queue = queue.Queue()

    def post(fn):
        ui_queue.put(fn)

    def pump_ui_queue():
        try:
            while True:
                ui_queue.get_nowait()()
        except queue.Empty:
            pass
        root.after(50, pump_ui_queue)

    # Başlık
    header = tk.Frame(root, bg="#1E293B", pady=12)
    header.pack(fill=tk.X)
    title_lbl = tk.Label(header, text="EK MODÜL HAZIRLAMA & FİRMWARE YÜKLEME", font=("Segoe UI", 14, "bold"), fg="#F8FAFC", bg="#1E293B")
    title_lbl.pack()
    sub_lbl = tk.Label(header, text="ESP32-WROOM-32U 8DI-8RO RS485 Modülü", font=("Segoe UI", 9), fg="#94A3B8", bg="#1E293B")
    sub_lbl.pack()

    main_frame = tk.Frame(root, padx=15, pady=10)
    main_frame.pack(fill=tk.BOTH, expand=True)

    # Seçim Alanı
    cfg_frame = tk.LabelFrame(main_frame, text=" 1. Cihaz ve Bağlantı Seçimi ", font=("Segoe UI", 10, "bold"), padx=10, pady=10)
    cfg_frame.pack(fill=tk.X, pady=5)

    # Port seçimi
    tk.Label(cfg_frame, text="COM Port (CH340):", font=("Segoe UI", 9)).grid(row=0, column=0, sticky="w", pady=4)
    port_combo = ttk.Combobox(cfg_frame, width=15, state="readonly")
    port_combo.grid(row=0, column=1, sticky="w", padx=5, pady=4)

    # İşlem Butonları
    act_frame = tk.LabelFrame(main_frame, text=" 2. İşlem Seçenekleri ", font=("Segoe UI", 10, "bold"), padx=10, pady=10)
    act_frame.pack(fill=tk.X, pady=5)

    # Log ekranı
    log_frame = tk.LabelFrame(main_frame, text=" İşlem Logları ", font=("Segoe UI", 10, "bold"), padx=5, pady=5)
    log_frame.pack(fill=tk.BOTH, expand=True, pady=5)
    log_text = scrolledtext.ScrolledText(log_frame, height=12, bg="#0F172A", fg="#38BDF8", font=("Consolas", 9))
    log_text.pack(fill=tk.BOTH, expand=True)

    def append_log(msg):
        log_text.insert(tk.END, msg + "\n")
        log_text.see(tk.END)

    def log(msg):
        """Her iş parçacığından güvenle çağrılabilir."""
        post(lambda: append_log(msg))

    def refresh_ports():
        ports = list(serial.tools.list_ports.comports())
        port_combo["values"] = [p.device for p in ports]
        if not ports:
            port_combo.set("")
            log("[PORT] Hiç COM port yok. Adaptör takılı mı, CH340 sürücüsü kurulu mu?")
            return
        choice = 0
        for i, p in enumerate(ports):
            label, known = describe_port(p)
            log(f"[PORT] {label}")
            if known and not describe_port(ports[choice])[1]:
                choice = i
        port_combo.current(choice)
        if not describe_port(ports[choice])[1]:
            log("[PORT] UYARI: Listede CH340/CP210x/FTDI çevirici yok. Seçili port kartın adaptörü olmayabilir;")
            log("[PORT]   adaptörü çıkarıp 'Yenile'ye basın, kaybolan port doğru porttur.")
    refresh_btn = tk.Button(cfg_frame, text="🔄 Yenile", command=refresh_ports, font=("Segoe UI", 8))
    refresh_btn.grid(row=0, column=2, sticky="w", pady=4)

    # Cihaz No seçimi
    tk.Label(cfg_frame, text="Cihaz No (Slave ID):", font=("Segoe UI", 9)).grid(row=0, column=3, sticky="e", padx=(20, 5), pady=4)
    dev_id_var = tk.StringVar(value="1")
    dev_id_spin = ttk.Spinbox(cfg_frame, from_=1, to=32, width=8, textvariable=dev_id_var)
    dev_id_spin.grid(row=0, column=4, sticky="w", pady=4)

    # Seri konsol: açıkken port bu araçta kilitli kalır; esptool'dan önce mutlaka kapatılır.
    console: dict = {"ser": None, "stop": None, "thread": None}

    def close_console():
        ser = console["ser"]
        if ser is None:
            return
        console["stop"].set()
        console["thread"].join(timeout=1)
        try:
            ser.close()
        except Exception:
            pass
        console.update(ser=None, stop=None, thread=None)
        log("[KONSOL] Seri port kapatıldı (esptool kullanabilsin diye).")

    def open_console(port):
        ser = serial.Serial(port, 115200, timeout=0.2)
        stop = threading.Event()

        def reader():
            while not stop.is_set():
                try:
                    raw = ser.readline()
                except Exception as e:
                    if not stop.is_set():
                        log(f"[KONSOL] Okuma hatası: {e}")
                    return
                text = raw.decode("utf-8", errors="replace").strip()
                if text:
                    log(f"[ESP32] {text}")

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        console.update(ser=ser, stop=stop, thread=t)
        log(f"[KONSOL] {port} 115200 baud ile açıldı; karttan gelen her satır burada görünür.")

    busy = {"on": False}

    def set_buttons(state):
        for b in (btn_test, btn_install, btn_scan):
            b.config(state=state)

    def run_job(job):
        """Seçili portu serbest bırakıp işi arka planda çalıştırır; hata olsa da butonlar geri açılır."""
        if busy["on"]:
            return
        port = port_combo.get()
        if not port:
            messagebox.showerror("Hata", "Lütfen bir COM port seçin! CH340 bağlı mı?")
            return
        close_console()
        busy["on"] = True
        set_buttons("disabled")

        def done():
            busy["on"] = False
            set_buttons("normal")

        def worker():
            try:
                job(port)
            except Exception as e:
                log(f"[HATA] Beklenmeyen hata: {e!r}")
            finally:
                post(done)

        threading.Thread(target=worker, daemon=True).start()

    # Buton 0: Bağlantı Testi
    def on_test_click():
        def job(port):
            log(f"\n==================================================")
            log(f">> BAĞLANTI TESTİ ({port})")
            log(f"==================================================")
            test_connection(port, log)
        run_job(job)

    # Buton 1: Cihaz Firmware Kur
    def on_install_click():
        try:
            cid = int(dev_id_var.get())
        except ValueError:
            messagebox.showerror("Hata", "Cihaz No bir sayı olmalı (1-32).")
            return

        def job(port):
            log(f"\n==================================================")
            log(f">> CİHAZ {cid} HAZIRLANIYOR...")
            log(f"==================================================")
            generate_config_h(device_id=cid, is_scanner=False)
            if build_firmware(log):
                flash_firmware(port, log)
        run_job(job)

    # Buton 2: Pin Keşif Firmware Kur
    def on_scan_click():
        def job(port):
            log(f"\n==================================================")
            log(f">> PIN KEŞİF / TEŞHİS FİRMWARE'İ HAZIRLANIYOR...")
            log(f"==================================================")
            generate_config_h(device_id=1, is_scanner=True)
            if build_firmware(log):
                if flash_firmware(port, log):
                    log("\n>> Pin Keşif Yazılımı kuruldu! Kartı resetledikten sonra aşağıya SCAN yazıp Gönder'e basın.")
        run_job(job)

    btn_test = tk.Button(act_frame, text="🔌 Bağlantıyı Test Et", bg="#475569", fg="white", font=("Segoe UI", 10, "bold"), padx=10, pady=6, command=on_test_click)
    btn_test.pack(side=tk.LEFT, padx=5)

    btn_install = tk.Button(act_frame, text="⚡ Cihaz Firmware'ini Hazırla ve Kur", bg="#16A34A", fg="white", font=("Segoe UI", 10, "bold"), padx=10, pady=6, command=on_install_click)
    btn_install.pack(side=tk.LEFT, padx=5)

    btn_scan = tk.Button(act_frame, text="🔍 Pin Keşif & Teşhis Yazılımını Kur", bg="#2563EB", fg="white", font=("Segoe UI", 10, "bold"), padx=10, pady=6, command=on_scan_click)
    btn_scan.pack(side=tk.LEFT, padx=5)

    # Seri Konsol Girişi (Test komutları göndermek için)
    cmd_frame = tk.Frame(main_frame, pady=5)
    cmd_frame.pack(fill=tk.X)
    tk.Label(cmd_frame, text="Seri Komut:", font=("Segoe UI", 9, "bold")).pack(side=tk.LEFT, padx=(0, 5))
    cmd_entry = tk.Entry(cmd_frame, font=("Segoe UI", 9))
    cmd_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=5)

    def send_cmd():
        cmd = cmd_entry.get().strip()
        port = port_combo.get()
        if not cmd or not port:
            return
        if busy["on"]:
            log("[KONSOL] Yükleme sürerken komut gönderilemez.")
            return
        try:
            ser = console["ser"]
            if ser is not None and (ser.port != port or not console["thread"].is_alive()):
                close_console()
                ser = None
            if ser is None:
                open_console(port)
                ser = console["ser"]
            ser.write((cmd + "\n").encode())
            log(f"[GÖNDERİLDİ] -> {cmd}")
            cmd_entry.delete(0, tk.END)
        except Exception as e:
            log(f"[HATA] Seri port hatası: {e}")

    send_btn = tk.Button(cmd_frame, text="Gönder", command=send_cmd, font=("Segoe UI", 9), padx=10)
    send_btn.pack(side=tk.LEFT)
    cmd_entry.bind("<Return>", lambda e: send_cmd())

    def on_close():
        close_console()
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", on_close)

    log(">> Ek Modül Hazırlama Aracı Hazır.")
    log(">> CH340 adaptörünüzü USB'ye takıp 'Yenile'ye basın.")
    log(">> Önce '🔌 Bağlantıyı Test Et' ile kartın cevap verdiğini görün, sonra 'Cihaz Firmware'ini Hazırla ve Kur'a basın.\n")
    refresh_ports()

    pump_ui_queue()
    root.mainloop()

# =============================================================================
# CLI MODU
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="Ek Modül Hazırlama ve Firmware Kurma Aracı")
    parser.add_argument("--cihaz", type=int, default=1, help="Cihaz Slave ID (Varsayılan: 1)")
    parser.add_argument("--mod", choices=["kur", "scan", "test", "gui"], default="gui", help="Çalışma modu")
    parser.add_argument("--port", type=str, default=None, help="COM Port (örn: COM3)")
    args = parser.parse_args()

    if args.mod == "gui":
        start_gui()
        return

    port = args.port
    if not port:
        ports = list(serial.tools.list_ports.comports())
        if not ports:
            print("[HATA] Bilgisayara bağlı hiçbir COM port bulunamadı! CH340 takılı mı?")
            return
        for p in ports:
            print(f"[PORT] {describe_port(p)[0]}")
        known = [p for p in ports if describe_port(p)[1]]
        port = (known or ports)[0].device
        print(f"[*] Port belirtilmedi, seçilen port: {port}")

    ok = False
    if args.mod == "test":
        ok = test_connection(port)
    elif args.mod == "scan":
        print(f"[*] Pin Keşif Firmware'i Cihaz 1 için hazırlanıyor...")
        generate_config_h(device_id=1, is_scanner=True)
        ok = build_firmware() and flash_firmware(port)
    elif args.mod == "kur":
        print(f"[*] Cihaz {args.cihaz} için RS485 Modbus Slave Firmware'i hazırlanıyor...")
        generate_config_h(device_id=args.cihaz, is_scanner=False)
        ok = build_firmware() and flash_firmware(port)
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
