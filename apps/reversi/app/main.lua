-- リバーシ(オセロ)。2人で交互に打つ。pico.game(2Dゲームの簡易エンジン)で作っている。
--
-- 盤面はタイルマップ(tiles.pimg。script/assets/generate_reversi_tiles.py で作る)で、1マス=1タイル。
-- 石の有無・色・打てる場所の印は全部「タイルの値」なので、石を置く/裏返すは map:set() するだけで、
-- エンジンが変わったマスだけを描き直す。タップは g.touch(キャンバスの中の座標)からマスを逆算する。
-- 手番ごとの流れ(打つ / パス / 終局)は g:state の3つの状態。
local game = require("pico.game")

local SIZE, CELL = 8, 24
-- タイルの値(tiles.pimgの左から1,2,3,4枚目)
local T_EMPTY, T_BLACK, T_WHITE, T_HINT = 1, 2, 3, 4
local DIRECTIONS = {
    { -1, -1 }, { -1, 0 }, { -1, 1 },
    { 0, -1 },             { 0, 1 },
    { 1, -1 },  { 1, 0 },  { 1, 1 },
}

local g = game.new{ bg = 15 }
local img = g:image(pico.path_join(pico.app_dir(), "tiles.pimg"))
local BX, BY = (g.vw - SIZE * CELL) // 2, 96
local map = g:tilemap{ image = img, tile = CELL, x = BX, y = BY, cols = SIZE,
                       data = string.rep(string.char(T_EMPTY), SIZE * SIZE) }

-- 盤面(1始まり。0=空, 1=黒, 2=白)と、今の手番で打てる場所
local board, valid = {}, {}
local current = 1
local pass_next        -- パスの表示中: 表示が終わったら手番になる側

for r = 1, SIZE do
    board[r], valid[r] = {}, {}
    for c = 1, SIZE do board[r][c], valid[r][c] = 0, false end
end

local function opponentOf(p) return p == 1 and 2 or 1 end
local function playerName(p) return p == 1 and pico.tr("黒") or pico.tr("白") end

local function countStones()
    local b, w = 0, 0
    for r = 1, SIZE do
        for c = 1, SIZE do
            local v = board[r][c]
            if v == 1 then b = b + 1 elseif v == 2 then w = w + 1 end
        end
    end
    return b, w
end

