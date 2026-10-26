-- おしてのぼれ: pico.game の物理を使ったパズルアクション
--   箱を押して踏み台にし、積み上げ、重い鉄箱でスイッチを押さえ、ばねと動く足場で旗まで行く。
--   左右で歩く、A(または↑)でジャンプ、↓ですり抜け床から降りる、Bでステージをやり直す。
-- 地図は stages.lua、絵は sheet.pimg(script/assets/generate_physics_sheet.py で作る)。絵の番号は左上から
--   0 草 1 土 2 レンガ 3 すり抜け床 4 扉 5,6 スイッチ 7 旗 8〜10 主人公 11 木箱 12 鉄箱 13 ボール 14 ばね 15 星
-- タイルマップの値は 番号+1(0は空)。
local game = require("pico.game")
local STAGES = require("stages")

local g = game.new{ bg = 11, pad = true, gravity = 900 }
local img = g:image(pico.path_join(pico.app_dir(), "sheet.pimg"))

local stage = 1
local stars, total = 0, 0
local player, map, switch, door_cells, door_open
local BODIES = { player = true, crate = true, ball = true }

local function hud_dirty() g:dirty(0, 0, g.vw, 18) end
local function beep(f, ms, wave) pico.sound_play(2, f, ms, { wave = wave or "pulse25", volume = 10 }) end
local function jingle(mml) pico.music_play_text("#tempo 180\nA @pulse25 v11 q7 o5 l16 " .. mml) end

-- ---- 登場するもの ----

local function make_player(x, y)
    player = g:sprite{ image = img, x = x, y = y, w = 16, h = 16, hitbox = { 3, 2, 10, 14 },
        max_fall = 420, solid = true, tag = "player", layer = 2, mass = 1,
        anims = { stand = { frames = { 8 } }, walk = { frames = { 8, 9 }, fps = 8 }, jump = { frames = { 10 } } } }
    player:play("stand")
    g:follow(player)
end

-- 木箱は押せば同じくらい動き、鉄箱(mass=4)は重くてゆっくりしか動かない
local function make_crate(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 11, tag = "crate",
        solid = true, friction = 400, max_fall = 420, layer = 1 }
end
local function make_iron(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 12, tag = "crate",
        solid = true, friction = 150, max_fall = 420, mass = 4, layer = 1 }
end

-- ボールは軽くてよく跳ねる
local function make_ball(x, y)
    g:sprite{ image = img, x = x + 2, y = y + 2, w = 12, h = 12, tag = "ball", solid = true, layer = 1,
        mass = 0.5, bounce = 0.7, friction = 120, max_fall = 420,
        draw = function(s, sx, sy) pico.draw_image_part(img, sx - 2, sy - 2, 5 * 16, 16, 16, 16) end }
end

local function make_spring(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 14, hitbox = { 1, 6, 14, 10 },
        tag = "spring", static = true }
end

local function make_star(x, y)
    total = total + 1
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 15, hitbox = { 3, 3, 10, 10 },
        tag = "star", gravity = 0 }
end

local function make_flag(x, y)
    g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 7, hitbox = { 6, 0, 6, 16 },
        tag = "goal", gravity = 0 }
end

local function make_switch(x, y)
    switch = g:sprite{ image = img, x = x, y = y, w = 16, h = 16, frame = 5, hitbox = { 2, 11, 12, 5 },
        tag = "switch", gravity = 0 }
end

-- 動く足場: 置いたマスの1つ下の上端が足場の上面。両端で折り返す。staticなので押されず、乗ったものを運ぶ
local function make_lift(cfg)
    return function(x, y)
        local s = g:sprite{ x = x, y = y + 16, w = 32, h = 6, tag = "lift", static = true, layer = 1,
            draw = function(s, sx, sy)
                pico.fill_rect(sx, sy, s.w, s.h, 6)
                pico.draw_rect(sx, sy, s.w, s.h, 4)
                pico.draw_line(sx + 2, sy + 2, sx + s.w - 3, sy + 2, 14)
            end }
        s.x0, s.y0, s.dir, s.wait = s.x, s.y, 1, 1
        local speed = 32
        -- 端に着いたら少し止まる(乗り降りしやすいように)
        local function turn(s, d)
            if s.dir ~= d then s.dir, s.wait = d, 0.8 end
        end
        s.on_update = function(s, dt)
            if cfg.dx ~= 0 then
                if s.x >= s.x0 + cfg.dx then turn(s, -1) elseif s.x <= s.x0 then turn(s, 1) end
            else
                if s.y <= s.y0 + cfg.dy then turn(s, -1) elseif s.y >= s.y0 then turn(s, 1) end
            end
            local v = s.dir * speed
            if s.wait > 0 then s.wait = s.wait - dt; v = 0 end
            if cfg.dx ~= 0 then s.vx = v else s.vy = -v end
        end
    end
end

local function build()
    local st = STAGES[stage]
    g:clear()
    stars, total, door_open, switch = 0, 0, false, nil
    local spawn = { P = make_player, c = make_crate, i = make_iron, o = make_ball, s = make_spring,
        ["*"] = make_star, F = make_flag, S = make_switch }
    for ch, cfg in pairs(st.lift or {}) do spawn[ch] = make_lift(cfg) end
    map = g:tilemap{ image = img, tile = 16, rows = st.rows, solid = { 1, 2, 3, 5 }, oneway = { 4 },
        legend = { ["#"] = 1, ["="] = 2, B = 3, ["-"] = 4, D = 5 }, spawn = spawn }
    door_cells = map:find(5)
    hud_dirty()
end

-- ---- 物理の規則(押し合う組み合わせ) ----

