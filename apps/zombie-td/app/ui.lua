-- ゾンビTD: 下の欄(情報の行 + ボタンの行)。
--   情報の行: 選んだ兵士/建物の情報と[強化][修理][売却]、建てる所の案内、準備時間の次のウェーブの予告
--   ボタン: [戻る][雇う][建設][選択](範囲選択)[x1/x3/停止](速さ)[他]
-- 選ぶ一覧(メニュー)もここ。地図の上に枠を出し、タッチでもコントローラー/キーボードでも選べる
-- (OSのダイアログはタッチでしか選べないので使わない)。
-- コントローラーで下の欄を選んでいる間は、そのボタンを黄色の枠で囲む(M.focus。cursor.lua が動かす)。
local G = require("state")
local PAL = require("palette")
local orders = require("orders")
local soldiers = require("soldiers")
local buildings = require("buildings")
local waves = require("waves")
local sfx = require("sfx")
local M = {}

local CX, PY, CW, INFO_H, BTN_H         -- 置き場所(init で決まる)
local VY, VH                            -- 地図の表示範囲の縦(メニューの置き場所)
local actions                           -- game.lua の操作 {back=, center=, new_game=, sound=, tutorial=}
local held = nil

function M.box(x, y, w, h, label, on)
    pico.fill_rect(x, y, w, h, on and PAL.mid or PAL.light)
    pico.draw_rect(x, y, w, h, 0)
    if label then pico.draw_text(x + w // 2, y + (h - 16) // 2, label, 0, 0, "center") end
end
local box = M.box

local BUTTONS = {
    { id = "back" }, { id = "hire", label = pico.tr("雇う") }, { id = "build", label = pico.tr("建設") },
    { id = "select", label = pico.tr("選択") }, { id = "speed" }, { id = "more", label = pico.tr("他") },
}
local SOLDIER_BUTTONS, BUILDING_BUTTONS
M.buttons = BUTTONS

local function info_buttons()
    if G.info_msg or G.build_mode then return nil end
    if G.bsel then return BUILDING_BUTTONS end
    if #G.sel == 1 then return SOLDIER_BUTTONS end
end

local function info_label(b)
    local bs = G.bsel
    if bs then
        local v
        if b.id == "upgrade" then v = buildings.upgrade_cost(bs)
        elseif b.id == "repair" then v = buildings.repair_cost(bs)
        else v = buildings.sell_value(bs) end
        local head = b.id == "upgrade" and pico.tr("強") or (b.id == "repair" and pico.tr("修") or pico.tr("売"))
        return v and (head .. v) or "-"
    end
    local s = G.sel[1]
    if b.id == "upgrade" then
        local c = soldiers.upgrade_cost(s)
        return c and (pico.tr("強化") .. c) or pico.tr("最大")
    end
    return pico.tr("売") .. soldiers.sell_value(s)
end

-- 建物の情報の行: 名前とレベル・耐久(建設中/強化中/修理中は残り秒。耐久は頭の上のバーで見える)
local function building_text(b)
    local left = buildings.remaining(b)
    if left then
        return string.format(pico.tr("%s %s%d秒"), b.t.name, b.state == "build" and pico.tr("建設") or (b.state == "up" and pico.tr("強化") or pico.tr("修理")),
            math.ceil(left))
    end
    return string.format("%s%d %d/%d", b.t.name, b.lv, math.max(0, math.floor(b.hp)), buildings.max_hp(b))
end

local function focus_list()
    local list = {}
    for _, b in ipairs(info_buttons() or {}) do list[#list + 1] = b end
    for _, b in ipairs(BUTTONS) do list[#list + 1] = b end
    return list
end

local function render()
    pico.fill_rect(CX, PY, CW, INFO_H + BTN_H, PAL.dark)
    local buttons = info_buttons()
    if G.info_msg then
        pico.draw_text(CX + 4, PY + 2, G.info_msg, 14, 0)
    elseif G.build_mode then
        local t = buildings.TYPES[G.build_mode]
        pico.draw_text(CX + 4, PY + 2, string.format(pico.tr("%s($%d) 置く所をタップ"), t.name, t.cost), 14, 0)
    elseif G.bsel then
        pico.draw_text(CX + 2, PY + 2, building_text(G.bsel), 15, 0)
    elseif #G.sel == 1 then
        local s = G.sel[1]
        pico.draw_text(CX + 2, PY + 2, string.format("%sLv%d %d/%d", s.t.name, s.lv, math.max(0, math.floor(s.hp)), soldiers.max_hp(s)), 15, 0)
    elseif #G.sel > 1 then
        pico.draw_text(CX + 4, PY + 2, pico.tr("%s人選択中 タップで移動", #G.sel), 15, 0)
    elseif G.select_mode then
        pico.draw_text(CX + 4, PY + 2, pico.tr("ドラッグで囲んで選ぶ"), 14, 0)
    elseif G.mode == "play" and waves.phase == "prep" then
        pico.draw_text(CX + 4, PY + 2, waves.preview(waves.n), 14, 0)
    else
        pico.draw_text(CX + 4, PY + 2, string.format(pico.tr("兵士%d人 タップで選ぶ"), soldiers.count()), 8, 0)
    end
    for _, b in ipairs(buttons or {}) do
        box(CX + b.x, PY + 1, b.w - 2, INFO_H - 2, nil, held == b)
        pico.draw_text(CX + b.x + (b.w - 2) // 2, PY + 2, info_label(b), 0, 0, "center")
        if M.focus == b then pico.draw_rect(CX + b.x, PY + 1, b.w - 2, INFO_H - 2, 14) end
    end
    for _, b in ipairs(BUTTONS) do
        local label = b.label or (b.id ~= "back" and (G.speed == 0 and pico.tr("停止") or ("x" .. G.speed))) or nil
        box(CX + b.x + 1, PY + INFO_H + 2, b.w - 2, BTN_H - 4, label, held == b or (b.id == "select" and G.select_mode))
        if b.id == "back" then   -- 戻るは左向きの矢印
            local mx, my = CX + b.x + b.w // 2, PY + INFO_H + 2 + (BTN_H - 4) // 2
            pico.fill_triangle(mx - 6, my, mx + 5, my - 6, mx + 5, my + 6, 0)
        end
        if M.focus == b then
            pico.draw_rect(CX + b.x + 1, PY + INFO_H + 2, b.w - 2, BTN_H - 4, 14)
            pico.draw_rect(CX + b.x + 2, PY + INFO_H + 3, b.w - 4, BTN_H - 6, 14)
        end
    end
end

-- ---------------------------------------------------------------- メニュー
local MENU_X, MENU_W, MENU_IH = 20, 200, 26
local menu = nil            -- {title=, items=, fn=, cancel=, idx=}

local function menu_rect()
    local h = 26 + #menu.items * MENU_IH + 4
    return CX + MENU_X, VY + (VH - h) // 2, MENU_W, h
end

function M.menu_active() return menu ~= nil end

-- 選ぶ一覧を出す。選んだら fn(番号。1始まり)、やめたら cancel()
function M.menu(title, items, fn, cancel)
    menu = { title = title, items = items, fn = fn, cancel = cancel, idx = 1 }
    pico.invalidate(G.view)
end

function M.menu_close(i)
    local m = menu
    if not m then return end
    menu = nil
    pico.invalidate(G.view)
    if i then m.fn(i) elseif m.cancel then m.cancel() end
end

function M.menu_draw()
    if not menu then return end
    local x, y, w, h = menu_rect()
    pico.fill_rect(x, y, w, h, PAL.light)
    pico.draw_rect(x, y, w, h, 0)
    pico.draw_text(x + w // 2, y + 5, menu.title, 0, 0, "center")
    for i, s in ipairs(menu.items) do
        local iy = y + 26 + (i - 1) * MENU_IH
        box(x + 6, iy, w - 12, MENU_IH - 2, s, i == menu.idx)
        if i == menu.idx then pico.draw_rect(x + 5, iy - 1, w - 10, MENU_IH, 14) end
    end
end

-- 地図のタップ: 項目なら選ぶ、枠の外ならやめる
function M.menu_tap(px, py)
    local x, y, w, h = menu_rect()
    if px < x or px >= x + w or py < y or py >= y + h then return M.menu_close(nil) end
    local i = (py - y - 26) // MENU_IH + 1
    if py >= y + 26 and i >= 1 and i <= #menu.items then M.menu_close(i) end
end

-- 上下で選び、ok で決める、cancel でやめる
function M.menu_input(up, down, ok, cancel)
    if not menu then return end
    local n = #menu.items
    if up or down then
        menu.idx = (menu.idx - 1 + (up and -1 or 1)) % n + 1
        pico.mark_dirty(menu_rect())
    end
    if ok then M.menu_close(menu.idx) elseif cancel then M.menu_close(nil) end
end

function M.press(b)
    local id = b.id
    if id == "back" then actions.back()
    elseif id == "hire" or id == "build" then
        if G.mode ~= "play" then return end
        if G.build_mode then G.build_mode = false; pico.invalidate(G.panel); return end
        local mod = id == "hire" and soldiers or buildings
        local items = {}
        for i, k in ipairs(mod.KINDS) do
            local t = mod.TYPES[k]
            items[i] = string.format("%s%s $%d", t.name, id == "hire" and pico.tr("兵") or "", t.cost)
        end
        M.menu(string.format("%s($%d)", id == "hire" and pico.tr("雇う") or pico.tr("建てる"), G.money), items, function(i)
            if id == "hire" then orders.hire(mod.KINDS[i])
            else orders.deselect_all(); G.build_mode = mod.KINDS[i] end
            pico.invalidate(G.panel)
        end)
    elseif id == "select" then G.select_mode = not G.select_mode
    elseif id == "speed" then G.speed = G.speed == 1 and 3 or (G.speed == 3 and 0 or 1)
    elseif id == "more" then
        local more = { pico.tr("ベースを見る"), pico.tr("選択を解除"), sfx.on and pico.tr("効果音を切る") or pico.tr("効果音を入れる"), pico.tr("説明をもう一度"), pico.tr("新しく始める") }
        M.menu(pico.tr("その他"), more, function(i)
            if i == 1 then actions.center()
            elseif i == 2 then orders.deselect_all()
            elseif i == 3 then actions.sound(not sfx.on)
            elseif i == 4 then actions.tutorial()
            else
                M.menu(pico.tr("今のゲームをやめますか?"), { pico.tr("続ける"), pico.tr("新しいマップで始める") },
                    function(k) if k == 2 then actions.new_game() end end)
            end
        end)
    elseif id == "upgrade" then orders.upgrade()
    elseif id == "repair" then orders.repair()
    elseif id == "sell" then orders.sell()
    end
    pico.invalidate(G.panel)
end

-- ---------------------------------------------------------------- フォーカス(コントローラー)
M.focus = nil

function M.set_focus(on)
    M.focus = on and BUTTONS[2] or nil     -- 「雇う」から
end

function M.focus_move(d)
    local list = focus_list()
    local i = 0
    for k, b in ipairs(list) do if b == M.focus then i = k end end
    if i == 0 then i = d > 0 and 0 or 1 end
    M.focus = list[(i - 1 + d) % #list + 1]
    pico.invalidate(G.panel)
end

-- フォーカスのボタンを押す。速さ・強化・修理はそのまま、他は押したら地図へ戻る
local STAY = { speed = true, upgrade = true, repair = true }
function M.focus_press()
    local b = M.focus
    local found = false
    for _, x in ipairs(focus_list()) do if x == b then found = true end end
    if not found then M.focus = BUTTONS[2]; pico.invalidate(G.panel); return end
    if not STAY[b.id] then M.focus = nil end
    M.press(b)
end

local function button_at(lx, ly)
    if ly >= INFO_H then
        for _, b in ipairs(BUTTONS) do if lx >= b.x and lx < b.x + b.w then return b end end
    else
        for _, b in ipairs(info_buttons() or {}) do if lx >= b.x and lx < b.x + b.w then return b end end
    end
end

-- layout = {x=, y=, w=, info_h=, btn_h=}
function M.init(layout, acts)
    CX, PY, CW, INFO_H, BTN_H = layout.x, layout.y, layout.w, layout.info_h, layout.btn_h
    VY, VH = layout.vy, layout.vh
    MENU_X, MENU_W = 20, CW - 40
    actions = acts
    local bw = CW // #BUTTONS
    for i, b in ipairs(BUTTONS) do b.x = (i - 1) * bw; b.w = (i == #BUTTONS) and (CW - b.x) or bw end
    SOLDIER_BUTTONS = { { id = "upgrade", x = CW - 96, w = 52 }, { id = "sell", x = CW - 42, w = 42 } }
    BUILDING_BUTTONS = { { id = "upgrade", x = CW - 120, w = 40 }, { id = "repair", x = CW - 80, w = 40 },
        { id = "sell", x = CW - 40, w = 40 } }
    local panel = G.panel
    pico.on(panel, "render", render)
    pico.on(panel, "press_start", function(_, _, _, lx, ly)
        if menu then return end
        M.focus = nil
        held = button_at(lx, ly)
        pico.invalidate(panel)
    end)
    pico.on(panel, "press_end", function(_, _, _, lx, ly)
        local b = held
        held = nil
        pico.invalidate(panel)
        if b and b == button_at(lx, ly) then M.press(b) end
    end)
    pico.on(panel, "press_out", function() held = nil; pico.invalidate(panel) end)
end

return M
