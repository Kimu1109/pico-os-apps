-- 「リバーシ」(apps/reversi/app/)のゲームの規則を、pico.* を差し替えて確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- pico.game は本物(src/lua/builtin/game.lua をそのまま読む)で、描画だけ捨てる。
-- lua_script_test から run.sh が呼ぶ。見た目はPCビルドの --tap / --shot で確かめること。
local APP = APPS_DIR .. "/apps/reversi/app/"
local fails = 0
local function check(c, msg)
    print((c and "[ OK ] " or "[FAIL] ") .. msg)
    if not c then fails = fails + 1 end
end

local game = assert(load(assert(io.open(ROOT_DIR .. "/src/lua/builtin/game.lua")):read("a"), "=pico.game"))()

local nid, popped = 0, false
pico = setmetatable({
    -- 表示言語(本物は LuaEngine_I18n.cpp)。ここは日本語のまま: 原文を返し、引数があれば format する
    lang = function() return "ja" end,
    tr = function(s, ...) if select("#", ...) > 0 then return string.format(s, ...) end return s end,
    content_rect = function() return 0, 20, 240, 300 end,
    create = function() nid = nid + 1 return nid end,
    millis = function() return 0 end,
    pad_down = function() return false end,
    pad_pressed = function() return false end,
    pad_released = function() return false end,
    every = function() return 1 end,
    image_load = function() return 1 end,
    image_size = function() return 96, 24 end,
    text_width = function(t) return #t * 6 end,
    app_dir = function() return APP end,
    path_join = function(a, b) return a .. b end,
    get_draw_area = function() return 0, 0, 0, 0 end,
    on_back = function() end,
    pop = function() popped = true end,
}, { __index = function() return function() end end })

local g
local new = game.new
game.new = function(o) g = new(o) return g end
function require(n) return game end

-- main.lua の末尾へ、ローカル変数を覗く口(TEST)を足してから読む
local src = assert(io.open(APP .. "main.lua")):read("a")
src = src .. [[
TEST = { board = board, count = countStones, resolve = resolveTurn, sync = sync,
         get = function() return current, valid end, set = function(c) current = c end }
]]
assert(load(src, "=main"))()

local B = 24                       -- 盤面の左 / 上(キャンバスの中の座標)
local TOP = 96
local function map() return g.maps[1] end
local function tile(r, c) return map():get(c - 1, r - 1) end   -- r,c は1始まり
local function tap(r, c)
    g:_touch("start", B + (c - 1) * 24 + 12, TOP + (r - 1) * 24 + 12)
    g:step(1 / 60)
    g:_touch("end", 0, 0)
    g:step(1 / 60)
end
local function press(name)
    g._latch[name] = true
    g:step(1 / 60)
end
local function run(sec) for _ = 1, math.floor(sec * 60) do g:step(1 / 60) end end
local function hints()
    local n = 0
    for r = 1, 8 do for c = 1, 8 do if tile(r, c) == 4 then n = n + 1 end end end
    return n
end

check(g.state_name == "play", "起動すると遊べる")
local T = TEST
local b0, w0 = T.count()
check(b0 == 2 and w0 == 2, "初期配置は黒2・白2")
check(tile(4, 4) == 3 and tile(4, 5) == 2 and tile(5, 4) == 2 and tile(5, 5) == 3, "初期配置のタイル(黒=2, 白=3)")
check(hints() == 4, "黒の打てる場所の印が4つ")

tap(1, 1)
check(tile(1, 1) == 1 and select(2, T.count()) == 2, "打てない場所をタップしても何も起きない")
tap(3, 4)
local b1, w1 = T.count()
check(tile(3, 4) == 2 and tile(4, 4) == 2 and b1 == 4 and w1 == 1, "打つと挟んだ白が裏返る(黒4 白1)")
check(T.get() == 2, "手番が白へ移る")
check(hints() == 3 and tile(3, 5) == 4 and tile(5, 3) == 4, "白の打てる場所に印が付く")
tap(3, 4)
check(select(2, T.count()) == 1, "石のあるマスをタップしても何も起きない")
-- 盤の外(右の余白・上の見出し)のタップは無視する
g:_touch("start", 5, 5); g:step(1 / 60); g:_touch("end", 0, 0); g:step(1 / 60)
g:_touch("start", 230, 200); g:step(1 / 60); g:_touch("end", 0, 0); g:step(1 / 60)
check(T.get() == 2, "盤面の外のタップは無視される")

-- ---- パス: 白が打てず黒が打てる盤面 ----
local board = T.board
local function clear() for r = 1, 8 do for c = 1, 8 do board[r][c] = 0 end end end
clear()
board[1][1], board[1][2] = 1, 2
T.set(1)                      -- 黒が打った直後 → 次は白(打てない)
T.resolve()
check(g.state_name == "pass", "次の人が打てなければパスの状態へ")
check(hints() == 0, "パス中は打てる場所の印を出さない")
tap(1, 3)
check(g.state_name == "play" and T.get() == 1, "タップでパスが終わり、黒の番へ戻る")
check(tile(1, 3) == 4, "黒の打てる場所(1,3)に印が付く")
tap(1, 3)
check(tile(1, 2) == 2 and tile(1, 3) == 2 and select(2, T.count()) == 0, "黒が打って白を裏返す(白0)")
check(g.state_name == "over", "両方打てなければ終局")

-- 時間でもパスが終わる(タップしなくても進む)
clear()
board[1][1], board[1][2] = 1, 2
T.set(1)
T.resolve()
check(g.state_name == "pass", "もう一度パスの状態へ")
run(2.0)
check(g.state_name == "play" and T.get() == 1, "しばらくすると自動で続く")

-- 終局のタップで新しいゲーム
clear()
board[1][1] = 1
T.set(1)
T.resolve()
check(g.state_name == "over", "全部が黒なら終局")
tap(4, 4)
check(g.state_name == "play" and T.get() == 1 and select(1, T.count()) == 2, "終局のあとタップするとやり直せる")

-- リセットボタン(パスの表示中でも新しいゲームになり、パスの続きへは進まない)
clear()
board[1][1], board[1][2] = 1, 2
T.set(1)
T.resolve()
press("reset")
check(g.state_name == "play" and T.get() == 1, "パス中にリセットすると最初の盤面になる")
local b2, w2 = T.count()
check(b2 == 2 and w2 == 2 and tile(1, 3) == 1, "リセットで初期配置へ戻る")
run(2.0)
check(T.get() == 1 and select(1, T.count()) == 2, "リセットのあと古いパスの続きは起きない")

-- 戻る
press("back")
check(popped, "「戻る」で閉じる")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
