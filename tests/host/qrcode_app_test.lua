-- Luaアプリ「QRコード」(apps/qrcode/app/)を pico_mock.lua の上で動かして確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- 追加(種類ごとの入力)・途中のキャンセル・編集・削除・前後の送り・QRに入らない長さ・保存の暗号化・
-- 壊れた保存の読み飛ばし、と、QRにする文字(vCard・Wi-Fiの逃がし)。pico.async は本物を読む。
-- QRが実際に読めることと見た目は、PCビルドの画面写真で確かめた(docs/design/lua-apps.md「QRコード」)。
-- lua_script_test(vendorしたLuaでこのファイルを動かすだけの下請け)から run.sh が呼ぶ。
local mock = dofile(ROOT_DIR .. "/script/host_test/lua/pico_mock.lua")
local APP = APPS_DIR .. "/apps/qrcode/app/main.lua"
local fails = 0
local function check(c, m) if c then print("[ OK ] " .. m) else print("[FAIL] " .. m) fails = fails + 1 end end

local async_src = assert(io.open(ROOT_DIR .. "/src/lua/builtin/async.lua")):read("a")
function require(n)
    assert(n == "pico.async", "想定外のrequire: " .. n)
    return assert(load(async_src, "=pico.async"))()
end

-- アプリを読み直す(store は前の値を引き継げる)
local function start(store)
    mock.install({ app_dir = "/lua/apps/QRコード" })
    mock.store = store
    assert(loadfile(APP))()
end

local function find(kind, pred)
    local found
    for id, w in pairs(mock.widgets) do
        if w.type == kind and (not pred or pred(w)) and (not found or id < found) then found = id end
    end
    return found
end
local function button(text) return find("Button", function(w) return w.text == text and w.visible end) end
local function press(text)
    local id = button(text)
    assert(id, "ボタンが無い: " .. text)
    mock.fire(id, "press_end")
end
-- 表示の画面の矢印(文字が空のボタン。xの小さい方が←)
local function arrow(right)
    local best
    for id, w in pairs(mock.widgets) do
        if w.type == "Button" and w.text == "" and w.visible then
            if not best or (right and w.x > mock.widgets[best].x) or (not right and w.x < mock.widgets[best].x) then best = id end
        end
    end
    mock.fire(best, "press_end")
