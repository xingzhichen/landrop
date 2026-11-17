"""Install branded icons into the checked-in Flutter platform projects.
Run `python3 Resources/make_icon.py` first; requires Pillow.
"""
from pathlib import Path
from PIL import Image
import re

root = Path(__file__).resolve().parent.parent
source = Image.open(root / 'Resources/LanDrop.iconset/icon_512x512@2x.png').convert('RGBA')
base = root / 'flutter_app'

for path in (base / 'macos/Runner/Assets.xcassets/AppIcon.appiconset').glob('app_icon_*.png'):
    size = int(re.search(r'app_icon_(\d+)', path.name).group(1))
    source.resize((size, size), Image.Resampling.LANCZOS).save(path)

for path in (base / 'ios/Runner/Assets.xcassets/AppIcon.appiconset').glob('Icon-App-*.png'):
    dimension, scale = re.search(r'Icon-App-(\d+(?:\.\d+)?)x[^@]+@(\d)x', path.name).groups()
    size = round(float(dimension) * int(scale))
    icon = source.resize((size, size), Image.Resampling.LANCZOS)
    background = Image.new('RGB', (size, size), (65, 117, 235))
    background.paste(icon, mask=icon.getchannel('A'))
    background.save(path)

for qualifier, size in [('mdpi',48), ('hdpi',72), ('xhdpi',96), ('xxhdpi',144), ('xxxhdpi',192)]:
    path = base / f'android/app/src/main/res/mipmap-{qualifier}/ic_launcher.png'
    source.resize((size, size), Image.Resampling.LANCZOS).save(path)

source.save(base / 'windows/runner/resources/app_icon.ico', format='ICO',
            sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
print('Installed LanDrop icons on macOS, iOS, Android and Windows.')
