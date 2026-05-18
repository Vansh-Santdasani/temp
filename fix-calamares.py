#!/usr/bin/env python3
"""
AegisOS — Calamares branding fix.
Run with:  sudo python3 /tmp/fix-calamares.py
"""
import os
from PIL import Image, ImageDraw, ImageFont

D = "/etc/calamares/branding/aegisos"
os.makedirs(D + "/slides", exist_ok=True)

def shield(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pad = max(1, size // 25)
    d.ellipse([pad, pad, size-pad, size-pad],
              outline=(147, 197, 253), width=max(2, size//25))
    inner = size // 5
    d.ellipse([inner, inner, size-inner, size-inner], fill=(99, 159, 255))
    dot = size // 3
    d.ellipse([dot, dot, size-dot, size-dot], fill=(255, 255, 255))
    return img

def font(sz):
    for p in ["/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/usr/share/fonts/truetype/ubuntu/Ubuntu-B.ttf",
              "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf"]:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, sz)
            except Exception:
                pass
    return ImageFont.load_default()

# logo.png — 256x256 transparent shield
shield(256).save(f"{D}/logo.png")
print(f"  wrote logo.png")

# banner.png — 600x100 dark blue with logo + "AegisOS"
banner = Image.new("RGB", (600, 100), (30, 58, 138))
banner.paste(shield(80), (10, 10), shield(80))
ImageDraw.Draw(banner).text((110, 28), "AegisOS", font=font(38), fill="white")
banner.save(f"{D}/banner.png")
print(f"  wrote banner.png")

# welcome.png — 480x320 hero for installer welcome page
welcome = Image.new("RGB", (480, 320), (30, 58, 138))
sh = shield(120)
welcome.paste(sh, ((480 - 120) // 2, 60), sh)
d = ImageDraw.Draw(welcome)
d.text((160, 200), "AegisOS", font=font(48), fill="white")
d.text((130, 260), "AI-first Linux desktop", font=font(22), fill=(147, 197, 253))
welcome.save(f"{D}/welcome.png")
print(f"  wrote welcome.png")

# slides/slide1.png — installation slideshow
slide = Image.new("RGB", (800, 450), (20, 40, 100))
sh = shield(140)
slide.paste(sh, ((800 - 140) // 2, 60), sh)
d = ImageDraw.Draw(slide)
d.text((280, 220), "AegisOS", font=font(56), fill="white")
d.text((200, 295), "AI-powered. Secure. Yours.", font=font(24), fill=(147, 197, 253))
slide.save(f"{D}/slides/slide1.png")
print(f"  wrote slides/slide1.png")

print()
print("All branding images created. Now run:  sudo calamares")
