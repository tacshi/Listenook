#!/usr/bin/env python3
"""Export the approved Listenook artwork at native desktop icon sizes."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageOps


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "listenook-icon.png"
MASTER = ROOT / "assets" / "branding" / "listenook-app-icon.png"
MAC_DIR = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
WINDOWS_SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
# Windows draws icons as-is, so the full-bleed artwork reads as a hard-edged
# square. Clip it to a rounded tile with a little breathing room instead.
WINDOWS_INSET = 0.03
WINDOWS_RADIUS = 0.2


def make_master() -> Image.Image:
    # The approved artwork includes its background and spacing. Do not add the
    # old gradient plate, shadow, or a second inset around it.
    with Image.open(SOURCE) as source:
        source = ImageOps.exif_transpose(source).convert("RGBA")
        if source.width != source.height:
            raise ValueError("The Listenook icon source must be square.")
        return source.resize((1024, 1024), Image.Resampling.LANCZOS)


def make_windows_frame(master: Image.Image, size: int) -> Image.Image:
    # Draw the mask at 4x and downsample so the curved edges stay smooth even
    # at 16 px.
    scale = 4
    canvas = size * scale
    inset = round(size * WINDOWS_INSET) * scale
    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, canvas - inset - 1, canvas - inset - 1),
        radius=round((canvas - 2 * inset) * WINDOWS_RADIUS),
        fill=255,
    )
    mask = mask.resize((size, size), Image.Resampling.LANCZOS)
    frame = master.resize((size, size), Image.Resampling.LANCZOS)
    frame.putalpha(mask)
    return frame


def main() -> None:
    master = make_master()
    master.save(MASTER, optimize=True)
    MAC_DIR.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        master.resize((size, size), Image.Resampling.LANCZOS).save(
            MAC_DIR / f"app_icon_{size}.png", optimize=True
        )
    WINDOWS_ICON.parent.mkdir(parents=True, exist_ok=True)
    frames = [make_windows_frame(master, size) for size in WINDOWS_SIZES]
    frames[-1].save(
        WINDOWS_ICON,
        format="ICO",
        sizes=[(size, size) for size in WINDOWS_SIZES],
        append_images=frames[:-1],
    )
    print(f"Wrote {MASTER}")
    print(f"Updated {MAC_DIR}")
    print(f"Updated {WINDOWS_ICON}")


if __name__ == "__main__":
    main()
