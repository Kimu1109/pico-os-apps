#!/usr/bin/env python3
"""
generate_blocks_sheet.py
------------------------
Luaアプリ「ブロック」(apps/blocks/app/。TheScienceElf氏の Blocks-TI-84 を
pico-os へ移したもの)の絵を作る。標準ライブラリのみ(PNGも自前で読む)。

元の絵は script/assets/blocks_assets/ にある Blocks-TI-84 の TextureMap.png(16x16のテクスチャを
上面/左面/右面の3段で23種類並べたもの)と player.png(カーソル)。どちらも MIT ライセンス
(script/assets/blocks_assets/LICENSE-Blocks-TI-84.txt)。

作るもの:
    faces.pimg   ブロックの面の絵(透過つき)。1種類につき高さ23pxの1段で、横に
                     x=0   上面 日なた      x=32  上面 影       (32x15)
                     x=64  上面 奥半分が影  x=96  上面 手前半分が影
                     x=128 左面 日なた      x=144 左面 影       (16x23)
                     x=160 左面 上半分が影  x=176 左面 下半分が影
                     x=192 右面 影          x=208 右面 日なた   (16x23)
                 を並べる。段の番号 = ブロックの番号 - 1(1=水, 2=石 … 24=金, 25=松明, 26=カーソル)。
                 右面は日の光が当たらないので影の絵だけを使うが、松明の光が当たると日なたの絵(x=208)になる。
                 松明の段は、松明の絵(32x31)を上(高さ8より上)・左半分・右半分に分けて、上面・左面・右面の
                 場所に置く(どの列も同じ絵。影も明るさも無く、いつもそのまま描く)。
                 面の形は元の convert_textures.py と同じ(上面は2:1のひし形、横の面は2pxごとに1段ずらす)。
                 影は元と同じく「明るさ半分の色」で、面を光の向きの対角線で2つの三角形に分けて
                 半分ずつ影にする(元の sprites/Masks の shadow top / shadow bottom)。
                 上面は x+z が一定の線(画面では横の中央線)で奥/手前に、左面は y=z の線
                 (テクスチャの対角線)で上/下に分ける。
    palette.lua  アプリが pico.set_palette で入れる色(1〜14番)と、空・水・UIに使う番号。
                 テクスチャの色(日なたと、明るさ半分の影)と空・水の色を、よく出るブロック(草・土・石・
                 葉・砂…)ほど重く数えて、Lab色空間の k-means で14色にまとめる。
    icon.pimg    ランチャのアイコン(48x48、既定のパレット)。

使い方:
    python3 script/assets/generate_blocks_sheet.py                   # 既定の場所へ書く
    python3 script/assets/generate_blocks_sheet.py --preview p.ppm   # 確認用のPPM(2倍)も書く
"""

import argparse
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "script" / "assets" / "blocks_assets"
APP = ROOT / "apps" / "blocks" / "app"

# 既定のパレット(src/gui/core/GFX_Functions.hpp の DEFAULT_COLORS)
DEFAULT_PALETTE = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0x80), (0x00, 0x80, 0x00), (0x00, 0x80, 0x80),
    (0x80, 0x00, 0x00), (0x80, 0x00, 0x80), (0x80, 0x80, 0x00), (0xD3, 0xD3, 0xD3),
    (0x80, 0x80, 0x80), (0x00, 0x00, 0xFF), (0x00, 0xFF, 0x00), (0x00, 0xFF, 0xFF),
    (0xFF, 0x00, 0x00), (0xFF, 0x00, 0xFF), (0xFF, 0xFF, 0x00), (0xFF, 0xFF, 0xFF),
]

SKY = (192, 240, 255)     # 元のゲームの空の色
WATER = (56, 96, 232)     # 水(ディザで半透明に見せる)
TEX_COUNT = 23            # 石(2)〜金(24)
B_GRASS = 3
ROW_H = 23                # 1種類ぶんの段の高さ
SHEET_W = 224
# 段の中の各絵の x(上: 日なた/影/奥半分/手前半分、左: 日なた/影/上半分/下半分、右: 影/日なた)
COLS = (0, 32, 64, 96, 128, 144, 160, 176, 192, 208)

# 松明(32x31 の絵の中。床(ブロックの底面の真ん中 y=23)に立つ棒と炎)。. は透過
# r=赤 y=黄 w=白 b=木の明るい側 d=木の暗い側
TORCH_ART = {
    3:  "..rr..",
    4:  ".ryyr.",
    5:  ".ryyr.",
    6:  "ryywyr",
    7:  "ryywyr",
    8:  "ryyyyr",
    9:  ".ryyr.",
    10: "..rr..",
}
TORCH_STICK = (11, 23)      # 棒の y の範囲(両端を含む)
TORCH_X = 13                # 炎の左端の x(棒は x=14〜17)
TORCH_COLORS = {"r": (204, 43, 10), "y": (236, 229, 70), "w": (255, 255, 255),
                "b": (175, 140, 80), "d": (107, 93, 65)}
