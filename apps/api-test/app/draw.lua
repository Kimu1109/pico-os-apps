-- 直接描画: Canvasのrenderコールバックで描く描画API・入力APIの確認。
--   pico.draw_ellipse/fill_ellipse/draw_triangle/fill_triangle/draw_polygon/fill_polygon/draw_arc/fill_arc
--   pico.draw_line(…, width) / pico.text_width / pico.draw_image_ex / pico.on_key / pico.battery / pico.millis
-- 「戻る」ボタン以外は全部Canvasのrenderコールバックの中で描く(直接描画の約束)。

local cx0, cy0, cw, ch = pico.content_rect()

local back = pico.create("Button")
pico.set(back, "x", cx0 + 4)
pico.set(back, "y", cy0 + 2)
pico.set(back, "icon_id", 30)  -- ArrowLeft
pico.on(back, "press_end", function() pico.pop() end)

local canvas = pico.create("Canvas")
pico.set(canvas, "x", cx0)
pico.set(canvas, "y", cy0 + 34)
pico.set(canvas, "w", cw)
pico.set(canvas, "h", ch - 34)

local last_key = pico.tr("(キー未入力)")
local angle = 0
local t0 = pico.millis()

pico.on_key(function(key, mods)
    last_key = key .. (mods.ctrl and " +Ctrl" or "") .. (mods.shift and " +Shift" or "")
    pico.invalidate(canvas)
    return true
end)

local img = pico.image_load(pico.path_join(pico.app_dir(), "icon.pimg"))

pico.on(canvas, "render", function()
    local x, y = cx0, cy0 + 34
    -- 太い線と輪郭
    pico.draw_line(x + 8, y + 8, x + 70, y + 30, 0, 1)
    pico.draw_line(x + 8, y + 18, x + 70, y + 40, 12, 4)
    pico.draw_line(x + 8, y + 28, x + 70, y + 50, 9, 8)
    -- 楕円
    pico.fill_ellipse(x + 110, y + 28, 28, 16, 10)
    pico.draw_ellipse(x + 110, y + 28, 36, 22, 0)
    -- 三角形
    pico.fill_triangle(x + 170, y + 50, x + 200, y + 8, x + 228, y + 50, 5)
    pico.draw_triangle(x + 170, y + 50, x + 200, y + 8, x + 228, y + 50, 0, 2)
    -- 多角形(凹んだ星)
    local star = {}
    for i = 0, 9 do
        local r = (i % 2 == 0) and 30 or 13
        local a = -math.pi / 2 + i * math.pi / 5
        star[#star + 1] = math.floor(x + 40 + r * math.cos(a))
        star[#star + 1] = math.floor(y + 110 + r * math.sin(a))
    end
    pico.fill_polygon(star, 11)
    pico.draw_polygon(star, 0, 2)
    -- 円弧と扇形(パイチャート)
    pico.fill_arc(x + 130, y + 110, 30, 0, math.pi * 0.8, 12)
    pico.fill_arc(x + 130, y + 110, 30, math.pi * 0.8, math.pi * 1.5, 9)
    pico.fill_arc(x + 130, y + 110, 30, math.pi * 1.5, math.pi * 2, 10)
    pico.draw_arc(x + 130, y + 110, 36, 0, math.pi * 1.5, 0, 3)
    -- 画像の拡大・回転・反転
    if img then
        local w, h = pico.image_size(img)
        pico.draw_image_ex(img, x + 40, y + 190, 0, 1, 1, w / 2, h / 2)
        pico.draw_image_ex(img, x + 100, y + 190, angle, 1.5, 1.5, w / 2, h / 2)
        pico.draw_image_ex(img, x + 170, y + 190, 0, -1, 1, w / 2, h / 2)
        pico.draw_image_ex(img, x + 215, y + 190, 0, 0.5, 2, w / 2, h / 2)
    end
    -- 文字: 右寄せ
    local label = pico.tr("キー: ") .. last_key
    pico.draw_text(x + cw - pico.text_width(label, 0) - 4, y + 248, label, 0, 0)
    local p, v, usb = pico.battery()
    if p then pico.draw_text(x + 4, y + 232, string.format(pico.tr("電池%d%% %.2fV%s"), p, v, usb and " USB" or ""), 0, 0) end
end)

function loop(dt)
    angle = (pico.millis() - t0) / 1000
    pico.invalidate(canvas)
end
