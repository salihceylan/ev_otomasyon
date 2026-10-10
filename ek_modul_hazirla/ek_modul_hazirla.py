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
=============================================================================
"""

import os
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

def find_pio_executable():
    """PlatformIO çalıştırılabilir dosyasının tam yolunu bulur."""
    import shutil
    # 1. PATH kontrolü
    p = shutil.which("pio")
    if p and os.path.exists(p):
        return p
    # 2. Standart PlatformIO penv dizini
    user_home = os.path.expanduser("~")
    candidates = [
        os.path.join(user_home, ".platformio", "penv", "Scripts", "pio.exe"),
        os.path.join(user_home, ".platformio", "penv", "Scripts", "pio.cmd"),
        os.path.join(user_home, ".platformio", "penv", "bin", "pio")
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return "pio"

def build_firmware(log_cb=print):
    """PlatformIO ile firmware'i derler."""
    pio_cmd = find_pio_executable()
    log_cb(f"[1/3] Firmware derleniyor ({pio_cmd})...")
    try:
        cmd = [pio_cmd, "run", "-d", FIRMWARE_DIR]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
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

def flash_firmware(port, log_cb=print):
    """esptool ile derlenen firmware'i CH340 üzerinden ESP32'ye flaşlar."""
    bin_path = os.path.join(FIRMWARE_DIR, ".pio", "build", "esp32_ek_modul", "firmware.bin")
    boot_path = os.path.join(FIRMWARE_DIR, ".pio", "build", "esp32_ek_modul", "bootloader.bin")
    part_path = os.path.join(FIRMWARE_DIR, ".pio", "build", "esp32_ek_modul", "partitions.bin")

    if not os.path.exists(bin_path):
        log_cb(f"[HATA] Firmware dosyası bulunamadı: {bin_path}")
        return False

    log_cb(f"[3/3] ESP32'ye flaşlanıyor (Port: {port})...")
    cmd = [
        sys.executable, "-m", "esptool",
        "--chip", "esp32",
        "--port", port,
        "--baud", "460800",
        "--before", "default_reset",
        "--after", "hard_reset",
        "write_flash", "-z",
        "--flash_mode", "dio",
        "--flash_freq", "40m",
        "--flash_size", "detect",
        "0x1000", boot_path,
        "0x8000", part_path,
        "0x10000", bin_path
    ]

    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
    for line in iter(p.stdout.readline, ""):
        line_s = line.strip()
        if "Writing at" in line_s or "Hash of data" in line_s or "Leaving..." in line_s:
            log_cb(f"  > {line_s}")
    p.stdout.close()
    p.wait()

    if p.returncode == 0:
        log_cb("==================================================")
        log_cb(">> FIRMWARE BAŞARIYLA YÜKLENDİ! <<")
        log_cb("==================================================")
        return True
    else:
        log_cb("[HATA] Flaşlama başarısız oldu! BOOT butonuna basılı tutarak tekrar deneyin.")
        return False

def list_serial_ports():
    ports = []
    for p in serial.tools.list_ports.comports():
        ports.append(p.device)
    return ports

