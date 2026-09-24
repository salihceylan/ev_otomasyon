"""
AHBU Ev Otomasyon Sistemi - Servis ve Üretim Aracı
1. Firmware Yükleyici (Waveshare ESP32-S3 Flasher)
2. Karekod Üret & Etiket Bas (Cihaz Envanter ve Etiketleme Sistemi)
"""

import os
import sys
import json
import re
import random
import shutil
import subprocess
import threading
import urllib.request
import urllib.error
from datetime import datetime
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import serial.tools.list_ports

import qrcode
from PIL import Image, ImageDraw, ImageFont, ImageTk

# Temel dizinler ve sabit donanım parametreleri
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEMO_DIR = os.path.join(BASE_DIR, "waveshare_s3_demo")
FACTORY_BIN = os.path.join(DEMO_DIR, "Firmware", "ESP32-S3-POE-ETH-8DI-8RO.bin")
RELEASES_DIR = os.path.join(DEMO_DIR, "firmware_releases")
VERSION_FILE = os.path.join(RELEASES_DIR, "version_info.json")
LABELS_DIR = os.path.join(BASE_DIR, "labels")
LOGO_PATH = os.path.join(BASE_DIR, "..", "assets", "images", "round_app_logo.png")

# Bulut API Ayarları
API_INVENTORY_URL = "https://evotomasyon.gudeteknoloji.com.tr/api/v1/admin/inventory"
ADMIN_API_KEY = "GudeAdminInventoryKey2026_SecretProvisioning"

# Cihazın sabit donanım ayarları
DEFAULT_CHIP = "esp32s3"
DEFAULT_BAUD = "460800"


