"""Generate LanDrop.icns (requires Pillow and macOS iconutil)."""
from pathlib import Path
from PIL import Image, ImageDraw
import subprocess

root = Path(__file__).resolve().parent
size = 1024
image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
pixels = image.load()
for y in range(size):
    for x in range(size):
        t = (x + y) / (2 * size)
        pixels[x, y] = (int(46 + t * 41), int(105 + t * 36), int(233 - t * 12), 255)
mask = Image.new("L", (size, size))
ImageDraw.Draw(mask).rounded_rectangle((34, 34, 990, 990), radius=218, fill=255)
image.putalpha(mask)
d = ImageDraw.Draw(image)
# A sheet of paper arriving on a phone screen.
d.rounded_rectangle((280, 164, 744, 720), radius=65, fill=(255, 255, 255, 244))
d.rounded_rectangle((347, 250, 675, 278), radius=14, fill=(78, 130, 235, 150))
d.rounded_rectangle((347, 324, 602, 350), radius=13, fill=(78, 130, 235, 110))
d.rounded_rectangle((347, 397, 643, 423), radius=13, fill=(78, 130, 235, 110))
# Arrow and phone tray form one legible silhouette at small sizes.
d.rounded_rectangle((434, 528, 590, 870), radius=46, fill=(27, 68, 178, 255))
d.rounded_rectangle((451, 546, 573, 834), radius=30, fill=(229, 241, 255, 255))
d.ellipse((501, 844, 523, 866), fill=(229, 241, 255, 255))
d.rounded_rectangle((495, 470, 529, 716), radius=16, fill=(42, 105, 225, 255))
d.polygon([(433, 663), (512, 742), (591, 663)], fill=(42, 105, 225, 255))
iconset = root / "LanDrop.iconset"
iconset.mkdir(exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    image.resize((pt, pt), Image.Resampling.LANCZOS).save(iconset / f"icon_{pt}x{pt}.png")
    image.resize((pt * 2, pt * 2), Image.Resampling.LANCZOS).save(iconset / f"icon_{pt}x{pt}@2x.png")
subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(root / "LanDrop.icns")], check=True)
print(root / "LanDrop.icns")
