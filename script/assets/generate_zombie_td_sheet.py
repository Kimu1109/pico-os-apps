#!/usr/bin/env python3
"""Luaアプリ「ゾンビTD」の絵を作る。標準ライブラリだけで動く。

  units.pimg  透過つき(0番 = 透過)。pico.iso の人や物(エンティティ)として立てる絵を横に並べる:
      x=0   ノーマルゾンビ  コマ1, 2(12x22)
      x=24  遠距離ゾンビ    コマ1, 2(12x22。石を持ち上げている)
      x=48  重量級ゾンビ    コマ1, 2(16x26)
      x=80  ベース(44x40)
      x=124 近接兵 コマ1, 2(12x22。短剣)
      x=148 回復兵 コマ1, 2(12x22。白い服に赤十字・杖)
      x=172 弓兵   コマ1, 2(12x22。弓)
      x=196 建設中の足場(20x24)
      x=216 弓塔(20x36。上に弓兵)
      x=236 剣塔(20x36。上に近接兵)
    兵士と塔は Lv1〜4 の絵を縦に並べる(段 = 40px。Lv n は y = 40*(n-1) からの段)。ゾンビ・ベース・足場は1段目だけ。
    どれも右を向いた絵で、左へ歩くときは左右反転する。高さの違う絵は下に寄せる(足元が y=39)。
    行の並びは main.lua の SPRITES と合わせること。
  icon.pimg   ランチャのアイコン(48x48、既定のパレット)

地面の絵(faces.pimg)と色(palette.lua)は「ブロック」と同じものを使う(scripts/generate_blocks_sheet.py が作る)。
このスクリプトは「ブロック」のフォルダから写す。ただし faces.pimg は、アリーナの地形で使わないブロック4種の段を
バリケード(柵)の Lv1〜4 の絵に差し替える(穴の開いた絵なので、中を通るゾンビが透けて見える):
  12(本) = Lv1 丸太 / 14(作業台) = Lv2 木材 / 15(かまど) = Lv3 木材と石 / 16(ジュークボックス) = Lv4 石
  (番号は buildings.lua の WALLS と合わせること)
  さらに、アリーナで使うブロックの段(FACE_ROWS)だけを上から順に並べた画像にする(全部の段だと約67KBで、
  実機でチャンクの置き場を確保できなくなった)。game.lua の iso.set_image に同じ並びを渡すこと。
人や物の絵は palette.lua の番号で直接描く:
  0=黒 1=青 2=緑 3=濃い灰 4=茶 5=焦げ茶 6=肌 8=灰 9=濃い緑 10=明るい緑 11=クリーム 12=赤 13=くすんだ茶 14=黄 15=白
"""
import argparse
import re
import shutil
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_blocks_sheet as blocks  # noqa: E402  面の形(make_faces)・影の色(half)・近い色(nearest)

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "apps" / "zombie-td" / "app"
BLOCKS = ROOT / "apps" / "blocks" / "app"

SHEET_H = 40

# faces.pimg に残す段(ブロックの番号。26 = カーソル)。game.lua の FACE_ROWS と同じ並びにすること
# 水・石・草・土・丸石・砂・柵Lv1(12)・柵Lv2(14)・柵Lv3(15)・柵Lv4(16)・砂利・岩盤・カーソル
FACE_ROWS = [1, 2, 3, 4, 5, 11, 12, 14, 15, 16, 18, 22, 26]

