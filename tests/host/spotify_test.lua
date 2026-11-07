-- Spotifyリモコン(apps/spotify-remote/app/)を pico_mock.lua の上で動かして確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- 通信は mock.respond() で応答を返す(本物のSpotifyへは行かない)。描画は数えるだけなので、
-- 見た目はPCビルドの --tap / --shot で確かめること。
-- lua_script_test(vendorしたLuaでこのファイルを動かすだけの下請け)から run.sh が呼ぶ。
local mock = dofile(ROOT_DIR .. "/script/host_test/lua/pico_mock.lua")
local APP = APPS_DIR .. "/apps/spotify-remote/app/"
local DIR = "/lua/apps/Spotify"
local fails = 0
local function check(c, m) if c then print("[ OK ] " .. m) else print("[FAIL] " .. m) fails = fails + 1 end end

local loaded = {}
function require(n)
    if loaded[n] == nil then loaded[n] = assert(loadfile(APP .. n .. ".lua"))() end
    return loaded[n]
end

local pico = mock.install({ app_dir = DIR })
-- 本物のアクセストークンは300文字ほどある(json_pick の255バイトを超える。実機で切れて401になった)
local AT_FILE = "BQA" .. string.rep("f", 320)
local AT2 = "BQB" .. string.rep("x", 320)
local AT3 = "BQC" .. string.rep("y", 320)
local RT_LONG = "AQD" .. string.rep("r", 128)
assert(loadfile(APP .. "main.lua"))()
local A, P, V = require("api"), require("player"), require("view")

-- 上の段のボタンとCanvasを見つける
local canvas, btn = nil, {}
local function find_widgets()
    for id, w in pairs(mock.widgets) do
        if w.type == "Canvas" then canvas = id end
        if w.type == "Button" then btn[w.icon_id == 30 and "戻る" or w.text] = id end
    end
end
local function tap(x, y)
    mock.fire(canvas, "press_start", x, y)
    mock.fire(canvas, "press_end", x, y)