# よく出るブロックの重み(石=0 草=1 土=2 丸石=3 板=4 … 葉=8 砂=9)
TEX_WEIGHT = {0: 3, 1: 8, 2: 4, 3: 2, 4: 2, 7: 2, 8: 3, 9: 3}


# ---------------------------------------------------------------- PNG(8bit、パレット/RGBA)

def read_png(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", path
    pos, idat, plte, trns = 8, b"", None, None
    w = h = ctype = 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and interlace == 0 and ctype in (3, 6), (path, depth, ctype)
        elif kind == b"PLTE":
            plte = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        elif kind == b"tRNS":
            trns = body
        elif kind == b"IDAT":
            idat += body
    raw = zlib.decompress(idat)
    bpp = 1 if ctype == 3 else 4
    stride = w * bpp
    rows, prev = [], bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    px = []
    for line in rows:
        out = []
        for x in range(w):
            if ctype == 3:
                i = line[x]
                alpha = trns[i] if trns and i < len(trns) else 255
                out.append(None if alpha < 128 else plte[i])
            else:
                r, g, b, a = line[x * 4:x * 4 + 4]
                out.append(None if a < 128 else (r, g, b))
        px.append(out)
    return w, h, px


# ---------------------------------------------------------------- 面の形(元の convert_textures.py と同じ)

def top_rows():
    """上面のひし形: 行r(0〜14)の左半分の幅"""
    return [2 * (r + 1) if r <= 7 else 2 * (15 - r) for r in range(15)]


def make_faces(top, left, right):
    """16x16の上面/左面/右面 → (上面32x15, 左面16x23, 右面16x23)。None は透過"""
    t = [[None] * 32 for _ in range(15)]
    for y, half in enumerate(top_rows()):
        for x in range(16 - half, 16 + half):
            # 画面(x-16, y) = M・テクスチャ(u, v)、M = [[1, -1], [0.5, 0.5]] の逆写像
            dx = x - 16 + 0.5
            dy = y + 0.5
            u = int(dy + dx / 2)
            v = int(dy - dx / 2)
            t[y][x] = top[min(max(v, 0), 15)][min(max(u, 0), 15)]
    lf = [[None] * 16 for _ in range(23)]
    rf = [[None] * 16 for _ in range(23)]
    for i in range(8):
        for c in (2 * i, 2 * i + 1):
            for k in range(16):
                lf[i + k][c] = left[k][c]           # 元: out[8+i : 24+i, 2i:2i+2]
                rf[7 - i + k][c] = right[k][c]      # 元: out[15-i : 31-i, 16+2i:18+2i]
    return t, lf, rf


def half(c):
    return None if c is None else (c[0] // 2, c[1] // 2, c[2] // 2)


def dither(face, color):
    """水: 市松模様の半分だけ色を置く(残りは透過で、奥が透けて見える)"""
    return [[color if c is not None and (x + y) % 2 == 0 else None for x, c in enumerate(row)]
            for y, row in enumerate(face)]


# ---------------------------------------------------------------- 減色

_LAB = {}


def lab(c):
    """sRGB → CIE L*a*b*(D65)。色の近さはこの空間の距離で測る"""
    v = _LAB.get(c)
    if v is not None:
        return v
    def lin(u):
        u /= 255
        return u / 12.92 if u <= 0.04045 else ((u + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(u) for u in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(x), f(y), f(z)
    v = (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    _LAB[c] = v
    return v


def dist(a, b):
    la, lb = lab(a), lab(b)
    return (la[0] - lb[0]) ** 2 + (la[1] - lb[1]) ** 2 + (la[2] - lb[2]) ** 2


def kmeans(samples, fixed, k, iters=40):
    """samples: {color: 重み}。fixed は動かさない中心。全部で len(fixed)+k 色"""
    colors = sorted(samples, key=lambda c: -samples[c])
    centers = list(fixed)
    # 決定的な k-means++ 風の初期値: いちばん遠い(重み付き)色を順に足す
    while len(centers) < len(fixed) + k:
        best, best_d = None, -1
        for c in colors:
            d = min(dist(c, z) for z in centers) * samples[c]
            if d > best_d:
                best, best_d = c, d
        centers.append(best)
    for _ in range(iters):
        acc = [[0, 0, 0, 0] for _ in centers]
        for c in colors:
            j = min(range(len(centers)), key=lambda i: dist(c, centers[i]))
            w = samples[c]
            acc[j][0] += c[0] * w
            acc[j][1] += c[1] * w
            acc[j][2] += c[2] * w
            acc[j][3] += w
        moved = False
        for j in range(len(fixed), len(centers)):
            if acc[j][3]:
                n = tuple(round(acc[j][i] / acc[j][3]) for i in range(3))
                if n != centers[j]:
                    centers[j], moved = n, True
        if not moved:
            break
    return centers


def nearest(color, palette, skip=()):
    return min((i for i in range(len(palette)) if i not in skip), key=lambda i: dist(color, palette[i]))


# ---------------------------------------------------------------- 本体

def build():
    w, _, tex = read_png(ASSETS / "TextureMap.png")
    assert w // 16 >= TEX_COUNT
    _, _, cur = read_png(ASSETS / "player.png")

    def cut(x0, y0):
        return [row[x0:x0 + 16] for row in tex[y0:y0 + 16]]

    # 段ごとの面: COLS の順の9枚
    def shade(f, which):
        """which(行, 列) が真の画素だけ明るさ半分にする"""
        return [[half(c) if c is not None and which(y, x) else c for x, c in enumerate(row)]
                for y, row in enumerate(f)]

    def faces9(t, lf, rf):
        far = lambda y, x: y <= 7                    # 上面の奥半分(画面で上の三角形)
        near = lambda y, x: y > 7
        up = lambda y, x: y - x // 2 <= x            # 左面: テクスチャの行 k = y - x//2、k <= 列 が上半分
        low = lambda y, x: y - x // 2 > x
        every = lambda y, x: True
        return [t, shade(t, every), shade(t, far), shade(t, near),
                lf, shade(lf, every), shade(lf, up), shade(lf, low), shade(rf, every), rf]

    rows = []
    tw, lw, rw = make_faces([[WATER] * 16] * 16, [[WATER] * 16] * 16, [[WATER] * 16] * 16)
    tw, lw, rw = dither(tw, WATER), dither(lw, WATER), dither(rw, WATER)
    # 水面(真上が水でない水): 元の WATER_HALF と同じく、水の高さを 2px 低く見せる。
    # 横の面はテクスチャの上2行を抜いた絵(左面 x=144・右面 x=160)、上面は描くときに2px下げる
    lw_cut = [[c if y - x // 2 >= 2 else None for x, c in enumerate(row)] for y, row in enumerate(lw)]
    rw_cut = [[c if y - 7 + x // 2 >= 2 else None for x, c in enumerate(row)] for y, row in enumerate(rw)]
    rows.append([tw] * 4 + [lw, lw_cut, rw_cut, lw, rw, rw])
    weights = []
    for i in range(TEX_COUNT):
        t, lf, rf = make_faces(cut(i * 16, 0), cut(i * 16, 16), cut(i * 16, 32))
        rows.append(faces9(t, lf, rf))
        weights.append(TEX_WEIGHT.get(i, 1))
    # 松明: 32x31 の絵を、上(y<8)は上面の場所、残りは左半分・右半分を横の面の場所へ
    art = [[None] * 32 for _ in range(31)]
    for y, line in TORCH_ART.items():
        for i, ch in enumerate(line):
            if ch != ".":
                art[y][TORCH_X + i] = TORCH_COLORS[ch]
    for y in range(TORCH_STICK[0], TORCH_STICK[1] + 1):
        for x, ch in zip(range(14, 18), "bbdd"):
            art[y][x] = TORCH_COLORS[ch]
    tt = [[art[y][x] if y < 8 else None for x in range(32)] for y in range(15)]
    tl = [[art[y + 8][x] for x in range(16)] for y in range(23)]
    tr = [[art[y + 8][x + 16] for x in range(16)] for y in range(23)]
    # 減色の重み(weights)は石〜金の23種だけ。松明の色はパレットの近い色を使う
    rows.append([tt] * 4 + [tl] * 4 + [tr, tr])
    # カーソル: player.png の上半分が上面、下半分が横の面
    ct, cl, cr = make_faces([r[:16] for r in cur[:16]], [r[:16] for r in cur[16:32]],
                            [r[:16] for r in cur[16:32]])
    rows.append([ct] * 4 + [cl] * 4 + [cr, cr])

    # 減色: テクスチャ(日なた+影)と空・水。日なたの面(上・左)と影の面(上・左・右)を数える
    samples = {}
    for faces, w in zip(rows[1:-1], weights):
        for f in (faces[0], faces[4], faces[1], faces[5], faces[8]):
            for row in f:
                for c in row:
                    if c is not None:
                        samples[c] = samples.get(c, 0) + w
    samples[SKY] = samples.get(SKY, 0) + 2000
    fixed = [(0, 0, 0), (255, 255, 255), SKY, WATER]
    centers = kmeans(samples, fixed, 16 - len(fixed))

    # 1〜14番へ並べる: 既定のパレットの近い番号に置く(ステータスバー等の色がなるべく変わらないように)
    free = centers[2:]
    pal = [None] * 16
    pal[0], pal[15] = (0, 0, 0), (255, 255, 255)
    left = list(range(1, 15))
    pairs = sorted(((dist(c, DEFAULT_PALETTE[i]), ci, i) for ci, c in enumerate(free) for i in left))
    used_c, used_i = set(), set()
    for _, ci, i in pairs:
        if ci in used_c or i in used_i:
            continue
        pal[i] = free[ci]
        used_c.add(ci)
        used_i.add(i)

    # 面の絵を番号にする(テクスチャの黒は透過の0番にしない)
    def idx(c):
        if c is None:
            return 0
        if c == (255, 255, 255):
            return 15
        return nearest(c, pal, skip=(0,))

    sheet_h = ROW_H * len(rows)
    sheet = [[0] * SHEET_W for _ in range(sheet_h)]
    for r, faces in enumerate(rows):
        y0 = r * ROW_H
        for f, x0 in zip(faces, COLS):
            for y, row in enumerate(f):
                for x, c in enumerate(row):
                    sheet[y0 + y][x0 + x] = idx(c)

    # UIの色(空と水の色は使わない)
    ui_skip = (0, 15, pal.index(SKY), pal.index(WATER))
    info = {
        "sky": pal.index(SKY), "water": pal.index(WATER),
        "dark": nearest((48, 48, 48), pal, skip=ui_skip[2:]), "mid": nearest((128, 128, 128), pal, skip=ui_skip),
        "light": nearest((210, 205, 180), pal, skip=ui_skip),
        "accent": nearest((220, 40, 20), pal, skip=ui_skip),
        "green": nearest((60, 170, 60), pal, skip=ui_skip),
    }

    # アイコン(既定のパレット): 空色の地に、草のブロックを1.5倍で
    block = [[None] * 32 for _ in range(31)]
    faces = rows[B_GRASS - 1]
    for f, (dx, dy) in ((faces[0], (0, 0)), (faces[2], (0, 8)), (faces[4], (16, 8))):
        for y, line in enumerate(f):
            for x, c in enumerate(line):
                if c is not None:
                    block[dy + y][dx + x] = c
    icon = [[11] * 48 for _ in range(48)]
    for y in range(46):
        for x in range(48):
            c = block[y * 2 // 3][x * 2 // 3]
            if c is not None:
                # 既定のパレットは原色ばかりなので、彩度を上げてから一番近い色を選ぶ(草が灰色にならないように)
                m = sum(c) / 3
                v = tuple(min(255, max(0, round(m + (k - m) * 2))) for k in c)
                icon[y + 1][x] = nearest(v, DEFAULT_PALETTE, skip=(11,))
    return sheet, pal, info, icon


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


def write_pimg(path, rows, transparent):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<HHB", len(rows[0]), len(rows), 1 if transparent else 0))
        f.write(rle(rows))
    print(f"{path} ({len(rows[0])}x{len(rows)}) を書きました")


def write_palette(path, pal, info):
    lines = [
        "-- script/assets/generate_blocks_sheet.py が作る。手で直さないこと。",
        "-- 1〜14番の色(pico.set_palette で入れる)と、空・水・UIに使う番号。",
        "return {",
        "    colors = {",
    ]
    for i in range(1, 15):
        lines.append("        { %d, %d, %d }," % pal[i])
    lines.append("    },")
    for k in ("sky", "water", "dark", "mid", "light", "accent", "green"):
        lines.append(f"    {k} = {info[k]},")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"{path} を書きました")


def main():
    ap = argparse.ArgumentParser(description="「ブロック」の絵(faces.pimg / palette.lua / icon.pimg)を作る")
    ap.add_argument("--dir", type=Path, default=APP)
    ap.add_argument("--preview", type=Path, help="確認用のPPM(2倍、透過は空色)")
    args = ap.parse_args()
    sheet, pal, info, icon = build()
    write_pimg(args.dir / "faces.pimg", sheet, True)
    write_pimg(args.dir / "icon.pimg", icon, False)
    write_palette(args.dir / "palette.lua", pal, info)
    if args.preview:
        h, w = len(sheet), len(sheet[0])
        with open(args.preview, "wb") as f:
            f.write(f"P6\n{w * 2} {h * 2}\n255\n".encode())
            for row in sheet:
                line = b"".join(bytes(pal[v] if v else pal[info["sky"]]) * 2 for v in row)
                f.write(line * 2)


if __name__ == "__main__":
    main()
