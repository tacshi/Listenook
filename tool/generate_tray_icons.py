#!/usr/bin/env python3
"""Generate deterministic macOS template and Windows tray assets."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets" / "branding" / "tray"
CANVAS = 1024


def glyph(color: tuple[int, int, int, int]) -> Image.Image:
    scale = CANVAS / 256
    image = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # The union of a symmetric ear crown and face produces a clean silhouette.
    crown = [
        (31, 184),
        (21, 34),
        (20, 20),
        (39, 30),
        (87, 76),
        (104, 63),
        (128, 58),
        (152, 63),
        (169, 76),
        (217, 30),
        (236, 20),
        (235, 34),
        (225, 184),
    ]
    draw.polygon([(round(x * scale), round(y * scale)) for x, y in crown], fill=color)
    draw.ellipse(
        tuple(round(value * scale) for value in (31, 58, 225, 242)),
        fill=color,
    )

    # Five rounded transparent peaks remain readable at the native 18 px size.
    bars = ((67, 20), (98, 42), (128, 68), (158, 42), (189, 20))
    for center_x, height in bars:
        width = 24
        left = round((center_x - width / 2) * scale)
        right = round((center_x + width / 2) * scale)
        top = round((138 - height / 2) * scale)
        bottom = round((138 + height / 2) * scale)
        draw.rounded_rectangle(
            (left, top, right, bottom),
            radius=round(12 * scale),
            fill=(0, 0, 0, 0),
        )
    return image


def resized(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    template = glyph((0, 0, 0, 255))
    resized(template, 18).save(OUTPUT / "meowstt-tray-template.png")
    resized(template, 36).save(OUTPUT / "meowstt-tray-template@2x.png")

    windows = glyph((142, 44, 170, 255))
    resized(windows, 64).save(OUTPUT / "meowstt-tray-windows-preview.png")
    resized(windows, 256).save(
        OUTPUT / "meowstt-tray.ico",
        format="ICO",
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (256, 256)],
    )


if __name__ == "__main__":
    main()
