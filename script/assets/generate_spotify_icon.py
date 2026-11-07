#!/usr/bin/env python3
"""Spotifyリモコン(apps/spotify-remote/app/)のランチャのアイコン icon.pimg(48x48)を作る。標準ライブラリのみ。

緑の丸に白い再生の三角と、下に小さな音量の棒(リモコンらしさ)。Spotifyのロゴは使わない。
色はpico-osの16色パレットの番号で直接描く(generate_pimg.py と同じ .pimg 形式)。

    python3 script/assets/generate_spotify_icon.py            # 既定の場所へ書く
    python3 script/assets/generate_spotify_icon.py out.pimg
"""
import argparse
import struct
from pathlib import Path

SIZE = 48
DKGREEN, GREEN, WHITE, BLACK = 2, 10, 15, 0


def build():
    rows = [[WHITE] * SIZE for _ in range(SIZE)]
    cx, cy, r = 23.5, 21.5, 20
    for y in range(SIZE):
        for x in range(SIZE):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            if d <= r:
                rows[y][x] = DKGREEN if d > r - 2 else GREEN
    # 再生の三角(右向き)
    for y in range(10, 34):
        half = 12 - abs(y - 21.5)
        for x in range(18, 18 + int(half * 1.6) + 1):
            if x < SIZE:
                rows[y][x] = WHITE
    # 下の音量の棒(大きくなる3本)
    for i, h in enumerate((3, 5, 7)):
        x0 = 30 + i * 5
        for y in range(46 - h, 46):
            for x in range(x0, x0 + 3):
                rows[y][x] = BLACK
    return rows


def rle(rows):
    out = bytearray()
    run, prev = 0, None
    for row in rows:
        for idx in row:
            if run and idx == prev and run < 255:
                run += 1
                continue
            if run:
                out += bytes((run, prev))
            prev, run = idx, 1
    if run:
        out += bytes((run, prev))
    return bytes(out)


def main():
    root = Path(__file__).resolve().parents[2]
    ap = argparse.ArgumentParser(description="Spotifyリモコンのアイコン(icon.pimg、48x48)を作る")
    ap.add_argument("output", nargs="?", type=Path, default=root / "apps/spotify-remote/app/icon.pimg")
    args = ap.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(struct.pack("<HHB", SIZE, SIZE, 0))
        f.write(rle(build()))
    print(f"{args.output} ({SIZE}x{SIZE}) を書きました")


if __name__ == "__main__":
    main()
