-- 追加の部品: 専用ウィジェットと補助モジュールの確認
--   ・Luaから作れるようになったウィジェット(ProgressBar / AnalogClock / DurationPicker / MonthGrid /
--     MarkdownView / TextView / ImageView)
--   ・pico.ui(宣言的な組み立て)・pico.tab_link(タブごとの表示切り替え)・pico.tween
--   ・ジェスチャー(swipe / long_press / double_tap)・pico.toast・pico.show_date・pico.encrypt
local ui = require("pico.ui")
local tween = require("pico.tween")

local x, y, w, h = pico.content_rect()
local top = y + 32
local panel_h = h - 32 - 36

-- ---- タブ ----
local tabs = pico.create("TabBar")
pico.set(tabs, "x", x)
pico.set(tabs, "y", y)
pico.set(tabs, "w", w)
pico.set(tabs, "h", 26)
for _, name in ipairs({ "表示", "文書", "日付", "暗号" }) do pico.tab_add(tabs, name) end

local function link(index, ...)
    for _, id in ipairs({ ... }) do pico.tab_link(tabs, index, id) end
end

-- ---- タブ0 表示: ProgressBar / AnalogClock / DurationPicker / ImageView ----
local bar_label = ui.Label{ x = x + 8, y = top, font_size = 0, text = "ProgressBar" }
local bar = ui.ProgressBar{ x = x + 8, y = top + 20, w = w - 16, h = 14, max_value = 100, color = 10 }
local clock = ui.AnalogClock{ x = x + 8, y = top + 44, w = 84, h = 84 }
local picker = ui.DurationPicker{ x = x + 100, y = top + 44, w = 132, h = 60, total_ms = 90000, name = "picker", font_size = 0,
    on_duration_changed = function(id, ms) pico.set(bar, "value", math.min(100, ms // 1000)) end }
local pic_label = ui.Label{ x = x + 100, y = top + 108, font_size = 0, text = "ImageView" }
local pic = ui.ImageView{ x = x + 100, y = top + 126, w = 60, h = 40,
    path = pico.path_join(pico.app_dir(), "icon.pimg") }
local fill = ui.Button{ x = x + 8, y = top + 140, font_size = 0, text = "ゲージ", w = 84, h = 28,
    on_press_end = function()
        tween.start{ from = 0, to = 100, duration = 800, ease = "ease_out",
                     on_update = function(v) pico.set(bar, "value", v) end,
                     on_done = function() pico.toast("おわり") end }
    end }
link(0, bar_label, bar, clock, picker, pic_label, pic, fill)

-- 時計は1秒ごとに現在時刻を流し込む
pico.every(1000, function()
    local t = pico.get_time()
    pico.set(clock, "hour", t.hour)
    pico.set(clock, "minute", t.min)
    pico.set(clock, "second", t.sec)
end)

-- ---- タブ1 文書: MarkdownView ----
local md = ui.MarkdownView{ x = x + 4, y = top, w = w - 8, h = panel_h,
    on_link_tap = function(id, path) pico.toast("リンク: " .. path) end }
pico.text_set(md, [[
# MarkdownView

Luaから作れるようになった。

- **太字**や*斜体*
- 長い文書も渡せる
- [リンク](docs/a.md)

## TextView

見えている行だけを描く軽い表示欄も作れる。
]])
link(1, md)

-- ---- タブ2 日付: MonthGrid ----
local today = pico.get_time()
local year, month = today.year, today.month
local month_label = ui.Label{ x = x + 8, y = top, font_size = 0, text = "" }
local grid = ui.MonthGrid{ x = x + 8, y = top + 28, w = w - 16, h = 136, today = today.day, selected = today.day,
    on_day_selected = function(id, day) pico.set(month_label, "text", string.format("%d年%d月%d日", year, month, day)) end }
local function show_month()
    pico.set(grid, "year", year)
    pico.set(grid, "month", month)
    pico.set(grid, "today", (year == today.year and month == today.month) and today.day or 0)
    pico.set_dots(grid, { [3] = { 12 }, [10] = { 9, 10 }, [20] = { 12, 9, 10 } })
    pico.set(month_label, "text", string.format("%d年%d月", year, month))
end
local function shift(d)
    month = month + d
    if month < 1 then month = 12; year = year - 1 elseif month > 12 then month = 1; year = year + 1 end
    show_month()
end
pico.on(grid, "swipe", function(id, dir) if dir == "left" then shift(1) elseif dir == "right" then shift(-1) end end)
pico.on(grid, "long_press", function() pico.toast("長押し") end)
pico.on(grid, "double_tap", function() year, month = today.year, today.month; show_month() end)
local pick_date = ui.Button{ x = x + 8, y = top + 172, w = 150, h = 28, font_size = 0, text = "日付ダイアログ",
    on_press_end = function()
        local d = pico.show_date("日付を選ぶ", year, month, 1)
        pico.on(d, "closed", function(_, ok, v) if ok then pico.toast(v) end end)
    end }
show_month()
link(2, month_label, grid, pick_date)
local hint = ui.Label{ x = x + 8, y = top + 204, font_size = 0, max_width = w - 16, text = "左右にスワイプで月を送る\nダブルタップで今月" }
link(2, hint)

-- ---- タブ3 暗号: encrypt / decrypt ----
local input = ui.Textbox{ x = x + 8, y = top, max_width = w - 16, placeholder = "ここに文字を入れる" }
local out = ui.TextView{ x = x + 8, y = top + 80, w = w - 16, h = 110 }
local PASSWORD = "demo-password"
local last_cipher = nil
local enc_btn = ui.Button{ x = x + 8, y = top + 38, w = 100, h = 28, font_size = 0, text = "暗号化",
    on_press_end = function()
        local text = pico.get(input, "text") or ""
        local c, why = pico.encrypt(text, PASSWORD)
        if not c then pico.toast(tostring(why)) return end
        last_cipher = c
        pico.text_set(out, c)
    end }
local dec_btn = ui.Button{ x = x + 124, y = top + 38, w = 100, h = 28, font_size = 0, text = "復号",
    on_press_end = function()
        if not last_cipher then pico.toast("先に暗号化") return end
        local p, why = pico.decrypt(last_cipher, PASSWORD)
        pico.text_set(out, p and ("復号: " .. p) or ("失敗: " .. tostring(why)))
    end }
local bad_btn = ui.Button{ x = x + 8, y = top + 196, w = 150, h = 28, font_size = 0, text = "違うパスワード",
    on_press_end = function()
        if not last_cipher then pico.toast("先に暗号化") return end
        local p, why = pico.decrypt(last_cipher, "wrong")
        pico.text_set(out, p and ("復号: " .. p) or ("失敗: " .. tostring(why)))
    end }
link(3, input, out, enc_btn, dec_btn, bad_btn)

-- ---- 戻る ----
local back = ui.Button{ x = x + 8, y = y + h - 30, w = 80, h = 26, font_size = 0, icon_id = 30,
    on_press_end = function() pico.go_back() end }
pico.on_back(function() pico.pop() end)

pico.tab_link(tabs, 0, bar) -- 同じ連動を重ねても1つ
