-- ジャンプアクション: pico.game(2Dゲームの簡易エンジン)のサンプル
--   左右で歩き、A(または↑)でジャンプ。コインを集めてゴールの旗まで行く。
--   スライムは上から踏むと倒せる。横から当たる・穴に落ちるとミス。
-- 絵は sheet.pimg(script/assets/generate_platformer_sheet.py で作る)。番号は左上から
--   0 草 1 土 2 レンガ 3 旗 4〜6 主人公(立ち/歩き/ジャンプ) 7 雲 8,9 コイン 10,11 スライム
-- タイルマップの値は 番号+1(0は空)。
local game = require("pico.game")

local SHEET = pico.path_join(pico.app_dir(), "sheet.pimg")

local LEVEL = {
    "................................................................................................",
    "......c.................c..................c.....................c..............c...............",
    "................................................................................................",
    "..................................................o.o.o.........................................",
    ".....................o.o........................BBBBBBB.........................................",
    "................................................................................................",
    "....................BBBBB..........o.o.......................o.o.o..............................",
    "................................BBBBBBB....................BBBBBBBB..............................",
    "..........o.o.o.................................................................o.o.o...........",
    "...........................s.......................s.....s....................................F.",
    "............................................................................BBBBBBB............",
    ".P............s.........#####.................s..................s.................s...........",
    "#######################=====####....###########################.....############################",
    "=======================================....=====================.....============================",
    "================================================================================================",
}

local g = game.new{ bg = 11, pad = true }
local img = g:image(SHEET)
local score, best, lives = 0, 0, 3
local player

local function hud_dirty() g:dirty(0, 0, g.vw, 18) end

local function beep(f, ms) pico.sound_play(2, f, ms, { wave = "pulse25", volume = 10 }) end
local function jingle(mml) pico.music_play_text("#tempo 180\nA @pulse25 v11 q7 o5 l16 " .. mml) end

-- ---- 登場するもの ----

local function make_player(x, y)
    player = g:sprite{ image = img, x = x, y = y, w = 16, h = 16, hitbox = { 3, 2, 10, 14 },
        gravity = 900, max_fall = 420, solid = true, tag = "player", layer = 2,
        anims = { stand = { frames = { 4 } }, walk = { frames = { 4, 5 }, fps = 8 }, jump = { frames = { 6 } } } }
    player:play("stand")
    g:follow(player)
end

local function make_coin(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, hitbox = { 4, 2, 8, 12 }, tag = "coin",
        anims = { spin = { frames = { 8, 9 }, fps = 4 } }, anim = "spin" }
end

local function make_slime(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, hitbox = { 1, 6, 14, 9 }, tag = "slime",
        vx = -30, gravity = 900, solid = true, layer = 1,
        anims = { move = { frames = { 10, 11 }, fps = 3 } }, anim = "move",
        on_update = function(s)
            if s.hit_wall ~= 0 then s.vx = -s.hit_wall * 30 end   -- 壁に当たったら向きを変える
            s.flip_x = s.vx > 0
        end }
end

local function make_flag(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 3, tag = "goal" }
end

local function build()
    g:clear()
    g:tilemap{ image = img, tile = 16, y = 8, rows = LEVEL, solid = { 1, 2, 3 },
        legend = { ["#"] = 1, ["="] = 2, B = 3, c = 8 },
        spawn = { P = make_player, o = make_coin, s = make_slime, F = make_flag } }
end

-- ---- 当たり ----

g:collide("player", "coin", function(p, c)
    if g.state_name ~= "play" then return end
    c:remove()
    score = score + 10
    beep(1568, 60)
    hud_dirty()
end)

g:collide("player", "slime", function(p, s)
    if g.state_name ~= "play" then return end
    if p.vy > 0 and p.y + 16 < s.y + 12 then        -- 上から踏んだ(足がスライムの上半分)
        s:remove()
        p.vy = -260
        score = score + 50
        beep(392, 80)
        hud_dirty()
    else
        g:go("miss")
    end
end)

g:collide("player", "goal", function()
    if g.state_name == "play" then g:go("clear") end
end)

-- ---- 状態 ----

local function center_text(text, y, color, size)
    local w = pico.text_width(text, size or 1)
    pico.draw_text(g.x + (g.vw - w) // 2, g.y + y, text, color or 15, size or 1)
end

g:state("title", {
    enter = function() build(); score, lives = 0, 3; g:pause(false) end,
    update = function()
        if g:pressed("a") or g:pressed("start") or g.touch.pressed then g:go("play") end
    end,
    draw = function()
        center_text("ジャンプアクション", 70, 1)
        center_text("Aかタップで始める", 110, 1, 0)
        if best > 0 then center_text("ハイスコア " .. best, 134, 1, 0) end
    end,
})

g:state("play", {
    enter = function() hud_dirty() end,
    update = function(gg, dt)
        local p = player
        if not p or p.dead then return end
        local h = g:axis()
        local target = h * 100
        p.vx = p.vx + (target - p.vx) * math.min(1, dt * 12)  -- 少し滑らかに加速
        if math.abs(p.vx) < 2 then p.vx = 0 end
        if h ~= 0 then p.flip_x = h < 0 end
        if p.on_ground and (g:pressed("a") or g:pressed("up")) then
            p.vy = -330
            beep(784, 60)
        end
        if p.vy < -120 and not (g:down("a") or g:down("up")) then p.vy = -120 end  -- 早く離すと低く
        if p.x < 0 then p.x = 0 end
        if not p.on_ground then p:play("jump")
        elseif p.vx ~= 0 then p:play("walk")
        else p:play("stand") end
        local _, wh = g:world_size()
        if p.y > wh then g:go("miss") end                    -- 穴に落ちた
    end,
})

g:state("miss", {
    enter = function()
        lives = lives - 1
        hud_dirty()
        jingle("e d c < b a g8")
        player.vx, player.vy, player.solid, player.gravity = 0, -250, false, 900
        player:play("jump")
        g:after(1.5, function()
            if lives <= 0 then g:go("over") else build(); g:go("play") end
        end)
    end,
})

g:state("clear", {
    enter = function()
        jingle("l8 c e g > c4")
        score = score + 100
        best = math.max(best, score)
        hud_dirty()
        player.vx = 0
        g:after(2.5, function() g:go("title") end)
    end,
    draw = function() center_text("ゴール!", 90, 14, 2) end,
})

g:state("over", {
    enter = function()
        best = math.max(best, score)
        g:after(2.5, function() g:go("title") end)
    end,
    draw = function() center_text("ゲームオーバー", 90, 12, 2) end,
})

-- 点数と残り(キャンバスの左上へ。中身が変わったらhud_dirty()で描き直す)
function g:on_draw(ox, oy)
    if self.state_name == "title" then return end
    pico.draw_text(ox + 4, oy + 2, "SCORE " .. score, 15, 0)
    pico.draw_text(ox + self.vw - 52, oy + 2, "x " .. lives, 15, 0)
end

pico.on_back(function() pico.pop() end)
g:go("title")
