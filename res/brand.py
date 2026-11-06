#!/usr/bin/env python3
"""Brands of the client (msk-rustdesk). The checkout is FlyDesk; another brand is applied before a build.

    python3 res/brand.py icons <brand>     regenerates res/brands/<brand>/icons/ from res/brands/<brand>/mark.png
                                           (needs Pillow; macOS for the .icns; run from the repository root)
    python3 res/brand.py apply <brand>     copies the brand's icons and logo into place and rewrites the platform
                                           files (app name, bundle id, URL scheme); `git checkout -- .` undoes it

The Rust side takes the name from the FLYDESK_APP_NAME build variable (src/common.rs), the workflows set it
with the brand. Brands: flydesk (the checkout), mskdesk.
"""
import os
import shutil
import subprocess
import sys

BRANDS = {
    "flydesk": {"name": "FlyDesk", "bundle": "com.flydesk.desktop"},
    "mskdesk": {"name": "MskDesk", "bundle": "com.mskdesk.desktop"},
}

# Files that carry the brand name, the bundle id or the URL scheme as text.
TEXT_FILES = [
    "flutter/macos/Runner/Configs/AppInfo.xcconfig",
    "flutter/macos/Runner/Info.plist",
    "flutter/macos/Runner.xcodeproj/project.pbxproj",
    "flutter/macos/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme",
    "flutter/windows/runner/Runner.rc",
    "libs/portable/Cargo.toml",
    "build.py",
]

# Generated icon files, by their place in the tree (the same names under res/brands/<brand>/icons/).
ICON_FILES = [
    "res/icon.png",
    "flutter/assets/icon.png",
    "res/32x32.png",
    "res/64x64.png",
    "res/128x128.png",
    "res/128x128@2x.png",
    "res/icon.ico",
    "flutter/windows/runner/resources/app_icon.ico",
    "res/tray-icon.ico",
    "res/mac-icon.png",
    "res/mac-tray-dark-x2.png",
    "res/mac-tray-light-x2.png",
    "flutter/macos/Runner/AppIcon.icns",
]


def brand_dir(brand):
    return os.path.join("res", "brands", brand)


def icons(brand):
    from PIL import Image

    sys.path.insert(0, "res")
    from flydesk_icons import LANCZOS, fit, mac_icon, silhouette

    out = os.path.join(brand_dir(brand), "icons")
    logo = Image.open(os.path.join(brand_dir(brand), "mark.png")).convert("RGBA")
    logo = logo.crop(logo.getbbox())

    def path(rel):
        p = os.path.join(out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    master = fit(logo, 1024, 0.04)
    master.save(path("res/icon.png"))
    master.save(path("flutter/assets/icon.png"))
    for name, size in (("32x32.png", 32), ("64x64.png", 64), ("128x128.png", 128), ("128x128@2x.png", 256)):
        fit(logo, size, 0.04).save(path(os.path.join("res", name)))

    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    fit(logo, 256, 0.02).save(path("res/icon.ico"), sizes=ico_sizes)
    fit(logo, 256, 0.02).save(path("flutter/windows/runner/resources/app_icon.ico"), sizes=ico_sizes)
    fit(logo, 64, 0.0).save(path("res/tray-icon.ico"), sizes=[(16, 16), (32, 32)])

    mac = mac_icon(logo)
    mac.save(path("res/mac-icon.png"))
    silhouette(logo, 60, 0.08, (0, 0, 0)).save(path("res/mac-tray-dark-x2.png"))
    silhouette(logo, 48, 0.08, (255, 255, 255)).save(path("res/mac-tray-light-x2.png"))

    iconset = os.path.join(out, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        mac.resize((base, base), LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}.png"))
        mac.resize((base * 2, base * 2), LANCZOS).save(os.path.join(iconset, f"icon_{base}x{base}@2x.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", path("flutter/macos/Runner/AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    print(f"icons of {brand} written under {out}")


def apply(brand):
    if brand == "flydesk":
        print("flydesk is the checkout; nothing to apply")
        return
    target = BRANDS[brand]
    base = BRANDS["flydesk"]
    for rel in TEXT_FILES:
        with open(rel, encoding="utf-8") as f:
            text = f.read()
        new = (
            text.replace(base["bundle"], target["bundle"])
            .replace(base["name"], target["name"])
            .replace(base["name"].lower(), target["name"].lower())
        )
        if new == text:
            sys.exit(f"{rel}: no brand token found, is the checkout FlyDesk?")
        with open(rel, "w", encoding="utf-8") as f:
            f.write(new)
    for rel in ICON_FILES:
        shutil.copyfile(os.path.join(brand_dir(brand), "icons", rel), rel)
    shutil.copyfile(os.path.join(brand_dir(brand), "logo.png"), "flutter/assets/logo.png")
    print(f"{target['name']} applied ({len(TEXT_FILES)} files rewritten, {len(ICON_FILES) + 1} images copied)")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("icons", "apply") or sys.argv[2] not in BRANDS:
        sys.exit(__doc__)
    if not os.path.isdir("res/brands"):
        sys.exit("run from the repository root")
    (icons if sys.argv[1] == "icons" else apply)(sys.argv[2])


if __name__ == "__main__":
    main()
