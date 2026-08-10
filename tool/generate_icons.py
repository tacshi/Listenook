#!/usr/bin/env python3
"""Generate deterministic Flutter desktop icons from the MeowSTT brand mark."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "assets" / "branding" / "meowstt-icon.png"
MASTER = ROOT / "assets" / "branding" / "meowstt-app-icon.png"
MAC_DIR = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
WINDOWS_ICON = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"


def make_master() -> Image.Image:
    size = 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    background = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = background.load()
    for y in range(size):
        mix = y / (size - 1)
        for x in range(size):
            edge = abs(x - size / 2) / (size / 2)
            pixels[x, y] = (
                int(249 - 36 * mix - 10 * edge),
                int(240 - 48 * mix - 6 * edge),
                int(255 - 15 * mix),
                255,
            )

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((45, 45, 979, 979), radius=215, fill=255)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_mask = mask.filter(ImageFilter.GaussianBlur(22))
    shadow.putalpha(shadow_mask.point(lambda value: int(value * 0.26)))
    shadow_color = Image.new("RGBA", (size, size), (83, 40, 120, 255))
    shadow_color.putalpha(shadow.getchannel("A"))
    canvas.alpha_composite(shadow_color, (0, 10))
    background.putalpha(mask)
    canvas.alpha_composite(background)

    mark = Image.open(SOURCE).convert("RGBA")
    mark.thumbnail((720, 720), Image.Resampling.LANCZOS)
    x = (size - mark.width) // 2
    y = (size - mark.height) // 2 + 12
    canvas.alpha_composite(mark, (x, y))
    return canvas


def main() -> None:
    master = make_master()
    master.save(MASTER, optimize=True)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        resized = master.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(MAC_DIR / f"app_icon_{size}.png", optimize=True)
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