end
local function frame(ms) mock.advance(ms or 16) loop() end
local function last() return mock.requests[#mock.requests], #mock.requests end
local function respond_last(ok, status, body, err) local _, i = last() return mock.respond(i, ok, status, body, err) end
local function render() mock.fire(canvas, "render") end
local function find_req(pattern, from)
    for i = from or 1, #mock.requests do
        if mock.requests[i].url:find(pattern, 1, true) then return mock.requests[i], i end
    end
end

-- 画面の場所(content_rect = 0,20,240,300、上の段32px)
local PLAY_X, PREV_X, NEXT_X, SHUF_X, REP_X, CTRL_Y = 120, 72, 168, 24, 216, 52 + 158
local SEEK_Y, VOL_Y = 52 + 104, 52 + 210

-- 再生中の応答(Spotifyの GET /me/player と同じ形)
local function player_json(o)
    o = o or {}
    return pico.json_encode({
        is_playing = o.playing ~= false,
        progress_ms = o.progress or 30000,
        currently_playing_type = o.kind or "track",
        shuffle_state = o.shuffle or false,
        repeat_state = o.rep or "off",
        device = { id = "dev1", name = "My PC", volume_percent = o.volume or 55, supports_volume = true },
        item = {
            name = o.title or "テストの曲",
            duration_ms = 200000,
            artists = { { name = "歌手A" }, { name = "歌手B" }, { name = "歌手C" } },
            album = { name = "アルバム", images = {
                { url = "https://i.scdn.co/image/640", width = 640 },
                { url = o.art or "https://i.scdn.co/image/300", width = 300 },
                { url = "https://i.scdn.co/image/64", width = 64 },
            } },
        },
    })
end

-- =====================================================================
-- ログインしていない
-- =====================================================================
setup()
find_widgets()
check(canvas ~= nil and btn["戻る"] and btn["端末"] and btn["他"], "画面: Canvasと上の段のボタン")
render()
check(mock.draws > 0, "未ログイン: 案内を描く")
frame()
check(#mock.requests == 0, "未ログイン: 通信しない")

-- =====================================================================
-- spotify_auth.json を取り込む → トークンの取り直し → 状態の取得
-- =====================================================================
local auth_path = DIR .. "/spotify_auth.json"
mock.sd[auth_path] = pico.json_encode({ version = 1, client_id = "CID", refresh_token = "RT1",
                                         access_token = AT_FILE, expires_at = 0, obtained_at = 0 })
local bx, by, bw, bh = V.reload_rect()
tap(bx + bw // 2, by + bh // 2)
check(mock.sd[auth_path] == nil, "取り込み: 平文のファイルを消す")
check(type(mock.store) == "table" and mock.store.auth and mock.store.auth.refresh_token == "RT1", "取り込み: 暗号化して保存")
check(A.auth.access_token == AT_FILE, "取り込み: 255バイトを超えるトークンも切らずに読む")
check(P.msg:find("取り込みました") ~= nil, "取り込み: 知らせる")

frame()
local r, ri = last()
check(r and r.url == A.TOKEN_URL and r.method == "POST", "期限切れ: まずトークンを取り直す")
check(r.content_type == "application/x-www-form-urlencoded"
      and r.body == "client_id=CID&grant_type=refresh_token&refresh_token=RT1", "取り直し: フォームの本文")
check(r.opts and r.opts.keep_alive == true, "取り直し: keep_alive")
mock.respond(ri, true, 200, pico.json_encode({ access_token = AT2, token_type = "Bearer", expires_in = 3600,
                                               refresh_token = RT_LONG, scope = "user-read-playback-state" }))
check(A.auth.access_token == AT2 and A.auth.refresh_token == RT_LONG and mock.store.auth.refresh_token == RT_LONG,
      "取り直し: 新しいトークン(refresh tokenも、切らずに)を保存し直す")
r, ri = last()
check(r.url:find("/me/player?market=from_token", 1, true) and r.method == "GET"
      and r.opts.headers.Authorization == "Bearer " .. AT2 and r.opts.keep_alive == true,
      "取得: GET /me/player を Bearer・keep_alive で")
mock.respond(ri, true, 200, player_json())
check(P.st and P.st.playing and P.st.title == "テストの曲" and P.st.artist == "歌手A, 歌手B ほか"
      and P.st.album == "アルバム" and P.st.device == "My PC" and P.st.volume == 55 and P.st.duration == 200000,
      "取得: 状態を読む")
r, ri = last()
check(r.url == "https://i.scdn.co/image/300" and r.opts.save_to == DIR .. "/art.jpg", "ジャケット: 300pxの画像を取る")
mock.respond(ri, true, 200, "JPEGDATA")
check(P.art ~= nil and mock.images[#mock.images].opts.max_w == 80, "ジャケット: 80pxに収めて読む")
render()

-- 時間が進むと再生位置も進む(取り直しまでの間)
local p0 = P.position()
mock.advance(1000)
check(P.position() - p0 == 1000, "再生位置: 取得の間も進めて見せる")
local n = #mock.requests
frame(2100)
check(#mock.requests == n + 1 and last().url:find("/me/player?", 1, true), "取得: 3秒ごとに取り直す")
respond_last(true, 200, player_json({ progress = 33000 }))
check(#mock.requests == n + 1, "ジャケット: 同じ画像は取り直さない")

-- =====================================================================
-- 操作
-- =====================================================================
tap(PLAY_X, CTRL_Y)
r, ri = last()
check(r.method == "PUT" and r.url == A.API .. "/me/player/pause" and r.body == nil, "一時停止: PUT /pause(本文なし)")
check(P.st.playing == false, "一時停止: すぐ見た目を変える")
mock.respond(ri, true, 204, nil)
tap(PLAY_X, CTRL_Y)
r, ri = last()
check(r.method == "PUT" and r.url == A.API .. "/me/player/play", "再生: PUT /play")
mock.respond(ri, true, 204, nil)
tap(NEXT_X, CTRL_Y)
r, ri = last()
check(r.method == "POST" and r.url == A.API .. "/me/player/next", "次へ: POST /next")
mock.respond(ri, true, 204, nil)
-- 前へ: 3秒より後なら曲の頭へ、前なら前の曲へ
tap(PREV_X, CTRL_Y)
r, ri = last()
check(r.method == "PUT" and r.url == A.API .. "/me/player/seek?position_ms=0", "前へ: 3秒より後なら頭へ")
mock.respond(ri, true, 204, nil)
tap(PREV_X, CTRL_Y)
r, ri = last()
check(r.method == "POST" and r.url == A.API .. "/me/player/previous", "前へ: 頭なら前の曲")
mock.respond(ri, true, 204, nil)
tap(SHUF_X, CTRL_Y)
r, ri = last()
check(r.url == A.API .. "/me/player/shuffle?state=true" and P.st.shuffle, "シャッフル")
mock.respond(ri, true, 204, nil)
tap(REP_X, CTRL_Y)
check(last().url == A.API .. "/me/player/repeat?state=context", "リピート: off→context")
respond_last(true, 204, nil)
tap(REP_X, CTRL_Y)
check(last().url == A.API .. "/me/player/repeat?state=track", "リピート: context→track")
respond_last(true, 204, nil)
-- シーク: バーの真ん中をドラッグして離す
mock.fire(canvas, "press_start", 40, SEEK_Y)
check(V.drag and V.drag.kind == "seek", "シーク: 押すとドラッグ")
mock.fire(canvas, "press_move", 120, SEEK_Y)
mock.fire(canvas, "press_end", 120, SEEK_Y)
r = last()
local pos = tonumber(r.url:match("position_ms=(%d+)"))
check(r.method == "PUT" and pos and math.abs(pos - 100000) < 2000, "シーク: 離した所へ(" .. tostring(pos) .. ")")
respond_last(true, 204, nil)

-- 音量: 続けて変えても最後の値を0.4秒後に1回だけ
n = #mock.requests
mock.key_handler("volumeup", {})
mock.key_handler("volumeup", {})
check(#mock.requests == n and P.st.volume == 65, "音量: すぐは送らず見た目だけ")
mock.advance(450)
r = last()
check(#mock.requests == n + 1 and r.url == A.API .. "/me/player/volume?volume_percent=65", "音量: 最後の値を1回だけ送る")
respond_last(true, 204, nil)
mock.fire(canvas, "press_start", 18, VOL_Y) mock.fire(canvas, "press_end", 18, VOL_Y)
mock.advance(450)
check(last().url:find("volume_percent=", 1, true) ~= nil, "音量: −ボタン")
respond_last(true, 204, nil)
mock.key_handler("mute", {})
mock.advance(450)
check(last().url == A.API .. "/me/player/volume?volume_percent=0", "ミュート: 0へ")
respond_last(true, 204, nil)
mock.key_handler("mute", {})
mock.advance(450)
check(last().url:find("volume_percent=0", 1, true) == nil, "ミュート: もう一度で戻す")
respond_last(true, 204, nil)

-- キーとコントローラー
check(mock.key_handler("nexttrack", {}) == true and last().url == A.API .. "/me/player/next", "キー: nexttrack")
respond_last(true, 204, nil)
check(mock.key_handler("x", {}) == false, "キー: 知らないキーは取らない")
n = #mock.requests
mock.pad_pressed = { a = true }
frame()
mock.pad_pressed = nil
local got_pad = false
for i = n + 1, #mock.requests do   -- 同じフレームで定期の取得も出ることがある
    local q = mock.requests[i]
    if q.url == A.API .. "/me/player/pause" or q.url == A.API .. "/me/player/play" then got_pad = true end
    mock.respond(i, true, q.method == "GET" and 200 or 204, q.method == "GET" and player_json() or nil)
end
check(got_pad, "コントローラー: Aで再生/一時停止")

-- 失敗: Premiumが要る
tap(NEXT_X, CTRL_Y)
respond_last(true, 403, pico.json_encode({ error = { status = 403, message = "Player command failed: Premium required",
                                                     reason = "PREMIUM_REQUIRED" } }))
check(P.msg:find("Premium") ~= nil and P.msg_err, "失敗: Premiumが要ることを出す")
tap(NEXT_X, CTRL_Y)
respond_last(true, 404, pico.json_encode({ error = { status = 404, message = "No active device" } }))
check(P.msg:find("端末がありません") ~= nil, "失敗: 端末が無い")

-- 401: トークンを取り直して1回だけ送り直す
tap(NEXT_X, CTRL_Y)
r, ri = last()
mock.respond(ri, true, 401, pico.json_encode({ error = { status = 401, message = "The access token expired" } }))
r, ri = last()
check(r.url == A.TOKEN_URL, "401: トークンを取り直す")
mock.respond(ri, true, 200, pico.json_encode({ access_token = AT3, expires_in = 3600 }))
r, ri = last()
check(r.url == A.API .. "/me/player/next" and r.opts.headers.Authorization == "Bearer " .. AT3, "401: 新しいトークンで送り直す")
check(A.auth.refresh_token == RT_LONG, "401: refresh tokenが返らなければ前のまま")
mock.respond(ri, true, 204, nil)

-- =====================================================================
-- 状態の取得の失敗
-- =====================================================================
local function poll_now()
    P.poll_soon(0)
    frame()
    return last()
end
-- 端末が無い(204)
r, ri = poll_now()
mock.respond(ri, true, 204, nil)
check(P.st == nil and P.msg:find("端末がありません") and P.art == nil, "204: 再生中の端末が無い(画像も外す)")
-- 16KiBを超えた応答 → SDへ保存して読み直す
r, ri = poll_now()
mock.respond(ri, false, 0, nil, "Write failed", nil, { too_large = true })   -- 文は言語で変わるので info.too_large で見分ける
frame()
r, ri = last()
check(r.url:find("/me/player?", 1, true) and r.opts.save_to == DIR .. "/player.json", "大きな応答: SDへ保存して取り直す")
mock.respond(ri, true, 200, player_json({ kind = "episode", title = "番組の回" }))
check(P.st and P.st.title == "番組の回", "大きな応答: SDから読む(sd_json_pick)")
-- 通信の失敗は間を空けて
r, ri = poll_now()
mock.respond(ri, false, 0, nil, "接続できない")
check(P.msg_err and P.msg:find("接続できない"), "通信の失敗: 理由を出す")
n = #mock.requests
frame(3000)
check(#mock.requests == n, "通信の失敗: すぐには取り直さない")
frame(3000)
check(#mock.requests == n + 1, "通信の失敗: 5秒後に取り直す")
respond_last(true, 200, player_json())
check(P.msg == "" and not P.msg_err, "通信の失敗: 取れたら消す")

-- =====================================================================
-- 端末の切り替え
-- =====================================================================
mock.fire(btn["端末"], "press_end")
r, ri = last()
check(r.url == A.API .. "/me/player/devices", "端末: 一覧を取る")
mock.respond(ri, true, 200, pico.json_encode({ devices = {
    { id = "dev1", name = "My PC", is_active = true, type = "Computer" },
    { id = "dev2", name = "スマホ", is_active = false, type = "Smartphone" },
} }))
local dlg = mock.dialogs[#mock.dialogs]
local items = mock.widgets[dlg].args[2]
check(items[1] == "● My PC" and items[2] == "スマホ", "端末: 一覧を選ばせる(今の端末に印)")
mock.close_dialog(dlg, true, 1)
r = last()
check(r.method == "PUT" and r.url == A.API .. "/me/player" and r.content_type == "application/json"
      and pico.json_decode(r.body).device_ids[1] == "dev2", "端末: 選んだ端末へ移す")
respond_last(true, 204, nil)

-- =====================================================================
-- refresh tokenが使えない → 案内の画面へ
-- =====================================================================
A.auth.access_token = ""
r, ri = poll_now()
check(r.url == A.TOKEN_URL, "無効: トークンを取りに行く")
mock.respond(ri, true, 400, pico.json_encode({ error = "invalid_grant", error_description = "Refresh token revoked" }))
check(A.revoked, "無効: 覚える")
frame()
check(P.msg:find("ログインし直して") ~= nil, "無効: ログインし直すよう出す")
n = #mock.requests
frame(20000)
check(#mock.requests == n, "無効: 案内の画面では通信しない")

-- =====================================================================
-- ログアウト・戻る
-- =====================================================================
mock.sd[auth_path] = pico.json_encode({ client_id = "CID", refresh_token = "RT9", expires_at = 0 })
tap(bx + bw // 2, by + bh // 2)
check(A.auth and A.auth.refresh_token == "RT9" and not A.revoked, "ログインし直し: 読み込む")
mock.fire(btn["他"], "press_end")
dlg = mock.dialogs[#mock.dialogs]
mock.close_dialog(dlg, true, 2)   -- ログアウト
mock.advance(50)
dlg = mock.dialogs[#mock.dialogs]
check(mock.widgets[dlg].dialog == "message", "ログアウト: 確かめる")
mock.close_dialog(dlg, true)
check(A.auth == nil and mock.store.auth == nil, "ログアウト: 保存したトークンを消す")

mock.fire(btn["戻る"], "press_end")
check(mock.popped ~= nil and (mock.http_closed or 0) > 0, "戻る: 接続を閉じて戻る")

-- 1ファイルが require の上限(32KiB)・main.lua が16KiBに収まる
for _, f in ipairs { "main", "api", "player", "view" } do
    local fh = assert(io.open(APP .. f .. ".lua", "rb"))
    local size = #fh:read("a")
    fh:close()
    check(size < (f == "main" and 16384 or 32768), f .. ".lua の大きさ " .. size)
end

print("")
if fails > 0 then print("FAILED (failures=" .. fails .. ")") os.exit(1) end
print("ALL PASSED (failures=0)")
