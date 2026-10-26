#!/usr/bin/env python3
"""
generate_pimg.py
-----------------
汎用画像（PNG/JPG等）を pico-os 用の独自フォーマット .pimg に変換する。

.pimg フォーマット仕様:
    header:
        width      : u16 (little-endian)
        height     : u16 (little-endian)
        flags      : u8   bit0 = has_transparent_index (index 0 を透過として扱う)
    body:
        (run_length: u8, palette_index: u8) の繰り返し
        - run_length は 1〜255。256以上連続する場合は複数ランに分割する。
        - palette_index は 0〜15 (4bit)。ファーム側の共通固定パレットの
          インデックスと一致させる（パレットテーブル自体はファイルに含めない）。

設計方針（アイコンパイプラインと共通）:
    - ディザリングは行わない（最近傍色マッピングのみ）。
      32px以上でのBayerディザ + アルファ量子化による不透明判定破綻の教訓を踏襲。
    - アルファ判定は単一グローバル閾値（ALPHA_THRESHOLD）。
    - オフラインでPython側が全処理を行い、C++側はデコード専任とする
      （データ/ロジック分離の方針を維持）。

使い方:
    uv run generate_pimg.py input.png output.pimg
    uv run generate_pimg.py input.png output.pimg --transparent
    uv run generate_pimg.py input.png output.pimg --transparent --preview preview.png
"""

import argparse
import struct
import sys
from pathlib import Path

from PIL import Image

# ------------------------------------------------------------------
# 固定16色パレット（RGB888）
# ★★★ 必ずファーム側の実際のパレットテーブル（kPaletteTable等）と
#      インデックス順序・RGB値を完全一致させること。
#      ここではプレースホルダとして一般的な16色を仮置きしている。
#      index 0 は透過用スロットとして予約する運用を想定。
# ------------------------------------------------------------------
PALETTE = [
    (0x00, 0x00, 0x00),  # 0: 透過 / 黒
    (0x00, 0x00, 0x80),  # 1: navy
    (0x00, 0x80, 0x00),  # 2: dark green
    (0x00, 0x80, 0x80),  # 3: dark cyan
    (0x80, 0x00, 0x00),  # 4: maroon
    (0x80, 0x00, 0x80),  # 5: purple
    (0x80, 0x80, 0x00),  # 6: olive
    (0xD3, 0xD3, 0xD3),  # 7: lightgrey
    (0x80, 0x80, 0x80),  # 8: darkgrey
    (0x00, 0x00, 0xFF),  # 9: blue
    (0x00, 0xFF, 0x00),  # 10: green
    (0x00, 0xFF, 0xFF),  # 11: cyan
    (0xFF, 0x00, 0x00),  # 12: red
    (0xFF, 0x00, 0xFF),  # 13: magenta
    (0xFF, 0xFF, 0x00),  # 14: yellow
    (0xFF, 0xFF, 0xFF),  # 15: white
]

ALPHA_THRESHOLD = 96  # アイコンパイプラインと同一閾値


def nearest_palette_index(rgb, palette, skip_index=None):
    """最近傍色マッピング（ディザなし）。skip_indexは候補から除外（例: 透過専用スロット）。"""
    best_idx = 0
    best_dist = None
    r, g, b = rgb
    for i, (pr, pg, pb) in enumerate(palette):
        if skip_index is not None and i == skip_index:
            continue
        dist = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if best_dist is None or dist < best_dist:
            best_dist = dist
            best_idx = i
    return best_idx


def quantize_image(img: Image.Image, palette, use_transparency: bool):
    """RGBA画像を4bitパレットインデックスの2次元配列に変換する。"""
    img = img.convert("RGBA")
    w, h = img.size
    pixels = img.load()

    indices = [[0] * w for _ in range(h)]
    transparent_index = 0 if use_transparency else None
    # --transparent無しで透過ピクセルに当たった場合、その下地RGB(ツールによっては
    # 未定義のゴミ値が入っている)を最近傍マッチングに使うと予期しない色を拾うため、
    # 白を明示的に割り当てる(PICO_WHITE、consts.hppのPICO_BACKGROUNDと一致)。
    white_index = nearest_palette_index((0xFF, 0xFF, 0xFF), palette)

    for y in range(h):
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a < ALPHA_THRESHOLD:
                indices[y][x] = 0 if use_transparency else white_index
            else:
                indices[y][x] = nearest_palette_index(
                    (r, g, b), palette, skip_index=transparent_index
                )
    return indices, w, h


