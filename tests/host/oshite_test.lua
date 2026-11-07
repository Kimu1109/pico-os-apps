-- 「おしてのぼれ」(apps/oshite/app/)の3つのステージが、操作を流し込むと
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- 実際に解けることを確かめる(pico.game の軽い物理: 押し合い・積み重ね・ばね・動く足場・
-- すり抜け床・スイッチ)。pico.* は描画を捨てる偽物に差し替え、pico.game は本物
-- (src/lua/builtin/game.lua をそのまま読む)。lua_script_test から run.sh が呼ぶ。
-- 見た目はPCビルドの --tap / --shot で確かめること。
local APP = APPS_DIR .. "/apps/oshite/app/"
local fails = 0
local function check(c, msg)
    print((c and "[ OK ] " or "[FAIL] ") .. msg)
    if not c then fails = fails + 1 end
end

-- pico.game の本体を同梱モジュールのソースから取り出す
local game = assert(load(assert(io.open(ROOT_DIR .. "/src/lua/builtin/game.lua")):read("a"), "=pico.game"))()

local nid = 0
pico = setmetatable({
    -- 表示言語(本物は LuaEngine_I18n.cpp)。ここは日本語のまま: 原文を返し、引数があれば format する
    lang = function() return "ja" end,
    tr = function(s, ...) if select("#", ...) > 0 then return string.format(s, ...) end return s end,
    content_rect = function() return 0, 24, 240, 296 end,
    create = function() nid = nid + 1 return nid end,
    millis = function() return 0 end,
    pad_down = function() return false end,
    pad_pressed = function() return false end,
    pad_released = function() return false end,
    every = function() return 1 end,
    image_load = function() return 1 end,
    image_size = function() return 128, 32 end,
    text_width = function(t) return #t * 6 end,
    app_dir = function() return APP end,
    path_join = function(a, b) return a .. b end,
    get_draw_area = function() return 0, 0, 0, 0 end,
}, { __index = function() return function() end end })

local g
local new = game.new
game.new = function(o) g = new(o) return g end
function require(n)
    if n == "pico.game" then return game end
    return dofile(APP .. n .. ".lua")
end
dofile(APP .. "main.lua")
check(g ~= nil and g.state_name == "title", "起動するとタイトル")

-- ---- 操作の道具 ----
local function hold(keys)
    for k in pairs(g._held) do g._held[k] = nil end
    for _, k in ipairs(keys or {}) do g._held[k] = true end
end
local function run(sec, keys)
    hold(keys)
    for _ = 1, math.floor(sec * 60) do g:step(1 / 60) end
end
local function till(keys, cond, sec)
    hold(keys)
    for _ = 1, math.floor((sec or 5) * 60) do
        g:step(1 / 60)
        if cond() then return true end
    end
    return false
end
local function P() return g:find("player")[1] end
local function jump(dir)
    local k = dir and { dir, "a" } or { "a" }
    g._latch.a = true
    run(0.02, k)
    till(k, function() return P().vy >= 0 end, 2)
    till(dir and { dir } or {}, function() return P().on_ground end, 2)
end
local function play_stage()
    run(1.7)   -- ステージ名を見せる間
    return g.state_name == "play"
end
local function next_stage()
    till({}, function() return g.state_name == "intro" end, 4)
    return play_stage()
end

g._latch.a = true
run(0.05)
check(play_stage(), "Aで始まり、ステージ1を遊べる")

-- ---- 1. 箱を押して壁を登る・動く足場・すり抜け床 ----
local c = g:find("crate")[1]
-- 箱を使わずに壁際で跳んでも上に乗れない
P().x = 205
till({}, function() return P().on_ground end, 1)
jump("right")
run(0.3, { "right" })
check(P().y == 192 and P().x < 224, "1: 箱が無いと壁(4マス)は越えられない")
P().x = 40
run(0.3)
check(till({ "right" }, function() return c.x + 16 >= 223.9 end, 8), "1: 木箱を壁まで押せる")
till({ "left" }, function() return P().x < c.x - 30 end, 3)
run(0.3)
jump("right")
check(P().on_ground and P().y == 176, "1: 箱の上に乗れる")
run(0.1, { "left" })
jump("right")
check(P().on_ground and P().y == 128, "1: 箱から壁の上へ跳べる")
till({ "right" }, function() return P().x > 330 end, 3)
run(0.2)
local lift = g:find("lift")[1]
till({}, function() return lift.x <= 352.1 and lift.wait > 0.5 end, 8)
till({ "right" }, function() return P().x > 360 end, 2)
run(0.3)
check(P().on_ground, "1: 動く足場に乗れる")
local x0, lx0 = P().x, lift.x
check(till({}, function() return lift.x >= 415.9 end, 4), "1: 足場が向こう岸へ動く")
check(math.abs((P().x - x0) - (lift.x - lx0)) < 1, "1: 乗ったまま運ばれる")
till({ "right" }, function() return P().x > 496 end, 3)
run(0.2)
jump()
check(P().on_ground and P().y == 144, "1: すり抜け床へ下から跳び乗れる")
till({ "down" }, function() return P().y > 180 end, 1)
check(P().y > 180, "1: ↓ですり抜け床から降りられる")
check(till({ "right" }, function() return g.state_name == "clear" end, 4), "1: 旗でクリア")

