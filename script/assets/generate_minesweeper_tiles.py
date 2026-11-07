#!/usr/bin/env python3
"""
generate_minesweeper_tiles.py
-----------------------------
マインスイーパー(apps/minesweeper/app/)の盤面の絵 tiles20/16/14.pimg を作る。
標準ライブラリのみ。

難易度ごとにマスの大きさが違う(初級20px・中級16px・上級14px)ので、1つの難易度につき1枚の画像を作る。
どれも「1マス = 1タイル」の横並びで、pico.game のタイルマップとしてそのまま使う
(マスの右と下に隙間の線(濃い灰)を1〜2px含むので、タイルの一辺は マス+隙間)。

    タイルの値: 1=閉じたマス  2=開いた空きマス  3〜10=数字1〜8  11=旗  12=地雷(赤地)

色はpico-osの16色パレットの番号で直接描く(generate_pimg.pyと同じ.pimg形式・同じパレット)。
数字・旗・地雷の絵(14x14)はこのファイルに文字で埋め込んである(0は透過)。

使い方:
    python3 script/assets/generate_minesweeper_tiles.py                     # 既定の場所へ書く
    python3 script/assets/generate_minesweeper_tiles.py --preview p.ppm     # 確認用のPPM(初級)も書く
      (PPMは python3 script/tools/ppm2png.py p.ppm p.png 4 でPNGにできる)
"""

import argparse
import struct
from pathlib import Path

PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]
LTGREY, DKGREY, RED, WHITE = 7, 8, 12, 15

# (マスの一辺, 隙間, 書き出すファイル名)。Lua側(main.lua)の難易度の表と合わせること
SIZES = [(20, 2, "tiles20.pimg"), (16, 1, "tiles16.pimg"), (14, 1, "tiles14.pimg")]
GLYPH = 14

# 1〜8の数字(14x14。0は透過)。隣接数の定番配色
DIGITS = [
    [
        "00000000000000",
        "00099999900000",
        "00099999900000",
        "00099999900000",
        "00000099900000",
        "00000099900000",
        "00000099900000",
        "00000099900000",
        "00000099900000",
        "00000099900000",
        "00099999999000",
        "00099999999900",
        "00099999999900",
        "00000000000000",
    ],
    [
        "00000000000000",
        "000aaaaaaa0000",
        "00aaaaaaaaa000",
        "00aaa00aaaa000",
        "00000000aaa000",
        "00000000aaa000",
        "0000000aaaa000",
        "000000aaaa0000",
        "00000aaaa00000",
        "000aaaaa000000",
        "00aaaaaaaaa000",
        "00aaaaaaaaa000",
        "00aaaaaaaaa000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "000ccccccc0000",
        "000cccccccc000",
        "000cc00cccc000",
        "0000000cccc000",
        "0000ccccccc000",
        "0000cccccc0000",
        "0000ccccccc000",
        "0000000cccc000",
        "00000000ccc000",
        "00ccccccccc000",
        "00ccccccccc000",
        "00cccccccc0000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "00000055555000",
        "00000555555000",
        "00000555555000",
        "00005555555000",
        "00055505555000",
        "00055505555000",
        "00555005555000",
        "00555555555500",
        "00555555555500",
        "00555555555500",
        "00000005555000",
        "00000005555000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "00044444444000",
        "00044444444000",
        "00044444444000",
        "00044444000000",
        "00044444440000",
        "00044444444000",
        "00040004444400",
        "00000000444400",
        "00000000444400",
        "00444444444000",
        "00444444444000",
        "00044444440000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "00000bbbbbb000",
        "0000bbbbbbb000",
        "000bbbb00bb000",
        "00bbbb00000000",
        "00bbbbbbbb0000",
        "00bbbbbbbbb000",
        "00bbbbbbbbbb00",
        "00bbbb00bbbb00",
        "00bbbb00bbbb00",
        "000bbbbbbbbb00",
        "000bbbbbbbb000",
        "0000bbbbbb0000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "00111111111100",
        "00111111111100",
        "00111111111000",
        "00000001111000",
        "00000001110000",
        "00000011110000",
        "00000011110000",
        "00000111100000",
        "00000111100000",
        "00001111000000",
        "00001111000000",
        "00001110000000",
        "00000000000000",
    ],
    [
        "00000000000000",
        "00008888880000",
        "00088888888000",
        "00888808888000",
        "00888800888000",
        "00088888888000",
        "00008888880000",
        "00088888888000",
        "00888800888800",
        "00888800888800",
        "00888888888800",
        "00088888888000",
        "00008888880000",
        "00000000000000",
    ],
]

