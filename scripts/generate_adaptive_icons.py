from PIL import Image, ImageDraw
import os

src_path = r"g:\site\ev_otomasyon\assets\images\round_app_logo_thin_ring.png"
logo = Image.open(src_path).convert("RGBA")

# 1. Ana Flutter asset dosyalarını güncelle
logo.save(r"g:\site\ev_otomasyon\assets\images\round_app_logo.png", format="PNG")
logo.save(r"g:\site\ev_otomasyon\assets\images\app_logo.png", format="PNG")

# 2. Android mipmap klasörleri
res_dir = r"g:\site\ev_otomasyon\android\app\src\main\res"

# Adaptive icon foreground boyutları (108dp standardı)
adaptive_sizes = {
    "mipmap-mdpi": 108,
    "mipmap-hdpi": 162,
    "mipmap-xhdpi": 216,
    "mipmap-xxhdpi": 324,
    "mipmap-xxxhdpi": 432,
}

# Legacy icon boyutları (48dp standardı)
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
    
    # Adaptive Foreground: 108dp canvas üzerinde güvenli alanı dolduran büyük logo
    # Standart safe zone %66'dır ama Gmail/Chrome gibi dopdolu görünmesi için %76 ölçekliyoruz
    fg_canvas = Image.new("RGBA", (total_size, total_size), (0, 0, 0, 0))
    logo_size = int(total_size * 0.76)
    resized_logo = logo.resize((logo_size, logo_size), Image.Resampling.LANCZOS)
    offset = (total_size - logo_size) // 2
    fg_canvas.paste(resized_logo, (offset, offset), mask=resized_logo)
    fg_canvas.save(os.path.join(folder_path, "ic_launcher_foreground.png"), format="PNG")
    
    # Legacy Launcher Icons (Dopdolu tam kenar)
    leg_size = legacy_sizes[folder]
    leg_img = logo.resize((leg_size, leg_size), Image.Resampling.LANCZOS)
    leg_img.save(os.path.join(folder_path, "ic_launcher.png"), format="PNG")
    leg_img.save(os.path.join(folder_path, "ic_launcher_round.png"), format="PNG")

# 3. Splash icon (büyük ve net)
splash_dir = os.path.join(res_dir, "drawable")
os.makedirs(splash_dir, exist_ok=True)
splash_img = logo.resize((288, 288), Image.Resampling.LANCZOS)
splash_img.save(os.path.join(splash_dir, "splash_logo.png"), format="PNG")

print("Tüm Android Adaptive ve Legacy ikonları başarıyla üretildi!")

