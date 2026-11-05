#!/usr/bin/env python3
"""Regenerates every FlyDesk icon from one logo (transparent PNG).

    python3 res/flydesk_icons.py <logo.png>      (needs Pillow; run from the repository root)

The macOS .icns is built from the iconset this script leaves in res/flydesk.iconset:
    iconutil -c icns res/flydesk.iconset -o flutter/macos/Runner/AppIcon.icns
"""
import os
import sys

from PIL import Image, ImageDraw

LANCZOS = Image.LANCZOS


def fit(logo, size, pad):
    """The logo centred on a transparent square canvas, `pad` = margin ratio per side."""
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    box = max(1, round(size * (1 - 2 * pad)))
    scale = min(box / logo.width, box / logo.height)
    w, h = max(1, round(logo.width * scale)), max(1, round(logo.height * scale))
    resized = logo.resize((w, h), LANCZOS)
    canvas.alpha_composite(resized, ((size - w) // 2, (size - h) // 2))
    return canvas


def mac_icon(logo, size=1024):
    """macOS style: white rounded square (Apple grid 824/1024) with the logo inside."""
    scale = 4
    big = size * scale
    plate = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    inset = round(big * 100 / 1024)
    radius = round(big * 185 / 1024)
    ImageDraw.Draw(plate).rounded_rectangle(
        [inset, inset, big - inset - 1, big - inset - 1], radius=radius, fill=(255, 255, 255, 255)
    )
    plate = plate.resize((size, size), LANCZOS)
    plate.alpha_composite(fit(logo, size, 0.21))
    return plate


def silhouette(logo, size, pad, rgb):
    """Single-colour shape of the logo (macOS menu-bar template image)."""
    shape = fit(logo, size, pad)
    flat = Image.new("RGBA", (size, size), rgb + (0,))
    flat.putalpha(shape.getchannel("A"))
    return flat


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    logo = Image.open(sys.argv[1]).convert("RGBA")
    logo = logo.crop(logo.getbbox())

    master = fit(logo, 1024, 0.04)
    master.save("res/icon.png")
    master.save("flutter/assets/icon.png")
    for name, size in (("32x32.png", 32), ("64x64.png", 64), ("128x128.png", 128), ("128x128@2x.png", 256)):
        fit(logo, size, 0.04).save(os.path.join("res", name))

    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    fit(logo, 256, 0.02).save("res/icon.ico", sizes=ico_sizes)
    fit(logo, 256, 0.02).save("flutter/windows/runner/resources/app_icon.ico", sizes=ico_sizes)
    fit(logo, 64, 0.0).save("res/tray-icon.ico", sizes=[(16, 16), (32, 32)])

    mac = mac_icon(logo)
    mac.save("res/mac-icon.png")
    silhouette(logo, 60, 0.08, (0, 0, 0)).save("res/mac-tray-dark-x2.png")
    silhouette(logo, 48, 0.08, (255, 255, 255)).save("res/mac-tray-light-x2.png")

    iconset = "res/flydesk.iconset"
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        mac.resize((base, base), LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
        mac.resize((base * 2, base * 2), LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))


if __name__ == "__main__":
    main()
