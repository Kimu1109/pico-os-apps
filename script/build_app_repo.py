#!/usr/bin/env python3
"""pico-os のアプリストアの配布物(docs/APP_REPO.md)を作る。標準ライブラリだけで動く。

使い方:
  # 1. 鍵を作る(1回だけ)。秘密鍵は手元のPCにだけ置く(リポジトリ・サーバに置かない)
  python3 script/build_app_repo.py keygen --key ~/.pico-os/app_repo.key

  # 2a. 配布物をまるごと作る(Raspberry Pi 等へそのまま置く)
  python3 script/build_app_repo.py build --key ~/.pico-os/app_repo.key --out /tmp/apps

  # 2b. GitHub Pages 向け: 署名した目録(catalog.tsv / catalog.sig / <id>/<版>/files.tsv・files.sig)だけを
  #     リポジトリの store/ へ書き、コミットする。アプリの中身は Pages のワークフローが
  #     pc/sdcard/lua/apps/ から写す(assemble)。秘密鍵は GitHub に置かなくてよい
  python3 script/build_app_repo.py sign --key ~/.pico-os/app_repo.key --out store
  python3 script/build_app_repo.py assemble --index store --out _site/apps

  # 署名を確かめる
  python3 script/build_app_repo.py verify --dir /tmp/apps [--pubkey 16進64桁]

  # 3. Webのページ(index.html)と、SDに置けば入るパッケージ(<id>-<版>.papp)を配布物に足す
  python3 script/build_app_repo.py site --dir _site/apps

  # 手元のアプリを1つだけパッケージにする(ストアを通さずに配る。作者の鍵で署名する)
  python3 script/build_app_repo.py package --key ~/.pico-os/author.key --app pc/sdcard/lua/apps/テトリス --out tetris.papp

  # 投稿用リポジトリ(kimu1109/pico-os-apps。今のストアの配布元)。作者が手元で apps/<id>/ に署名し、PRを出す。
  # --src を付けると pico-os の pc/sdcard から app/ へ写してから署名する(公式アプリの更新)
  python3 script/build_app_repo.py author-sign --key ~/.pico-os/author.key --app apps/tetris \
      [--src ../pico-os/pc/sdcard/lua/apps/テトリス] [--owner <GitHubのアカウント> --dir テトリス(初めてのとき)]
  # 同じリポジトリのCIが使う: PRの検査と自動マージの判定 / 配布物を作ってカタログ鍵で署名
  python3 -I script/build_app_repo.py registry-check --registry pr --base main --user <login> --luac luac5.4 --out result.json
  python3 script/build_app_repo.py registry-build --registry . --key catalog.key --out _site --prev-catalog prev.tsv
  # このスクリプトの正本は pico-os。pico-os-apps の script/ はその写し(直したら写し直す)

署名は2種類(docs/APP_REPO.md 形式2): catalog.sig はカタログ鍵(--key)、各アプリの files.sig は
作者の鍵(--author-key。既定は --key と同じ。pico-os の公式アプリは同じ鍵で両方を署名する)。

配るアプリは pc/sdcard/lua/apps/<ディレクトリ>/app.cfg に id = ... があるものだけ
(--apps-dir で場所を変えられる)。gitの管理下なら、gitが管理しているファイルだけを配る
(遊んでいる間にできた store.json・セーブデータ等を配らないため)。
"""

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import time

# ---- 本体(apps/store/App_Repo.hpp)と揃える値 ----
MAGIC = "pico-os-apps"
FORMAT = 2
SIGN_CONTEXT = b"pico-os-apps-v2\0"  # 16バイト(カタログ鍵)
APP_SIGN_CONTEXT = b"pico-os-app-v2\0\0"  # 16バイト(作者の鍵)
STATUSES = ("-", "yanked", "blocked")
# 形式1(作者の署名が無い)の目録は、assemble / verify でだけ通す(コミット済みの store/ を
# sign し直すまで、形式1のファームへ配り続けるため)
SIGN_CONTEXT_V1 = b"pico-os-apps-v1\0"
MAX_ENTRIES = 40
MAX_CATALOG_BYTES = 32 * 1024
MAX_LINE_BYTES = 638  # 本体は640バイト(改行込み)まで読む
MAX_FILES = 64
MAX_FILES_BYTES = 8 * 1024
MAX_FILE_BYTES = 1024 * 1024
MAX_APP_BYTES = 4 * 1024 * 1024
MAX_PATH_LEN = 95
MAX_PATH_DEPTH = 4
MAX_NAME_BYTES = 47
MAX_DESC_BYTES = 180
MAX_AUTHOR_BYTES = 47
DEFAULT_AUTHOR = "kimu1109"

ID_RE = re.compile(r"^[a-z0-9_-]{1,23}$")
VERSION_RE = re.compile(r"^[0-9]+(\.[0-9]+)*$")
SEG_RE = re.compile(r"^[A-Za-z0-9_-][A-Za-z0-9._-]*$")

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEFAULT_APPS_DIR = os.path.join(ROOT, "pc", "sdcard", "lua", "apps")