end
local function last_dialog() local id = mock.dialogs[#mock.dialogs] return id, mock.widgets[id] end
-- 開いているダイアログへ答える(value=nil ならキャンセル)
local function answer(value)
    local id = last_dialog()
    if value == nil then mock.close_dialog(id, false) else mock.close_dialog(id, true, value) end
end
local function qr() return mock.widgets[find("QRCode")] end
local function list() return mock.widgets[find("ScrollList")] end
local function title() return mock.widgets[find("Label", function(w) return w.max_height == 26 end)] end

-- ---- 空で始める ----
start(nil)
check(list().visible and list().item_count == 0, "空: 一覧は0件")
check(find("Label", function(w) return w.visible and (w.text or ""):find("%[追加%]") end) ~= nil, "空: 使い方の案内が出る")
check(not qr().visible, "空: QRは隠れている")

-- ---- 連絡先を追加 ----
press("追加")
local _, d = last_dialog()
check(d.dialog == "choice" and #d.args[2] == 4, "追加: 種類を選ぶ(4種)")
answer(1)                       -- 連絡先
answer("山田 太郎")
answer("090-1234-5678")
answer("taro@example.com")
answer("")                      -- URLは無し
local items = mock.store and mock.store.items
check(items and #items == 1 and items[1].kind == "contact", "連絡先: 保存された")
check(mock.store_opts and mock.store_opts.encrypt == true, "保存は端末の鍵で暗号化")
check(qr().visible and not list().visible, "追加したらその項目の表示へ")
check(qr().text == "BEGIN:VCARD\nVERSION:3.0\nN:山田 太郎;;;;\nFN:山田 太郎\nTEL:090-1234-5678\nEMAIL:taro@example.com\nEND:VCARD",
      "連絡先: vCard(空の項目は出さない)")
check(title().text == "山田 太郎", "表示: 名前")

-- ---- 途中でキャンセルすると何も足さない。もう一度[追加]できる ----
press("一覧")
press("追加")
answer(0)                       -- URL
answer("サイト")
answer(nil)                     -- URLの入力でキャンセル
check(#mock.store.items == 1, "キャンセル: 足さない")
press("追加")
check(last_dialog() and select(2, last_dialog()).dialog == "choice", "キャンセルの後も[追加]できる")
answer(nil)

-- ---- Wi-Fi(逃がし・パスワード無し)----
press("追加")
answer(2)
answer("家")
answer('a;b,c:d"e\\')
answer("p:w")
check(qr().text == 'WIFI:T:WPA;S:a\\;b\\,c\\:d\\"e\\\\;P:p\\:w;;', "Wi-Fi: \\ ; , : \" を逃がす")
press("一覧")
press("追加")
answer(2)
answer("ゲスト")
answer("guest")
answer("")
check(qr().text == "WIFI:T:nopass;S:guest;;", "Wi-Fi: パスワード無しは nopass")

-- ---- URL ----
press("一覧")
press("追加")
answer(0)
answer("GitHub")
check(select(2, last_dialog()).args[2] == "https://", "URL: 入力の初期値は https://")
answer("https://github.com/Kimu1109/pico-os")
check(qr().text == "https://github.com/Kimu1109/pico-os", "URL: そのまま")

-- ---- QRに入らない長さは保存しない ----
press("一覧")
local before = #mock.store.items
press("追加")
answer(3)                       -- テキスト
answer("長いメモ")
answer(string.rep("あ", 100))   -- 300バイト
_, d = last_dialog()
check(d.dialog == "message" and d.args[1]:find("300バイト"), "長すぎ: 知らせる")
answer(true)
check(#mock.store.items == before, "長すぎ: 保存しない")
check(list().visible, "長すぎ: 一覧のまま")

-- ---- 一覧のタップで表示・前後の送り(端で回る)----
check(list().item_count == 4 and list().items[4].text == "GitHub", "一覧: 4件(足した順)")
mock.widgets[find("ScrollList")].selected_index = 0
mock.fire(find("ScrollList"), "select_item", false)
check(title().text == "山田 太郎", "一覧のタップで表示")
arrow(false)
check(title().text == "GitHub", "←で最後へ回る")
arrow(true)
check(title().text == "山田 太郎", "→で最初へ回る")
arrow(true)
check(title().text == "家", "→で次へ")

-- ---- 編集(元の値が初期値。種類は変えない)----
press("編集")
_, d = last_dialog()
check(d.dialog == "input" and d.args[2] == "家", "編集: 名前の初期値は元の名前")
answer("家のWi-Fi")
check(select(2, last_dialog()).args[2] == 'a;b,c:d"e\\', "編集: SSIDの初期値は元の値")
answer("home")
answer("secret")
check(mock.store.items[2].name == "家のWi-Fi" and mock.store.items[2].kind == "wifi", "編集: 同じ場所を書き換える")
check(qr().text == "WIFI:T:WPA;S:home;P:secret;;" and title().text == "家のWi-Fi", "編集: 表示も新しく")

-- ---- 削除(確認で取り消せる)----
press("削除")
answer(nil)
check(#mock.store.items == 4 and qr().visible, "削除: キャンセルなら残す")
press("削除")
check(select(2, last_dialog()).args[1]:find("家のWi-Fi", 1, true), "削除: 名前を出して確かめる")
answer(true)
check(#mock.store.items == 3 and list().visible and list().item_count == 3, "削除: 消して一覧へ")

-- ---- 開き直す: 保存から戻る。壊れた項目は読み飛ばす ----
local saved = mock.store
saved.items[#saved.items + 1] = { kind = "???", name = "x", f = {} }
saved.items[#saved.items + 1] = "壊れた"
start(saved)
check(list().item_count == 3 and list().items[1].text == "山田 太郎", "開き直し: 3件が戻り、壊れた項目は読まない")

-- ---- 50件まで ----
local many = { items = {} }
for i = 1, 50 do many.items[i] = { kind = "text", name = "m" .. i, f = { text = "t" .. i } } end
start(many)
press("追加")
_, d = last_dialog()
check(d.dialog == "message" and d.args[1]:find("50件"), "50件で[追加]は断る")

-- ---- 戻る ----
answer(true)
press("戻る")
check(mock.popped ~= nil, "戻るでアプリを閉じる")

print(fails == 0 and "ALL PASSED" or ("FAILED: " .. fails))
if fails > 0 then os.exit(1) end