# '.' = 透過。それ以外は16進1桁の色番号
ZOMBIE_TOP = [
    "...9999.....",
    "..922229....",
    "..922c2c....",
    "..9222229...",
    "...92229....",
    "....999.....",
    "...11111....",
    "..1111122222",
    "..1111199999",
    "..111111....",
    "..11.111....",
    "..111111....",
    "...11111....",
    "...ddddd....",
    "...dd.dd....",
]
RANGED_TOP = [
    "......888...",
    ".....8888...",
    "...999888...",
    "..922229.2..",
    "..922c2c.2..",
    "..9222229...",
    "...92229....",
    "...44444....",
    "..4444442...",
    "..4444442...",
    "..444444....",
    "..44.444....",
    "...44444....",
    "...ddddd....",
    "...dd.dd....",
]
ZOMBIE_LEGS = [
    [
        "...dd.dd....",
        "...dd.dd....",
        "...dd.dd....",
        "...dd.dd....",
        "...33.33....",
        "..333.333...",
        "............",
    ],
    [
        "..dd...dd...",
        "..dd...dd...",
        ".dd.....dd..",
        ".dd.....dd..",
        ".33.....33..",
        "333.....333.",
        "............",
    ],
]
HEAVY_TOP = [
    "....999999......",
    "...99999999.....",
    "...9999c9c9.....",
    "...99999999.....",
    "....999999......",
    "..3333333333....",
    ".333888888333...",
    ".338888888839999",
    ".338888888839999",
    ".33888888883....",
    ".33888888883....",
    ".3338888883.....",
    "..333333333.....",
    "..333333333.....",
    "..555555555.....",
    "..555....555....",
    "..555....555....",
    "..555....555....",
]
HEAVY_LEGS = [
    [
        "..555....555....",
        "..555....555....",
        "..555....555....",
        "..333....333....",
        ".3333...3333....",
        ".3333...3333....",
        "................",
        "................",
    ],
    [
        ".555......555...",
        ".555......555...",
        "555........555..",
        "333........333..",
        "3333.......3333.",
        "3333.......3333.",
        "................",
        "................",
    ],
]
BASE = [
    "..................1.........................",
    "..................11........................",
    "..................111.......................",
    "..................1.........................",
    "..................5.........................",
    "...............cccccccc.....................",
    ".............cccccccccccc...................",
    "...........cccccccccccccccc.................",
    ".........cccccccccccccccccccc...............",
    ".......cccccccccccccccccccccccc.............",
    ".....cccccccccccccccccccccccccccc...........",
    "...cccccccccccccccccccccccccccccccc.........",
    ".cccccccccccccccccccccccccccccccccccc.......",
    "cccccccccccccccccccccccccccccccccccccc......",
    "..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb44......",
    "..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb444.....",
    "..bb1111bbbbbbbbbbbbbbbbbbbbb1111bbb4444....",
    "..bb1771bbbbbbbbbbbbbbbbbbbbb1771bbb44444...",
    "..bb1771bbbbbbbbbbbbbbbbbbbbb1771bbb444444..",
    "..bb1111bbbbbbbbbbbbbbbbbbbbb1111bbb444444..",
    "..bbbbbbbbbbbbbbb55555bbbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb55555e5bbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb444444..",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb44444...",
    "..bbbbbbbbbbbbbb5555555bbbbbbbbbbbbb4444....",
    "..88888888888888888888888888888888884.......",
    "..8888888888888888888888888888888888........",
]
# 兵士(人間側)。上の15行 + 足の7行
MELEE_TOP = [
    "....888.....",
    "...88888....",
    "...8666.....",
    "...66606....",
    "...66666....",
    "....666.....",
    "...11111....",
    "..1111116...",
    "..11111.6888",
    "..111111....",
    "..111111....",
    "..444444....",
    "..111111....",
    "...11111....",
    "...55.55....",
]
HEALER_TOP = [
    "....222.....",
    "...22222....",
    "...2666.....",
    "...26606....",
    "...26666....",
    "....666.....",
    "...fffff..a.",
    "..ffcfff6aaa",
    "..fcccff.4a.",
    "..ffcfff.4..",
    "..ffffff.4..",
    "..ffffff.4..",
    "..ffffff.4..",
    "...fffff.4..",
    "...55.55.4..",
]
ARCHER_TOP = [
    "....999.....",
    "...99999....",
    "...9666.....",
    "...96606.4..",
    "...96666..4.",
    "....666...4.",
    "...99999..4.",
    "..9999996.4.",
    "..99999..64.",
    "..999999..4.",
    "..999999..4.",
    "..444444.4..",
    "..999999....",
    "...99999....",
    "...55.55....",
]
SOLDIER_LEGS = [
    [
        "...55.55....",
        "...55.55....",
        "...55.55....",
        "...55.55....",
        "...00.00....",
        "..000.000...",
        "............",
    ],
    [
        "..55...55...",
        "..55...55...",
        ".55.....55..",
        ".55.....55..",
        ".00.....00..",
        "000.....000.",
        "............",
    ],
]
# タワー。建設中の足場・弓塔・剣塔(上に兵士が立つ)
SCAFFOLD = [
    "5..................5",
    "55................55",
    "5.5..............5.5",
    "5..5............5..5",
    "5...5..........5...5",
    "5....5........5....5",
    "5.....5......5.....5",
    "5......5....5......5",
    "5.......5..5.......5",
    "55555555555555555555",
    "5.......5..5.......5",
    "5......5....5......5",
    "5.....5......5.....5",
    "5....5........5....5",
    "5...5..........5...5",
    "5..5............5..5",
    "5.5..............5.5",
    "55................55",
    "5..................5",
    "55555555555555555555",
    "5..................5",
    "5..................5",
    "88888888888888888888",
    "88888888888888888888",
]


