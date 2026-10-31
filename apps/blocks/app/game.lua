-- ブロック: 斜め上から見たマインクラフト風の箱庭(TheScienceElf/Blocks-TI-84 の移植。MIT)
-- 1024x16x1024 の世界(見えている所のまわりのチャンクだけを読み込む)でカーソルを動かし、
-- 25種類のブロック(松明を含む)を置く/壊す。影・松明の光・昼と夜・半透明の水・5つのセーブ枠。
-- 操作(画面): 左下の9つのキー=移動(真ん中=置く/壊す)、上へ/下へ、ブロック変更、中央、昼/夜、終了。
--   ワールドのタップ=その面の手前へカーソル、長押し=そのブロックへカーソル、
--   ドラッグ=視点を動かす。
-- コントローラー: 十字=移動(斜めは2つ同時)、A=置く/壊す、B/START=ブロック変更、X/R=上へ、Y/L=下へ、
--   SELECT+十字=視点、ZL/ZR=昼/夜、HOME=保存して終了。
--   キーボード: 1〜9(5=置く/壊す)、*と-=上下、Enter=変更、矢印=視点、n=昼/夜。
-- 本体はこのファイル(main.lua は16KiBまでなので、32KiBまで読める require のモジュールにした)。
-- ワールド(チャンクの読み込み・生成・保存)と描画(影・松明の光・水・タップ位置の引き当て)は C++ のエンジン pico.iso
-- (src/iso/Iso_World、src/lua/LuaEngine_Iso.cpp)が受け持つ。ここは画面の流れと操作だけ。
-- 色は palette.lua(script/assets/generate_blocks_sheet.py が作る)。
local iso = pico.iso
local PAL = require("palette")
local H = 16
local B = { AIR = 0, WATER = 1, STONE = 2, GRASS = 3, TORCH = 25 }
local BLOCK_COUNT = 25          -- ブロックの種類(水と松明を含む)
local NIGHT_SKY = 0             -- 夜の空の色
local KINDS = { [0] = pico.tr("自然"), pico.tr("平ら"), pico.tr("デモ"), pico.tr("空") }

for i, c in ipairs(PAL.colors) do pico.set_palette(i, c[1], c[2], c[3]) end
iso.sky(PAL.sky)
local DIR = pico.app_dir()
local img = pico.image_load(pico.path_join(DIR, "faces.pimg"))
if img then iso.set_image(img) else pico.show_error(pico.tr("faces.pimg を読めません")) end
local SAVE_DIR = pico.path_join(DIR, "worlds")

local CX, CY, CW, CH = pico.content_rect()
local PANEL_H = 96
local VH = CH - PANEL_H
local PY = CY + VH
iso.view(CX, CY, CW, VH)

local view = pico.create("Canvas")
local panel = pico.create("Canvas")
pico.set(view, "x", CX); pico.set(view, "y", CY); pico.set(view, "w", CW)
pico.set(panel, "x", CX); pico.set(panel, "y", PY); pico.set(panel, "w", CW); pico.set(panel, "h", PANEL_H)