# 旗(14x14。0は透過)
FLAG = [
    "00000000000000",
    "00008000000000",
    "00008c00000000",
    "00008cccc00000",
    "00008ccccccc00",
    "00008ccccc0000",
    "00008ccc000000",
    "00008c00000000",
    "00008000000000",
    "00008000000000",
    "00008000000000",
    "00008000000000",
    "00888888000000",
    "00888888000000",
]

# 地雷(14x14。0は透過)
MINE = [
    "00000008000000",
    "08000008000080",
    "00800008000800",
    "00080888808000",
    "00008888880000",
    "00088f88888000",
    "00088888888000",
    "88888888888888",
    "00088888888000",
    "00008888880000",
    "00080888808000",
    "00800008000800",
    "08000008000080",
    "00000008000000",
]


def put_glyph(t, rows, ox, oy):
    for y, line in enumerate(rows):
        for x, ch in enumerate(line):
            v = int(ch, 16)
            if v:
                t[oy + y][ox + x] = v


def make_tiles(cell, gap):
    T = cell + gap
    bevel = 2 if cell >= 20 else 1
    off = (cell - GLYPH) // 2

    def blank(color):
        t = [[DKGREY] * T for _ in range(T)]
        for y in range(cell):
            for x in range(cell):
                t[y][x] = color
        return t

    def hidden():
        t = blank(LTGREY)
        for i in range(cell):
            for k in range(bevel):
                t[k][i] = WHITE              # 上と左の縁は明るく
                t[i][k] = WHITE
                t[cell - 1 - k][i] = DKGREY  # 下と右の縁は暗く
                t[i][cell - 1 - k] = DKGREY
        for k in range(bevel):               # 角は暗い側へ揃える
            for j in range(bevel):
                t[cell - 1 - k][j] = DKGREY if j else WHITE
        return t

    tiles = [hidden(), blank(WHITE)]
    for rows in DIGITS:
        t = blank(WHITE)
        put_glyph(t, rows, off, off)
        tiles.append(t)
    t = hidden()
    put_glyph(t, FLAG, off, off)
    tiles.append(t)
    t = blank(RED)
    put_glyph(t, MINE, off, off)
    tiles.append(t)
    return T, tiles


def build_sheet(cell, gap):
    T, tiles = make_tiles(cell, gap)
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
    ap = argparse.ArgumentParser(description="マインスイーパーの盤面の画像(tilesNN.pimg)を作る")
    ap.add_argument("--dir", type=Path, default=root / "apps/minesweeper/app",
                    help="書き出し先のディレクトリ")
    ap.add_argument("--preview", type=Path, help="確認用のPPM(P6。初級の画像)も書き出す")
    args = ap.parse_args()

    args.dir.mkdir(parents=True, exist_ok=True)
    for cell, gap, name in SIZES:
        w, h, rows = build_sheet(cell, gap)
        path = args.dir / name
        with open(path, "wb") as f:
            f.write(struct.pack("<HHB", w, h, 0))
            f.write(rle(rows))
        print(f"{path} ({w}x{h}) を書きました")
        if args.preview and cell == SIZES[0][0]:
            with open(args.preview, "wb") as f:
                f.write(f"P6\n{w} {h}\n255\n".encode())
                for row in rows:
                    for idx in row:
                        f.write(bytes(PALETTE[idx]))
            print(f"{args.preview} を書きました")


if __name__ == "__main__":
    main()