-- ---- 2. 重い鉄箱でスイッチ・扉・ばね ----
check(next_stage(), "ステージ2へ進む")
local iron = g:find("crate")[1]
local m = g.maps[1]
check(iron.mass == 4 and m:get(18, 10) == 5, "2: 鉄箱は重く、扉は閉じている")
local t = 0
check(till({ "right" }, function() t = t + 1; return iron.x >= 160 end, 10), "2: 鉄箱を押せる")
check(t / 60 > 2.0, string.format("2: 鉄箱は木箱より遅い(%.1f秒)", t / 60))
check(m:get(18, 10) == 0, "2: 鉄箱がスイッチを押さえると扉が開く")
till({ "left" }, function() return P().x < iron.x - 30 end, 3)
jump("right")
till({ "right" }, function() return P().x > 372 end, 4)
check(P().x > 300 and m:get(18, 10) == 0, "2: 主人公が離れても扉は開いたまま(鉄箱が押さえている)")
g._latch.a = true
local top = 999
for _ = 1, 120 do
    hold(P().x < 404 and { "right" } or {})   -- 棚の上まで流れたら手を離して降りる
    g:step(1 / 60)
    top = math.min(top, P().y)
end
check(top < 80, string.format("2: ばねで高く跳ぶ(y=%.0f)", top))
check(P().on_ground and P().y == 96, "2: ばねで高い棚(すり抜け床)に乗れる")
till({ "right" }, function() return P().x > 450 end, 2)
check(#g:find("star") == 0, "2: 高い棚の星が取れる")
check(till({ "right" }, function() return g.state_name == "clear" end, 5), "2: 旗でクリア")

-- ---- 3. 箱を2段に積む・縦に動く足場 ----
check(next_stage(), "ステージ3へ進む")
local cs = g:find("crate")
table.sort(cs, function(a, b) return a.y > b.y end)
local A, B = cs[1], cs[2]
check(till({ "right" }, function() return A.x >= 319.9 end, 10), "3: 下の箱を壁まで押す(棚と足場の下を通る)")
P().x = A.x - 20
till({}, function() return P().on_ground end, 1)
jump("right")
jump("right")
check(P().y > 130, "3: 箱1つでは壁(5マス)に届かない")
till({ "left" }, function() return P().x < 150 end, 5)
lift = g:find("lift")[1]
till({}, function() return lift.y >= 207.9 and lift.wait > 0.7 end, 8)
till({ "right" }, function() return P().x >= 180 end, 2)
run(0.1)
check(till({}, function() return lift.y <= 160.1 end, 4) and P().y < 150, "3: 縦の足場で棚の高さへ運ばれる")
check(P().on_ground, "3: 上がる足場の上でも on_ground のまま")
check(till({ "right" }, function() return B.x >= 318 end, 8), "3: 棚の箱を押して端から落とす")
run(1.0, { "right" })
check(B.x == A.x and math.abs(B.y + 16 - A.y) < 0.5, "3: 落とした箱が下の箱の上に積まれる")
jump("right")
check(P().on_ground and P().y == 112, "3: 2段の箱から壁の上へ跳べる")
check(till({ "right" }, function() return g.state_name == "clear" end, 5), "3: 旗でクリア")
till({}, function() return g.state_name == "ending" end, 4)
check(g.state_name == "ending", "全ステージでエンディング")

-- ---- Bでやり直し・穴に落ちるとやり直し ----
g:go("intro")
play_stage()
local p = P()
p.x = 300
till({}, function() return p.x ~= 300 end, 0.1)
g._latch.b = true
run(0.05)
check(g.state_name == "intro", "Bでステージをやり直す")
play_stage()
P().x, P().y = 380, 230
check(till({}, function() return g.state_name == "miss" end, 2), "穴に落ちるとミス")
check(till({}, function() return g.state_name == "play" end, 5), "ミスの後は同じステージをやり直す")

if fails > 0 then
    print(fails .. "件の失敗")
    os.exit(1)
end
print("全て成功")
os.exit(0)