g:solid("player", "crate")
g:solid("crate", "crate")
g:solid("player", "ball")
g:solid("crate", "ball")
for _, t in ipairs({ "player", "crate", "ball" }) do
    g:solid(t, "lift", { oneway = true })
    -- ばね: 上に乗ったものを高く打ち上げる(重いものほど低い)
    g:solid(t, "spring", function(a, b, nx, ny)
        if ny == -1 then
            a.vy = -520 / math.sqrt(a.mass or 1)
            a.jumped = false                 -- ばねの勢いはAを離しても弱めない
            beep(523, 80, "triangle")
        end
    end)
end

-- ---- 星・旗・スイッチ ----

g:collide("player", "star", function(p, s)
    if g.state_name ~= "play" then return end
    s:remove()
    stars = stars + 1
    beep(1568, 60)
    hud_dirty()
end)

g:collide("player", "goal", function()
    if g.state_name == "play" then g:go("clear") end
end)

local function pressed_by_something()
    for _, s in ipairs(g.sprites) do
        if BODIES[s.tag] and not s.dead and s:overlaps(switch) then return true end
    end
    return false
end

-- 扉のマスに何かが重なっていたら閉じない(閉じ込めないため)
local function door_blocked()
    for _, c in ipairs(door_cells) do
        local cell = { x = c[1] * 16, y = c[2] * 16, w = 16, h = 16 }
        for _, s in ipairs(g.sprites) do
            if BODIES[s.tag] and not s.dead and game.overlaps(s, cell) then return true end
        end
    end
    return false
end

local function update_switch()
    if not switch then return end
    local on = pressed_by_something()
    if on == door_open then return end
    if not on and door_blocked() then return end
    door_open = on
    switch.frame = on and 6 or 5
    for _, c in ipairs(door_cells) do map:set(c[1], c[2], on and 0 or 5) end
    beep(on and 880 or 330, 70, "square")
end

-- ---- 状態 ----

-- 画面の幅で折り返して中央に描く
local function center_text(text, y, color, size)
    pico.draw_text_wrapped(g.x + 8, g.y + y, g.vw - 16, text, color or 1, size or 1, "center")
end

g:state("title", {
    enter = function() stage = 1; build() end,
    update = function()
        if g:pressed("a") or g:pressed("start") or g.touch.pressed then g:go("intro") end
    end,
    draw = function()
        center_text("おしてのぼれ", 40, 1, 2)
        center_text("箱を押して、積んで、\n旗まで行こう", 84, 1, 0)
        center_text("A:ジャンプ B:やり直し\n↓:すり抜け床から降りる", 124, 1, 0)
        center_text("Aかタップで始める", 168, 12, 0)
    end,
})

-- ステージの名前を少し見せてから始める
g:state("intro", {
    enter = function()
        build()
        g:after(1.5, function() if g.state_name == "intro" then g:go("play") end end)
    end,
    draw = function()
        local st = STAGES[stage]
        center_text(st.name, 50, 1, 1)
        center_text(st.hint, 84, 1, 0)
    end,
})

g:state("play", {
    enter = function() g:redraw() end,
    update = function(gg, dt)
        local p = player
        if not p or p.dead then return end
        if g:pressed("b") then g:go("intro") return end
        local h = g:axis()
        local target = h * 90
        p.vx = p.vx + (target - p.vx) * math.min(1, dt * 12)   -- 押している箱の重さで遅くなる
        if math.abs(p.vx) < 2 then p.vx = 0 end
        if h ~= 0 then p.flip_x = h < 0 end
        p.drop_through = g:down("down")
        if p.on_ground and (g:pressed("a") or g:pressed("up")) then
            p.vy = -330
            p.jumped = true
            beep(784, 60)
        end
        -- Aを早く離すと低く跳ぶ(自分のジャンプのときだけ)
        if p.jumped and p.vy < -120 and not (g:down("a") or g:down("up")) then p.vy = -120 end
        if p.vy >= 0 then p.jumped = false end
        if p.x < 0 then p.x = 0 end
        if not p.on_ground then p:play("jump")
        elseif p.vx ~= 0 then p:play("walk")
        else p:play("stand") end
        update_switch()
        -- 穴に落ちたものは消す。主人公ならやり直し
        local _, wh = g:world_size()
        for _, s in ipairs(g.sprites) do
            if s.y > wh and not s.dead then
                if s == p then g:go("miss") return end
                s:remove()
            end
        end
    end,
})

g:state("miss", {
    enter = function()
        jingle("e d c < b a g8")
        player.vx, player.vy = 0, 0
        g:after(1.2, function() g:go("intro") end)
    end,
    draw = function() center_text("おちた!", 90, 12, 2) end,
})

g:state("clear", {
    enter = function()
        jingle("l8 c e g > c4")
        player.vx = 0
        hud_dirty()
        g:after(2, function()
            if stage < #STAGES then stage = stage + 1; g:go("intro") else g:go("ending") end
        end)
    end,
    draw = function() center_text("クリア!", 90, 14, 2) end,
})

g:state("ending", {
    enter = function() g:clear() end,
    update = function()
        if g:pressed("a") or g:pressed("start") or g.touch.pressed then g:go("title") end
    end,
    draw = function()
        center_text("ぜんぶ クリア!", 60, 1, 1)
        center_text("あそんでくれてありがとう", 120, 1, 0)
    end,
})

function g:on_draw(ox, oy)
    local n = self.state_name
    if n ~= "play" and n ~= "clear" and n ~= "miss" then return end
    pico.draw_text(ox + 4, oy + 2, "STAGE " .. stage, 0, 0)
    if total > 0 then
        local t = "STAR " .. stars .. "/" .. total
        pico.draw_text(ox + self.vw - pico.text_width(t, 0) - 4, oy + 2, t, 0, 0)
    end
end

pico.on_back(function() pico.pop() end)
g:go("title")
