-- 再生の状態を数秒ごとに取りに行き、操作(再生/停止・次へ・前へ・シーク・音量・シャッフル・リピート・端末)を送る。
-- 状態は P.st に置き、画面を描き直してほしいときは P.dirty を立てる(描くのは view.lua)。
-- ジャケットの欄も描き直すときだけ P.art_dirty も立てる(ジャケットはフルカラーで描くたびにSDから解き直し、
-- そのとき液晶が少しちらつくので、3秒ごとの取り直しや操作では描き直さない)。
local A = require("api")
local P = {}

P.ART = 80          -- ジャケット画像の大きさ(px。見せる枠)
P.st = nil          -- 再生の状態(nil = 再生中の端末が無い/まだ分からない)
P.msg = ""          -- 下の欄の1行
P.msg_err = false
P.dirty = true
P.art_dirty = true
P.art = nil         -- ジャケット画像のハンドル

local POLL_MS = 3000      -- 再生中・止めているときの取り直しの間隔
local IDLE_MS = 10000     -- 端末が無いとき
local next_poll = 0
local polling = false
local file_mode = false   -- 応答が16KiBを超えた(番組の説明が長い等)ので、SDへ保存してから読む
local backoff = 0
local msg_until = nil
local art_url = nil       -- 今見せている(または取れなかった)画像のURL
local art_loading = nil
local vol_timer = nil
local vol_pending = nil
local muted_from = nil

-- json_pick で読むパス(32個まで)
local PATHS = {
    "is_playing", "progress_ms", "currently_playing_type", "shuffle_state", "repeat_state",
    "device.id", "device.name", "device.volume_percent", "device.supports_volume",
    "item.name", "item.duration_ms", "item.artists#", "item.artists.1.name", "item.artists.2.name",
    "item.album.name", "item.album.images#", "item.album.images.1.url", "item.album.images.2.url",
    "item.show.name", "item.images#", "item.images.1.url", "item.images.2.url",
}

-- 下の欄に出す。ms を付けるとその時間で消える(付けなければ次に状態が取れたら消える)
function P.say(text, err, ms)
    text = text or ""
    if P.msg ~= text or P.msg_err ~= (err == true) then P.dirty = true end
    P.msg, P.msg_err = text, err == true
    msg_until = ms and (pico.millis() + ms) or nil
end

-- ms後(既定はすぐ)に状態を取り直す
function P.poll_soon(ms)
    local t = pico.millis() + (ms or 0)
    if t < next_poll then next_poll = t end
end

-- 今の再生位置(ms)。前に取ってからの時間を足して見せる
function P.position()
    local s = P.st
    if not s then return 0 end
    local p = s.progress
    if s.playing then p = p + (pico.millis() - s.at) end
    if s.duration > 0 and p > s.duration then p = s.duration end
    return p
end

-- 画像は横300px前後(2番目)を使う(1/4に縮めて75px)。1つしか無ければそれ
local function pick_image(r, base)
    local n = r[base .. "#"] or 0
    if n >= 2 then return r[base .. ".2.url"] end
    if n >= 1 then return r[base .. ".1.url"] end
end

local function parse(r)
    local s = {
        playing = r.is_playing == true,
        progress = r.progress_ms or 0,
        duration = r["item.duration_ms"] or 0,
        kind = r.currently_playing_type or "track",
        title = r["item.name"] or "",
        album = r["item.album.name"] or "",
        device = r["device.name"] or "",
        device_id = r["device.id"],
        volume = r["device.volume_percent"],
        shuffle = r.shuffle_state == true,
        rep = r.repeat_state or "off",
        at = pico.millis(),
    }
    s.can_volume = r["device.supports_volume"] ~= false and s.volume ~= nil
    local a1, a2 = r["item.artists.1.name"], r["item.artists.2.name"]
    if a1 then
        s.artist = a2 and (a1 .. ", " .. a2 .. ((r["item.artists#"] or 0) > 2 and " ほか" or "")) or a1
    else
        s.artist = r["item.show.name"] or ""   -- ポッドキャストは番組名
    end
    if s.kind == "ad" then s.title = "(広告)" end
    s.art = pick_image(r, "item.album.images") or pick_image(r, "item.images")
    return s
