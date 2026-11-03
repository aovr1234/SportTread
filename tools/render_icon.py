"""Renders design/AppIcon.svg into the iPhone app icon.

Uses headless Chrome so SVG gradients and the glow filter render exactly as designed.
Usage: python tools/render_icon.py
"""
import pathlib
import subprocess
import tempfile

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design/AppIcon.svg"
OUTPUTS = [
    ROOT / "SportTread/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
]
CHROME_PATHS = [
    pathlib.Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    pathlib.Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
]

chrome = next(p for p in CHROME_PATHS if p.exists())
with tempfile.TemporaryDirectory() as tmp:
    shot = pathlib.Path(tmp) / "icon.png"
    subprocess.run([
        str(chrome), "--headless=new", "--disable-gpu", "--hide-scrollbars",
        "--force-device-scale-factor=1", "--window-size=1024,1024",
        f"--screenshot={shot}", SOURCE.as_uri(),
    ], check=True, capture_output=True)
    # App icons must be opaque 1024x1024 RGB
    icon = Image.open(shot).convert("RGB").crop((0, 0, 1024, 1024))

for path in OUTPUTS:
    path.parent.mkdir(parents=True, exist_ok=True)
    icon.save(path, "PNG")
    print("wrote", path.relative_to(ROOT))
