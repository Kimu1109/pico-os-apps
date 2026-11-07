-- 「マインスイーパー」(apps/minesweeper/app/)のゲームの規則を、pico.* を差し替えて確かめる。
-- (2026-11-07 に pico-os の script/host_test/ から移した。pico-os のホストテストの lua-apps グループが、
--  lua_script_test で ROOT_DIR = pico-os・APPS_DIR = このリポジトリ として動かす)
-- pico.game は本物(src/lua/builtin/game.lua をそのまま読む)で、描画だけ捨てる。
-- lua_script_test から run.sh が呼ぶ。見た目はPCビルドの --tap / --shot で確かめること。
local APP = APPS_DIR .. "/apps/minesweeper/app/"
local fails = 0
local function check(c, msg)
    print((c and "[ OK ] " or "[FAIL] ") .. msg)
    if not c then fails = fails + 1 end
end

local game = assert(load(assert(io.open(ROOT_DIR .. "/src/lua/builtin/game.lua")):read("a"), "=pico.game"))()

local nid, popped, music = 0, false, 0
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
    image_size = function() return 264, 22 end,
    text_width = function(t) return #t * 6 end,
    app_dir = function() return APP end,
    path_join = function(a, b) return a .. b end,
    get_draw_area = function() return 0, 0, 0, 0 end,
    get_time = function() return { sec = 1, min = 2, hour = 3 } end,
    music_play_text = function() music = music + 1 end,
    on_back = function() end,
    pop = function() popped = true end,
}, { __index = function() return function() end end })

local g
local new = game.new
game.new = function(o) g = new(o) return g end
function require(n) return game end

local src = assert(io.open(APP .. "main.lua")):read("a")
src = src .. [[
TEST = { st = function() return mine, revealed, flagged, adjacent, flag_count, revealed_count end }
]]
assert(load(src, "=main"))()
local T = TEST

-- 乱数は決まった地雷の位置を返す差し替え(placeMines が重複や安全マスを引いたらやり直す)
local mines_at
local seq = 0
math.random = function(a, b)
    seq = seq + 1
    return mines_at[(seq - 1) % #mines_at + 1]
end

local function press(name) g._latch[name] = true g:step(1 / 60) end
local function tapxy(x, y)
    g:_touch("start", x, y)
    g:step(1 / 60)
    g:_touch("end", 0, 0)
    g:step(1 / 60)
end
-- 今の難易度のマス(r,c は1始まり)をタップする
local function cellxy(d, r, c)
    local t = d.cell + d.gap
    local bx = (240 - d.cols * t) // 2
    return bx + (c - 1) * t + t // 2, 58 + (r - 1) * t + t // 2
end
local EASY = { cell = 20, gap = 2, cols = 9, rows = 9 }
local MID = { cell = 16, gap = 1, cols = 12, rows = 12 }
local HARD = { cell = 14, gap = 1, cols = 15, rows = 16 }
local function tapcell(d, r, c) tapxy(cellxy(d, r, c)) end
local function tile(r, c)
    local m = g.maps[1]
    return m:get(c - 1, r - 1)
end
local function start(level, d) press("d" .. level) end

check(g.state_name == "menu", "起動すると難易度の選択")
check(g.maps[1].visible == false, "選択中は盤面を描かない")
press("reset")
check(g.state_name == "menu", "選択中は隠れたボタンが効かない")

-- ---- 初級: 最初の1手で全部開いて勝つ(地雷は上2行) ----
mines_at = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 }
start(1)
check(g.state_name == "play" and g.maps[1].visible, "初級を選ぶと遊べる")
local m = g.maps[1]
check(m.cols == 9 and m.rows == 9 and m.tw == 22, "初級: 9x9 マス・タイル22px")
check(tile(1, 1) == 1, "最初は全部閉じている")
tapcell(EASY, 9, 9)
local mine, revealed, flagged, adjacent, fc, rc = T.st()
check(rc == 71, "最初の1手で0マスが連鎖して開く(開いたマス " .. rc .. ")")
check(tile(9, 9) == 2 and tile(2, 2) == 2 + 4 and tile(3, 1) == 2 + 1, "空きマス=2・数字は2+隣接数")
check(g.state_name == "done", "地雷以外が全部開いたらクリア")
check(tile(1, 1) == 11 and tile(2, 1) == 11, "クリアすると地雷へ旗が立つ")
check(music == 1, "クリアのジングルが鳴る")
tapcell(EASY, 1, 1)
check(g.state_name == "done", "クリア後はタップしても何も起きない")