def tower(top, level=1):
    """上の兵士(12x15)を、物見台(20x21)の上に載せる。Lv3 から脚が石、Lv4 は手すりが金"""
    base = [
        "dddddddddddddddddddd",
        "d4444444444444444445",
        "d4444444444444444445",
        "55555555555555555555",
        ".5..5..........5..5.",
        ".5...5........5...5.",
        ".5....5......5....5.",
        ".5.....5....5.....5.",
        ".5......5..5......5.",
        ".5.......55.......5.",
        ".5......5..5......5.",
        ".5.....5....5.....5.",
        ".5....5......5....5.",
        ".5...5........5...5.",
        ".5..5..........5..5.",
        ".5.5............5.5.",
        ".55..............55.",
        ".5................5.",
        ".5................5.",
        "8888888888888888888.",
        "8888888888888888888.",
    ]
    if level >= 3:
        base = base[:3] + [line.replace("5", "8") for line in base[3:19]] + base[19:]
    if level >= 4:
        base = [line.replace("d", "e") for line in base[:1]] + base[1:]
    if level >= 2:
        # 手すりの右端に旗
        flag = ["...ccc..", "...ccc..", "...5....", "...5...."]
        top = [line + "" for line in top]
        art = ["...." + line + "...." for line in top] + base
        for i, f in enumerate(flag):
            row = list(art[i])
            for x, ch in enumerate(f):
                if ch != ".":
                    row[12 + x] = ch
            art[i] = "".join(row)
        return art
    return ["...." + line + "...." for line in top] + base


def edit(art, recolor=None, points=None, rows=None):
    """絵の写しを作る。recolor = {元: 先}(rows の行だけ)、points = [(x, y, 色), ...]"""
    out = [list(line) for line in art]
    if recolor:
        for y in (rows if rows is not None else range(len(out))):
            out[y] = [recolor.get(c, c) for c in out[y]]
    for x, y, ch in points or []:
        out[y][x] = ch
    return ["".join(line) for line in out]


