-- ゾンビTD: コントローラーと物理キーボードの操作(カーソルを動かして選ぶ)。
-- 地図のカーソル(マス1つ。黄色のひし形)と、下の欄のボタンのフォーカス(ui.lua)を動かす。
--   十字/矢印: カーソルを1マス。マス目に沿って斜めに動く(上=右上、右=右下、下=左下、左=左上。
--              2つ同時で画面の上下左右)。押したままで続けて動く。画面の端に近づくとカメラが付いてくる
--   A/Enter・Space: カーソルの所の兵士・建物を選ぶ/選んだ兵士をそこへ動かす/「建設」中ならそこへ建てる
--   B/Esc: 建設をやめる → 選択を外す
--   X/x: 兵士を順に選ぶ、Y/y: 建物を順に選ぶ(カーソルもそこへ)
--   R/c: カーソルをベースへ、START/n: 次へ(準備時間)、L+十字/Shift+矢印: カメラだけ動かす
--   SELECT/Tab: 下の欄のボタンへ(左右で選び A で押す。B か SELECT で地図へ戻る)
--   メニュー(ui.menu)が開いている間は上下で選び A で決める、B でやめる
-- 地図をタッチするとカーソルは隠れる(次に十字を押すと画面の真ん中から)。
-- Luaのメモリを食わないよう関数を少なくしてある(関数1つで約0.5KB)。操作は名前(act の a)にしてから1か所で行う。
local iso = pico.iso
local G = require("state")
local orders = require("orders")
local soldiers = require("soldiers")
local buildings = require("buildings")
local ui = require("ui")
local M = { on = false, x = 0, z = 0 }

local VX, VY, VW, VH            -- 地図の表示範囲(init で決まる)
local hooks                     -- game.lua の操作 {scroll=, start=, new_game=}
local rx, rz, rt = 0, 0, 0      -- 押したままの向きと、次に動くまでの秒

-- カーソルのひし形(その柱の地面の上面)の手前の角。他の3つの角は決まった距離(1マス = 横16・縦8)
local function corner()
    local ax, ay = iso.to_screen(M.x, iso.ground(M.x, M.z) or 0, M.z)
    return math.floor(ax), math.floor(ay)
end

local function dirty()
    if M.on then
        local ax, ay = corner()
        pico.mark_dirty(ax - 18, ay - 19, 38, 23)
    end
end

function M.draw()
    if not M.on then return end
    local ax, ay = corner()
    pico.draw_line(ax, ay, ax + 16, ay - 8, 14, 2)
    pico.draw_line(ax + 16, ay - 8, ax, ay - 16, 14, 2)
    pico.draw_line(ax, ay - 16, ax - 16, ay - 8, 14, 2)
    pico.draw_line(ax - 16, ay - 8, ax, ay, 14, 2)
end

-- カーソルを柱 (x, z) へ。画面の端に近ければカメラを動かす
local function place(x, z)
    dirty()
    local w = iso.size() - 1
    M.x, M.z, M.on = math.max(0, math.min(w, math.floor(x))), math.max(0, math.min(w, math.floor(z))), true
    dirty()
    local sx, sy = corner()
    sy = sy - 8
    local mx = math.max(0, VX + 28 - sx) + math.min(0, VX + VW - 28 - sx)
    local my = math.max(0, VY + 20 - sy) + math.min(0, VY + VH - 20 - sy)
    if mx ~= 0 or my ~= 0 then hooks.scroll(mx, my) end
end
M.place = place

function M.hide()
    dirty()
    M.on = false
end

