-- ブロック崩し。pico.game(2Dゲームの簡易エンジン)で作っている。
-- ブロック=タイルマップ(tiles.pimg。1〜6が速さの段、7が壊せない灰)。ボール・パドル・アイテム=スプライト。
-- ステージクリア等は g:state の枠。ステージの定義は lib.lua(グローバルSTAGES)。
-- コントローラー: 左右=パドル、A/START/上=発射・次へ、HOME=戻る。
-- ※LuaSceneが読むのは16KiBまで(日本語コメントは1文字3バイト)。足すときは余裕を見ること
local game = require("pico.game")
local STAGES = STAGES

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local COLS = STAGES.cols

-- 速さの段。1が最速(赤)、6が最遅(青)
local TIER_MULT = { 2.0, 1.6, 1.35, 1.25, 1.0, 0.7 }
local TIER_POINTS = { 60, 50, 40, 30, 20, 10 }
local WALL_TIER = -1 -- lib.luaのWALLと同じ値
local T_WALL = 7
local function baseSpeed(stage) return 110 + stage * 5 end -- px/秒

local BLOCK_W, BLOCK_H, GAP = 27, 12, 2
local TW, TH = BLOCK_W + GAP, BLOCK_H + GAP    -- タイル(ブロック+隙間)
local BALL_R = 4
local PADDLE_H = 8
-- パドル幅はステージが進むほど狭くする(5ステージごとに4px、最小28px)
local PADDLE_W_MAX, PADDLE_W_MIN, PADDLE_W_STEP, PADDLE_W_STAGE_SPAN = 40, 28, 4, 5
local function paddleWidthForStage(stage)
    local w = PADDLE_W_MAX - math.floor((stage - 1) / PADDLE_W_STAGE_SPAN) * PADDLE_W_STEP
    return math.max(PADDLE_W_MIN, w)
end
-- drawは w x h の外へ描かない(残る)。fill_circleは直径2r+1画素なので、ボールは9x9・アイテムは11x11
local BALL_SIZE = BALL_R * 2 + 1
local ITEM_SIZE = 11
local ITEM_TRIBALL, ITEM_DOUBLE, ITEM_SLOW = 1, 2, 3
local ITEM_FALL_SPEED = 70 -- px/秒
local DROP_CHANCE = 0.2
local MAX_BALLS = 16
local MAX_ITEMS = 4
local STEP_MAX = 6 -- サブステップ分割の閾値(px)。低フレームレートでの貫通防止
local PAD_SPEED = 220 -- コントローラーでのパドルの速さ(px/秒)
local MAX_ANGLE = 1.1 -- パドル反射の最大角(ラジアン)

local g = game.new{ bg = 15 }
local cw, ch = g.vw, g.vh
local MARGIN = 4
local field_x = MARGIN
local field_w = cw - MARGIN * 2
local TOP_WALL = 22
local BLOCK_TOP = TOP_WALL + 2
local BLOCK_X = field_x + (field_w - (COLS * TW - GAP)) // 2
local paddle_y = ch - 24
local BOTTOM_LIMIT = ch

local img = g:image(pico.path_join(pico.app_dir(), "tiles.pimg"))
local map, paddle
local paddle_w = paddleWidthForStage(1)

local score, lives, stage_idx = 0, 3, 1
local blocks_remaining = 0
local balls = {}
local paddle_cx = field_x + field_w / 2
local auto = false      -- 自動プレイ(右上の「自動」。バッテリー計測用の放置プレイ)
local auto_btn

-- 効果音はch2で1フレーム1回、優先度の高いもの(ボールが多いと命令の列が溢れる)
local snd
local function se(pri, f, ms, wave)
    if not snd or pri > snd[1] then snd = { pri, f, ms, wave or "pulse25" } end
end
-- ジングルは短いMMLを曲として鳴らす(ch1)
local function jingle(mml)
    pico.music_play_text("#tempo 200\nA @pulse25 v11 q7 o5 l16 " .. mml)
end

local function hudDirty() g:dirty(0, 0, g.vw, TOP_WALL) end

-- ---- スプライトの絵 ----

