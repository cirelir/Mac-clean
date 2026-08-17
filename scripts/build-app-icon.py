#!/usr/bin/env python3
"""Build MacClean PNG and ICNS icon assets from a square source image."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from PIL import Image


ICNS_SIZES = (32, 64, 128, 256, 512, 1024)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("Assets"))
    return parser.parse_args()


def restore_transparency(source: Image.Image) -> Image.Image:
    """Remove only dark pixels connected to the canvas border.

    The selected artwork was exported against black. Flood-filling from the
    border avoids touching the dark SSD inside the blue icon. Edge pixels are
    un-matted from black so the rounded silhouette does not retain a dark halo.
    """

    rgb = source.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    exterior = bytearray(width * height)
    queue: deque[tuple[int, int]] = deque()

    def enqueue_if_dark(x: int, y: int) -> None:
        index = y * width + x
        if exterior[index] or max(pixels[x, y]) >= 64:
            return
        exterior[index] = 1
        queue.append((x, y))

    for x in range(width):
        enqueue_if_dark(x, 0)
        enqueue_if_dark(x, height - 1)
    for y in range(height):
        enqueue_if_dark(0, y)
        enqueue_if_dark(width - 1, y)

    while queue:
        x, y = queue.popleft()
        if x > 0:
            enqueue_if_dark(x - 1, y)
        if x + 1 < width:
            enqueue_if_dark(x + 1, y)
        if y > 0:
            enqueue_if_dark(x, y - 1)
        if y + 1 < height:
            enqueue_if_dark(x, y + 1)

    fringe = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            if not exterior[y * width + x]:
                continue
            for neighbor_y in range(max(0, y - 1), min(height, y + 2)):
                for neighbor_x in range(max(0, x - 1), min(width, x + 2)):
                    neighbor_index = neighbor_y * width + neighbor_x
                    if not exterior[neighbor_index]:
                        fringe[neighbor_index] = 1

    output = Image.new("RGBA", rgb.size)
    output_pixels = output.load()
    for y in range(height):
        for x in range(width):
            red, green, blue = pixels[x, y]
            index = y * width + x
            if exterior[index]:
                output_pixels[x, y] = (0, 0, 0, 0)
                continue

            if not fringe[index]:
                output_pixels[x, y] = (red, green, blue, 255)
                continue

            alpha = max(red, green, blue)
            if alpha >= 250:
                output_pixels[x, y] = (red, green, blue, 255)
                continue
            output_pixels[x, y] = (
                min(255, round(red * 255 / alpha)),
                min(255, round(green * 255 / alpha)),
                min(255, round(blue * 255 / alpha)),
                alpha,
            )

    return output


def main() -> None:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    with Image.open(args.source) as source:
        if source.width != source.height:
            raise SystemExit("App icon source must be square")
        icon = restore_transparency(source)

    icon = icon.resize((1024, 1024), Image.Resampling.LANCZOS)
    png_path = args.output_dir / "AppIcon.png"
    icns_path = args.output_dir / "AppIcon.icns"
    icon.save(png_path, optimize=True)

    icon.save(
        icns_path,
        format="ICNS",
        append_images=[
            icon.resize((size, size), Image.Resampling.LANCZOS)
            for size in ICNS_SIZES
        ],
    )

    print(png_path)
    print(icns_path)


if __name__ == "__main__":
    main()
