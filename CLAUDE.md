# CLAUDE.md — pico-os-apps

pico-os のアプリストアの配布元(投稿用リポジトリ)。置き方・決まり・管理者の手順は `README.md`。
本体(ファーム・形式の仕様・設計記録)は別リポジトリ [kimu1109/pico-os](https://github.com/Kimu1109/pico-os)
(`docs/spec/APP_REPO.md`、`docs/design/lua-apps.md`「アプリストアの投稿」「標準Luaアプリの置き場所」)。
**pico-os の標準のLuaアプリの正本はここ**(`apps/<id>/app/`。テストは `tests/host/`、絵の道具は `script/assets/`)。

## 決まり

- **`script/build_app_repo.py`・`script/generate_pimg.py`・`web/store.html` は pico-os の写し。ここでは直さない。** 直すのは pico-os
  (`script/release/build_app_repo.py` / `script/tools/generate_pimg.py` / `site/store.html`。ホストテスト `registry_tool_test` 等がそこにある)で、
  マージしてから写し直す。`script/assets/` はここが正本(標準アプリの絵)。
- **`.github/workflows/check.yml` は PR の中身を実行しない**(`pull_request_target` で main の道具が `pr/` をデータとして読む)。
  PRの中身を動かす手順(`npm install`・PRの中のスクリプトの実行・`pr/` の中の設定を読む道具)を足さないこと。
  PRの中身を動かすテストは `test.yml`(`pull_request`・読むだけの権限・Secretなし)に分けてある。こちらに書き込みの権限やSecretを足さないこと。
- `apps/<id>/files.sig` は作者の秘密鍵が無いと作れない。中身(`app/`)を書き換えたら作者が `author-sign` をやり直す必要がある。
  Claude Code は `app/` を直して版を上げるところまでして、署名は利用者に頼む(`sign-changed --key ~/.pico-os/app_repo.key`。README.md「標準アプリの開発」)。
  署名するまで検査(`check.yml`)は落ちる。
- 標準アプリを直したら、pico-os を隣に置いてテストを回す(`sh ../pico-os/script/host_test/run.sh lua-apps`・`picoos lua-test apps`・`i18n.py lua-check apps/*/app`)。
- コメント・文書は日本語。
