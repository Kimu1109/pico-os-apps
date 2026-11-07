#!/usr/bin/env python3
"""MQTTリモコン(apps/mqtt-remote/app/)のランチャのアイコン icon.pimg(48x48)を作る。標準ライブラリのみ。

紺の角丸の板に、白い電源の印と、右上に電波の弧(遠くの機器を点け消しするリモコンらしさ)。
色はpico-osの16色パレットの番号で直接描く(generate_pimg.py と同じ .pimg 形式)。

    python3 script/assets/generate_mqtt_remote_icon.py            # 既定の場所へ書く
    python3 script/assets/generate_mqtt_remote_icon.py out.pimg
"""
import argparse
import math
import struct
from pathlib import Path

SIZE = 48
NAVY, CYAN, WHITE, YELLOW = 1, 11, 15, 14


def build():
    rows = [[WHITE] * SIZE for _ in range(SIZE)]
    # 角丸の板(半径8)
    r = 8
    for y in range(2, 46):
        for x in range(2, 46):
            dx = max(2 + r - x, 0, x - (45 - r))
            dy = max(2 + r - y, 0, y - (45 - r))
            if dx * dx + dy * dy <= r * r:
                rows[y][x] = NAVY
    # 電源の印: 上の開いた輪と縦棒
    cx, cy = 21.5, 26.5
    for y in range(SIZE):
        for x in range(SIZE):
            d = math.hypot(x - cx, y - cy)
            ang = math.degrees(math.atan2(x - cx, cy - y))  # 真上が0度
            if 9 <= d <= 12.5 and abs(ang) > 40:
                rows[y][x] = WHITE
    for y in range(11, 27):
        for x in range(20, 24):
            rows[y][x] = WHITE
    # 右上の電波(2本の弧)
    ox, oy = 33.5, 14.5
    for y in range(SIZE):
        for x in range(SIZE):
            d = math.hypot(x - ox, y - oy)
            ang = math.degrees(math.atan2(x - ox, oy - y))
            if 0 <= ang <= 90 and (4 <= d <= 5.6 or 8 <= d <= 9.6):
                rows[y][x] = YELLOW
    rows[15][33] = rows[15][34] = rows[14][33] = rows[14][34] = YELLOW
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
    ap = argparse.ArgumentParser(description="MQTTリモコンのアイコン(icon.pimg、48x48)を作る")
    ap.add_argument("output", nargs="?", type=Path, default=root / "apps/mqtt-remote/app/icon.pimg")
    args = ap.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(struct.pack("<HHB", SIZE, SIZE, 0))
        f.write(rle(build()))
    print(f"{args.output} ({SIZE}x{SIZE}) を書きました")


if __name__ == "__main__":
    main()
