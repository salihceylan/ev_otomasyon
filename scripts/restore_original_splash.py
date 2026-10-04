"""Orijinal devreli/neonlu logoyu ve devre arka planını geri yükler; launcher ikonlarını dağıtır.

Dizin düzeni (WP-BOOT, PF-16/PF-17):
  assets_src/    tam boyutlu ana kopya (pakete GİRMEZ)
  assets/images/ yalnız pakete giren dosyalar (pubspec.yaml'daki AÇIK liste): küçültülmüş logolar + arka plan
Kök dizin bu dosyanın konumundan türetilir: ana ağaçta da geliştirme kopyasında da çalışır.
Girdi dosyaları (brain_*) bu makineye özgü dış yollardır.
"""
from pathlib import Path
import os
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "assets_src"
IMAGES_DIR = ROOT / "assets" / "images"
RES_DIR = ROOT / "android" / "app" / "src" / "main" / "res"

# Pakete giren logolar (px). En büyük kullanım 130 dp (3,5x ≈ 455 px); 1024x1024 RGBA ≈ 4 MiB çözülür.
# round_app_logo.png ile app_logo.png AYNI baytlar olmamalı (farklı yol = ayrı ImageCache girdisi).
PACKAGED_LOGOS = {"round_app_logo.png": 512, "app_logo.png": 256}

brain_logo = r"C:\Users\fingonancalime\.gemini\antigravity\brain\e81fb177-6dae-4323-9540-fcf1d05c58d6\round_app_logo_1790187033859.jpg"
brain_bg = r"C:\Users\fingonancalime\.gemini\antigravity\brain\e81fb177-6dae-4323-9540-fcf1d05c58d6\ai_circuit_bg_1790187016957.jpg"

dest_master = SRC_DIR / "round_app_logo.png"
dest_bg = IMAGES_DIR / "ai_circuit_bg.jpg"

# 1. Orijinal Devreli ve Neonlu Logoyu Aç
img = Image.open(brain_logo).convert("RGBA")

# Dairesel maske uygula
mask = Image.new("L", img.size, 0)
draw = ImageDraw.Draw(mask)
draw.ellipse((0, 0, img.size[0], img.size[1]), fill=255)
img.putalpha(mask)

SRC_DIR.mkdir(parents=True, exist_ok=True)
IMAGES_DIR.mkdir(parents=True, exist_ok=True)
img.save(dest_master, "PNG")
for name, size in PACKAGED_LOGOS.items():
    img.resize((size, size), Image.Resampling.LANCZOS).save(IMAGES_DIR / name, "PNG", optimize=True)
print("Orijinal dairesel devre logoları kaydedildi:", img.size)

# 2. Orijinal Arka Planı Garantiye Al
bg_img = Image.open(brain_bg)
bg_img.save(dest_bg, "JPEG", quality=95)
print("Orijinal devre arka planı kaydedildi:", bg_img.size)

# 3. Android res Klasörlerine Native Splash ve Launcher İkonlarını Dağıt
res_dir = str(RES_DIR)

adaptive_sizes = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

legacy_sizes = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}

for folder, total_size in adaptive_sizes.items():
    folder_path = os.path.join(res_dir, folder)
    os.makedirs(folder_path, exist_ok=True)
    
    # Adaptive Foreground (%78 ölçekli, dolu dolu görünen orijinal logo)
    fg_canvas = Image.new("RGBA", (total_size, total_size), (0, 0, 0, 0))
    logo_size = int(total_size * 0.78)
    resized_logo = img.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
    offset = (total_size - logo_size) // 2
    fg_canvas.paste(resized_logo, (offset, offset), mask=resized_logo)
    fg_canvas.save(os.path.join(folder_path, "ic_launcher_foreground.png"), format="PNG")
    
    # Legacy Launcher Icons
    leg_size = legacy_sizes[folder]
    leg_img = img.resize((leg_size, leg_size), Image.Resampling.LANCZOS)
    leg_img.save(os.path.join(folder_path, "ic_launcher.png"), format="PNG")
    leg_img.save(os.path.join(folder_path, "ic_launcher_round.png"), format="PNG")

# 4. Native açılış bitmap'i bu betikle ÜRETİLMEZ: eski drawable/splash_logo.png ve drawable/splash_bg_circuit.png
#    hiçbir XML/Kotlin dosyasında referanssızdı (commit 17596ad) ve kaldırıldı. Açılış bitmap'i için
#    scripts/generate_hd_splash.py kullanılır (drawable-nodpi/splash_screen_full.webp).

print("Android launcher ikonları başarıyla orijinal haline döndürüldü!")