# =============================================================================
# GUI ARAYÜZÜ (Tkinter)
# =============================================================================
def start_gui():
    import tkinter as tk
    from tkinter import ttk, messagebox, scrolledtext

    root = tk.Tk()
    root.title("AHBU Ev Otomasyonu - Ek Modül Hazırlama Aracı")
    root.geometry("740x650")
    root.minsize(700, 600)

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

    def refresh_ports():
        ports = list_serial_ports()
        port_combo["values"] = ports
        if ports:
            port_combo.current(0)
    refresh_btn = tk.Button(cfg_frame, text="🔄 Yenile", command=refresh_ports, font=("Segoe UI", 8))
    refresh_btn.grid(row=0, column=2, sticky="w", pady=4)
    refresh_ports()

    # Cihaz No seçimi
    tk.Label(cfg_frame, text="Cihaz No (Slave ID):", font=("Segoe UI", 9)).grid(row=0, column=3, sticky="e", padx=(20, 5), pady=4)
    dev_id_var = tk.StringVar(value="1")
    dev_id_spin = ttk.Spinbox(cfg_frame, from_=1, to=32, width=8, textvariable=dev_id_var)
    dev_id_spin.grid(row=0, column=4, sticky="w", pady=4)

    # İşlem Butonları
    act_frame = tk.LabelFrame(main_frame, text=" 2. İşlem Seçenekleri ", font=("Segoe UI", 10, "bold"), padx=10, pady=10)
    act_frame.pack(fill=tk.X, pady=5)

    # Log ekranı
    log_frame = tk.LabelFrame(main_frame, text=" İşlem Logları ", font=("Segoe UI", 10, "bold"), padx=5, pady=5)
    log_frame.pack(fill=tk.BOTH, expand=True, pady=5)
    log_text = scrolledtext.ScrolledText(log_frame, height=12, bg="#0F172A", fg="#38BDF8", font=("Consolas", 9))
    log_text.pack(fill=tk.BOTH, expand=True)

    def log(msg):
        log_text.insert(tk.END, msg + "\n")
        log_text.see(tk.END)
        root.update_idletasks()

    def run_async(target_func):
        t = threading.Thread(target=target_func, daemon=True)
        t.start()

    # Buton 1: Cihaz Firmware Kur
    def on_install_click():
        port = port_combo.get()
        if not port:
            messagebox.showerror("Hata", "Lütfen bir COM port seçin! CH340 bağlı mı?")
            return
        cid = int(dev_id_var.get())
        btn_install.config(state="disabled")
        btn_scan.config(state="disabled")

        def worker():
            log(f"\n==================================================")
            log(f">> CİHAZ {cid} HAZIRLANIYOR...")
            log(f"==================================================")
            generate_config_h(device_id=cid, is_scanner=False)
            if build_firmware(log):
                flash_firmware(port, log)
            btn_install.config(state="normal")
            btn_scan.config(state="normal")

        run_async(worker)

    # Buton 2: Pin Keşif Firmware Kur
    def on_scan_click():
        port = port_combo.get()
        if not port:
            messagebox.showerror("Hata", "Lütfen bir COM port seçin! CH340 bağlı mı?")
            return
        btn_install.config(state="disabled")
        btn_scan.config(state="disabled")

        def worker():
            log(f"\n==================================================")
            log(f">> PIN KEŞİF / TEŞHİS FİRMWARE'İ HAZIRLANIYOR...")
            log(f"==================================================")
            generate_config_h(device_id=1, is_scanner=True)
            if build_firmware(log):
                if flash_firmware(port, log):
                    log("\n>> Pin Keşif Yazılımı kuruldu! Şimdi konsoldan pinleri bulabilirsiniz.")
            btn_install.config(state="normal")
            btn_scan.config(state="normal")

        run_async(worker)

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

    serial_conn = None

    def send_cmd():
        nonlocal serial_conn
        cmd = cmd_entry.get().strip()
        if not cmd:
            return
        port = port_combo.get()
        if not port:
            return
        try:
            if serial_conn is None or not serial_conn.is_open:
                serial_conn = serial.Serial(port, 115200, timeout=1)
            serial_conn.write((cmd + "\n").encode())
            log(f"[GÖNDERİLDİ] -> {cmd}")
            cmd_entry.delete(0, tk.END)
            time.sleep(0.1)
            while serial_conn.in_waiting:
                resp = serial_conn.readline().decode("utf-8", errors="replace").strip()
                if resp:
                    log(f"[ESP32] {resp}")
        except Exception as e:
            log(f"[HATA] Seri port hatası: {e}")

    send_btn = tk.Button(cmd_frame, text="Gönder", command=send_cmd, font=("Segoe UI", 9), padx=10)
    send_btn.pack(side=tk.LEFT)
    cmd_entry.bind("<Return>", lambda e: send_cmd())

    log(">> Ek Modül Hazırlama Aracı Hazır.")
    log(">> CH340 adaptörünüzü USB'ye takıp 'Yenile'ye basın.")
    log(">> 'Cihaz Firmware'ini Hazırla ve Kur' butonuna bastığınızda seçili cihazın RS485 yazılımı doğrudan kurulur.\n")

    root.mainloop()

# =============================================================================
# CLI MODU
# =============================================================================
def main():
    parser = argparse.ArgumentParser(description="Ek Modül Hazırlama ve Firmware Kurma Aracı")
    parser.add_argument("--cihaz", type=int, default=1, help="Cihaz Slave ID (Varsayılan: 1)")
    parser.add_argument("--mod", choices=["kur", "scan", "gui"], default="gui", help="Çalışma modu")
    parser.add_argument("--port", type=str, default=None, help="COM Port (örn: COM3)")
    args = parser.parse_args()

    if args.mod == "gui":
        start_gui()
        return

    port = args.port
    if not port:
        ports = list_serial_ports()
        if not ports:
            print("[HATA] Bilgisayara bağlı hiçbir COM port bulunamadı! CH340 takılı mı?")
            return
        port = ports[0]
        print(f"[*] Port belirtilmedi, ilk port seçildi: {port}")

    if args.mod == "scan":
        print(f"[*] Pin Keşif Firmware'i Cihaz 1 için hazırlanıyor...")
        generate_config_h(device_id=1, is_scanner=True)
        if build_firmware():
            flash_firmware(port)
    elif args.mod == "kur":
        print(f"[*] Cihaz {args.cihaz} için RS485 Modbus Slave Firmware'i hazırlanıyor...")
        generate_config_h(device_id=args.cihaz, is_scanner=False)
        if build_firmware():
            flash_firmware(port)

if __name__ == "__main__":
    main()