-- (r,c)へplayerが打ったときに裏返る石の一覧(空なら打てない)
local function flipsForMove(r, c, player)
    if board[r][c] ~= 0 then return {} end
    local opp = opponentOf(player)
    local flips = {}
    for _, d in ipairs(DIRECTIONS) do
        local rr, cc = r + d[1], c + d[2]
        local line = {}
        while rr >= 1 and rr <= SIZE and cc >= 1 and cc <= SIZE and board[rr][cc] == opp do
            line[#line + 1] = { rr, cc }
            rr, cc = rr + d[1], cc + d[2]
        end
        if #line > 0 and rr >= 1 and rr <= SIZE and cc >= 1 and cc <= SIZE and board[rr][cc] == player then
            for _, p in ipairs(line) do flips[#flips + 1] = p end
        end
    end
    return flips
end

local function computeValidMoves(player)
    local vm, count = {}, 0
    for r = 1, SIZE do
        vm[r] = {}
        for c = 1, SIZE do
            local ok = board[r][c] == 0 and #flipsForMove(r, c, player) > 0
            vm[r][c] = ok
            if ok then count = count + 1 end
        end
    end
    return vm, count
end

local function applyMove(r, c, player)
    -- 先に裏返す石を確定させる(石を置いた後だと空きマスでなくなり、何も裏返らない)
    local flips = flipsForMove(r, c, player)
    board[r][c] = player
    for _, p in ipairs(flips) do board[p[1]][p[2]] = player end
end

-- 盤面をタイルへ写す。タイルが変わったマスだけエンジンが描き直す
local function sync(show_hints)
    for r = 1, SIZE do
        for c = 1, SIZE do
            local v = board[r][c]
            local t = (v == 1) and T_BLACK or (v == 2) and T_WHITE
                or (show_hints and valid[r][c]) and T_HINT or T_EMPTY
            map:set(c - 1, r - 1, t)
        end
    end
end

-- 上の状態の行(黒の番 黒:2 白:2)を描き直す
local function statusDirty() g:dirty(0, 30, g.vw, 22) end

local function newGame()
    for r = 1, SIZE do
        for c = 1, SIZE do board[r][c] = 0 end
    end
    board[4][4], board[4][5], board[5][4], board[5][5] = 2, 1, 1, 2
    current = 1
    pass_next = nil                 -- パスの表示中にリセットしても、その続きへ進まない
    valid = computeValidMoves(current)
    sync(true)
    statusDirty()
    g:go("play")
end

-- 打った後の手番交代。次の人が打てなければパス、両方打てなければ終局
local function resolveTurn()
    local mover = current
    current = opponentOf(current)
    local vm, count = computeValidMoves(current)
    if count > 0 then
        valid = vm
        sync(true)
        statusDirty()
        return
    end
    local other = mover
    local ovm, ocount = computeValidMoves(other)
    valid = vm                      -- 全マスfalse(パス中・終局後は印を出さない)
    sync(false)
    statusDirty()
    if ocount == 0 then
        g:go("over")
    else
        pass_next = { player = other, valid = ovm }
        g:go("pass")
    end
end

local function cellAt(x, y)
    local c, r = (x - BX) // CELL + 1, (y - BY) // CELL + 1
    if r < 1 or r > SIZE or c < 1 or c > SIZE then return nil end
    return r, c
end

-- ---- 画面 ----

local function centerText(text, y, color, size)
    pico.draw_text(g.x + (g.vw - pico.text_width(text, size or 0)) // 2, g.y + y, text, color, size or 0)
end

-- 盤面の真ん中に出す枠。lines は1行ずつの文字
local function banner(lines)
    local h = 16 + #lines * 24
    local y = BY + (SIZE * CELL - h) // 2
    pico.fill_rect(g.x + BX + 8, g.y + y, SIZE * CELL - 16, h, 0)
    pico.draw_rect(g.x + BX + 8, g.y + y, SIZE * CELL - 16, h, 15)
    for i, t in ipairs(lines) do centerText(t, y + 8 + (i - 1) * 24, i == 1 and 14 or 15) end
end

function g:on_update()
    if self:pressed("back") then pico.pop() return end
    if self:pressed("reset") then newGame() end
end

-- 盤面の左と上の縁(タイルは右と下の辺だけ線を持つ)
function g:on_draw_world(ox, oy)
    pico.draw_line(ox + BX, oy + BY, ox + BX + SIZE * CELL - 1, oy + BY, 0)
    pico.draw_line(ox + BX, oy + BY, ox + BX, oy + BY + SIZE * CELL - 1, 0)
end

function g:on_draw(ox, oy)
    pico.draw_text(ox + 8, oy + 4, pico.tr("リバーシ"), 0, 1)
    local b, w = countStones()
    local text
    if self.state_name == "over" then
        text = pico.tr("終了  黒:%d 白:%d", b, w)
    else
        text = pico.tr("%sの番  黒:%d 白:%d", playerName(current), b, w)
    end
    pico.draw_text(ox + 8, oy + 32, text, 0, 0)
end

g:button{ name = "back", x = 8, y = 56, w = 59, h = 31, label = "left" }
g:button{ name = "reset", x = 71, y = 56, w = 79, h = 31, label = pico.tr("リセット") }

g:state("play", {
    update = function()
        if not g.touch.pressed then return end
        local r, c = cellAt(g.touch.x, g.touch.y)
        if r and valid[r][c] then
            applyMove(r, c, current)
            resolveTurn()
        end
    end,
})

-- パス: 置ける場所が無い側を知らせる。タップかしばらくで次の人の番へ
local pass_timer
g:state("pass", {
    enter = function() pass_timer = g:after(1.8, function() g:go("play") end) end,
    update = function() if g.touch.pressed then g:go("play") end end,
    exit = function()
        g:cancel(pass_timer)
        if not pass_next then return end
        current, valid = pass_next.player, pass_next.valid
        pass_next = nil
        sync(true)
        statusDirty()
    end,
    draw = function()
        if pass_next then banner({ pico.tr("%sは置ける場所が", playerName(opponentOf(pass_next.player))), pico.tr("無いのでパス") }) end
    end,
})

g:state("over", {
    update = function() if g.touch.pressed then newGame() end end,
    draw = function()
        local b, w = countStones()
        local msg = b > w and pico.tr("黒の勝ち!") or w > b and pico.tr("白の勝ち!") or pico.tr("引き分け")
        banner({ msg, pico.tr("黒%d - 白%d", b, w), pico.tr("タップでもう一度") })
    end,
})

pico.on_back(function() pico.pop() end)
newGame()
