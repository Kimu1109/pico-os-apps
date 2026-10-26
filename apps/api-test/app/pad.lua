-- 外部コントローラーの動作確認(SUMMARY.md #10)。
-- 今押しているボタンを図で出し、十字キーで点を動かす(斜め = 2方向の同時押しの確認)。
-- 実物のコントローラーが無い間は、PCで script/pad_serial.py を動かすとキーボードがコントローラーになる。
-- HOMEか「戻る」でメニューへ戻る。

-- Buttonのw/hは枠・立体表示を含めた全体の大きさ。文字/アイコンの領域はこれより9px小さい
local BUTTON_FRAME = 9

local x, y, w, h = pico.content_rect()
local margin = 8

local BLACK, WHITE, GREY, RED, BLUE = 0, 15, 7, 12, 9

local status = pico.create("Label")
pico.set(status, "x", x + margin)
pico.set(status, "y", y + margin)
pico.set(status, "font_size", 0)
pico.set(status, "text", "")

-- ---- ボタンの図 ----
local PAD_Y = y + 36
local PAD_H = 118
local pad = pico.create("Canvas")
pico.set(pad, "x", x)
pico.set(pad, "y", PAD_Y)
pico.set(pad, "w", w)
pico.set(pad, "h", PAD_H)

local function key(px, py, bw, bh, name, label)
    local down = pico.pad_down(name)
    if down then
        pico.fill_rect(px, py, bw, bh, BLACK)
    else
        pico.draw_rect(px, py, bw, bh, BLACK)
    end
    pico.draw_text(px + 3, py + (bh - 16) // 2, label, down and WHITE or BLACK, 0)
end

local function round(cx, cy, r, name, label)
    local down = pico.pad_down(name)
    if down then
        pico.fill_circle(cx, cy, r, BLACK)
    else
        pico.draw_circle(cx, cy, r, BLACK)
    end
    pico.draw_text(cx - 4, cy - 8, label, down and WHITE or BLACK, 0)
end

pico.on(pad, "render", function()
    local ox, oy = x, PAD_Y
    -- 肩のボタン
    key(ox + 4,       oy + 2, 34, 20, "zl", "ZL")
    key(ox + 40,      oy + 2, 26, 20, "l", "L")
    key(ox + w - 66,  oy + 2, 26, 20, "r", "R")
    key(ox + w - 38,  oy + 2, 34, 20, "zr", "ZR")
    -- 十字キー
    local cx, cy, s = ox + 48, oy + 70, 22
    key(cx - s // 2, cy - s - s // 2, s, s, "up", "")
    key(cx - s // 2, cy + s // 2,     s, s, "down", "")
    key(cx - s - s // 2, cy - s // 2, s, s, "left", "")
    key(cx + s // 2, cy - s // 2,     s, s, "right", "")
    -- ABXY(Wiiクラシックの並び: 右A 下B 左Y 上X)
    local bx, by, d = ox + w - 50, oy + 70, 24
    round(bx + d, by, 12, "a", "A")
    round(bx, by + d, 12, "b", "B")
    round(bx - d, by, 12, "y", "Y")
    round(bx, by - d, 12, "x", "X")
    -- 真ん中
    key(ox + 86,  oy + 94, 30, 20, "select", "-")
    key(ox + 105, oy + 66, 30, 20, "home", "H")
    key(ox + 124, oy + 94, 30, 20, "start", "+")
end)

-- ---- 十字キーで動く点 ----
local FIELD_Y = PAD_Y + PAD_H + 6
local FIELD_H = h - (FIELD_Y - y) - 40
local field = pico.create("Canvas")
pico.set(field, "x", x + margin)
pico.set(field, "y", FIELD_Y)
pico.set(field, "w", w - margin * 2)
pico.set(field, "h", FIELD_H)

local R = 6
local dot_x, dot_y = (w - margin * 2) / 2, FIELD_H / 2
local SPEED = 90 -- px/秒

pico.on(field, "render", function()
    local fx, fy = x + margin, FIELD_Y
    pico.draw_rect(fx, fy, w - margin * 2, FIELD_H, GREY)
    local color = BLACK
    if pico.pad_down("a") then color = RED elseif pico.pad_down("b") then color = BLUE end
    pico.fill_circle(fx + math.floor(dot_x), fy + math.floor(dot_y), R, color)
end)

local back = pico.create("Button")
pico.set(back, "x", x + margin)
pico.set(back, "y", y + h - 32)
pico.set(back, "w", 80 + BUTTON_FRAME)
pico.set(back, "h", 26 + BUTTON_FRAME)
pico.set(back, "icon_id", 30)  -- ArrowLeft
pico.on(back, "press_start", function() pico.go_back() end)
-- EscキーとコントローラーのHOMEでも戻る(HOMEは下のキー図にも出る)
pico.on_back(function() pico.pop() end)

-- ---- 毎フレーム ----
local NAMES = { "up", "down", "left", "right", "a", "b", "x", "y",
                "l", "r", "zl", "zr", "start", "select", "home" }
local last_key = nil
local last_connected = nil

function loop(dt)
    local connected = pico.pad_connected()
    if connected ~= last_connected then
        last_connected = connected
        pico.set(status, "text", connected and "コントローラー: 接続中"
                                           or "コントローラー: 未接続")
    end

    -- 押しているものが変わったときだけ図を描き直す
    local k = ""
    for _, n in ipairs(NAMES) do
        if pico.pad_down(n) then k = k .. n .. " " end
    end
    if k ~= last_key then
        last_key = k
        pico.invalidate(pad)
        pico.invalidate(field)
    end

    local vx, vy = 0, 0
    if pico.pad_down("left") then vx = vx - 1 end
    if pico.pad_down("right") then vx = vx + 1 end
    if pico.pad_down("up") then vy = vy - 1 end
    if pico.pad_down("down") then vy = vy + 1 end
    if vx ~= 0 or vy ~= 0 then
        local step = SPEED * dt / 1000
        if vx ~= 0 and vy ~= 0 then step = step * 0.7071 end
        dot_x = math.max(R + 1, math.min(w - margin * 2 - R - 2, dot_x + vx * step))
        dot_y = math.max(R + 1, math.min(FIELD_H - R - 2, dot_y + vy * step))
        pico.invalidate(field)
    end
end
