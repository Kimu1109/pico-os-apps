#!/usr/bin/env python3
"""
generate_reversi_tiles.py
-------------------------
リバーシ(apps/reversi/app/)の盤面の絵 tiles.pimg を作る。標準ライブラリのみ。

24x24pxのタイルを横に4枚並べた1枚の画像(96x24)。pico.game のタイルマップとして使い、
盤面の1マス = タイルマップの1マスで、石の有無・色は「タイルの値」そのもの。

    タイルの値: 1=空のマス  2=黒石  3=白石  4=打てる場所の印(小さな点)

色はpico-osの16色パレットの番号で直接描く(generate_pimg.pyと同じ.pimg形式・同じパレット)。
透過は使わない(どのタイルもマスの緑で全面を塗る)。

使い方:
    python3 script/assets/generate_reversi_tiles.py                      # 既定の場所へ書く
    python3 script/assets/generate_reversi_tiles.py --preview p.ppm      # 確認用のPPMも書く
      (PPMは python3 script/tools/ppm2png.py p.ppm p.png 4 でPNGにできる)
"""

import argparse
import struct
from pathlib import Path

T = 24

PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]
BLACK, DKGREEN, LTGREY, WHITE = 0, 2, 7, 15


def cell():
    """緑のマス + 黒の格子線(右と下の辺だけ。盤面の左と上の縁はLua側が線で描く)"""
    t = [[DKGREEN] * T for _ in range(T)]
    for i in range(T):
        t[T - 1][i] = BLACK
        t[i][T - 1] = BLACK
    return t


def disc(t, r, fill, outline=None):
    cx = cy = T // 2
    for y in range(T):
        for x in range(T):
            d = (x - cx) ** 2 + (y - cy) ** 2
            if d <= r * r + r:
                t[y][x] = outline if (outline is not None and d > (r - 1) ** 2 + (r - 1)) else fill
    return t


def build_sheet():
    tiles = [
        cell(),
        disc(cell(), 9, BLACK),
        disc(cell(), 9, WHITE, BLACK),
        disc(cell(), 2, LTGREY),
    ]
    w, h = T * len(tiles), T
    rows = [[0] * w for _ in range(h)]
    for n, t in enumerate(tiles):
        for y in range(T):
            for x in range(T):
                rows[y][n * T + x] = t[y][x]
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
    ap = argparse.ArgumentParser(description="リバーシの盤面の画像(tiles.pimg)を作る")
    ap.add_argument("output", nargs="?", type=Path,
                    default=root / "apps/reversi/app/tiles.pimg")
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
