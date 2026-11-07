#!/usr/bin/env python3
"""
generate_tetris_blocks.py
-------------------------
テトリス(apps/tetris/app/)のミノの画像 blocks.pimg を作る。標準ライブラリのみ。

12x12pxのタイルを横に10枚並べた1枚の画像(120x12)。pico.game のタイルマップ(盤面)と
スプライト(落ちているミノ・ゴースト)・pico.draw_image_part()(HOLD/NEXTの絵)で同じ画像を使う
(Luaが同時に持てる画像は8枚までなので1枚にまとめてある)。

    並び: 1=I 2=O 3=T 4=S 5=Z 6=J 7=L 8=ゴースト(落ちる位置の影)
          9=消えるラインの白  10=空きマス(盤面の黒)

色はpico-osの16色パレットの番号で直接描く(generate_pimg.pyと同じ.pimg形式・同じパレット)。
パレットに橙が無いので、L は灰色にしてある。

絵を変えたいときは、このスクリプトの TILES を書き換えるか、同じ大きさ(96x12)の
PNGを描いて generate_pimg.py で変換して差し替えればよい。

使い方:
    python3 script/assets/generate_tetris_blocks.py                      # 既定の場所へ書く
    python3 script/assets/generate_tetris_blocks.py out.pimg --preview p.ppm   # 確認用のPPMも書く
      (PPMは python3 script/tools/ppm2png.py p.ppm p.png 8 でPNGにできる)
"""

import argparse
import struct
from pathlib import Path

TILE = 12

# pico-osのパレット(consts.hpp / generate_pimg.py と同じ順)。プレビュー用
PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]
BLACK, NAVY, DKGREEN, DKCYAN, MAROON, PURPLE, OLIVE, LTGREY = range(8)
DKGREY, BLUE, GREEN, CYAN, RED, MAGENTA, YELLOW, WHITE = range(8, 16)

# (明るい縁, 地, 影) — ミノごとの色
MINOS = [
    (WHITE, CYAN, DKCYAN),      # I
    (WHITE, YELLOW, OLIVE),     # O
    (WHITE, MAGENTA, PURPLE),   # T
    (WHITE, GREEN, DKGREEN),    # S
    (WHITE, RED, MAROON),       # Z
    (CYAN, BLUE, NAVY),         # J
    (WHITE, LTGREY, DKGREY),    # L(パレットに橙が無いので灰)
]


def mino_tile(light, base, dark):
    """立体に見えるブロック: 左上が明るく右下が暗い縁 + 地 + 左上の光沢"""
    t = [[base] * TILE for _ in range(TILE)]
    for i in range(TILE):
        t[0][i] = light          # 上の縁
        t[i][0] = light          # 左の縁
        t[TILE - 1][i] = dark    # 下の縁
        t[i][TILE - 1] = dark    # 右の縁
    t[TILE - 1][0] = dark
    t[0][TILE - 1] = dark
    # 内側の段(もう1段だけ影を入れて厚みを出す)
    for i in range(1, TILE - 1):
        t[TILE - 2][i] = dark
        t[i][TILE - 2] = dark
    # 光沢(左上の小さなL字)
    for i in range(2, 5):
        t[2][i] = light
        t[i][2] = light
    return t


def ghost_tile():
    """ゴースト: 地は盤面と同じ黒で、灰色の点線の枠だけ"""
    t = [[BLACK] * TILE for _ in range(TILE)]
    for i in range(TILE):
        c = DKGREY if i % 2 == 0 else BLACK
        t[0][i] = c
        t[TILE - 1][TILE - 1 - i] = c
        t[TILE - 1 - i][0] = c
        t[i][TILE - 1] = c
    return t


def solid_tile(color):
    return [[color] * TILE for _ in range(TILE)]


def build_sheet():
    tiles = [mino_tile(*m) for m in MINOS] + [ghost_tile(), solid_tile(WHITE), solid_tile(BLACK)]
    w, h = TILE * len(tiles), TILE
    rows = [[0] * w for _ in range(h)]
    for n, t in enumerate(tiles):
        for y in range(TILE):
            for x in range(TILE):
                rows[y][n * TILE + x] = t[y][x]
    return w, h, rows


# ランチャのアイコン(48x48 = タイル4x4)。数字はタイルの番号(1〜7)、0は白地
ICON = [
    [0, 3, 0, 1],
    [3, 3, 3, 1],
    [2, 2, 4, 1],
    [2, 2, 4, 4],
]


def build_icon():
    tiles = [mino_tile(*m) for m in MINOS]
    rows = [[WHITE] * (TILE * 4) for _ in range(TILE * 4)]
    for ty, line in enumerate(ICON):
        for tx, n in enumerate(line):
            if not n:
                continue
            for y in range(TILE):
                for x in range(TILE):
                    rows[ty * TILE + y][tx * TILE + x] = tiles[n - 1][y][x]
    return TILE * 4, TILE * 4, rows


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
    ap = argparse.ArgumentParser(description="テトリスのミノの画像(blocks.pimg)を作る")
    ap.add_argument("output", nargs="?", type=Path,
                    default=root / "apps/tetris/app/blocks.pimg")
    ap.add_argument("--icon", type=Path, default=root / "apps/tetris/app/icon.pimg",
                    help="ランチャのアイコン(48x48)の書き出し先")
    ap.add_argument("--preview", type=Path, help="確認用のPPM(P6)も書き出す")
    args = ap.parse_args()

    for path, (w, h, rows) in ((args.output, build_sheet()), (args.icon, build_icon())):
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as f:
            f.write(struct.pack("<HHB", w, h, 0))
            f.write(rle(rows))
        print(f"{path} ({w}x{h}) を書きました")

    w, h, rows = build_sheet()

    if args.preview:
        with open(args.preview, "wb") as f:
            f.write(f"P6\n{w} {h}\n255\n".encode())
            for row in rows:
                for idx in row:
                    f.write(bytes(PALETTE[idx]))
        print(f"{args.preview} を書きました")


if __name__ == "__main__":
    main()
