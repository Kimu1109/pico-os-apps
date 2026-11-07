#!/usr/bin/env python3
"""
generate_breakout_blocks.py
---------------------------
ブロック崩し(apps/breakout/app/)のブロックの絵 tiles.pimg を作る。標準ライブラリのみ。

29x14pxのタイルを横に7枚並べた1枚の画像(203x14)。pico.game のタイルマップとして使い、
盤面の1マス = タイルマップの1マス。ブロック本体は27x12pxで、右と下の2pxは隙間(背景の白)。

    タイルの値: 1〜6=壊せるブロック(速さの段。1が最速の赤、6が最遅の青)  7=壊せないブロック(灰)

色はpico-osの16色パレットの番号で直接描く(generate_pimg.pyと同じ.pimg形式・同じパレット)。
Lua側(main.lua)の TIER_COLOR と合わせてある。

使い方:
    python3 script/assets/generate_breakout_blocks.py                      # 既定の場所へ書く
    python3 script/assets/generate_breakout_blocks.py --preview p.ppm      # 確認用のPPMも書く
      (PPMは python3 script/tools/ppm2png.py p.ppm p.png 4 でPNGにできる)
"""

import argparse
import struct
from pathlib import Path

TW, TH = 29, 14          # タイル(ブロック+隙間)
BW, BH = 27, 12          # ブロック本体
PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]
WHITE = 15
# タイル1〜7の色(パレット番号): 赤・マゼンタ・黄・緑・シアン・青、壊せないブロックは濃い灰
COLORS = [12, 13, 14, 10, 11, 9, 8]


def block(color):
    t = [[WHITE] * TW for _ in range(TH)]
    for y in range(BH):
        for x in range(BW):
            t[y][x] = color
    return t


def build_sheet():
    tiles = [block(c) for c in COLORS]
    w, h = TW * len(tiles), TH
    rows = [[0] * w for _ in range(h)]
    for n, t in enumerate(tiles):
        for y in range(TH):
            for x in range(TW):
                rows[y][n * TW + x] = t[y][x]
    return w, h, rows


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
    ap = argparse.ArgumentParser(description="ブロック崩しのブロックの画像(tiles.pimg)を作る")
    ap.add_argument("output", nargs="?", type=Path,
                    default=root / "apps/breakout/app/tiles.pimg")
    ap.add_argument("--preview", type=Path, help="確認用のPPM(P6)も書き出す")
    args = ap.parse_args()

    w, h, rows = build_sheet()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(struct.pack("<HHB", w, h, 0))
        f.write(rle(rows))
    print(f"{args.output} ({w}x{h}) を書きました")
    if args.preview:
        with open(args.preview, "wb") as f:
            f.write(f"P6\n{w} {h}\n255\n".encode())
            for row in rows:
                for idx in row:
                    f.write(bytes(PALETTE[idx]))
        print(f"{args.preview} を書きました")


if __name__ == "__main__":
    main()
