#!/usr/bin/env python3
"""UDPツール(apps/udp-tool/app/)のランチャのアイコン icon.pimg(48x48)を作る。標準ライブラリのみ。

緑の角丸の板に、右向きの白い矢印(送る)と左向きの黄色い矢印(受ける)。
色はpico-osの16色パレットの番号で直接描く(generate_pimg.py と同じ .pimg 形式)。

    python3 script/assets/generate_udp_tool_icon.py            # 既定の場所へ書く
    python3 script/assets/generate_udp_tool_icon.py out.pimg
"""
import argparse
import struct
from pathlib import Path

SIZE = 48
DKGREEN, WHITE, YELLOW = 2, 15, 14


def build():
    rows = [[WHITE] * SIZE for _ in range(SIZE)]
    # 角丸の板(半径8)
    r = 8
    for y in range(2, 46):
        for x in range(2, 46):
            dx = max(2 + r - x, 0, x - (45 - r))
            dy = max(2 + r - y, 0, y - (45 - r))
            if dx * dx + dy * dy <= r * r:
                rows[y][x] = DKGREEN
    # 上: 右向きの矢印(送る)
    for y in range(15, 19):
        for x in range(10, 32):
            rows[y][x] = WHITE
    for k in range(0, 8):
        for y in range(17 - k, 17 + k):
            rows[y][38 - k] = WHITE
    # 下: 左向きの矢印(受ける)
    for y in range(29, 33):
        for x in range(16, 38):
            rows[y][x] = YELLOW
    for k in range(0, 8):
        for y in range(31 - k, 31 + k):
            rows[y][9 + k] = YELLOW
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
    ap = argparse.ArgumentParser(description="UDPツールのアイコン(icon.pimg、48x48)を作る")
    ap.add_argument("output", nargs="?", type=Path, default=root / "apps/udp-tool/app/icon.pimg")
    args = ap.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        f.write(struct.pack("<HHB", SIZE, SIZE, 0))
        f.write(rle(build()))
    print(f"{args.output} ({SIZE}x{SIZE}) を書きました")


if __name__ == "__main__":
    main()
