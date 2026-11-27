"""Builds Resources/AppIcon.icns from the iPhone app's 1024 px icon: a macOS-style rounded square with the usual margin."""
import os, subprocess, sys
from PIL import Image, ImageDraw
here = os.path.dirname(os.path.abspath(__file__))
src = Image.open(os.path.join(here, "..", "Resources", "icon-source.png")).convert("RGBA")
canvas = 1024; inset = 100; size = canvas - 2 * inset            # macOS icon grid: 824 px artwork on a 1024 px canvas
art = src.resize((size, size), Image.LANCZOS)
mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, size - 1, size - 1), radius=int(size * 0.2237), fill=255)
icon = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
icon.paste(art, (inset, inset), mask)
iconset = os.path.join(here, "..", "Resources", "AppIcon.iconset")
os.makedirs(iconset, exist_ok=True)
for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = base * scale
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "..", "Resources", "AppIcon.icns")], check=True)
print("AppIcon.icns written")