# ---------------------------------------------------------------------------
# Ed25519(RFC 8032 の参照実装を短くしたもの。署名は1回だけなので速さは気にしない)
# ---------------------------------------------------------------------------
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_I = pow(2, (_P - 1) // 4, _P)


def _inv(x):
    return pow(x, _P - 2, _P)


def _xrecover(y):
    xx = (y * y - 1) * _inv(_D * y * y + 1)
    x = pow(xx, (_P + 3) // 8, _P)
    if (x * x - xx) % _P != 0:
        x = (x * _I) % _P
    if x % 2 != 0:
        x = _P - x
    return x


_BY = 4 * _inv(5) % _P
_B = (_xrecover(_BY), _BY, 1, _xrecover(_BY) * _BY % _P)


def _add(p, q):
    x1, y1, z1, t1 = p
    x2, y2, z2, t2 = q
    a = (y1 - x1) * (y2 - x2) % _P
    b = (y1 + x1) * (y2 + x2) % _P
    c = t1 * 2 * _D * t2 % _P
    d = z1 * 2 * z2 % _P
    e, f, g, h = b - a, d - c, d + c, b + a
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _mul(s, p):
    q = (0, 1, 1, 0)
    while s > 0:
        if s & 1:
            q = _add(q, p)
        p = _add(p, p)
        s >>= 1
    return q


def _encode_point(p):
    x, y, z, _ = p
    zi = _inv(z)
    x, y = x * zi % _P, y * zi % _P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def _decode_point(b):
    y = int.from_bytes(b, "little") & ((1 << 255) - 1)
    x = _xrecover(y)
    if (x & 1) != (b[31] >> 7):
        x = _P - x
    return (x, y, 1, x * y % _P)


def _secret_scalar(seed):
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, h[32:]


def ed25519_public(seed):
    a, _ = _secret_scalar(seed)
    return _encode_point(_mul(a, _B))


def ed25519_sign(seed, msg):
    a, prefix = _secret_scalar(seed)
    pub = _encode_point(_mul(a, _B))
    r = int.from_bytes(hashlib.sha512(prefix + msg).digest(), "little") % _L
    R = _encode_point(_mul(r, _B))
    k = int.from_bytes(hashlib.sha512(R + pub + msg).digest(), "little") % _L
    s = (r + k * a) % _L
    return R + s.to_bytes(32, "little")


def ed25519_verify(pub, msg, sig):
    if len(sig) != 64 or len(pub) != 32:
        return False
    s = int.from_bytes(sig[32:], "little")
    if s >= _L:
        return False
    try:
        A = _decode_point(pub)
        R = _decode_point(sig[:32])
    except Exception:
        return False
    k = int.from_bytes(hashlib.sha512(sig[:32] + pub + msg).digest(), "little") % _L
    left = _mul(s, _B)
    right = _add(R, _mul(k, A))
    return _encode_point(left) == _encode_point(right)


# ---------------------------------------------------------------------------
# 鍵
# ---------------------------------------------------------------------------
def load_seed(path):
    path = os.path.expanduser(path)
    with open(path, "r", encoding="ascii") as f:
        text = f.read().strip()
    seed = bytes.fromhex(text)
    if len(seed) != 32:
        raise SystemExit(f"{path}: 秘密鍵は16進64桁です")
    return seed


def cmd_keygen(args):
    path = os.path.expanduser(args.key)
    if os.path.exists(path) and not args.force:
        raise SystemExit(f"{path} は既にあります(上書きするなら --force)")
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    seed = os.urandom(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as f:
        f.write(seed.hex() + "\n")
    pub = ed25519_public(seed)
    print(f"秘密鍵: {path}(この端末の外へ出さないこと)")
    print_pubkey(pub)


def print_pubkey(pub):
    print(f"公開鍵: {pub.hex()}")
    print("")
    print("本体に信頼させるには、どちらか:")
    print(f"  SDの /sys/store.cfg に  key = {pub.hex()}")
    body = ", ".join(f"0x{b:02x}" for b in pub)
    print("  src/apps/store/App_Repo_Keys.hpp の kBuiltin に")
    print(f"        {{ {{ {body} }} }},")


def cmd_pubkey(args):
    print_pubkey(ed25519_public(load_seed(args.key)))


# ---------------------------------------------------------------------------
# アプリを集める
# ---------------------------------------------------------------------------
def read_app_cfg(path):
    cfg = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


def truthy(v):
    return v.strip().lower() in ("true", "1", "yes", "on")


def cut_utf8(s, limit):
    b = s.encode("utf-8")
    if len(b) <= limit:
        return s
    return b[:limit].decode("utf-8", errors="ignore")


def valid_dir_name(name):
    if not name or name.startswith(".") or len(name.encode("utf-8")) > 47:
        return False
    if any(ord(c) < 0x20 or ord(c) == 0x7F or c in '/\\:*?"<>|' for c in name):
        return False
    return not name.endswith((" ", "."))


def valid_rel_path(p):
    if len(p) > MAX_PATH_LEN:
        return False
    segs = p.split("/")
    if len(segs) > MAX_PATH_DEPTH:
        return False
    return all(SEG_RE.match(s) for s in segs)


def dev_only(rel):
    """配らないファイル(picoos lua-test のテスト。tests/ の下と *_test.lua)"""
    return rel.startswith("tests/") or rel.endswith("_test.lua")


def tracked_files(app_dir):
    """gitが管理しているファイル(gitの外ならディレクトリの中の全部)。app_dir からの相対パス。
    テスト(dev_only)は端末に要らないので除く"""
    try:
        out = subprocess.run(["git", "-C", app_dir, "ls-files", "-z", "--", "."],
                             check=True, capture_output=True).stdout
        names = [n for n in out.decode("utf-8").split("\0") if n and not dev_only(n)]
        if names:
            return sorted(names)
    except (OSError, subprocess.CalledProcessError):
        pass
    result = []
    for base, dirs, files in os.walk(app_dir):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for f in files:
            if f.startswith("."):
                continue
            rel = os.path.relpath(os.path.join(base, f), app_dir).replace(os.sep, "/")
            if not dev_only(rel):
                result.append(rel)
    return sorted(result)


class App:
    pass


def collect_apps(apps_dir, only, only_dir=None):
    apps = []
    for name in sorted(os.listdir(apps_dir)):
        if only_dir is not None and name != only_dir:
            continue
        app_dir = os.path.join(apps_dir, name)
        cfg_path = os.path.join(app_dir, "app.cfg")
        if not os.path.isdir(app_dir) or not os.path.isfile(cfg_path):
            continue
        cfg = read_app_cfg(cfg_path)
        if not cfg.get("id", ""):
            continue
        if only and cfg["id"] not in only:
            continue
        apps.append(load_app(app_dir, name, tracked_files(app_dir), f"{name}/app.cfg"))
    check_app_set(apps)
    return apps


def check_app_set(apps):
    ids = [a.id for a in apps]
    if len(set(ids)) != len(ids):
        raise SystemExit("同じ id のアプリが2つあります")
    dirs = [a.dir.lower() for a in apps]
    if len(set(dirs)) != len(dirs):
        raise SystemExit("同じ dir のアプリが2つあります(SDでは大文字小文字も区別しない)")
    if len(apps) > MAX_ENTRIES:
        raise SystemExit(f"アプリは{MAX_ENTRIES}個までです")


def load_app(app_dir, name, files, where):
    """app_dir のアプリを読む。name … catalog.tsv の dir、files … 配るファイル(app_dir からの相対パス)"""
    cfg = read_app_cfg(os.path.join(app_dir, "app.cfg"))
    app_id = cfg.get("id", "")
    if not ID_RE.match(app_id):
        raise SystemExit(f"{where}: id は英小文字・数字・-・_ の23文字までです ({app_id})")
    version = cfg.get("version", "")
    if not VERSION_RE.match(version) or len(version) > 23:
        raise SystemExit(f"{where}: version は 1.2.3 のような数字と.だけにしてください ({version})")
    if not valid_dir_name(name):
        raise SystemExit(f"{name}: ディレクトリ名に使えない文字があります")
    a = App()
    a.id, a.version, a.dir, a.path = app_id, version, name, app_dir
    a.name = cut_utf8(cfg.get("name", name).replace("\t", " "), MAX_NAME_BYTES) or name
    a.description = cut_utf8(cfg.get("description", "").replace("\t", " "), MAX_DESC_BYTES)
    perms = []
    if truthy(cfg.get("permission_network", "false")):
        perms.append("network")
    if truthy(cfg.get("permission_notify", "false")):
        perms.append("notify")
    if truthy(cfg.get("permission_sd_outside_app_dir", "false")):
        perms.append("sd")
    if truthy(cfg.get("permission_background", "false")):
        perms.append("background")
    if truthy(cfg.get("permission_microphone", "false")):
        perms.append("microphone")
    a.perms = ",".join(perms) or "-"
    a.status = "-"
    files = list(files)
    if "main.lua" not in files or "app.cfg" not in files:
        raise SystemExit(f"{name}: main.lua と app.cfg が要ります(gitの管理下ならgit addも)")
    files.sort(key=lambda p: (p.lower(), p))
    lowered = [p.lower() for p in files]
    if len(set(lowered)) != len(lowered):
        raise SystemExit(f"{name}: 大文字小文字だけが違うファイルがあります(SDでは同じ名前になる)")
    if len(files) > MAX_FILES:
        raise SystemExit(f"{name}: ファイルは{MAX_FILES}個までです")
    a.files = []
    total = 0
    for rel in files:
        if not valid_rel_path(rel):
            raise SystemExit(f"{name}/{rel}: パスは英数字と . - _ で、{MAX_PATH_DEPTH}段・{MAX_PATH_LEN}文字までにしてください")
        with open(os.path.join(app_dir, rel), "rb") as f:
            data = f.read()
        if len(data) > MAX_FILE_BYTES:
            raise SystemExit(f"{name}/{rel}: 1ファイル{MAX_FILE_BYTES}バイトまでです")
        total += len(data)
        a.files.append((rel, len(data), hashlib.sha256(data).hexdigest()))
    if total > MAX_APP_BYTES:
        raise SystemExit(f"{name}: 合計{MAX_APP_BYTES}バイトまでです")
    a.bytes = total
    a.files_tsv = "".join(f"{p}\t{n}\t{h}\n" for p, n, h in a.files).encode("ascii")
    if len(a.files_tsv) > MAX_FILES_BYTES:
        raise SystemExit(f"{name}: files.tsv が大きすぎます")
    return a


def make_catalog(apps, serial):
    lines = [f"{MAGIC}\t{FORMAT}\t{serial}\n"]
    for a in apps:
        h = hashlib.sha256(a.files_tsv).hexdigest()
        if a.status not in STATUSES:
            raise SystemExit(f"{a.id}: status は {'/'.join(STATUSES)} のどれかです ({a.status})")
        author = cut_utf8(a.author.replace("\t", " "), MAX_AUTHOR_BYTES) or "-"
        line = (f"{a.id}\t{a.version}\t{a.dir}\t{a.name}\t{a.bytes}\t{h}\t{a.perms}\t{a.description}"
                f"\t{a.author_key}\t{author}\t{a.status}\n")
        if len(line.encode("utf-8")) > MAX_LINE_BYTES:
            raise SystemExit(f"{a.dir}: カタログの1行が長すぎます(名前・説明を短く)")
        lines.append(line)
    data = "".join(lines).encode("utf-8")
    if len(data) > MAX_CATALOG_BYTES:
        raise SystemExit("catalog.tsv が大きすぎます")
    return data


def sign_catalog(seed, catalog):
    msg = SIGN_CONTEXT + hashlib.sha256(catalog).digest()
    pub = ed25519_public(seed)
    sig = ed25519_sign(seed, msg)
    return f"ed25519 {pub.hex()} {sig.hex()}\n".encode("ascii")


def files_message(app_id, version, files_tsv):
    header = f"{app_id}\t{version}\t{hashlib.sha256(files_tsv).hexdigest()}\n".encode("utf-8")
    return APP_SIGN_CONTEXT + hashlib.sha256(header).digest()


def sign_files(seed, app_id, version, files_tsv):
    pub = ed25519_public(seed)
    sig = ed25519_sign(seed, files_message(app_id, version, files_tsv))
    return f"ed25519 {pub.hex()} {sig.hex()}\n".encode("ascii")


def check_files_sig(text, author_key_hex, app_id, version, files_tsv):
    parts = text.split()
    if len(parts) != 3 or parts[0] != "ed25519":
        raise SystemExit(f"{app_id}: files.sig の形式が違います")
    if parts[1].lower() != author_key_hex.lower():
        raise SystemExit(f"{app_id}: files.sig の鍵が catalog.tsv の author_key と違います")
    if not ed25519_verify(bytes.fromhex(parts[1]), files_message(app_id, version, files_tsv), bytes.fromhex(parts[2])):
        raise SystemExit(f"{app_id}: files.sig の署名が合いません")


def write_bytes(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def write_index(out, apps, seed, serial, author_seed=None, author=DEFAULT_AUTHOR):
    """seed=カタログ鍵、author_seed=作者の鍵(既定は seed)。アプリごとに a.author_seed / a.author で替えられる"""
    for a in apps:
        a.sign_seed = getattr(a, "author_seed", None) or author_seed or seed
        a.author_key = ed25519_public(a.sign_seed).hex()
        if not getattr(a, "author", None):
            a.author = author
    catalog = make_catalog(apps, serial)
    write_bytes(os.path.join(out, "catalog.tsv"), catalog)
    write_bytes(os.path.join(out, "catalog.sig"), sign_catalog(seed, catalog))
    for a in apps:
        base = os.path.join(out, a.id, a.version)
        write_bytes(os.path.join(base, "files.tsv"), a.files_tsv)
        write_bytes(os.path.join(base, "files.sig"), sign_files(a.sign_seed, a.id, a.version, a.files_tsv))


def default_serial(args):
    return args.serial if args.serial is not None else int(time.time())


def author_seed(args):
    return load_seed(args.author_key) if args.author_key else None


def cmd_build(args):
    seed = load_seed(args.key)
    apps = collect_apps(args.apps_dir, set(args.only.split(",")) if args.only else None)
    if args.clean and os.path.isdir(args.out):
        shutil.rmtree(args.out)
    write_index(args.out, apps, seed, default_serial(args), author_seed(args), args.author)
    for a in apps:
        for rel, _, _ in a.files:
            dst = os.path.join(args.out, a.id, a.version, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(a.path, rel), dst)
    print(f"{args.out}: {len(apps)}件のアプリ")
    for a in apps:
        print(f"  {a.id} {a.version} ({a.dir}) {a.bytes}バイト perms={a.perms}")


def cmd_sign(args):
    seed = load_seed(args.key)
    apps = collect_apps(args.apps_dir, set(args.only.split(",")) if args.only else None)
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    write_index(args.out, apps, seed, default_serial(args), author_seed(args), args.author)
    print(f"{args.out}: {len(apps)}件のアプリの目録に署名しました。コミットしてください")


def read_catalog(index_dir):
    with open(os.path.join(index_dir, "catalog.tsv"), "rb") as f:
        catalog = f.read()
    lines = catalog.decode("utf-8").splitlines()
    head = lines[0].split("\t")
    if head[0] != MAGIC or head[1] not in ("1", str(FORMAT)):
        raise SystemExit("catalog.tsv の1行目が違います")
    fmt = int(head[1])
    if fmt == 1:
        print("::warning::catalog.tsv が形式1(作者の署名なし)です。形式2のファームは読みません。"
              "build_app_repo.py sign をやり直してください")
    entries = []
    for line in lines[1:]:
        if not line or line.startswith("#"):
            continue
        c = line.split("\t")
        if len(c) < (11 if fmt == 2 else 8):
            raise SystemExit(f"catalog.tsv の行の列が足りません ({c[0]})")
        entries.append({"id": c[0], "version": c[1], "dir": c[2], "name": c[3], "bytes": int(c[4]), "files_sha256": c[5],
                        "perms": c[6], "description": c[7],
                        "author_key": c[8] if fmt == 2 else None, "author": c[9] if fmt == 2 else "-",
                        "status": c[10] if fmt == 2 else "-", "line": line})
    return catalog, entries, fmt


def check_signature(index_dir, catalog, pubkey_hex, fmt=FORMAT):
    with open(os.path.join(index_dir, "catalog.sig"), "r", encoding="ascii") as f:
        parts = f.read().split()
    if len(parts) != 3 or parts[0] != "ed25519":
        raise SystemExit("catalog.sig の形式が違います")
    pub, sig = bytes.fromhex(parts[1]), bytes.fromhex(parts[2])
    if pubkey_hex and pub.hex() != pubkey_hex.lower():
        raise SystemExit("catalog.sig の鍵が指定した公開鍵と違います")
    context = SIGN_CONTEXT if fmt == FORMAT else SIGN_CONTEXT_V1
    if not ed25519_verify(pub, context + hashlib.sha256(catalog).digest(), sig):
        raise SystemExit("catalog.sig の署名が合いません")
    return pub


def cmd_assemble(args):
    """署名済みの目録(sign の出力)に、アプリの中身を写して配布物にする。中身が目録と違えば止まる"""
    catalog, entries, fmt = read_catalog(args.index)
    check_signature(args.index, catalog, args.pubkey, fmt)
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    shutil.copytree(args.index, args.out)
    stale = []
    for e in entries:
        files_tsv_path = os.path.join(args.index, e["id"], e["version"], "files.tsv")
        with open(files_tsv_path, "rb") as f:
            files_tsv = f.read()
        if hashlib.sha256(files_tsv).hexdigest() != e["files_sha256"]:
            raise SystemExit(f"{e['id']}: files.tsv が catalog.tsv と合いません")
        if fmt == FORMAT:
            with open(os.path.join(args.index, e["id"], e["version"], "files.sig"), "r", encoding="ascii") as f:
                check_files_sig(f.read(), e["author_key"], e["id"], e["version"], files_tsv)
        src_dir = os.path.join(args.apps_dir, e["dir"])
        for line in files_tsv.decode("ascii").splitlines():
            rel, size, digest = line.split("\t")
            with open(os.path.join(src_dir, rel), "rb") as f:
                data = f.read()
            if len(data) != int(size) or hashlib.sha256(data).hexdigest() != digest:
                msg = (f"{e['dir']}/{rel}: 署名した後で中身が変わっています。"
                       "build_app_repo.py sign をやり直してください")
                if not args.allow_stale:
                    raise SystemExit(msg)
                # 署名した中身はもう手元に無いので、このアプリは配らない(本体ではインストールが404で止まる)
                print(f"::warning::{msg}(このアプリは配りません)")
                shutil.rmtree(os.path.join(args.out, e["id"], e["version"]), ignore_errors=True)
                stale.append(e["id"])
                break
            write_bytes(os.path.join(args.out, e["id"], e["version"], rel), data)
    print(f"{args.out}: {len(entries) - len(stale)}件のアプリ" + (f"(古いので配らない: {', '.join(stale)})" if stale else ""))


def cmd_verify(args):
    catalog, entries, fmt = read_catalog(args.dir)
    pub = check_signature(args.dir, catalog, args.pubkey, fmt)
    skipped = 0
    for e in entries:
        base = os.path.join(args.dir, e["id"], e["version"])
        if not os.path.isdir(base):
            print(f"  {e['id']} {e['version']}: 配っていません")
            skipped += 1
            continue
        with open(os.path.join(base, "files.tsv"), "rb") as f:
            files_tsv = f.read()
        if hashlib.sha256(files_tsv).hexdigest() != e["files_sha256"]:
            raise SystemExit(f"{e['id']}: files.tsv が合いません")
        if fmt == FORMAT:
            with open(os.path.join(base, "files.sig"), "r", encoding="ascii") as f:
                check_files_sig(f.read(), e["author_key"], e["id"], e["version"], files_tsv)
        total = 0
        for line in files_tsv.decode("ascii").splitlines():
            rel, size, digest = line.split("\t")
            p = os.path.join(base, rel)
            if os.path.exists(p):
                with open(p, "rb") as f:
                    data = f.read()
                if len(data) != int(size) or hashlib.sha256(data).hexdigest() != digest:
                    raise SystemExit(f"{e['id']}/{rel}: 中身が合いません")
            total += int(size)
        if total != e["bytes"]:
            raise SystemExit(f"{e['id']}: 合計が合いません")
    print(f"署名OK(鍵 {pub.hex()})、{len(entries) - skipped}件")


# ---------------------------------------------------------------------------
# 投稿用リポジトリ(kimu1109/pico-os-apps。docs/design/lua-apps.md「アプリストアの投稿」)
#
#   apps/<id>/meta.cfg   owners = alice, bob / key = 作者の公開鍵 / dir = /lua/apps/ の下の名前 / author = 表示名
#   apps/<id>/app/...    アプリのファイル
#   apps/<id>/files.tsv  author-sign が作る(files.sig も)
#   status.tsv           <id> <TAB> <status> <TAB> <理由>
#
# registry-check は PR の中身をデータとして読むだけで、実行はしない(luac -p も構文を見るだけ)。
# ---------------------------------------------------------------------------
REGISTRY_APP_FILES = ("files.tsv", "files.sig")  # apps/<id>/ の直下で作者が変えてよいもの(と app/ の下)


def walk_files(app_dir):
    """app_dir の下の全部のファイル(相対パス)。PRの中身を読むので、リンクと隠しファイルは断る
    (リンクを辿るとCIの中の別のファイルを読んでしまう)"""
    result = []
    for base, dirs, files in os.walk(app_dir):
        for n in dirs + files:
            p = os.path.join(base, n)
            rel = os.path.relpath(p, app_dir).replace(os.sep, "/")
            if os.path.islink(p):
                raise SystemExit(f"{rel}: リンクは置けません")
            if n.startswith("."):
                raise SystemExit(f"{rel}: . で始まる名前は置けません")
        for f in files:
            rel = os.path.relpath(os.path.join(base, f), app_dir).replace(os.sep, "/")
            if not dev_only(rel):
                result.append(rel)
    return sorted(result)


def read_meta(path, where):
    if os.path.islink(path) or not os.path.isfile(path):
        raise SystemExit(f"{where}: meta.cfg がありません")
    cfg = read_app_cfg(path)
    owners = [o.strip().lower() for o in cfg.get("owners", "").split(",") if o.strip()]
    if not owners:
        raise SystemExit(f"{where}: meta.cfg の owners が空です")
    key = cfg.get("key", "").lower()
    if not re.match(r"^[0-9a-f]{64}$", key) or key == "0" * 64:
        raise SystemExit(f"{where}: meta.cfg の key は作者の公開鍵(16進64桁)です")
    d = cfg.get("dir", "")
    if not valid_dir_name(d):
        raise SystemExit(f"{where}: meta.cfg の dir に使えない文字があります ({d})")
    author = cut_utf8(cfg.get("author", "") or owners[0], MAX_AUTHOR_BYTES)
    return {"owners": owners, "key": key, "dir": d, "author": author}


def read_status(path):
    """status.tsv → {id: (status, 理由)}。無ければ空"""
    result = {}
    if not os.path.isfile(path):
        return result
    if os.path.islink(path):
        raise SystemExit("status.tsv: リンクは置けません")
    for line in open(path, encoding="utf-8").read().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        if c[1:2] and c[1] not in STATUSES:
            raise SystemExit(f"status.tsv: {c[0]} の status は {'/'.join(STATUSES)} のどれかです ({c[1]})")
        result[c[0]] = (c[1] if len(c) > 1 else "-", c[2] if len(c) > 2 else "")
    return result


def load_registry_app(registry, app_id):
    """apps/<app_id>/ を読み、files.tsv が中身と合うか・files.sig が meta.cfg の鍵で合うかまで確かめる"""
    where = f"apps/{app_id}"
    base = os.path.join(registry, "apps", app_id)
    if not ID_RE.match(app_id):
        raise SystemExit(f"{where}: ディレクトリ名(id)は英小文字・数字・-・_ の23文字までです")
    meta = read_meta(os.path.join(base, "meta.cfg"), where)
    app_dir = os.path.join(base, "app")
    if os.path.islink(app_dir) or not os.path.isdir(app_dir):
        raise SystemExit(f"{where}: app/ がありません")
    a = load_app(app_dir, meta["dir"], walk_files(app_dir), f"{where}/app/app.cfg")
    if a.id != app_id:
        raise SystemExit(f"{where}: app.cfg の id ({a.id}) がディレクトリ名と違います")
    for name in REGISTRY_APP_FILES:
        p = os.path.join(base, name)
        if os.path.islink(p) or not os.path.isfile(p):
            raise SystemExit(f"{where}: {name} がありません(build_app_repo.py author-sign で作ります)")
    with open(os.path.join(base, "files.tsv"), "rb") as f:
        if f.read() != a.files_tsv:
            raise SystemExit(f"{where}: files.tsv が app/ の中身と合いません(author-sign をやり直してください)")
    with open(os.path.join(base, "files.sig"), "r", encoding="ascii", errors="replace") as f:
        a.files_sig = f.read()
    check_files_sig(a.files_sig, meta["key"], a.id, a.version, a.files_tsv)
    a.author_key, a.author, a.owners = meta["key"], meta["author"], meta["owners"]
    return a


def load_registry(registry):
    apps_root = os.path.join(registry, "apps")
    names = sorted(os.listdir(apps_root)) if os.path.isdir(apps_root) else []
    # 並びは今までの目録(pc/sdcard のディレクトリ名の順)と同じにする。ストアの一覧はこの順で出る
    apps = sorted((load_registry_app(registry, n) for n in names), key=lambda a: a.dir)
    status = read_status(os.path.join(registry, "status.tsv"))
    for a in apps:
        a.status = status.get(a.id, ("-", ""))[0]
    unknown = set(status) - {a.id for a in apps}
    if unknown:
        raise SystemExit(f"status.tsv: apps/ に無い id があります ({', '.join(sorted(unknown))})")
    check_app_set(apps)
    make_catalog(apps, 0)  # 1行の長さ・全体の大きさ
    return apps


def version_tuple(v):
    return tuple(int(x) for x in v.split("."))


def tree_digest(root):
    """root の下のファイル → SHA-256(.git は除く。リンクはリンク先の名前で比べる)"""
    result = {}
    if not root or not os.path.isdir(root):
        return result
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if not (base == root and d == ".git")]
        for n in files + [d for d in dirs if os.path.islink(os.path.join(base, d))]:
            p = os.path.join(base, n)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            data = ("link:" + os.readlink(p)).encode() if os.path.islink(p) else open(p, "rb").read()
            result[rel] = hashlib.sha256(data).hexdigest()
    return result


def review_reasons(registry, base, user):
    """自動でマージしてよければ []。だめなら人が見る理由の一覧(registry は検査に通っていること)"""
    new, old = tree_digest(registry), tree_digest(base)
    changed = sorted(p for p in set(new) | set(old) if new.get(p) != old.get(p))
    if not changed:
        return ["変更がありません"], changed
    reasons = []
    ids = set()
    for p in changed:
        seg = p.split("/")
        if len(seg) >= 3 and seg[0] == "apps" and (seg[2] == "app" and len(seg) >= 4 or
                                                  (len(seg) == 3 and seg[2] in REGISTRY_APP_FILES)):
            ids.add(seg[1])
        else:
            reasons.append(f"アプリの中身と署名の他を変えています: {p}")
    if len(ids) > 1:
        reasons.append(f"2つ以上のアプリを変えています: {', '.join(sorted(ids))}")
    for app_id in sorted(ids):
        if not os.path.isfile(os.path.join(base, "apps", app_id, "meta.cfg")):
            reasons.append(f"{app_id}: 新しいアプリです")
            continue
        if not os.path.isdir(os.path.join(registry, "apps", app_id)):
            reasons.append(f"{app_id}: アプリを消しています")
            continue
        try:
            before = load_registry_app(base, app_id)
        except SystemExit as e:
            reasons.append(f"{app_id}: main の版が読めません({e})")
            continue
        after = load_registry_app(registry, app_id)
        if (user or "").lower() not in before.owners:
            reasons.append(f"{app_id}: PRを出したアカウント({user})が main の meta.cfg の owners にいません")
        if version_tuple(after.version) <= version_tuple(before.version):
            reasons.append(f"{app_id}: 版が main ({before.version}) より新しくありません ({after.version})")
        more = set(after.perms.split(",")) - set(before.perms.split(",")) - {"-"}
        if more:
            reasons.append(f"{app_id}: 権限が増えています ({', '.join(sorted(more))})")
        st = read_status(os.path.join(base, "status.tsv")).get(app_id, ("-", ""))[0]
        if st != "-":
            reasons.append(f"{app_id}: status が {st} です")
    return reasons, changed


def luac_check(luac, registry, apps):
    errors = []
    for a in apps:
        for rel, _, _ in a.files:
            if not rel.endswith(".lua"):
                continue
            p = os.path.abspath(os.path.join(a.path, rel))
            try:
                r = subprocess.run([luac, "-p", "--", p], capture_output=True, text=True)
            except OSError as e:
                raise SystemExit(f"{luac} を動かせません ({e})")
            if r.returncode != 0:
                errors.append(f"apps/{a.id}/app/{rel}: Luaの構文の誤り: {(r.stderr or r.stdout).strip()}")
    return errors


def cmd_registry_check(args):
    """投稿用リポジトリ(PRの中身)の検査と、自動でマージしてよいかの判定。結果は --out の JSON"""
    import json
    result = {"ok": True, "errors": [], "automerge": False, "reasons": [], "changed": []}
    apps = []
    try:
        apps = load_registry(args.registry)
    except SystemExit as e:
        result["errors"].append(str(e))
    if apps and args.luac:
        result["errors"] += luac_check(args.luac, args.registry, apps)
    result["ok"] = not result["errors"]
    if result["ok"] and args.base:
        try:
            result["reasons"], result["changed"] = review_reasons(args.registry, args.base, args.user)
        except SystemExit as e:
            result["reasons"] = [f"判定できません: {e}"]
        result["automerge"] = not result["reasons"]
    lines = ["## 検査の結果", ""]
    if result["ok"]:
        lines.append(f"- 検査: 通りました({len(apps)}件のアプリ)")
    else:
        lines.append("- 検査: **落ちました**")
        lines += [f"  - {e}" for e in result["errors"]]
    if result["ok"] and args.base:
        if result["automerge"]:
            lines.append("- 判定: 自動でマージします")
        else:
            lines.append("- 判定: 管理者が見ます(`needs-review`)")
            lines += [f"  - {r}" for r in result["reasons"]]
    text = "\n".join(lines) + "\n"
    print(text)
    if args.out:
        write_bytes(os.path.abspath(args.out), json.dumps(result, ensure_ascii=False, indent=1).encode("utf-8"))
    if args.summary:
        write_bytes(os.path.abspath(args.summary), text.encode("utf-8"))
    if not result["ok"]:
        sys.exit(1)


def cmd_registry_build(args):
    """投稿用リポジトリから配布物(docs/APP_REPO.md)を作り、カタログ鍵で署名する。files.sig は作者のものをそのまま使う"""
    seed = load_seed(args.key)
    apps = load_registry(args.registry)
    serial = args.serial
    if serial is None:
        serial = int(time.time())
        if args.prev_catalog and os.path.isfile(args.prev_catalog):
            head = open(args.prev_catalog, encoding="utf-8", errors="replace").readline().split("\t")
            if len(head) >= 3 and head[0] == MAGIC and head[2].strip().isdigit():
                serial = max(serial, int(head[2]) + 1)
    if serial >= 2 ** 32:
        raise SystemExit("serial が32bitを超えます")
    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    catalog = make_catalog(apps, serial)
    write_bytes(os.path.join(args.out, "catalog.tsv"), catalog)
    write_bytes(os.path.join(args.out, "catalog.sig"), sign_catalog(seed, catalog))
    for a in apps:
        base = os.path.join(args.out, a.id, a.version)
        write_bytes(os.path.join(base, "files.tsv"), a.files_tsv)
        write_bytes(os.path.join(base, "files.sig"), a.files_sig.encode("ascii"))
        for rel, _, _ in a.files:
            with open(os.path.join(a.path, rel), "rb") as f:
                write_bytes(os.path.join(base, rel), f.read())
    print(f"{args.out}: {len(apps)}件のアプリ(serial {serial}、カタログ鍵 {ed25519_public(seed).hex()})")


def cmd_author_sign(args):
    """投稿用リポジトリの apps/<id>/ に files.tsv と files.sig を作る(作者が手元で)。
    --src を付けると、先に app/ をそのディレクトリの中身で置き換える(pico-os の pc/sdcard から写すとき)"""
    seed = load_seed(args.key)
    pub = ed25519_public(seed).hex()
    base = os.path.normpath(args.app)
    app_dir = os.path.join(base, "app")
    if args.src:
        files = tracked_files(args.src)
        if os.path.isdir(app_dir):
            shutil.rmtree(app_dir)
        for rel in files:
            dst = os.path.join(app_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(os.path.join(args.src, rel), dst)
    meta_path = os.path.join(base, "meta.cfg")
    if not os.path.isfile(meta_path):
        if not (args.owner and args.dir):
            raise SystemExit(f"{meta_path} がありません。初めての投稿なら --owner <GitHubのアカウント> --dir <表示するディレクトリ名> を付けてください")
        write_bytes(meta_path, f"owners = {args.owner}\nkey = {pub}\ndir = {args.dir}\n".encode("utf-8"))
        print(f"{meta_path} を作りました")
    meta = read_meta(meta_path, base)
    if meta["key"] != pub:
        raise SystemExit(f"{meta_path} の key ({meta['key']}) とこの鍵 ({pub}) が違います。"
                         "鍵を替えるなら meta.cfg も直してください(管理者が見ます)")
    a = load_app(app_dir, meta["dir"], walk_files(app_dir), f"{base}/app/app.cfg")
    if a.id != os.path.basename(base):
        raise SystemExit(f"{base}: app.cfg の id ({a.id}) がディレクトリ名と違います")
    write_bytes(os.path.join(base, "files.tsv"), a.files_tsv)
    write_bytes(os.path.join(base, "files.sig"), sign_files(seed, a.id, a.version, a.files_tsv))
    print(f"{base}: {a.name} {a.version}({len(a.files)}ファイル、{a.bytes}バイト、権限 {a.perms})に署名しました")


# ---------------------------------------------------------------------------
# パッケージ(.papp。docs/APP_REPO.md「パッケージ(.papp)」)
# ---------------------------------------------------------------------------
PACKAGE_MAGIC = "pico-os-app"
PACKAGE_FORMAT = 1
PACKAGE_EXT = ".papp"


def make_package(catalog_line, files_sig, files_tsv, datas):
    """catalog_line … catalog.tsv の1行(改行なし)、files_sig … files.sig の中身、
    datas … files.tsv の順に並べた各ファイルの中身"""
    sig_line = files_sig.decode("ascii").strip()
    head = (f"{PACKAGE_MAGIC}\t{PACKAGE_FORMAT}\t{len(files_tsv)}\n{catalog_line}\n{sig_line}\n").encode("utf-8")
    return head + files_tsv + b"".join(datas)


def package_name(app_id, version):
    return f"{app_id}-{version}{PACKAGE_EXT}"


def read_package(data):
    """make_package の逆(テストと確認用)。(catalog の列, files.sig の行, files.tsv, {path: 中身})"""
    head = []
    pos = 0
    for _ in range(3):
        end = data.index(b"\n", pos)
        head.append(data[pos:end].decode("utf-8"))
        pos = end + 1
    magic, fmt, n = head[0].split("\t")
    if magic != PACKAGE_MAGIC or int(fmt) != PACKAGE_FORMAT:
        raise SystemExit("パッケージではありません")
    files_tsv = data[pos:pos + int(n)]
    pos += int(n)
    files = {}
    for line in files_tsv.decode("ascii").splitlines():
        rel, size, _ = line.split("\t")
        files[rel] = data[pos:pos + int(size)]
        pos += int(size)
    if pos != len(data):
        raise SystemExit("パッケージの後ろに余分なデータがあります")
    return head[1].split("\t"), head[2], files_tsv, files


def cmd_package(args):
    """手元のアプリを1つパッケージにする(作者の鍵で files.sig を署名する。カタログの署名は要らない)"""
    app_dir = os.path.normpath(args.app)
    apps = collect_apps(os.path.dirname(app_dir) or ".", None, os.path.basename(app_dir))
    if not apps:
        raise SystemExit(f"{app_dir}: app.cfg に id のあるアプリではありません")
    a = apps[0]
    seed = load_seed(args.key)
    a.author_key = ed25519_public(seed).hex()
    a.author = args.author
    line = make_catalog([a], 0).decode("utf-8").splitlines()[1]
    datas = []
    for rel, _, _ in a.files:
        with open(os.path.join(a.path, rel), "rb") as f:
            datas.append(f.read())
    out = args.out or package_name(a.id, a.version)
    write_bytes(os.path.abspath(out), make_package(line, sign_files(seed, a.id, a.version, a.files_tsv), a.files_tsv, datas))
    print(f"{out}: {a.name} {a.version}({a.bytes}バイト、{len(a.files)}ファイル)")
    print("SDカードの直下に置くと、次の起動で /lua/apps/ へ入ります")


# ---- アイコン(.pimg → PNG)。Pillow を使わずに書く(CIのPythonに無くてよいように) ----
def _pimg_palette():
    """script/generate_pimg.py の PALETTE を読む(import すると Pillow が要るので、式だけ取り出す)"""
    import ast
    src = open(os.path.join(ROOT, "script", "generate_pimg.py"), encoding="utf-8").read()
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(getattr(t, "id", "") == "PALETTE" for t in node.targets):
            return ast.literal_eval(node.value)
    raise SystemExit("generate_pimg.py に PALETTE がありません")


def pimg_to_png(data, palette):
    import struct
    import zlib
    if len(data) < 5:
        return None
    w, h, flags = struct.unpack_from("<HHB", data, 0)
    if not (0 < w <= 256 and 0 < h <= 256):
        return None
    transparent = bool(flags & 1)
    idx = bytearray()
    for i in range(5, len(data) - 1, 2):
        idx.extend(bytes([data[i + 1] & 15]) * data[i])
    if len(idx) < w * h:
        return None
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            c = idx[y * w + x]
            r, g, b = palette[c]
            raw.extend((r, g, b, 0 if transparent and c == 0 else 255))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---- Webのページ ----
PERM_TEXT = {"network": "ネットワーク", "notify": "通知", "sd": "SD全体", "background": "バックグラウンド",
             "microphone": "マイク"}
STORE_PAGE = os.path.join(ROOT, "pc", "web", "store.html")


def _size_text(n):
    return f"{n} B" if n < 1024 else f"{n / 1024:.1f} KB" if n < 1024 * 1024 else f"{n / 1048576:.1f} MB"


def render_card(e, icon, pkg, pkg_bytes):
    from html import escape as esc
    perms = [p for p in e["perms"].split(",") if p and p != "-"]
    badges = "".join(f'<span class="perm">{esc(PERM_TEXT.get(p, p))}</span>' for p in perms) \
        or '<span class="perm none">権限なし</span>'
    img = (f'<img class="icon" src="{esc(icon)}" alt="" width="48" height="48" loading="lazy">' if icon
           else '<span class="icon noicon" aria-hidden="true"></span>')
    search = esc(" ".join((e["name"], e["id"], e["description"], e["author"])).lower())
    return f"""<article class="card" id="{esc(e['id'])}" data-search="{search}">
  <div class="card-head">{img}<div><h3>{esc(e['name'])}</h3>
    <p class="meta px">v{esc(e['version'])} · {esc(e['author'])}</p></div></div>
  <p class="desc">{esc(e['description']) or '&nbsp;'}</p>
  <p class="perms">{badges}</p>
  <div class="card-foot">
    <a class="btn primary" href="{esc(pkg)}" download>DOWNLOAD <small>{_size_text(pkg_bytes)}</small></a>
    <span class="id">{esc(e['id'])}</span>
  </div>
</article>"""


def cmd_site(args):
    """配布物(assemble/build の出力)に、パッケージ・アイコン・一覧のページ(index.html)を足す"""
    catalog, entries, fmt = read_catalog(args.dir)
    check_signature(args.dir, catalog, args.pubkey, fmt)
    if fmt != FORMAT:
        raise SystemExit("形式2の目録だけパッケージにできます(build_app_repo.py sign をやり直してください)")
    palette = _pimg_palette()
    cards = []
    for e in entries:
        base = os.path.join(args.dir, e["id"], e["version"])
        if e["status"] != "-" or not os.path.isdir(base):
            continue  # 取り下げ・危険の印のもの・配っていない(中身が古い)ものは載せない
        with open(os.path.join(base, "files.tsv"), "rb") as f:
            files_tsv = f.read()
        with open(os.path.join(base, "files.sig"), "rb") as f:
            files_sig = f.read()
        check_files_sig(files_sig.decode("ascii"), e["author_key"], e["id"], e["version"], files_tsv)
        datas = []
        icon_png = None
        cfg = {}
        for line in files_tsv.decode("ascii").splitlines():
            rel, size, digest = line.split("\t")
            with open(os.path.join(base, rel), "rb") as f:
                data = f.read()
            if len(data) != int(size) or hashlib.sha256(data).hexdigest() != digest:
                raise SystemExit(f"{e['id']}/{rel}: 中身が合いません")
            datas.append(data)
            if rel == "app.cfg":
                for l in data.decode("utf-8", errors="replace").splitlines():
                    if "=" in l and not l.lstrip().startswith("#"):
                        k, v = l.split("=", 1)
                        cfg[k.strip()] = v.strip()
        icon_rel = cfg.get("icon", "")
        if icon_rel:
            p = os.path.join(base, icon_rel)
            if os.path.isfile(p) and icon_rel.lower().endswith(".pimg"):
                icon_png = pimg_to_png(open(p, "rb").read(), palette)
        pkg = package_name(e["id"], e["version"])
        blob = make_package(e["line"], files_sig, files_tsv, datas)
        write_bytes(os.path.join(args.dir, pkg), blob)
        icon = None
        if icon_png:
            icon = f"{e['id']}-{e['version']}.png"
            write_bytes(os.path.join(args.dir, icon), icon_png)
        cards.append(render_card(e, icon, pkg, len(blob)))
    with open(args.template or STORE_PAGE, encoding="utf-8") as f:
        page = f.read()
    page = (page.replace("<!--@APPS@-->", "\n".join(cards))
                .replace("@@COUNT@@", str(len(cards)))
                .replace("@@UPDATED@@", time.strftime("%Y-%m-%d", time.gmtime())))
    write_bytes(os.path.join(args.dir, "index.html"), page.encode("utf-8"))
    print(f"{args.dir}: index.html と {len(cards)}件のパッケージ")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("keygen", help="署名の鍵を作る")
    p.add_argument("--key", required=True)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_keygen)

    p = sub.add_parser("pubkey", help="秘密鍵から公開鍵を表示する")
    p.add_argument("--key", required=True)
    p.set_defaults(func=cmd_pubkey)

    for name, func, help_text in (("build", cmd_build, "配布物をまるごと作る"),
                                  ("sign", cmd_sign, "署名した目録だけを作る(GitHub Pages向け)")):
        p = sub.add_parser(name, help=help_text)
        p.add_argument("--key", required=True, help="カタログ鍵(catalog.sig)")
        p.add_argument("--author-key", help="作者の鍵(files.sig)。既定は --key と同じ")
        p.add_argument("--author", default=DEFAULT_AUTHOR, help=f"表示する作者名(既定 {DEFAULT_AUTHOR})")
        p.add_argument("--out", required=True)
        p.add_argument("--apps-dir", default=DEFAULT_APPS_DIR)
        p.add_argument("--only", help="配るidをカンマ区切りで(既定は id のある全部)")
        p.add_argument("--serial", type=int, help="版の番号(既定は今のUNIX時刻。前より小さいと本体が断る)")
        if name == "build":
            p.add_argument("--clean", action="store_true", help="--out を消してから作る")
        p.set_defaults(func=func)

    p = sub.add_parser("assemble", help="署名した目録にアプリの中身を写す")
    p.add_argument("--index", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--apps-dir", default=DEFAULT_APPS_DIR)
    p.add_argument("--pubkey", help="この公開鍵の署名だけを受け付ける(16進64桁)")
    p.add_argument("--allow-stale", action="store_true",
                   help="署名の後で中身が変わったアプリは警告して配らない(既定は止まる)")
    p.set_defaults(func=cmd_assemble)

    p = sub.add_parser("verify", help="配布物の署名と中身を確かめる")
    p.add_argument("--dir", required=True)
    p.add_argument("--pubkey")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("site", help="配布物にWebのページとパッケージ(.papp)を足す")
    p.add_argument("--dir", required=True, help="assemble / build の出力")
    p.add_argument("--pubkey")
    p.add_argument("--template", help="ページの雛形(既定 pc/web/store.html)")
    p.set_defaults(func=cmd_site)

    p = sub.add_parser("package", help="手元のアプリを1つパッケージ(.papp)にする")
    p.add_argument("--key", required=True, help="作者の鍵(files.sig)")
    p.add_argument("--app", required=True, help="アプリのディレクトリ(app.cfg に id があること)")
    p.add_argument("--author", default=DEFAULT_AUTHOR, help=f"表示する作者名(既定 {DEFAULT_AUTHOR})")
    p.add_argument("--out", help="書き出す先(既定 <id>-<版>.papp)")
    p.set_defaults(func=cmd_package)

    p = sub.add_parser("author-sign", help="投稿用リポジトリの apps/<id>/ に作者の署名をする")
    p.add_argument("--key", required=True, help="作者の鍵")
    p.add_argument("--app", required=True, help="apps/<id> のディレクトリ")
    p.add_argument("--src", help="先に app/ をこのディレクトリの中身で置き換える")
    p.add_argument("--owner", help="初めての投稿で meta.cfg を作るときの GitHub のアカウント")
    p.add_argument("--dir", help="初めての投稿で meta.cfg を作るときの /lua/apps/ の下の名前")
    p.set_defaults(func=cmd_author_sign)

    p = sub.add_parser("registry-check", help="投稿用リポジトリの検査と自動マージの判定(CI)")
    p.add_argument("--registry", required=True, help="PRの中身")
    p.add_argument("--base", help="main の中身(付けると自動でマージしてよいかも判定する)")
    p.add_argument("--user", help="PRを出したアカウント")
    p.add_argument("--luac", help="luac のパス(付けると .lua の構文を確かめる)")
    p.add_argument("--out", help="結果の JSON")
    p.add_argument("--summary", help="結果の Markdown")
    p.set_defaults(func=cmd_registry_check)

    p = sub.add_parser("registry-build", help="投稿用リポジトリから配布物を作ってカタログに署名する(CI)")
    p.add_argument("--registry", required=True)
    p.add_argument("--key", required=True, help="カタログ鍵")
    p.add_argument("--out", required=True)
    p.add_argument("--prev-catalog", help="今公開している catalog.tsv(serial をそれより大きくする)")
    p.add_argument("--serial", type=int)
    p.set_defaults(func=cmd_registry_build)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
