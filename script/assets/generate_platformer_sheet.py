#!/usr/bin/env python3
"""
generate_platformer_sheet.py
----------------------------
pico.game のサンプル「ジャンプアクション」(apps/jump-action/app/)の
絵 sheet.pimg と、ランチャのアイコン icon.pimg を作る。標準ライブラリのみ。

16x16pxの絵を横に8枚 x 2段並べた1枚の画像(128x32)。タイルマップとスプライトで同じ画像を使う
(Luaが同時に持てる画像は8枚までなので1枚にまとめてある)。番号(frame)は左上から右へ:

     0 草の地面   1 土   2 レンガ   3 ゴールの旗   4 主人公(立ち)  5 主人公(歩き)  6 主人公(ジャンプ)  7 雲
     8 コイン1   9 コイン2  10 スライム1  11 スライム2  12〜15 空き

タイルマップの値は frame+1(0は空)なので、草=1 土=2 レンガ=3 旗=4 雲=8。
透過つき(パレット0=黒は描かれない)なので、黒の代わりに濃い灰(8)や紺(1)で縁取っている。

使い方:
    python3 script/assets/generate_platformer_sheet.py                   # 既定の場所へ書く
    python3 script/assets/generate_platformer_sheet.py --preview p.ppm   # 確認用のPPMも書く
      (PPMは python3 script/tools/ppm2png.py p.ppm p.png 4 でPNGにできる)
"""

import argparse
import struct
from pathlib import Path

T = 16
COLS = 8

PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]

# 絵の文字 → パレット番号(. は透過)
INK = {
    ".": 0, "N": 1, "g": 2, "c": 3, "m": 4, "p": 5, "o": 6, "l": 7,
    "K": 8, "B": 9, "G": 10, "C": 11, "R": 12, "M": 13, "Y": 14, "W": 15,
}

ART = [
    # 0 草の地面
    [
        "GGGGGGGGGGGGGGGG",
        "GGgGGGGGGgGGGGGG",
        "gGgGGgGGgGgGGgGg",
        "gggggggggggggggg",
        "oooooooooooooooo",
        "ooomoooooooomooo",
        "oooooooooooooooo",
        "oomoooooooomoooo",
        "oooooooomooooooo",
        "oooooooooooooooo",
        "ooooomoooooooomo",
        "oooooooooooooooo",
        "omoooooooomooooo",
        "oooooooooooooooo",
        "ooooooomoooooooo",
        "oooooooooooooooo",
    ],
    # 1 土
    [
        "oooooooooooooooo",
        "ooomoooooooomooo",
        "oooooooooooooooo",
        "oomoooooooomoooo",
        "oooooooomooooooo",
        "oooooooooooooooo",
        "ooooomoooooooomo",
        "oooooooooooooooo",
        "omoooooooomooooo",
        "oooooooooooooooo",
        "ooooooomoooooooo",
        "oooooooooooooooo",
        "ooomoooooooomooo",
        "oooooooooooooooo",
        "oooooomooooooooo",
        "oooooooooooooooo",
    ],
    # 2 レンガ
    [
        "lllllllllllllllK",
        "RRRRRRRlRRRRRRRK",
        "RRRRRRRlRRRRRRRK",
        "mmmmmmmlmmmmmmmK",
        "lllllllllllllllK",
        "RRRlRRRRRRRlRRRK",
        "RRRlRRRRRRRlRRRK",
        "mmmlmmmmmmmlmmmK",
        "lllllllllllllllK",
        "RRRRRRRlRRRRRRRK",
        "RRRRRRRlRRRRRRRK",
        "mmmmmmmlmmmmmmmK",
        "lllllllllllllllK",
        "RRRlRRRRRRRlRRRK",
        "mmmlmmmmmmmlmmmK",
        "KKKKKKKKKKKKKKKK",
    ],
    # 3 ゴールの旗
    [
        "...YY...........",
        "...YY...........",
        "...KRRRRRRR.....",
        "...KRRRRRRRRR...",
        "...KRRWWRRRRRRR.",
        "...KRRWWRRRRRR..",
        "...KRRRRRRRR....",
        "...KRRRRR.......",
        "...K............",
        "...K............",
        "...K............",
        "...K............",
        "...K............",
        "...K............",
        "..KKK...........",
        ".KKKKK..........",
    ],
    # 4 主人公(立ち、右向き)
    [
        "................",
        ".....BBBBBB.....",
        "....BBBBBBBBBB..",
        "....NWWWWWW.....",
        "...NWWKWWWKW....",
        "...NWWKWWWKW....",
        "...NWWWWWWWW....",
        "....NWWRRWW.....",
        ".....NWWWW......",
        "....GGGGGGG.....",
        "...GGGGGGGGG....",
        "..WWGGGGGGGWW...",
        "....BBBBBBB.....",
        "....BBB.BBB.....",
        "....NNN.NNN.....",
        "...NNNN.NNNN....",
    ],
    # 5 主人公(歩き)
    [
        "................",
        ".....BBBBBB.....",
        "....BBBBBBBBBB..",
        "....NWWWWWW.....",
        "...NWWKWWWKW....",
        "...NWWKWWWKW....",
        "...NWWWWWWWW....",
        "....NWWRRWW.....",
        ".....NWWWW......",
        "....GGGGGGG.....",
        "...GGGGGGGGGW...",
        "..WGGGGGGGG.....",
        "....BBBBBBB.....",
        "...BBB...BBB....",
        "..NNN.....NNN...",
        "..NNN......NNN..",
    ],
    # 6 主人公(ジャンプ)
    [
        "..W.............",
        "..WW.BBBBBB.....",
        "...WBBBBBBBBBB..",
        "...GNWWWWWW.....",
        "...GWWKWWWKW....",
        "...GWWKWWWKW....",
        "...NWWWWWWWW....",
        "....NWWRRWW.....",
        ".....NWWWW......",
        "....GGGGGGGW....",
        "...GGGGGGGGWW...",
        "...GGGGGGGG.....",
        "....BBBBBBB.....",
        "....BBB..BBB....",
        "...NNN....NNN...",
        "..NNN......NNN..",
    ],
    # 7 雲(飾り)
    [
        "................",
        "................",
        "................",
        "................",
        "......WWWW......",
        ".....WWWWWW.....",
        "...WWWWWWWWWW...",
        "..WWWWWWWWWWWW..",
        ".WWWWWWWWWWWWWW.",
        ".WWWWWWWWWWWWWW.",
        "..WWlWWWWWWlWW..",
        "...llllllllll...",
        "................",
        "................",
        "................",
        "................",
    ],
    # 8 コイン1
    [
        "................",
        "................",
        "......oooo......",
        ".....oYYYYo.....",
        "....oYYWYYYo....",
        "....oYWYYYYo....",
        "....oYWYoYYo....",
        "....oYWYoYYo....",
        "....oYYYoYYo....",
        "....oYYYoYYo....",
        "....oYYYYYYo....",
        "....oYYYYYYo....",
        ".....oYYYYo.....",
        "......oooo......",
        "................",
        "................",
    ],
    # 9 コイン2(細く見える回転中)
    [
        "................",
        "................",
        ".......oo.......",
        "......oYYo......",
        "......oYWo......",
        "......oWYo......",
        "......oWYo......",
        "......oYYo......",
        "......oYYo......",
        "......oYYo......",
        "......oYYo......",
        "......oYYo......",
        "......oYYo......",
        ".......oo.......",
        "................",
        "................",
    ],
    # 10 スライム1
    [
        "................",
        "................",
        "................",
        "................",
        "................",
        "......gggg......",
        "....ggGGGGgg....",
        "...gGGWGGGGGg...",
        "..gGGWGGGGGGGg..",
        "..gGGWWKGGWKGg..",
        ".gGGGGWKGGWKGGg.",
        ".gGGGGGGGGGGGGg.",
        ".gGGGGGGGGGGGGg.",
        ".gGGGGGGGGGGGGg.",
        "..ggggggggggggg.",
        "................",
    ],
    # 11 スライム2(つぶれ)
    [
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        "................",
        ".....gggggg.....",
        "...ggGGGGGGgg...",
        "..gGGWGGGGGGGg..",
        ".gGGWWKGGGWKGGg.",
        ".gGGGGWKGGWKGGg.",
        "gGGGGGGGGGGGGGGg",
        "gGGGGGGGGGGGGGGg",
        ".gggggggggggggg.",
        "................",
    ],
]


