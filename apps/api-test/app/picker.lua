-- push_scene の子の画面: pico.args() で親から値を受け取り、pico.pop(result) で結果を返す
local args = pico.args() or {}
local x, y, w, h = pico.content_rect()

local title = pico.create("Label")
pico.set(title, "x", x + 10)
pico.set(title, "y", y + 10)
pico.set(title, "text", args.title or "選んでください")

local colors = { "red", "green", "blue" }
for i, name in ipairs(colors) do
    local b = pico.create("Button")
    pico.set(b, "x", x + 10)
    pico.set(b, "y", y + 40 + (i - 1) * 40)
    pico.set(b, "w", 120)
    pico.set(b, "h", 34)
    pico.set(b, "text", name)
    pico.on(b, "press_end", function()
        pico.pop({ color = name, index = i })   -- 親の on_result に届く
    end)
end

local cancel = pico.create("Button")
pico.set(cancel, "x", x + 10)
pico.set(cancel, "y", y + 170)
pico.set(cancel, "w", 120)
pico.set(cancel, "h", 34)
pico.set(cancel, "text", "やめる")
pico.on(cancel, "press_end", function() pico.pop() end)   -- 結果なし: 親の on_result は呼ばれない