# 兵士のレベルごとの上半身(仕様の表: 近接 短剣→鎧付き短剣→鎧付き槍→強化鎧付き槍 / 回復は回復量・間隔 / 弓はダメージ・間隔)
def soldier_levels():
    spear = [(9, y, "4") for y in range(2, 14)] + [(9, 0, "8"), (9, 1, "8"), (8, 1, "8"), (10, 1, "8")]
    no_dagger = [(9, 8, "."), (10, 8, "."), (11, 8, ".")]
    melee2 = edit(MELEE_TOP, {"1": "8"}, rows=range(6, 11))                     # 鎧
    melee3 = edit(melee2, points=no_dagger + spear)                              # 槍
    melee4 = edit(melee3, {"8": "3"}, rows=range(6, 11))                         # 強化鎧(濃い灰と金の縁)
    melee4 = edit(melee4, points=[(x, 6, "e") for x in range(3, 8)] + [(x, 0, "e") for x in range(4, 7)])
    archer2 = edit(ARCHER_TOP, {"4": "c"}, rows=[11])                            # 赤い帯
    archer3 = edit(archer2, points=[(1, y, "5") for y in range(5, 11)] + [(1, 4, "8")])   # 背中の矢筒
    archer4 = edit(archer3, {"9": "8"}, rows=[0, 1])                             # 兜
    archer4 = edit(archer4, {"4": "e"}, rows=range(3, 12))                       # 金の弓
    healer2 = edit(HEALER_TOP, {"2": "a"}, rows=range(0, 5))                     # 明るい頭巾
    healer3 = edit(healer2, points=[(10, 5, "e"), (9, 6, "e"), (11, 6, "e")])     # 杖が光る
    healer4 = edit(healer3, {"a": "e"}, rows=range(0, 5))                        # 金の頭巾
    return ([MELEE_TOP, melee2, melee3, melee4], [HEALER_TOP, healer2, healer3, healer4],
            [ARCHER_TOP, archer2, archer3, archer4])


