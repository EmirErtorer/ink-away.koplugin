"""Generate original synthetic comic archives; no downloaded/copyrighted pages.

Usage: python3 tests/realbb/comic_fixtures.py OUTPUT [--large]
RAR5 stored blocks follow https://www.rarlab.com/technote.htm (no RAR tool needed).
Large fixtures contain 100 noise pages, about 144 MB per archive.
"""
import argparse
import random
import struct
import zipfile
import zlib
from pathlib import Path


def vint(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def block(body):
    header = vint(len(body)) + body
    return struct.pack("<I", zlib.crc32(header)) + header


def png(w, h, noise):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = random.Random(42).randbytes(w * h * 3) if noise else bytes([255]) * (w * h * 3)
    rows = b"".join(b"\0" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--large", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    pages = [(600, 800)] * 100 if args.large else [(2000, 3000), (3000, 1000), (2000, 2000)]
    cached = {}
    with zipfile.ZipFile(args.output / "comic.cbz", "w", compression=zipfile.ZIP_STORED) as cbz, \
            (args.output / "comic.cbr").open("wb") as cbr:
        cbr.write(b"Rar!\x1a\x07\x01\0" + block(vint(1) + vint(0) + vint(0)))
        for i, size in enumerate(pages, 1):
            if size not in cached:
                cached[size] = png(*size, noise=args.large)
            data = cached[size]
            name = f"{i:04}.png".encode()
            cbz.writestr(name.decode(), data)
            # File header: data present, CRC present, stored compression, Unix host.
            header = (vint(2) + vint(2) + vint(len(data)) + vint(4) + vint(len(data)) + vint(0)
                      + struct.pack("<I", zlib.crc32(data)) + vint(0) + vint(1) + vint(len(name)) + name)
            cbr.write(block(header) + data)
        cbr.write(block(vint(5) + vint(0) + vint(0)))
    for ext in ("cbz", "cbr"):
        path = args.output / f"comic.{ext}"
        print(f"{path}: {path.stat().st_size / 1e6:.2f} MB, {len(pages)} pages")


if __name__ == "__main__":
    main()