def find_esptool():
    """PlatformIO veya sistemdeki esptool.py yolunu bulur."""
    candidates = [
        r"G:\.platformio\packages\tool-esptoolpy\esptool.py",
        os.path.expanduser(r"~/.platformio/packages/tool-esptoolpy/esptool.py"),
        os.path.join(os.environ.get("USERPROFILE", ""), ".platformio", "packages", "tool-esptoolpy", "esptool.py"),
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    which_esptool = shutil.which("esptool.py") or shutil.which("esptool")
    if which_esptool:
        return which_esptool
    return "esptool.py"


def load_version_info():
    """Geliştirilen yazılımın versiyon bilgisini okur."""
    if os.path.exists(VERSION_FILE):
        try:
            with open(VERSION_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {
        "current_version": "1.0.0",
        "firmware_file": "v1.0.0/firmware_v1.0.0.bin",
        "updated_at": datetime.now().isoformat()
    }


def save_version_info(data):
    """Versiyon bilgisini kaydeder."""
    os.makedirs(RELEASES_DIR, exist_ok=True)
    with open(VERSION_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def increment_version_str(ver_str):
    """1.0.0 -> 1.0.1 şeklinde versiyonu artırır."""
    parts = ver_str.split(".")
    if len(parts) == 3:
        try:
            major, minor, patch = int(parts[0]), int(parts[1]), int(parts[2])
            patch += 1
            return f"{major}.{minor}.{patch}"
        except ValueError:
            pass
    return f"{ver_str}.1"


def format_serial_badge(serial_val):
    """Sıra numarasını güvenli şekilde 4 haneli badge formatına (#0001) dönüştürür."""
    if serial_val is None or str(serial_val).strip() == "":
        return "#0001"
    try:
        clean = str(serial_val).replace("#", "").strip()
        return f"#{int(clean):04d}"
    except Exception:
        clean_str = str(serial_val).strip()
        return f"#{clean_str}" if not clean_str.startswith("#") else clean_str


class ServerPasswordDialog(tk.Toplevel):
    """Cihaz kaydı ve hassas envanter işlemleri için sunucu şifresi soran modal diyalog."""
    def __init__(self, parent, title="🔐 Sunucu Yönetici Doğrulaması", prompt="Cihazı sunucu envanterine kaydetmek için lütfen Sunucu Şifresini giriniz:"):
        super().__init__(parent)
        self.title(title)
        self.transient(parent)
        self.resizable(False, False)
        self.configure(bg="#ffffff", padx=20, pady=16)

        self.result = None
        self.remember_session = tk.BooleanVar(value=True)

        # Başlık ve Açıklama
        hdr_frame = tk.Frame(self, bg="#ffffff")
        hdr_frame.pack(fill=tk.X, pady=(0, 10))

        tk.Label(
            hdr_frame,
            text="🔐 Sunucu Güvenlik Doğrulaması",
            font=("Segoe UI", 12, "bold"),
            fg="#0f172a",
            bg="#ffffff"
        ).pack(anchor="w")

        tk.Label(
            hdr_frame,
            text=prompt,
            font=("Segoe UI", 9),
            fg="#475569",
            bg="#ffffff",
            wraplength=380,
            justify="left"
        ).pack(anchor="w", pady=(4, 0))

        # Şifre Giriş Alanı
        entry_frame = tk.Frame(self, bg="#ffffff")
        entry_frame.pack(fill=tk.X, pady=8)

        self.pwd_entry = tk.Entry(entry_frame, show="•", font=("Segoe UI", 11), width=28)
        self.pwd_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 6))

        # Şifreyi Göster / Gizle Butonu
        self.show_pwd = False
        self.toggle_btn = tk.Button(
            entry_frame,
            text="👁️",
            width=3,
            command=self._toggle_pwd,
            font=("Segoe UI", 9),
            relief="groove",
            cursor="hand2"
        )
        self.toggle_btn.pack(side=tk.RIGHT)

        # Bu oturum boyunca hatırla seçeneği
        chk = tk.Checkbutton(
            self,
            text="Bu oturum boyunca hatırla (Her cihazda tekrar sorma)",
            variable=self.remember_session,
            font=("Segoe UI", 8),
            bg="#ffffff",
            activebackground="#ffffff",
            fg="#1e293b"
        )
        chk.pack(anchor="w", pady=(2, 12))

        # Butonlar
        btn_box = tk.Frame(self, bg="#ffffff")
        btn_box.pack(fill=tk.X)

        btn_cancel = tk.Button(
            btn_box,
            text="İptal",
            width=10,
            command=self._on_cancel,
            font=("Segoe UI", 9),
            bg="#f1f5f9",
            relief="groove",
            cursor="hand2"
        )
        btn_cancel.pack(side=tk.RIGHT, padx=(6, 0))

        btn_ok = tk.Button(
            btn_box,
            text="✓ Doğrula ve Kaydet",
            command=self._on_ok,
            font=("Segoe UI", 9, "bold"),
            bg="#1565c0",
            fg="#ffffff",
            activebackground="#0d47a1",
            activeforeground="#ffffff",
            relief="groove",
            cursor="hand2",
            padx=10,
            pady=4
        )
        btn_ok.pack(side=tk.RIGHT)

        self.bind("<Return>", lambda e: self._on_ok())
        self.bind("<Escape>", lambda e: self._on_cancel())

        # Ortala ve odaklan
        self.update_idletasks()
        try:
            pw = parent.winfo_width()
            ph = parent.winfo_height()
            px = parent.winfo_rootx()
            py = parent.winfo_rooty()
            w = self.winfo_reqwidth()
            h = self.winfo_reqheight()
            self.geometry(f"+{px + max(0, (pw - w)//2)}+{py + max(0, (ph - h)//2)}")
        except Exception:
            pass

        self.pwd_entry.focus_set()
        self.grab_set()
        parent.wait_window(self)

    def _toggle_pwd(self):
        self.show_pwd = not self.show_pwd
        self.pwd_entry.config(show="" if self.show_pwd else "•")

    def _on_ok(self):
        val = self.pwd_entry.get().strip()
        if not val:
            messagebox.showwarning("Eksik Şifre", "Lütfen sunucu şifresini giriniz.", parent=self)
            return
        self.result = (val, self.remember_session.get())
        self.destroy()

    def _on_cancel(self):
        self.result = None
        self.destroy()


class EvOtomasyonServisApp(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title("AHBU - Ev Otomasyon Sistemi | Servis & Üretim Konsolu")
        self.geometry("980x760")
        self.minsize(900, 680)

        # Renk teması
        self.bg_color = "#f4f6f9"
        self.card_bg = "#ffffff"
        self.primary_color = "#0f172a"
        self.accent_blue = "#1565c0"
        self.accent_green = "#2e7d32"
        self.accent_orange = "#e65100"
        self.danger_color = "#c62828"
        self.text_color = "#1e293b"

        self.configure(bg=self.bg_color)
        self.is_flashing = False
        self.current_label_img = None
        self.current_label_path = None

        self.mode_var = tk.StringVar(value="custom")
        self.version_data = load_version_info()
        self.session_server_password = None

        # Dizinleri hazırla
        os.makedirs(LABELS_DIR, exist_ok=True)

        self._create_main_layout()
        self.refresh_ports()
        self.apply_mode_selection()

        # İlk açılışta envanteri listele
        self.after(500, self.refresh_inventory_list)

    def get_server_password(self, force_prompt=False, prompt="Cihazı sunucu envanterine kaydetmek için lütfen Sunucu Yönetici Şifresini giriniz:"):
        """Sunucu şifresini oturumdan alır veya kullanıcıya sorar."""
        if self.session_server_password and not force_prompt:
            return self.session_server_password

        dlg = ServerPasswordDialog(self, title="🔐 Sunucu Kimlik Doğrulama", prompt=prompt)
        if not dlg.result:
            return None

        pwd, remember = dlg.result
        if remember:
            self.session_server_password = pwd
        return pwd

    def clear_server_password(self):
        """Kayıtlı oturum şifresini sıfırlar."""
        self.session_server_password = None
        messagebox.showinfo("Şifre Sıfırlandı", "Oturum sunucu şifresi sıfırlandı. Yeni işlemde tekrar sorulacaktır.")

    def _create_main_layout(self):
        # 1. Üst Başlık Kartı
        header_frame = tk.Frame(self, bg=self.primary_color, padx=15, pady=10)
        header_frame.pack(fill=tk.X)

        title_row = tk.Frame(header_frame, bg=self.primary_color)
        title_row.pack(fill=tk.X)

        title_lbl = tk.Label(
            title_row,
            text="🏠 AHBU AKILLI EV SİSTEMLERİ",
            font=("Segoe UI", 14, "bold"),
            fg="#38bdf8",
            bg=self.primary_color
        )
        title_lbl.pack(side=tk.LEFT)

        sub_lbl = tk.Label(
            title_row,
            text="Üretim, Firmware Yükleme ve Cihaz Envanter Konsolu",
            font=("Segoe UI", 10),
            fg="#94a3b8",
            bg=self.primary_color,
            padx=10
        )
        sub_lbl.pack(side=tk.LEFT, pady=(3, 0))

        # 2. Sekmeli Arayüz (Notebook)
        style = ttk.Style()
        style.theme_use('default')
        style.configure('TNotebook', background=self.bg_color)
        style.configure('TNotebook.Tab', padding=[16, 8], font=('Segoe UI', 10, 'bold'))

        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

        # Sekme 1: Firmware Yükleyici (Flasher)
        self.tab_flasher = tk.Frame(self.notebook, bg=self.bg_color)
        self.notebook.add(self.tab_flasher, text="⚡ 1. Firmware Yükleyici (Flasher)")

        # Sekme 2: Karekod Üret & Etiket Bas (Envanter)
        self.tab_inventory = tk.Frame(self.notebook, bg=self.bg_color)
        self.notebook.add(self.tab_inventory, text="🏷️ 2. Karekod Üret & Etiket Bas (Envanter)")

        # Sekme içeriklerini oluştur
        self._build_flasher_tab()
        self._build_inventory_tab()

    # =========================================================================
    # SEKME 1: FİRMWARE YÜKLEYİCİ (FLASHER)
    # =========================================================================
    def _build_flasher_tab(self):
        content_frame = tk.Frame(self.tab_flasher, bg=self.bg_color, padx=10, pady=10)
        content_frame.pack(fill=tk.BOTH, expand=True)

        # Port ve Bağlantı Ayarları
        conn_frame = tk.LabelFrame(
            content_frame,
            text=" 🔌 Bağlantı ve Çip Ayarları ",
            font=("Segoe UI", 10, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=10,
            pady=8
        )
        conn_frame.pack(fill=tk.X, pady=(0, 10))

        tk.Label(conn_frame, text="COM Port:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=0, column=0, sticky="w", pady=4)
        self.port_combo = ttk.Combobox(conn_frame, width=32, state="readonly")
        self.port_combo.grid(row=0, column=1, padx=(5, 10), pady=4, sticky="w")

        refresh_btn = tk.Button(
            conn_frame,
            text="🔄 Portları Yenile",
            command=self.refresh_ports,
            font=("Segoe UI", 8),
            bg="#e0e0e0",
            relief="groove"
        )
        refresh_btn.grid(row=0, column=2, padx=5, pady=4)

        tk.Label(conn_frame, text="Hedef Donanım:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=1, column=0, sticky="w", pady=4)
        dev_info_lbl = tk.Label(
            conn_frame,
            text="Waveshare ESP32-S3 (8DI-8RO Pano Modülü) | 460.800 bps Yüksek Hız",
            font=("Segoe UI", 9),
            bg="#e8eaf6",
            fg="#1a237e",
            padx=8,
            pady=2,
            relief="groove"
        )
        dev_info_lbl.grid(row=1, column=1, columnspan=2, sticky="w", padx=(5, 0), pady=4)

        # Firmware Seçim Modu
        fw_frame = tk.LabelFrame(
            content_frame,
            text=" 📦 Yüklenecek Firmware Seçimi ",
            font=("Segoe UI", 10, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=10,
            pady=8
        )
        fw_frame.pack(fill=tk.X, pady=(0, 10))

        # Seçenek 1: Bizim Geliştirdiğimiz Yazılım
        r1_frame = tk.Frame(fw_frame, bg=self.card_bg)
        r1_frame.pack(fill=tk.X, pady=(2, 4))

        self.r_custom = tk.Radiobutton(
            r1_frame,
            text="🚀 Bizim Geliştirdiğimiz Yazılım (Otomatik Seçili)",
            variable=self.mode_var,
            value="custom",
            command=self.apply_mode_selection,
            font=("Segoe UI", 10, "bold"),
            fg="#0d47a1",
            bg=self.card_bg,
            activebackground=self.card_bg
        )
        self.r_custom.pack(side=tk.LEFT)

        self.inc_ver_btn = tk.Button(
            r1_frame,
            text="➕ Versiyon Arttır",
            command=self.inc_version,
            font=("Segoe UI", 8, "bold"),
            bg="#e8f5e9",
            fg="#2e7d32",
            relief="groove"
        )
        self.inc_ver_btn.pack(side=tk.RIGHT, padx=5)

        self.ver_label = tk.Label(
            r1_frame,
            text=f"Mevcut: v{self.version_data.get('current_version', '1.0.0')}",
            font=("Segoe UI", 9, "bold"),
            fg="#2e7d32",
            bg=self.card_bg
        )
        self.ver_label.pack(side=tk.RIGHT, padx=5)

        # Seçenek 2: Fabrika Firmware
        r2_frame = tk.Frame(fw_frame, bg=self.card_bg)
        r2_frame.pack(fill=tk.X, pady=(2, 6))

        self.r_factory = tk.Radiobutton(
            r2_frame,
            text="🛡️ Fabrika Çıkış Orijinal Yazılımı (Test / Kurtarma Modu)",
            variable=self.mode_var,
            value="factory",
            command=self.apply_mode_selection,
            font=("Segoe UI", 9),
            fg="#424242",
            bg=self.card_bg,
            activebackground=self.card_bg
        )
        self.r_factory.pack(side=tk.LEFT)

        # Dosya Yolu Seçim Çubuğu
        path_frame = tk.Frame(fw_frame, bg=self.card_bg)
        path_frame.pack(fill=tk.X, pady=(4, 2))

        tk.Label(path_frame, text="Dosya:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).pack(side=tk.LEFT, padx=(0, 5))
        self.file_entry = tk.Entry(path_frame, font=("Segoe UI", 9))
        self.file_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))

        self.browse_btn = tk.Button(
            path_frame,
            text="📁 Gözat...",
            command=self.browse_custom_file,
            font=("Segoe UI", 8),
            bg="#f5f5f5"
        )
        self.browse_btn.pack(side=tk.RIGHT)

        # İşlem Butonları Çubuğu
        btn_frame = tk.Frame(content_frame, bg=self.bg_color)
        btn_frame.pack(fill=tk.X, pady=(0, 10))

        self.btn_flash = tk.Button(
            btn_frame,
            text="⚡ FİRMWARE'İ KARTA YÜKLE (FLASH)",
            command=self.start_flash,
            font=("Segoe UI", 11, "bold"),
            bg=self.accent_blue,
            fg="#ffffff",
            activebackground="#0d47a1",
            activeforeground="#ffffff",
            pady=8,
            cursor="hand2"
        )
        self.btn_flash.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))

        self.btn_read_info = tk.Button(
            btn_frame,
            text="🔍 Çip Bilgisi Oku",
            command=self.start_read_info,
            font=("Segoe UI", 9, "bold"),
            bg="#cfd8dc",
            pady=8,
            cursor="hand2"
        )
        self.btn_read_info.pack(side=tk.LEFT, padx=5)

        self.btn_erase = tk.Button(
            btn_frame,
            text="🗑️ Hafızayı Sil (Erase Flash)",
            command=self.start_erase,
            font=("Segoe UI", 9, "bold"),
            bg="#ffcdd2",
            fg="#b71c1c",
            pady=8,
            cursor="hand2"
        )
        self.btn_erase.pack(side=tk.LEFT, padx=(5, 0))

        # Log & İlerleme Konsolu
        log_frame = tk.LabelFrame(
            content_frame,
            text=" 📋 İşlem Log Çıktısı ",
            font=("Segoe UI", 9, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=8,
            pady=6
        )
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(
            log_frame,
            wrap=tk.WORD,
            font=("Consolas", 9),
            bg="#1e1e1e",
            fg="#00e676",
            insertbackground="#ffffff"
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scrollbar = tk.Scrollbar(log_frame, command=self.log_text.yview)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.config(yscrollcommand=scrollbar.set)

    # =========================================================================
    # SEKME 2: KAREKOD ÜRET & ETİKET BAS (CİHAZ ENVANTERİ)
    # =========================================================================
    def _build_inventory_tab(self):
        inv_content = tk.Frame(self.tab_inventory, bg=self.bg_color, padx=10, pady=8)
        inv_content.pack(fill=tk.BOTH, expand=True)

        # Üst Kısım: Sol Form + Sağ Önizleme (PanedWindow veya 2 Frame)
        top_split = tk.Frame(inv_content, bg=self.bg_color)
        top_split.pack(fill=tk.X, pady=(0, 8))

        # SOL: Üretim ve Kayıt Formu
        form_frame = tk.LabelFrame(
            top_split,
            text=" ⚙️ Cihaz Tanımlama & Otomatik Kimlik Üretimi ",
            font=("Segoe UI", 10, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=12,
            pady=10
        )
        form_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 6))

        # 1. Satır: Port ve MAC Okuma
        tk.Label(form_frame, text="1. Donanım MAC:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=0, column=0, sticky="w", pady=4)
        
        mac_row = tk.Frame(form_frame, bg=self.card_bg)
        mac_row.grid(row=0, column=1, sticky="ew", pady=4)

        self.inv_mac_entry = tk.Entry(mac_row, width=20, font=("Consolas", 10, "bold"), fg="#0d47a1")
        self.inv_mac_entry.pack(side=tk.LEFT, padx=(0, 6))

        self.btn_read_mac = tk.Button(
            mac_row,
            text="📡 Karttan MAC Oku",
            command=self.read_mac_from_board,
            font=("Segoe UI", 8, "bold"),
            bg="#e3f2fd",
            fg="#0d47a1",
            relief="groove",
            cursor="hand2"
        )
        self.btn_read_mac.pack(side=tk.LEFT)

        # 2. Satır: Cihaz UUID
        tk.Label(form_frame, text="2. Cihaz Seri No (UUID):", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=1, column=0, sticky="w", pady=4)
        
        uuid_row = tk.Frame(form_frame, bg=self.card_bg)
        uuid_row.grid(row=1, column=1, sticky="ew", pady=4)

        self.inv_uuid_entry = tk.Entry(uuid_row, width=24, font=("Consolas", 10, "bold"), fg="#1565c0")
        self.inv_uuid_entry.pack(side=tk.LEFT, padx=(0, 6))

        btn_gen_uuid = tk.Button(
            uuid_row,
            text="🔄 UUID Üret",
            command=self.generate_device_uuid,
            font=("Segoe UI", 8),
            bg="#f5f5f5",
            relief="groove"
        )
        btn_gen_uuid.pack(side=tk.LEFT)

        # 3. Satır: Kurulum PIN (6 Haneli)
        tk.Label(form_frame, text="3. Kurulum PIN (6 Hane):", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=2, column=0, sticky="w", pady=4)
        
        pin_row = tk.Frame(form_frame, bg=self.card_bg)
        pin_row.grid(row=2, column=1, sticky="ew", pady=4)

        self.inv_pin_entry = tk.Entry(pin_row, width=12, font=("Consolas", 11, "bold"), fg="#b71c1c")
        self.inv_pin_entry.pack(side=tk.LEFT, padx=(0, 6))

        btn_gen_pin = tk.Button(
            pin_row,
            text="🎲 Rastgele PIN Üret",
            command=self.generate_random_pin,
            font=("Segoe UI", 8),
            bg="#f5f5f5",
            relief="groove"
        )
        btn_gen_pin.pack(side=tk.LEFT)

        # 4. Satır: Model ve Parti
        tk.Label(form_frame, text="4. Donanım Modeli:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=3, column=0, sticky="w", pady=4)
        self.inv_model_entry = tk.Entry(form_frame, width=28, font=("Segoe UI", 9))
        self.inv_model_entry.insert(0, "ESP32-S3-POE-ETH-8DI-8RO")
        self.inv_model_entry.grid(row=3, column=1, sticky="w", pady=4)

        tk.Label(form_frame, text="5. Üretim Partisi:", font=("Segoe UI", 9, "bold"), bg=self.card_bg).grid(row=4, column=0, sticky="w", pady=4)
        self.inv_batch_entry = tk.Entry(form_frame, width=28, font=("Segoe UI", 9))
        current_batch = datetime.now().strftime("BATCH-%Y-%m")
        self.inv_batch_entry.insert(0, current_batch)
        self.inv_batch_entry.grid(row=4, column=1, sticky="w", pady=4)

        # Bilgilendirme / Garanti Rozeti
        dup_info = tk.Label(
            form_frame,
            text="🛡️ Sıfır-Mükerrerlik Garantisi: Aynı MAC veya UUID sunucuya 2. kez eklenemez!",
            font=("Segoe UI", 8, "italic"),
            fg="#2e7d32",
            bg=self.card_bg
        )
        dup_info.grid(row=5, column=0, columnspan=2, sticky="w", pady=(6, 8))

        # Ana Aksiyon Butonu: Sunucuya Kaydet & Karekod Bas
        self.btn_register_device = tk.Button(
            form_frame,
            text="☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET",
            command=self.register_device_and_generate_label,
            font=("Segoe UI", 10, "bold"),
            bg=self.accent_green,
            fg="#ffffff",
            activebackground="#1b5e20",
            activeforeground="#ffffff",
            pady=8,
            cursor="hand2"
        )
        self.btn_register_device.grid(row=6, column=0, columnspan=2, sticky="ew", pady=(2, 0))

        # SAĞ: Termal Etiket & Karekod Önizleme
        preview_frame = tk.LabelFrame(
            top_split,
            text=" 🖨️ Termal Etiket & Karekod Önizleme ",
            font=("Segoe UI", 10, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=12,
            pady=10
        )
        preview_frame.pack(side=tk.RIGHT, fill=tk.BOTH, expand=False, padx=(6, 0))

        self.label_canvas_img = tk.Label(
            preview_frame,
            text="Henüz etiket üretilmedi.\nSoldaki formdan 'Karekod Üret' butonuna basın.",
            font=("Segoe UI", 9),
            bg="#f8fafc",
            fg="#64748b",
            width=50,
            height=12,
            relief="groove"
        )
        self.label_canvas_img.pack(pady=(0, 8))

        btn_label_row = tk.Frame(preview_frame, bg=self.card_bg)
        btn_label_row.pack(fill=tk.X)

        self.btn_save_label = tk.Button(
            btn_label_row,
            text="💾 Etiketi Kaydet (PNG)",
            command=self.save_label_file,
            font=("Segoe UI", 8, "bold"),
            bg="#e2e8f0",
            state=tk.DISABLED
        )
        self.btn_save_label.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 4))

        self.btn_print_label = tk.Button(
            btn_label_row,
            text="🖨️ Yazdır (Barkod / Termal)",
            command=self.print_label_file,
            font=("Segoe UI", 8, "bold"),
            bg="#e0f2fe",
            fg="#0284c7",
            state=tk.DISABLED
        )
        self.btn_print_label.pack(side=tk.RIGHT, fill=tk.X, expand=True, padx=(4, 0))

        # ALT KISIM: Canlı Sunucu Envanter Tablosu & Yönetim (Süper Kullanıcı)
        table_frame = tk.LabelFrame(
            inv_content,
            text=" 📊 Sunucu Cihaz Envanteri & Durum Yönetimi (Süper Yönetici) ",
            font=("Segoe UI", 10, "bold"),
            bg=self.card_bg,
            fg=self.text_color,
            padx=10,
            pady=6
        )
        table_frame.pack(fill=tk.BOTH, expand=True)

        # Tablo Butonları Çubuğu
        table_action_row = tk.Frame(table_frame, bg=self.card_bg)
        table_action_row.pack(fill=tk.X, pady=(0, 6))

        tk.Button(
            table_action_row,
            text="🔄 Listeyi Yenile",
            command=self.refresh_inventory_list,
            font=("Segoe UI", 8, "bold"),
            bg="#e2e8f0"
        ).pack(side=tk.LEFT, padx=(0, 6))

        tk.Button(
            table_action_row,
            text="🔑 Şifreyi Sıfırla",
            command=self.clear_server_password,
            font=("Segoe UI", 8),
            bg="#f1f5f9"
        ).pack(side=tk.LEFT, padx=(0, 6))

        self.btn_suspend = tk.Button(
            table_action_row,
            text="⏸️ Askıya Al (Kilit)",
            command=self.suspend_selected_device,
            font=("Segoe UI", 8, "bold"),
            bg="#fff3e0",
            fg="#e65100"
        )
        self.btn_suspend.pack(side=tk.LEFT, padx=4)

        self.btn_activate = tk.Button(
            table_action_row,
            text="▶️ Aktif Et (Stok)",
            command=self.activate_selected_device,
            font=("Segoe UI", 8, "bold"),
            bg="#e8f5e9",
            fg="#2e7d32"
        )
        self.btn_activate.pack(side=tk.LEFT, padx=4)

        self.btn_delete_device = tk.Button(
            table_action_row,
            text="🗑️ Envanterden Sil",
            command=self.delete_selected_device,
            font=("Segoe UI", 8, "bold"),
            bg="#ffebee",
            fg="#c62828"
        )
        self.btn_delete_device.pack(side=tk.LEFT, padx=4)

        self.btn_show_selected_label = tk.Button(
            table_action_row,
            text="🏷️ Seçilenin Etiketini Göster",
            command=self.render_selected_device_label,
            font=("Segoe UI", 8, "bold"),
            bg="#e0f2fe",
            fg="#0369a1"
        )
        self.btn_show_selected_label.pack(side=tk.RIGHT)

        # Tablo (Treeview)
        columns = ("serial_no", "device_uuid", "mac_address", "model", "status", "created_at", "claimed_at")
        self.inv_tree = ttk.Treeview(table_frame, columns=columns, show="headings", height=7, selectmode="browse")

        self.inv_tree.heading("serial_no", text="Sıra No")
        self.inv_tree.heading("device_uuid", text="Cihaz UUID (Seri No)")
        self.inv_tree.heading("mac_address", text="MAC Adresi")
        self.inv_tree.heading("model", text="Model")
        self.inv_tree.heading("status", text="Durum")
        self.inv_tree.heading("created_at", text="Kayıt Tarihi")
        self.inv_tree.heading("claimed_at", text="Daire Eşleme Tarihi")

        self.inv_tree.column("serial_no", width=65, anchor="center")
        self.inv_tree.column("device_uuid", width=170, anchor="w")
        self.inv_tree.column("mac_address", width=140, anchor="center")
        self.inv_tree.column("model", width=180, anchor="w")
        self.inv_tree.column("status", width=95, anchor="center")
        self.inv_tree.column("created_at", width=130, anchor="center")
        self.inv_tree.column("claimed_at", width=130, anchor="center")

        tree_scroll = ttk.Scrollbar(table_frame, orient="vertical", command=self.inv_tree.yview)
        self.inv_tree.configure(yscrollcommand=tree_scroll.set)

        self.inv_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        tree_scroll.pack(side=tk.RIGHT, fill=tk.Y)

        self.inv_tree.bind("<<TreeviewSelect>>", self.on_tree_select)

        # Başlangıçta rastgele bir PIN üret
        self.generate_random_pin()

    # =========================================================================
    # KAREKOD & ENVANTER İŞ MANTIĞI METOTLARI
    # =========================================================================
    def generate_random_pin(self):
        """6 basamaklı rastgele güvenli Kurulum PIN'i üretir."""
        pin = f"{random.randint(100000, 999999)}"
        self.inv_pin_entry.delete(0, tk.END)
        self.inv_pin_entry.insert(0, pin)

    def generate_device_uuid(self):
        """MAC adresi varsa ondan, yoksa rastgele benzersiz UUID üretir."""
        mac = self.inv_mac_entry.get().strip().replace(":", "").replace("-", "").upper()
        if len(mac) >= 6:
            suffix = mac[-6:]
        else:
            suffix = f"{random.randint(100000, 999999):06X}"
        uuid = f"AHBU-S3-{suffix}"
        self.inv_uuid_entry.delete(0, tk.END)
        self.inv_uuid_entry.insert(0, uuid)

    def read_mac_from_board(self):
        """COM port üzerinden bağlı ESP32-S3 çipinden MAC adresini okur."""
        port = self.get_selected_port()
        if not port:
            messagebox.showwarning("Port Seçilmedi", "Lütfen önce üstteki 'COM Port' açılır kutusundan kartınızın takılı olduğu portu seçin!")
            return

        self.btn_read_mac.config(state=tk.DISABLED, text="⏳ Okunuyor...")

        def _worker():
            try:
                cmd = self.build_esptool_cmd([
                    "--chip", DEFAULT_CHIP,
                    "--port", port,
                    "read_mac"
                ])
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                )
                output, _ = process.communicate(timeout=15)

                # MAC Regex: MAC: e8:f6:0a:dd:87:54
                match = re.search(r"MAC:\s*([0-9a-fA-F:]{17})", output)
                if match:
                    mac = match.group(1).upper()
                    self.after(0, lambda: self._on_mac_read_success(mac))
                else:
                    self.after(0, lambda: messagebox.showerror("MAC Okunamadı", f"Çipten MAC adresi okunamadı.\nesptool çıktısı:\n{output[-300:]}"))
            except Exception as e:
                self.after(0, lambda: messagebox.showerror("Hata", f"Bağlantı hatası: {str(e)}"))
            finally:
                self.after(0, lambda: self.btn_read_mac.config(state=tk.NORMAL, text="📡 Karttan MAC Oku"))

        threading.Thread(target=_worker, daemon=True).start()

    def _on_mac_read_success(self, mac):
        self.inv_mac_entry.delete(0, tk.END)
        self.inv_mac_entry.insert(0, mac)
        self.generate_device_uuid()
        messagebox.showinfo("MAC Okundu", f"Bağlı kartın fabrikasyon MAC adresi başarıyla tespit edildi:\n{mac}")

    def register_device_and_generate_label(self):
        """Cihazı sunucu envanterine kaydeder ve termal etiket oluşturur."""
        mac = self.inv_mac_entry.get().strip().upper()
        uuid = self.inv_uuid_entry.get().strip().upper()
        pin = self.inv_pin_entry.get().strip()
        model = self.inv_model_entry.get().strip()
        batch_no = self.inv_batch_entry.get().strip()

        if not mac or len(mac) < 12:
            messagebox.showwarning("Eksik Bilgi", "Lütfen geçerli bir MAC adresi girin veya 'Karttan MAC Oku' butonunu kullanın.")
            return

        if not uuid:
            messagebox.showwarning("Eksik Bilgi", "Lütfen Cihaz Seri No (UUID) belirleyin.")
            return

        if not pin or len(pin) != 6 or not pin.isdigit():
            messagebox.showwarning("Geçersiz PIN", "Kurulum PIN kodu tam olarak 6 haneli rakamlardan oluşmalıdır.")
            return

        # Sunucu şifresini sor (oturumda varsa kullanır, yoksa modal açar)
        server_pwd = self.get_server_password(
            prompt="Cihazı resmi sunucu envanterine kaydetmek ve karekod üretmek için lütfen Sunucu Yönetici Şifresini giriniz:"
        )
        if not server_pwd:
            return

        payload = {
            "device_uuid": uuid,
            "mac_address": mac,
            "pin": pin,
            "model": model or "ESP32-S3-POE-ETH-8DI-8RO",
            "batch_no": batch_no or datetime.now().strftime("BATCH-%Y-%m")
        }

        self.btn_register_device.config(state=tk.DISABLED, text="⏳ Sunucuya Kaydediliyor...")

        def _worker():
            try:
                req = urllib.request.Request(
                    f"{API_INVENTORY_URL}/register",
                    data=json.dumps(payload).encode("utf-8"),
                    headers={
                        "Content-Type": "application/json",
                        "X-Admin-Api-Key": server_pwd
                    },
                    method="POST"
                )
                with urllib.request.urlopen(req, timeout=10) as response:
                    res_body = response.read().decode("utf-8")
                    data = json.loads(res_body)

                self.after(0, lambda: self._on_register_success(data, pin))

            except urllib.error.HTTPError as e:
                err_text = e.read().decode("utf-8")
                try:
                    err_json = json.loads(err_text)
                    msg = err_json.get("message", err_text)
                except Exception:
                    msg = err_text

                if e.code == 409:
                    self.after(0, lambda m=msg: messagebox.showerror(
                        "Mükerrer Cihaz Uyarısı (409)",
                        f"⚠️ AYNI CİHAZ İKİNCİ KEZ EKLENEMEZ!\n\n{m}"
                    ))
                elif e.code == 401:
                    # Şifre geçersiz - oturum şifresini temizle
                    self.session_server_password = None
                    self.after(0, lambda m=msg: messagebox.showerror(
                        "Yetkisiz İşlem (401)",
                        f"🔒 Hatalı Sunucu Şifresi!\n\n{m}\n\nLütfen şifrenizi kontrol edip tekrar deneyin."
                    ))
                else:
                    self.after(0, lambda c=e.code, m=msg: messagebox.showerror("Kayıt Başarısız", f"Sunucu Hatası ({c}):\n{m}"))

            except Exception as e:
                err_str = str(e)
                self.after(0, lambda es=err_str: messagebox.showerror("Bağlantı Hatası", f"API Sunucusuna ulaşılamadı:\n{es}"))
            finally:
                self.after(0, lambda: self.btn_register_device.config(
                    state=tk.NORMAL, text="☁️ SUNUCU ENVANTERİNE KAYDET & KAREKOD ÜRET"
                ))

        threading.Thread(target=_worker, daemon=True).start()

    def _on_register_success(self, res_data, plain_pin):
        """Kayıt başarılı olunca etiketi oluşturur ve önizlemeye koyar."""
        device = res_data.get("data", {}).get("device", {})
        qr_url = res_data.get("data", {}).get("qr_claim_url", "")
        
        uuid = device.get("device_uuid")
        serial_no = device.get("serial_no", 1)
        mac = device.get("mac_address")
        created_at = device.get("created_at")
        model = device.get("model", "ESP32-S3-POE-ETH-8DI-8RO")

        # Termal Etiket Çizim
        img = self._create_thermal_label_image(
            uuid=uuid,
            pin=plain_pin,
            mac=mac,
            serial_no=serial_no,
            model=model,
            created_at=created_at,
            qr_url=qr_url
        )

        # Diske Kaydet
        out_filename = f"{uuid}_label.png"
        out_path = os.path.join(LABELS_DIR, out_filename)
        img.save(out_path)
        self.current_label_path = out_path

        # Önizlemeyi Güncelle
        self._display_label_preview(img)

        # Tabloyu Yenile
        self.refresh_inventory_list()

        messagebox.showinfo(
            "Cihaz Envantere Eklendi!",
            f"✅ Başarılı!\n\n"
            f"Sıra No: {format_serial_badge(serial_no)}\n"
            f"Cihaz UUID: {uuid}\n"
            f"Kurulum PIN: {plain_pin}\n"
            f"MAC: {mac}\n\n"
            f"Karekod ve etiket görseli 'labels/' klasörüne kaydedildi.\n"
            f"Şimdi etiketi yazdırıp cihaz kapağına yapıştırabilirsiniz."
        )

    def _create_thermal_label_image(self, uuid, pin, mac, serial_no, model, created_at, qr_url):
        """Pillow ile yüksek çözünürlüklü termal barkod etiket görseli oluşturur."""
        width, height = 500, 280
        img = Image.new("RGB", (width, height), color="#ffffff")
        draw = ImageDraw.Draw(img)

        # Dış Kutu Çerçevesi
        draw.rectangle([(2, 2), (width - 3, height - 3)], outline="#0f172a", width=3)
        draw.rectangle([(5, 5), (width - 6, 42)], fill="#0f172a")

        # Başlık ve Model
        try:
            title_font = ImageFont.truetype("segoeui.ttf", 15)
            bold_font = ImageFont.truetype("segoeui.ttf", 13)
            val_font = ImageFont.truetype("segoeui.ttf", 12)
            small_font = ImageFont.truetype("segoeui.ttf", 9)
        except Exception:
            title_font = ImageFont.load_default()
            bold_font = title_font
            val_font = title_font
            small_font = title_font

        draw.text((15, 12), "AHBU AKILLI EV & BİNA OTOMASYONU", fill="#38bdf8", font=title_font)
        draw.text((width - 95, 14), format_serial_badge(serial_no), fill="#ffffff", font=bold_font)

        # Karekod Oluşturma
        qr = qrcode.QRCode(box_size=5, border=1)
        qr.add_data(qr_url or f"https://evotomasyon.gudeteknoloji.com.tr/claim?uid={uuid}&pin={pin}")
        qr.make(fit=True)
        qr_img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
        qr_img = qr_img.resize((190, 190))
        img.paste(qr_img, (14, 52))

        # Sağ Alan Bilgileri
        x_left = 220
        y = 56

        # Cihaz UUID
        draw.text((x_left, y), "CİHAZ SERİ NO (UUID):", fill="#64748b", font=small_font)
        draw.text((x_left, y + 15), str(uuid), fill="#0f172a", font=bold_font)
        y += 42

        # Kurulum PIN (Kutu içine vurgulu)
        draw.text((x_left, y), "KURULUM GÜVENLİK PIN:", fill="#64748b", font=small_font)
        draw.rectangle([(x_left, y + 14), (x_left + 150, y + 42)], outline="#dc2626", fill="#fef2f2", width=1)
        
        # PIN'i 3'er haneli boşluklu göster (örn: 482 915)
        clean_pin = str(pin).strip()
        display_pin = f"{clean_pin[:3]} {clean_pin[3:]}" if len(clean_pin) == 6 else clean_pin
        draw.text((x_left + 35, y + 18), display_pin, fill="#dc2626", font=title_font)
        y += 50

        # MAC Adresi
        draw.text((x_left, y), "MAC ADRESİ:", fill="#64748b", font=small_font)
        draw.text((x_left, y + 14), str(mac), fill="#1e293b", font=val_font)
        y += 36

        # Alt Satır: Model & Tarih
        date_str = datetime.now().strftime("%d.%m.%Y %H:%M")
        if created_at:
            try:
                if isinstance(created_at, datetime):
                    date_str = created_at.strftime("%d.%m.%Y %H:%M")
                else:
                    dt = datetime.fromisoformat(str(created_at).replace("Z", "+00:00"))
                    date_str = dt.strftime("%d.%m.%Y %H:%M")
            except Exception:
                date_str = str(created_at)[:16]

        draw.line([(10, height - 32), (width - 10, height - 32)], fill="#cbd5e1", width=1)
        draw.text((15, height - 24), f"Model: {model}", fill="#64748b", font=small_font)
        draw.text((width - 150, height - 24), f"Kayıt: {date_str}", fill="#64748b", font=small_font)

        return img

    def _display_label_preview(self, pil_img):
        """Etiket resmini sağdaki önizleme kutusuna yerleştirir."""
        self.current_label_img = pil_img
        preview_copy = pil_img.copy()
        preview_copy.thumbnail((420, 240))
        tk_img = ImageTk.PhotoImage(preview_copy)
        self.label_canvas_img.config(image=tk_img, text="", width=420, height=240)
        self.label_canvas_img.image = tk_img

        self.btn_save_label.config(state=tk.NORMAL)
        self.btn_print_label.config(state=tk.NORMAL)

    def save_label_file(self):
        """Oluşturulan etiketi kullanıcının seçeceği konuma kaydeder."""
        if not self.current_label_img:
            return
        initial_file = os.path.basename(self.current_label_path) if self.current_label_path else "etiket.png"
        path = filedialog.asksaveasfilename(
            defaultextension=".png",
            filetypes=[("PNG Görseli", "*.png"), ("Tüm Dosyalar", "*.*")],
            initialfile=initial_file
        )
        if path:
            self.current_label_img.save(path)
            messagebox.showinfo("Kaydedildi", f"Etiket görseli başarıyla kaydedildi:\n{path}")

    def print_label_file(self):
        """Etiketi Windows varsayılan termal/barkod yazıcısına gönderir."""
        if not self.current_label_path or not os.path.exists(self.current_label_path):
            messagebox.showwarning("Etiket Yok", "Lütfen önce bir etiket oluşturun veya tablodan seçin.")
            return

        try:
            if os.name == 'nt':
                os.startfile(self.current_label_path, "print")
                messagebox.showinfo("Yazıcıya Gönderildi", "Etiket yazdırma sırasına gönderildi.")
            else:
                messagebox.showinfo("Yazdırma", f"Etiket dosya yolu: {self.current_label_path}")
        except Exception as e:
            messagebox.showerror("Yazdırma Hatası", f"Yazıcıya gönderilirken hata oluştu: {str(e)}")

    def refresh_inventory_list(self):
        """Sunucudan envanter listesini çeker ve Treeview'a doldurur."""
        auth_key = self.session_server_password or ADMIN_API_KEY
        def _worker():
            try:
                req = urllib.request.Request(
                    f"{API_INVENTORY_URL}?limit=100",
                    headers={"X-Admin-Api-Key": auth_key}
                )
                with urllib.request.urlopen(req, timeout=8) as response:
                    data = json.loads(response.read().decode("utf-8"))
                    items = data.get("data", {}).get("items", [])
                    self.after(0, lambda it=items: self._populate_inventory_tree(it))
            except Exception:
                # Arka plan hatasında sessiz kal veya logla
                pass

        threading.Thread(target=_worker, daemon=True).start()

    def _populate_inventory_tree(self, items):
        for row in self.inv_tree.get_children():
            self.inv_tree.delete(row)

        for item in items:
            serial_no = format_serial_badge(item.get('serial_no', 1))
            uuid = item.get("device_uuid", "")
            mac = item.get("mac_address", "")
            model = item.get("model", "")
            status = item.get("status", "IN_STOCK")
            
            created_at = item.get("created_at", "")
            if created_at:
                try:
                    created_at = datetime.fromisoformat(created_at.replace("Z", "+00:00")).strftime("%d.%m.%Y %H:%M")
                except Exception:
                    pass

            claimed_at = item.get("claimed_at")
            if claimed_at:
                try:
                    claimed_at = datetime.fromisoformat(claimed_at.replace("Z", "+00:00")).strftime("%d.%m.%Y %H:%M")
                except Exception:
                    pass
            else:
                claimed_at = "Henüz Eşlenmedi"

            self.inv_tree.insert(
                "",
                tk.END,
                values=(serial_no, uuid, mac, model, status, created_at, claimed_at),
                tags=(status,)
            )

        # Durum renklendirme etiketleri
        self.inv_tree.tag_configure("IN_STOCK", foreground="#2e7d32")
        self.inv_tree.tag_configure("CLAIMED", foreground="#1565c0")
        self.inv_tree.tag_configure("SUSPENDED", foreground="#e65100")
        self.inv_tree.tag_configure("REVOKED", foreground="#c62828")

    def on_tree_select(self, event):
        selected = self.inv_tree.selection()
        if not selected:
            return
        item = self.inv_tree.item(selected[0])
        vals = item.get("values", [])
        if vals:
            uuid = vals[1]
            mac = vals[2]
            # Formu doldur
            self.inv_uuid_entry.delete(0, tk.END)
            self.inv_uuid_entry.insert(0, uuid)
            self.inv_mac_entry.delete(0, tk.END)
            self.inv_mac_entry.insert(0, mac)

    def render_selected_device_label(self):
        """Tablodan seçilen cihazın etiketini önizlemeye getirir."""
        selected = self.inv_tree.selection()
        if not selected:
            messagebox.showinfo("Seçim Yapın", "Lütfen tablodan bir cihaz seçin.")
            return

        item = self.inv_tree.item(selected[0])
        vals = item.get("values", [])
        serial_no = format_serial_badge(vals[0])
        uuid = vals[1]
        mac = vals[2]
        model = vals[3]
        created_at = vals[5]

        # Etiket resmini üret
        img = self._create_thermal_label_image(
            uuid=uuid,
            pin="******", # Envanterde pin hashli olduğu için masked gösterilir
            mac=mac,
            serial_no=serial_no,
            model=model,
            created_at=created_at,
            qr_url=f"https://evotomasyon.gudeteknoloji.com.tr/claim?uid={uuid}"
        )
        out_filename = f"{uuid}_label.png"
        out_path = os.path.join(LABELS_DIR, out_filename)
        img.save(out_path)
        self.current_label_path = out_path
        self._display_label_preview(img)

    def suspend_selected_device(self):
        """Seçilen cihazı askıya alır (SUSPENDED)."""
        selected = self.inv_tree.selection()
        if not selected:
            messagebox.showinfo("Seçim Yapın", "Lütfen önce tablodan bir cihaz seçin.")
            return
        uuid = self.inv_tree.item(selected[0])["values"][1]

        if not messagebox.askyesno("Onay", f"Cihaz ({uuid}) askıya alınacaktır.\nAskıdaki cihazlar sahada daireye tanımlanamaz.\nDevam edilsin mi?"):
            return

        self._update_device_status(uuid, "SUSPENDED")

    def activate_selected_device(self):
        """Seçilen cihazı tekrar aktif stok durumuna getirir."""
        selected = self.inv_tree.selection()
        if not selected:
            messagebox.showinfo("Seçim Yapın", "Lütfen önce tablodan bir cihaz seçin.")
            return
        uuid = self.inv_tree.item(selected[0])["values"][1]

        self._update_device_status(uuid, "IN_STOCK")

    def _update_device_status(self, uuid, new_status):
        auth_key = self.get_server_password(
            prompt=f"Cihaz durumunu ({new_status}) güncellemek için lütfen Sunucu Şifresini giriniz:"
        )
        if not auth_key:
            return

        def _worker():
            try:
                req = urllib.request.Request(
                    f"{API_INVENTORY_URL}/{uuid}/status",
                    data=json.dumps({"status": new_status}).encode("utf-8"),
                    headers={
                        "Content-Type": "application/json",
                        "X-Admin-Api-Key": auth_key
                    },
                    method="PATCH"
                )
                with urllib.request.urlopen(req, timeout=8) as response:
                    res = json.loads(response.read().decode("utf-8"))
                    self.after(0, lambda msg=res.get("message", "Durum güncellendi."): messagebox.showinfo("Başarılı", msg))
                    self.after(0, self.refresh_inventory_list)
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    self.session_server_password = None
                    self.after(0, lambda: messagebox.showerror("Yetkisiz Erişim (401)", "🔒 Hatalı sunucu şifresi! İşlem yetkisi reddedildi."))
                else:
                    self.after(0, lambda c=e.code: messagebox.showerror("Hata", f"Sunucu hatası ({c})"))
            except Exception as e:
                err_str = str(e)
                self.after(0, lambda es=err_str: messagebox.showerror("Hata", f"Durum güncellenemedi: {es}"))

        threading.Thread(target=_worker, daemon=True).start()

    def delete_selected_device(self):
        """Seçilen cihazı envanterden siler."""
        selected = self.inv_tree.selection()
        if not selected:
            messagebox.showinfo("Seçim Yapın", "Lütfen önce tablodan silinecek cihazı seçin.")
            return
        uuid = self.inv_tree.item(selected[0])["values"][1]

        if not messagebox.askyesno("Kritik Onay", f"DİKKAT!\n\nCihaz ({uuid}) envanterden tamamen silinecektir.\nBu işlem geri alınamaz.\n\nEmin misiniz?"):
            return

        auth_key = self.get_server_password(
            prompt=f"Cihazı ({uuid}) envanterden silmek için lütfen Sunucu Şifresini giriniz:"
        )
        if not auth_key:
            return

        def _worker():
            try:
                req = urllib.request.Request(
                    f"{API_INVENTORY_URL}/{uuid}",
                    headers={"X-Admin-Api-Key": auth_key},
                    method="DELETE"
                )
                with urllib.request.urlopen(req, timeout=8) as response:
                    res = json.loads(response.read().decode("utf-8"))
                    self.after(0, lambda msg=res.get("message", "Cihaz silindi."): messagebox.showinfo("Silindi", msg))
                    self.after(0, self.refresh_inventory_list)
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    self.session_server_password = None
                    self.after(0, lambda: messagebox.showerror("Yetkisiz Erişim (401)", "🔒 Hatalı sunucu şifresi! Silme yetkisi reddedildi."))
                else:
                    self.after(0, lambda c=e.code: messagebox.showerror("Hata", f"Sunucu hatası ({c})"))
            except Exception as e:
                err_str = str(e)
                self.after(0, lambda es=err_str: messagebox.showerror("Hata", f"Silme işlemi başarısız: {es}"))

        threading.Thread(target=_worker, daemon=True).start()

    # =========================================================================
    # SEKME 1 (FLASHER) YARDIMCI VE ÇALIŞTIRMA METOTLARI
    # =========================================================================
    def refresh_ports(self):
        """Sistemdeki aktif seri portları bulur ve açılır kutuya doldurur."""
        ports = list(serial.tools.list_ports.comports())
        port_list = []
        for p in ports:
            desc = p.description or ""
            port_list.append(f"{p.device} ({desc})")

        self.port_combo["values"] = port_list
        if port_list:
            self.port_combo.current(0)
        else:
            self.port_combo.set("Port bulunamadı (USB bağlayın)")

    def get_selected_port(self):
        """Açılır kutudan COM port adını ayrıştırır (örn: 'COM4')."""
        val = self.port_combo.get()
        if not val or "bulunamadı" in val:
            return None
        return val.split(" ")[0].strip()

    def apply_mode_selection(self):
        """Seçilen moda göre firmware dosya yolunu otomatik ayarlar."""
        mode = self.mode_var.get()
        if mode == "custom":
            rel_file = self.version_data.get("firmware_file", "")
            target_path = os.path.normpath(os.path.join(RELEASES_DIR, rel_file))
            if not os.path.exists(target_path):
                alt_build = os.path.normpath(os.path.join(DEMO_DIR, ".pio", "build", "esp32-s3-waveshare", "firmware.bin"))
                if os.path.exists(alt_build):
                    target_path = alt_build

            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, target_path)
            self.inc_ver_btn.config(state=tk.NORMAL)
            self.browse_btn.config(state=tk.NORMAL)

        elif mode == "factory":
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, os.path.normpath(FACTORY_BIN))
            self.inc_ver_btn.config(state=tk.DISABLED)
            self.browse_btn.config(state=tk.DISABLED)

    def inc_version(self):
        """Sürüm numarasını arttırır ve yeni sürüm klasörünü oluşturur."""
        cur = self.version_data.get("current_version", "1.0.0")
        next_ver = increment_version_str(cur)

        if messagebox.askyesno("Versiyon Arttır", f"Mevcut sürüm: v{cur}\nYeni sürüm: v{next_ver}\n\nOnaylıyor musunuz?"):
            new_rel_dir = os.path.join(RELEASES_DIR, f"v{next_ver}")
            os.makedirs(new_rel_dir, exist_ok=True)

            cur_bin = self.file_entry.get().strip()
            new_bin_name = f"firmware_v{next_ver}.bin"
            new_bin_path = os.path.join(new_rel_dir, new_bin_name)

            if os.path.exists(cur_bin):
                shutil.copy2(cur_bin, new_bin_path)

            self.version_data["current_version"] = next_ver
            self.version_data["firmware_file"] = f"v{next_ver}/{new_bin_name}"
            self.version_data["updated_at"] = datetime.now().isoformat()
            save_version_info(self.version_data)

            self.ver_label.config(text=f"Mevcut: v{next_ver}")
            self.apply_mode_selection()
            self.log(f"\n[VERSİYON] Sürüm v{next_ver} olarak güncellendi: {new_bin_path}")

    def browse_custom_file(self):
        """Kullanıcının harici bir .bin dosyası seçmesine izin verir."""
        path = filedialog.askopenfilename(
            title="Firmware .bin Dosyası Seçin",
            filetypes=[("Binary Firmware", "*.bin"), ("Tüm Dosyalar", "*.*")],
            initialdir=RELEASES_DIR
        )
        if path:
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, os.path.normpath(path))

    def set_ui_state(self, enabled=True):
        state = tk.NORMAL if enabled else tk.DISABLED
        self.btn_flash.config(state=state)
        self.btn_read_info.config(state=state)
        self.btn_erase.config(state=state)
        self.r_custom.config(state=state)
        self.r_factory.config(state=state)
        self.is_flashing = not enabled

    def log(self, text):
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)

    def run_command(self, cmd_args):
        """Harici komutu (esptool) arka planda çalıştırır ve çıktıları loglar."""
        def target():
            try:
                self.log("\n" + "=" * 50)
                self.log(f"[BAŞLADI] {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
                self.log(f"[KOMUT] {' '.join(cmd_args)}")
                self.log("=" * 50)

                process = subprocess.Popen(
                    cmd_args,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
                )

                for line in process.stdout:
                    clean_line = line.rstrip()
                    if clean_line:
                        self.log(clean_line)

                process.wait()
                if process.returncode == 0:
                    self.log("\n✅ [BAŞARILI] İşlem eksiksiz tamamlandı!")
                    messagebox.showinfo("Başarılı", "Firmware işlemi başarıyla tamamlandı!")
                else:
                    self.log(f"\n❌ [HATA] İşlem başarısız oldu (Hata Kodu: {process.returncode})")
                    messagebox.showerror("Hata", "İşlem sırasında hata oluştu. Log penceresini kontrol edin.")

            except Exception as e:
                self.log(f"\n❌ [İSTİSNA] {str(e)}")
                messagebox.showerror("Hata", f"Beklenmeyen bir hata oluştu: {str(e)}")
            finally:
                self.set_ui_state(True)

        self.set_ui_state(False)
        threading.Thread(target=target, daemon=True).start()

    def build_esptool_cmd(self, sub_args):
        esptool_path = find_esptool()
        if esptool_path.endswith(".py"):
            return [sys.executable, esptool_path] + sub_args
        return [esptool_path] + sub_args

    def start_flash(self):
        port = self.get_selected_port()
        if not port:
            messagebox.showwarning("Port Seçilmedi", "Lütfen önce bir COM portu seçin!")
            return

        bin_path = self.file_entry.get().strip()
        if not bin_path or not os.path.exists(bin_path):
            messagebox.showwarning("Dosya Bulunamadı", f"Seçilen firmware dosyası bulunamadı:\n{bin_path}")
            return

        cmd = self.build_esptool_cmd([
            "--chip", DEFAULT_CHIP,
            "--port", port,
            "--baud", DEFAULT_BAUD,
            "write_flash",
            "0x0",
            bin_path
        ])
        self.run_command(cmd)

    def start_read_info(self):
        port = self.get_selected_port()
        if not port:
            messagebox.showwarning("Port Seçilmedi", "Lütfen önce bir COM portu seçin!")
            return

        cmd = self.build_esptool_cmd([
            "--chip", DEFAULT_CHIP,
            "--port", port,
            "chip_id"
        ])
        self.run_command(cmd)

    def start_erase(self):
        port = self.get_selected_port()
        if not port:
            messagebox.showwarning("Port Seçilmedi", "Lütfen önce bir COM portu seçin!")
            return

        if not messagebox.askyesno("Onay", "Çipteki tüm flash hafıza silinecektir. Devam etmek istiyor musunuz?"):
            return

        cmd = self.build_esptool_cmd([
            "--chip", DEFAULT_CHIP,
            "--port", port,
            "erase_flash"
        ])
        self.run_command(cmd)


if __name__ == "__main__":
    app = EvOtomasyonServisApp()
    app.mainloop()