def rle_encode(indices, w, h):
    """行優先（ラスタスキャン）でrun-length符号化する。256以上のランは分割する。"""
    body = bytearray()
    flat = [indices[y][x] for y in range(h) for x in range(w)]

    n = len(flat)
    i = 0
    run_count = 0
    while i < n:
        idx = flat[i]
        run = 1
        while i + run < n and flat[i + run] == idx and run < 255:
            run += 1
        body.append(run)
        body.append(idx)
        run_count += 1
        i += run

    return bytes(body), run_count


def write_pimg(path: Path, w: int, h: int, use_transparency: bool, body: bytes):
    flags = 0x01 if use_transparency else 0x00
    header = struct.pack("<HHB", w, h, flags)
    with open(path, "wb") as f:
        f.write(header)
        f.write(body)


def write_preview(indices, w, h, palette, out_path: Path):
    """デコード結果を確認するためのプレビューPNGを出力する（実機なしで見た目を確認する用途）。"""
    preview = Image.new("RGB", (w, h))
    px = preview.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = palette[indices[y][x]]
    preview.save(out_path)


def main():
    parser = argparse.ArgumentParser(description="Convert an image to pico-os .pimg format (4bpp indexed RLE)")
    parser.add_argument("input", type=Path, help="入力画像ファイル (png/jpg等)")
    parser.add_argument("output", type=Path, help="出力先 .pimg ファイル")
    parser.add_argument(
        "--transparent",
        action="store_true",
        help="index 0 を透過スロットとして扱う（UIウィジェット重ね描き用）",
    )
    parser.add_argument(
        "--preview",
        type=Path,
        default=None,
        help="デコード結果確認用のプレビューPNGを出力するパス（任意）",
    )
    parser.add_argument(
        "--max-width",
        type=int,
        default=None,
        help="指定した場合、アスペクト比を保ったままこの幅にリサイズする",
    )
    args = parser.parse_args()

    if not args.input.exists():
        print(f"error: input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    img = Image.open(args.input)

    if args.max_width and img.width > args.max_width:
        ratio = args.max_width / img.width
        new_size = (args.max_width, max(1, round(img.height * ratio)))
        img = img.resize(new_size, Image.LANCZOS)

    if img.width > 65535 or img.height > 65535:
        print("error: image dimensions exceed u16 range", file=sys.stderr)
        sys.exit(1)

    indices, w, h = quantize_image(img, PALETTE, args.transparent)
    body, run_count = rle_encode(indices, w, h)
    write_pimg(args.output, w, h, args.transparent, body)

    raw_size = w * h  # 1byte/pixel相当（比較用の目安。実際のフレームバッファは4bit=0.5byte/pixel）
    raw_4bpp_size = (w * h + 1) // 2
    encoded_size = len(body) + 5  # + header

    print(f"input : {args.input}  ({img.width}x{img.height} -> {w}x{h})")
    print(f"output: {args.output}")
    print(f"runs  : {run_count}")
    print(f"size  : {encoded_size} bytes  (raw 4bpp相当: {raw_4bpp_size} bytes, raw 8bpp相当: {raw_size} bytes)")
    if raw_4bpp_size > 0:
        ratio = encoded_size / raw_4bpp_size
        print(f"ratio : {ratio:.2f}x vs raw 4bpp  ({'圧縮できています' if ratio < 1.0 else '非圧縮の方が小さくなる可能性があります'})")

    if args.preview:
        write_preview(indices, w, h, PALETTE, args.preview)
        print(f"preview: {args.preview}")


if __name__ == "__main__":
    main()
