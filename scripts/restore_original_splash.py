import os
from PIL import Image, ImageDraw

brain_logo = r"C:\Users\fingonancalime\.gemini\antigravity\brain\e81fb177-6dae-4323-9540-fcf1d05c58d6\round_app_logo_1790187033859.jpg"
brain_bg = r"C:\Users\fingonancalime\.gemini\antigravity\brain\e81fb177-6dae-4323-9540-fcf1d05c58d6\ai_circuit_bg_1790187016957.jpg"

dest_round = r"g:\site\ev_otomasyon\assets\images\round_app_logo.png"
dest_app = r"g:\site\ev_otomasyon\assets\images\app_logo.png"
dest_bg = r"g:\site\ev_otomasyon\assets\images\ai_circuit_bg.jpg"

# 1. Orijinal Devreli ve Neonlu Logoyu Aç
img = Image.open(brain_logo).convert("RGBA")

# Dairesel maske uygula
mask = Image.new("L", img.size, 0)
draw = ImageDraw.Draw(mask)
draw.ellipse((0, 0, img.size[0], img.size[1]), fill=255)
img.putalpha(mask)

img.save(dest_round, "PNG")
img.save(dest_app, "PNG")
print("Orijinal dairesel devre logoları kaydedildi:", img.size)

# 2. Orijinal Arka Planı Garantiye Al
bg_img = Image.open(brain_bg)
bg_img.save(dest_bg, "JPEG", quality=95)
print("Orijinal devre arka planı kaydedildi:", bg_img.size)

# 3. Android res Klasörlerine Native Splash ve Launcher İkonlarını Dağıt
res_dir = r"g:\site\ev_otomasyon\android\app\src\main\res"

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

# 4. Splash Drawable için Orijinal Splash Logo
splash_dir = os.path.join(res_dir, "drawable")
os.makedirs(splash_dir, exist_ok=True)
splash_img = img.resize((288, 288), Image.Resampling.LANCZOS)
splash_img.save(os.path.join(splash_dir, "splash_logo.png"), format="PNG")

# 5. Android Native Splash için Arka Plan Görseli (Elektronik Devre)
# Android launch_background.xml'de bitmap olarak kullanılacak
splash_bg_circuit = bg_img.resize((1080, 1920), Image.Resampling.LANCZOS)
splash_bg_circuit.save(os.path.join(splash_dir, "splash_bg_circuit.png"), format="PNG")

print("Android splash ve launcher ikonları başarıyla orijinal haline döndürüldü!")

