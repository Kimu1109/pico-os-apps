-- 基本の部品: pico.create で作る汎用部品と、その固有イベントの確認。
--   「入力」タブ … Textbox(text_changed) / NumberInput / Checkbox(checked_changed) /
--                  DropdownMenu(list_add + dropdown_changed) / LayoutContainer(add_child / remove_child) / pico.beep
--   「図形」タブ … 図形ウィジェット(Rect / Ellipse / Line / Triangle)。Canvasと違い、置けば値が変わるまで残る
-- タブごとの表示の切り替えは pico.tab_link に任せる。

local x, y, w, h = pico.content_rect()
local m = 8
local top = y + 32

local function label(text, lx, ly)
    local l = pico.create("Label")
    pico.set(l, "x", lx)
    pico.set(l, "y", ly)
    pico.set(l, "font_size", 0)
    pico.set(l, "text", text)
    return l
end

local function button(text, bx, by, bw, fn)
    local b = pico.create("Button")
    pico.set(b, "font_size", 0)
    pico.set(b, "text", text)
    pico.set(b, "x", bx)
    pico.set(b, "y", by)
    pico.set(b, "w", bw)
    pico.set(b, "h", 30)
    pico.on(b, "press_end", fn)
    return b
end

local tabs = pico.create("TabBar")
pico.set(tabs, "x", x)
pico.set(tabs, "y", y)
pico.set(tabs, "w", w)
pico.set(tabs, "h", 26)
pico.tab_add(tabs, pico.tr("入力"))
pico.tab_add(tabs, pico.tr("図形"))

local function link(index, ...)
    for _, id in ipairs({ ... }) do pico.tab_link(tabs, index, id) end
end

-- ---- 入力 ----
local textbox = pico.create("Textbox")
pico.set(textbox, "x", x + m)
pico.set(textbox, "y", top)
pico.set(textbox, "max_width", w - m * 2)
pico.set(textbox, "max_height", 26)
pico.set(textbox, "is_single_line", true)
pico.set(textbox, "placeholder", pico.tr("タップして入力"))
local text_label = label(pico.tr("text: (未入力)"), x + m, top + 30)
pico.on(textbox, "text_changed", function(id)
    pico.set(text_label, "text", "text: " .. pico.get(id, "text"))
end)

local number = pico.create("NumberInput")
pico.set(number, "x", x + m)
pico.set(number, "y", top + 54)
local number_label = label(pico.tr("数: "), x + m + 72, top + 58)

local checkbox = pico.create("Checkbox")
pico.set(checkbox, "x", x + m)
pico.set(checkbox, "y", top + 126)
pico.set(checkbox, "text", pico.tr("チェック"))
local check_label = label("checked: false", x + 130, top + 130)
pico.on(checkbox, "checked_changed", function(id)
    pico.set(check_label, "text", "checked: " .. tostring(pico.get(id, "checked")))
end)

-- コンテナへの出し入れ: 子を作って足し、もう一度押すと破棄せず外してから消す
local container = pico.create("LayoutContainer")
pico.set(container, "x", x + m)
pico.set(container, "y", top + 158)
pico.set(container, "w", w - m * 2)
pico.set(container, "h", 24)
local child = nil
local toggle
toggle = button(pico.tr("子を追加"), x + m, top + 186, 110, function()
    if child == nil then
        child = pico.create("Label")
        pico.set(child, "text", pico.tr("追加された子"))
        pico.add_child(container, child)
        pico.set(toggle, "text", pico.tr("子を外す"))
    else
        pico.remove_child(container, child)
        pico.destroy(child)
        child = nil
        pico.set(toggle, "text", pico.tr("子を追加"))
    end
end)
local beep = button(pico.tr("テスト音"), x + 130, top + 186, 100, function() pico.beep(880, 300) end)

-- ---- 図形 ----
local shapes = {}
local function shape(kind, props)
    local s = pico.create(kind)
    for k, v in pairs(props) do pico.set(s, k, v) end
    shapes[#shapes + 1] = s
    return s
end
shape("Rect",    { x = x + m,       y = top + 8, w = 50, h = 34, color = 9 })
shape("Rect",    { x = x + m + 60,  y = top + 8, w = 50, h = 34, color = 12, filled = false, thickness = 3 })
shape("Ellipse", { x = x + m + 120, y = top + 8, w = 34, h = 34, color = 10 })
shape("Ellipse", { x = x + m + 164, y = top + 10, w = 46, h = 30, color = 5, filled = false })
local line = shape("Line", { x1 = x + m, y1 = top + 60, x2 = x + m + 60, y2 = top + 90, color = 0, thickness = 3 })
local tri = shape("Triangle", { x1 = x + m + 80, y1 = top + 90, x2 = x + m + 100, y2 = top + 60,
                                x3 = x + m + 120, y3 = top + 90, color = 14 })
shape("Triangle", { x1 = x + m + 140, y1 = top + 90, x2 = x + m + 160, y2 = top + 60,
                    x3 = x + m + 180, y3 = top + 90, color = 8, filled = false, thickness = 2 })
-- x/y は形全体の平行移動
local moved = false
local move = button(pico.tr("x/yで平行移動"), x + m, top + 120, 140, function()
    local dy = moved and -20 or 20
    pico.set(line, "y", pico.get(line, "y") + dy)
    pico.set(tri, "y", pico.get(tri, "y") + dy)
    moved = not moved
end)

-- ---- 戻る ----
local back = button("", x + m, y + h - 34, 80, function() pico.pop() end)
pico.set(back, "icon_id", 30)  -- ArrowLeft

-- 開いた一覧が下の部品に重なるので、ドロップダウンは最後に作る(後に作ったものが上に描かれる)
local dropdown = pico.create("DropdownMenu")
pico.set(dropdown, "x", x + m)
pico.set(dropdown, "y", top + 86)
pico.set(dropdown, "w", 120)
pico.list_add(dropdown, pico.tr("りんご"))
pico.list_add(dropdown, pico.tr("みかん"))
pico.list_add(dropdown, pico.tr("ぶどう"))
local dropdown_label = label(pico.tr("未選択"), x + 140, top + 94)
pico.on(dropdown, "dropdown_changed", function(id)
    pico.set(dropdown_label, "text", pico.tr("選択: ") .. pico.get(id, "selected_index"))
end)

link(0, textbox, text_label, number, number_label, checkbox, check_label, container, toggle, beep,
     dropdown, dropdown_label)
link(1, move, table.unpack(shapes))

-- NumberInput は変化のイベントを持たないので、毎フレーム読んで変わったら出す
local last_num = nil
function loop()
    local n = pico.get(number, "text")
    if n ~= last_num then
        last_num = n
        pico.set(number_label, "text", pico.tr("数: ") .. n)
    end
end
