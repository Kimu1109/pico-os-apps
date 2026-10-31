-- ニュース: Google ニュースのRSS(APIキー不要)で見出しを読む。
-- RSSは100件ほどで数十〜百KBあるので、pico.http_request の save_to でSDの news.xml へ保存し、
-- pico.sd_xml_pick で必要な値(題名・日時・媒体名)だけをLuaへ取り出す。
-- 一覧は上下のドラッグ(キーボードの↑↓・コントローラーの十字)でスクロールし、タップ(Enter/A)で詳細。
-- 最後に見た分野・検索語は store.json に覚え、news.xml が残っていれば起動時にすぐ見せる。
-- ※LuaSceneが読む main.lua は16KiBまで。
local X, Y, W, H = pico.content_rect()

-- 向き先は settings.cfg の base= で差し替えられる(偽物のサーバで試すとき)
local BASE = pico.settings_get("base", "https://news.google.com")
local TAIL = "hl=ja&gl=JP&ceid=JP:ja"
local TOPICS = {
    { pico.tr("ヘッドライン"), "/rss?" .. TAIL },
    { pico.tr("国内"), "NATION" }, { pico.tr("国際"), "WORLD" }, { pico.tr("ビジネス"), "BUSINESS" },
    { pico.tr("テクノロジー"), "TECHNOLOGY" }, { pico.tr("エンタメ"), "ENTERTAINMENT" },
    { pico.tr("スポーツ"), "SPORTS" }, { pico.tr("科学"), "SCIENCE" }, { pico.tr("健康"), "HEALTH" },
}
local MAXN = 30                    -- 読み込む件数
local FILE = pico.app_dir() .. "/news.xml"
local ROW, STAT = 56, 22           -- 1件の高さ / 上の状態の行
local GREY, DGREY, LGREY, BLUE, RED = 8, 8, 7, 9, 12

local store = pico.store_load() or {}
local mode = store.mode or "topic"            -- "topic" か "search"
local topic = tonumber(store.topic) or 1
local query = store.query or ""

local items = {}                   -- { title=, src=, time= }
local status = ""
local req = nil
local scroll, sel = 0, 1
local canvas

local MON = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }

local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = y // 400
    local yoe = y - era * 400
    local doy = (153 * (m + (m > 2 and -3 or 9)) + 2) // 5 + d - 1
    return era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
end

local function civil_from_days(z)
    z = z + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    return mp + (mp < 10 and 3 or -9), d
end

