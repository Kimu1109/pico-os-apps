# 標準のLuaアプリのアイコンの元絵

`apps/<id>/app/icon.pimg` の元になったPNG(48x48)。ファイル名はアプリの SD でのフォルダ名(meta.cfg の dir)と同じにする。
アプリのフォルダに置かないのは、ストアで配る中身(`app/` の全部)にPNGが入ってしまうため。

描き直したら、透過を付けずに変換して差し替える(今の `icon.pimg` はこの変換とバイト単位で同じ):

```sh
python3 ../pico-os/cli-tool/picoos pimg script/assets/app_icons/リバーシ.png apps/reversi/app/icon.pimg
```

アプリの版を上げてから公開すること(`docs/design/lua-apps.md`「アプリストアの投稿」)。

| 元絵 | アイコン |
|---|---|
| `ブロック崩し.png` | `apps/breakout/app/icon.pimg` |
| `マインスイーパー.png` | `apps/minesweeper/app/icon.pimg` |
| `リバーシ.png` | `apps/reversi/app/icon.pimg` |

ほかのアプリのアイコンはプログラムで描いている(`script/assets/generate_*_icon.py` 等)か、元絵が残っていない。
元絵が pico-os の `script/secondary-icons/` にあった頃は参照が無く、何の絵か分からなかったのでpico-os の `script/assets/app_icons/` へ移した(2026-11-06)。2026-11-07 に標準アプリと一緒にこのリポジトリへ移した。
