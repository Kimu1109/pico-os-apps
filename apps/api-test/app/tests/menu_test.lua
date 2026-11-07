-- 「動作確認」のメニュー(main.lua)のテスト。picoos lua-test の書き方の見本も兼ねる。
--   cli-tool/picoos lua-test sdcard/lua/apps/動作確認
-- 書き方は lua-api-doc の guide/app/testing.md

test("ページのボタンが8個と戻るボタン", function()
    local app = load_app()
    local buttons = app:find_all { type = "Button" }
    eq(#buttons, 9)
    eq(app:widget("基本の部品").x, 8, "左の余白")
end)

test("ボタンを押すとそのページを開く", function()
    local app = load_app()
    app:tap("画面とデータ")
    eq(app.mock.scene, { kind = "push", path = "/lua/apps/動作確認/scene.lua" })
end)

test("戻るボタンでアプリを閉じる", function()
    local app = load_app()
    local back = app:find_all { type = "Button", icon_id = 30 }
    eq(#back, 1)
    app:tap(back[1])
    ok(app.mock.popped, "pop した")
end)

test("通知から開かれたら通知のページへ送る", function()
    local app = load_app { launch_reason = { "notify", "alarm" } }
    eq(app.mock.scene.path, "/lua/apps/動作確認/notify.lua")
    eq(app.mock.scene.args, { tag = "notify", data = "alarm" })
end)

test("英語では lang/en.lua の名前のボタンになる", function()
    local app = load_app { lang = "en" }
    eq(app:widget("Basic widgets").x, 8, "pico.tr で訳したボタン")
end)
