-- ゾンビTD: 選ぶ・雇う・建てる・強化・修理・売る・移動の指示(画面の操作から呼ぶ)。
-- 状態は state.lua(G)。G.S_STAND(兵士と建てる所の規則)は game.lua が入れる。
local iso = pico.iso
local G = require("state")
local combat = require("combat")
local soldiers = require("soldiers")
local buildings = require("buildings")
local sfx = require("sfx")
local M = {}

function M.deselect_all()
    local sel = G.sel
    for i = #sel, 1, -1 do soldiers.select(sel[i], false); sel[i] = nil end
    if G.bsel then
        if G.bsel.id then iso.entity_set(G.bsel.id, { mark = false }) end
        iso.cursor(0, 0, 0, false)
        G.bsel = false
    end
    pico.invalidate(G.panel)
end

function M.set_selection(list)
    M.deselect_all()
    for i, s in ipairs(list) do G.sel[i] = s; soldiers.select(s, true) end
end

-- 建物を選ぶ(タワーは頭の上の印、バリケードはそのブロックにカーソル)
function M.select_building(b)
    M.deselect_all()
    G.bsel = b
    if b.id then iso.entity_set(b.id, { mark = 14 })
    else iso.cursor(math.floor(b.x), b.y, math.floor(b.z), true) end
end

-- 倒れた兵士・壊された建物は選択からも外す
soldiers.on_lost = function(s)
    for i = #G.sel, 1, -1 do if G.sel[i] == s then table.remove(G.sel, i) end end
    pico.invalidate(G.panel)
end
buildings.on_lost = function(b)
    if G.bsel == b then G.bsel = false; iso.cursor(0, 0, 0, false) end
    pico.invalidate(G.panel)
end

local function pay(c)
    if G.money < c then G.say("お金が足りません"); return false end
    G.add_money(-c)
    sfx.coin()
    return true
end

function M.hire(kind)
    local t = soldiers.TYPES[kind]
    if soldiers.count() >= soldiers.MAX then return G.say("兵士は" .. soldiers.MAX .. "人までです") end
    if G.money < t.cost then return G.say("お金が足りません") end
    local s = soldiers.hire(kind)
    if not s then return G.say("これ以上置けません") end
    pay(t.cost)
    M.set_selection({ s })
end

-- 建てる(G.build_mode の種類を、タップした柱へ)
function M.build_at(bx, bz)
    local kind = G.build_mode
    local ok, why = buildings.can_place(kind, bx, bz, G.S_STAND)
    if not ok then return G.say(why) end
    if G.money < buildings.TYPES[kind].cost then return G.say("お金が足りません") end
    local b = buildings.place(kind, bx, bz, G.S_STAND)
    if not b then return G.say("これ以上置けません") end
    pay(buildings.TYPES[kind].cost)
    G.build_mode = false
    M.select_building(b)
end

function M.upgrade()
    local b = G.bsel
    if b then
        local c = buildings.upgrade_cost(b)
        if c and pay(c) then buildings.upgrade(b) end
        return
    end
    local s = G.sel[1]
    if #G.sel ~= 1 then return end
    local c = soldiers.upgrade_cost(s)
    if c and pay(c) then soldiers.upgrade(s) end
end

function M.repair()
    local b = G.bsel
    local c = b and buildings.repair_cost(b)
    if c and pay(c) then buildings.repair(b) end
end

function M.sell()
    local v
    if G.bsel then
        local b = G.bsel
        if not buildings.sell_value(b) then return G.say("建設中・強化中は売れません") end
        M.deselect_all()
        v = buildings.sell(b)
    elseif #G.sel == 1 then
        local s = G.sel[1]
        M.deselect_all()
        v = soldiers.sell(s)
    else return end
    G.add_money(v)
    sfx.coin()
end

-- 選ぶ(選んでいるものをもう一度選ぶと外す)
local function toggle(u)
    if u.side == "soldier" then
        if #G.sel == 1 and G.sel[1] == u then M.deselect_all() else M.set_selection({ u }) end
    elseif G.bsel == u then M.deselect_all()
    else M.select_building(u) end
end

-- 選んでいる兵士を柱 (bx, bz) へ動かす
local function move_to(bx, bz)
    if #G.sel == 0 then return end
    if soldiers.order_group(G.sel, bx + 0.5, bz + 0.5) then G.moved = true else G.say("そこへは行けません") end
end

-- 柱の真ん中の近くに立っている兵士
local function soldier_near(bx, bz)
    local best, bd = nil, 0.75
    for _, s in ipairs(soldiers.list) do
        local d = math.max(math.abs(s.x - bx - 0.5), math.abs(s.z - bz - 0.5))
        if d < bd then best, bd = s, d end
    end
    return best
end

-- 地図のタップ: 兵士・建物なら選ぶ、地面なら選んでいる兵士を動かす/「建設」で選んだ建物を建てる
function M.tap_map(px, py)
    local id = not G.build_mode and iso.entity_at(px, py)
    local u = id and combat.units[id]
    if u and (u.side == "soldier" or u.side == "building") then return toggle(u) end
    local bx, _, bz = iso.pick(px, py)
    if not bx then return end
    if G.build_mode then return M.build_at(bx, bz) end
    local w = buildings.wall_at(bx, bz)
    if w then return toggle(w) end
    move_to(bx, bz)
end

-- カーソル(コントローラー)で柱 (bx, bz) を選んだ: そこの兵士・建物を選ぶ/選んでいる兵士を動かす/建てる
function M.act_at(bx, bz)
    if G.build_mode then return M.build_at(bx, bz) end
    local u = soldier_near(bx, bz) or buildings.at[buildings.col(bx, bz)]
    if u then return toggle(u) end
    move_to(bx, bz)
end

-- 範囲選択: 画面の矩形の中に立っている兵士
function M.select_rect(x0, y0, x1, y1)
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    local got = {}
    for _, s in ipairs(soldiers.list) do
        local sx, sy = iso.to_screen(s.x, s.y + 0.6, s.z)
        if sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1 then got[#got + 1] = s end
    end
    M.set_selection(got)
    if #got == 0 then G.say("兵士がいません") end
end

return M
