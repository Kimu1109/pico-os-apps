-- QRコード: よく見せるQR(サイト・SNSのアカウント・連絡先・Wi-Fi・メモ)を保存しておき、一覧から選んで大きく出す。
--
--   一覧      [戻る][追加] + 保存したQRの一覧(種類ごとのアイコン)。タップで表示
--   表示      [一覧][←][→][編集][削除] + 名前 + QR + 中身の要約
--
-- QRの部品は pico.create("QRCode")。中身は pico.text_set で渡し、入らない(255バイト超)ときは保存しない。
-- 入力は pico.async でダイアログを順に出す。保存は store.json(連絡先などを含むので端末の鍵で暗号化)。
-- ※LuaSceneが読む main.lua は16KiBまで。
local async = require("pico.async")

local X, Y, W, H = pico.content_rect()
local GAP = 4
local ROW_H = 30
local MAX_ITEMS = 50

-- 種類: 一覧の文字・アイコンと、入力の項目
local KINDS = {
    { id = "url",     label = "URL・サイト", icon = pico.ICON_Link },
    { id = "contact", label = "連絡先",     icon = pico.ICON_User },
    { id = "wifi",    label = "Wi-Fi",      icon = pico.ICON_WifiSignal4 },
    { id = "text",    label = "テキスト",   icon = pico.ICON_File },
}
local KIND_BY_ID = {}
for _, k in ipairs(KINDS) do KIND_BY_ID[k.id] = k end

local items = {}     -- { kind=, name=, f={...} }
local current = 0    -- 表示中の番号(0は一覧)
local busy = false   -- 入力の途中(ボタンの二度押しを防ぐ)

-- ---- 中身(QRにする文字) ----

-- vCard の値: \ , ; と改行を逃がす
local function vesc(s)
    return (s:gsub("[\\,;]", "\\%0"):gsub("\r?\n", "\\n"))
end
-- Wi-Fi の値: \ ; , : " を逃がす
local function wesc(s)
    return (s:gsub('[\\;,:"]', "\\%0"))
end