local function ballDraw(_, x, y) pico.fill_circle(x + BALL_R, y + BALL_R, BALL_R, 0) end
-- アイテム: 1=3つに増える(黄の四角) 2=倍にする(シアンの円) 3=ゆっくり(青の三角)
local ITEM_DRAWS = {
    function(_, x, y) pico.fill_rect(x, y, ITEM_SIZE, ITEM_SIZE, 14) end,
    function(_, x, y) pico.fill_circle(x + ITEM_SIZE // 2, y + ITEM_SIZE // 2, ITEM_SIZE // 2, 11) end,
    function(_, x, y) pico.fill_triangle(x, y + ITEM_SIZE - 1, x + ITEM_SIZE // 2, y, x + ITEM_SIZE - 1, y + ITEM_SIZE - 1, 9) end,
}

local function newBall(cx, cy, dx, dy)
    local b = g:sprite{ x = cx - BALL_R, y = cy - BALL_R, w = BALL_SIZE, h = BALL_SIZE, layer = 3,
                        draw = ballDraw, tag = "ball", cx = cx, cy = cy, dx = dx, dy = dy }
    balls[#balls + 1] = b
    return b
end

local function placeBall(b)
    b.x, b.y = b.cx - BALL_R, b.cy - BALL_R
end

-- ---- ステージ ----

local function loadStage(idx)
    local data = STAGES.list[idx]
    g:clear()                       -- 前のステージのものを全部消す
    local bytes, parts = {}, {}
    blocks_remaining = 0
    for r = 1, data.rows do
        for c = 1, COLS do
            local tier = data.cell(r, c)
            local v = 0
            if tier == WALL_TIER then v = T_WALL
            elseif tier ~= 0 then v = tier; blocks_remaining = blocks_remaining + 1 end
            bytes[c] = v
        end
        parts[r] = string.char(table.unpack(bytes, 1, COLS))
    end
    map = g:tilemap{ image = img, tile_w = TW, tile_h = TH, x = BLOCK_X, y = BLOCK_TOP,
                     data = table.concat(parts), cols = COLS }
    paddle_w = paddleWidthForStage(idx)
    paddle = g:sprite{ x = 0, y = paddle_y, w = paddle_w, h = PADDLE_H, color = 1, tag = "paddle", layer = 2 }
    balls = {}
    hudDirty()
end

local function setPaddle(x)
    paddle_cx = clamp(x, field_x + paddle_w / 2, field_x + field_w - paddle_w / 2)
    paddle.x = math.floor(paddle_cx - paddle_w / 2)
end

local function clearItems()
    for _, it in ipairs(g:find("item")) do it:remove() end
end

local function readyBall()
    for _, b in ipairs(balls) do b:remove() end
    balls = {}
    clearItems()
    setPaddle(field_x + field_w / 2)
    newBall(paddle_cx, paddle_y - BALL_R * 2 - 1, 0, 0)
    g:go("ready")
end

local function startGame()
    score, lives, stage_idx = 0, 3, 1
    loadStage(stage_idx)
    readyBall()
end

local function applyTierSpeed(b, tier)
    local speed = baseSpeed(stage_idx) * TIER_MULT[tier]
    local mag = math.sqrt(b.dx * b.dx + b.dy * b.dy)
    if mag > 0 then
        local k = speed / mag
        b.dx, b.dy = b.dx * k, b.dy * k
    end
end

-- ---- アイテム ----

local function spawnItem(x, y)
    if #g:find("item") >= MAX_ITEMS then return end
    local kind = math.random(1, 3)
    g:sprite{ x = x - ITEM_SIZE / 2, y = y - ITEM_SIZE / 2, w = ITEM_SIZE, h = ITEM_SIZE, vy = ITEM_FALL_SPEED,
              layer = 1, tag = "item", kind = kind, draw = ITEM_DRAWS[kind],
              on_update = function(s) if s.y > BOTTOM_LIMIT then s:remove() end end }
end

local function spawnExtraBalls(n)
    local speed = baseSpeed(stage_idx)
    for i = 1, n do
        if #balls < MAX_BALLS then
            local ang = (i - (n + 1) / 2) * 0.35
            newBall(paddle_cx, paddle_y - BALL_R * 2 - 1, speed * math.sin(ang), -speed * math.cos(ang))
        end
    end
end

local function doubleBalls()
    local n = #balls
    for i = 1, n do
        if #balls < MAX_BALLS then
            local b = balls[i]
            newBall(b.cx, b.cy, -b.dx, b.dy)
        end
    end
end

local function slowAllBalls()
    for i = 1, #balls do applyTierSpeed(balls[i], #TIER_MULT) end
end

g:collide("paddle", "item", function(_, it)
    it:remove()
    se(4, 1760, 120, "pulse50")
    if it.kind == ITEM_TRIBALL then spawnExtraBalls(3)
    elseif it.kind == ITEM_DOUBLE then doubleBalls()
    else slowAllBalls() end
end)

-- ---- ボールの動き ----

local function destroyBlock(c, r, tier)
    map:set(c, r, 0)
    blocks_remaining = blocks_remaining - 1
    se(3, 1500 - tier * 150, 50, "pulse50")
    score = score + TIER_POINTS[tier]
    hudDirty()
    if math.random() < DROP_CHANCE then
        spawnItem(BLOCK_X + c * TW + BLOCK_W / 2, BLOCK_TOP + r * TH + BLOCK_H / 2)
    end
end

-- ボールの外接矩形がかかるマスだけ調べ、1つ見つけたら反射して終わり
local function collideBlocks(b)
    local c0 = math.floor((b.cx - BALL_R - BLOCK_X) / TW)
    local c1 = math.floor((b.cx + BALL_R - BLOCK_X) / TW)
    local r0 = math.floor((b.cy - BALL_R - BLOCK_TOP) / TH)
    local r1 = math.floor((b.cy + BALL_R - BLOCK_TOP) / TH)
    for r = r0, r1 do
        for c = c0, c1 do
            local v = map:get(c, r)
            if v ~= 0 then
                local bx, by = BLOCK_X + c * TW, BLOCK_TOP + r * TH
                local nx = clamp(b.cx, bx, bx + BLOCK_W)
                local ny = clamp(b.cy, by, by + BLOCK_H)
                local dx, dy = b.cx - nx, b.cy - ny
                if dx * dx + dy * dy < BALL_R * BALL_R then
                    local left = (b.cx + BALL_R) - bx
                    local right = (bx + BLOCK_W) - (b.cx - BALL_R)
                    local top = (b.cy + BALL_R) - by
                    local bottom = (by + BLOCK_H) - (b.cy - BALL_R)
                    local m = math.min(left, right, top, bottom)
                    if m == left then
                        b.cx = bx - BALL_R; b.dx = -math.abs(b.dx)
                    elseif m == right then
                        b.cx = bx + BLOCK_W + BALL_R; b.dx = math.abs(b.dx)
                    elseif m == top then
                        b.cy = by - BALL_R; b.dy = -math.abs(b.dy)
                    else
                        b.cy = by + BLOCK_H + BALL_R; b.dy = math.abs(b.dy)
                    end
                    if v == T_WALL then
                        se(2, 180, 40, "triangle") -- 壊せないブロック: 反射だけ
                    else
                        applyTierSpeed(b, v)
                        destroyBlock(c, r, v)
                    end
                    return
                end
            end
        end
    end
end

local function collidePaddle(b)
    local px = paddle_cx - paddle_w / 2
    if b.cx + BALL_R >= px and b.cx - BALL_R <= px + paddle_w
        and b.cy + BALL_R >= paddle_y and b.cy - BALL_R <= paddle_y + PADDLE_H then
        local offset = clamp((b.cx - paddle_cx) / (paddle_w / 2), -1, 1)
        local speed = math.sqrt(b.dx * b.dx + b.dy * b.dy)
        local angle = offset * MAX_ANGLE
        b.dx = speed * math.sin(angle)
        b.dy = -speed * math.cos(angle)
        b.cy = paddle_y - BALL_R
        se(2, 520, 40)
    end
end

local function stepBall(b, dtSec)
    local dist = math.sqrt(b.dx * b.dx + b.dy * b.dy) * dtSec
    local steps = math.max(1, math.ceil(dist / STEP_MAX))
    local subDt = dtSec / steps
    for _ = 1, steps do
        b.cx = b.cx + b.dx * subDt
        b.cy = b.cy + b.dy * subDt
        local dx, dy = b.dx, b.dy
        if b.cx - BALL_R < field_x then
            b.cx = field_x + BALL_R; b.dx = math.abs(b.dx)
        elseif b.cx + BALL_R > field_x + field_w then
            b.cx = field_x + field_w - BALL_R; b.dx = -math.abs(b.dx)
        end
        if b.cy - BALL_R < TOP_WALL then
            b.cy = TOP_WALL + BALL_R; b.dy = math.abs(b.dy)
        end
        if dx ~= b.dx or dy ~= b.dy then se(1, 330, 20, "pulse12") end
        collideBlocks(b)
        if b.dy > 0 then collidePaddle(b) end
        if b.cy - BALL_R > BOTTOM_LIMIT then
            b.lost = true
            return
        end
    end
end

-- ---- 流れ ----

local function stageClear()
    clearItems()
    if stage_idx >= #STAGES.list then
        jingle("c e g > c e g > c4")
        g:go("win")
    else
        jingle("c e g > c4")
        g:go("clear")
    end
end

local function loseLife()
    lives = lives - 1
    hudDirty()
    if lives <= 0 then
        jingle("l8 e d c < g2")
        clearItems()
        g:go("over")
    else
        jingle("l8 g e c4")
        readyBall()
    end
end

local function launch()
    local speed = baseSpeed(stage_idx)
    local b = balls[1]
    b.dx, b.dy = 0, -speed
    g:go("play")
    se(2, 880, 60)
end

-- パドル: 指(触れている間そこへ)・コントローラー・自動プレイ
local function control(dt, playing)
    local t = g.touch
    local dir = (g:down("right") and 1 or 0) - (g:down("left") and 1 or 0)
    if auto then
        if playing then setPaddle(STAGES.autoTargetX(balls, paddle_cx) - 20) end -- あえてずらす
    else
        if t.down then setPaddle(t.x) end
        if dir ~= 0 then setPaddle(paddle_cx + dir * PAD_SPEED * dt) end
    end
end

-- 発射・次へ・もう一度(タップ、A、START、上。自動プレイ中は常に)
local function goKey()
    return auto or g.touch.pressed or g:pressed("a") or g:pressed("start") or g:pressed("up")
end

-- ---- 画面 ----

local function overlay(ox, oy, l1, l2, l3)
    local x, y, w, h = ox + 20, oy + 96, cw - 40, l3 and 84 or 60
    pico.fill_rect(x, y, w, h, 0)
    pico.draw_rect(x, y, w, h, 15)
    local lines = { l1, l2, l3 }
    for i = 1, l3 and 3 or 2 do
        local t = lines[i]
        pico.draw_text(x + (w - pico.text_width(t, 0)) // 2, y + 8 + (i - 1) * 24, t, i == 1 and 14 or 15, 0)
    end
end

function g:on_update()
    if self:pressed("back") then pico.pop() return end
    if self:pressed("auto") then
        auto = not auto
        self:dirty(auto_btn.x, auto_btn.y, auto_btn.w, auto_btn.h)
    end
    for _, b in ipairs(balls) do placeBall(b) end
    if snd then
        pico.sound_play(2, snd[2], snd[3], { wave = snd[4], volume = 9, envelope = -3 })
        snd = nil
    end
end

function g:on_draw_world(ox, oy)
    pico.draw_rect(ox + field_x, oy + TOP_WALL, field_w, BOTTOM_LIMIT - TOP_WALL, 7)
end

function g:on_draw(ox, oy)
    pico.draw_text(ox + 46, oy + 3,
        "St" .. stage_idx .. "/" .. #STAGES.list .. " Sc" .. score .. " L" .. lives, 0, 0)
end

g:button{ name = "back", x = 2, y = 0, w = 40, h = 22, label = "left" }
auto_btn = g:button{ name = "auto", x = cw - 43, y = 0, w = 41, h = 22, draw = function(b, x, y, w, h)
    pico.fill_rect(x + 1, y + 1, w - 2, h - 2, auto and 2 or 8)
    pico.draw_rect(x + 1, y + 1, w - 2, h - 2, 0)
    pico.draw_text(x + (w - pico.text_width(pico.tr("自動"), 0)) // 2, y + 3, pico.tr("自動"), 15, 0)
end }

g:state("ready", {
    update = function(_, dt)
        control(dt, false)
        local b = balls[1]
        b.cx, b.cy = paddle_cx, paddle_y - BALL_R * 2 - 1
        if goKey() then launch() end
    end,
    draw = function(_, ox, oy)
        local t = pico.tr("タップで発射")
        pico.draw_text(ox + (cw - pico.text_width(t, 0)) // 2, oy + paddle_y - 36, t, 8, 0)
    end,
})

g:state("play", {
    update = function(_, dt)
        control(dt, true)
        for i = #balls, 1, -1 do
            stepBall(balls[i], dt)
            if balls[i].lost then
                balls[i]:remove()
                table.remove(balls, i)
            end
        end
        if #balls == 0 then
            loseLife()
        elseif blocks_remaining == 0 then
            stageClear()
        end
    end,
})

g:state("clear", {
    update = function()
        if goKey() then
            stage_idx = stage_idx + 1
            loadStage(stage_idx)
            readyBall()
        end
    end,
    draw = function(_, ox, oy) overlay(ox, oy, pico.tr("ステージ%dクリア!", stage_idx), pico.tr("タップで次へ")) end,
})

g:state("over", {
    update = function() if goKey() then startGame() end end,
    draw = function(_, ox, oy) overlay(ox, oy, pico.tr("ゲームオーバー"), pico.tr("スコア:%d", score), pico.tr("タップでもう一度")) end,
})

g:state("win", {
    update = function() if goKey() then startGame() end end,
    draw = function(_, ox, oy) overlay(ox, oy, pico.tr("全ステージクリア!"), pico.tr("スコア:%d", score), pico.tr("タップで最初から")) end,
})

pico.on_back(function() pico.pop() end)
math.randomseed(pico.get_time().sec * 1000 + pico.get_time().min)
startGame()
