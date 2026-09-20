"""
Ev Otomasyon Sistemi - Firmware Yükleme Aracı
Waveshare ESP32-S3-ETH-8DI-8RO ve ESP32 Pano Modülleri için Flasher
"""

import os
import sys
import json
import shutil
import subprocess
import threading
from datetime import datetime
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import serial.tools.list_ports

# Temel dizinler ve sabit donanım parametreleri
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DEMO_DIR = os.path.join(BASE_DIR, "waveshare_s3_demo")
FACTORY_BIN = os.path.join(DEMO_DIR, "Firmware", "ESP32-S3-POE-ETH-8DI-8RO.bin")
RELEASES_DIR = os.path.join(DEMO_DIR, "firmware_releases")
VERSION_FILE = os.path.join(RELEASES_DIR, "version_info.json")

# Cihazın sabit donanım ayarları (Kullanıcı seçimine bırakılmaz)
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


class FirmwareFlasherApp(tk.Tk):
    def __init__(self):
        super().__init__()

        self.title("AHBU - Ev Otomasyon Sistemi | Firmware Yükleyici")
        self.geometry("700x620")
        self.minsize(650, 560)

        # Renk teması
        self.bg_color = "#f4f6f9"
        self.card_bg = "#ffffff"
        self.primary_color = "#1565c0"
        self.accent_color = "#00897b"
        self.danger_color = "#c62828"
        self.text_color = "#212529"
        
        self.configure(bg=self.bg_color)
        self.is_flashing = False

        # Firmware seçim modu: "custom" (bizimki) veya "factory" (fabrika)
        self.mode_var = tk.StringVar(value="custom")
        self.version_data = load_version_info()

        self._create_widgets()
        self.refresh_ports()
        self.apply_mode_selection()

    def _create_widgets(self):
        # 1. Üst Başlık Kartı
        header_frame = tk.Frame(self, bg=self.primary_color, padx=15, pady=12)
        header_frame.pack(fill=tk.X)

        title_lbl = tk.Label(
            header_frame, 
            text="⚡ Ev Otomasyon Sistemi - Firmware Yükleyici", 
            font=("Segoe UI", 14, "bold"), 
            fg="#ffffff", 
            bg=self.primary_color
        )
        title_lbl.pack(anchor="w")

        sub_lbl = tk.Label(
            header_frame, 
            text="Waveshare ESP32-S3-ETH-8DI-8RO / Pano Röle & Otomasyon Modülü Flasher", 
            font=("Segoe UI", 9), 
            fg="#e3f2fd", 
            bg=self.primary_color
        )
        sub_lbl.pack(anchor="w")

        # Ana İçerik Çerçevesi
        content_frame = tk.Frame(self, bg=self.bg_color, padx=15, pady=10)
        content_frame.pack(fill=tk.BOTH, expand=True)

        # 2. Port ve Bağlantı Ayarları
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

        # Sabit donanım bilgilendirme rozeti
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

        # 3. Firmware Seçim Modu (Bizim Geliştirdiğimiz vs Fabrika)
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

        self.ver_badge = tk.Label(
            r1_frame, 
            text=f"v{self.version_data.get('current_version', '1.0.0')}", 
            font=("Segoe UI", 9, "bold"), 
            bg="#e8f5e9", 
            fg="#2e7d32", 
            padx=8, 
            pady=2,
            relief="solid",
            bd=1
        )
        self.ver_badge.pack(side=tk.LEFT, padx=10)

        self.inc_ver_btn = tk.Button(
            r1_frame, 
            text="➕ Versiyon Arttır", 
            command=self.increment_version,
            font=("Segoe UI", 8, "bold"),
            bg="#e0f2f1",
            fg="#004d40",
            relief="groove"
        )
        self.inc_ver_btn.pack(side=tk.LEFT)

        # Seçenek 2: Fabrika Çıkış Orijinal Yazılımı
        r2_frame = tk.Frame(fw_frame, bg=self.card_bg)
        r2_frame.pack(fill=tk.X, pady=(4, 6))

        self.r_factory = tk.Radiobutton(
            r2_frame, 
            text="🛡️ Fabrika Çıkış Orijinal Yazılımı (Waveshare Demo - Orijinal)", 
            variable=self.mode_var, 
            value="factory",
            command=self.apply_mode_selection,
            font=("Segoe UI", 9),
            fg="#424242",
            bg=self.card_bg,
            activebackground=self.card_bg
        )
        self.r_factory.pack(side=tk.LEFT)

        # Dosya Yolu Gösterimi & Gözat Butonu
        path_frame = tk.Frame(fw_frame, bg=self.card_bg)
        path_frame.pack(fill=tk.X, pady=(6, 2))

        self.file_entry = tk.Entry(path_frame, font=("Segoe UI", 9))
        self.file_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 5))

        self.browse_btn = tk.Button(
            path_frame, 
            text="📂 Gözat...", 
            command=self.browse_file,
            font=("Segoe UI", 9),
            bg="#e0e0e0",
            relief="groove"
        )
        self.browse_btn.pack(side=tk.RIGHT)

        # 4. İşlem Butonları Çerçevesi
        btn_frame = tk.Frame(content_frame, bg=self.bg_color)
        btn_frame.pack(fill=tk.X, pady=(0, 10))

        self.flash_btn = tk.Button(
            btn_frame, 
            text="⚡ Firmware'i Karta Yükle (Flash)", 
            command=self.start_flash,
            font=("Segoe UI", 10, "bold"), 
            bg=self.primary_color, 
            fg="#ffffff",
            activebackground="#0d47a1",
            activeforeground="#ffffff",
            padx=16, 
            pady=7,
            relief="raised",
            cursor="hand2"
        )
        self.flash_btn.pack(side=tk.LEFT, padx=(0, 10))

        self.info_btn = tk.Button(
            btn_frame, 
            text="🔍 Çip Bilgisini Oku", 
            command=self.start_read_info,
            font=("Segoe UI", 9), 
            bg="#ffffff", 
            fg=self.text_color,
            padx=10, 
            pady=6,
            relief="groove"
        )
        self.info_btn.pack(side=tk.LEFT, padx=(0, 10))

        self.erase_btn = tk.Button(
            btn_frame, 
            text="🧹 Çipi Tam Sıfırla (Erase)", 
            command=self.start_erase,
            font=("Segoe UI", 9), 
            bg="#ffebee", 
            fg=self.danger_color,
            padx=10, 
            pady=6,
            relief="groove"
        )
        self.erase_btn.pack(side=tk.RIGHT)

        # 5. Log Çıktı Ekranı
        log_frame = tk.LabelFrame(
            content_frame, 
            text=" Yükleme ve Çıktı Günlüğü ", 
            font=("Segoe UI", 10, "bold"), 
            bg=self.card_bg, 
            fg=self.text_color,
            padx=5, 
            pady=5
        )
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(
            log_frame, 
            wrap=tk.WORD, 
            bg="#1e1e1e", 
            fg="#d4d4d4", 
            insertbackground="#ffffff",
            font=("Consolas", 9)
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scroll = tk.Scrollbar(log_frame, command=self.log_text.yview)
        scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.config(yscrollcommand=scroll.set)

        # Alt Bilgi / İpucu Çubuğu
        tip_lbl = tk.Label(
            self, 
            text="💡 İpucu: Fabrika yazılımı orijinal olarak korunur; yeni sürümler 'firmware_releases' altında versiyonlanarak saklanır.",
            font=("Segoe UI", 8),
            fg="#555555",
            bg=self.bg_color,
            pady=4
        )
        tip_lbl.pack(side=tk.BOTTOM, fill=tk.X)

    def log(self, message):
        """Log penceresine metin ekler."""
        self.log_text.insert(tk.END, message + "\n")
        self.log_text.see(tk.END)

    def refresh_ports(self):
        """Bağlı COM portlarını listeler."""
        ports = serial.tools.list_ports.comports()
        port_list = [f"{p.device} ({p.description})" for p in ports]
        self.port_combo['values'] = port_list
        if port_list:
            self.port_combo.current(0)
            self.log(f"[BİLGİ] {len(port_list)} adet seri port tespit edildi.")
        else:
            self.port_combo.set("")
            self.log("[UYARI] Bağlı COM port bulunamadı. Cihazın USB-C kablosunu takıp 'Yenile'ye basın.")

    def get_selected_port(self):
        val = self.port_combo.get()
        if not val:
            return None
        return val.split(" ")[0].strip()

    def get_custom_bin_path(self):
        rel_path = self.version_data.get("firmware_file", "v1.0.0/firmware_v1.0.0.bin")
        return os.path.join(RELEASES_DIR, rel_path.replace("/", os.sep))

    def apply_mode_selection(self):
        """Kullanıcının mod seçimine göre dosya yolunu günceller."""
        mode = self.mode_var.get()
        self.file_entry.delete(0, tk.END)

        if mode == "custom":
            custom_path = self.get_custom_bin_path()
            self.file_entry.insert(0, custom_path)
            cur_ver = self.version_data.get("current_version", "1.0.0")
            self.ver_badge.config(text=f"v{cur_ver}")
            self.log(f"[SEÇİM] Bizim Geliştirdiğimiz Firmware seçildi (v{cur_ver})")
            self.inc_ver_btn.config(state=tk.NORMAL)
        else:
            self.file_entry.insert(0, FACTORY_BIN)
            self.log("[SEÇİM] Fabrika Çıkış Orijinal Firmware seçildi (Waveshare Demo)")
            self.inc_ver_btn.config(state=tk.DISABLED)

    def increment_version(self):
        """Versiyonu bir artırır, klasörünü oluşturur ve dosyayı kopyalar."""
        cur_ver = self.version_data.get("current_version", "1.0.0")
        new_ver = increment_version_str(cur_ver)

        if not messagebox.askyesno(
            "Versiyon Artır", 
            f"Mevcut sürüm: v{cur_ver}\nYeni oluşturulacak sürüm: v{new_ver}\n\nVersiyon artırılsın mı?"
        ):
            return

        new_dir = os.path.join(RELEASES_DIR, f"v{new_ver}")
        os.makedirs(new_dir, exist_ok=True)
        new_bin_name = f"firmware_v{new_ver}.bin"
        new_bin_path = os.path.join(new_dir, new_bin_name)

        # Mevcut en son dosyayı veya kaynak dosyayı yeni versiyona kopyala
        source_bin = self.get_custom_bin_path()
        if not os.path.exists(source_bin):
            source_bin = FACTORY_BIN

        if os.path.exists(source_bin):
            shutil.copy2(source_bin, new_bin_path)

        # JSON güncelle
        self.version_data["current_version"] = new_ver
        self.version_data["firmware_file"] = f"v{new_ver}/{new_bin_name}"
        self.version_data["updated_at"] = datetime.now().isoformat()
        save_version_info(self.version_data)

        # UI güncelle
        self.apply_mode_selection()
        self.log(f"🎉 [VERSİYON] Yeni sürüm oluşturuldu: v{new_ver}")
        self.log(f"📁 Dosya: {new_bin_path}")
        messagebox.showinfo("Başarılı", f"Versiyon başarıyla v{new_ver} olarak artırıldı!")

    def browse_file(self):
        filename = filedialog.askopenfilename(
            title="Firmware (.bin) Dosyası Seçin",
            filetypes=[("Binary Dosyası", "*.bin"), ("Tüm Dosyalar", "*.*")],
            initialdir=RELEASES_DIR if self.mode_var.get() == "custom" else os.path.dirname(FACTORY_BIN)
        )
        if filename:
            self.file_entry.delete(0, tk.END)
            self.file_entry.insert(0, filename)

    def set_ui_state(self, enabled):
        state = tk.NORMAL if enabled else tk.DISABLED
        self.flash_btn.config(state=state)
        self.info_btn.config(state=state)
        self.erase_btn.config(state=state)
        self.browse_btn.config(state=state)
        self.r_custom.config(state=state)
        self.r_factory.config(state=state)
        if self.mode_var.get() == "custom":
            self.inc_ver_btn.config(state=state)
        self.is_flashing = not enabled

    def run_command(self, cmd_args):
        """esptool komutunu çalıştırıp çıktıyı canlı loglar."""
        def target():
            try:
                self.log("\n--------------------------------------------------")
                self.log(f"[KOMUT] {' '.join(cmd_args)}")
                self.log("--------------------------------------------------")

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
                    messagebox.showinfo("Başarılı", "Firmware başarıyla karta yüklendi!")
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

        # write_flash komutu (0x0 adresinden başlar)
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
    app = FirmwareFlasherApp()
    app.mainloop()
