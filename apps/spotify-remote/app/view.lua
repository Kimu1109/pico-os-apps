-- 画面を描く・タップの場所から操作を決める。状態は player.lua(P)が持つ。
-- Canvas 1枚の render の中で描く(ボタンも自分で描く。部品ごとにButtonを作らない)
local P = require("player")
local V = {}

-- パレットの番号(既定のパレット)
local BLACK, DKGREEN, MAROON, LTGREY, DKGREY, GREEN, WHITE = 0, 2, 4, 7, 8, 10, 15
local FS = 0      -- 文字は16px

local X, Y, W, H = 0, 0, 240, 268
-- 部品の位置(setup()で決める)
local ART_X, ART_Y, TX, TW
local BAR_Y, BAR_X0, BAR_X1
local CTRL_Y, CTRL_X
local VOL_Y, VOL_X0, VOL_X1, VOL_MINUS, VOL_PLUS
local MSG_Y

V.drag = nil      -- { kind = "seek"|"vol", v = 0〜1 }(つまみを動かしている間)

function V.setup(x, y, w, h)
    X, Y, W, H = x, y, w, h
    ART_X, ART_Y = X + 8, Y + 6
    TX = ART_X + P.ART + 8
    TW = X + W - 6 - TX
    BAR_Y = Y + 104
    BAR_X0, BAR_X1 = X + 14, X + W - 14
    CTRL_Y = Y + 158
    CTRL_X = { X + W * 1 // 10, X + W * 3 // 10, X + W // 2, X + W * 7 // 10, X + W * 9 // 10 }
    VOL_Y = Y + 210
    VOL_MINUS, VOL_PLUS = X + 18, X + W - 64
    VOL_X0, VOL_X1 = X + 38, X + W - 84
    MSG_Y = Y + 232
end

-- 幅に収まるよう後ろを切って "..." を付ける(同じ文字列を何度も測らないよう覚える)
local fit_cache, fit_count = {}, 0
local function fit(text, w)
    if text == "" then return "" end
    local key = w .. "\0" .. text
    local hit = fit_cache[key]
    if hit then return hit end
    local out = text
    if pico.text_width(text, FS) > w then
        local n = utf8.len(text) or #text
        local lo, hi = 0, n
        while lo < hi do   -- 収まる一番長い文字数を探す
            local mid = (lo + hi + 1) // 2
            local cut = text:sub(1, (utf8.offset(text, mid + 1) or #text + 1) - 1)
            if pico.text_width(cut .. "...", FS) <= w then lo = mid else hi = mid - 1 end
        end
        out = text:sub(1, (utf8.offset(text, lo + 1) or #text + 1) - 1) .. "..."
    end
    if fit_count > 32 then fit_cache, fit_count = {}, 0 end
    fit_cache[key] = out
    fit_count = fit_count + 1
    return out
end
V.fit = fit

local function mmss(ms)
    local s = (ms or 0) // 1000
    return string.format("%d:%02d", s // 60, s % 60)
end

local function draw_art()
    if P.art then
        local w, h = pico.image_size(P.art)
        pico.draw_image(P.art, ART_X + (P.ART - w) // 2, ART_Y + (P.ART - h) // 2)
        return
    end
    -- 画像が無いときは音符の絵
    pico.fill_rect(ART_X, ART_Y, P.ART, P.ART, LTGREY)
    local cx, cy = ART_X + P.ART // 2, ART_Y + P.ART // 2
    pico.fill_circle(cx - 8, cy + 14, 8, DKGREY)
    pico.fill_rect(cx - 1, cy - 20, 4, 36, DKGREY)
    pico.fill_triangle(cx + 3, cy - 20, cx + 17, cy - 10, cx + 3, cy - 6, DKGREY)
end

local function bar(x0, x1, y, v, color)
    pico.fill_rect(x0, y - 2, x1 - x0, 4, LTGREY)
    local kx = x0 + math.floor((x1 - x0) * math.max(0, math.min(1, v)) + 0.5)
    pico.fill_rect(x0, y - 2, kx - x0, 4, color)
    pico.fill_circle(kx, y, 6, color)
end

-- 再生位置の欄(1秒ごとに描き直すのはここだけ)
function V.progress_rect() return X, BAR_Y - 10, W, 34 end

local function draw_progress(s)
    local pos = P.position()
    local v = (s.duration > 0) and (pos / s.duration) or 0
    if V.drag and V.drag.kind == "seek" then
        v = V.drag.v
        pos = math.floor(v * s.duration)
    end
    bar(BAR_X0, BAR_X1, BAR_Y, v, s.duration > 0 and BLACK or LTGREY)
    pico.draw_text(BAR_X0, BAR_Y + 8, mmss(pos), DKGREY, FS)
    if s.duration > 0 then pico.draw_text(BAR_X1, BAR_Y + 8, mmss(s.duration), DKGREY, FS, "right") end
end

-- 操作のボタン(シャッフル・前・再生/停止・次・リピート)
local function draw_controls(s)
    local y = CTRL_Y
    local on = s ~= nil
    local fg = on and BLACK or LTGREY
    -- シャッフル: 交差する2本の線と矢じり
    local x = CTRL_X[1]
    local c = (s and s.shuffle) and DKGREEN or (on and DKGREY or LTGREY)
    pico.draw_line(x - 10, y - 6, x + 8, y + 6, c, 2)
    pico.draw_line(x - 10, y + 6, x + 8, y - 6, c, 2)
    pico.fill_triangle(x + 11, y - 7, x + 5, y - 9, x + 7, y - 2, c)
    pico.fill_triangle(x + 11, y + 7, x + 5, y + 9, x + 7, y + 2, c)
    if s and s.shuffle then pico.fill_circle(x, y + 14, 2, DKGREEN) end
    -- 前: 縦棒と左向きの三角
    x = CTRL_X[2]
    pico.fill_rect(x - 10, y - 9, 3, 18, fg)
    pico.fill_triangle(x + 9, y - 9, x + 9, y + 9, x - 6, y, fg)
    -- 再生/一時停止: 黒い丸に白で
    x = CTRL_X[3]
    pico.fill_circle(x, y, 22, on and BLACK or LTGREY)
    if s and s.playing then
        pico.fill_rect(x - 8, y - 9, 6, 18, WHITE)
        pico.fill_rect(x + 2, y - 9, 6, 18, WHITE)
    else
        pico.fill_triangle(x - 6, y - 11, x - 6, y + 11, x + 11, y, WHITE)
    end
    -- 次: 右向きの三角と縦棒
    x = CTRL_X[4]
    pico.fill_triangle(x - 9, y - 9, x - 9, y + 9, x + 6, y, fg)
    pico.fill_rect(x + 7, y - 9, 3, 18, fg)
    -- リピート: 角の丸い輪と矢じり。曲のリピートは「1」
    x = CTRL_X[5]
    local rep = s and s.rep or "off"
    c = (rep ~= "off") and DKGREEN or (on and DKGREY or LTGREY)
    pico.draw_rect(x - 10, y - 6, 20, 12, c)
    pico.draw_rect(x - 9, y - 5, 18, 10, c)
    pico.fill_triangle(x + 2, y - 11, x + 2, y - 1, x + 8, y - 6, c)
    if rep == "track" then pico.draw_text(x - 3, y - 7, "1", c, FS) end
    if rep ~= "off" then pico.fill_circle(x, y + 14, 2, DKGREEN) end
end

local function draw_volume(s)
    local can = s and s.can_volume
    local c = can and BLACK or LTGREY
    -- −と+
    pico.draw_circle(VOL_MINUS, VOL_Y, 10, c)
    pico.fill_rect(VOL_MINUS - 5, VOL_Y - 1, 11, 3, c)
    pico.draw_circle(VOL_PLUS, VOL_Y, 10, c)
    pico.fill_rect(VOL_PLUS - 5, VOL_Y - 1, 11, 3, c)
    pico.fill_rect(VOL_PLUS - 1, VOL_Y - 5, 3, 11, c)
    local v = (s and s.volume or 0) / 100
    if V.drag and V.drag.kind == "vol" then v = V.drag.v end
    bar(VOL_X0, VOL_X1, VOL_Y, v, can and DKGREEN or LTGREY)
    local label = can and (math.floor(v * 100 + 0.5) .. "%") or "音量 -"
    pico.draw_text(X + W - 6, VOL_Y - 8, label, can and BLACK or DKGREY, FS, "right")
end

local function draw_message()
    if P.msg == "" then return end
    pico.draw_text_wrapped(X + 6, MSG_Y, W - 12, P.msg, P.msg_err and MAROON or DKGREY, FS, "left")
end

-- ログインしていないときの案内
local function draw_setup()
    pico.draw_text_wrapped(X + 8, Y + 8, W - 16,
        "Spotifyにログインしていません。\n\n" ..
        "PCで次を実行し、作られた spotify_auth.json をSDの lua/apps/Spotify/ へ置いてください" ..
        "(USBドライブで繋げばそのまま書けます)。\n\n" ..
        "picoos spotify-auth --client-id <ID> --sd <SDの場所>\n\n" ..
        "Client ID は developer.spotify.com のダッシュボードで作ったアプリのものです。",
        BLACK, FS, "left")
    -- 読み直すボタン
    local bx, by, bw, bh = V.reload_rect()
    pico.fill_rect(bx, by, bw, bh, BLACK)
    pico.draw_text(bx + bw // 2, by + 8, "読み込む", WHITE, FS, "center")
    draw_message()
end
function V.reload_rect() return X + W // 2 - 60, Y + H - 72, 120, 32 end

function V.render(logged_in)
    pico.fill_rect(X, Y, W, H, WHITE)
    if not logged_in then return draw_setup() end
    local s = P.st
    draw_art()
    if s then
        pico.draw_text(TX, ART_Y, fit(s.title, TW), BLACK, FS)
        pico.draw_text(TX, ART_Y + 20, fit(s.artist, TW), BLACK, FS)
        pico.draw_text(TX, ART_Y + 40, fit(s.album, TW), DKGREY, FS)
        if s.device ~= "" then
            pico.draw_text(TX, ART_Y + 62, fit("端末: " .. s.device, TW), DKGREEN, FS)
        end
        draw_progress(s)
    else
        pico.draw_text(TX, ART_Y, "停止中", DKGREY, FS)
        bar(BAR_X0, BAR_X1, BAR_Y, 0, LTGREY)
    end
    draw_controls(s)
    draw_volume(s)
    draw_message()
end

-- タップした場所の操作。戻り値: 名前, 値(シーク/音量の割合)
function V.hit(px, py, logged_in)
    if not logged_in then
        local bx, by, bw, bh = V.reload_rect()
        if px >= bx and px < bx + bw and py >= by and py < by + bh then return "reload" end
        return nil
    end
    if math.abs(py - BAR_Y) <= 14 and px >= BAR_X0 - 8 and px <= BAR_X1 + 8 then
        return "seek", math.max(0, math.min(1, (px - BAR_X0) / (BAR_X1 - BAR_X0)))
    end
    if math.abs(py - CTRL_Y) <= 26 then
        local names = { "shuffle", "prev", "play", "next", "repeat" }
        local best, bd = nil, 1e9
        for i, cx in ipairs(CTRL_X) do
            local d = math.abs(px - cx)
            if d < bd then best, bd = names[i], d end
        end
        if bd <= W // 10 then return best end
    end
    if math.abs(py - VOL_Y) <= 14 then
        if math.abs(px - VOL_MINUS) <= 14 then return "vol-" end
        if math.abs(px - VOL_PLUS) <= 14 then return "vol+" end
        if px >= VOL_X0 - 8 and px <= VOL_X1 + 8 then
            return "vol", math.max(0, math.min(1, (px - VOL_X0) / (VOL_X1 - VOL_X0)))
        end
    end
    return nil
end

return V
