# CLAUDE.md — pico-os-apps

pico-os のアプリストアの配布元(投稿用リポジトリ)。置き方・決まり・管理者の手順は `README.md`。
本体(ファーム・形式の仕様・設計記録)は別リポジトリ [kimu1109/pico-os](https://github.com/Kimu1109/pico-os)
(`docs/APP_REPO.md`、`docs/design/lua-apps.md`「アプリストアの投稿」)。

## 決まり

- **`script/` と `web/store.html` は pico-os の写し。ここでは直さない。** 直すのは pico-os(`script/build_app_repo.py` /
  `script/generate_pimg.py` / `pc/web/store.html`。ホストテスト `registry_tool_test` 等がそこにある)で、マージしてから写し直す。
- **`.github/workflows/check.yml` は PR の中身を実行しない**(`pull_request_target` で main の道具が `pr/` をデータとして読む)。
  PRの中身を動かす手順(`npm install`・PRの中のスクリプトの実行・`pr/` の中の設定を読む道具)を足さないこと。
- `apps/<id>/files.sig` は作者の秘密鍵が無いと作れない。中身(`app/`)を書き換えたら作者が `author-sign` をやり直す必要がある。
  Claude Code が中身だけ直しても配れない(検査に落ちる)ので、直したいときは作者(公式アプリなら pico-os の `pc/sdcard/lua/apps/`)へ。
- 公式アプリの開発元は pico-os の `pc/sdcard/lua/apps/`。ここへは `author-sign --src` で写す(README.md「pico-os の公式アプリの更新」)。
- コメント・文書は日本語。
