#!/usr/bin/env python3
"""Render the Listenook page-and-wave vector glyph for desktop trays.

The compact vector follows the approved artwork's silhouette while retaining
transparent wave and page-fold gaps for macOS template rendering.
"""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "assets" / "branding" / "tray"
CANVAS = 1024
VIEWBOX = (260, 205, 735, 855)
# Shared geometry for the editable SVG and its native raster exports.
PATHS = (
    (
        ("M", 300, 701), ("L", 300, 420),
        ("C", 300, 367, 329, 334, 380, 314), ("L", 606, 248),
        ("C", 646, 236, 678, 235, 678, 268), ("L", 678, 452),
        ("C", 678, 515, 709, 540, 775, 550), ("L", 896, 571),
        ("C", 937, 579, 954, 601, 954, 638), ("L", 954, 708),
        ("C", 898, 675, 853, 666, 815, 679),
        ("C", 768, 695, 744, 746, 708, 757),
        ("C", 669, 771, 650, 726, 633, 663),
        ("C", 616, 598, 600, 553, 568, 553),
        ("C", 535, 553, 516, 584, 500, 640),
        ("C", 485, 690, 482, 720, 466, 720),
        ("C", 445, 720, 442, 638, 407, 638),
        ("C", 373, 638, 369, 695, 300, 701), ("Z",),
    ),
    (
        ("M", 703, 245), ("L", 915, 459),
        ("C", 949, 490, 954, 518, 954, 552),
        ("C", 918, 518, 841, 516, 778, 505),
        ("C", 722, 495, 703, 466, 703, 419), ("Z",),
    ),
    (
        ("M", 300, 726),
        ("C", 357, 709, 371, 784, 402, 818),
        ("C", 429, 847, 463, 827, 481, 785),
        ("L", 519, 712), ("C", 542, 662, 569, 659, 584, 690),
        ("C", 608, 725, 617, 820, 656, 855),
        ("C", 696, 896, 745, 847, 776, 791),
        ("C", 823, 713, 877, 712, 954, 734), ("L", 954, 966),
        ("C", 954, 1005, 934, 1024, 894, 1018), ("L", 396, 964),
        ("C", 330, 956, 300, 916, 300, 847), ("Z",),
    ),
)


def glyph(color: tuple[int, int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    x, y, width, height = VIEWBOX
    scale = CANVAS / max(width, height)
    offset_x = (CANVAS - width * scale) / 2
    offset_y = (CANVAS - height * scale) / 2

    for path in PATHS:
        points = []
        current = (0, 0)
        for command, *values in path:
            if command in ("M", "L"):
                current = tuple(values)
                points.append(current)
            elif command == "C":
                start = current
                control1, control2, end = values[:2], values[2:4], values[4:6]
                for step in range(1, 49):
                    t = step / 48
                    points.append(tuple(
                        (1 - t) ** 3 * start[axis]
                        + 3 * (1 - t) ** 2 * t * control1[axis]
                        + 3 * (1 - t) * t * t * control2[axis]
                        + t ** 3 * end[axis]
                        for axis in (0, 1)
                    ))
                current = tuple(end)
        draw.polygon([
            ((px - x) * scale + offset_x, (py - y) * scale + offset_y)
            for px, py in points
        ], fill=color)
    return image


def resized(image: Image.Image, size: int) -> Image.Image:
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    paths = [" ".join(command[0] + " ".join(map(str, command[1:]))
                      for command in path) for path in PATHS]
    svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="{}">\n'.format(
        " ".join(map(str, VIEWBOX))
    )
    svg += "".join(f'  <path fill="#000" d="{path}"/>\n' for path in paths)
    (OUTPUT / "listenook-tray-glyph.svg").write_text(svg + "</svg>\n")

    template = glyph((0, 0, 0, 255))
    resized(template, 18).save(OUTPUT / "listenook-tray-template.png")
    resized(template, 36).save(OUTPUT / "listenook-tray-template@2x.png")
    windows = glyph((116, 57, 206, 255))
    resized(windows, 64).save(OUTPUT / "listenook-tray-windows-preview.png")
    resized(windows, 256).save(
        OUTPUT / "listenook-tray.ico",
        format="ICO",
        sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (256, 256)],
    )
    print(f"Updated {OUTPUT}")


if __name__ == "__main__":
    main()
