-- マインスイーパー。難易度3段階(初級/中級/上級)。pico.game(2Dゲームの簡易エンジン)で作っている。
--
-- 盤面はタイルマップ(tiles20/16/14.pimg。script/assets/generate_minesweeper_tiles.py で作る)で、1マス=1タイル。
-- 閉じたマス・開いたマス・数字・旗・地雷は全部「タイルの値」なので、マスを開く/旗を立てるは
-- map:set() するだけで、エンジンが変わったマスだけを描き直す(0マスの連鎖で大きく開いても同じ)。
-- マスの大きさが難易度ごとに違うので、難易度を選ぶたびにタイルマップを作り直す(画像も難易度ごと)。
-- 画面は g:state の3つ: menu(難易度を選ぶ) → play(遊ぶ) → done(クリア/失敗。リセットで続ける)。
local game = require("pico.game")

-- cell: マスの一辺 / gap: 隙間(タイルの右と下に含む) / img: タイルの画像
local DIFFICULTIES = {
    { name = "初級", rows = 9,  cols = 9,  mines = 10, cell = 20, gap = 2, img = "tiles20.pimg" },
    { name = "中級", rows = 12, cols = 12, mines = 22, cell = 16, gap = 1, img = "tiles16.pimg" },
    { name = "上級", rows = 16, cols = 15, mines = 45, cell = 14, gap = 1, img = "tiles14.pimg" },
}
-- タイルの値(画像の左から1番目〜)
local T_HIDDEN, T_BLANK, T_NUM1, T_FLAG, T_MINE = 1, 2, 3, 11, 12

local g = game.new{ bg = 15 }
local HEADER_H = 58                   -- 上の見出しの高さ。盤面はその下(上級でちょうど収まる)

local diff = DIFFICULTIES[1]
local ROWS, COLS, MINES, T
local map, board_x
-- 盤面(1次元。(r-1)*COLS+c)
local mine, revealed, flagged, adjacent = {}, {}, {}, {}
local started, flag_mode, win = false, false, false
local flag_count, revealed_count = 0, 0

-- 効果音(チャンネル2)。勝ったときのジングルは短いMMLを曲として鳴らす(チャンネル1なので効果音に食われない)
local function se(freq, ms, wave, env)
    pico.sound_play(2, freq, ms, { wave = wave or "pulse25", volume = 9, envelope = env or -3 })
end

local function statusDirty() g:dirty(0, 32, g.vw, 24) end

-- ---- 盤面 ----

local function idx(r, c) return (r - 1) * COLS + c end

local function tileOf(i)
    if revealed[i] then
        if mine[i] then return T_MINE end
        return T_BLANK + adjacent[i]       -- 0マスは空きマス、1〜8は数字のタイル
    end
    return flagged[i] and T_FLAG or T_HIDDEN
end

