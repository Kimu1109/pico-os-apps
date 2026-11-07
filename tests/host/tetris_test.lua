-- テトリス(apps/tetris/app/)のゲームの規則を、pico.* を差し替えて確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- pico.game は本物(src/lua/builtin/game.lua をそのまま読む)で、描画だけ捨てる。
-- lua_script_test(vendorしたLuaでこのファイルを動かすだけの下請け)から run.sh が呼ぶ。
-- 見た目はPCビルドの --tap / --shot で確かめること(ここでは描画は数えるだけ)。
-- main.lua の末尾へ TEST(ローカル変数を覗く口)を足してから読み込む
local DIR = "/lua/apps/テトリス/"
-- SDのパス(/lua/apps/テトリス/…)→ このリポジトリのアプリのファイル
local function host(p)
    if p:sub(1, #DIR) == DIR then return APPS_DIR .. "/apps/tetris/app/" .. p:sub(#DIR + 1) end
    return ROOT_DIR .. "/sdcard" .. p   -- アプリの外(pico-os の SD の見本)
end
local fails = 0
local function check(c, m) if c then print("[ OK ] " .. m) else print("[FAIL] " .. m) fails = fails + 1 end end

local game = assert(load(assert(io.open(ROOT_DIR .. "/src/lua/builtin/game.lua")):read("a"), "=pico.game"))()

local files_written = {}
local pad, pad_prev = {}, {}
local draws, popped, music_on = 0, false, false
local back_fn
local nid = 0
pico = setmetatable({
    -- 表示言語(本物は LuaEngine_I18n.cpp)。ここは日本語のまま: 原文を返し、引数があれば format する
    lang = function() return "ja" end,
    tr = function(s, ...) if select("#", ...) > 0 then return string.format(s, ...) end return s end,
    content_rect = function() return 0, 20, 240, 300 end,
    create = function() nid = nid + 1 return nid end,
    millis = function() return 0 end,
    every = function() return 1 end,
    app_dir = function() return DIR end,
    path_join = function(a, b) return a .. b end,
    image_load = function() return 1 end,
    image_size = function() return 120, 12 end,
    text_width = function(t) return #t * 6 end,
    sd_read = function(p)
        if files_written[p] then return files_written[p] end
        local f = io.open(host(p), "rb")
        if not f then return nil end
        local s = f:read("a")
        f:close()
        return s
    end,
    sd_write = function(p, s) files_written[p] = s return true end,
    log = function(s) print("LOG", s) end,
    get_draw_area = function() return 0, 0, 0, 0 end,
    pad_down = function(n) return pad[n] or false end,
    pad_pressed = function(n) return (pad[n] and not pad_prev[n]) or false end,
    pad_released = function(n) return (pad_prev[n] and not pad[n]) or false end,
    sound_play = function() return true end,
    music_play = function(p) music_on = true return pico.sd_read(p) ~= nil end,
    music_stop = function() music_on = false end,
    on_back = function(f) back_fn = f end,
    pop = function() popped = true end,
}, { __index = function() return function() draws = draws + 1 end end })
for _, n in ipairs { "fill_rect", "draw_rect", "draw_text", "draw_line", "draw_circle", "draw_image_part" } do
    pico[n] = function() draws = draws + 1 end
end

local g
local new = game.new
game.new = function(o) g = new(o) return g end
function require(n) return game end

-- LuaSceneは本体(main.lua)より先に同じディレクトリのlib.luaを読み込み・実行する
-- (LuaScene.hppのクラスコメント参照)。ここでも同じ順序を再現する
assert(load(assert(io.open(host(DIR) .. "lib.lua")):read("a"), "lib"))()

local src = assert(io.open(host(DIR) .. "main.lua")):read("a")
assert(#src < 15872, "main.lua must stay under 15.5KiB (LuaScene reads 16KiB only): " .. #src)
src = src .. [[
TEST = { grid = grid, spawn = spawn, map = map, piece = piece_s, ghost = ghost_s,
         S = function() return g.state_name, score, lines, level, p, rot, px, py, hold, hiscore end }
]]
assert(load(src, "=main"))()

local function step(n, ms)
    for _ = 1, n or 1 do
        g:step((ms or 16) / 1000)
        for k in pairs(pad_prev) do pad_prev[k] = nil end
        for k, v in pairs(pad) do pad_prev[k] = v end
    end
end
local function pressPad(name) pad[name] = true; step(1); pad[name] = nil; step(1) end
local function tap(x, y)
    g:_touch("start", x, y)
    step(1)
    g:_touch("end", 0, 0)
    step(1)
end
local function S() return TEST.S() end
local W = 10
local grid = TEST.grid
local function tile(x, y) return TEST.map:get(x, y) end

g:step(0)
g:_render()
check(draws > 0, "描画が最後までエラー無く走る")

check(S() == "title", "起動するとタイトル")
tap(60, 100)                              -- 盤面のタップ
check(S() == "play", "盤面をタップすると始まる")
check(music_on, "BGMが始まる")
step(1)
check(tile(0, 19) == 10 and tile(9, 0) == 10, "空きマスは黒のタイル(10)")

-- 左に押し続ける → 壁まで
pad.left = true; step(40); pad.left = nil; step(1)
local _, _, _, _, p, rot, px = S()
check(px <= 1, "押し続けると壁まで動く (px=" .. px .. ")")

-- HOLD
local _, _, _, _, p0 = S()
pressPad("l")
local _, _, _, _, p1, _, _, _, hold = S()
check(hold == p0 and p1 ~= nil, "HOLDで今のミノを取っておく")
pressPad("l")
local _, _, _, _, p2, _, _, _, hold2 = S()
check(hold2 == p0 and p2 == p1, "HOLDは1個につき1回だけ")

-- 落ちているミノとゴーストのスプライト
local ps, gs = TEST.piece[1], TEST.ghost[1]
local st, _, _, _, pp, rr, pxx, pyy = S()
check(ps.frame == pp - 1 and ps.x % 12 == 5 % 12, "落ちているミノのスプライトの絵と位置")
check(gs.y >= ps.y, "ゴーストはミノの真下(以下)")

-- 1ライン消し: 最下段を4マス(3..6)残して埋め、Iを落とす
for i = 1, #grid do grid[i] = 0 end
for x = 0, 9 do if x < 3 or x > 6 then grid[21 * W + x + 1] = 5 end end
TEST.spawn(1)
pressPad("up")
local st, score, lines = S()
check(st == "clear" and lines == 1, "1ライン消し (state=" .. st .. ", lines=" .. lines .. ")")
check(tile(0, 19) == 9 and tile(9, 19) == 9 and tile(4, 19) == 9, "消える行は白く光る")
step(20)
st = S()
check(st == "play", "光った後は続きから")
local empty = true
for x = 0, 9 do if grid[21 * W + x + 1] ~= 0 then empty = false end end
check(empty and tile(0, 19) == 10, "最下段が空になる")

-- ミノが固まるとタイルになる(Iが最下段に横向き)
for i = 1, #grid do grid[i] = 0 end
TEST.spawn(1)
pressPad("up")
check(tile(3, 19) == 1 and tile(6, 19) == 1 and tile(2, 19) == 10, "固まったミノは盤面のタイルになる")

-- テトリス: 下4段を列5以外埋めて、縦にしたIを落とす
for i = 1, #grid do grid[i] = 0 end
for y = 18, 21 do for x = 0, 9 do if x ~= 5 then grid[y * W + x + 1] = 3 end end end
local _, sc0 = S()
TEST.spawn(1)
pressPad("a")  -- 右回転: 縦で列px+2=5
local _, _, _, _, _, r, ppx = S()
check(r == 1 and ppx == 3, "Iが縦になり列5に来る")
pressPad("up")
local st2, sc1, lines2 = S()
check(lines2 == 5 and sc1 - sc0 >= 800, "テトリス: 4ライン、+800 (+" .. (sc1 - sc0) .. ")")
step(20)
local all_empty = true
for i = 1, #grid do if grid[i] ~= 0 then all_empty = false end end
check(all_empty, "テトリスのあと盤面が空")

-- 壁蹴り: 右壁にくっつけたTを回転できる
TEST.spawn(3)
pad.right = true; step(40); pad.right = nil; step(1)
pressPad("b"); pressPad("b")
local _, _, _, _, _, rr2 = S()
check(rr2 == 2, "壁際でもTが回る (rot=" .. rr2 .. ")")

-- ゲームオーバー → ハイスコア保存
for y = 1, 3 do for x = 3, 6 do grid[y * W + x + 1] = 2 end end
TEST.spawn(4)
local st3, sc3 = S()
check(st3 == "over", "出現位置が埋まっていたらゲームオーバー")
check(files_written[DIR .. "hiscore.txt"] == tostring(sc3), "ハイスコアを保存する")
check(not music_on, "ゲームオーバーでBGMが止まる")
g:step(0); g:_render()
pressPad("start")
check(S() == "play", "STARTでやり直せる")

-- 一時停止
pressPad("start")
check(S() == "pause", "STARTで一時停止")
check(not music_on, "一時停止中はBGMが止まる")
g:_render()
tap(60, 100)
check(S() == "play", "盤面のタップで再開")
check(music_on, "再開でBGMが戻る")
g._latch.pause = true; step(2)
check(S() == "pause", "「停止」ボタンで一時停止")
g._latch.pause = true; step(2)
check(S() == "play", "もう一度押すと再開")

-- タッチの操作ボタン: 左端のボタン(左移動)
local _, _, _, _, _, _, pxa = S()
tap(10, 270)
local _, _, _, _, _, _, pxb = S()
check(pxb == pxa - 1, "左のボタンで左へ動く")
-- 押したまま指を滑らせると隣のボタンへ移る
g:_touch("start", 10, 270); step(1)
g:_touch("move", 50, 270); step(1)
g:_touch("end", 0, 0); step(2)
local _, _, _, _, _, _, pxc = S()
check(pxc == pxb - 1, "押したまま滑らせても取りこぼさない (px " .. pxb .. "→" .. pxc .. ")")

-- 重力: 落下中のミノが時間で下がる
local _, _, _, _, _, _, _, pya = S()
step(70)
local _, _, _, _, _, _, _, pyb = S()
check(pyb > pya, "時間でミノが落ちる")
g:_render()

-- 戻る(HOMEとEscは pico.on_back、画面の「戻る」ボタン)
check(back_fn ~= nil, "on_back を登録している")
back_fn()
check(popped, "HOME/Escで戻る")
popped = false
g._latch.back = true; step(1)
check(popped, "「戻る」ボタンで戻る")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
