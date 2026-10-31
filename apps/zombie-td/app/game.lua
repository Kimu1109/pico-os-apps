-- ゾンビTD: 斜め上から見た箱庭(pico.iso)のタワーディフェンス。仕様は docs/ZOMBIE_TD.md。
-- 「作る順番」の2〜7: マップの生成・カメラ・ゾンビ・兵士・建物・ウェーブ(準備時間/次へ/お金)・保存・ハイスコア・効果音・説明。
--   上の行: ベースの耐久・お金・ウェーブ(準備時間は残り秒と[次へ]、ウェーブ中は残りのゾンビ)・fps
--   下の欄: ui.lua。地図: タップ=兵士・建物を選ぶ/選んでいる兵士をそこへ動かす/(「建設」で選んだ後)そこへ建てる、
--         ドラッグ=カメラ(「選択」中は範囲選択)。
--   コントローラー・キーボード: カーソルを動かして選ぶ(cursor.lua)。1/2/3=雇う、HOME=戻る。
--   5秒ごとにシリアルへ "[TD] fps=.. lua=..ms render=..ms alive=.. mem lua=.. heap_free=.. refused=.." を出す(実機の速さとメモリを測る)。
-- ファイル: state(共有の状態)・orders(操作)・ui(下の欄・メニュー)・cursor(コントローラー)・waves・save・sfx(効果音)・tutorial(説明)・
--         zombies・soldiers・buildings・combat。
-- マップ・流れの場・経路探索・押し合い・弾・描画は C++ のエンジン(src/iso/)。
local iso = pico.iso
local PAL = require("palette")
local G = require("state")
local combat = require("combat")
local zombies = require("zombies")
local soldiers = require("soldiers")
local buildings = require("buildings")
local orders = require("orders")
local ui = require("ui")
local waves = require("waves")
local save = require("save")
local sfx = require("sfx")
local tutorial = require("tutorial")
local cursor = require("cursor")

local W_CHUNKS = 7                 -- 7x7 チャンク = 56x56 マス(全部を読み込んだままにできる上限)
local BASE_HP = 2000
local MAX_TRIES = 8                -- 出現位置からベースへ道が無い種は飛ばす(この回数まで)
local START_MONEY = 300
local WATER = 1                    -- 水のブロック(ゾンビも兵士も入らない)
local LOG_MS = 5000
-- ゾンビの道の規則(流れの場)。水には入らない。段差は1段まで登り、2段まで降りる。高低差は少し嫌う。
-- バリケード(buildings.WALLS のブロック)は、ゾンビは中を通り抜けられる(pass)が通ると高くつく。兵士は避ける。
-- 弾と視線はバリケードを透過する
local WALLS = buildings.WALLS
local WALL_COST = {}
for _, b in ipairs(WALLS) do WALL_COST[b] = 6 end
local FLOW_RULES = { max_up = 1, max_down = 2, height = 2, up_cost = 0.5, diagonal = true, avoid = { WATER },
    pass = WALLS, body_cost = WALL_COST }
local STAND_RULES = { height = 2, avoid = { WATER }, pass = WALLS }        -- ゾンビ
local S_STAND_RULES = { height = 2, avoid = { WATER, WALLS[1], WALLS[2], WALLS[3], WALLS[4] } }   -- 兵士・建てる所
local CROWD_RULES = { height = 2, pass = WALLS }
combat.SIGHT_PASS = WALLS
G.S_STAND = S_STAND_RULES

-- Luaのごみ集めは世代別にする。既定(incremental)だと、毎フレームの使い捨ての表が
-- 生きている量の2倍まで溜まってから集めるので、ゾンビが多いとLuaが予算(200KB)近くまで膨らみ、
-- 実機では本体のメモリが先に尽きて落ちた(ゾンビ30体を超えたところで再起動)。
-- さらに小さい集め(minor)を早めにする(既定の 20, 100 → 5, 30)。ゾンビ40匹・兵士8人・建物10個で、
-- ごみを含めた山が PC で約267KB → 約247KB(実機の32bit換算で約200KB → 約186KB)になり、処理時間は変わらなかった
collectgarbage("generational", 5, 30)