end

local function art_path() return pico.path_join(pico.app_dir(), "art.jpg") end

local function free_art()
    if P.art then pico.image_free(P.art) P.art = nil end
end

-- 曲が変わってジャケットのURLが変わったら取りに行く(1枚ずつ。失敗した同じURLは取り直さない)
local function update_art(url)
    if url == art_url or art_loading then return end
    if not url then
        free_art()
        art_url = nil
        P.dirty = true
        P.art_dirty = true
        return
    end
    art_loading = url
    A.download(url, art_path(), function(ok)
        art_loading = nil
        free_art()
        art_url = url
        -- full_color: Canvas で描くと、16色の絵の上にSDから解きながら液晶へそのままの色で描かれる
        if ok then P.art = pico.image_load(art_path(), { max_w = P.ART, max_h = P.ART, full_color = true }) end
        P.dirty = true
        P.art_dirty = true
    end)
end

local function poll()
    if polling or not A.auth then return end
    local now = pico.millis()
    if not A.clock_ok() then
        P.say("時計が合うのを待っています(Wi-Fiにつないでください)")
        next_poll = now + 2000
        return
    end
    polling = true
    next_poll = now + 60000   -- 応答が来るまでは次を出さない(来たら決め直す)
    local save = file_mode and pico.path_join(pico.app_dir(), "player.json") or nil
    A.call("GET", "/me/player?market=from_token&additional_types=episode", nil, function(ok, status, body, err)
        polling = false
        now = pico.millis()
        if not ok then
            if err == "書き込みに失敗" and not file_mode then   -- 16KiBを超えた: 次はSDへ保存して読む
                file_mode = true
                next_poll = now
                return
            end
            backoff = math.min(backoff == 0 and 5000 or backoff * 2, 60000)
            P.say(tostring(err), true)
            next_poll = now + backoff
            return
        end
        backoff = 0
        if status == 204 then
            if P.st then P.st = nil P.dirty = true end
            update_art(nil)
            P.say("再生中の端末がありません。Spotifyで再生するか「端末」で選んでください")
            next_poll = now + IDLE_MS
            return
        end
        if status ~= 200 then
            P.say(A.error_text(status, body), true)
            next_poll = now + (status == 429 and 30000 or IDLE_MS)
            return
        end
        local r
        if save then r = pico.sd_json_pick(save, PATHS) else r = pico.json_pick(body or "", PATHS) end
        if not r then
            P.say("応答を読めません", true)
            next_poll = now + POLL_MS
            return
        end
        local s = parse(r)
        if file_mode and s.kind == "track" then file_mode = false end
        if vol_pending then s.volume = vol_pending end   -- 送る前の音量で戻さない
        P.st = s
        P.dirty = true
        if not msg_until then P.say("") end
        update_art(s.art)
        next_poll = now + POLL_MS
    end, { save_to = save })
end

-- 毎フレーム呼ぶ
function P.update()
    local now = pico.millis()
    if msg_until and now >= msg_until then P.say("") end
    if A.auth and now >= next_poll then poll() end
end

-- 操作を送る。成功したら少し待って状態を取り直す(Spotify側に反映されるまで少しかかる)
local function action(method, path, json, wait_ms)
    A.call(method, path, json, function(ok, status, body, err)
        if not ok then P.say(tostring(err), true, 4000)
        elseif status >= 300 then P.say(A.error_text(status, body), true, 5000) end
        P.poll_soon(wait_ms or 700)
    end)
end

function P.toggle()
    local s = P.st
    if s and s.playing then
        s.progress = P.position()
        s.at = pico.millis()
        s.playing = false
        P.dirty = true
        action("PUT", "/me/player/pause")
    else
        if s then s.at = pico.millis() s.playing = true P.dirty = true end
        action("PUT", "/me/player/play")
    end