def build_sheet():
    rows_n = (len(ART) + COLS - 1) // COLS
    w, h = COLS * T, rows_n * T
    px = [[0] * w for _ in range(h)]
    for i, art in enumerate(ART):
        assert len(art) == T and all(len(r) == T for r in art), f"絵{i}の大きさが16x16ではありません"
        ox, oy = (i % COLS) * T, (i // COLS) * T
        for y, row in enumerate(art):
            for x, ch in enumerate(row):
                px[oy + y][ox + x] = INK[ch]
    return w, h, px


def build_icon():
    """48x48: 空色の地に地面と主人公(3倍)"""
    S = 48
    px = [[11] * S for _ in range(S)]
    ground = ART[0]
    for y in range(36, S):
        for x in range(S):
            c = INK[ground[(y - 36) % T][x % T]]
            px[y][x] = c if c else 11
    hero = ART[6]
    for y in range(T):
        for x in range(T):
            c = INK[hero[y][x]]
            if not c:
                continue
            for dy in range(2):
                for dx in range(2):
                    yy, xx = 4 + y * 2 + dy, 8 + x * 2 + dx
                    if yy < 36:
                        px[yy][xx] = c
    return S, S, px


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


def write_pimg(path, w, h, rows, transparent):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<HHB", w, h, 1 if transparent else 0))
        f.write(rle(rows))
    print(f"{path} ({w}x{h}) を書きました")


def main():
    root = Path(__file__).resolve().parents[2]
    app = root / "apps/jump-action/app"
    ap = argparse.ArgumentParser(description="pico.gameのサンプルの絵(sheet.pimg / icon.pimg)を作る")
    ap.add_argument("output", nargs="?", type=Path, default=app / "sheet.pimg")
    ap.add_argument("--icon", type=Path, default=app / "icon.pimg")
    ap.add_argument("--preview", type=Path, help="確認用のPPM(P6)も書き出す(透過は空色で塗る)")
    args = ap.parse_args()

    w, h, rows = build_sheet()
    write_pimg(args.output, w, h, rows, True)
    write_pimg(args.icon, *build_icon(), False)

    if args.preview:
        with open(args.preview, "wb") as f:
            f.write(f"P6\n{w} {h}\n255\n".encode())
            for row in rows:
                for idx in row:
                    f.write(bytes(PALETTE[idx if idx else 11]))
        print(f"{args.preview} を書きました")


if __name__ == "__main__":
    main()
