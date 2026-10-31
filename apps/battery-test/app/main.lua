-- 電池テスト: 電池で動いていられる時間を、負荷の違う3通りで測る放置用アプリ。
-- 60秒ごとに経過時間と電池の状態を log.csv へ追記する(電池が切れて落ちても最後の行が結果)。
-- 保存先は SDの /lua/apps/電池テスト/ 。画面の「前回」は store.json から出す。
--
--   高負荷 … 全画面を毎フレーム描き直し、計算も回す。スリープしない
--   中負荷 … 1秒ごとに画面を更新。スリープしない
--   低負荷 … 1分ごとにだけ更新。何もしないので自動調光・スリープに任せる
--
-- 測るときはUSBを外し、画面の明るさ・Wi-Fi・音量を毎回同じにすること。

local X, Y, W, H = pico.content_rect()
local LOG = pico.path_join(pico.app_dir(), "log.csv")
local LOG_EVERY_S = 60

local MODES = {
    { key = "high", name = pico.tr("高負荷"), desc = pico.tr("全面描画+計算") },
    { key = "mid",  name = pico.tr("中負荷"), desc = pico.tr("1秒ごと更新") },
    { key = "low",  name = pico.tr("低負荷"), desc = pico.tr("放置(スリープ可)") },
}

local store = pico.store_load() or {}
store.runs = store.runs or 0
store.last = store.last or {}