for i, c in ipairs(PAL.colors) do pico.set_palette(i, c[1], c[2], c[3]) end
iso.sky(PAL.sky)
local DIR = pico.app_dir()
local faces = pico.image_load(pico.path_join(DIR, "faces.pimg"))
local units = pico.image_load(pico.path_join(DIR, "units.pimg"))
-- faces.pimg は使うブロックの段だけを並べてある(script/assets/generate_zombie_td_sheet.py の FACE_ROWS と同じ並び。26 = カーソル)
local FACE_ROWS = { 1, 2, 3, 4, 5, 11, 12, 14, 15, 16, 18, 22, 26 }
if faces then iso.set_image(faces, FACE_ROWS) else pico.show_error(pico.tr("faces.pimg を読めません")) end
if not units then pico.show_error(pico.tr("units.pimg を読めません")) end
local MAP_DIR = pico.path_join(DIR, "map")   -- 何も書かない(地形は種から作るので保存しない)

local CX, CY, CW, CH = pico.content_rect()
local HUD_H, INFO_H, BTN_H = 20, 20, 34
local PANEL_H = INFO_H + BTN_H
local VY = CY + HUD_H
local VH = CH - HUD_H - PANEL_H
local PY = VY + VH
iso.view(CX, VY, CW, VH)

local hud = pico.create("Canvas")
local view = pico.create("Canvas")
local panel = pico.create("Canvas")
pico.set(hud, "x", CX); pico.set(hud, "y", CY); pico.set(hud, "w", CW); pico.set(hud, "h", HUD_H)
pico.set(view, "x", CX); pico.set(view, "y", VY); pico.set(view, "w", CW); pico.set(view, "h", VH)
pico.set(panel, "x", CX); pico.set(panel, "y", PY); pico.set(panel, "w", CW); pico.set(panel, "h", PANEL_H)
G.hud, G.view, G.panel = hud, view, panel

local load_msg = ""
local stage = nil          -- load の中: pump / flow(nil = 始め方を選んでいる/失敗した)
local tries = 0
local W = 56
local arena = nil
local resume = nil         -- 続きから始めるときの保存(マップを作り終えたら戻す)
local over_text = nil      -- ゲームオーバーの枠の2行目
local OX, OY = 0, 0
G.seed = 0

-- ---------------------------------------------------------------- カメラ

local function set_origin(x, y)
    -- 画面の真ん中に見える地面(高さ6あたり)の点がマップの中に収まるように抑える
    local u = (CX + CW / 2 - x - 16) / 16                 -- x - z
    local s = (y + 32 - 16 * 6 - (VY + VH / 2)) / 8       -- x + z
    local cu = math.max(-W, math.min(W, u))
    local cs = math.max(0, math.min(2 * W, s))
    x = math.floor(x - (cu - u) * 16 + 0.5)
    y = math.floor(y + (cs - s) * 8 + 0.5)
    if x == OX and y == OY then return end
    OX, OY = x, y
    iso.origin(x, y)
    pico.invalidate(view)
end

