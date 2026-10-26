-- 通知: pico.notify の確認。
-- 予約した通知はこのアプリを閉じても出る(見張るのはOS)。トーストか通知センターで
-- タップするとこのアプリが開き、main.lua が pico.launch_reason() で「どの通知から開いたか」を受け取って
-- このページへ args で渡す(launch_reason は起動した最初の画面で1回だけ読める)。
-- 通知を使うには app.cfg に permission_notify=true が要る。

local x, y, w, h = pico.content_rect()
local m = 8

local function button(text, bx, by, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", bx)
    pico.set(b, "y", by)
    pico.on(b, "press_end", fn)
    return b
end

local function label(text, lx, ly)
    local l = pico.create("Label")
    pico.set(l, "x", lx)
    pico.set(l, "y", ly)
    pico.set(l, "font_size", 0)
    pico.set(l, "text", text)
    return l
end

pico.set(button("", x + m, y + m, function() pico.pop() end), "icon_id", 30)  -- ArrowLeft
label("通知", x + 70, y + m + 6)

local status = label("", x + m, y + 200)
local reason = label("", x + m, y + 255)

local function refresh(msg)
    pico.set(status, "text", (msg and (msg .. "\n") or "") .. "予約: " .. #pico.notify_list() .. "件")
end

local function result(id, err)
    if id == nil then refresh("失敗: " .. tostring(err)) else refresh("OK (id=" .. id .. ")") end
end

local row = y + 50
button("すぐ通知", x + m, row, function()
    result(pico.notify{ title = "テスト通知", body = "すぐ出した通知です", tag = "now", data = "now" })
end)
button("10秒後", x + 120, row, function()
    result(pico.notify{ title = "10秒経ちました", body = "閉じていても出ます", delay_ms = 10000, tag = "later", data = "later" })
end)
row = row + 45
button("1分ごと", x + m, row, function()
    result(pico.notify{ title = "1分ごとの通知", every_ms = 60000, tag = "every", data = "every", sound = false })
end)
button("取り消し", x + 120, row, function()
    refresh("取り消し: " .. pico.notify_cancel() .. "件")
end)
row = row + 45
button("電池20%未満", x + m, row, function()
    result(pico.notify{ title = "電池が少なくなりました", when = "battery_low", below = 20, tag = "battery" })
end)
-- バックグラウンド(background.lua)が動くたびに通知を出すか。動いた回数は background.lua が settings へ書く
local bg_button
local function bg_text()
    local on = pico.settings_get("bg_notify") == "true"
    return "BG通知:" .. (on and "入" or "切")
end
bg_button = button(bg_text(), x + 120, row, function()
    local on = pico.settings_get("bg_notify") == "true"
    pico.settings_set("bg_notify", on and "false" or "true")
    pico.set(bg_button, "text", bg_text())
end)
local bg_label = label("", x + m, y + 230)
pico.set(bg_label, "text", "バックグラウンド: " .. (pico.settings_get("bg_runs") or "0") .. "回(最後 "
         .. (pico.settings_get("bg_last") or "-") .. ")")

local from = pico.args()
if from and from.tag then
    pico.set(reason, "text", "通知から: " .. from.tag .. " / " .. tostring(from.data))
else
    pico.set(reason, "text", "メニューから開いた")
end
refresh()