-- ---- 最初の1手は必ず安全 ----
press("reset")
mines_at = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }   -- 1(最初のマス)は避けられるので11個ぶん
check(g.state_name == "play" and tile(1, 1) == 1, "リセットで新しい盤面")
tapcell(EASY, 1, 1)                     -- 地雷があるはずのマス
mine, revealed = T.st()
check(not mine[1] and revealed[1], "最初にタップしたマスは地雷にならない")
local mc = 0
for i = 1, 81 do if mine[i] then mc = mc + 1 end end
check(mc == 10, "地雷は10個")

-- ---- 地雷を踏むと失敗 ----
press("reset")
mines_at = { 2, 30, 31, 32, 50, 51, 52, 70, 71, 72 }
tapcell(EASY, 1, 1)                     -- (1,1) の隣に地雷(2)
check(g.state_name == "play" and tile(1, 1) == 2 + 1, "隣に地雷が1つなら数字1")
local _, _, _, _, _, rc2 = T.st()
check(rc2 == 1, "数字のマスは連鎖しない")
tapcell(EASY, 1, 2)
check(g.state_name == "done", "地雷を踏むと失敗")
check(tile(1, 2) == 12 and tile(4, 3) == 12, "失敗すると全部の地雷が見える")
local _, _, _, _, _, rc3 = T.st()
check(rc3 == 1, "失敗しても数えるのは安全マスだけ")

-- ---- 旗 ----
press("reset")
mines_at = { 2, 30, 31, 32, 50, 51, 52, 70, 71, 72 }
tapcell(EASY, 5, 5)                     -- 先に最初の1手を済ませる(開く)
local before = select(6, T.st())
press("flag")
check(g.buttons[3].label == "旗:ON", "旗ボタンでモードが切り替わる")
tapcell(EASY, 1, 2)
check(tile(1, 2) == 11 and select(5, T.st()) == 1, "旗モードでタップすると旗が立つ")
tapcell(EASY, 1, 2)
check(tile(1, 2) == 1 and select(5, T.st()) == 0, "もう一度タップすると外れる")
tapcell(EASY, 1, 2)
press("flag")
tapcell(EASY, 1, 2)
check(g.state_name == "play" and tile(1, 2) == 11, "旗の立ったマスは開けない(地雷でも踏まない)")
tapcell(EASY, 5, 5)
check(select(6, T.st()) == before, "開いたマスをもう一度タップしても何も起きない")

-- ---- 難度ボタンで選択へ戻り、中級・上級へ ----
press("menu")
check(g.state_name == "menu" and g.maps[1].visible == false, "「難度」で選択へ戻る")
mines_at = { 1, 2, 3 }
start(2)
m = g.maps[1]
check(m.cols == 12 and m.rows == 12 and m.tw == 17 and #g.maps == 1, "中級: 12x12・タイル17px・盤面は1枚だけ")
press("menu")
start(3)
m = g.maps[1]
check(m.cols == 15 and m.rows == 16 and m.tw == 15, "上級: 15x16・タイル15px")
check(58 + m.rows * m.th <= 300, "上級の盤面が画面に収まる")
mines_at = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
             31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45 }
tapcell(HARD, 16, 15)
check(select(6, T.st()) > 100 and g.state_name ~= "menu", "上級でも連鎖して開く")

press("back")
check(popped, "「戻る」で閉じる")

print(fails == 0 and "ALL OK" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
