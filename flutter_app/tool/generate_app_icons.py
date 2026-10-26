#!/usr/bin/env python3
"""Regenerate app icons: python3 flutter_app/tool/generate_app_icons.py.

Requires rsvg-convert (librsvg). The artwork fits the maskable icon safe zone.
"""

from pathlib import Path
import subprocess


app = Path(__file__).resolve().parents[1]
source = Path(__file__).with_name("app_icon.svg")
targets = {app / "web/favicon.png": 32}
for size in (192, 512):
    for kind in ("Icon", "Icon-maskable"):
        targets[app / f"web/icons/{kind}-{size}.png"] = size
for density, size in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                      ("xxhdpi", 144), ("xxxhdpi", 192)):
    targets[app / f"android/app/src/main/res/mipmap-{density}/ic_launcher.png"] = size

for target, size in targets.items():
    subprocess.run(
        ["rsvg-convert", "--width", str(size), "--height", str(size),
         "--output", str(target), str(source)],
        check=True,
    )