end

function P.next() action("POST", "/me/player/next", nil, 900) end

-- 3秒より後なら曲の頭へ、それより前なら前の曲へ(よくある音楽アプリと同じ)
function P.prev()
    if P.st and P.position() > 3000 then return P.seek(0) end
    action("POST", "/me/player/previous", nil, 900)
end

function P.seek(ms)
    local s = P.st
    if not s then return end
    ms = math.floor(math.max(0, math.min(ms, s.duration)))
    s.progress = ms
    s.at = pico.millis()
    P.dirty = true
    action("PUT", "/me/player/seek?position_ms=" .. ms)
end

function P.shuffle()
    local s = P.st
    if not s then return end
    s.shuffle = not s.shuffle
    P.dirty = true
    action("PUT", "/me/player/shuffle?state=" .. tostring(s.shuffle))
end

local NEXT_REPEAT = { off = "context", context = "track", track = "off" }
function P.repeat_cycle()
    local s = P.st
    if not s then return end
    s.rep = NEXT_REPEAT[s.rep] or "off"
    P.dirty = true
    action("PUT", "/me/player/repeat?state=" .. s.rep)
end

-- 音量(0〜100)。続けて変えても、最後の値だけを0.4秒後に送る
function P.set_volume(v)
    local s = P.st
    if not (s and s.can_volume) then
        P.say("この端末は音量を変えられません", false, 3000)
        return
    end
    v = math.floor(math.max(0, math.min(100, v)) + 0.5)
    if s.volume ~= v then s.volume = v P.dirty = true end
    vol_pending = v
    if vol_timer then pico.cancel(vol_timer) end
    vol_timer = pico.after(400, function()
        vol_timer = nil
        local send = vol_pending
        action("PUT", "/me/player/volume?volume_percent=" .. send, nil, 1500)
        vol_pending = nil
    end)
end

function P.volume_step(d)
    if P.st and P.st.volume then P.set_volume(P.st.volume + d) end
end

function P.mute()
    local s = P.st
    if not (s and s.volume) then return end
    if s.volume > 0 then
        muted_from = s.volume
        P.set_volume(0)
    else
        P.set_volume(muted_from or 50)
    end
end

-- 端末の一覧。fn(list) list = { {id=, name=, active=}, ... } / fn(nil, 理由)
function P.devices(fn)
    A.call("GET", "/me/player/devices", nil, function(ok, status, body, err)
        if not ok then return fn(nil, tostring(err)) end
        if status ~= 200 then return fn(nil, A.error_text(status, body)) end
        local paths = { "devices#" }
        for i = 1, 8 do
            paths[#paths + 1] = "devices." .. i .. ".id"
            paths[#paths + 1] = "devices." .. i .. ".name"
            paths[#paths + 1] = "devices." .. i .. ".is_active"
        end
        local r = pico.json_pick(body or "", paths)
        if not r then return fn(nil, "応答を読めません") end
        local list = {}
        for i = 1, math.min(r["devices#"] or 0, 8) do
            local id = r["devices." .. i .. ".id"]
            if id then
                list[#list + 1] = { id = id, name = r["devices." .. i .. ".name"] or "?",
                                    active = r["devices." .. i .. ".is_active"] == true }
            end
        end
        fn(list)
    end)
end

-- その端末へ再生を移す(止まっていれば再生も始める)
function P.transfer(id)
    P.say("端末を切り替えています…", false, 3000)
    action("PUT", "/me/player", pico.json_encode({ device_ids = { id }, play = true }), 1500)
end

-- ログアウトや画面を離れるとき
function P.reset()
    free_art()
    art_url = nil
    P.st = nil
    if vol_timer then pico.cancel(vol_timer) vol_timer = nil end
    vol_pending = nil
    next_poll = 0
    P.dirty = true
    P.art_dirty = true
end

function P.close()
    P.reset()
    pico.http_cancel()
    pico.http_close()
end

return P