local function refresh(i)
    map:set((i - 1) % COLS, (i - 1) // COLS, tileOf(i))
end

-- 隣の8マスそれぞれに fn(添字) を呼ぶ
local function eachNeighbor(i, fn)
    local r, c = (i - 1) // COLS + 1, (i - 1) % COLS + 1
    for dr = -1, 1 do
        local nr = r + dr
        if nr >= 1 and nr <= ROWS then
            for dc = -1, 1 do
                local nc = c + dc
                if (dr ~= 0 or dc ~= 0) and nc >= 1 and nc <= COLS then fn(idx(nr, nc)) end
            end
        end
    end
end

-- 最初にタップしたマス(safe)を避けて地雷を置き、隣接数を数える
local function placeMines(safe)
    local placed = 0
    while placed < MINES do
        local i = math.random(1, ROWS * COLS)
        if not mine[i] and i ~= safe then
            mine[i] = true
            placed = placed + 1
        end
    end
    for i = 1, ROWS * COLS do
        if not mine[i] then
            local n = 0
            eachNeighbor(i, function(j) if mine[j] then n = n + 1 end end)
            adjacent[i] = n
        end
    end
end

-- 0マスは繋がっている限り開く
local function floodReveal(first)
    local stack, n = { first }, 1
    while n > 0 do
        local i = stack[n]
        stack[n] = nil
        n = n - 1
        if not revealed[i] and not flagged[i] then
            revealed[i] = true
            revealed_count = revealed_count + 1
            refresh(i)
            if adjacent[i] == 0 then
                eachNeighbor(i, function(j)
                    if not revealed[j] and not flagged[j] then
                        n = n + 1
                        stack[n] = j
                    end
                end)
            end
        end
    end
end

local function setFlag(i, on)
    if flagged[i] == on then return end
    flagged[i] = on
    flag_count = flag_count + (on and 1 or -1)
    refresh(i)
end

local function finish(won)
    win = won
    g:go("done")
end

local function onReveal(i)
    if flagged[i] or revealed[i] then return end
    if not started then
        started = true
        -- 毎回違う盤面になるよう、時刻とゲーム内の経過時間で乱数の種を変える
        local t = pico.get_time()
        math.randomseed(math.floor(g.time * 1000) + t.sec * 1000 + t.min * 60000 + t.hour * 3600000)
        placeMines(i)
    end
    if mine[i] then
        se(70, 900, "noise", -2) -- 爆発
        for j = 1, ROWS * COLS do
            if mine[j] and not revealed[j] then revealed[j] = true; refresh(j) end
        end
        finish(false)
        return
    end
    -- 1マスだけならクリック音、0マスで広く開いたら低めの長い音
    if adjacent[i] == 0 then se(440, 120, "triangle", -2) else se(880, 30) end
    floodReveal(i)
    if revealed_count == ROWS * COLS - MINES then
        pico.music_play_text("#tempo 180\nA @pulse25 v11 q7 o5 l16 c e g > c e g > c4")
        for j = 1, ROWS * COLS do          -- 地雷へ自動で旗を立てて見せる
            if mine[j] then setFlag(j, true) end
        end
        finish(true)
    end
end

local function onFlag(i)
    if revealed[i] then return end
    setFlag(i, not flagged[i])
    se(flagged[i] and 1320 or 660, 40, "pulse12")
end

-- ---- 画面ボタン ----

local buttons = {}
local function button(name, x, y, w, h, label)
    local b = g:button{ name = name, x = x, y = y, w = w, h = h, label = label }
    buttons[name] = b
    return b
end

button("back", 4, 2, 42, 28, "left")
button("reset", 50, 2, 76, 28, "リセット")
button("flag", g.vw - 110, 2, 64, 28, "旗:OFF") -- 右の2つは右端に寄せる(240幅で130・198)
button("menu", g.vw - 42, 2, 38, 28, "難度")
for i, d in ipairs(DIFFICULTIES) do
    button("d" .. i, 20, 104 + (i - 1) * 56, g.vw - 40, 44, d.name .. "  " .. d.cols .. "×" .. d.rows .. "  地雷" .. d.mines)
end

-- 今の画面で見せるボタン(隠したボタンはタッチも受けない)
local function showButtons(names)
    local set = {}
    for _, n in ipairs(names) do set[n] = true end
    for n, b in pairs(buttons) do b.visible = set[n] == true end
end

local function setFlagMode(on)
    flag_mode = on
    buttons.flag.label = on and "旗:ON" or "旗:OFF"
    local b = buttons.flag
    g:dirty(b.x, b.y, b.w, b.h)
end

-- ---- 新しい盤面 ----

-- 難易度dの盤面を作る(マスの大きさが違うので、前のタイルマップは捨てて作り直す)
local function buildBoard(d)
    diff = d
    ROWS, COLS, MINES = d.rows, d.cols, d.mines
    T = d.cell + d.gap
    g:clear()
    board_x = (g.vw - COLS * T) // 2
    map = g:tilemap{ image = g:image(pico.path_join(pico.app_dir(), d.img)), tile = T, x = board_x, y = HEADER_H,
                     cols = COLS, data = string.rep(string.char(T_HIDDEN), ROWS * COLS) }
    mine, revealed, flagged, adjacent = {}, {}, {}, {}
    for i = 1, ROWS * COLS do
        mine[i], revealed[i], flagged[i], adjacent[i] = false, false, false, 0
    end
    started, win = false, false
    flag_count, revealed_count = 0, 0
    setFlagMode(false)
end

local function startDifficulty(d)
    buildBoard(d)
    g:go("play")
end

local function centerText(text, y, color, size)
    pico.draw_text(g.x + (g.vw - pico.text_width(text, size or 0)) // 2, g.y + y, text, color, size or 0)
end

function g:on_update()
    if self:pressed("back") then pico.pop() return end
    for i, d in ipairs(DIFFICULTIES) do
        if self:pressed("d" .. i) then startDifficulty(d) return end
    end
    if self.state_name == "menu" then return end
    if self:pressed("menu") then self:go("menu") return end
    if self:pressed("reset") then startDifficulty(diff) return end
    if self:pressed("flag") then
        setFlagMode(not flag_mode)
        se(flag_mode and 990 or 660, 30, "pulse12")
    end
end

function g:on_draw(ox, oy)
    if self.state_name == "menu" then return end
    local text
    if self.state_name == "done" then
        text = win and "クリア!" or "失敗"
    else
        text = "残り:" .. (MINES - flag_count)
    end
    pico.draw_text(ox + 8, oy + 36, text, 0, 0)
    pico.draw_text(ox + g.vw - 8 - pico.text_width(diff.name, 0), oy + 36, diff.name, 8, 0)
end

g:state("menu", {
    enter = function()
        map.visible = false
        showButtons({ "back", "d1", "d2", "d3" })
    end,
    draw = function(_, ox, oy)
        centerText("マインスイーパー", 40, 0, 1)
        centerText("難易度を選んでください", 76, 8, 0)
    end,
})

g:state("play", {
    enter = function()
        map.visible = true
        showButtons({ "back", "reset", "flag", "menu" })
    end,
    update = function()
        if not g.touch.pressed then return end
        local c, r = (g.touch.x - board_x) // T + 1, (g.touch.y - HEADER_H) // T + 1
        if r < 1 or r > ROWS or c < 1 or c > COLS then return end
        local i = idx(r, c)
        if flag_mode then onFlag(i) else onReveal(i) end
        statusDirty()
    end,
})

g:state("done", {
    enter = function()
        map.visible = true
        showButtons({ "back", "reset", "menu" })
    end,
})

pico.on_back(function() pico.pop() end)
buildBoard(diff)
g:go("menu")
