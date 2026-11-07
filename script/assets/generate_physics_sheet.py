#!/usr/bin/env python3
"""
generate_physics_sheet.py
-------------------------
pico.game の物理を使うサンプル「おしてのぼれ」(apps/oshite/app/)の
絵 sheet.pimg と、ランチャのアイコン icon.pimg を作る。標準ライブラリのみ。

16x16pxの絵を横に8枚 x 2段(128x32)。地面・主人公・旗は「ジャンプアクション」の絵
(generate_platformer_sheet.py)をそのまま借りる。番号(frame)は左上から右へ:

     0 草の地面   1 土   2 レンガ   3 すり抜け床   4 扉   5 スイッチ   6 スイッチ(押されている)  7 旗
     8 主人公(立ち)  9 主人公(歩き)  10 主人公(ジャンプ)  11 木箱  12 鉄箱  13 ボール  14 ばね  15 星

タイルマップの値は frame+1(0は空)。透過つき(パレット0=黒は描かれない)。

使い方:
    python3 script/assets/generate_physics_sheet.py                   # 既定の場所へ書く
    python3 script/assets/generate_physics_sheet.py --preview p.ppm   # 確認用のPPMも書く
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_platformer_sheet as base  # noqa: E402

T, COLS, INK, PALETTE = base.T, base.COLS, base.INK, base.PALETTE

PLANK = [
    "oooooooooooooooo",
    "oYYYYYYYYYYYYYYo",
    "oYYoYYYYYYYoYYYo",
    "oooooooooooooooo",
    ".o............o.",
    ".o............o.",
] + ["................"] * 10

DOOR = [
    "KKKKKKKKKKKKKKKK",
    "KRRWWRRWWRRWWRRK",
    "KRWWRRWWRRWWRRWK",
    "KWWRRWWRRWWRRWWK",
    "KWRRWWRRWWRRWWRK",
    "KRRWWRRWWRRWWRRK",
    "KRWWRRWWRRWWRRWK",
    "KWWRRWWRRWWRRWWK",
    "KWRRWWRRWWRRWWRK",
    "KRRWWRRWWRRWWRRK",
    "KRWWRRWWRRWWRRWK",
    "KWWRRWWRRWWRRWWK",
    "KWRRWWRRWWRRWWRK",
    "KRRWWRRWWRRWWRRK",
    "KRWWRRWWRRWWRRWK",
    "KKKKKKKKKKKKKKKK",
]

SWITCH_OFF = ["................"] * 9 + [
    "....mmmmmmmm....",
    "...mRRRRRRRRm...",
    "...mRWWRRRRRm...",
    "...mRRRRRRRRm...",
    ".KKKKKKKKKKKKKK.",
    ".KllllllllllllK.",
    ".KKKKKKKKKKKKKK.",
]

SWITCH_ON = ["................"] * 12 + [
    "...gggggggggg...",
    ".KKKKKKKKKKKKKK.",
    ".KllllllllllllK.",
    ".KKKKKKKKKKKKKK.",
]

CRATE = [
    "oooooooooooooooo",
    "oYYYYYYYYYYYYYYo",
    "oYooYYYYYYYYooYo",
    "oYooooYYYYooooYo",
    "oYYYoooYYoooYYYo",
    "oYYYYYooooYYYYYo",
    "oYYYYYYooYYYYYYo",
    "oYYYYYooooYYYYYo",
    "oYYYYoooYoooYYYo",
    "oYYYoooYYYoooYYo",
    "oYYoooYYYYYoooYo",
    "oYoooYYYYYYYoooo",
    "oYooYYYYYYYYYooo",
    "oYYYYYYYYYYYYYYo",
    "oYYYYYYYYYYYYYYo",
    "oooooooooooooooo",
]

IRON = [
    "KKKKKKKKKKKKKKKK",
    "KllllllllllllllK",
    "KlWllllllllllWlK",
    "KllllllllllllllK",
    "KllKKKKKKKKKKllK",
    "KllKllllllllKllK",
    "KllKllllllllKllK",
    "KllKllllllllKllK",
    "KllKllllllllKllK",
    "KllKllllllllKllK",
    "KllKllllllllKllK",
    "KllKKKKKKKKKKllK",
    "KllllllllllllllK",
    "KlWllllllllllWlK",
    "KllllllllllllllK",
    "KKKKKKKKKKKKKKKK",
]

BALL = [
    "................",
    "......pppp......",
    "....ppMMMMpp....",
    "...pMMMMMMMMp...",
    "..pMWWMMMMMMMp..",
    "..pMWWMMMMMMMp..",
    ".pMMMMMMMMMMMMp.",
    ".pMMMMMMMMMMMMp.",
    ".pMMMMMMMMMMMMp.",
    ".pMMMMMMMMMMMMp.",
    "..pMMMMMMMMMMp..",
    "..pMMMMMMMMMMp..",
    "...pMMMMMMMMp...",
    "....ppMMMMpp....",
    "......pppp......",
    "................",
]

SPRING = ["................"] * 6 + [
    ".mmmmmmmmmmmmmm.",
    ".mRRRRRRRRRRRRm.",
    ".mmmmmmmmmmmmmm.",
    "....KKKKKKKK....",
    "...KllK..KllK...",
    "....KKKKKKKK....",
    "...KllK..KllK...",
    "....KKKKKKKK....",
    ".KKKKKKKKKKKKKK.",
    ".KllllllllllllK.",
]

STAR = [
    "................",
    ".......oo.......",
    ".......YY.......",
    "......oYYo......",
    "......YYYY......",
    "ooooooYWYYoooooo",
    ".oYYYYWYYYYYYYo.",
    "..oYYYWYYYYYYo..",
    "...oYYYYYYYYo...",
    "....YYYYYYYY....",
    "....YYYYYYYY....",
    "...oYYYooYYYo...",
    "...YYYo..oYYY...",
    "..oYYo....oYYo..",
    "..YYo......oYY..",
    "................",
]

ART = [
    base.ART[0], base.ART[1], base.ART[2], PLANK, DOOR, SWITCH_OFF, SWITCH_ON, base.ART[3],
    base.ART[4], base.ART[5], base.ART[6], CRATE, IRON, BALL, SPRING, STAR,
]


def build_sheet():
    w, h = COLS * T, 2 * T
    px = [[0] * w for _ in range(h)]
    for i, art in enumerate(ART):
        assert len(art) == T and all(len(r) == T for r in art), f"絵{i}の大きさが16x16ではありません"
        ox, oy = (i % COLS) * T, (i // COLS) * T
        for y, row in enumerate(art):
            for x, ch in enumerate(row):
                px[oy + y][ox + x] = INK[ch]
    return w, h, px


def build_icon():
    """48x48: 空色の地に地面・木箱・主人公"""
    S = 48
    px = [[11] * S for _ in range(S)]
    for y in range(36, S):
        for x in range(S):
            c = INK[ART[0][(y - 36) % T][x % T]]
            px[y][x] = c if c else 11

    def put(art, ox, oy, scale):
        for y in range(T * scale):
            for x in range(T * scale):
                c = INK[art[y // scale][x // scale]]
                if c and 0 <= oy + y < S and 0 <= ox + x < S:
                    px[oy + y][ox + x] = c

    put(CRATE, 24, 20, 1)
    put(CRATE, 24, 4, 1)
    put(ART[9], 4, 20, 1)
    return S, S, px


def main():
    app = Path(__file__).resolve().parents[2] / "apps" / "oshite" / "app"
    ap = argparse.ArgumentParser(description="「おしてのぼれ」の絵(sheet.pimg / icon.pimg)を作る")
    ap.add_argument("--sheet", type=Path, default=app / "sheet.pimg")
    ap.add_argument("--icon", type=Path, default=app / "icon.pimg")
    ap.add_argument("--preview", type=Path, help="確認用のPPM(4倍)")
    args = ap.parse_args()
    w, h, px = build_sheet()
    base.write_pimg(args.sheet, w, h, px, True)
    base.write_pimg(args.icon, *build_icon(), False)
    if args.preview:
        s = 4
        with open(args.preview, "wb") as f:
            f.write(b"P6\n%d %d\n255\n" % (w * s, h * s))
            for y in range(h * s):
                for x in range(w * s):
                    c = px[y // s][x // s]
                    f.write(bytes(PALETTE[c] if c else (0x60, 0x90, 0xC0)))


if __name__ == "__main__":
    main()