local function payload(e)
    local f = e.f
    if e.kind == "contact" then
        local t = { "BEGIN:VCARD", "VERSION:3.0", "N:" .. vesc(e.name) .. ";;;;", "FN:" .. vesc(e.name) }
        if f.tel ~= "" then t[#t + 1] = "TEL:" .. vesc(f.tel) end
        if f.email ~= "" then t[#t + 1] = "EMAIL:" .. vesc(f.email) end
        if f.url ~= "" then t[#t + 1] = "URL:" .. vesc(f.url) end
        t[#t + 1] = "END:VCARD"
        return table.concat(t, "\n")
    elseif e.kind == "wifi" then
        if f.pass == "" then return "WIFI:T:nopass;S:" .. wesc(f.ssid) .. ";;" end
        return "WIFI:T:WPA;S:" .. wesc(f.ssid) .. ";P:" .. wesc(f.pass) .. ";;"
    elseif e.kind == "url" then
        return f.url
    end
    return f.text
end

-- 表示の下に出す要約(1行)
local function summary(e)
    local f = e.f
    if e.kind == "contact" then
        local t = {}
        for _, v in ipairs({ f.tel, f.email, f.url }) do if v ~= "" then t[#t + 1] = v end end
        return table.concat(t, " / ")
    elseif e.kind == "wifi" then
        return "SSID: " .. f.ssid
    elseif e.kind == "url" then
        return f.url
    end
    return (f.text:gsub("\n.*", " …"))
end

-- ---- 保存 ----

local function save()
    if not pico.store_save({ items = items }, { encrypt = true }) then
        pico.show_message("保存できませんでした(SDを確認してください)", "", "OK")
    end
end

local function load()
    local s = pico.store_load()
    if type(s) ~= "table" or type(s.items) ~= "table" then return end
    for _, e in ipairs(s.items) do
        if type(e) == "table" and KIND_BY_ID[e.kind] and type(e.name) == "string" and type(e.f) == "table" then
            items[#items + 1] = e
        end
    end
end

-- ---- 部品 ----

local function button(text, x, w, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", x)
    pico.set(b, "y", Y)
    pico.set(b, "w", w)
    pico.set(b, "h", ROW_H)
    pico.set(b, "font_size", pico.FONT_SMALL)
    pico.on(b, "press_end", fn)
    return b
end

local list_view, show_view = {}, {}
local list, empty_label, count_label
local title_label, qr, detail_label

local function set_view(ids, on)
    for _, id in ipairs(ids) do pico.set(id, "visible", on) end
end

local function refresh_list()
    pico.list_clear(list)
    for _, e in ipairs(items) do
        pico.list_add(list, e.name, { icon = KIND_BY_ID[e.kind].icon })
    end
    pico.set(count_label, "text", #items .. "件")
    pico.set(empty_label, "visible", current == 0 and #items == 0)
end

local function show_list()
    current = 0
    set_view(show_view, false)
    set_view(list_view, true)
    refresh_list()
end

local function show_item(i)
    current = i
    local e = items[i]
    set_view(list_view, false)
    pico.set(empty_label, "visible", false)
    set_view(show_view, true)
    pico.set(title_label, "text", e.name)
    pico.text_set(qr, payload(e))
    pico.set(detail_label, "text", summary(e))
end

-- ---- 入力(追加・編集) ----

-- 種類ごとの入力。e は編集なら元の項目、追加なら nil。キャンセルされたら nil を返す
local function ask(kind, e)
    local f = e and e.f or {}
    local name = async.input(kind == "contact" and "名前" or "名前(一覧に出す)", e and e.name or "")
    if not name or name == "" then return nil end
    local nf = {}
    if kind == "url" then
        nf.url = async.input("URL(サイト・SNSのアカウントのページなど)", f.url or "https://")
        if not nf.url or nf.url == "" then return nil end
    elseif kind == "contact" then
        nf.tel = async.input("電話番号(無ければ空)", f.tel or "")
        if not nf.tel then return nil end
        nf.email = async.input("メールアドレス(無ければ空)", f.email or "")
        if not nf.email then return nil end
        nf.url = async.input("URL(無ければ空)", f.url or "")
        if not nf.url then return nil end
    elseif kind == "wifi" then
        nf.ssid = async.input("Wi-Fiの名前(SSID)", f.ssid or "")
        if not nf.ssid or nf.ssid == "" then return nil end
        nf.pass = async.input("パスワード(無ければ空)", f.pass or "")
        if not nf.pass then return nil end
    else
        nf.text = async.input("QRにする文字", f.text or "", false)
        if not nf.text or nf.text == "" then return nil end
    end
    return { kind = kind, name = name, f = nf }
end

-- QRに入るか(255バイトまで)。入らなければ知らせて false
local function fits(e)
    local s = payload(e)
    if #s <= 255 then return true end
    async.message(string.format("長すぎてQRに入りません(%dバイト。255バイトまで)", #s), "", "OK")
    return false
end

local function add()
    if busy then return end
    if #items >= MAX_ITEMS then
        pico.show_message("保存できるのは" .. MAX_ITEMS .. "件までです", "", "OK")
        return
    end
    busy = true
    async.run(function()
        local names = {}
        for i, k in ipairs(KINDS) do names[i] = k.label end
        local k = async.choice("何のQRを作りますか", names)
        local e = k and ask(KINDS[k + 1].id)
        if e and fits(e) then
            items[#items + 1] = e
            save()
            show_item(#items)
        end
        busy = false
    end)
end

local function edit()
    if busy or current == 0 then return end
    busy = true
    async.run(function()
        local i = current
        local e = ask(items[i].kind, items[i])
        if e and fits(e) then
            items[i] = e
            save()
            show_item(i)
        end
        busy = false
    end)
end

local function remove()
    if busy or current == 0 then return end
    busy = true
    async.run(function()
        local i = current
        if async.message("「" .. items[i].name .. "」を消しますか?", "キャンセル", "消す") then
            table.remove(items, i)
            save()
            show_list()
        end
        busy = false
    end)
end

local function step(d)
    if current == 0 or #items == 0 then return end
    show_item((current - 1 + d) % #items + 1)
end

-- ---- 画面 ----

-- 一覧
local bw = (W - GAP) // 3
list_view[#list_view + 1] = button("戻る", X, bw, function() pico.pop() end)
list_view[#list_view + 1] = button("追加", X + bw + GAP, bw, add)
count_label = pico.create("Label")
pico.set(count_label, "x", X + (bw + GAP) * 2 + GAP)
pico.set(count_label, "y", Y + 6)
pico.set(count_label, "font_size", pico.FONT_SMALL)
list_view[#list_view + 1] = count_label

list = pico.create("ScrollList")
pico.set(list, "x", X)
pico.set(list, "y", Y + ROW_H + GAP)
pico.set(list, "w", W)
pico.set(list, "h", H - ROW_H - GAP)
pico.set(list, "enable_icon", true)
pico.on(list, "select_item", function(id)
    local i = pico.get(id, "selected_index")
    if i >= 0 and items[i + 1] then show_item(i + 1) end
end)
list_view[#list_view + 1] = list

empty_label = pico.create("Label")
pico.set(empty_label, "x", X + 8)
pico.set(empty_label, "y", Y + ROW_H + GAP + 8)
pico.set(empty_label, "font_size", pico.FONT_SMALL)
pico.set(empty_label, "max_width", W - 16)
pico.set(empty_label, "text", "[追加]で、URL・連絡先・Wi-FiなどのQRを保存できます")
pico.set(empty_label, "hit_transparent", true)

-- 表示
local sw = (W - GAP * 4) // 5
local sx = X
-- 前/次は矢印のアイコン(◀▶はフォントに無い)
for _, b in ipairs({ { "一覧", show_list }, { pico.ICON_ArrowLeft, function() step(-1) end },
                     { pico.ICON_ArrowRight, function() step(1) end }, { "編集", edit }, { "削除", remove } }) do
    local id = button(type(b[1]) == "string" and b[1] or "", sx, sw, b[2])
    if type(b[1]) == "number" then pico.set(id, "icon_id", b[1]) end
    show_view[#show_view + 1] = id
    sx = sx + sw + GAP
end

local title_y = Y + ROW_H + GAP
title_label = pico.create("Label")
pico.set(title_label, "x", X + 4)
pico.set(title_label, "y", title_y)
pico.set(title_label, "max_width", W - 8)
pico.set(title_label, "max_height", 26)
show_view[#show_view + 1] = title_label

local detail_h = 20
local qr_top = title_y + 28
local side = math.min(W, Y + H - qr_top - detail_h)
qr = pico.create("QRCode")
pico.set(qr, "x", X + (W - side) // 2)
pico.set(qr, "y", qr_top)
pico.set(qr, "w", side)
pico.set(qr, "h", side)
show_view[#show_view + 1] = qr

detail_label = pico.create("Label")
pico.set(detail_label, "x", X + 4)
pico.set(detail_label, "y", qr_top + side)
pico.set(detail_label, "font_size", pico.FONT_SMALL)
pico.set(detail_label, "max_width", W - 8)
pico.set(detail_label, "max_height", detail_h)
show_view[#show_view + 1] = detail_label

load()
show_list()
