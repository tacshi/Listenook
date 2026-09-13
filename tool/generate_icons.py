#!/usr/bin/env python3
"""Export the approved Listenook artwork at native desktop icon sizes."""

from pathlib import Path

from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "listenook-icon.png"
MASTER = ROOT / "assets" / "branding" / "listenook-app-icon.png"
MAC_DIR = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"


def make_master() -> Image.Image:
    # The approved artwork includes its background and spacing. Do not add the
    # old gradient plate, shadow, or a second inset around it.
    with Image.open(SOURCE) as source:
        source = ImageOps.exif_transpose(source).convert("RGBA")
        if source.width != source.height:
            raise ValueError("The Listenook icon source must be square.")
        return source.resize((1024, 1024), Image.Resampling.LANCZOS)


def main() -> None:
    master = make_master()
    master.save(MASTER, optimize=True)
    MAC_DIR.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            MAC_DIR / f"app_icon_{size}.png", optimize=True
        )
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)
    master.save(
        WINDOWS_ICON,
        format="ICO",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"Wrote {MASTER}")
    print(f"Updated {MAC_DIR}")
    print(f"Updated {WINDOWS_ICON}")


if __name__ == "__main__":
    main()
