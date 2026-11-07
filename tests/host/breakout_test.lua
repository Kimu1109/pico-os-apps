-- 「ブロック崩し」(apps/breakout/app/)のゲームの規則を、pico.* を差し替えて確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- pico.game は本物(src/lua/builtin/game.lua をそのまま読む)で、描画だけ捨てる。
-- lua_script_test から run.sh が呼ぶ。見た目はPCビルドの --tap / --shot で確かめること。
local APP = "/lua/apps/ブロック崩し/"
-- SDのパス(/lua/apps/ブロック崩し/…)→ このリポジトリのアプリのファイル
local function host(p)
    if p:sub(1, #APP) == APP then return APPS_DIR .. "/apps/breakout/app/" .. p:sub(#APP + 1) end
    return ROOT_DIR .. "/sdcard" .. p   -- アプリの外(pico-os の SD の見本)
end
local fails = 0
local function check(c, msg)
    print((c and "[ OK ] " or "[FAIL] ") .. msg)
    if not c then fails = fails + 1 end
end

local game = assert(load(assert(io.open(ROOT_DIR .. "/src/lua/builtin/game.lua")):read("a"), "=pico.game"))()

local pad, pad_prev = {}, {}
local popped, back_fn, jingles, sounds = false, nil, 0, 0
local nid = 0
pico = setmetatable({
    -- 表示言語(本物は LuaEngine_I18n.cpp)。ここは日本語のまま: 原文を返し、引数があれば format する
    lang = function() return "ja" end,
    tr = function(s, ...) if select("#", ...) > 0 then return string.format(s, ...) end return s end,
    content_rect = function() return 0, 20, 240, 300 end,
    create = function() nid = nid + 1 return nid end,
    millis = function() return 0 end,
    every = function() return 1 end,
    app_dir = function() return APP end,
    path_join = function(a, b) return a .. b end,
    image_load = function() return 1 end,
    image_size = function() return 203, 14 end,
    text_width = function(t) return #t * 6 end,
    get_draw_area = function() return 0, 0, 0, 0 end,
    get_time = function() return { sec = 1, min = 2, hour = 3 } end,
    pad_down = function(n) return pad[n] or false end,
    pad_pressed = function(n) return (pad[n] and not pad_prev[n]) or false end,
    pad_released = function(n) return (pad_prev[n] and not pad[n]) or false end,
    sound_play = function() sounds = sounds + 1 return true end,
    music_play_text = function() jingles = jingles + 1 end,
    on_back = function(f) back_fn = f end,
    pop = function() popped = true end,
}, { __index = function() return function() end end })

local g
local new = game.new
game.new = function(o) g = new(o) return g end
function require(n) return game end

-- LuaSceneは本体(main.lua)より先にlib.luaを読み込み・実行する(グローバルSTAGESで渡る)
assert(load(assert(io.open(host(APP) .. "lib.lua")):read("a"), "lib"))()

local src = assert(io.open(host(APP) .. "main.lua")):read("a")
assert(#src < 15872, "main.lua must stay under 15.5KiB (LuaScene reads 16KiB only): " .. #src)
src = src .. [[
TEST = { S = function() return score, lives, stage_idx, blocks_remaining end,
         balls = function() return balls end, paddle = function() return paddle end,
         map = function() return map end, cx = function() return paddle_cx end,
         load = function(i) stage_idx = i; loadStage(i); readyBall() end,
         set_stage = function(i) stage_idx = i end, auto = function() return auto end,
         spawnItem = spawnItem }
]]
assert(load(src, "=main"))()
local T = TEST

local function step(n, dt)
    for _ = 1, n or 1 do
        g:step(dt or 1 / 60)
        for k in pairs(pad_prev) do pad_prev[k] = nil end
        for k, v in pairs(pad) do pad_prev[k] = v end
    end
end
local function tap(x, y)
    g:_touch("start", x or 120, y or 150)
    step(1)
    g:_touch("end", 0, 0)
    step(1)
end
local function press(name) g._latch[name] = true; step(2) end
local function blocksLeft()
    local m, n = T.map(), 0
    for r = 0, m.rows - 1 do
        for c = 0, m.cols - 1 do
            local v = m:get(c, r)
            if v ~= 0 and v ~= 7 then n = n + 1 end
        end
    end
    return n
end

g:step(0)
g:_render()
check(g.state_name == "ready", "起動するとボールをパドルに載せて待つ")
local score, lives, stage, remain = T.S()
check(score == 0 and lives == 3 and stage == 1, "点0・残機3・ステージ1")
check(remain == 24 and blocksLeft() == 24, "ステージ1は3段x8列=24個 (数えた数 " .. blocksLeft() .. ")")
local ball = T.balls()[1]
check(#T.balls() == 1 and ball.cx == T.cx() and ball.cy < T.paddle().y, "ボールはパドルの上")

-- パドル: コントローラーの左右と、触れた位置
local x0 = T.cx()
pad.left = true; step(10); pad.left = nil; step(1)
check(T.cx() < x0 - 20, "十字キーの左でパドルが動く")
pad.right = true; step(60); pad.right = nil; step(1)
check(T.cx() > x0 + 30, "十字キーの右でパドルが動く")
g:_touch("start", 100, 150); step(1)
g:_touch("move", 60, 150); step(1)
check(math.abs(T.cx() - 60) < 1, "触れている間は指の位置へ")
g:_touch("end", 0, 0); step(1)
step(1)
g:_touch("start", 4, 276); g:_touch("end", 0, 0)   -- 画面の端
step(2)
local pw = T.paddle().w
check(T.cx() >= 4 + pw / 2 - 0.01, "パドルは壁の外へ出ない")

-- 発射(盤面のタップ)
tap(120, 150)
check(g.state_name == "play", "タップで発射")
local b = T.balls()[1]
check(b.dy < 0 and b.dx == 0, "真上へ飛ぶ")

-- 壁で跳ね返る
b.cx, b.cy, b.dx, b.dy = 8, 200, -100, 0
step(10)
check(b.dx > 0, "左の壁で跳ね返る")
b.cx, b.cy, b.dx, b.dy = 232, 200, 100, 0
step(10)
check(b.dx < 0, "右の壁で跳ね返る")
b.cx, b.cy, b.dx, b.dy = 100, 30, 0, -100
step(10)
check(b.dy > 0, "上の壁で跳ね返る")

-- ブロックを壊す(3段目=黄、40点)。下から当てる
local m = T.map()
local before = blocksLeft()
local sc0 = T.S()
b.cx, b.cy, b.dx, b.dy = 5 + 2 * 29 + 13, 24 + 2 * 14 + 12 + 6, 0, -200
step(6)
check(m:get(2, 2) == 0, "当たったブロックは消える")
check(blocksLeft() == before - 1, "残りが1つ減る")
check(T.S() == sc0 + 40, "黄色のブロックは40点 (+" .. (T.S() - sc0) .. ")")
check(b.dy > 0, "ブロックで跳ね返る")

-- 速さは壊したブロックの色で変わる(赤=最速)。下の2段を片付けて、赤の段へ下から当てる
for c = 0, 7 do m:set(c, 1, 0); m:set(c, 2, 0) end
b.cx, b.cy, b.dx, b.dy = 5 + 4 * 29 + 13, 24 + 0 * 14 + 12 + 2, 0, -50
step(2)
local speed = math.sqrt(b.dx * b.dx + b.dy * b.dy)
check(math.abs(speed - (110 + 5) * 2.0) < 1, "赤のブロックに当てると最速になる (" .. string.format("%.1f", speed) .. ")")

-- パドルで跳ね返る(真ん中は真上へ、端は斜めへ)
local py = T.paddle().y
b.cx, b.cy, b.dx, b.dy = T.cx(), py - 12, 0, 120
step(20)
check(b.dy < 0 and math.abs(b.dx) < 1, "パドルの真ん中は真上へ返る")
b.cx, b.cy, b.dx, b.dy = T.cx() + pw / 2 - 1, py - 12, 0, 120
step(20)
check(b.dy < 0 and b.dx > 30, "パドルの端は斜めへ返る (dx=" .. string.format("%.0f", b.dx) .. ")")

-- 落とすと残機が減る → 待ちへ
b.cx, b.cy, b.dx, b.dy = 20, 280, 0, 150
step(60)
check(select(2, T.S()) == 2 and g.state_name == "ready", "落とすと残機2で待ちへ")
check(#T.balls() == 1, "新しいボールが載る")
tap()
local b2 = T.balls()[1]
b2.cx, b2.cy, b2.dx, b2.dy = 20, 280, 0, 150
step(60)
check(select(2, T.S()) == 1, "残機1")
tap()
local b3 = T.balls()[1]
b3.cx, b3.cy, b3.dx, b3.dy = 20, 280, 0, 150
step(60)
check(g.state_name == "over" and select(2, T.S()) == 0, "残機が無くなるとゲームオーバー")
g:_render()
check(jingles >= 3, "ジングルが鳴る")
tap()
check(g.state_name == "ready" and select(2, T.S()) == 3 and T.S() == 0, "タップで最初から(点0・残機3)")

-- アイテム(乱数を差し替えて必ず落とす)
local real_random = math.random
local kind_pick = 1
math.random = function(a, b2)
    if a then return kind_pick end
    return 0
end
tap()
m = T.map()
local sc1 = T.S()
b = T.balls()[1]
b.cx, b.cy, b.dx, b.dy = 5 + 1 * 29 + 13, 24 + 2 * 14 + 12 + 6, 0, -200
step(6)
local items = g:find("item")
check(#items == 1 and items[1].kind == 1, "壊したブロックからアイテムが落ちる")
local it = items[1]
local y0 = it.y
step(30)
check(it.y > y0, "アイテムは落ちてくる")
it.x, it.y = T.cx() - 5, T.paddle().y - 12
step(6)
check(#g:find("item") == 0 and #T.balls() == 4, "三つ又: パドルで拾うとボールが3つ増える (" .. #T.balls() .. ")")
kind_pick = 2
T.spawnItem(T.cx(), T.paddle().y - 12)
step(6)
check(#T.balls() >= 5 and #T.balls() <= 8, "倍: ボールが倍になる (" .. #T.balls() .. ")")
kind_pick = 3
for _, bb in ipairs(T.balls()) do bb.dx, bb.dy = 100, -100 end
T.spawnItem(T.cx(), T.paddle().y - 12)
step(6)
local slow = T.balls()[1]
check(math.abs(math.sqrt(slow.dx ^ 2 + slow.dy ^ 2) - (110 + 5) * 0.7) < 2, "スロー: 一番遅い速さになる")
math.random = real_random

-- 同時に落とせるアイテムは4つまで
for _ = 1, 6 do T.spawnItem(100, 100) end
check(#g:find("item") <= 4, "アイテムは同時に4つまで")

-- ステージクリア → 次のステージ。壊せるブロックを1つずつ下から当てて全部壊す
local function breakAll()
    m = T.map()
    b = T.balls()[1]
    for r = 0, m.rows - 1 do
        for c = 0, m.cols - 1 do
            local v = m:get(c, r)
            if v ~= 0 and v ~= 7 and g.state_name == "play" then
                b.cx, b.cy, b.dx, b.dy = 5 + c * 29 + 13, 24 + r * 14 + 12 + 2, 0, -50
                step(1)
            end
        end
    end
end
T.load(1)
tap()
breakAll()
check(g.state_name == "clear" and select(4, T.S()) == 0, "全部壊すとステージクリア (state=" .. g.state_name .. ")")
g:_render()
tap()
check(g.state_name == "ready" and select(3, T.S()) == 2, "タップで次のステージへ")
check(blocksLeft() > 0, "ステージ2のブロックが並ぶ")

-- 全ステージクリア
T.load(20)
tap()
breakAll()
check(g.state_name == "win", "最後のステージを壊すと全ステージクリア (state=" .. g.state_name .. ")")
g:_render()
tap()
check(g.state_name == "ready" and select(3, T.S()) == 1, "タップで最初から")

-- 20ステージすべてが作れて、壊せるブロックが残っている
local all_ok = true
for i = 1, 20 do
    T.load(i)
    if blocksLeft() ~= select(4, T.S()) or blocksLeft() == 0 then all_ok = false end
end
check(all_ok, "20ステージとも壊せるブロックの数が合う")
T.load(1)

-- 自動プレイ
check(not T.auto(), "自動プレイは最初は切れている")
press("auto")
check(T.auto(), "「自動」ボタンで自動プレイ")
step(2)
check(g.state_name == "play", "自動プレイは発射も自分で行う")
step(30)
local target = STAGES.autoTargetX(T.balls(), T.cx()) - 20
local pw2 = T.paddle().w
target = math.max(4 + pw2 / 2, math.min(236 - pw2 / 2, target))
step(1)
check(math.abs(T.cx() - target) < 0.01, "パドルが落ちてくるボールを追う")
press("auto")

-- 戻る
check(back_fn ~= nil, "on_back を登録している")
back_fn()
check(popped, "HOME/Escで戻る")
popped = false
press("back")
check(popped, "「戻る」ボタンで戻る")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