# バリケードのテクスチャ(16x16)。'.' = 穴、それ以外は palette.lua の色番号(16進)
def wall_textures(level):
    side = [["." for _ in range(16)] for _ in range(16)]
    top = [["." for _ in range(16)] for _ in range(16)]
    def put(t, x, y, c):
        if 0 <= x < 16 and 0 <= y < 16:
            t[y][x] = c
    if level == 1:      # 丸太: 両端の杭と横の丸太2本
        for y in range(16):
            for x in (1, 2, 13, 14):
                put(side, x, y, "5")
        for y0 in (3, 10):
            for x in range(16):
                put(side, x, y0, "6"); put(side, x, y0 + 1, "4"); put(side, x, y0 + 2, "4"); put(side, x, y0 + 3, "5")
        for y0 in (3, 10):
            for x in range(16):
                put(top, x, y0, "6"); put(top, x, y0 + 1, "4"); put(top, x, y0 + 2, "5")
        for y in range(16):
            for x in (1, 13):
                put(top, x, y, "5")
    elif level == 2:    # 木材: 柱と板3枚
        for y in range(16):
            for x in (0, 1, 14, 15):
                put(side, x, y, "d")
        for y0 in (1, 6, 11):
            for x in range(16):
                put(side, x, y0, "6"); put(side, x, y0 + 1, "6"); put(side, x, y0 + 2, "6"); put(side, x, y0 + 3, "4")
        for y0 in (1, 6, 11):
            for x in range(16):
                put(top, x, y0, "6"); put(top, x, y0 + 1, "6"); put(top, x, y0 + 2, "4")
        for y in range(16):
            for x in (0, 15):
                put(top, x, y, "d")
    elif level == 3:    # 木材と石: 下半分は石、上は板2枚
        for y in range(8, 16):
            for x in range(16):
                put(side, x, y, "3" if y in (8, 12) or (x + (4 if y > 12 else 0)) % 8 == 0 else "8")
        for x in range(6, 10):
            for y in range(9, 12):
                put(side, x, y, ".")
        for y0 in (1, 5):
            for x in range(16):
                put(side, x, y0, "6"); put(side, x, y0 + 1, "6"); put(side, x, y0 + 2, "4")
        for y in range(16):
            for x in range(16):
                if y % 5 != 4:
                    put(top, x, y, "8" if y >= 8 else "6")
                if y >= 8 and x % 8 == 0:
                    put(top, x, y, "3")
    else:               # 石: 石積みに矢狭間(縦長の穴)が2つ
        for y in range(16):
            for x in range(16):
                put(side, x, y, "3" if y % 4 == 3 or (x + (4 if (y // 4) % 2 else 0)) % 8 == 7 else "8")
        for x0 in (3, 11):
            for x in range(x0, x0 + 2):
                for y in range(3, 12):
                    put(side, x, y, ".")
        for y in range(16):
            for x in range(16):
                put(top, x, y, "3" if y % 4 == 3 or (x + (4 if (y // 4) % 2 else 0)) % 8 == 7 else "8")
        for x in range(4, 12):
            for y in range(6, 10):
                put(top, x, y, ".")
    return top, side
WALLS = {12: 1, 14: 2, 15: 3, 16: 4}   # ブロック番号 → レベル


# アイコン(既定のパレット: 0=黒 2=暗い緑 7=明るい灰 8=暗い灰 10=緑 12=赤 14=黄 15=白)
ICON = [
    "................................................",
    "................................................",
    "................................................",
    "................22222222222222..................",
    "..............222aaaaaaaaaaa222.................",
    ".............22aaaaaaaaaaaaaaaa22...............",
    "............2aaaaaaaaaaaaaaaaaaaa2..............",
    "...........2aaaaaaaaaaaaaaaaaaaaaa2.............",
    "...........2aaaaaaaaaaaaaaaaaaaaaa2.............",
    "..........2aaaaaaaaaaaaaaaaaaaaaaaa2............",
    "..........2aaa0000aaaaaaaa0000aaaaa2............",
    "..........2aa0cccc0aaaaaa0cccc0aaaa2............",
    "..........2aa0cccc0aaaaaa0cccc0aaaa2............",
    "..........2aaa0000aaaaaaaa0000aaaaa2............",
    "..........2aaaaaaaaaaaaaaaaaaaaaaaa2............",
    "..........2aaaaaaaaaa22aaaaaaaaaaaa2............",
    "...........2aaaaaaaaaaaaaaaaaaaaaa2.............",
    "...........2aaa00000000000000aaaaa2.............",
    "............2aa0f0f0f0f0f0f00aaaa2..............",
    ".............2aa00000000000000aa2...............",
    "..............22aaaaaaaaaaaaaa22................",
    "................22222222222222..................",
    "................................................",
    "................................................",
    "........8888888888888888888888888888............",
    "........8777777777777777777777777778............",
    "........87788887777888877778888777788...........",
    "........8777777777777777777777777778............",
    "........8888888888888888888888888888............",
    "..........8c8..........8c8..........8c8.........",
    "..........8c8..........8c8..........8c8.........",
    "..........888..........888..........888.........",
    "................................................",
    "................................................",
    "............................e...................",
    "...........................eee..................",
    "..........................eeeee.................",
    ".........................e00e00e................",
    "........................eeeeeeeee...............",
    "................................................",
]


def pix(ch):
    return 0 if ch == "." else int(ch, 16)


def build_units():
    w = 12 * 4 + 16 * 2 + 44 + 12 * 6 + 20 * 3
    rows = [[0] * w for _ in range(SHEET_H * 4)]

    def put(art, ox, level=1):
        oy = SHEET_H * level - len(art)   # その段(レベル)の下に寄せる
        for y, line in enumerate(art):
            assert len(line) == len(art[0]), (line, len(line), len(art[0]))
            for x, ch in enumerate(line):
                rows[oy + y][ox + x] = pix(ch)

    for i, legs in enumerate(ZOMBIE_LEGS):
        put(ZOMBIE_TOP + legs, 12 * i)
        put(RANGED_TOP + legs, 24 + 12 * i)
    for i, legs in enumerate(HEAVY_LEGS):
        put(HEAVY_TOP + legs, 48 + 16 * i)
    put(BASE, 80)
    melee, healer, archer = soldier_levels()
    for lv in range(1, 5):
        for i, legs in enumerate(SOLDIER_LEGS):
            put(melee[lv - 1] + legs, 124 + 12 * i, lv)
            put(healer[lv - 1] + legs, 148 + 12 * i, lv)
            put(archer[lv - 1] + legs, 172 + 12 * i, lv)
        put(tower(archer[lv - 1], lv), 216, lv)
        put(tower(melee[lv - 1], lv), 236, lv)
    put(SCAFFOLD, 196)
    return rows


def build_icon():
    rows = []
    for y in range(48):
        line = ICON[y] if y < len(ICON) else "." * 48
        assert len(line) == 48, (y, len(line))
        rows.append([15 if ch == "." else int(ch, 16) for ch in line])
    return rows


def rle(rows):
    out = bytearray()
    run, prev = 0, None
    for row in rows:
        for v in row:
            if run and v == prev and run < 255:
                run += 1
                continue
            if run:
                out += bytes((run, prev))
            prev, run = v, 1
    if run:
        out += bytes((run, prev))
    return bytes(out)


def read_pimg(path):
    data = path.read_bytes()
    w, h, _ = struct.unpack("<HHB", data[:5])
    px = []
    for i in range(5, len(data), 2):
        px += [data[i + 1]] * data[i]
    return [px[y * w:(y + 1) * w] for y in range(h)]


def read_palette(path):
    """palette.lua の 1〜14番の色 → 16色のパレット(0=黒 15=白)"""
    cols = [tuple(map(int, m)) for m in re.findall(r"\{ *(\d+), *(\d+), *(\d+) *\}", path.read_text(encoding="utf-8"))]
    assert len(cols) == 14, cols
    return [(0, 0, 0)] + cols + [(255, 255, 255)]


def build_faces():
    """「ブロック」の faces.pimg の、柵に使う段を差し替える"""
    sheet = read_pimg(BLOCKS / "faces.pimg")
    pal = read_palette(BLOCKS / "palette.lua")

    def rgb(ch):
        return None if ch == "." else pal[int(ch, 16)]

    def idx(c):
        return 0 if c is None else blocks.nearest(c, pal, skip=(0,))

    def shade(f, which):
        return [[blocks.half(c) if c is not None and which(y, x) else c for x, c in enumerate(row)]
                for y, row in enumerate(f)]

    for block, level in WALLS.items():
        top, side = wall_textures(level)
        t, lf, rf = blocks.make_faces([[rgb(c) for c in r] for r in top], [[rgb(c) for c in r] for r in side],
                                      [[rgb(c) for c in r] for r in side])
        every = lambda y, x: True
        faces = [t, shade(t, every), shade(t, lambda y, x: y <= 7), shade(t, lambda y, x: y > 7),
                 lf, shade(lf, every), shade(lf, lambda y, x: y - x // 2 <= x), shade(lf, lambda y, x: y - x // 2 > x),
                 shade(rf, every), rf]
        y0 = (block - 1) * blocks.ROW_H
        for y in range(blocks.ROW_H):
            sheet[y0 + y] = sheet[y0 + y][:]
            for x in range(blocks.SHEET_W):
                sheet[y0 + y][x] = 0
        for f, x0 in zip(faces, blocks.COLS):
            for y, row in enumerate(f):
                for x, c in enumerate(row):
                    sheet[y0 + y][x0 + x] = idx(c)
    out = []
    for block in FACE_ROWS:
        y0 = (block - 1) * blocks.ROW_H
        out += sheet[y0:y0 + blocks.ROW_H]
    return out


def write(path, rows, transparent):
    with open(path, "wb") as f:
        f.write(struct.pack("<HHB", len(rows[0]), len(rows), 1 if transparent else 0))
        f.write(rle(rows))
    print(f"{path} ({len(rows[0])}x{len(rows)}) を書きました")


def main():
    ap = argparse.ArgumentParser(description="「ゾンビTD」の絵を作る")
    ap.add_argument("--dir", type=Path, default=APP)
    args = ap.parse_args()
    args.dir.mkdir(parents=True, exist_ok=True)
    write(args.dir / "units.pimg", build_units(), True)
    write(args.dir / "icon.pimg", build_icon(), False)
    shutil.copyfile(BLOCKS / "palette.lua", args.dir / "palette.lua")
    print(f"{args.dir / 'palette.lua'} を「ブロック」から写しました")
    write(args.dir / "faces.pimg", build_faces(), True)


if __name__ == "__main__":
    main()
