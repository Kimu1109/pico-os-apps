# pico-os-apps

[pico-os](https://github.com/Kimu1109/pico-os)(Raspberry Pi Pico 2 W で動く自作のタッチGUI OS)のアプリストアの配布元です。
ここにある Lua アプリが、本体のランチャの「ストア」と [Webのページ](https://kimu1109.github.io/pico-os-apps/) に並びます。

**投稿はプルリクエストで受け付けます。** 検査は GitHub Actions がして、決まりを満たす更新は自動でマージし、
main への反映でカタログに署名して GitHub Pages へ出します。配布の形式は pico-os の
[docs/APP_REPO.md](https://github.com/Kimu1109/pico-os/blob/main/docs/APP_REPO.md)、設計の経緯は
[docs/design/lua-apps.md「アプリストアの投稿」](https://github.com/Kimu1109/pico-os/blob/main/docs/design/lua-apps.md)。

## 置き方

```
apps/<id>/meta.cfg     owners = alice, bob   (更新してよい GitHub のアカウント)
                       key    = <作者の公開鍵 16進64桁>
                       dir    = テトリス      (/lua/apps/ の下の名前。日本語可)
                       author = alice        (ストアに出す作者名。無ければ owners の最初)
apps/<id>/app/...      アプリのファイル(main.lua, app.cfg, ...)
apps/<id>/files.tsv    author-sign が作る
apps/<id>/files.sig    〃(作者の鍵の署名)
status.tsv             <id> <TAB> <status> <TAB> <理由>(管理者だけが変える。- / yanked / blocked)
script/                build_app_repo.py・generate_pimg.py(pico-os の写し。直すのは pico-os 側)
web/store.html         Webのページの雛形(同じく pico-os の pc/web/store.html の写し)
```

- 置くのは最新版だけです(本体が取るのも最新版だけ。古い版は git の履歴にあります)。
- `app/` の中身はそのまま配られます。隠しファイル(`.` で始まる名前)とリンクは置けません。
  `tests/` の下と `*_test.lua` は配りません(`picoos lua-test` のテスト用)。
- ファイル名は英数字と `. - _`、4段・95文字まで。1ファイル1MiB・合計4MiB・64ファイルまで。

## 投稿の流れ(作者)

Python 3 だけで動きます(追加のパッケージは要りません)。

1. 作者の鍵を作る(1回だけ)。**秘密鍵は手元にだけ置いてください**(リポジトリにも、どこのサーバにも置かない)。
   ```sh
   python3 script/build_app_repo.py keygen --key ~/.pico-os/author.key
   ```
2. `apps/<id>/app/` にアプリを置く。`<id>` は `app.cfg` の `id` と同じにする(英小文字・数字・`-`・`_`、23文字まで)。
3. 署名する。初めてのときは `--owner`(自分の GitHub のアカウント)と `--dir` を付けると `meta.cfg` も作ります。
   ```sh
   python3 script/build_app_repo.py author-sign --key ~/.pico-os/author.key --app apps/<id> \
       --owner <GitHubのアカウント> --dir <表示するディレクトリ名>
   ```
   2回目からは `--owner`/`--dir` は要りません。中身を変えたら、`app.cfg` の `version` を上げて署名し直してください。
4. プルリクエストを出す。

アプリの書き方は [Lua API のガイド](https://kimu1109.github.io/pico-os/lua-api/)にあります。

## マージの決まり

次の**全部**を満たすPRは自動でマージします。1つでも外れると `needs-review` のラベルが付き、管理者が読んでからマージします。

- 変えたのが1つの `apps/<id>/` の `app/**`・`files.tsv`・`files.sig` だけ(`meta.cfg`・`status.tsv`・`script/`・`.github/` 等に触れていない)
- PRを出したアカウントが、**main の** `meta.cfg` の `owners` にいる
- 検査に通る。版が main より新しい。権限が main の版より増えていない。status が `-`。下書きのPRでない

新しいアプリ・権限が増える更新・`meta.cfg` の変更(鍵や owners の差し替え)は、必ず人が見ます。見るところ:
権限の理由・通信先(`pico.http` 等のURL)・難読化していないか・名前やアイコンのなりすまし・大きさ・id と dir の重なり。

検査(`.github/workflows/check.yml`)は、`files.tsv` が `app/` の中身と合うか・`files.sig` が `meta.cfg` の鍵で合うか・
`app.cfg` の `id`/`version`・配布の形式の制限・`.lua` の構文(`luac -p`)を見ます。**PRの中身は実行しません。**

鍵を無くしたときは、`meta.cfg` の `key` を新しい鍵に替えるPRを出してください(管理者が見ます)。
その版は、入れている端末では「作者の鍵が変わった」になり、一度消してから入れ直すことになります。

## pico-os の公式アプリの更新(管理者)

公式アプリの開発元は pico-os の `pc/sdcard/lua/apps/` です(テストとPCビルドがそこを使うため)。
版を上げてから、pico-os を隣に置いて写して署名し、PRを出します(owners なので、版が上がっていれば自動でマージされます)。

```sh
python3 script/build_app_repo.py author-sign --key ~/.pico-os/app_repo.key --app apps/tetris \
    --src ../pico-os/pc/sdcard/lua/apps/テトリス
```

`--src` は git が管理しているファイルだけを写します(遊んでいる間にできたセーブ等は写らない)。

## 管理者の準備(1回だけ)

1. **Pages**: Settings → Pages → Source を「GitHub Actions」にする。
2. **カタログ鍵**: 手元で作り、秘密鍵を Environment の Secret に入れる。**作者の鍵(公式アプリの署名に使う手元の鍵)とは別の鍵にする**
   (CIが乗っ取られても、公式アプリの偽の更新は作者の鍵が無いと出せないように)。
   ```sh
   python3 script/build_app_repo.py keygen --key ~/.pico-os/catalog.key
   cat ~/.pico-os/catalog.key   # これを Secret に入れる
   ```
   - Settings → Environments → New environment「`catalog`」→ Deployment branches and tags を「Selected branches」で `main` だけにする
     → Environment secrets に `CATALOG_KEY`(上の16進64桁)。
   - 公開鍵(keygen が表示する16進64桁)を、リポジトリの変数 `CATALOG_PUBKEY`(Settings → Secrets and variables → Actions → Variables)に入れる。
     同じ公開鍵を pico-os のファームの `src/apps/store/App_Repo_Keys.hpp` の `kBuiltin` へ足す。
3. **ルールセット**: Settings → Rules → main に、「Require a pull request before merging」(承認の数は0。人が見るPRは管理者がマージする)と、
   「Require status checks to pass」に `検査と判定` を付ける。force push と削除は禁止。
4. **ラベル**: `needs-review` を作る(無くても初めて付けるときにできる)。

## 鍵やアカウントが漏れたとき

| 漏れたもの | できてしまうこと | 直し方 |
|---|---|---|
| カタログ鍵 | 偽の新規アプリを一覧に出す・取り下げの印を付ける(入っているアプリの更新はできない) | 鍵を作り直し、Secret とファームの `kBuiltin` を替える |
| 作者の鍵だけ | 無い(マージには owners のアカウントも要る) | 鍵を替えるPR |
| 作者の GitHub のアカウントだけ | 無い(署名できない) | owners から外すPR |
| 作者の鍵とアカウントの両方 | そのアプリの偽の版を出す | 管理者が `status.tsv` で `blocked` にする |
