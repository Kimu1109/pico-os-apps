-- 実機チェック: 実機の速さとメモリを測るアプリ(docs/HARDWARE_CHECKLIST.md の 5・7章)。
-- 「全部」で上から順に測り、結果を画面とログ([HWCHK] の行)と results.txt(追記)へ出す。
--
--   Lua     … 整数/小数の計算・表への追加・文字列の連結・ごみ集め
--   描画    … Canvasのrenderの中で図形・文字・画像を描く時間(合成の中だけ。液晶への転送は含まない)
--   転送    … Canvas全体を毎フレーム描き直したときのフレーム時間(液晶への転送込み。SPIの速さが効く)
--   SD      … 16KiBの書き込み・読み込み・追記・設定ファイル
--   暗号    … pico.encrypt(固定鍵 / パスワード付き=Argon2id)・pico.hash
--   JSON    … 200件の表の encode / decode
--   HTTPS   … settings.cfg の tls_url(既定 https://www.google.com/generate_204)へ GET。
--             かかった時間と、その間に一番長く止まったフレーム(TLSのハンドシェイクは同期)
--   メモリ  … pico.memory_info()
--
-- 時間はすべて pico.micros() の差。1つの測定は1フレームの中で終わる量にしてある
-- (1回の呼び出しの命令数の上限と、ウォッチドッグに当たらないように)。

local X, Y, W, H = pico.content_rect()
local DIR = pico.app_dir()
local RESULT_FILE = pico.path_join(DIR, "results.txt")
local TMP_FILE = pico.path_join(DIR, "bench.tmp")
local TLS_URL = pico.settings_get("tls_url", "https://www.google.com/generate_204")

local BTN_H = 28
local BODY_Y = Y + BTN_H + 24
local BODY_H = H - BTN_H - 24

-- ---- 画面 ----
local function button(text, bx, bw, fn)
    local b = pico.create("Button")
    pico.set(b, "text", text)
    pico.set(b, "x", bx)
    pico.set(b, "y", Y)
    pico.set(b, "w", bw)
    pico.set(b, "h", BTN_H)
    pico.on(b, "press_end", fn)
    return b
end

local status = pico.create("Label")
pico.set(status, "x", X + 4)
pico.set(status, "y", Y + BTN_H + 2)
pico.set(status, "font_size", 0)
pico.set(status, "text", pico.tr("「全部」で測り始めます"))

local view = pico.create("TextView")
pico.set(view, "x", X)
pico.set(view, "y", BODY_Y)
pico.set(view, "w", W)
pico.set(view, "h", BODY_H)

local canvas = pico.create("Canvas")
pico.set(canvas, "x", X)
pico.set(canvas, "y", BODY_Y)
pico.set(canvas, "w", W)
pico.set(canvas, "h", BODY_H)
pico.set(canvas, "visible", false)

local image = pico.image_load(pico.path_join(DIR, "icon.pimg"))

-- ---- 結果 ----
local lines = {}

local function show()
    pico.text_set(view, table.concat(lines, "\n"))
    pico.set(view, "scroll_y", 1000000)  -- 一番下(新しい結果)を見せる。大きすぎる値は切り詰められる
end

local function out(fmt, ...)
    local s = string.format(fmt, ...)
    lines[#lines + 1] = s
    pico.log("[HWCHK] " .. s)
    show()
end

local function us(t0) return pico.micros() - t0 end
local function ms(v) return string.format("%.2fms", v / 1000) end

-- ---- 描画(Canvasのrenderの中で動かす仕事) ----
local draw_job = nil   -- { fn = function(), done = false, us = 0 }

pico.on(canvas, "render", function()
    local job = draw_job
    if not job then
        pico.fill_rect(X, BODY_Y, W, BODY_H, 15)
        return
    end
    local t0 = pico.micros()
    job.fn()
    job.us = us(t0)
    job.done = true
end)

-- 次のフレームのrenderでfnを1回動かし、その時間(マイクロ秒)を返す(コルーチンの中で呼ぶ)
local function timed_render(fn)
    draw_job = { fn = fn, done = false, us = 0 }
    pico.invalidate(canvas)
    local waited = 0
    while not draw_job.done do
        coroutine.yield()
        waited = waited + 1
        if waited > 120 then draw_job = nil; return nil end
    end
    local r = draw_job.us
    draw_job = nil
    return r
end

-- ---- 測るもの ----
local function test_lua()
    out("== Lua ==")
    local t0 = pico.micros()
    local s = 0
    for i = 1, 100000 do s = s + i end
    out(pico.tr("整数の足し算 10万回: %s"), ms(us(t0)))
    coroutine.yield()

    t0 = pico.micros()
    local f = 0.0
    for i = 1, 20000 do f = f + math.sin(i * 0.001) * 1.5 end
    out(pico.tr("sin+掛け算 2万回: %s"), ms(us(t0)))
    coroutine.yield()

    t0 = pico.micros()
    local t = {}
    for i = 1, 2000 do t[i] = i end
    out(pico.tr("表へ追加 2000件: %s"), ms(us(t0)))
    coroutine.yield()

    t0 = pico.micros()
    local parts = {}
    for i = 1, 2000 do parts[i] = tostring(i) end
    local joined = table.concat(parts, ",")
    out(pico.tr("文字列 2000個→連結(%dB): %s"), #joined, ms(us(t0)))
    t, parts, joined = nil, nil, nil
    coroutine.yield()

    t0 = pico.micros()
    collectgarbage("collect")
    out(pico.tr("ごみ集め(全部): %s  Lua %dKB"), ms(us(t0)), math.floor(collectgarbage("count")))
    coroutine.yield()
end

local function test_draw()
    out(pico.tr("== 描画(renderの中だけ) =="))
    pico.set(view, "visible", false)
    pico.set(canvas, "visible", true)

    local r = timed_render(function()
        for i = 1, 10 do pico.fill_rect(X, BODY_Y, W, BODY_H, i % 14 + 1) end
    end)
    if r then out(pico.tr("全面fill_rect x10: %s (1回 %s)"), ms(r), ms(r // 10)) end

    r = timed_render(function()
        pico.fill_rect(X, BODY_Y, W, BODY_H, 15)
        for i = 1, 100 do pico.fill_circle(X + (i * 37) % W, BODY_Y + (i * 53) % BODY_H, 10, i % 14 + 1) end
    end)
    if r then out("fill_circle r10 x100: %s", ms(r)) end

    r = timed_render(function()
        pico.fill_rect(X, BODY_Y, W, BODY_H, 15)
        for i = 1, 100 do pico.draw_line(X, BODY_Y + i * 2, X + W - 1, BODY_Y + BODY_H - i * 2, i % 14 + 1) end
    end)
    if r then out(pico.tr("draw_line 全幅 x100: %s"), ms(r)) end

    r = timed_render(function()
        pico.fill_rect(X, BODY_Y, W, BODY_H, 15)
        for i = 0, 29 do pico.draw_text(X + 2, BODY_Y + (i % 15) * 18, "日本語の文字ABC123", 0, 16) end
    end)
    if r then out(pico.tr("draw_text 16px 9文字 x30: %s"), ms(r)) end

    if image then
        local iw, ih = pico.image_size(image)
        r = timed_render(function()
            pico.fill_rect(X, BODY_Y, W, BODY_H, 15)
            for i = 0, 99 do pico.draw_image(image, X + (i * 23) % (W - iw), BODY_Y + (i * 31) % (BODY_H - ih)) end
        end)
        if r then out("draw_image %dx%d x100: %s", iw, ih, ms(r)) end
    end

    out(pico.tr("== 転送(全面の描き直し 60フレーム) =="))
    local frames, worst = 0, 0
    local last = nil
    local t0 = pico.micros()
    for i = 1, 60 do
        draw_job = { fn = function() pico.fill_rect(X, BODY_Y, W, BODY_H, i % 14 + 1) end, done = false, us = 0 }
        pico.invalidate(canvas)
        coroutine.yield()
        local now = pico.micros()
        if last then worst = math.max(worst, now - last) end
        last = now
        frames = frames + 1
    end
    local total = us(t0)
    draw_job = nil
    out(pico.tr("%dx%d: 平均 %s/フレーム (%.1ffps) 最大 %s"), W, BODY_H, ms(total // frames), frames * 1e6 / total, ms(worst))

    pico.set(canvas, "visible", false)
    pico.set(view, "visible", true)
    show()
    coroutine.yield()
end

local function test_sd()
    out("== SD ==")
    local data = string.rep("0123456789abcdef", 1024)  -- 16KiB
    local t0 = pico.micros()
    local ok = pico.sd_write(TMP_FILE, data)
    out(pico.tr("書き込み 16KiB: %s %s"), ms(us(t0)), ok and "" or pico.tr("(失敗)"))
    coroutine.yield()

    t0 = pico.micros()
    local back = pico.sd_read(TMP_FILE)
    out(pico.tr("読み込み 16KiB: %s %s"), ms(us(t0)), back == data and "" or pico.tr("(中身が違う)"))
    coroutine.yield()

    t0 = pico.micros()
    for i = 1, 20 do pico.sd_write(TMP_FILE, "line\n", true) end
    out(pico.tr("追記 5B x20: %s"), ms(us(t0)))
    coroutine.yield()

    t0 = pico.micros()
    pico.settings_set("bench", pico.millis())
    out(pico.tr("settings_set 1回: %s"), ms(us(t0)))
    pico.sd_remove(TMP_FILE)
    coroutine.yield()
end

local function test_crypto()
    out(pico.tr("== 暗号 =="))
    local plain = string.rep("secret", 100)
    local t0 = pico.micros()
    local c = pico.encrypt(plain)
    out(pico.tr("encrypt 600B(固定鍵): %s"), ms(us(t0)))
    coroutine.yield()

    local before = pico.memory_info()
    t0 = pico.micros()
    c = pico.encrypt(plain, "password-1234")
    local enc = us(t0)
    coroutine.yield()
    t0 = pico.micros()
    local p = pico.decrypt(c, "password-1234")
    out(pico.tr("encrypt/decrypt パスワード(Argon2id): %s / %s %s"), ms(enc), ms(us(t0)), p == plain and "" or pico.tr("(戻らない)"))
    out(pico.tr("  その前の heap_free=%d"), before.heap_free or -1)
    coroutine.yield()

    t0 = pico.micros()
    for i = 1, 20 do pico.hash(plain) end
    out("hash 600B x20: %s", ms(us(t0)))
    coroutine.yield()
end

local function test_json()
    out("== JSON ==")
    local items = {}
    for i = 1, 200 do items[i] = { id = i, name = "item" .. i, v = i * 0.5, ok = (i % 2 == 0) } end
    local t0 = pico.micros()
    local text = pico.json_encode(items)
    out(pico.tr("encode 200件(%dB): %s"), #text, ms(us(t0)))
    coroutine.yield()
    t0 = pico.micros()
    local back = pico.json_decode(text)
    out("decode: %s %s", ms(us(t0)), (back and #back == 200) and "" or pico.tr("(失敗)"))
    coroutine.yield()
end

local function test_https()
    out("== HTTPS ==")
    local wifi = pico.wifi_status()
    if not wifi.connected then
        out(pico.tr("Wi-Fiに繋がっていないので飛ばします"))
        return
    end
    out("GET %s", TLS_URL)
    local done, result = false, nil
    local t0 = pico.micros()
    local last, worst = t0, 0
    local id = pico.http_request("GET", TLS_URL, nil, nil, function(ok, code, body, err)
        result = { ok = ok, code = code, err = err, size = body and #body or 0 }
        done = true
    end)
    if not id then out(pico.tr("始められませんでした")); return end
    while not done do
        coroutine.yield()
        local now = pico.micros()
        worst = math.max(worst, now - last)
        last = now
        if now - t0 > 30000000 then pico.http_cancel(id); out(pico.tr("30秒で打ち切り")); return end
    end
    if result.ok then
        out(pico.tr("status=%s %dB: %s  一番長く止まったフレーム %s"), tostring(result.code), result.size, ms(us(t0)), ms(worst))
    else
        out(pico.tr("失敗: %s (%s)"), tostring(result.err), ms(us(t0)))
    end
    coroutine.yield()
end

local function test_memory()
    out(pico.tr("== メモリ =="))
    local m = pico.memory_info()
    out(pico.tr("Lua %d/%dKB  画像 %dB"), (m.lua_used or 0) // 1024, (m.lua_budget or 0) // 1024, m.image_bytes or 0)
    out("heap free=%d used=%d headroom=%d", m.heap_free or -1, m.heap_used or -1, m.heap_headroom or -1)
    if m.heap_room then out("heap room=%d refused=%d", m.heap_room, m.heap_refused or 0) end
end

-- ---- 順に動かす ----
local runner = nil
local started_ms = 0

local function header()
    local t = pico.get_time()
    local b = { pico.battery() }
    out("---- %04d-%02d-%02d %02d:%02d ----", t.year, t.month, t.day, t.hour, t.min)
    if b[1] then out(pico.tr("電池 %d%% %s"), b[1], b[3] and pico.tr("USB給電") or pico.tr("電池駆動")) end
    out(pico.tr("音 %dHz / 起動から %ds"), pico.sound_rate(), pico.millis() // 1000)
end

local function start(tests)
    if runner then return end
    lines = {}
    started_ms = pico.millis()
    runner = coroutine.create(function()
        header()
        for i, t in ipairs(tests) do
            pico.set(status, "text", string.format(pico.tr("測っています %d/%d"), i, #tests))
            t()
        end
    end)
end

local ALL = { test_lua, test_draw, test_sd, test_crypto, test_json, test_https, test_memory }

button(pico.tr("全部"), X + 2, 70, function() start(ALL) end)
button(pico.tr("描画"), X + 76, 70, function() start({ test_draw }) end)
pico.set(button("", X + W - 72, 70, function() pico.pop() end), "icon_id", 30)  -- ArrowLeft
pico.on_back(function() pico.pop() end)

function loop(dt)
    if not runner then return end
    pico.keep_awake()
    local ok, err = coroutine.resume(runner)
    if not ok then
        out(pico.tr("エラー: %s"), tostring(err))
        runner = nil
        pico.set(canvas, "visible", false)
        pico.set(view, "visible", true)
        pico.set(status, "text", pico.tr("エラーで止まりました"))
        return
    end
    if coroutine.status(runner) == "dead" then
        runner = nil
        out(pico.tr("(%d秒)"), (pico.millis() - started_ms) // 1000)
        local saved = pico.sd_write(RESULT_FILE, table.concat(lines, "\n") .. "\n\n", true)
        pico.set(status, "text", saved and pico.tr("終わりました(results.txt へ追記)") or pico.tr("終わりました(保存に失敗)"))
    end
end
