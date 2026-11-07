#!/usr/bin/env python3
"""HAパネル(apps/ha-panel/app/)のランチャのアイコン icon.pimg(48x48)を作る。標準ライブラリのみ。

水色の角丸の板に白い家と、戸口の上の電波の弧(家の機器と繋がっている印)。
色はpico-osの16色パレットの番号で直接描く(generate_pimg.py と同じ .pimg 形式)。

    python3 script/assets/generate_ha_panel_icon.py            # 既定の場所へ書く
    python3 script/assets/generate_ha_panel_icon.py out.pimg
"""
import argparse
import math
import struct
from pathlib import Path

SIZE = 48
NAVY, CYAN, WHITE = 1, 11, 15


def build():
    rows = [[WHITE] * SIZE for _ in range(SIZE)]
    # 角丸の板(半径8)
    r = 8
    for y in range(2, 46):
        for x in range(2, 46):
            dx = max(2 + r - x, 0, x - (45 - r))
            dy = max(2 + r - y, 0, y - (45 - r))
            if dx * dx + dy * dy <= r * r:
                rows[y][x] = CYAN
    # 家: 屋根(三角)と壁
    for y in range(10, 24):
        half = y - 10
        for x in range(24 - half, 24 + half):
            rows[y][x] = WHITE
    for y in range(24, 38):
        for x in range(12, 36):
            rows[y][x] = WHITE
    # 戸口
    for y in range(28, 38):
        for x in range(21, 27):
            rows[y][x] = NAVY
    # 戸口の上の電波(繋がっている印)
    ox, oy = 23.5, 27.5
    for y in range(14, 27):
        for x in range(14, 34):
            d = math.hypot(x - ox, y - oy)
            ang = math.degrees(math.atan2(x - ox, oy - y))
            if abs(ang) <= 45 and (4 <= d <= 5.6 or 8 <= d <= 9.6):
                rows[y][x] = NAVY
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
    ap = argparse.ArgumentParser(description="HAパネルのアイコン(icon.pimg、48x48)を作る")
    ap.add_argument("output", nargs="?", type=Path, default=root / "apps/ha-panel/app/icon.pimg")
    args = ap.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(struct.pack("<HHB", SIZE, SIZE, 0))
        f.write(rle(build()))
    print(f"{args.output} ({SIZE}x{SIZE}) を書きました")


if __name__ == "__main__":
    main()
