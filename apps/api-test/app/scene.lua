-- 画面とデータ: 次の5つの確認
--   1. require("util")                         … モジュールの分割
--   2. press_start(id, x, y, lx, ly, dx, dy)   … タッチ座標の引数(盤面のマス目を逆算)
--   3. push_scene(path, args) / pico.args() / pico.pop(result) / on_suspend・on_resume・on_result / store_load・store_save
--   4. json_decode / json_encode(HTTPは権限が要るのでここでは使わない)
--   5. pico.every / pico.after / pico.cancel
local util = require("util")

local x, y, w, h = pico.content_rect()
local save = pico.store_load() or { taps = 0 }
local seconds = 0
local picked = "-"
local last_cell = "-"

local function label(text, lx, ly)
    local l = pico.create("Label")
    pico.set(l, "x", lx)
    pico.set(l, "y", ly)
    pico.set(l, "font_size", 0)   -- 小さい文字(16px)
    pico.set(l, "text", text)
    return l
end

local title = label(pico.tr("画面とデータ"), x + 8, y + 4)
local clock_label = label(pico.tr("経過 0:00"), x + 8, y + 24)
local cell_label = label(pico.tr("マス: -"), x + 8, y + 44)
local drag_label = label(pico.tr("ドラッグ: 0,0"), x + 8, y + 64)
local json_label = label("", x + 8, y + 84)
local pick_label = label(pico.tr("選んだ色: -"), x + 8, y + 104)
local tap_label = label(pico.tr("保存済みタップ数: ") .. save.taps, x + 8, y + 124)

-- 5. タイマー: 1秒ごとに経過時間(util.clock)を更新
pico.every(1000, function()
    seconds = seconds + 1
    pico.set(clock_label, "text", pico.tr("経過 ") .. util.clock(seconds))
end)

-- 2. 盤面: 108x72の枠を 36x24 のマスに分け、lx,ly から (列,行) を出す
local board = pico.create("Canvas")
pico.set(board, "x", x + 8)
pico.set(board, "y", y + 148)
pico.set(board, "w", 108)
pico.set(board, "h", 72)
local sel_col, sel_row = nil, nil
pico.on(board, "render", function()
    local ax, ay = pico.get_draw_area()
    local bx = x + 8
    local by = y + 148
    pico.fill_rect(bx, by, 108, 72, 15)
    for c = 0, 3 do
        pico.draw_line(bx + c * 36, by, bx + c * 36, by + 71, 0)
    end
    for r = 0, 2 do
        pico.draw_line(bx, by + r * 24, bx + 107, by + r * 24, 0)
    end
    if sel_col then
        pico.fill_rect(bx + sel_col * 36 + 1, by + sel_row * 24 + 1, 35, 23, 8)
    end
end)
pico.on(board, "press_start", function(id, px, py, lx, ly)
    sel_col, sel_row = lx // 36, ly // 24
    last_cell = sel_col .. "," .. sel_row
    pico.set(cell_label, "text", pico.tr("マス: ") .. last_cell)
    pico.invalidate(board)
    save.taps = save.taps + 1
    pico.set(tap_label, "text", pico.tr("保存済みタップ数: ") .. save.taps)
    pico.store_save(save)                      -- アプリのフォルダの store.json に保存
end)
local drag_x, drag_y = 0, 0
pico.on(board, "press_move", function(id, px, py, lx, ly, dx, dy)
    drag_x, drag_y = drag_x + dx, drag_y + dy
    pico.set(drag_label, "text", pico.tr("ドラッグ: ") .. drag_x .. "," .. drag_y)
end)

-- 4. JSON: 往復して表示
local round = pico.json_decode(pico.json_encode({ name = "たろう", scores = { 10, 20.5 }, ok = true }))
pico.set(json_label, "text", "JSON: " .. round.name .. " " .. round.scores[2] .. " " .. tostring(round.ok))

-- 3. 画面の受け渡し
local pick_btn = pico.create("Button")
pico.set(pick_btn, "x", x + 8)
pico.set(pick_btn, "y", y + 232)
pico.set(pick_btn, "w", 130)
pico.set(pick_btn, "h", 34)
pico.set(pick_btn, "text", pico.tr("色を選ぶ"))
pico.on(pick_btn, "press_end", function()
    pico.push_scene(pico.path_join(pico.app_dir(), "picker.lua"), { title = pico.tr("色を選ぶ") })
end)

local back = pico.create("Button")
pico.set(back, "x", x + 150)
pico.set(back, "y", y + 232)
pico.set(back, "w", 80)
pico.set(back, "h", 34)
pico.set(back, "icon_id", 30)  -- ArrowLeft
pico.on(back, "press_end", function() pico.pop() end)

-- 離れる前の状態を持ち越す(Pop で戻るとこのスクリプトは最初から実行し直される)
function on_suspend()
    return { seconds = seconds, picked = picked, cell = last_cell }
end
function on_resume(s)
    seconds = s.seconds
    picked = s.picked
    pico.set(clock_label, "text", pico.tr("経過 ") .. util.clock(seconds))
    pico.set(pick_label, "text", pico.tr("選んだ色: ") .. picked)
end
function on_result(r)
    picked = r.color
    pico.set(pick_label, "text", pico.tr("選んだ色: ") .. picked .. " (#" .. r.index .. ")")
end
