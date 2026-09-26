"""Draw a simple, original IntoL icon with Python's standard library."""

import math
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "IntoL"
BACKGROUND = (14, 17, 20)
ACCENT = (214, 245, 115)


def smooth(edge):
    return max(0.0, min(1.0, 0.5 - edge))


def rounded_rect(x, y, cx, cy, half_width, half_height, radius):
    qx = abs(x - cx) - (half_width - radius)
    qy = abs(y - cy) - (half_height - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius


def render(size):
    rows = []
    bars = [0.22, 0.42, 0.62, 0.74, 0.62, 0.42, 0.22]
    for py in range(size):
        row = bytearray([0])
        y = (py + 0.5) / size
        for px in range(size):
            x = (px + 0.5) / size
            distance = math.hypot(x - 0.5, y - 0.5)
            ring = smooth((abs(distance - 0.408) - 0.006) * size)
            waveform = 0.0
            for index, height in enumerate(bars):
                bx = 0.5 + (index - 3) * 0.098
                edge = rounded_rect(x, y, bx, 0.5, 0.024, height / 2, 0.023)
                waveform = max(waveform, smooth(edge * size))
            alpha = max(waveform, ring * 0.26)
            for base, accent in zip(BACKGROUND, ACCENT):
                row.append(round(base * (1 - alpha) + accent * alpha))
        rows.append(bytes(row))
    raw = b"".join(rows)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


for size, filename in [(1024, "AppIcon.png"), (120, "AppIcon-60@2x.png"), (180, "AppIcon-60@3x.png")]:
    path = OUT / filename
    path.write_bytes(render(size))
    print(path, path.stat().st_size)