-- "Tue, 14 Oct 2026 03:00:00 GMT" → 日本時間の "10/14 12:00"
local function jst(pub)
    local d, mon, y, h, mi = (pub or ""):match("(%d+) (%a+) (%d+) (%d+):(%d+)")
    if not d or not MON[mon] then return "" end
    local mins = tonumber(h) * 60 + tonumber(mi) + 540
    local day = days_from_civil(tonumber(y), MON[mon], tonumber(d)) + mins // 1440
    mins = mins % 1440
    local m, dd = civil_from_days(day)
    return string.format("%d/%d %02d:%02d", m, dd, mins // 60, mins % 60)
end

-- 題名の終わりの " - 媒体名" は媒体名を別に出すので落とす
local function clean(title, src)
    if src and src ~= "" then
        local tail = " - " .. src
        if #title > #tail and title:sub(-#tail) == tail then return title:sub(1, #title - #tail) end
    end
    return title
end

local function read_items()
    local out, err = {}, nil
    for a = 1, MAXN, 10 do
        local paths = {}
        for i = a, a + 9 do
            local p = "rss.channel.item." .. i
            paths[#paths + 1] = p .. ".title"
            paths[#paths + 1] = p .. ".pubDate"
            paths[#paths + 1] = p .. ".source"
        end
        local r, e = pico.sd_xml_pick(FILE, paths)
        if not r then err = e break end
        local got = false
        for i = a, a + 9 do
            local p = "rss.channel.item." .. i
            local t = r[p .. ".title"]
            if t then
                got = true
                local src = r[p .. ".source"] or ""
                out[#out + 1] = { title = clean(t, src), src = src, time = jst(r[p .. ".pubDate"]) }
            end
        end
        if not got then break end
    end
    return out, err
end

local function name_now()
    if mode == "search" then return pico.tr("検索: ") .. query end
    return TOPICS[topic][1]
end

local function url_now()
    if mode == "search" then
        return BASE .. "/rss/search?q=" .. pico.url_encode(query) .. "&" .. TAIL
    end
    local t = TOPICS[topic][2]
    if t:sub(1, 1) == "/" then return BASE .. t end
    return BASE .. "/rss/headlines/section/topic/" .. t .. "?" .. TAIL
end

-- ---- 描画 ----
local function max_scroll()
    return math.max(0, #items * ROW - (H - 32 - STAT))
end

local function render()
    local top = Y + 32 + STAT
    local lo, hi = top, Y + H        -- 一覧を描いてよい縦の範囲(ボタンの帯へはみ出さない)
    -- 範囲 [y, y+h) を lo..hi に収めて set_draw_area する(収まらなければ false)
    local function area(x, y, w, h)
        local y0, y1 = math.max(y, lo), math.min(y + h, hi)
        if y1 <= y0 then return false end
        pico.set_draw_area(x, y0, w, y1 - y0)
        return true
    end
    for i = 1, #items do
        local ry = top + (i - 1) * ROW - scroll
        if ry + ROW > lo and ry < hi then
            local it = items[i]
            if i == sel and area(X, ry, W, ROW - 1) then
                pico.fill_rect(X, ry, W, ROW - 1, LGREY)
                pico.clear_draw_area()
            end
            if ry + ROW - 1 >= lo and ry + ROW - 1 < hi then
                pico.draw_line(X + 4, ry + ROW - 1, X + W - 5, ry + ROW - 1, LGREY)
            end
            if area(X + 6, ry + 2, W - 14, 34) then
                pico.draw_text_wrapped(X + 6, ry + 2, W - 14, it.title, 0, 0)
                pico.clear_draw_area()
            end
            local meta = (it.src ~= "" and it.src or "") .. (it.time ~= "" and ("  " .. it.time) or "")
            if area(X + 6, ry + 37, W - 14, 18) then
                pico.draw_text(X + 6, ry + 37, meta, BLUE, 0)
                pico.clear_draw_area()
            end
        end
    end
    -- 上の状態の行(はみ出した行を隠してから描く)
    pico.fill_rect(X, Y + 32, W, STAT, 15)
    pico.draw_text(X + 6, Y + 34, status ~= "" and status or name_now(), (status:find(pico.tr("失敗")) and RED) or DGREY, 0)
    -- スクロールの印
    local ms = max_scroll()
    if ms > 0 then
        local lh = H - 32 - STAT
        local bh = math.max(12, lh * lh // (#items * ROW))
        pico.fill_rect(X + W - 3, top + (lh - bh) * scroll // ms, 3, bh, GREY)
    end
end

local function redraw() pico.invalidate(canvas) end

local function set_scroll(v)
    v = math.max(0, math.min(max_scroll(), v))
    if v ~= scroll then scroll = v redraw() end
end

local function select_row(i)
    if #items == 0 then return end
    sel = math.max(1, math.min(#items, i))
    local top, lh = (sel - 1) * ROW, H - 32 - STAT
    if top < scroll then scroll = top elseif top + ROW > scroll + lh then scroll = top + ROW - lh end
    scroll = math.max(0, math.min(max_scroll(), scroll))
    redraw()
end

local function show_detail(i)
    local it = items[i]
    if not it then return end
    sel = i
    redraw()
    local meta = (it.src ~= "" and it.src or "") .. (it.time ~= "" and ("  " .. it.time) or "")
    pico.show_message(it.title .. "\n\n" .. meta, "", pico.tr("閉じる"))
end

-- ---- 通信 ----
local function show_file(note)
    local list, err = read_items()
    if #list == 0 then
        items = {}
        status = pico.tr("取得に失敗しました: ") .. (err or pico.tr("記事が見つかりません"))
    else
        items, sel, scroll = list, 1, 0
        status = ""
        if note then status = note end
    end
    redraw()
end

local function load_news()
    if req then pico.http_cancel(req) end
    status = pico.tr("取得中…")
    redraw()
    local my = name_now()
    req = pico.http_request("GET", url_now(), nil, nil, function(ok, code)
        req = nil
        if my ~= name_now() then return end
        if not ok then
            status = pico.tr("取得に失敗しました")
            redraw()
        elseif code ~= 200 then
            status = pico.tr("取得に失敗しました(HTTP %s)", tostring(code))
            redraw()
        else
            show_file()
        end
    end, { keep_alive = true, save_to = FILE })
    if not req then
        status = pico.tr("取得に失敗しました: 通信できません")
        redraw()
    end
end

local function remember()
    store.mode, store.topic, store.query = mode, topic, query
    pico.store_save(store)
end

local function pick_topic()
    local names = {}
    for i, t in ipairs(TOPICS) do names[i] = t[1] end
    local dlg = pico.show_choice(pico.tr("分野を選ぶ"), names)
    pico.on(dlg, "closed", function(_, ok, idx)
        if ok and TOPICS[idx + 1] then
            mode, topic = "topic", idx + 1
            remember()
            items = {}
            load_news()
        end
    end)
end

local function search()
    local dlg = pico.show_input(pico.tr("キーワード"), query, true, pico.tr("検索"), pico.tr("キャンセル"))
    pico.on(dlg, "closed", function(id, ok)
        local q = ok and pico.get(id, "text") or ""
        if q ~= "" then
            mode, query = "search", q
            remember()
            items = {}
            load_news()
        end
    end)
end

local function back()
    if req then pico.http_cancel(req) end
    pico.http_close()
    pico.pop()
end

-- ---- 部品 ----
local function button(text, x, w, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", x)
    pico.set(b, "y", Y)
    pico.set(b, "w", w)
    pico.set(b, "h", 30)
    pico.on(b, "press_end", fn)
    return b
end

local bw = (W - 6) // 4
button(pico.tr("戻る"), X, bw, back)
button(pico.tr("分野"), X + bw + 2, bw, pick_topic)
button(pico.tr("検索"), X + (bw + 2) * 2, bw, search)
button(pico.tr("更新"), X + (bw + 2) * 3, bw, load_news)

canvas = pico.create("Canvas")
pico.set(canvas, "x", X)
pico.set(canvas, "y", Y + 32)
pico.set(canvas, "w", W)
pico.set(canvas, "h", H - 32)
pico.on(canvas, "render", render)

-- ドラッグでスクロール、ほとんど動かさずに離したらタップ
local moved = 0
pico.on(canvas, "press_start", function() moved = 0 end)
pico.on(canvas, "press_move", function(_, _, _, _, _, _, dy)
    moved = moved + math.abs(dy)
    set_scroll(scroll - dy)
end)
pico.on(canvas, "press_end", function(_, _, _, _, ly)
    if moved < 8 and ly >= STAT then show_detail((ly - STAT + scroll) // ROW + 1) end
end)

pico.on_key(function(key)
    if key == "up" then select_row(sel - 1) return true end
    if key == "down" then select_row(sel + 1) return true end
    if key == "pageup" then select_row(sel - 4) return true end
    if key == "pagedown" then select_row(sel + 4) return true end
    if key == "enter" then show_detail(sel) return true end
    return false
end)

function loop()
    if pico.pad_pressed("up") then select_row(sel - 1) end
    if pico.pad_pressed("down") then select_row(sel + 1) end
    if pico.pad_pressed("a") then show_detail(sel) end
    if pico.pad_pressed("x") then pick_topic() end
    if pico.pad_pressed("y") then search() end
    if pico.pad_pressed("start") then load_news() end
    if pico.pad_pressed("b") then back() end
end

pico.on_back(back)

-- 前回の news.xml があればすぐ見せて、そのまま更新する
if pico.sd_exists(FILE) then show_file(pico.tr("保存済みの記事")) end
load_news()