local function fmt(sec)
    return string.format("%d:%02d:%02d", sec // 3600, (sec // 60) % 60, sec % 60)
end

local function label(y, text, size)
    local l = pico.create("Label")
    pico.set(l, "x", X + 4)
    pico.set(l, "y", y)
    pico.set(l, "font_size", size or 0)
    pico.set(l, "text", text)
    return l
end

local function button(text, x, y, w, h, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", x)
    pico.set(b, "y", y)
    pico.set(b, "w", w)
    pico.set(b, "h", h)
    pico.on(b, "press_end", fn)
    return b
end

local running, mode, run_no = false, nil, 0
local total_s, rem_ms, since_log, frame = 0, 0, 0, 0
local mode_btns, mode_descs = {}, {}
local lbl_state, lbl_time, lbl_batt, lbl_usb, lbl_hist, btn_stop, btn_back, canvas

local CANVAS_Y = Y + 70
local CANVAS_H = H - 70
local shown_time, shown_batt = "", ""

local function show_history()
    local parts = {}
    for _, m in ipairs(MODES) do
        local s = store.last[m.key]
        parts[#parts + 1] = m.name:sub(1, 3) .. " " .. (s and fmt(s) or "-")
    end
    pico.set(lbl_hist, "text", pico.tr("前回 %s", table.concat(parts, " ")))
end

local function battery_text()
    local pct, v, usb = pico.battery()
    if not pct then return pico.tr("電池 -"), false, nil, nil end
    return string.format(pico.tr("電池 %d%% %.2fV"), pct, v), usb, pct, v
end

local function save_progress()
    local text, usb, pct, v = battery_text()
    if not pico.sd_exists(LOG) then
        pico.sd_write(LOG, "run,mode,elapsed_s,percent,volts,usb\n")
    end
    pico.sd_write(LOG, string.format("%d,%s,%d,%s,%s,%d\n", run_no, mode.key, total_s,
        pct and tostring(pct) or "", v and string.format("%.2f", v) or "", usb and 1 or 0), true)
    store.last[mode.key] = total_s
    pico.store_save(store)
    shown_batt = text .. (usb and " USB!" or "")
    pico.set(lbl_batt, "text", text)
    pico.set(lbl_usb, "text", usb and pico.tr("USB給電中! 外して測る") or "")
end

local function set_idle_ui(idle)
    for i = 1, #MODES do
        pico.set(mode_btns[i], "visible", idle)
        pico.set(mode_descs[i], "visible", idle)
    end
    pico.set(btn_back, "visible", idle)
    pico.set(btn_stop, "visible", not idle)
    local hi = (not idle) and mode.key == "high"
    pico.set(canvas, "visible", hi)
    -- 高負荷は文字もキャンバスの中へ描くので、ラベルは隠す
    for _, l in ipairs({ lbl_state, lbl_time, lbl_batt, lbl_usb, lbl_hist }) do
        pico.set(l, "visible", not hi)
    end
end

local function start(m)
    mode = m
    store.runs = store.runs + 1
    run_no = store.runs
    running = true
    total_s, rem_ms, since_log = 0, 0, 0
    set_idle_ui(false)
    pico.set(lbl_state, "text", pico.tr("%s 測定中(run %s)", m.name, run_no))
    pico.set(lbl_time, "text", fmt(0))
    save_progress()
end

local function stop()
    if not running then return end
    running = false
    save_progress()
    set_idle_ui(true)
    pico.set(lbl_state, "text", pico.tr("停止しました(%s %s)", mode.name, fmt(total_s)))
    show_history()
end

label(Y + 2, pico.tr("電池テスト"), 1)
for i, m in ipairs(MODES) do
    local by = Y + 30 + (i - 1) * 40
    mode_btns[i] = button(m.name, X + 4, by, 84, 36, function() start(m) end)
    mode_descs[i] = label(by + 8, m.desc, 0)
    pico.set(mode_descs[i], "x", X + 94)
end
lbl_state = label(Y + 30 + 3 * 40 + 2, pico.tr("測る負荷を選んで開始"), 0)
lbl_time = label(Y + 30 + 3 * 40 + 22, "", 2)
lbl_batt = label(Y + 30 + 3 * 40 + 56, (battery_text()), 0)
lbl_usb = label(Y + 30 + 3 * 40 + 76, "", 0)
lbl_hist = label(Y + 30 + 3 * 40 + 96, "", 0)
pico.set(lbl_time, "text", "0:00:00")
btn_stop = button(pico.tr("停止"), X + 4, Y + 30, W - 8, 36, stop)
btn_back = button(pico.tr("戻る"), X + 4, Y + H - 34, 84, 30, function() pico.pop() end)

canvas = pico.create("Canvas")
pico.set(canvas, "x", X)
pico.set(canvas, "y", CANVAS_Y)
pico.set(canvas, "w", W)
pico.set(canvas, "h", CANVAS_H)
pico.on(canvas, "render", function()
    frame = frame + 1
    local cx, cy, cw, ch = X, CANVAS_Y, W, CANVAS_H
    pico.fill_rect(cx, cy, cw, ch, 1 + (frame // 20) % 14)
    for i = 0, 11 do
        pico.draw_line(cx + (i * 37 + frame * 5) % cw, cy,
            cx + cw - 1 - (i * 53 + frame * 3) % cw, cy + ch - 1, (i + frame) % 16)
    end
    pico.fill_circle(cx + (frame * 4) % cw, cy + (frame * 3) % ch, 20, 15 - (frame // 20) % 14)
    pico.draw_text(cx + 6, cy + 6, pico.tr("高負荷 run %s", run_no), 0)
    pico.draw_text(cx + 6, cy + 28, shown_time, 0)
    pico.draw_text(cx + 6, cy + 50, shown_batt, 0)
end)

set_idle_ui(true)
show_history()

function loop(dt)
    if not running then return end
    if mode.key ~= "low" then pico.keep_awake() end
    if mode.key == "high" then
        local s = 0
        for i = 1, 30000 do s = s + (i * i) % 7 end
        pico.invalidate(canvas)
    elseif mode.key == "mid" then
        local s = 0
        for i = 1, 2000 do s = s + (i * i) % 7 end
    end
    rem_ms = rem_ms + dt
    local ticked = false
    while rem_ms >= 1000 do
        rem_ms = rem_ms - 1000
        total_s = total_s + 1
        since_log = since_log + 1
        ticked = true
    end
    local logging = since_log >= LOG_EVERY_S
    if logging then
        since_log = 0
        save_progress()
    end
    -- 低負荷は画面をほとんど書き換えない(1分に1回)
    if (ticked and mode.key ~= "low") or logging then
        shown_time = fmt(total_s)
        pico.set(lbl_time, "text", shown_time)
    end
end