local function center_on(x, y, z)
    set_origin(CX + CW // 2 - 16 - 16 * (x - z), VY + VH // 2 - 16 + 8 * (x + z) + 16 * y)
end

local function scroll(dx, dy) set_origin(OX + dx, OY + dy) end

local function center_base()
    local b = G.base
    if b then center_on(b.x, b.y, b.z) end
end

-- ---------------------------------------------------------------- 計測

local perf = { frames = 0, lua_us = 0, render_us = 0, t0 = 0, fps = 0, lua_ms = 0, render_ms = 0 }
-- Luaの整数は32bit(LUA_32BITS)。pico.micros() は約36分で負へ回るが、引き算も同じく回るので差は正しい
local function us_since(t) return pico.micros() - t end

local function perf_tick()
    perf.frames = perf.frames + 1
    local now = pico.millis()
    if perf.t0 == 0 then perf.t0 = now end
    local span = now - perf.t0
    if span >= LOG_MS then
        perf.fps = perf.frames * 1000 / span
        perf.lua_ms = perf.lua_us / perf.frames / 1000
        perf.render_ms = perf.render_us / perf.frames / 1000
        local m = pico.memory_info()
        pico.log(string.format("[TD] fps=%.1f lua=%.2fms render=%.2fms alive=%d wait=%d shots=%d mem lua=%d heap_free=%d headroom=%d refused=%d",
            perf.fps, perf.lua_ms, perf.render_ms, zombies.alive(), zombies.waiting(), iso.shot_count(),
            m.lua_used, m.heap_free, m.heap_headroom or 0, m.heap_refused or 0))
        perf.frames, perf.lua_us, perf.render_us, perf.t0 = 0, 0, 0, now
        pico.invalidate(hud)
    end
end

-- ---------------------------------------------------------------- マップを作る

local function goals_around(bx, bz)
    -- ベースのまわり(中心から2マス離れた輪の16柱)がゾンビの目的地
    local g = {}
    for dx = -2, 2 do
        for dz = -2, 2 do
            if math.max(math.abs(dx), math.abs(dz)) == 2 then g[#g + 1] = { bx + dx, bz + dz } end
        end
    end
    return g
end

local function mem_log(what)
    collectgarbage("collect")
    local m = pico.memory_info()
    pico.log(string.format("[TD] %s: ヒープの空き %d + 未使用 %d バイト、Lua %d/%d バイト",
        what, m.heap_free, m.heap_headroom or 0, m.lua_used, m.lua_budget))
end

local function gen_fail(msg)
    mem_log("失敗")
    pico.show_error(msg)
    load_msg = pico.tr("作れませんでした(「他」でやり直し)")
    stage = nil
    pico.invalidate(view)
end

local function clear_units()
    orders.deselect_all()       -- 先に外す(消した後だと選択の印を消せない)
    zombies.clear()
    soldiers.clear()
    buildings.clear()
    combat.clear_shots()
    G.build_mode = false
end

local function gen_start()
    clear_units()
    cursor.hide()
    iso.flow_clear()
    iso.close()
    G.base = false
    local bx, by, bz = iso.create(MAP_DIR, 4, G.seed, W_CHUNKS)
    G.mode = "load"
    if not bx then return gen_fail(pico.tr("マップを作れません: ") .. tostring(by)) end
    W = iso.size()
    if not iso.keep_all(true) then
        iso.close()
        return gen_fail(pico.tr("マップを作れません: メモリが足りません"))
    end
    arena = iso.arena()
    center_on(bx, by, bz)
    load_msg = pico.tr("マップを作っています...")
    stage = "pump"
    pico.invalidate(view)
    pico.invalidate(hud)
end

-- 新しいマップで始める(s を渡すとその種で。続きから始めるときは game に保存を渡す)
local function new_map(s, game)
    G.seed = s or (pico.millis() * 7919 + math.random(0, 0xffff)) % 0x7fffffff
    tries = game and MAX_TRIES or 0      -- 保存した種は道があると分かっているので作り直さない
    resume = game
    gen_start()
end

local function update_base_bar()
    iso.entity_set(G.base.id, { bar = math.max(0, G.base.hp) * 100 // BASE_HP })
end

-- 途中の保存(準備時間の間とウェーブの始め)
local function save_game()
    if G.mode == "play" then save.write(save.dump(G, waves, soldiers, buildings)) end
end

-- ベースが壊れた: スコア(耐えたウェーブ数)を残し、途中の保存を消す
local function game_over()
    G.mode = "over"
    local score = { w = waves.n - 1, hp = 0, earned = G.earned }
    local best = save.load().best
    save.write(nil, score)
    local nb = save.load().best or score
    over_text = string.format(pico.tr("耐えたウェーブ %d (最高 %d)%s"), score.w, nb.w,
        save.better(score, best) and score.w > 0 and pico.tr(" 新記録!") or "")
    pico.invalidate(view)
    tutorial.stop()
    sfx.game_over()
    pico.log(string.format("[TD] ベースが壊れました(種 %d、ウェーブ %d、出したゾンビ %d、倒した %d、雇った兵士 %d)",
        G.seed, waves.n, zombies.stats.spawned, zombies.stats.killed, soldiers.stats.hired))
end

local function base_hurt(b, dmg)
    if G.mode ~= "play" then return end
    b.hp = b.hp - dmg
    sfx.base()
    update_base_bar()
    pico.invalidate(hud)
    if b.hp <= 0 then game_over() end
end

local function start_play()
    local a = arena.base
    local base = { x = a.x, y = a.y, z = a.z, hp = BASE_HP, r = 1.4, side = "base", hurt = base_hurt }
    base.id = iso.entity_add(units, a.x + 0.5, a.y, a.z + 0.5, {
        sx = 80, sy = 0, w = 44, h = 40, r = 1.4, height = 2.5, crowd = "fixed", tag = 2,
        bar = 100, bar_color = 2,
    })
    G.base = base
    combat.add(base)
    zombies.init(units, arena.spawns, base, STAND_RULES)
    soldiers.init(units, base, S_STAND_RULES)
    buildings.init(units, base, arena.spawns)
    G.money, G.earned, G.speed = START_MONEY, 0, 1
    waves.reset(1)
    if resume then
        save.restore(resume, G, waves, soldiers, buildings, S_STAND_RULES)
        resume = nil
        update_base_bar()
    end
    G.mode = "play"
    pico.invalidate(view)
    pico.invalidate(hud)
    pico.invalidate(panel)
    collectgarbage("collect")
    local m = pico.memory_info()
    local st = iso.stats()
    pico.log(string.format("[TD] 種 %d: チャンク %d 個 (置き場 %d バイト)、Lua %d/%d バイト、ヒープの空き %d + 未使用 %d バイト",
        G.seed, st.chunks, st.bytes, m.lua_used, m.lua_budget, m.heap_free, m.heap_headroom or 0))
end

local function gen_step()
    if stage == "pump" then
        iso.pump(64, 30)
        if iso.pending() == 0 then
            load_msg = pico.tr("道を調べています...")
            pico.invalidate(view)
            mem_log("チャンクを読み込んだ")
            local ok, err = iso.flow_build(goals_around(arena.base.x, arena.base.z), FLOW_RULES)
            if not ok then return gen_fail(pico.tr("道を作れません: ") .. tostring(err)) end
            stage = "flow"
        end
    elseif stage == "flow" then
        local done = iso.flow_step(4000)
        local info = iso.flow_info()
        if info.failed then return gen_fail(pico.tr("道を作れません: メモリが足りません")) end
        if done then
            -- 出現位置のどれかからベースへ届かない種は使わない
            local ok = true
            for _, s in ipairs(arena.spawns) do
                if not iso.flow_get(s.x, s.z) then ok = false end
            end
            if ok or tries >= MAX_TRIES then
                if not ok then pico.log("[TD] 道のある種が見つかりませんでした。このまま使います") end
                stage = nil
                start_play()
            else
                pico.log(string.format("[TD] 種 %d は出現位置から道がありません。次の種へ", G.seed))
                tries = tries + 1
                G.seed = (G.seed + 1) % 0x7fffffff
                gen_start()
            end
        end
    end
end

-- ---------------------------------------------------------------- ウェーブ

local function next_wave()
    if G.mode ~= "play" or waves.phase ~= "prep" then return end
    local bonus = waves.skip()
    if bonus > 0 then G.add_money(bonus, true); G.say(string.format(pico.tr("早く呼んだ +$%d"), bonus)) end
end

local function wave_event(ev)
    if ev == "start" then
        save_game()                         -- ウェーブ中に閉じたら、ここからやり直す
        waves.start(zombies)
        sfx.wave_start()
        G.say(string.format(pico.tr("ウェーブ %d!"), waves.n))
    elseif ev == "clear" then
        local bonus = waves.bonus(waves.n - 1)
        G.add_money(bonus, true)
        G.say(string.format(pico.tr("ウェーブ %d を越えた +$%d"), waves.n - 1, bonus))
        sfx.wave_clear()
        save_game()
    end
    pico.invalidate(hud)
end

-- ---------------------------------------------------------------- つなぎ

zombies.on_kill = function(zb)
    G.add_money(math.floor(zb.money * waves.money_mul(waves.n) + 0.5), true)
end
buildings.on_walls_changed = function() G.flow_dirty = true end
zombies.TARGET_TAGS = { soldiers.TAG, buildings.TAG }
zombies.wall_at = buildings.wall_at
soldiers.ZOMBIE_TAG = zombies.TAG
buildings.ZOMBIE_TAG = zombies.TAG
soldiers.blocked = function(x, z) return buildings.at[buildings.col(x, z)] ~= nil end
soldiers.pressing = zombies.pressing

-- ---------------------------------------------------------------- 描画

local box = ui.box
local NEXT_X = CW - 42      -- 上の行の[次へ]

pico.on(hud, "render", function()
    pico.fill_rect(CX, CY, CW, HUD_H, PAL.dark)
    local base = G.base
    if G.mode == "load" or not base then
        pico.draw_text(CX + 4, CY + 2, pico.tr("種 ") .. G.seed, 15, 0)
        return
    end
    pico.draw_text(CX + 2, CY + 2, string.format(pico.tr("基%d"), math.max(0, math.floor(base.hp))), base.hp > BASE_HP // 4 and 15 or 12, 0)
    pico.draw_text(CX + 58, CY + 2, string.format("$%d", G.money), 14, 0)
    if waves.phase == "prep" and G.mode == "play" then
        pico.draw_text(CX + 106, CY + 2, string.format(pico.tr("W%dまで%d"), waves.n, math.ceil(waves.timer)), 10, 0)
        box(CX + NEXT_X, CY + 1, 40, HUD_H - 2, nil)
        pico.draw_text(CX + NEXT_X + 20, CY + 2, pico.tr("次へ"), 0, 0, "center")
    else
        pico.draw_text(CX + 106, CY + 2, string.format(pico.tr("W%d 残%d"), waves.n, zombies.alive() + zombies.waiting()), 15, 0)
        pico.draw_text(CX + CW - 2, CY + 2, string.format("%.0ffps", perf.fps), 8, 0, "right")
    end
end)
pico.on(hud, "press_end", function(_, _, _, lx)
    if lx >= NEXT_X and not ui.menu_active() then next_wave() end
end)

local drag_rect = nil      -- 範囲選択の矩形 {x0, y0, x1, y1}
-- 説明の案内(地図の上に出す枠)
local TUT_X, TUT_Y, TUT_W = CX + 4, VY + 4, CW - 8
local TUT_H = 40            -- 描き直す範囲(2行まで)
local function tut_dirty() pico.mark_dirty(TUT_X, TUT_Y, TUT_W, TUT_H) end

pico.on(view, "render", function()
    if G.mode == "load" then
        local x, y, w, h = pico.get_draw_area()
        pico.fill_rect(x, y, w, h, PAL.sky)
        if load_msg ~= "" then box(CX + 30, VY + VH // 2 - 20, CW - 60, 40, load_msg) end
        ui.menu_draw()
        return
    end
    local t = pico.micros()
    iso.render()
    perf.render_us = perf.render_us + us_since(t)
    cursor.draw()
    if drag_rect then
        local r = drag_rect
        pico.draw_rect(math.min(r[1], r[3]), math.min(r[2], r[4]), math.abs(r[3] - r[1]) + 1, math.abs(r[4] - r[2]) + 1, 14)
    end
    local tt = tutorial.text()
    if tt then
        local _, th = pico.measure_text(tt, TUT_W - 24, 0)
        pico.fill_rect(TUT_X, TUT_Y, TUT_W, th + 6, PAL.light)
        pico.draw_rect(TUT_X, TUT_Y, TUT_W, th + 6, 0)
        pico.draw_text_wrapped(TUT_X + 4, TUT_Y + 3, TUT_W - 24, tt, 0, 0)
        pico.draw_text(TUT_X + TUT_W - 4, TUT_Y + 3, "×", 8, 0, "right")      -- タップで説明を終える
    end
    if G.mode == "over" then
        box(CX + 10, VY + VH // 2 - 38, CW - 20, 76)
        pico.draw_text(CX + CW // 2, VY + VH // 2 - 32, pico.tr("ベースが壊れました"), 12, 0, "center")
        pico.draw_text(CX + CW // 2, VY + VH // 2 - 10, over_text or "", 0, 0, "center")
        pico.draw_text(CX + CW // 2, VY + VH // 2 + 12, pico.tr("タップかAで新しく始める"), 0, 0, "center")
    end
    ui.menu_draw()
end)

-- ---------------------------------------------------------------- 操作

local function new_game()
    new_map()
    if not save.load().tut then tutorial.start(); tut_dirty() end
end

-- 効果音の入り切り(覚えておく)
local function set_sound(on)
    sfx.on = on
    save.set("snd", on)
end

-- 説明をもう一度(終えると覚える)
local function restart_tutorial()
    tutorial.start()
    tut_dirty()
end

local function back()
    -- 準備時間の間に閉じたら今の状態を保存する(ウェーブ中ならウェーブの始めの保存が残っている)
    if G.mode == "play" and waves.phase == "prep" then save_game() end
    pico.pop()
end

ui.init({ x = CX, y = PY, w = CW, info_h = INFO_H, btn_h = BTN_H, vy = VY, vh = VH },
    { back = back, center = center_base, new_game = new_game, sound = set_sound, tutorial = restart_tutorial })
cursor.init({ x = CX, y = VY, w = CW, h = VH }, {
    scroll = scroll, new_game = new_game,
    start = function() next_wave() end,
})

local touch = nil
pico.on(view, "press_start", function(_, x, y)
    touch = { x = x, y = y, drag = false, menu = ui.menu_active() }
    if touch.menu then return end
    cursor.hide()
    if ui.focus then ui.set_focus(false); pico.invalidate(panel) end
end)
pico.on(view, "press_move", function(_, x, y, _, _, dx, dy)
    if not touch or touch.menu or G.mode == "load" then return end
    if not touch.drag and math.abs(x - touch.x) + math.abs(y - touch.y) > 8 then
        touch.drag = true
        dx, dy = x - touch.x, y - touch.y
    end
    if not touch.drag then return end
    if G.select_mode then
        drag_rect = { touch.x, touch.y, x, y }
        pico.invalidate(view)
    else
        scroll(dx, dy)
    end
end)
pico.on(view, "press_end", function(_, x, y)
    local t = touch
    touch = nil
    if not t then return end
    if t.menu then return ui.menu_tap(x, y) end
    if drag_rect then
        local r = drag_rect
        drag_rect = nil
        pico.invalidate(view)
        orders.select_rect(r[1], r[2], x, y)
        G.select_mode = false
        pico.invalidate(panel)
        return
    end
    if t.drag then return end
    -- 説明の案内をタップすると説明を終える
    if tutorial.text() and y < TUT_Y + TUT_H and t.y < TUT_Y + TUT_H then
        tutorial.stop()
        save.set("tut", true)
        pico.invalidate(view)
        return
    end
    if G.mode == "over" then new_game()
    elseif G.mode == "play" then orders.tap_map(x, y) end
    pico.invalidate(panel)
end)
pico.on(view, "press_out", function()
    touch = nil
    if drag_rect then drag_rect = nil; pico.invalidate(view) end
end)

pico.on_back(function() back(); return true end)

pico.on_key(function(key, mods)
    if cursor.key(key, mods) then return true end
    if key == "1" or key == "2" or key == "3" then
        if G.mode == "play" then orders.hire(soldiers.KINDS[tonumber(key)]) end
    else return false end
    pico.invalidate(panel)
    return true
end)

-- ---------------------------------------------------------------- 毎フレーム

local SIM_MS = 33
local sim_acc = 0
function loop(dt)
    perf_tick()
    if G.mode == "load" then gen_step(); cursor.update(dt / 1000); return end
    local t0 = pico.micros()
    if G.mode == "play" then
        -- ウェーブ中と一時停止中はスリープしない
        if waves.phase == "wave" or G.speed == 0 then pico.keep_awake() end
        -- ゲームの計算(ゾンビ・兵士・建物・弾・押し合い)は1秒に30回まで(SIM_MS ごと)。画面の描き直しと操作は毎フレーム。
        -- 実機ではLuaの計算が1フレーム 5〜12ms かかり(PCの約30倍。特に重い所は無く、Luaの実行そのものの速さ)、
        -- 60〜90fps で毎回計算すると CPU の大半を使っていた
        sim_acc = sim_acc + dt
        local d = 0
        if sim_acc >= SIM_MS then
            d = math.min(sim_acc, 50) / 1000 * G.speed
            sim_acc = 0
        end
        if d > 0 then
            local ev = waves.update(d, zombies)
            if ev then wave_event(ev) end
            zombies.hunt = soldiers.count() + buildings.count() > 0
            zombies.update(d)
            soldiers.update(d)
            buildings.update(d)
            -- バリケードが変わったら流れの場を作り直す(少しずつ。作っている間は前の流れのまま)
            if G.flow_dirty then
                G.flow_dirty = false
                local ok, err = iso.flow_build(goals_around(arena.base.x, arena.base.z), FLOW_RULES)
                if not ok then G.say(pico.tr("道を作り直せません: ") .. tostring(err)); G.flow_retry = 2 end
            end
            local fi = iso.flow_info()
            if fi.building then iso.flow_step(800)
            elseif fi.failed or G.flow_retry then
                -- メモリが足りず作り直しが止まった(前の流れのまま動く): 2秒後にやり直す
                G.flow_retry = (G.flow_retry or 2) - d
                if G.flow_retry <= 0 then G.flow_retry = nil; G.flow_dirty = true end
            end
            if iso.crowd(2, CROWD_RULES) > 0 then
                zombies.sync()
                soldiers.sync()
            end
            combat.step(d)
        end
        if (perf.frames % 15) == 0 then pico.invalidate(hud) end
        if (#G.sel == 1 or G.bsel) and (perf.frames % 10) == 0 then pico.invalidate(panel) end
    end
    if tutorial.active and G.mode == "play" then
        if tutorial.update(dt / 1000) then
            pico.invalidate(view)
            if not tutorial.active then save.set("tut", true) end
        end
    end
    sfx.flush()
    if G.info_msg then
        G.info_t = G.info_t - dt / 1000
        if G.info_t <= 0 then G.info_msg = false; pico.invalidate(panel) end
    end
    cursor.update(dt / 1000)
    perf.lua_us = perf.lua_us + us_since(t0)
end

-- ---------------------------------------------------------------- 始める

math.randomseed(pico.millis())
local saved = save.load()
sfx.on = saved.snd ~= false
if saved.game and saved.game.seed then
    -- 途中の保存があれば、続きからか新しく始めるかを選ぶ(閉じた/キャンセルは続きから。うっかり保存を失わないように)
    local game = saved.game
    ui.menu(pico.tr("ゾンビTD"), { string.format(pico.tr("続きから W%d"), game.w or 1), pico.tr("新しく始める") },
        function(i) if i == 2 then new_game() else new_map(game.seed, game) end end,
        function() new_map(game.seed, game) end)
    saved = nil
else
    new_game()
end

if TEST then TEST.env = { G = G, waves = waves, save = save, zombies = zombies, soldiers = soldiers, buildings = buildings,
    orders = orders, ui = ui, new_map = new_map, tutorial = tutorial, sfx = sfx, next_wave = next_wave, back = back, scroll = scroll,
    center_on = center_on, origin = function() return OX, OY end, perf = perf, cursor = cursor } end