local function list_next(list, cur)
    local i = 0
    for k, u in ipairs(list) do if u == cur then i = k end end
    return list[i % #list + 1]
end

-- 操作を1つ行う。a = "move"(dx, dz で1マス)/ "cam"(dx, dz を画面の横・縦に動かす)/ "ok" / "cancel" /
-- "soldier" / "building" / "base" / "start" / "panel"(下の欄のフォーカスの入り切り)
local function act(a, dx, dz)
    if ui.menu_active() then
        return ui.menu_input(a == "move" and dx > 0, a == "move" and dx < 0, a == "ok" or a == "start", a == "cancel")
    end
    if G.mode == "over" then
        if a == "ok" or a == "start" then hooks.new_game() end
        return
    end
    if G.mode ~= "play" then return end
    if a == "panel" then ui.set_focus(not ui.focus)
    elseif ui.focus then
        -- 下の欄: 左右でボタンを選び、A で押す、B で地図へ
        if a == "move" and dz ~= 0 then ui.focus_move(-dz)
        elseif a == "ok" then ui.focus_press()
        elseif a == "cancel" then ui.set_focus(false) end
    elseif a == "move" then
        if M.on then place(M.x + dx, M.z + dz)
        else
            -- 隠れていたら画面の真ん中(無ければベース)に出す
            local x, _, z = iso.pick(VX + VW // 2, VY + VH // 2)
            local b = G.base
            if x then place(x, z) elseif b then place(b.x, b.z) end
        end
    elseif a == "cam" then hooks.scroll(dx, dz)
    elseif a == "ok" then
        if M.on then orders.act_at(M.x, M.z) else act("move", 0, 0) end
    elseif a == "cancel" then
        if G.build_mode then G.build_mode = false else orders.deselect_all() end
    elseif a == "soldier" or a == "building" then
        local s = a == "soldier"
        local list = s and soldiers.list or buildings.list
        if #list == 0 then return G.say(s and "兵士がいません" or "建物がありません") end
        local u = list_next(list, s and G.sel[1] or G.bsel)
        if s then orders.set_selection({ u }) else orders.select_building(u) end
        place(u.x, u.z)
    elseif a == "base" then
        local b = G.base
        if b then place(b.x, b.z) end
    elseif a == "start" then hooks.start() end
    pico.invalidate(G.panel)
end
M.act = act

-- コントローラーのボタン → 操作(押した瞬間)
local PAD_ACT = { a = "ok", b = "cancel", x = "soldier", y = "building", r = "base", start = "start", select = "panel" }

-- 毎フレーム(dt は秒)。コントローラーを読む
function M.update(dt)
    local pd, pp = pico.pad_down, pico.pad_pressed
    for b, a in pairs(PAD_ACT) do if pp(b) then act(a) end end
    local dx = (pd("up") and 1 or 0) - (pd("down") and 1 or 0)
    local dz = (pd("left") and 1 or 0) - (pd("right") and 1 or 0)
    if pd("l") then
        -- L を押している間はカメラだけ(左右は画面の左右、上下は画面の上下)
        if dx ~= 0 or dz ~= 0 then act("cam", dz * 6, dx * 4) end
        dx, dz = 0, 0
    end
    if dx ~= rx or dz ~= rz then
        rx, rz, rt = dx, dz, 0.28
        if dx ~= 0 or dz ~= 0 then act("move", dx, dz) end
    elseif dx ~= 0 or dz ~= 0 then
        rt = rt - dt
        if rt <= 0 then rt = 0.08; act("move", dx, dz) end
    end
end

-- 物理キーボードのキー → 操作。矢印は {dx, dz, カメラの横, 縦}(Shift+矢印でカメラ)
local KEY_ACT = { enter = "ok", [" "] = "ok", escape = "cancel", x = "soldier", y = "building", c = "base",
    n = "start", tab = "panel" }
local KEY_DIR = { up = { 1, 0, 0, 16 }, down = { -1, 0, 0, -16 }, left = { 0, 1, 32, 0 }, right = { 0, -1, -32, 0 } }

-- 取ったら true(メニューが開いている間は全部取る)
function M.key(key, mods)
    local d = KEY_DIR[key]
    if d then
        if mods and mods.shift then act("cam", d[3], d[4]) else act("move", d[1], d[2]) end
    elseif KEY_ACT[key] then act(KEY_ACT[key])
    else return ui.menu_active() end
    return true
end

-- view = {x=, y=, w=, h=}
function M.init(view, h)
    VX, VY, VW, VH = view.x, view.y, view.w, view.h
    hooks = h
end

return M