-- 選ぶ画面の並び(元と同じく水が最後。7列 x 4段)
local SEL_COLS, SEL_STEP = 7, 34
local ORDER = {}
for b = 2, BLOCK_COUNT do ORDER[#ORDER + 1] = b end
ORDER[#ORDER + 1] = B.WATER

local mode = "title"      -- title / play / select / busy / load(チャンクを読み込み中)
local busy_msg = ""
local slot = 1
local title_sel = 1
local exists = {}
local cur = B.STONE
local sel = 1
local SLOTS = 5
local in_game = false
local W = 48                   -- 今のワールドの1辺のマス数
local OX, OY = 0, 0            -- ブロック(0,0,0)の絵の左上(視点)
local cx, cy, cz = 0, 0, 0     -- カーソル
local night = false

-- スロット i のディレクトリ(world.dat とチャンクのファイルを入れる)と、前の版の1ファイルの保存
local function slot_dir(i) return pico.path_join(SAVE_DIR, string.char(64 + i)) end
local function old_path(i) return pico.path_join(SAVE_DIR, "world_" .. string.char(64 + i) .. ".dat") end
local function refresh_slots()
    for i = 1, SLOTS do
        local k, w = iso.info(slot_dir(i) .. "/world.dat")
        if k then exists[i] = (KINDS[k] or "?") .. " " .. w .. "x" .. w
        elseif pico.sd_exists(old_path(i)) then exists[i] = pico.tr("48x48(前の版)")
        else exists[i] = nil end
    end
end

local function set_mode(m)
    mode = m
    local full = (m == "title") or ((m == "busy" or m == "load") and not in_game)
    pico.set(view, "h", full and CH or VH)
    pico.set(panel, "visible", not full)
    pico.invalidate(view)
    pico.invalidate(panel)
end

local function busy(msg, fn)
    busy_msg = msg
    set_mode("busy")
    pico.after(40, fn)
end

local function click(f, ms) pico.sound_play(2, f, ms or 30, { wave = "noise", volume = 7 }) end

-- ---------------------------------------------------------------- カメラとカーソル

-- 視点を動かすと、エンジンが次の pump で読み込むチャンクの範囲を決め直す
local function set_origin(x, y)
    OX, OY = x, y
    iso.origin(x, y)
    pico.invalidate(view)
end

local function center_on(x, y, z)
    set_origin(CX + CW // 2 - 16 - 16 * (x - z), CY + VH // 2 - 16 + 8 * (x + z) + 16 * y)
end

-- カーソルが表示の端へ寄ったら真ん中へ戻す(戻したら true)
local function keep_visible()
    local bx, by = iso.block_pos(cx, cy, cz)
    if bx < CX + 8 or bx + 32 > CX + CW - 8 or by < CY + 8 or by + 31 > CY + VH - 8 then
        center_on(cx, cy, cz)
        return true
    end
    return false
end

local function cursor_to(x, y, z)
    x = math.max(0, math.min(W - 1, x))
    y = math.max(0, math.min(H - 1, y))
    z = math.max(0, math.min(W - 1, z))
    if x == cx and y == cy and z == cz then return end
    iso.dirty_block(cx, cy, cz)
    cx, cy, cz = x, y, z
    iso.cursor(x, y, z)
    if not keep_visible() then iso.dirty_block(x, y, z) end
end

local function move(dx, dy, dz) cursor_to(cx + dx, cy + dy, cz + dz) end

-- 昼/夜: 夜は日の光が無く、松明の光が届く所だけ明るい
local function set_night(on)
    night = on
    iso.sunlight(not on)
    iso.sky(on and NIGHT_SKY or PAL.sky)
    pico.invalidate(view)
    pico.invalidate(panel)
end

local function scroll(dx, dy) set_origin(OX + dx, OY + dy) end

-- 置く/壊す(元と同じ: 空気なら置く、水なら置き換える、ブロックなら壊す。水を持っているときは水を置く/何でも消す)
local function act()
    local x, y, z = cx, cy, cz
    local b = iso.get(x, y, z)
    if cur ~= B.WATER then
        if b == B.AIR or b == B.WATER then iso.set(x, y, z, cur); click(900)
        else iso.set(x, y, z, B.AIR); click(300, 60) end
    else
        if b == B.AIR then iso.set(x, y, z, B.WATER); click(600)
        else iso.set(x, y, z, B.AIR); click(300, 60) end
    end
    iso.dirty_edit(x, y, z)
end

-- ---------------------------------------------------------------- 始める・保存する

local function start(kind)
    busy(kind and pico.tr("ワールドを作っています...") or pico.tr("読み込んでいます..."), function()
        local d = slot_dir(slot)
        local x, y, z, c
        if kind then
            pico.sd_mkdir(SAVE_DIR)
            pico.sd_mkdir(d)
            math.randomseed(pico.millis())
            x, y, z = iso.create(d, kind, math.random(0, 0x7fffffff))
            c = B.STONE
            if not x then
                pico.show_error(pico.tr("ワールドを作れません: ") .. tostring(y))
                set_mode("title")
                return
            end
        else
            if not iso.info(d .. "/world.dat") and pico.sd_exists(old_path(slot)) then
                local ok, e = iso.migrate(old_path(slot), d)
                if not ok then
                    pico.show_error(pico.tr("前の版のワールドを移せません: ") .. tostring(e))
                    set_mode("title")
                    return
                end
            end
            x, y, z, c = iso.open(d)
            if not x then
                pico.show_error(pico.tr("ワールドを読めません: ") .. tostring(y))
                set_mode("title")
                return
            end
        end
        W = iso.size()
        cur = c
        cx, cy, cz = x, y, z
        iso.cursor(x, y, z, true)
        in_game = true
        center_on(x, y, z)
        busy_msg = pico.tr("チャンクを読み込んでいます...")
        set_mode("load")
    end)
end

local function save_and_quit()
    busy(pico.tr("保存しています..."), function()
        local ok = iso.save(cx, cy, cz, cur)
        if not ok then pico.show_error(pico.tr("保存できませんでした")) end
        iso.close()
        in_game = false
        refresh_slots()
        set_mode("title")
    end)
end

local function open_slot(i, direct)
    slot = i
    title_sel = i
    pico.invalidate(view)
    local name = pico.tr("ワールド ") .. string.char(64 + i)
    if exists[i] then
        if direct then start(nil); return end
        local d = pico.show_choice(name, { pico.tr("遊ぶ"), pico.tr("削除する") })
        pico.on(d, "closed", function(_, ok, v)
            if not ok then return end
            if v == 0 then start(nil)
            else
                local m = pico.show_message(pico.tr("%s を削除しますか?", name), pico.tr("いいえ"), pico.tr("はい"))
                pico.on(m, "closed", function(_, yes)
                    if yes then
                        pico.sd_remove(slot_dir(i))
                        pico.sd_remove(old_path(i))
                        refresh_slots()
                        pico.invalidate(view)
                    end
                end)
            end
        end)
    else
        local d = pico.show_choice(pico.tr("どんなワールド?"), { pico.tr("自然"), pico.tr("平ら"), pico.tr("デモ") })
        pico.on(d, "closed", function(_, ok, v) if ok then start(v) end end)
    end
end

local function open_select()
    for i, b in ipairs(ORDER) do if b == cur then sel = i end end
    set_mode("select")
end

local function choose(i)
    if i then cur = ORDER[i]; click(1200, 20) end
    set_mode("play")
end

-- ---------------------------------------------------------------- 描画

local function button(x, y, w, h, label, on)
    pico.fill_rect(x, y, w, h, on and PAL.mid or PAL.light)
    pico.draw_rect(x, y, w, h, 0)
    if label then pico.draw_text(x + w // 2, y + (h - 16) // 2, label, 0, 0, "center") end
end

local function draw_title()
    pico.fill_rect(CX, CY, CW, CH, PAL.light)
    iso.draw_icon(B.GRASS, CX + 20, CY + 6)
    pico.draw_text(CX + 60, CY + 8, "Blocks", 0, 1)
    for i = 1, SLOTS + 1 do
        local y = CY + 44 + (i - 1) * 42
        local on = (i == title_sel)
        pico.fill_rect(CX + 10, y, CW - 20, i <= SLOTS and 38 or 30, on and 15 or PAL.light)
        pico.draw_rect(CX + 10, y, CW - 20, i <= SLOTS and 38 or 30, on and PAL.accent or PAL.mid)
        if i <= SLOTS then
            pico.draw_text(CX + 20, y + 4, pico.tr("ワールド ") .. string.char(64 + i), 0, 0)
            pico.draw_text(CX + 36, y + 20, exists[i] or pico.tr("( 空き )"), PAL.mid, 0)
        else
            pico.draw_text(CX + 20, y + 7, pico.tr("おわる"), 0, 0)
        end
    end
end

local function draw_select()
    pico.fill_rect(CX, CY, CW, VH, PAL.light)
    pico.draw_rect(CX + 2, CY + 2, CW - 4, VH - 4, 0)
    pico.draw_text(CX + CW // 2, CY + 6, pico.tr("ブロックを選ぶ"), 0, 0, "center")
    for i, b in ipairs(ORDER) do
        local col, row = (i - 1) % SEL_COLS, (i - 1) // SEL_COLS
        local x, y = CX + 1 + col * SEL_STEP, CY + 28 + row * 42
        if i == sel then
            pico.draw_rect(x, y - 2, 34, 38, PAL.accent)
            pico.draw_rect(x + 1, y - 1, 32, 36, PAL.accent)
        end
        iso.draw_icon(b, x + 1, y + 1)
    end
end

local function select_at(lx, ly)
    local col, row = (lx - 1) // SEL_STEP, (ly - 28) // 42
    if col < 0 or col >= SEL_COLS or row < 0 or ly < 28 then return nil end
    local i = row * SEL_COLS + col + 1
    if i > #ORDER then return nil end
    return i
end

pico.on(view, "render", function()
    if mode == "title" then draw_title()
    elseif mode == "busy" or mode == "load" then
        local x, y, w, h = pico.get_draw_area()
        pico.fill_rect(x, y, w, h, PAL.sky)
        local my = CY + (in_game and VH or CH) // 2
        button(CX + 30, my - 20, CW - 60, 40, busy_msg)
    elseif mode == "select" then draw_select()
    else iso.render() end
end)

-- 操作パネル: 9つの移動キー(真ん中は置く/壊す)と右側のボタン
local MOVES = {
    { "7", 0, 1, -2, -1 }, { "8", 1, 1, 0, -1 }, { "9", 1, 0, 2, -1 },
    { "4", -1, 1, -1, 0 }, { "5" }, { "6", 1, -1, 1, 0 },
    { "1", -1, 0, -2, 1 }, { "2", -1, -1, 0, 1 }, { "3", 0, -1, 2, 1 },
}
local BUTTONS = {}
for i, m in ipairs(MOVES) do
    BUTTONS[#BUTTONS + 1] = { id = m[1], x = ((i - 1) % 3) * 32, y = ((i - 1) // 3) * 32, w = 32, h = 32,
                              dx = m[2], dz = m[3], ax = m[4], ay = m[5], rep = m[1] ~= "5" }
end
local function add(id, x, y, w, label, rep)
    BUTTONS[#BUTTONS + 1] = { id = id, x = x, y = y, w = w, h = 30, label = label, rep = rep }
end
add("up", 102, 1, 67, pico.tr("上へ"), true)
add("down", 172, 1, 67, pico.tr("下へ"), true)
add("block", 102, 33, 137)
add("center", 102, 65, 45, pico.tr("中央"))
add("night", 149, 65, 45)
add("quit", 196, 65, 43, pico.tr("終了"))

local held = nil

pico.on(panel, "render", function()
    pico.fill_rect(CX, PY, CW, PANEL_H, PAL.dark)
    for _, b in ipairs(BUTTONS) do
        local x, y = CX + b.x, PY + b.y
        button(x, y, b.w, b.h, b.label, held == b)
        if b.id == "5" then
            iso.draw_icon(cur, x, y + 1)
        elseif b.ax then
            local len = math.sqrt(b.ax * b.ax + b.ay * b.ay)
            local vx, vy = b.ax / len, b.ay / len
            local mx, my = x + 16, y + 16
            local f = math.floor
            pico.draw_line(f(mx - vx * 11), f(my - vy * 11), f(mx + vx * 2), f(my + vy * 2), 0, 3)
            pico.fill_triangle(f(mx + vx * 12), f(my + vy * 12),
                f(mx + vy * 6), f(my - vx * 6), f(mx - vy * 6), f(my + vx * 6), 0)
        elseif b.id == "block" then
            pico.set_draw_area(x + 1, y + 1, 34, b.h - 2)
            iso.draw_icon(cur, x + 2, y)
            pico.clear_draw_area()
            pico.draw_text(x + 40, y + 7, pico.tr("ブロック変更"), 0, 0)
        elseif b.id == "night" then
            pico.draw_text(x + b.w // 2, y + (b.h - 16) // 2, night and pico.tr("昼へ") or pico.tr("夜へ"), 0, 0, "center")
        end
    end
end)

local function press(b)
    if mode ~= "play" then return end
    if b.dx then move(b.dx, 0, b.dz)
    elseif b.id == "5" then act()
    elseif b.id == "up" then move(0, 1, 0)
    elseif b.id == "down" then move(0, -1, 0)
    elseif b.id == "block" then open_select()
    elseif b.id == "center" then center_on(cx, cy, cz)
    elseif b.id == "night" then set_night(not night)
    elseif b.id == "quit" then save_and_quit() end
end

local function button_at(lx, ly)
    for _, b in ipairs(BUTTONS) do
        if lx >= b.x and lx < b.x + b.w and ly >= b.y and ly < b.y + b.h then return b end
    end
end

local rep_ms = 0
local function set_held(b)
    if b ~= held then held = b; pico.invalidate(panel) end
end

pico.on(panel, "press_start", function(_, _, _, lx, ly)
    local b = button_at(lx, ly)
    set_held(b)
    rep_ms = 320
    if b then press(b) end
end)
pico.on(panel, "press_move", function(_, _, _, lx, ly)
    local b = button_at(lx, ly)
    if b ~= held and b and b.rep then set_held(b); rep_ms = 320; press(b) end
end)
pico.on(panel, "press_end", function() set_held(nil) end)
pico.on(panel, "press_out", function() set_held(nil) end)

-- ワールドのタッチ: タップ=面の手前へ、長押し=そのブロックへ、ドラッグ=視点
local touch = nil
local function pick_to(px, py, onto)
    local x, y, z, f = iso.pick(px, py)
    if not x then return end
    if not onto then
        local nx, ny, nz = x, y, z
        if f == "top" then ny = y + 1 elseif f == "left" then nx = x - 1 else nz = z - 1 end
        if nx >= 0 and ny < H and nz >= 0 then x, y, z = nx, ny, nz end
    end
    cursor_to(x, y, z)
end

pico.on(view, "press_start", function(_, x, y)
    touch = { x = x, y = y, t = pico.millis(), drag = false, long = false }
end)
pico.on(view, "press_move", function(_, x, y, _, _, dx, dy)
    if not touch or mode ~= "play" then return end
    if not touch.drag and math.abs(x - touch.x) + math.abs(y - touch.y) > 8 then
        touch.drag = true
        dx, dy = x - touch.x, y - touch.y
    end
    if touch.drag then scroll(dx, dy) end
end)
pico.on(view, "press_end", function(_, x, y, lx, ly)
    local t = touch
    touch = nil
    if not t or t.drag or t.long then return end
    if mode == "play" then pick_to(x, y, false)
    elseif mode == "select" then
        local i = select_at(lx, ly)
        if i then choose(i) end
    elseif mode == "title" then
        local i = (ly - 44) // 42 + 1
        if ly >= 44 and i >= 1 and i <= SLOTS then open_slot(i)
        elseif i == SLOTS + 1 then pico.pop() end
    end
end)
pico.on(view, "press_out", function() touch = nil end)

-- ---------------------------------------------------------------- コントローラー・キーボード

local pad_rep, pad_dir = 0, nil

local function back()
    if mode == "play" then save_and_quit()
    elseif mode == "select" then choose(nil)
    elseif mode == "title" then return false end
    return true
end
pico.on_back(back)

function loop(dt)
    if in_game then
        -- 見えている所のチャンクを少しずつ読み込む(視点が変わっていればエンジンが範囲を決め直す)
        local n = iso.pump(mode == "load" and 48 or 8, mode == "load" and 40 or 10)
        if n > 0 and mode ~= "load" then pico.invalidate(view) end
        if mode == "load" and iso.pending() == 0 then
            set_mode("play")
            collectgarbage("collect")
            local m = pico.memory_info()
            local st = iso.stats()
            pico.log(string.format("ブロック: チャンク %d 個 (置き場 %d バイト)、Lua %d/%d バイト",
                st.chunks, st.bytes, m.lua_used, m.lua_budget))
        end
    end
    if touch and not touch.drag and not touch.long and mode == "play" and pico.millis() - touch.t > 500 then
        touch.long = true
        pick_to(touch.x, touch.y, true)
    end
    if held and held.rep then
        local _, _, on = pico.get_touch()
        if not on then set_held(nil)
        else
            rep_ms = rep_ms - dt
            if rep_ms <= 0 then rep_ms = 110; press(held) end
        end
    end
    local P = pico.pad_pressed
    if mode == "play" then
        local h = (pico.pad_down("right") and 1 or 0) - (pico.pad_down("left") and 1 or 0)
        local v = (pico.pad_down("up") and 1 or 0) - (pico.pad_down("down") and 1 or 0)
        local key = (h ~= 0 or v ~= 0) and (h * 3 + v) or nil
        local first = key ~= pad_dir
        if first then pad_dir = key; pad_rep = 0 end
        if key then
            pad_rep = pad_rep - dt
            if first or pad_rep <= 0 then
                pad_rep = first and 300 or 110
                if pico.pad_down("select") then scroll(-h * 32, v * 16)
                else
                    local cl = function(n) return math.max(-1, math.min(1, n)) end
                    move(cl(h + v), 0, cl(v - h))
                end
            end
        end
        if P("a") then act() end
        if P("b") or P("start") then open_select() end
        if P("x") or P("r") then move(0, 1, 0) end
        if P("y") or P("l") then move(0, -1, 0) end
        if P("zl") or P("zr") then set_night(not night) end
    elseif mode == "select" then
        local d = (P("right") and 1 or 0) - (P("left") and 1 or 0)
            + ((P("down") and SEL_COLS or 0) - (P("up") and SEL_COLS or 0))
        if d ~= 0 then sel = math.max(1, math.min(#ORDER, sel + d)); pico.invalidate(view) end
        if P("a") then choose(sel) elseif P("b") then choose(nil) end
    elseif mode == "title" then
        local d = (P("down") and 1 or 0) - (P("up") and 1 or 0)
        if d ~= 0 then title_sel = (title_sel - 1 + d) % (SLOTS + 1) + 1; pico.invalidate(view) end
        if P("a") or P("start") then
            if title_sel <= SLOTS then open_slot(title_sel, true) else pico.pop() end
        end
    end
end

local KEY_MOVES = {}
for _, m in ipairs(MOVES) do if m[2] then KEY_MOVES[m[1]] = m end end

pico.on_key(function(key)
    if key == "escape" then back(); return true end
    if mode == "play" then
        local m = KEY_MOVES[key]
        if m then move(m[2], 0, m[3])
        elseif key == "5" or key == " " then act()
        elseif key == "*" or key == "+" then move(0, 1, 0)
        elseif key == "-" or key == "/" then move(0, -1, 0)
        elseif key == "enter" then open_select()
        elseif key == "left" then scroll(32, 0)
        elseif key == "right" then scroll(-32, 0)
        elseif key == "up" then scroll(0, 16)
        elseif key == "down" then scroll(0, -16)
        elseif key == "c" then center_on(cx, cy, cz)
        elseif key == "n" then set_night(not night)
        else return false end
        return true
    elseif mode == "select" then
        local d = ({ left = -1, right = 1, up = -SEL_COLS, down = SEL_COLS })[key]
        if d then sel = math.max(1, math.min(#ORDER, sel + d)); pico.invalidate(view)
        elseif key == "enter" then choose(sel)
        else return false end
        return true
    elseif mode == "title" then
        if key == "up" or key == "down" then
            title_sel = (title_sel - 1 + (key == "down" and 1 or -1)) % (SLOTS + 1) + 1
            pico.invalidate(view)
        elseif key == "enter" then
            if title_sel <= SLOTS then open_slot(title_sel, true) else pico.pop() end
        elseif key == "delete" and title_sel <= SLOTS and exists[title_sel] then
            open_slot(title_sel)
        else return false end
        return true
    end
    return false
end)

refresh_slots()
set_mode("title")
-- PCビルドの --scene nature(画面写真用): ワールドAへ「自然」のワールドを作って入る(あれば読む)
do
    local tag, scene = pico.launch_reason()
    if tag == "scene" and scene == "nature" then
        slot = 1
        start(not exists[1] and 0 or nil)
    end
end

if TEST then TEST.env = { act = act, move = move, start = start, scroll = scroll, center_on = center_on,
    save_and_quit = save_and_quit, open_select = open_select, choose = choose, pick_to = pick_to,
    mode = function() return mode end, set_cur = function(b) cur = b end, slot = function(i) slot = i end,
    cursor = function() return cx, cy, cz end, set_cursor = function(x, y, z) cx, cy, cz = x, y, z end,
    origin = function() return OX, OY end, set_night = set_night, night = function() return night end,
    order = ORDER, select_at = select_at } end
